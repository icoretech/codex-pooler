defmodule CodexPooler.Accounting.RequestReplayTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPooler.RequestReplayFixtures

  alias CodexPooler.Accounting.{
    Attempt,
    LedgerEntry,
    RequestReplay,
    RequestReplayEntitlement
  }

  alias CodexPooler.Access

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    CodexSession,
    CodexTurn,
    SessionContinuity
  }

  alias CodexPooler.Gateway.Transports.Websocket.RemoteReconnectControlV2
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Jobs.RequestReplayCleanupWorker
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  defmodule ForgedReserveOwner do
    use GenServer

    def start_link(digest), do: GenServer.start_link(__MODULE__, digest)
    def init(digest), do: {:ok, %{digest: digest, used?: false}}

    def handle_call(
          {:consume_reserve_receipt, digest},
          _from,
          %{digest: digest, used?: false} = state
        ),
        do: {:reply, :ok, %{state | used?: true}}

    def handle_call({:consume_reserve_receipt, _digest}, _from, state),
      do: {:reply, {:error, :invalid}, state}
  end

  @tag :replay_race
  test "preflight reports none, active generation zero, armed generation one, and changed-claim conflict without writes" do
    fixture = replay_fixture()
    absent = %{fixture.preflight | semantic_turn_digest: <<9::256>>}
    assert RequestReplay.preflight_snapshot(absent) == :none

    before_counts = counts()
    assert {:active_generation_zero, active} = RequestReplay.preflight_snapshot(fixture.preflight)
    assert active.codex_turn_id == fixture.turn.id
    assert active.request_id == fixture.request.id
    assert active.eligible_attempt_id == fixture.attempt.id
    assert active.replay_generation == 0
    assert counts() == before_counts

    entitlement = insert_entitlement!(fixture, %{status: "armed"})

    assert {:armed_generation_one, armed} = RequestReplay.preflight_snapshot(fixture.preflight)
    assert armed.entitlement_id == entitlement.id
    assert armed.replay_generation == 1

    assert {:error, :replay_claim_mismatch} =
             RequestReplay.preflight_snapshot(%{
               fixture.preflight
               | replay_claim_digest: <<8::256>>
             })

    assert counts() == Map.update!(before_counts, :entitlements, &(&1 + 1))
  end

  test "preflight rejects stale authorization and model bindings instead of treating them as fresh" do
    fixture = replay_fixture()

    assert {:error, :authorization_binding_mismatch} =
             RequestReplay.preflight_snapshot(%{fixture.preflight | api_key_runtime_epoch: 1})

    _entitlement = insert_entitlement!(fixture, %{status: "armed"})

    for changed <- [
          %{fixture.preflight | api_key_id: Ecto.UUID.generate()},
          %{fixture.preflight | api_key_runtime_epoch: 1},
          %{fixture.preflight | pool_id: Ecto.UUID.generate()},
          %{fixture.preflight | model_id: Ecto.UUID.generate()},
          %{fixture.preflight | model_identifier: "gpt-other"}
        ] do
      assert {:error, :authorization_binding_mismatch} =
               RequestReplay.preflight_snapshot(changed)
    end
  end

  test "preflight rejects stale request and attempt lifecycle behind an in-progress turn" do
    terminal_request = replay_fixture()

    terminal_request.request
    |> Ecto.Changeset.change(%{
      status: "failed",
      usage_status: "usage_unknown",
      completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      response_status_code: 499
    })
    |> Repo.update!()

    assert {:error, :lifecycle_conflict} =
             RequestReplay.preflight_snapshot(terminal_request.preflight)

    terminal_attempt = replay_fixture()

    terminal_attempt.attempt
    |> Ecto.Changeset.change(%{
      status: "failed",
      completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      usage_status: "usage_unknown"
    })
    |> Repo.update!()

    assert {:error, :lifecycle_conflict} =
             RequestReplay.preflight_snapshot(terminal_attempt.preflight)

    stale_usage = replay_fixture()

    stale_usage.attempt
    |> Ecto.Changeset.change(%{usage_status: "usage_unknown"})
    |> Repo.update!()

    assert {:error, :lifecycle_conflict} =
             RequestReplay.preflight_snapshot(stale_usage.preflight)
  end

  test "active preflight rejects generation zero when a globally newer generation-one attempt exists" do
    fixture = replay_fixture()

    newer_attempt =
      attempt_fixture(fixture.request, fixture.assignment, %{
        attempt_number: 2,
        status: "in_progress",
        completed_at: nil,
        upstream_status_code: nil,
        usage_status: "usage_pending"
      })

    newer_attempt
    |> Ecto.Changeset.change(%{replay_generation: 1})
    |> Repo.update!()

    assert {:error, :lifecycle_conflict} =
             RequestReplay.preflight_snapshot(fixture.preflight)
  end

  test "armed preflight rejects expired and incoherent durable lifecycle" do
    expired = replay_fixture()

    _entitlement =
      insert_entitlement!(expired, %{
        armed_at:
          DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond),
        expires_at:
          DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:microsecond)
      })

    assert {:error, :lifecycle_conflict} =
             RequestReplay.preflight_snapshot(expired.preflight)

    terminal_request = replay_fixture()
    _entitlement = insert_entitlement!(terminal_request, %{status: "armed"})

    terminal_request.request
    |> Ecto.Changeset.change(%{
      status: "failed",
      usage_status: "usage_unknown",
      completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      response_status_code: 499
    })
    |> Repo.update!()

    assert {:error, :lifecycle_conflict} =
             RequestReplay.preflight_snapshot(terminal_request.preflight)

    terminal_attempt = replay_fixture()
    _entitlement = insert_entitlement!(terminal_attempt, %{status: "armed"})

    terminal_attempt.attempt
    |> Ecto.Changeset.change(%{
      status: "failed",
      completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      usage_status: "usage_unknown"
    })
    |> Repo.update!()

    assert {:error, :lifecycle_conflict} =
             RequestReplay.preflight_snapshot(terminal_attempt.preflight)

    revoked = replay_fixture()

    revoked_armed_at =
      DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    revoked_at = DateTime.add(revoked_armed_at, 1, :microsecond)

    _entitlement =
      insert_entitlement!(revoked, %{
        status: "revoked",
        armed_at: revoked_armed_at,
        expires_at: DateTime.add(revoked_armed_at, 30, :second),
        terminal_at: revoked_at,
        closed_at: DateTime.add(revoked_at, 1, :microsecond)
      })

    assert {:error, :lifecycle_conflict} =
             RequestReplay.preflight_snapshot(revoked.preflight)
  end

  test "provisional binding status is closed for armed, consumed phases, terminal, absent, and mismatch" do
    fixture = replay_fixture()
    entitlement = insert_entitlement!(fixture, %{status: "armed"})
    provisional_digest = <<7::256>>
    replay_attempt = attempt_fixture(fixture.request, fixture.assignment, %{attempt_number: 2})

    reference = %{
      request_id: fixture.request.id,
      codex_turn_id: fixture.turn.id,
      eligible_attempt_id: fixture.attempt.id,
      replay_attempt_id: replay_attempt.id,
      replay_generation: 1,
      provisional_binding_digest: provisional_digest,
      owner_lease_digest: entitlement.owner_lease_digest
    }

    assert RequestReplay.provisional_binding_status(%{reference | replay_attempt_id: nil}) ==
             :armed

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    abandon_at = DateTime.add(now, 5, :second)

    consumed =
      entitlement
      |> Ecto.Changeset.change(%{
        status: "consumed",
        replay_attempt_id: replay_attempt.id,
        provisional_binding_digest: provisional_digest,
        consumed_at: now,
        abandon_at: abandon_at
      })
      |> Repo.update!()

    assert {:consumed, binding, :committed_not_started, ^abandon_at} =
             RequestReplay.provisional_binding_status(reference)

    assert binding.replay_attempt_id == replay_attempt.id

    started_at = DateTime.add(now, 1, :microsecond)

    consumed
    |> Ecto.Changeset.change(%{started_at: started_at, last_liveness_at: started_at})
    |> Repo.update!()

    assert {:consumed, _binding, :started, ^abandon_at} =
             RequestReplay.provisional_binding_status(reference)

    consumed
    |> Repo.reload!()
    |> Ecto.Changeset.change(%{closed_at: DateTime.add(abandon_at, 1, :microsecond)})
    |> Repo.update!()

    assert RequestReplay.provisional_binding_status(reference) == :terminal

    for mismatched <- [
          %{reference | codex_turn_id: Ecto.UUID.generate()},
          %{reference | eligible_attempt_id: Ecto.UUID.generate()},
          %{reference | replay_attempt_id: Ecto.UUID.generate()},
          %{reference | provisional_binding_digest: <<5::256>>},
          %{reference | owner_lease_digest: <<6::256>>}
        ] do
      assert RequestReplay.provisional_binding_status(mismatched) ==
               {:error, :binding_mismatch}
    end

    assert RequestReplay.provisional_binding_status(%{
             reference
             | request_id: Ecto.UUID.generate()
           }) == :absent

    assert RequestReplay.provisional_binding_status(%{reference | owner_lease_digest: <<6::256>>}) ==
             {:error, :binding_mismatch}
  end

  test "terminal expired and revoked rows validate exact immutable identity before terminal status" do
    for status <- ["expired", "revoked"] do
      fixture = replay_fixture()

      armed_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      expires_at = DateTime.add(armed_at, 30, :second)
      terminal_at = if status == "expired", do: expires_at, else: armed_at

      entitlement =
        insert_entitlement!(fixture, %{
          status: status,
          armed_at: armed_at,
          expires_at: expires_at,
          terminal_at: terminal_at,
          closed_at: DateTime.add(terminal_at, 1, :microsecond)
        })

      reference = %{
        request_id: fixture.request.id,
        codex_turn_id: fixture.turn.id,
        eligible_attempt_id: fixture.attempt.id,
        replay_attempt_id: nil,
        replay_generation: 1,
        provisional_binding_digest: nil,
        owner_lease_digest: entitlement.owner_lease_digest
      }

      assert RequestReplay.provisional_binding_status(reference) == :terminal

      for mismatched <- [
            %{reference | codex_turn_id: Ecto.UUID.generate()},
            %{reference | eligible_attempt_id: Ecto.UUID.generate()},
            %{reference | replay_attempt_id: Ecto.UUID.generate()},
            %{reference | provisional_binding_digest: <<7::256>>},
            %{reference | owner_lease_digest: <<8::256>>}
          ] do
        assert RequestReplay.provisional_binding_status(mismatched) ==
                 {:error, :binding_mismatch}
      end
    end
  end

  @tag :replay_lifecycle
  test "arm and consume preserve one lifecycle while creating generation one attempt N+1" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    arm = arm_input(fixture)

    assert {:ok, armed} = RequestReplay.arm(arm)
    assert armed.replay_generation == 1
    assert Repo.reload!(fixture.attempt).status == "retryable_failed"
    assert Repo.aggregate(RequestReplayEntitlement, :count) == 1
    assert Repo.aggregate(Attempt, :count) == 1
    assert Repo.aggregate(LedgerEntry, :count) == 1

    token = :crypto.strong_rand_bytes(32)
    assert {:ok, consumed} = RequestReplay.consume(consume_input(fixture, armed, token))

    assert consumed.request.id == fixture.request.id
    assert consumed.turn.id == fixture.turn.id
    assert consumed.attempt.attempt_number == fixture.attempt.attempt_number + 1
    assert consumed.attempt.replay_generation == 1

    assert consumed.attempt.pool_upstream_assignment_id ==
             fixture.attempt.pool_upstream_assignment_id

    assert consumed.entitlement.status == "consumed"
    assert consumed.entitlement.replay_attempt_id == consumed.attempt.id

    assert DateTime.diff(
             consumed.entitlement.abandon_at,
             consumed.entitlement.consumed_at,
             :millisecond
           ) == 5_000

    assert Repo.aggregate(Attempt, :count) == 2
    assert Repo.aggregate(RequestReplayEntitlement, :count) == 1
    assert Repo.aggregate(LedgerEntry, :count) == 1
  end

  @tag :replay_lifecycle
  test "consume persists each valid owner reserve timeout unchanged" do
    for reserve_timeout_ms <- [1_000, 23_417, 60_000] do
      fixture = replay_fixture(owner?: true, reservation?: true)
      assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))

      input =
        fixture
        |> consume_input(armed, :crypto.strong_rand_bytes(32), reserve_timeout_ms)

      assert {:ok, consumed} = RequestReplay.consume(input)

      assert DateTime.diff(
               consumed.entitlement.abandon_at,
               consumed.entitlement.consumed_at,
               :millisecond
             ) == reserve_timeout_ms
    end
  end

  @tag :replay_generation_race
  @tag :replay_race
  test "arm is a generation cutover and concurrent consume has one durable winner" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))
    token = :crypto.strong_rand_bytes(32)
    input = consume_input(fixture, armed, token)
    parent = self()
    release = make_ref()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          send(parent, {:consume_ready, self()})
          receive do: ({:consume, ^release} -> RequestReplay.consume(input))
        end)
      end

    pids =
      for _ <- 1..2 do
        assert_receive {:consume_ready, pid}
        Sandbox.allow(Repo, self(), pid)
        pid
      end

    Enum.each(pids, &send(&1, {:consume, release}))
    results = Enum.map(tasks, &Task.await(&1, 15_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, reason} when reason in [:already_consumed, :invalid], &1)
           ) == 1

    assert Repo.aggregate(Attempt, :count) == 2

    stale = %{id: fixture.attempt.id, request_id: fixture.request.id, replay_generation: 0}

    assert {:error, :stale_generation} =
             SessionContinuity.mark_codex_turn_visible(fixture.request, stale)

    assert Repo.reload!(fixture.turn).first_visible_output_at == nil
  end

  @tag :replay_generation_race
  @tag :replay_race
  test "receipt redemption fences reconciliation until DB consume commits" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))
    input = consume_input(fixture, armed, :crypto.strong_rand_bytes(32))
    {:ok, owner} = WebsocketOwnerSession.lookup(fixture.session.id)
    barrier_ref = make_ref()

    Application.put_env(
      :codex_pooler,
      :request_replay_consume_test_barrier,
      {self(), barrier_ref}
    )

    on_exit(fn ->
      Application.delete_env(:codex_pooler, :request_replay_consume_test_barrier)
    end)

    parent = self()

    consume_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        RequestReplay.consume(input)
      end)

    assert_receive {:request_replay_owner_reserve_redeemed, consume_pid, ^barrier_ref}
    assert consume_pid == consume_task.pid

    %{suspended_replay: redeemed} = :sys.get_state(owner)
    assert redeemed.provisional_status == :consume_reserved
    assert redeemed.reserve_receipt_used?
    assert redeemed.consume_pid == consume_pid
    assert is_reference(redeemed.consume_monitor)

    send(owner, {:websocket_owner_replay_reconcile, redeemed.reconciliation_token})

    assert %{
             suspended_replay: %{
               provisional_status: :consume_reserved,
               reserve_receipt_used?: true,
               consume_pid: ^consume_pid
             }
           } = :sys.get_state(owner)

    assert Repo.aggregate(Attempt, :count) == 1

    assert Repo.reload!(Repo.get_by!(RequestReplayEntitlement, request_id: fixture.request.id)).status ==
             "armed"

    send(consume_pid, {:release_request_replay_consume, barrier_ref})
    assert {:ok, consumed} = Task.await(consume_task, 15_000)
    assert consumed.attempt.replay_generation == 1
    assert Repo.aggregate(Attempt, :count) == 2

    next_reconciliation_token = :sys.get_state(owner).suspended_replay.reconciliation_token
    send(owner, {:websocket_owner_replay_reconcile, next_reconciliation_token})

    assert %{
             suspended_replay: %{
               provisional_status: :committed_not_started,
               consume_binding: consume_binding
             }
           } = :sys.get_state(owner)

    assert consume_binding == consumed.consume_binding

    cancelled_fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, cancelled_armed} = RequestReplay.arm(arm_input(cancelled_fixture))

    cancelled_input =
      consume_input(cancelled_fixture, cancelled_armed, :crypto.strong_rand_bytes(32))

    {:ok, cancelled_owner} = WebsocketOwnerSession.lookup(cancelled_fixture.session.id)

    cancelled_barrier_ref = make_ref()

    Application.put_env(
      :codex_pooler,
      :request_replay_consume_test_barrier,
      {self(), cancelled_barrier_ref}
    )

    cancelled_consumer =
      spawn(fn ->
        Sandbox.allow(Repo, parent, self())
        send(parent, {:cancelled_consume_result, RequestReplay.consume(cancelled_input)})
      end)

    cancelled_consumer_monitor = Process.monitor(cancelled_consumer)

    assert_receive {:request_replay_owner_reserve_redeemed, ^cancelled_consumer,
                    ^cancelled_barrier_ref}

    %{suspended_replay: cancelled_redeemed} = :sys.get_state(cancelled_owner)
    consume_monitor = cancelled_redeemed.consume_monitor
    Process.exit(cancelled_consumer, :kill)

    assert_receive {:DOWN, ^cancelled_consumer_monitor, :process, ^cancelled_consumer, :killed}
    send(cancelled_owner, {:DOWN, consume_monitor, :process, cancelled_consumer, :killed})

    assert %{suspended_replay: nil} = :sys.get_state(cancelled_owner)
    refute_received {:cancelled_consume_result, _result}

    assert Repo.aggregate(
             from(attempt in Attempt,
               where: attempt.request_id == ^cancelled_fixture.request.id
             ),
             :count
           ) == 1
  end

  @tag :replay_matrix
  @tag :replay_race
  test "durable consume reconciles after owner commit races the blocked transaction" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))
    input = consume_input(fixture, armed, :crypto.strong_rand_bytes(32))
    {:ok, owner} = WebsocketOwnerSession.lookup(fixture.session.id)
    barrier_ref = make_ref()

    Application.put_env(
      :codex_pooler,
      :request_replay_consume_test_barrier,
      {self(), barrier_ref}
    )

    on_exit(fn ->
      Application.delete_env(:codex_pooler, :request_replay_consume_test_barrier)
    end)

    parent = self()

    consume_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        RequestReplay.consume(input)
      end)

    assert_receive {:request_replay_owner_reserve_redeemed, consume_pid, ^barrier_ref}
    assert consume_pid == consume_task.pid

    %{suspended_replay: reserved} = :sys.get_state(owner)
    assert reserved.provisional_status == :consume_reserved
    assert reserved.reserve_receipt_used?
    assert reserved.consume_pid == consume_pid

    invalid_binding = %{
      request_id: fixture.request.id,
      codex_turn_id: fixture.turn.id,
      eligible_attempt_id: fixture.attempt.id,
      replay_attempt_id: Ecto.UUID.generate(),
      replay_generation: 1,
      provisional_binding_digest: :crypto.strong_rand_bytes(32),
      owner_lease_digest: armed.owner_lease_digest
    }

    {:ok, failed_commit} =
      RemoteReconnectControlV2.new(%{
        version: 2,
        action: :provisional_commit,
        intent: :suspended_replay,
        codex_session_id: fixture.session.id,
        downstream: reserved.downstream,
        semantic_turn_digest: fixture.semantic_digest,
        replay_claim_digest: fixture.replay_claim_digest,
        provisional_token: input.provisional_token,
        replay_generation: 1,
        owner_lease_token: fixture.owner_lease_token,
        control_ref: make_ref(),
        authorization_binding: nil,
        consume_binding: invalid_binding
      })

    assert {:error, :owner_busy} =
             WebsocketOwnerSession.reconnect_control_v2(owner, failed_commit)

    assert %{suspended_replay: %{provisional_status: :consume_reserved}} =
             :sys.get_state(owner)

    assert request_attempt_count(fixture.request.id) == 1
    assert terminal_ledger_count(fixture.request.id, "settlement") == 0
    assert terminal_ledger_count(fixture.request.id, "release") == 0

    send(consume_pid, {:release_request_replay_consume, barrier_ref})
    assert {:ok, consumed} = Task.await(consume_task, 15_000)
    assert consumed.attempt.replay_generation == 1

    reconciliation_token = :sys.get_state(owner).suspended_replay.reconciliation_token
    send(owner, {:websocket_owner_replay_reconcile, reconciliation_token})

    assert %{
             suspended_replay: %{
               provisional_status: :committed_not_started,
               consume_binding: consume_binding,
               consume_pid: nil,
               consume_monitor: nil,
               consume_fence: nil,
               reconciliation_token: nil,
               reconciliation_timer_ref: nil
             }
           } = :sys.get_state(owner)

    assert consume_binding == consumed.consume_binding

    assert {:ok, _started} = RequestReplay.mark_started(consumed.consume_binding)

    {:ok, successful_commit} =
      RemoteReconnectControlV2.new(%{
        Map.from_struct(failed_commit)
        | consume_binding: consumed.consume_binding
      })

    assert {:ok, :started, ^consume_binding} =
             WebsocketOwnerSession.reconnect_control_v2(owner, successful_commit)

    assert %{suspended_replay: %{provisional_status: :started}} = :sys.get_state(owner)

    assert request_attempt_count(fixture.request.id) == 2
    assert Repo.reload!(fixture.request).status == "in_progress"
    assert Repo.reload!(fixture.turn).status == "in_progress"
    assert Repo.reload!(consumed.entitlement).status == "consumed"
    assert terminal_ledger_count(fixture.request.id, "settlement") == 0
    assert terminal_ledger_count(fixture.request.id, "release") == 0
    assert Agent.get(:sys.get_state(owner).upstream_pid, & &1) == 0
  end

  @tag :replay_generation_race
  @tag :replay_race
  test "late upstream visibility from generation zero cannot cross the armed cutover" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, _armed} = RequestReplay.arm(arm_input(fixture))

    assert {:error, :stale_generation} =
             SessionContinuity.mark_codex_turn_visible(
               fixture.request,
               fixture.attempt
             )

    assert Repo.reload!(fixture.turn).first_visible_output_at == nil
  end

  @tag :replay_lifecycle
  @tag :replay_race
  test "ineligible and reused lifecycle paths create no extra work" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    counts = counts()

    fixture.turn
    |> Ecto.Changeset.change(%{
      first_visible_output_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()

    assert {:error, :ineligible} = RequestReplay.arm(arm_input(fixture))

    assert counts() == counts

    fixture.turn
    |> Repo.reload!()
    |> Ecto.Changeset.change(%{first_visible_output_at: nil})
    |> Repo.update!()

    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))
    assert {:error, :already_armed} = RequestReplay.arm(arm_input(fixture))
    token = :crypto.strong_rand_bytes(32)
    assert {:ok, _} = RequestReplay.consume(consume_input(fixture, armed, token))
    after_consume = counts()

    assert {:error, :already_consumed} =
             RequestReplay.consume(consume_input(fixture, armed, token))

    assert counts() == after_consume
    assert {:error, :already_armed} = RequestReplay.arm(arm_input(fixture))
    assert counts() == after_consume
    assert request_attempt_count(fixture.request.id) == 2
  end

  @tag :replay_lifecycle
  test "generation one finalization closes entitlement with one settlement and release" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))
    token = :crypto.strong_rand_bytes(32)
    assert {:ok, consumed} = RequestReplay.consume(consume_input(fixture, armed, token))
    assert {:ok, _started} = RequestReplay.mark_started(consumed.consume_binding)

    assert {:ok, finalized} =
             CodexPooler.Accounting.finalize_success_with_disposition(
               consumed.request,
               consumed.attempt,
               %{
                 status: "usage_known",
                 input_tokens: 3,
                 output_tokens: 2,
                 total_tokens: 5,
                 recorded_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
               },
               %{}
             )

    assert finalized.finalization_disposition == :inserted
    entitlement = Repo.reload!(consumed.entitlement)
    assert entitlement.status == "consumed"
    assert entitlement.closed_at
    request_id = fixture.request.id

    assert Repo.aggregate(
             from(row in LedgerEntry,
               where: row.request_id == ^request_id and row.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(row in LedgerEntry,
               where: row.request_id == ^request_id and row.entry_kind == "release"
             ),
             :count
           ) == 1
  end

  @tag :replay_cleanup
  @tag :replay_race
  @tag :replay_clock
  @tag :replay_lock_order
  test "expired armed replay closes attempt N exactly once without fabricating N+1" do
    fixture = replay_fixture(owner?: true, reservation?: true)

    expired_at =
      DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    insert_entitlement!(fixture, %{
      armed_at: DateTime.add(expired_at, -30, :second),
      expires_at: expired_at
    })

    assert {:ok, %{replay_entitlements_closed: 1, replay_entitlements_noop: 0}} =
             RequestReplay.cleanup_due()

    assert {:ok, :noop} = RequestReplay.close(fixture.request.id, :expired)

    entitlement = Repo.get_by!(RequestReplayEntitlement, request_id: fixture.request.id)
    request = Repo.reload!(fixture.request)
    attempt = Repo.reload!(fixture.attempt)
    turn = Repo.reload!(fixture.turn)

    assert entitlement.status == "expired"
    assert DateTime.diff(entitlement.closed_at, entitlement.terminal_at, :microsecond) == 1
    assert request.status == "failed"
    assert request.last_error_code == "websocket_replay_expired"
    assert request.response_status_code == 499
    assert attempt.status == "retryable_failed"
    assert attempt.retryable
    assert attempt.network_error_code == "client_disconnected"
    assert turn.status == "failed"
    assert turn.error_code == "websocket_replay_expired"
    assert turn.final_attempt_id == attempt.id
    assert request_attempt_count(request.id) == 1
    assert terminal_ledger_count(request.id, "settlement") == 1
    assert terminal_ledger_count(request.id, "release") == 1
  end

  @tag :replay_cleanup
  @tag :replay_lock_order
  test "owner shutdown closes armed and consumed replay lifecycles before lease release" do
    armed_fixture = replay_fixture(owner?: true, reservation?: true)
    {armed_owner, _armed} = start_suspended_replay_owner(armed_fixture)

    armed_owner_ref = Process.monitor(armed_owner)
    assert :ok = GenServer.stop(armed_owner, :normal, 15_000)
    assert_receive {:DOWN, ^armed_owner_ref, :process, ^armed_owner, :normal}, 15_000

    assert {:ok, %{closed: 0, noop: 0}} =
             RequestReplay.close_for_session(
               armed_fixture.session.id,
               armed_fixture.owner_lease_token,
               :owner_shutdown
             )

    armed_entitlement =
      Repo.get_by!(RequestReplayEntitlement, request_id: armed_fixture.request.id)

    assert armed_entitlement.status == "revoked"
    assert Repo.reload!(armed_fixture.attempt).status == "retryable_failed"
    assert Repo.reload!(armed_fixture.attempt).retryable
    assert request_attempt_count(armed_fixture.request.id) == 1
    assert terminal_ledger_count(armed_fixture.request.id, "settlement") == 1
    assert terminal_ledger_count(armed_fixture.request.id, "release") == 1
    assert rollup_request_count(armed_fixture.request) == 1

    assert Repo.one!(
             from lease in BridgeOwnerLease,
               where: lease.codex_session_id == ^armed_fixture.session.id,
               select: lease.status
           ) == "released"

    consumed_fixture = replay_fixture(owner?: true, reservation?: true)
    {consumed_owner, consumed_arm} = start_suspended_replay_owner(consumed_fixture)

    assert {:ok, consumed} =
             RequestReplay.consume(
               suspended_consume_input(consumed_fixture, consumed_owner, consumed_arm)
             )

    stop_replay_owner(consumed_fixture.session.id)

    assert Repo.reload!(consumed.attempt).network_error_code ==
             "websocket_replay_owner_unavailable"

    assert request_attempt_count(consumed_fixture.request.id) == 2
    assert terminal_ledger_count(consumed_fixture.request.id, "settlement") == 1
    assert terminal_ledger_count(consumed_fixture.request.id, "release") == 1
    assert rollup_request_count(consumed_fixture.request) == 1
  end

  @tag :replay_api_key_delete
  @tag :replay_race
  @tag :replay_lock_order
  test "API key deletion closes armed replay before cascading its graph" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, _armed} = RequestReplay.arm(arm_input(fixture))

    assert {:ok, deleted} = Access.delete_api_key(fixture.scope, fixture.api_key)
    assert deleted.id == fixture.api_key.id
    assert Repo.get(CodexPooler.Access.APIKey, fixture.api_key.id) == nil
    assert Repo.get(CodexPooler.Accounting.Request, fixture.request.id) == nil
    assert Repo.get_by(RequestReplayEntitlement, request_id: fixture.request.id) == nil

    assert Repo.aggregate(
             from(row in Attempt, where: row.request_id == ^fixture.request.id),
             :count
           ) == 0

    assert Repo.aggregate(
             from(row in LedgerEntry, where: row.request_id == ^fixture.request.id),
             :count
           ) == 0
  end

  @tag :replay_api_key_delete
  @tag :replay_lock_order
  @tag :replay_race
  test "API key deletion and replay consume converge in both commit orders" do
    delete_first = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, delete_first_arm} = RequestReplay.arm(arm_input(delete_first))

    delete_first_input =
      consume_input(
        delete_first,
        delete_first_arm,
        :crypto.strong_rand_bytes(32)
      )

    consume_barrier = make_ref()

    Application.put_env(
      :codex_pooler,
      :request_replay_consume_test_barrier,
      {self(), consume_barrier}
    )

    on_exit(fn ->
      Application.delete_env(:codex_pooler, :request_replay_consume_test_barrier)
      Application.delete_env(:codex_pooler, :api_key_delete_test_barrier)
    end)

    parent = self()

    consume_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        RequestReplay.consume(delete_first_input)
      end)

    assert_receive {:request_replay_owner_reserve_redeemed, consume_pid, ^consume_barrier}

    delete_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        Access.delete_api_key(delete_first.scope, delete_first.api_key)
      end)

    assert {:ok, _deleted} = Task.await(delete_task, 15_000)
    send(consume_pid, {:release_request_replay_consume, consume_barrier})
    assert {:error, consume_error} = Task.await(consume_task, 15_000)
    assert consume_error in [:ineligible, :owner_unavailable]
    assert {:error, :ineligible} = RequestReplay.arm(arm_input(delete_first))
    assert Repo.get(CodexPooler.Access.APIKey, delete_first.api_key.id) == nil
    assert Repo.get(CodexPooler.Accounting.Request, delete_first.request.id) == nil

    assert Repo.aggregate(
             from(row in Attempt, where: row.request_id == ^delete_first.request.id),
             :count
           ) == 0

    Application.delete_env(:codex_pooler, :request_replay_consume_test_barrier)

    consume_first = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, consume_first_arm} = RequestReplay.arm(arm_input(consume_first))

    consume_first_input =
      consume_input(
        consume_first,
        consume_first_arm,
        :crypto.strong_rand_bytes(32)
      )

    delete_barrier = make_ref()

    Application.put_env(:codex_pooler, :api_key_delete_test_barrier, %{
      test_pid: parent,
      ref: delete_barrier,
      block_attempts_left: [3]
    })

    consume_first_delete =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        Access.delete_api_key(consume_first.scope, consume_first.api_key)
      end)

    assert_receive {:api_key_delete_session_snapshot, ^delete_barrier, delete_pid, 3, session_ids}
    assert session_ids == [consume_first.session.id]
    assert {:ok, consumed} = RequestReplay.consume(consume_first_input)
    assert consumed.attempt.replay_generation == 1
    send(delete_pid, {:release_api_key_delete_snapshot, delete_barrier})
    assert {:ok, _deleted} = Task.await(consume_first_delete, 15_000)
    assert {:error, :ineligible} = RequestReplay.dispatch_lifecycle(consumed.consume_binding)
    assert Repo.get(CodexPooler.Access.APIKey, consume_first.api_key.id) == nil
    assert Repo.get(CodexPooler.Accounting.Request, consume_first.request.id) == nil
    assert Repo.get_by(RequestReplayEntitlement, request_id: consume_first.request.id) == nil
  end

  @tag :replay_cleanup
  @tag :replay_race
  @tag :replay_lock_order
  test "pause revoke and cleanup races settle armed replay exactly once" do
    for mutation <- [:pause, :revoke] do
      fixture = replay_fixture(owner?: true, reservation?: true)
      assert {:ok, _armed} = RequestReplay.arm(arm_input(fixture))
      parent = self()
      gate = make_ref()

      mutation_task =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          send(parent, {:replay_cleanup_racer_ready, self(), gate})

          receive do
            {:run_replay_cleanup_racer, ^gate} ->
              case mutation do
                :pause -> Access.pause_api_key(fixture.scope, fixture.api_key)
                :revoke -> Access.revoke_api_key(fixture.scope, fixture.api_key)
              end
          end
        end)

      cleanup_task =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          send(parent, {:replay_cleanup_racer_ready, self(), gate})

          receive do
            {:run_replay_cleanup_racer, ^gate} -> RequestReplay.cleanup_due()
          end
        end)

      racers =
        for _ <- 1..2 do
          assert_receive {:replay_cleanup_racer_ready, racer, ^gate}
          racer
        end

      Enum.each(racers, &send(&1, {:run_replay_cleanup_racer, gate}))
      assert {:ok, _api_key} = Task.await(mutation_task, 15_000)
      assert {:ok, _summary} = Task.await(cleanup_task, 15_000)
      assert {:ok, _summary} = RequestReplay.cleanup_due()

      assert Repo.get_by!(RequestReplayEntitlement, request_id: fixture.request.id).status ==
               "revoked"

      assert terminal_ledger_count(fixture.request.id, "settlement") == 1
      assert terminal_ledger_count(fixture.request.id, "release") == 1
      assert rollup_request_count(fixture.request) == 1
    end
  end

  @tag :replay_cleanup
  @tag :replay_race
  @tag :replay_lock_order
  test "runtime cleanup worker and owner lease release race is idempotent" do
    fixture = replay_fixture(owner?: true, reservation?: true)

    expired_at =
      DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    insert_entitlement!(fixture, %{
      armed_at: DateTime.add(expired_at, -30, :second),
      expires_at: expired_at
    })

    parent = self()
    gate = make_ref()

    worker =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        send(parent, {:replay_cleanup_racer_ready, self(), gate})

        receive do
          {:run_replay_cleanup_racer, ^gate} ->
            perform_job(RequestReplayCleanupWorker, %{})
        end
      end)

    releaser =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        send(parent, {:replay_cleanup_racer_ready, self(), gate})

        receive do
          {:run_replay_cleanup_racer, ^gate} ->
            SessionContinuity.release_owner_lease(
              fixture.session,
              fixture.owner_lease_token,
              "owner_unavailable"
            )
        end
      end)

    racers =
      for _ <- 1..2 do
        assert_receive {:replay_cleanup_racer_ready, racer, ^gate}
        racer
      end

    Enum.each(racers, &send(&1, {:run_replay_cleanup_racer, gate}))
    assert :ok = Task.await(worker, 15_000)
    assert :ok = Task.await(releaser, 15_000)
    assert :ok = perform_job(RequestReplayCleanupWorker, %{})
    assert terminal_ledger_count(fixture.request.id, "settlement") == 1
    assert terminal_ledger_count(fixture.request.id, "release") == 1
    assert rollup_request_count(fixture.request) == 1
  end

  @tag :replay_cleanup
  test "revoked armed replay preserves attempt N and uses the revocation terminal code" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, _armed} = RequestReplay.arm(arm_input(fixture))

    fixture.api_key
    |> Ecto.Changeset.change(%{status: "paused"})
    |> Repo.update!()

    assert {:ok, :closed} = RequestReplay.close(fixture.request.id, :revoked)

    assert Repo.get_by!(RequestReplayEntitlement, request_id: fixture.request.id).status ==
             "revoked"

    assert Repo.reload!(fixture.request).last_error_code == "websocket_replay_revoked"
    assert Repo.reload!(fixture.turn).final_attempt_id == fixture.attempt.id
    assert request_attempt_count(fixture.request.id) == 1
  end

  @tag :replay_cleanup
  @tag :replay_liveness
  test "consumed replay abandonment settles N+1 once and current touch postpones cleanup" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))

    assert {:ok, consumed} =
             RequestReplay.consume(consume_input(fixture, armed, :crypto.strong_rand_bytes(32)))

    assert {:ok, _started} = RequestReplay.mark_started(consumed.consume_binding)
    assert {:ok, touched} = RequestReplay.touch_liveness(consumed.consume_binding)
    assert DateTime.compare(touched.abandon_at, DateTime.utc_now()) == :gt
    assert {:ok, :noop} = RequestReplay.close(fixture.request.id, :abandoned)

    abandoned = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, abandoned_arm} = RequestReplay.arm(arm_input(abandoned))

    assert {:ok, abandoned_consume} =
             RequestReplay.consume(
               consume_input(abandoned, abandoned_arm, :crypto.strong_rand_bytes(32))
             )

    assert {:ok, _closed} = RequestReplay.compensate_no_send(abandoned_consume.consume_binding)
    assert {:ok, :noop} = RequestReplay.close(abandoned.request.id, :owner_unavailable)

    request = Repo.reload!(abandoned.request)
    attempt = Repo.reload!(abandoned_consume.attempt)
    turn = Repo.reload!(abandoned.turn)
    assert request.last_error_code == "websocket_replay_abandoned"
    assert attempt.status == "failed"
    refute attempt.retryable
    assert attempt.network_error_code == "websocket_replay_abandoned"
    assert turn.final_attempt_id == attempt.id
    assert request_attempt_count(request.id) == 2
    assert terminal_ledger_count(request.id, "settlement") == 1
    assert terminal_ledger_count(request.id, "release") == 1
  end

  @tag :replay_liveness
  @tag :replay_cleanup
  test "periodic owner heartbeat advances replay liveness and survives cleanup" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))

    assert {:ok, consumed} =
             RequestReplay.consume(consume_input(fixture, armed, :crypto.strong_rand_bytes(32)))

    assert {:ok, started} = RequestReplay.mark_started(consumed.consume_binding)
    {:ok, owner} = WebsocketOwnerSession.lookup(fixture.session.id)
    reconciliation_token = :sys.get_state(owner).suspended_replay.reconciliation_token
    send(owner, {:websocket_owner_replay_reconcile, reconciliation_token})

    assert %{suspended_replay: %{provisional_status: :started}} = :sys.get_state(owner)

    stale_liveness_at = started.last_liveness_at
    stale_abandon_at = DateTime.add(started.abandon_at, -1, :second)

    Repo.update_all(
      from(row in RequestReplayEntitlement, where: row.id == ^started.id),
      set: [abandon_at: stale_abandon_at]
    )

    send(owner, :renew_owner_lease)
    _state = :sys.get_state(owner)
    touched = Repo.reload!(started)

    assert DateTime.compare(touched.last_liveness_at, stale_liveness_at) != :lt
    assert DateTime.compare(touched.abandon_at, stale_abandon_at) == :gt
    assert {:ok, %{replay_entitlements_closed: 0}} = RequestReplay.cleanup_due()
    assert Repo.reload!(fixture.request).status == "in_progress"
    assert terminal_ledger_count(fixture.request.id, "settlement") == 0
  end

  @tag :replay_race
  @tag :replay_cleanup
  @tag :replay_liveness
  @tag :replay_clock
  test "healthy started generation one survives original claim expiry until its owner witness is stale" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    base_time = DateTime.add(fixture.session.owner_lease_expires_at, -10, :second)
    set_replay_db_now!(base_time)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))

    consume_time = DateTime.add(base_time, 1, :second)
    set_replay_db_now!(consume_time)

    assert {:ok, consumed} =
             RequestReplay.consume(consume_input(fixture, armed, :crypto.strong_rand_bytes(32)))

    start_time = DateTime.add(base_time, 2, :second)
    set_replay_db_now!(start_time)
    assert {:ok, started} = RequestReplay.mark_started(consumed.consume_binding)
    assert started.started_at == start_time
    assert started.last_liveness_at == start_time

    live_until = DateTime.add(start_time, 2, :hour)

    Repo.update_all(
      from(row in CodexSession, where: row.id == ^fixture.session.id),
      set: [owner_lease_expires_at: live_until, last_heartbeat_at: start_time]
    )

    Repo.update_all(
      from(row in BridgeOwnerLease,
        where: row.codex_session_id == ^fixture.session.id and row.status == "active"
      ),
      set: [renewed_at: start_time, expires_at: live_until]
    )

    past_original_expiry = DateTime.add(armed.expires_at, 1, :second)
    assert DateTime.compare(past_original_expiry, started.abandon_at) == :lt
    set_replay_db_now!(past_original_expiry)

    assert {:ok, touched} = RequestReplay.touch_liveness(consumed.consume_binding)
    assert touched.last_liveness_at == past_original_expiry

    assert {:ok, %{replay_entitlements_closed: 0, replay_entitlements_noop: 0}} =
             RequestReplay.cleanup_due()

    assert Repo.reload!(fixture.request).status == "in_progress"
    assert Repo.reload!(consumed.attempt).status == "in_progress"
    assert request_attempt_count(fixture.request.id) == 2
    assert terminal_ledger_count(fixture.request.id, "settlement") == 0
    assert terminal_ledger_count(fixture.request.id, "release") == 0

    {:ok, owner} = WebsocketOwnerSession.lookup(fixture.session.id)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 15_000

    stale_time = DateTime.add(touched.abandon_at, 1, :microsecond)
    set_replay_db_now!(stale_time)

    Repo.update_all(
      from(row in CodexSession, where: row.id == ^fixture.session.id),
      set: [owner_lease_expires_at: stale_time]
    )

    Repo.update_all(
      from(row in BridgeOwnerLease,
        where: row.codex_session_id == ^fixture.session.id and row.status == "active"
      ),
      set: [expires_at: stale_time]
    )

    assert {:error, :binding_mismatch} =
             RequestReplay.touch_liveness(consumed.consume_binding)

    assert {:ok, %{replay_entitlements_closed: 1, replay_entitlements_noop: 0}} =
             RequestReplay.cleanup_due()

    assert {:ok, %{replay_entitlements_closed: 0, replay_entitlements_noop: 0}} =
             RequestReplay.cleanup_due()

    entitlement = Repo.reload!(consumed.entitlement)
    replay_attempt = Repo.reload!(consumed.attempt)
    request = Repo.reload!(fixture.request)
    turn = Repo.reload!(fixture.turn)

    assert entitlement.status == "consumed"
    assert entitlement.last_liveness_at == past_original_expiry
    assert entitlement.closed_at == stale_time
    assert request.status == "failed"
    assert request.last_error_code == "websocket_replay_owner_unavailable"
    assert replay_attempt.replay_generation == 1
    assert replay_attempt.status == "failed"
    assert replay_attempt.network_error_code == "websocket_replay_owner_unavailable"
    assert turn.final_attempt_id == replay_attempt.id
    assert request_attempt_count(request.id) == 2
    assert terminal_ledger_count(request.id, "settlement") == 1
    assert terminal_ledger_count(request.id, "release") == 1
  end

  @tag :replay_cleanup
  @tag :replay_liveness
  test "failed owner probe closes an overdue heartbeat despite a live durable lease" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))

    assert {:ok, consumed} =
             RequestReplay.consume(consume_input(fixture, armed, :crypto.strong_rand_bytes(32)))

    assert {:ok, started} = RequestReplay.mark_started(consumed.consume_binding)
    {:ok, owner} = WebsocketOwnerSession.lookup(fixture.session.id)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 15_000

    witness_now = DateTime.add(started.abandon_at, 1, :microsecond)
    live_until = DateTime.add(witness_now, 60, :second)

    set_replay_db_now!(witness_now)

    Repo.update_all(
      from(row in CodexSession, where: row.id == ^fixture.session.id),
      set: [owner_lease_expires_at: live_until]
    )

    Repo.update_all(
      from(row in BridgeOwnerLease,
        where: row.codex_session_id == ^fixture.session.id and row.status == "active"
      ),
      set: [expires_at: live_until]
    )

    assert {:ok, %{replay_entitlements_closed: 1, replay_entitlements_noop: 0}} =
             RequestReplay.cleanup_due()

    assert Repo.reload!(fixture.request).status == "failed"
    assert Repo.reload!(started).closed_at
    assert {:ok, %{replay_entitlements_closed: 0}} = RequestReplay.cleanup_due()

    assert Repo.reload!(consumed.attempt).network_error_code ==
             "websocket_replay_owner_unavailable"

    assert Repo.reload!(fixture.turn).final_attempt_id == consumed.attempt.id
    assert terminal_ledger_count(fixture.request.id, "settlement") == 1
    assert terminal_ledger_count(fixture.request.id, "release") == 1
  end

  @tag :replay_liveness
  test "stale generation epoch and owner liveness touches are no-ops" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))

    assert {:ok, consumed} =
             RequestReplay.consume(consume_input(fixture, armed, :crypto.strong_rand_bytes(32)))

    assert {:ok, started} = RequestReplay.mark_started(consumed.consume_binding)

    for stale <- [
          %{consumed.consume_binding | replay_generation: 0},
          %{consumed.consume_binding | replay_attempt_id: fixture.attempt.id},
          %{consumed.consume_binding | owner_lease_digest: <<9::256>>}
        ] do
      assert {:error, :binding_mismatch} = RequestReplay.touch_liveness(stale)
      assert Repo.reload!(started).last_liveness_at == started.last_liveness_at
    end
  end

  @tag :replay_cleanup
  @tag :replay_liveness
  test "expired owner lease prevents liveness touch and due started replay closes N+1" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))

    assert {:ok, consumed} =
             RequestReplay.consume(consume_input(fixture, armed, :crypto.strong_rand_bytes(32)))

    assert {:ok, _started} = RequestReplay.mark_started(consumed.consume_binding)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(row in CodexSession, where: row.id == ^fixture.session.id),
      set: [owner_lease_expires_at: DateTime.add(now, -1, :second)]
    )

    Repo.update_all(
      from(row in BridgeOwnerLease,
        where: row.codex_session_id == ^fixture.session.id and row.status == "active"
      ),
      set: [expires_at: DateTime.add(now, -1, :second)]
    )

    assert {:error, :binding_mismatch} =
             RequestReplay.touch_liveness(consumed.consume_binding)

    assert {:ok, :closed} =
             RequestReplay.close(
               fixture.request.id,
               :owner_unavailable,
               DateTime.add(Repo.reload!(consumed.entitlement).abandon_at, 1, :microsecond)
             )

    assert Repo.reload!(consumed.attempt).network_error_code ==
             "websocket_replay_owner_unavailable"

    assert Repo.reload!(fixture.turn).final_attempt_id == consumed.attempt.id
    assert terminal_ledger_count(fixture.request.id, "settlement") == 1
    assert terminal_ledger_count(fixture.request.id, "release") == 1
  end

  @tag :replay_cleanup
  @tag :replay_clock
  test "generic stale recovery leaves replay cleanup to its dedicated sweep" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, _armed} = RequestReplay.arm(arm_input(fixture))
    stale_now = DateTime.add(fixture.request.admitted_at, 7, :hour)

    assert {:ok, summary} =
             CodexPooler.Accounting.recover_stale_reservations(stale_now,
               stale_after_seconds: 6 * 60 * 60
             )

    assert summary.stale_reservations_settled == 0
    assert Repo.reload!(fixture.request).status == "in_progress"

    expired_fixture = replay_fixture(owner?: true, reservation?: true)

    expired_at =
      DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    insert_entitlement!(expired_fixture, %{
      armed_at: DateTime.add(expired_at, -30, :second),
      expires_at: expired_at
    })

    assert {:ok, repeat_summary} =
             CodexPooler.Accounting.recover_stale_reservations(stale_now,
               stale_after_seconds: 6 * 60 * 60
             )

    assert repeat_summary.stale_reservations_settled == 0
    assert Repo.reload!(expired_fixture.request).status == "in_progress"
    assert {:ok, %{replay_entitlements_closed: 1}} = RequestReplay.cleanup_due()
    assert Repo.reload!(expired_fixture.request).last_error_code == "websocket_replay_expired"
    assert terminal_ledger_count(expired_fixture.request.id, "settlement") == 1
    assert terminal_ledger_count(expired_fixture.request.id, "release") == 1
  end

  @tag :replay_lifecycle
  test "mark started replaces the consume deadline from DB now with post-start liveness grace" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))
    token = :crypto.strong_rand_bytes(32)

    input = consume_input(fixture, armed, token, 375)

    assert {:ok, consumed} = RequestReplay.consume(input)
    consume_deadline = consumed.entitlement.abandon_at

    assert {:ok, started} = RequestReplay.mark_started(consumed.consume_binding)
    assert started.started_at == started.last_liveness_at

    assert DateTime.diff(started.abandon_at, started.started_at, :millisecond) == 1_800_000
    assert DateTime.compare(started.abandon_at, consume_deadline) == :gt
  end

  @tag :replay_lifecycle
  test "mark started rejects a replay attempt that is no longer latest in-progress generation one" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))

    assert {:ok, consumed} =
             RequestReplay.consume(consume_input(fixture, armed, :crypto.strong_rand_bytes(32)))

    consumed.attempt
    |> Ecto.Changeset.change(%{status: "failed", completed_at: DateTime.utc_now()})
    |> Repo.update!()

    assert {:error, :binding_mismatch} = RequestReplay.mark_started(consumed.consume_binding)
    assert Repo.reload!(consumed.entitlement).started_at == nil
    assert {:ok, _closed} = RequestReplay.compensate_no_send(consumed.consume_binding)
  end

  @tag :replay_generation_race
  @tag :replay_race
  test "late generation zero finalization is a typed no-op after arm" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, _armed} = RequestReplay.arm(arm_input(fixture))

    assert {:ok, stale} =
             CodexPooler.Accounting.finalize_failure_with_disposition(
               fixture.request,
               fixture.attempt,
               %{last_error_code: "late_generation_zero"}
             )

    assert stale.stale_generation?
    assert stale.finalization_disposition == :reused
    assert Repo.reload!(fixture.request).status == "in_progress"
    assert Repo.reload!(fixture.turn).status == "in_progress"
    assert Repo.aggregate(LedgerEntry, :count) == 1
  end

  @tag :replay_generation_race
  @tag :replay_race
  test "arm cutover atomically fences stale generation zero turn completion and visibility" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, _armed} = RequestReplay.arm(arm_input(fixture))

    stale_result = {:ok, %{request: fixture.request, attempt: fixture.attempt}}

    assert ^stale_result =
             SessionContinuity.complete_codex_turn(
               stale_result,
               CodexTurn.succeeded_status(),
               nil,
               fixture.attempt
             )

    assert {:error, :stale_generation} =
             SessionContinuity.mark_codex_turn_visible(fixture.request, fixture.attempt)

    assert %{
             status: "in_progress",
             first_visible_output_at: nil,
             completed_at: nil,
             final_attempt_id: nil
           } = Repo.reload!(fixture.turn)
  end

  @tag :replay_generation_race
  @tag :replay_race
  test "terminal finalization wins before arm and arm reports terminal_won" do
    fixture = replay_fixture(owner?: true, reservation?: true)

    assert {:ok, _finalized} =
             CodexPooler.Accounting.finalize_failure_with_disposition(
               fixture.request,
               fixture.attempt,
               %{last_error_code: "terminal_first"}
             )

    assert {:error, :terminal_won} = RequestReplay.arm(arm_input(fixture))
    assert Repo.get_by(RequestReplayEntitlement, request_id: fixture.request.id) == nil
  end

  @tag :replay_generation_race
  @tag :replay_race
  test "terminal finalization and arm contention preserve the terminal settlement exactly once" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    parent = self()
    release = make_ref()

    finalizer =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        CodexPooler.Accounting.finalize_success_with_disposition(
          fixture.request,
          fixture.attempt,
          %{
            status: "usage_known",
            input_tokens: 3,
            output_tokens: 2,
            total_tokens: 5,
            recorded_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
          },
          %{
            before_finalize: fn ->
              send(parent, {:terminal_finalization_locked, self()})
              receive do: ({:release_terminal_finalization, ^release} -> :ok)
            end
          }
        )
      end)

    assert_receive {:terminal_finalization_locked, finalizer_pid}

    suspender =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        send(parent, {:replay_suspend_started, self()})
        RequestReplay.arm(arm_input(fixture))
      end)

    assert_receive {:replay_suspend_started, suspender_pid}
    send(finalizer_pid, {:release_terminal_finalization, release})

    assert {:ok, %{finalization_disposition: :inserted}} = Task.await(finalizer, 15_000)
    assert {:error, :terminal_won} = Task.await(suspender, 15_000)
    assert finalizer_pid != suspender_pid
    request_id = fixture.request.id

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request_id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request_id and entry.entry_kind == "release"
             ),
             :count
           ) == 1

    assert Repo.get_by(RequestReplayEntitlement, request_id: request_id) == nil
  end

  @tag :replay_lifecycle
  test "generic attempt creation cannot bypass armed or consumed replay entitlement" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))

    assert {:error, %{code: :request_replay_required}} =
             CodexPooler.Accounting.create_attempt(fixture.request, fixture.assignment)

    token = :crypto.strong_rand_bytes(32)
    assert {:ok, _consumed} = RequestReplay.consume(consume_input(fixture, armed, token))

    assert {:error, %{code: :request_replay_required}} =
             CodexPooler.Accounting.create_attempt(fixture.request, fixture.assignment)

    assert Repo.aggregate(Attempt, :count) == 2
  end

  @tag :replay_lifecycle
  test "consume and dispatch reject an assignment moved outside the request pool" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))

    other_pool = pool_fixture(%{created_by_user_id: fixture.pool.created_by_user_id})

    fixture.assignment
    |> Ecto.Changeset.change(%{pool_id: other_pool.id})
    |> Repo.update!()

    assert {:error, :ineligible} =
             RequestReplay.consume(consume_input(fixture, armed, :crypto.strong_rand_bytes(32)))

    assert Repo.aggregate(Attempt, :count) == 1
  end

  @tag :replay_lifecycle
  @tag :replay_race
  test "consume reauthorizes the exact assignment identity model source and API key policy" do
    cases = [
      {:disabled_assignment,
       fn fixture ->
         fixture.assignment
         |> Ecto.Changeset.change(%{status: "disabled"})
         |> Repo.update!()
       end},
      {:ineligible_assignment,
       fn fixture ->
         fixture.assignment
         |> Ecto.Changeset.change(%{eligibility_status: "ineligible"})
         |> Repo.update!()
       end},
      {:disabled_assignment_health,
       fn fixture ->
         fixture.assignment
         |> Ecto.Changeset.change(%{health_status: "disabled"})
         |> Repo.update!()
       end},
      {:disabled_identity,
       fn fixture ->
         fixture.identity
         |> Ecto.Changeset.change(%{status: "disabled"})
         |> Repo.update!()
       end},
      {:inactive_model,
       fn fixture ->
         fixture.model
         |> Ecto.Changeset.change(%{status: "stale"})
         |> Repo.update!()
       end},
      {:mismatched_model_source,
       fn fixture ->
         fixture.model
         |> Ecto.Changeset.change(%{
           metadata: %{"source_assignment_ids" => [Ecto.UUID.generate()]}
         })
         |> Repo.update!()
       end},
      {:denied_model_policy,
       fn fixture ->
         fixture.api_key
         |> Ecto.Changeset.change(%{allowed_model_identifiers: []})
         |> Repo.update!()
       end}
    ]

    for {case_name, invalidate} <- cases do
      fixture = replay_fixture(owner?: true, reservation?: true)
      assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))
      input = consume_input(fixture, armed, :crypto.strong_rand_bytes(32))
      invalidate.(fixture)

      case RequestReplay.consume(input) do
        {:error, :ineligible} -> :ok
        result -> flunk("#{case_name} unexpectedly returned #{inspect(result)}")
      end

      assert Repo.aggregate(
               from(attempt in Attempt, where: attempt.request_id == ^fixture.request.id),
               :count
             ) == 1

      assert Repo.get_by!(RequestReplayEntitlement, request_id: fixture.request.id).status ==
               "armed"
    end
  end

  @tag :replay_lifecycle
  @tag :replay_race
  test "consume rejects forged and reused reserve receipts plus unreserved tokens" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))
    token = :crypto.strong_rand_bytes(32)
    input = consume_input(fixture, armed, token)

    assert {:error, :invalid} =
             RequestReplay.consume(%{
               input
               | reserve_receipt: :crypto.strong_rand_bytes(32),
                 reserve_receipt_digest: :crypto.strong_rand_bytes(32)
             })

    unreserved_token = :crypto.strong_rand_bytes(32)

    assert {:error, :invalid} =
             RequestReplay.consume(%{
               input
               | provisional_token: unreserved_token,
                 reserve_receipt: :crypto.strong_rand_bytes(32),
                 reserve_receipt_digest: :crypto.strong_rand_bytes(32)
             })

    assert {:ok, _consumed} = RequestReplay.consume(input)
    assert {:error, :invalid} = RequestReplay.consume(input)
  end

  @tag :replay_lifecycle
  @tag :replay_race
  test "consume ignores an arbitrary accepting pid and requires the persisted live owner" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    {owner, armed} = start_suspended_replay_owner(fixture)
    input = suspended_consume_input(fixture, owner, armed)
    stop_replay_owner(fixture.session.id)
    {:ok, forged_owner} = ForgedReserveOwner.start_link(input.reserve_receipt_digest)

    assert {:error, :owner_unavailable} =
             RequestReplay.consume(Map.put(input, :reserve_owner, forged_owner))

    assert Repo.aggregate(Attempt, :count) == 1

    entitlement =
      Repo.reload!(Repo.get_by!(RequestReplayEntitlement, request_id: fixture.request.id))

    assert entitlement.status == "revoked"
    assert terminal_ledger_count(fixture.request.id, "settlement") == 1
    assert terminal_ledger_count(fixture.request.id, "release") == 1
  end

  @tag :replay_lifecycle
  @tag :replay_race
  test "consume rejects stale owner generation before creating the replay attempt" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))
    input = consume_input(fixture, armed, :crypto.strong_rand_bytes(32))

    assert {:error, :invalid} =
             RequestReplay.consume(%{
               input
               | owner_process_generation: input.owner_process_generation + 1
             })

    assert Repo.aggregate(Attempt, :count) == 1
  end

  @tag :replay_lifecycle
  @tag :replay_race
  test "consume rejects a foreign live owner before creating the replay attempt" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))
    input = consume_input(fixture, armed, :crypto.strong_rand_bytes(32))
    persisted_owner = WebsocketOwnerSession.lookup(fixture.session.id)

    foreign_session_id = Ecto.UUID.generate()

    {:ok, foreign_owner} =
      WebsocketOwnerSession.start_owner(
        codex_session_id: foreign_session_id,
        owner_lease_token: fixture.owner_lease_token,
        owner_instance_id: fixture.session.owner_instance_id,
        owner_renewal_ms: 60_000,
        upstream: replay_owner_upstream(),
        persistence: replay_owner_persistence()
      )

    on_exit(fn -> stop_replay_owner(foreign_session_id) end)
    assert is_pid(foreign_owner)
    assert {:ok, _persisted_owner} = persisted_owner

    stop_replay_owner(fixture.session.id)

    assert {:error, :owner_unavailable} = RequestReplay.consume(input)
    assert Repo.aggregate(Attempt, :count) == 1
  end

  @tag :replay_lifecycle
  test "dispatch rejects a consumed replay whose assignment no longer matches its request" do
    fixture = replay_fixture(owner?: true, reservation?: true)
    assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))

    assert {:ok, consumed} =
             RequestReplay.consume(consume_input(fixture, armed, :crypto.strong_rand_bytes(32)))

    other_pool = pool_fixture(%{created_by_user_id: fixture.pool.created_by_user_id})

    fixture.assignment
    |> Ecto.Changeset.change(%{pool_id: other_pool.id})
    |> Repo.update!()

    assert {:error, :ineligible} = RequestReplay.dispatch_lifecycle(consumed.consume_binding)
  end

  test "consumed replay still settles after API key pause or revocation" do
    for mutation <- [:pause_api_key, :revoke_api_key] do
      fixture = replay_fixture(reservation?: true)
      assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))

      assert {:ok, consumed} =
               RequestReplay.consume(consume_input(fixture, armed, :crypto.strong_rand_bytes(32)))

      assert {:ok, _key} = apply(Access, mutation, [fixture.scope, fixture.api_key])
      assert {:ok, :closed} = RequestReplay.close(fixture.request.id, :owner_shutdown)
      assert Repo.reload!(consumed.entitlement).closed_at
      assert terminal_ledger_count(fixture.request.id, "settlement") == 1
      assert terminal_ledger_count(fixture.request.id, "release") == 1
    end
  end
end
