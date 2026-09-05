defmodule CodexPooler.Gateway.Websocket.OwnerCleanupReplayTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.RequestReplayFixtures

  alias CodexPooler.Accounting.RequestReplay
  alias CodexPooler.Gateway.Persistence.BridgeOwnerLease
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission.Binding
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Persistence
  alias CodexPooler.Gateway.Websocket.OwnerCleanup

  @moduletag capture_log: true

  test "actual detached consumed owner drain closes replay and releases lease" do
    {fixture, consumed, owner} = pending_consumed_replay(:consumed_unnotified)
    downstream = :sys.get_state(owner).downstream
    assert :ok = WebsocketOwnerSession.detach_downstream(owner, downstream)
    detached = :sys.get_state(owner)
    assert is_nil(detached.downstream)
    assert is_nil(detached.suspended_replay.downstream)
    monitor = Process.monitor(owner)
    assert :ok = WebsocketOwnerSession.drain_owner(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 15_000
    assert Repo.reload!(fixture.request).status == "failed"
    assert Repo.reload!(consumed.attempt).status == "failed"
    assert Repo.reload!(consumed.entitlement).closed_at
    assert owner_lease(fixture).status == "released"
    assert terminal_ledger_count(fixture.request.id, "settlement") == 1
    assert terminal_ledger_count(fixture.request.id, "release") == 1
  end

  for phase <- [:consumed_unnotified, :committed_not_started] do
    test "actual owner drain closes #{phase} replay before submission" do
      {fixture, consumed, owner} = pending_consumed_replay(unquote(phase))
      monitor = Process.monitor(owner)
      assert :ok = WebsocketOwnerSession.drain_owner(owner)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 15_000
      assert Repo.reload!(fixture.request).status == "failed"
      assert Repo.reload!(consumed.attempt).status == "failed"
      assert Repo.reload!(consumed.entitlement).closed_at
      assert owner_lease(fixture).status == "released"
      assert terminal_ledger_count(fixture.request.id, "settlement") == 1
      assert terminal_ledger_count(fixture.request.id, "release") == 1
    end
  end

  test "actual owner drain with wrong provisional token leaves consumed replay untouched" do
    {fixture, consumed, owner} = pending_consumed_replay(:wrong_token)
    monitor = Process.monitor(owner)
    assert :ok = WebsocketOwnerSession.drain_owner(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 15_000
    assert Repo.reload!(fixture.request).status == "in_progress"
    assert Repo.reload!(consumed.attempt).status == "in_progress"
    assert is_nil(Repo.reload!(consumed.entitlement).closed_at)
    assert owner_lease(fixture).status == "active"
    assert terminal_ledger_count(fixture.request.id, "settlement") == 0
    assert terminal_ledger_count(fixture.request.id, "release") == 0
  end

  test "current consumed replay at a new downstream epoch closes exactly once on drain" do
    {fixture, consumed, state} = consumed_replay()
    assert state.active_turn.cleanup_witness.downstream_epoch == 2
    assert fixture.request.request_metadata["websocket_owner_forwarding"]["downstream_epoch"] == 1
    assert consumed.attempt.replay_generation == 1

    assert :ok = Persistence.interrupt_codex_session(state, :owner_drained)
    assert Repo.reload!(fixture.request).status == "failed"
    assert Repo.reload!(consumed.attempt).status == "failed"
    assert Repo.reload!(fixture.turn).status == "failed"
    assert Repo.reload!(consumed.entitlement).closed_at
    assert terminal_ledger_count(fixture.request.id, "settlement") == 1
    assert terminal_ledger_count(fixture.request.id, "release") == 1

    _duplicate = Persistence.interrupt_codex_session(state, :owner_drained)
    assert terminal_ledger_count(fixture.request.id, "settlement") == 1
    assert terminal_ledger_count(fixture.request.id, "release") == 1
  end

  test "different provisional replay proof cannot close the current consumed attempt" do
    {fixture, consumed, state} = consumed_replay()
    witness = state.active_turn.cleanup_witness
    binding = %{witness.native_replay_binding | provisional_binding_digest: <<8::256>>}

    stale = %{
      state
      | active_turn: %{cleanup_witness: %{witness | native_replay_binding: binding}}
    }

    assert {:error, :stale_owner_cleanup} =
             Persistence.interrupt_codex_session(stale, :owner_drained)

    assert Repo.reload!(fixture.request).status == "in_progress"
    assert Repo.reload!(consumed.attempt).status == "in_progress"
    assert Repo.reload!(fixture.turn).status == "in_progress"
    assert is_nil(Repo.reload!(consumed.entitlement).closed_at)
    assert terminal_ledger_count(fixture.request.id, "settlement") == 0
    assert terminal_ledger_count(fixture.request.id, "release") == 0
  end

  defp consumed_replay do
    fixture = replay_fixture(reservation?: true)

    request =
      fixture.request
      |> Ecto.Changeset.change(
        request_metadata: %{
          "websocket_owner_forwarding" => %{
            "owner_instance_id" => fixture.session.owner_instance_id,
            "downstream_epoch" => 1
          }
        }
      )
      |> Repo.update!()

    fixture = %{fixture | request: request}
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))
    input = consume_input(fixture, armed, :crypto.strong_rand_bytes(32))
    assert {:ok, consumed} = RequestReplay.consume(input)
    assert {:ok, started} = RequestReplay.mark_started(consumed.consume_binding)
    assert started.started_at
    assert {:ok, owner} = WebsocketOwnerSession.lookup(fixture.session.id)
    state = :sys.get_state(owner)

    binding =
      struct!(
        Binding,
        Map.merge(consumed.consume_binding, %{
          semantic_turn_digest: fixture.semantic_digest,
          replay_claim_digest: fixture.replay_claim_digest,
          downstream_epoch: state.downstream.epoch,
          owner_process_generation: state.process_generation
        })
      )

    request = %Request{
      request_id: consumed.request.id,
      attempt_id: consumed.attempt.id,
      native_replay_binding: binding
    }

    witness = OwnerCleanup.capture(state, Map.from_struct(request), state.downstream, 1)

    state = %{
      state
      | active_turn: %{cleanup_witness: witness},
        suspended_replay: nil,
        persistence: %{
          state.persistence
          | interrupt_codex_session: &Interruption.interrupt_codex_session/2
        }
    }

    {fixture, consumed, state}
  end

  defp pending_consumed_replay(phase) do
    fixture = replay_fixture(reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))
    input = consume_input(fixture, armed, :crypto.strong_rand_bytes(32))
    assert {:ok, owner} = WebsocketOwnerSession.lookup(fixture.session.id)

    :sys.replace_state(owner, fn state ->
      witness =
        OwnerCleanup.capture(
          state,
          %{request_id: fixture.request.id, attempt_id: fixture.attempt.id},
          %{epoch: 1},
          0
        )

      %{
        state
        | suspended_replay: Map.put(state.suspended_replay, :cleanup_witness, witness),
          persistence: %{
            state.persistence
            | interrupt_codex_session: &Interruption.interrupt_codex_session/2,
              release_owner_lease: &SessionContinuity.release_owner_lease/4
          }
      }
    end)

    assert {:ok, consumed} = RequestReplay.consume(input)
    assert is_nil(consumed.entitlement.started_at)

    :sys.replace_state(owner, fn state ->
      suspended =
        case phase do
          :consumed_unnotified ->
            state.suspended_replay

          :committed_not_started ->
            %{
              state.suspended_replay
              | provisional_status: :committed_not_started,
                consume_binding: consumed.consume_binding
            }

          :wrong_token ->
            %{state.suspended_replay | provisional_token: :crypto.strong_rand_bytes(32)}
        end

      %{state | suspended_replay: suspended}
    end)

    {fixture, consumed, owner}
  end

  defp owner_lease(fixture) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where:
          lease.codex_session_id == ^fixture.session.id and
            lease.lease_token == ^fixture.owner_lease_token
    )
  end
end
