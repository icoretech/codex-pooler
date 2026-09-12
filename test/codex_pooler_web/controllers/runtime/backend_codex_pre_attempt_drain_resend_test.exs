defmodule CodexPoolerWeb.Runtime.BackendCodexPreAttemptDrainResendTest do
  # End-to-end coverage for the pre-attempt owner drain *producer*, joined to
  # the consumer that reads what it writes.
  #
  # `ClientRetry.verified_pre_attempt_drain?/2` and `released_without_settlement?/1`
  # are exercised elsewhere against a hand-stamped `websocket_pre_attempt_drain`
  # marker and a hand-built release (`client_retry_pre_attempt_test.exs`,
  # `client_retry_postgres_test.exs`). Stamping is legitimate input for a
  # predicate, but it cannot notice that nothing *produces* the marker: the key
  # was never written once in ~1,000,000 production requests while those tests
  # were green (icoretech/codex-pooler-findings#160, #170).
  #
  # This module closes that loop. Every row the predicate reads is written by a
  # real drain driven through a real entry point -- the owner's own
  # `drain_owner/1` and the downstream socket's rollout-shaped `terminate/2` --
  # with no option map, receipt, marker, or ledger entry built by the test. The
  # assertion is the capability itself: the byte-identical resend is admitted.
  use ExUnit.Case, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, ClientRetry, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  @budget 15_000
  @moduletag capture_log: true

  # `WebsocketOwnerSession.drain_owner/1` is the graceful rollout drain of the
  # owner process itself (`RolloutDrain.drain_for_shutdown/0`).
  test "a graceful owner drain writes the marker and release a client resend needs" do
    assert_pre_attempt_drain_admits_resend(fn _setup, state ->
      assert :ok = WebsocketOwnerSession.drain_owner(state.websocket_owner_pid)
    end)
  end

  # The downstream socket's own shutdown is the other real entry point, and the
  # one that matters most: 96% of pre-visible drains are on the downstream
  # websocket (icoretech/codex-pooler-findings#166). A `:shutdown` teardown is
  # what a rollout delivers, and it is what makes the socket call the drain
  # reason `owner_drained` rather than `client_disconnected`.
  test "a downstream socket rollout shutdown writes the marker and release a client resend needs" do
    assert_pre_attempt_drain_admits_resend(fn _setup, state ->
      assert :ok = CodexResponsesSocket.terminate(:shutdown, state)
    end)
  end

  defp assert_pre_attempt_drain_admits_resend(drain) do
    {setup, upstream, state} = fixture()
    attach_commit_barrier(:reservation)
    frame = payload(setup)

    assert {:ok, state} = CodexResponsesSocket.handle_in({frame, [opcode: :text]}, state)
    assert_receive {:reservation_committed, task}, @budget
    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)

    # The turn is parked exactly inside the pre-attempt window: claimed and
    # reserved, no attempt row, so nothing has reached the provider.
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert request.status == "in_progress"
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
    assert ledger_kinds(request) == ["reservation"]
    assert ClientRetry.original_witness_eligible?(request)

    drain.(setup, state)

    request = Repo.reload!(request)
    turn = Repo.get_by!(CodexTurn, request_id: request.id)

    # Producer: the exact durable shape the two predicates read. Written here
    # by the drain, not by this test.
    assert request.status == "failed"
    assert request.last_error_code == "owner_drained"
    assert request.response_status_code == 499
    assert request.usage_status == "usage_unknown"
    assert request.request_metadata["websocket_pre_attempt_drain"] == true
    assert turn.status == "interrupted"
    assert turn.error_code == "owner_drained"
    assert is_nil(turn.final_attempt_id)
    assert is_nil(turn.first_visible_output_at)
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0

    # The marker and the release are the two halves of one safety argument and
    # must never diverge: a marker without a release would admit a resend whose
    # predecessor still holds reserved budget (findings#167).
    assert ledger_kinds(request) == ["release", "reservation"]

    release =
      Repo.one!(
        from e in LedgerEntry, where: e.request_id == ^request.id and e.entry_kind == "release"
      )

    assert release.details["release_reason"] == "owner_drained"
    assert release.usage_status == "usage_unknown"
    assert is_nil(release.attempt_id)

    # Consumer: the capability itself, through the entry point the resending
    # native websocket turn actually uses. `preflight_snapshot/4` is what
    # `Runtime.Service` calls when a client resends a byte-identical frame whose
    # semantic turn digest already has a turn; it answers "may this resend be
    # admitted as a successor of that predecessor?". For the whole of the
    # installation's history it answered `{:error, :terminal_predecessor}` for a
    # drained turn, because the marker was never written and the reservation was
    # never released.
    #
    # `preflight_snapshot/4` defers the owner-idle gate on purpose: whether the
    # previous owner is still serving is an orthogonal question, answered by the
    # resending socket's own lease, not by the drained rows.
    assert {:ok, %{client_retry_predecessor_request_id: predecessor_id, replay_generation: 0}} =
             ClientRetry.preflight_snapshot(
               Repo.reload!(state.codex_session),
               Repo.reload!(setup.api_key),
               setup.model,
               %{
                 endpoint: request.endpoint,
                 requested_model: setup.model.exposed_model_id,
                 runtime_revocation_epoch: setup.api_key.runtime_revocation_epoch,
                 semantic_turn_digest: turn.semantic_turn_digest,
                 replay_claim_digest: request.native_client_retry_digest
               }
             )

    assert predecessor_id == request.id
    assert FakeUpstream.count(upstream) == 0
  end

  defp fixture do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Sandbox.mode(Repo, :manual)

      if previous == nil,
        do: Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled),
        else: Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, previous)
    end)

    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete!(setup.pool)
        Repo.delete!(setup.identity)
        Repo.delete!(setup.pricing)
      end)
    end)

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{request_id: Ecto.UUID.generate(), accepted_turn_state: Ecto.UUID.generate()}
      })

    owner = state.websocket_owner_pid
    on_exit(fn -> if Process.alive?(owner), do: WebsocketOwnerSession.drain_owner(owner) end)
    {Map.put(setup, :auth, auth), upstream, state}
  end

  # Parks the response task on the commit that closes the reservation, which is
  # the last durable write before an attempt row exists.
  defp attach_commit_barrier(phase) do
    parent = self()
    barrier = make_ref()

    :ok =
      :telemetry.attach(
        barrier,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          query = metadata.query
          table = %{claim: "requests", reservation: "codex_turns", attempt: "attempts"}[phase]

          if String.contains?(query, "INSERT INTO") and String.contains?(query, table) do
            Process.put(barrier, true)
          end

          if String.downcase(query) == "commit" and Process.delete(barrier) do
            send(parent, {:reservation_committed, self()})

            receive do
              {:release_reservation, ^barrier} -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(barrier) end)
  end

  defp payload(setup) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [],
      "client_metadata" => %{
        "x-codex-turn-metadata" =>
          CodexPooler.JSON.encode!(%{
            "session_id" => Ecto.UUID.generate(),
            "thread_id" => Ecto.UUID.generate(),
            "turn_id" => Ecto.UUID.generate(),
            "request_kind" => "turn"
          })
      },
      "stream" => true,
      "generate" => true
    })
  end

  defp ledger_kinds(request) do
    Repo.all(from e in LedgerEntry, where: e.request_id == ^request.id, select: e.entry_kind)
    |> Enum.sort()
  end
end
