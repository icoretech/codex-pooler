defmodule CodexPooler.Accounting.RequestReplayCleanupTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.RequestReplayFixtures

  alias CodexPooler.Accounting.{RequestReplay, RequestReplayEntitlement}
  alias CodexPooler.Gateway.Transports.Streaming.{RuntimeAdmissionProof, StreamProtocol}
  alias CodexPooler.Gateway.Transports.Websocket.{NativeReplayAdmission, WebsocketOwnerSession}
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request
  alias CodexPooler.Jobs.{RequestReplayCleanupWorker, RuntimeStateCleanupWorker, Schedule}

  test "more than a batch of earlier noops cannot starve later expired replay" do
    due_at = DateTime.add(DateTime.utc_now(), -60, :second)

    for _ <- 1..101 do
      fixture = replay_fixture(reservation?: true)

      insert_entitlement!(fixture, %{
        armed_at: DateTime.add(due_at, -30, :second),
        expires_at: due_at
      })

      fixture.turn |> Ecto.Changeset.change(status: "failed") |> Repo.update!()
    end

    last = replay_fixture(reservation?: true)

    insert_entitlement!(last, %{
      armed_at: DateTime.add(due_at, -29, :second),
      expires_at: DateTime.add(due_at, 1, :second)
    })

    assert {:ok,
            %{
              replay_entitlements_selected: 100,
              replay_entitlements_noop: 100,
              replay_entitlements_closed: 0,
              replay_cleanup_batch_full: true
            }} = measured_cleanup("populated-noop-batch")

    assert {:ok, %{replay_entitlements_selected: 100, replay_entitlements_closed: 1}} =
             measured_cleanup("populated-progress-batch")

    assert Repo.reload!(last.request).last_error_code == "websocket_replay_expired"
    assert terminal_ledger_count(last.request.id, "settlement") == 1

    assert Repo.aggregate(
             from(row in RequestReplayEntitlement,
               where: not is_nil(row.cleanup_checked_at)
             ),
             :count
           ) == 101
  end

  test "minute worker persists measured bounded summary and generic worker keeps fifteen minutes" do
    assert {:ok, %{replay_entitlements_selected: 0}} = measured_cleanup("idle")
    assert {"* * * * *", RequestReplayCleanupWorker} in Schedule.oban_crontab()
    assert {"*/15 * * * *", RuntimeStateCleanupWorker} in Schedule.oban_crontab()
    assert RequestReplayCleanupWorker.timeout(%Oban.Job{}) == 45_000
    changeset = RequestReplayCleanupWorker.new(%{})
    assert Ecto.Changeset.get_field(changeset, :max_attempts) == 1
    job = Repo.insert!(changeset)
    assert :ok = RequestReplayCleanupWorker.perform(job)
    summary = Repo.reload!(job).meta["replay_cleanup"]
    assert summary["replay_entitlements_selected"] == 0
    assert summary["replay_entitlements_closed"] == 0
    assert summary["replay_entitlements_noop"] == 0
    assert summary["replay_cleanup_batch_full"] == false
    assert is_integer(summary["duration_ms"])
  end

  test "revoked or expired committed replay cannot start and compensates exactly once" do
    for cause <- [:revoked, :expired] do
      fixture = replay_fixture(reservation?: true)
      assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))

      assert {:ok, consumed} =
               RequestReplay.consume(consume_input(fixture, armed, :crypto.strong_rand_bytes(32)))

      case cause do
        :revoked ->
          assert {:ok, _key} = CodexPooler.Access.revoke_api_key(fixture.scope, fixture.api_key)

        :expired ->
          set_replay_db_now!(DateTime.add(consumed.entitlement.abandon_at, 1, :microsecond))
      end

      assert {:error, :ineligible} = RequestReplay.dispatch_lifecycle(consumed.consume_binding)
      assert {:error, :binding_mismatch} = RequestReplay.mark_started(consumed.consume_binding)
      assert is_nil(Repo.reload!(consumed.entitlement).started_at)
      assert_rejected_owner_send(fixture, consumed)

      assert {:error, :binding_mismatch} =
               RequestReplay.compensate_no_send(consumed.consume_binding)

      assert terminal_ledger_count(fixture.request.id, "settlement") == 1
      assert terminal_ledger_count(fixture.request.id, "release") == 1
    end
  end

  defp assert_rejected_owner_send(fixture, consumed) do
    {:ok, owner} = WebsocketOwnerSession.lookup(fixture.session.id)
    state = :sys.get_state(owner)
    downstream = Map.put(state.downstream, :active_turn_reconnect?, false)

    binding =
      struct!(
        NativeReplayAdmission.Binding,
        Map.merge(consumed.consume_binding, %{
          semantic_turn_digest: fixture.semantic_digest,
          replay_claim_digest: fixture.replay_claim_digest,
          downstream_epoch: state.downstream.epoch,
          owner_process_generation: state.process_generation
        })
      )

    :sys.replace_state(owner, fn state ->
      %{
        state
        | downstream: downstream,
          suspended_replay: %{
            state.suspended_replay
            | consume_binding: consumed.consume_binding,
              provisional_status: :committed_not_started
          }
      }
    end)

    request = %Request{
      url: "ws://localhost/replay-test",
      headers: [],
      payload: Jason.encode!(%{"type" => "response.create"}),
      timeouts: %{connect: 1_000, receive: 1_000},
      message_mapper: &StreamProtocol.canonicalize_native_codex_responses_json_message/1,
      native_replay_binding: binding,
      native_replay_proof:
        RuntimeAdmissionProof.new(self(), make_ref(), make_ref(), <<7::256>>, :native_replay),
      provisional_token: state.suspended_replay.provisional_token
    }

    assert {:error, :owner_unavailable} =
             WebsocketOwnerSession.submit_request(owner, downstream, request)

    assert Agent.get(state.upstream_pid, & &1) == 0
    assert Repo.reload!(consumed.entitlement).closed_at
  end

  defp measured_cleanup(label) do
    ref = make_ref()
    handler = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :repo, :query],
        &__MODULE__.count_query/4,
        {self(), ref}
      )

    started_at = System.monotonic_time(:microsecond)

    try do
      result = RequestReplay.cleanup_due()
      duration_us = System.monotonic_time(:microsecond) - started_at
      queries = drain_query_count(ref, 0)
      IO.puts(Jason.encode!(%{cleanup: label, duration_us: duration_us, queries: queries}))
      result
    after
      :telemetry.detach(handler)
    end
  end

  def count_query(_event, _measurements, _metadata, {parent, ref}) do
    if self() == parent, do: send(parent, {:cleanup_query, ref})
  end

  defp drain_query_count(ref, count) do
    receive do
      {:cleanup_query, ^ref} -> drain_query_count(ref, count + 1)
    after
      0 -> count
    end
  end
end
