defmodule CodexPooler.RuntimeStateCleanupTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounting.RequestLifecycle
  alias CodexPooler.Accounting.RequestReplayEntitlement
  alias CodexPooler.AccountsFixtures
  alias CodexPooler.Files
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.RuntimeCleanup
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Websocket.ResponseTask
  alias CodexPooler.Platform.ExecutionIdentity
  alias CodexPooler.TestDiagnostics
  alias CodexPooler.UnboxedFixture

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    IdempotencyKey
  }

  alias CodexPooler.Jobs
  alias CodexPooler.Platform.InstancePresence
  alias CodexPooler.Platform.InstancePresence.Identity
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  alias CodexPooler.Gateway.Persistence.SessionContinuity

  test "cleanup marks expired file metadata without touching active rows" do
    now = ~U[2026-05-03 02:30:00Z]
    expired_at = DateTime.add(now, -1, :second)
    future_at = DateTime.add(now, 3600, :second)
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    expired_file =
      file_record_fixture(pool, api_key, %{status: "uploaded", expires_at: expired_at})

    abandoned_file = file_record_fixture(pool, api_key, %{expires_at: expired_at})

    active_file =
      file_record_fixture(pool, api_key, %{expires_at: future_at})

    assert {:ok, summary} = Files.cleanup_expired(now)

    assert summary == %{abandoned_files: 1, expired_files: 1}
    assert Repo.get!(FileRecord, expired_file.id).status == "expired"
    assert Repo.get!(FileRecord, abandoned_file.id).status == "abandoned"
    assert Repo.get!(FileRecord, active_file.id).status == "pending_upload"
  end

  @tag :replay_clock
  test "cleanup expires bridge aliases owner leases and idempotency keys deterministically" do
    now = ~U[2026-05-03 02:45:00Z]
    expired_at = DateTime.add(now, -1, :second)
    future_at = DateTime.add(now, 3600, :second)
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    session = session_fixture(pool, api_key, assignment, now)

    active_lease_session =
      session_fixture(pool, api_key, assignment, DateTime.add(now, 1, :second))

    expired_alias = alias_fixture(session, pool, api_key, expired_at)
    active_alias = alias_fixture(session, pool, api_key, future_at)
    expired_lease = lease_fixture(session, pool, api_key, assignment, expired_at, now)
    active_lease = lease_fixture(active_lease_session, pool, api_key, assignment, future_at, now)
    expired_key = idempotency_key_fixture(pool, api_key, expired_at)
    active_key = idempotency_key_fixture(pool, api_key, future_at)

    assert {:ok, summary} = RuntimeCleanup.cleanup_expired_runtime_state(now)

    assert summary == %{
             expired_aliases: 1,
             expired_idempotency_keys: 1,
             expired_owner_leases: 1,
             expired_owner_sessions_recovered: 0,
             closed_retired_sessions: 0
           }

    assert Repo.get!(BridgeSessionAlias, expired_alias.id).status == "expired"
    assert Repo.get!(BridgeSessionAlias, active_alias.id).status == "active"
    assert Repo.get!(BridgeOwnerLease, expired_lease.id).status == "expired"
    assert Repo.get!(BridgeOwnerLease, active_lease.id).status == "active"
    assert Repo.get!(IdempotencyKey, expired_key.id).status == "expired"
    assert Repo.get!(IdempotencyKey, active_key.id).status == "in_progress"
  end

  @tag :replay_lock_order
  test "cleanup interrupts in-progress turns before expiring owner leases" do
    now = ~U[2026-05-03 03:15:00Z]
    expired_at = DateTime.add(now, -1, :second)
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    model = model_fixture(pool, %{exposed_model_id: "gpt-cleanup"})
    session = session_fixture(pool, api_key, assignment, expired_at)
    expired_lease = lease_fixture(session, pool, api_key, assignment, expired_at, now)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        model_id: model.id,
        requested_model: model.exposed_model_id,
        transport: "websocket",
        status: "in_progress",
        usage_status: "usage_pending",
        completed_at: nil,
        response_status_code: nil,
        request_metadata: %{"codex_session_id" => session.id}
      })

    attempt =
      attempt_fixture(request, assignment, %{
        status: "in_progress",
        completed_at: nil,
        usage_status: "usage_pending",
        response_metadata: %{}
      })

    turn = turn_fixture(session, request, attempt, now)

    request
    |> ledger_entry_fixture(%{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      entry_kind: "reservation",
      amount_status: "recorded",
      usage_status: "usage_pending",
      transport: "websocket",
      output_tokens: 8,
      total_tokens: 12,
      details: %{"source" => "test_reservation"}
    })
    |> Ecto.Changeset.change(%{source_event_id: "request:#{request.id}:reservation"})
    |> Repo.update!()

    assert {:ok, summary} = RuntimeCleanup.cleanup_expired_runtime_state(now)
    assert summary.expired_owner_sessions_recovered == 1
    assert summary.expired_owner_leases == 1

    assert %Request{
             status: "failed",
             usage_status: "usage_unknown",
             response_status_code: 499,
             last_error_code: "owner_unavailable"
           } = Repo.reload!(request)

    assert %Attempt{
             status: "failed",
             usage_status: "usage_unknown",
             network_error_code: "owner_unavailable"
           } = Repo.reload!(attempt)

    assert %CodexTurn{status: "interrupted", error_code: "owner_unavailable"} =
             Repo.reload!(turn)

    assert Repo.reload!(expired_lease).status == "expired"

    assert Enum.map(ledger_entries_for_request(request.id), & &1.entry_kind) |> Enum.sort() == [
             "release",
             "reservation",
             "settlement"
           ]
  end

  for execution_state <- [:dead, :scanner_first, :entitled, :alive, :unknown] do
    test "expired owner preserves exact #{execution_state} execution classification" do
      now = ~U[2026-05-03 03:15:00.000000Z]
      expired_at = DateTime.add(now, -1, :second)
      %{pool: pool, api_key: api_key} = active_api_key_fixture()
      %{assignment: assignment} = upstream_assignment_fixture(pool)
      model = model_fixture(pool, %{exposed_model_id: "gpt-cleanup"})
      session = session_fixture(pool, api_key, assignment, expired_at)
      expired_lease = lease_fixture(session, pool, api_key, assignment, expired_at, now)

      request =
        request_fixture(%{pool: pool, api_key: api_key}, %{
          model_id: model.id,
          requested_model: model.exposed_model_id,
          transport: "websocket",
          status: "in_progress",
          usage_status: "usage_pending",
          completed_at: nil,
          response_status_code: nil,
          request_metadata: %{"codex_session_id" => session.id}
        })

      parent = self()
      registry = Module.concat(__MODULE__, "Expired#{System.unique_integer([:positive])}")

      start_supervised!({ActivityRegistry, name: registry})

      starter =
        start_supervised!(
          {Task,
           fn ->
             {:ok, pid} =
               ResponseTask.start(
                 self(),
                 :local_owner,
                 fn _ ->
                   {:ok, attempt} = Accounting.create_attempt(request, assignment)
                   send(parent, {:execution_identity, self(), attempt})

                   receive do
                     :finish -> :ok
                   end
                 end,
                 fn _, _ -> :ok end,
                 activity_registry: registry
               )

             Process.link(pid)

             receive do
               :finish -> send(pid, :finish)
             end
           end}
        )

      assert_receive {:execution_identity, pid, attempt}, 15_000
      owner = InstancePresence.local_identity()

      session =
        session
        |> Ecto.Changeset.change(
          owner_instance_id: owner.node_name,
          owner_instance_boot_id: owner.boot_id
        )
        |> Repo.update!()

      expired_lease
      |> Ecto.Changeset.change(
        owner_instance_id: owner.node_name,
        owner_instance_boot_id: owner.boot_id
      )
      |> Repo.update!()

      if unquote(execution_state) in [:dead, :scanner_first, :entitled] do
        monitor = Process.monitor(pid)
        send(starter, :finish)
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 15_000
        CodexPooler.ExecutionProofSupport.publish_terminal!(attempt)
      end

      attempt =
        if unquote(execution_state) == :unknown do
          attempt
          |> Ecto.Changeset.change(owner_execution_id: Ecto.UUID.generate())
          |> Repo.update!()
        else
          attempt
        end

      assert ExecutionIdentity.status(attempt) ==
               if(unquote(execution_state) in [:scanner_first, :entitled],
                 do: :dead,
                 else: unquote(execution_state)
               )

      expected_code =
        case unquote(execution_state) do
          state when state in [:dead, :scanner_first] -> "dead_execution_recovered"
          :entitled -> "websocket_replay_revoked"
          _ -> "owner_unavailable"
        end

      expected_attempt_code =
        if unquote(execution_state) == :entitled, do: "client_disconnected", else: expected_code

      expected_attempt_status =
        if unquote(execution_state) == :entitled, do: "retryable_failed", else: "failed"

      turn = turn_fixture(session, request, attempt, now)

      request
      |> ledger_entry_fixture(%{
        attempt_id: attempt.id,
        pool_upstream_assignment_id: assignment.id,
        upstream_identity_id: assignment.upstream_identity_id,
        entry_kind: "reservation",
        amount_status: "recorded",
        usage_status: "usage_pending",
        transport: "websocket",
        output_tokens: 8,
        total_tokens: 12,
        details: %{"source" => "test_reservation"}
      })
      |> Ecto.Changeset.change(%{source_event_id: "request:#{request.id}:reservation"})
      |> Repo.update!()

      if unquote(execution_state) == :entitled do
        attempt
        |> Ecto.Changeset.change(
          status: "retryable_failed",
          completed_at: now,
          retryable: true,
          network_error_code: "client_disconnected",
          usage_status: "usage_unknown"
        )
        |> Repo.update!()

        turn |> Ecto.Changeset.change(semantic_turn_digest: <<1::256>>) |> Repo.update!()

        %RequestReplayEntitlement{}
        |> RequestReplayEntitlement.changeset(%{
          request_id: request.id,
          codex_turn_id: turn.id,
          eligible_attempt_id: attempt.id,
          api_key_id: api_key.id,
          api_key_runtime_epoch: api_key.runtime_revocation_epoch,
          pool_id: pool.id,
          model_id: model.id,
          model_identifier: model.exposed_model_id,
          semantic_turn_digest: <<1::256>>,
          replay_claim_digest: <<2::256>>,
          replay_generation: 1,
          owner_lease_digest: <<3::256>>,
          owner_lease_key_version: "test-v1",
          predecessor_epoch: 1,
          status: "armed",
          armed_at: now,
          expires_at: DateTime.add(now, 30)
        })
        |> Repo.insert!()
      end

      if unquote(execution_state) == :scanner_first do
        assert {:ok, :recovered} =
                 RequestLifecycle.recover_dead_execution(
                   request,
                   attempt,
                   now
                 )
      end

      assert {:ok, summary} = RuntimeCleanup.cleanup_expired_runtime_state(now)

      assert summary.expired_owner_sessions_recovered ==
               if(unquote(execution_state) == :scanner_first, do: 0, else: 1)

      assert summary.expired_owner_leases == 1

      assert %Request{
               status: "failed",
               usage_status: "usage_unknown",
               response_status_code: 499,
               last_error_code: ^expected_code
             } = Repo.reload!(request)

      assert %Attempt{
               status: ^expected_attempt_status,
               usage_status: "usage_unknown",
               network_error_code: ^expected_attempt_code
             } = Repo.reload!(attempt)

      expected_turn_status =
        if unquote(execution_state) == :entitled, do: "failed", else: "interrupted"

      assert %CodexTurn{status: ^expected_turn_status, error_code: ^expected_code} =
               Repo.reload!(turn)

      assert Repo.reload!(expired_lease).status == "expired"

      assert {:ok, :noop} =
               RequestLifecycle.recover_dead_execution(
                 request,
                 attempt,
                 now
               )

      assert Enum.map(ledger_entries_for_request(request.id), & &1.entry_kind) |> Enum.sort() == [
               "release",
               "reservation",
               "settlement"
             ]
    end
  end

  @tag :replay_cleanup
  @tag :replay_lock_order
  test "expired owner cleanup does not interrupt a replacement owner after candidate selection" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expired_at = DateTime.add(now, -1, :second)
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    model = model_fixture(pool, %{exposed_model_id: "gpt-cleanup-takeover"})
    session = session_fixture(pool, api_key, assignment, expired_at)
    old_token = session.owner_lease_token
    old_lease = lease_fixture(session, pool, api_key, assignment, expired_at, now)

    old_lease
    |> Ecto.Changeset.change(%{lease_token: old_token})
    |> Repo.update!()

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        model_id: model.id,
        requested_model: model.exposed_model_id,
        transport: "websocket",
        status: "in_progress",
        usage_status: "usage_pending",
        completed_at: nil,
        response_status_code: nil,
        request_metadata: %{"codex_session_id" => session.id}
      })

    attempt =
      attempt_fixture(request, assignment, %{
        status: "in_progress",
        completed_at: nil,
        usage_status: "usage_pending",
        response_metadata: %{}
      })

    turn = turn_fixture(session, request, attempt, now)

    request
    |> ledger_entry_fixture(%{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      entry_kind: "reservation",
      amount_status: "recorded",
      usage_status: "usage_pending",
      transport: "websocket",
      details: %{"source" => "test_reservation"}
    })
    |> Ecto.Changeset.change(%{source_event_id: "request:#{request.id}:reservation"})
    |> Repo.update!()

    barrier_ref = make_ref()
    parent = self()

    Application.put_env(
      :codex_pooler,
      :runtime_cleanup_owner_candidate_test_barrier,
      {parent, barrier_ref}
    )

    on_exit(fn ->
      Application.delete_env(:codex_pooler, :runtime_cleanup_owner_candidate_test_barrier)
    end)

    cleanup_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        RuntimeCleanup.cleanup_expired_runtime_state(now)
      end)

    assert_receive {:runtime_cleanup_owner_candidates_selected, cleanup_pid, ^barrier_ref, [candidate]}

    assert candidate.session_id == session.id
    assert candidate.owner_instance_id == session.owner_instance_id
    assert candidate.owner_lease_token == old_token
    assert candidate.owner_lease_expires_at == session.owner_lease_expires_at

    replacement_opts =
      %{}
      |> RequestOptions.for_websocket()
      |> RequestOptions.put_continuity(
        owner_instance_id: "node-b",
        bridge_owner_lease_ttl_seconds: 120
      )

    assert {:ok, replacement} =
             SessionContinuity.replace_unavailable_owner_lease(session, replacement_opts)

    refute replacement.owner_lease_token == old_token
    released_old_lease = Repo.reload!(old_lease)
    assert released_old_lease.status == "released"

    replacement_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        model_id: model.id,
        requested_model: model.exposed_model_id,
        transport: "websocket",
        status: "in_progress",
        usage_status: "usage_pending",
        completed_at: nil,
        response_status_code: nil,
        request_metadata: %{"codex_session_id" => replacement.id}
      })

    replacement_attempt =
      attempt_fixture(replacement_request, assignment, %{
        status: "in_progress",
        completed_at: nil,
        usage_status: "usage_pending",
        response_metadata: %{}
      })

    replacement_turn =
      %CodexTurn{
        codex_session_id: replacement.id,
        request_id: replacement_request.id,
        turn_sequence: 2,
        transport_kind: replacement_request.transport,
        final_attempt_id: replacement_attempt.id,
        status: "in_progress",
        started_at: now,
        created_at: now,
        updated_at: now
      }
      |> Repo.insert!()

    replacement_request
    |> ledger_entry_fixture(%{
      attempt_id: replacement_attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      entry_kind: "reservation",
      amount_status: "recorded",
      usage_status: "usage_pending",
      transport: "websocket",
      details: %{"source" => "test_reservation"}
    })
    |> Ecto.Changeset.change(%{
      source_event_id: "request:#{replacement_request.id}:reservation"
    })
    |> Repo.update!()

    assert {:ok, :stale_owner} =
             CodexPooler.Accounting.close_request_replays_for_session(
               candidate.session_id,
               Map.take(candidate, [
                 :owner_instance_id,
                 :owner_lease_token,
                 :owner_lease_expires_at
               ]),
               :owner_shutdown
             )

    send(cleanup_pid, {:release_runtime_cleanup_owner_candidates, barrier_ref})

    assert {:ok, summary} = Task.await(cleanup_task, 15_000)
    assert summary.expired_owner_sessions_recovered == 0

    replacement_lease =
      Repo.one!(
        from lease in BridgeOwnerLease,
          where: lease.codex_session_id == ^session.id and lease.status == "active"
      )

    assert Repo.reload!(replacement).status == "active"
    assert Repo.reload!(old_lease) == released_old_lease
    assert replacement_lease.lease_token == replacement.owner_lease_token
    assert Repo.reload!(request).status == "in_progress"
    assert Repo.reload!(attempt).status == "in_progress"
    assert Repo.reload!(turn).status == "in_progress"
    assert Repo.reload!(replacement_request).status == "in_progress"
    assert Repo.reload!(replacement_attempt).status == "in_progress"
    assert Repo.reload!(replacement_turn).status == "in_progress"

    Application.delete_env(:codex_pooler, :runtime_cleanup_owner_candidate_test_barrier)

    assert {:ok, repeated} = RuntimeCleanup.cleanup_expired_runtime_state(now)
    assert repeated.expired_owner_sessions_recovered == 0
    assert Repo.reload!(replacement).status == "active"
    assert Repo.reload!(old_lease) == released_old_lease
    assert Repo.reload!(request).status == "in_progress"
    assert Repo.reload!(attempt).status == "in_progress"
    assert Repo.reload!(turn).status == "in_progress"
    assert Repo.reload!(replacement_request).status == "in_progress"
    assert Repo.reload!(replacement_attempt).status == "in_progress"
    assert Repo.reload!(replacement_turn).status == "in_progress"
  end

  test "jobs cleanup entrypoint combines file and gateway cleanup summaries" do
    now = ~U[2026-05-03 03:00:00Z]
    expired_at = DateTime.add(now, -1, :second)
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    session = session_fixture(pool, api_key, assignment, now)

    file_record_fixture(pool, api_key, %{status: "uploaded", expires_at: expired_at})
    alias_fixture(session, pool, api_key, expired_at)

    assert {:ok, summary} = Jobs.cleanup_runtime_state(now)

    assert summary.expired_files == 1
    assert summary.expired_aliases == 1
  end

  test "every cleanup step contributes to the summary" do
    # The pass runs seven independent kinds of cleanup. They used to run in one
    # `with` chain, which made each conditional on all the earlier ones: a fault
    # in file expiry silently skipped ownership recovery and presence pruning,
    # and nothing distinguished "recovery ran and found nothing" from "recovery
    # never ran". Asserting one key per step keeps that honest — a reintroduced
    # chain would drop the keys of everything behind the first failure.
    now = ~U[2026-05-03 03:00:00Z]
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    session = session_fixture(pool, api_key, assignment, now)

    file_record_fixture(pool, api_key, %{
      status: "uploaded",
      expires_at: DateTime.add(now, -1, :second)
    })

    alias_fixture(session, pool, api_key, DateTime.add(now, -1, :second))

    assert {:ok, summary} = Jobs.cleanup_runtime_state(now)

    for key <- [
          :expired_files,
          :expired_owner_leases,
          :stale_reservations_released,
          :absent_instance_attempts_recovered,
          :instance_presence_rows_pruned,
          :stale_catalog_sync_runs_failed,
          :stale_account_reconciliations_failed,
          :expired_quota_windows_pruned
        ] do
      assert Map.has_key?(summary, key), "the summary does not report #{key}"
    end

    assert summary.expired_files == 1
    assert summary.expired_aliases == 1
  end

  for first <- [:owner, :scanner] do
    test "expired owner and dead scanner serialize with #{first} holding the session lock" do
      %{user: user} = AccountsFixtures.committed_bootstrap_owner_fixture!()
      parent = self()

      executor =
        start_supervised!(
          {Task,
           fn ->
             fixture =
               UnboxedFixture.run_unboxed(fn ->
                 pool = pool_fixture(%{created_by_user_id: user.id})

                 %{api_key: api_key} =
                   active_api_key_fixture(pool, %{created_by_user_id: user.id})

                 model = model_fixture(pool)
                 %{assignment: assignment} = upstream_assignment_fixture(pool)
                 now = DateTime.utc_now()
                 expiry = DateTime.add(now, -60)
                 session = session_fixture(pool, api_key, assignment, expiry)
                 lease_fixture(session, pool, api_key, assignment, expiry, now)

                 {:ok, reserved} =
                   Accounting.reserve(
                     %{pool: pool, api_key: api_key},
                     model,
                     %{"model" => model.exposed_model_id, "max_output_tokens" => 10},
                     %{
                       transport: "websocket",
                       correlation_id: Ecto.UUID.generate(),
                       request_metadata: %{"codex_session_id" => session.id}
                     }
                   )

                 {:ok, attempt} = Accounting.create_attempt(reserved.request, assignment)
                 turn = turn_fixture(session, reserved.request, attempt, now)
                 %{session: session, request: reserved.request, attempt: attempt, turn: turn}
               end)

             send(parent, {:race_fixture, fixture})

             receive do
               :finish -> :ok
             end
           end}
        )

      assert_receive {:race_fixture, fixture}, 15_000
      monitor = Process.monitor(executor)
      send(executor, :finish)
      assert_receive {:DOWN, ^monitor, :process, ^executor, :normal}, 15_000
      assert ExecutionIdentity.status(fixture.attempt) == :dead
      CodexPooler.ExecutionProofSupport.publish_committed_terminal!(fixture.attempt)
      first = unquote(first)
      second = unquote(if(first == :owner, do: :scanner, else: :owner))

      runner = fn kind, held ->
        result =
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")

              if held do
                Repo.one!(from s in CodexSession, where: s.id == ^fixture.session.id, lock: "FOR UPDATE")
              end

              send(parent, {:race_backend, kind, self(), backend})

              if held do
                receive do
                  :release -> :ok
                end
              end

              case kind do
                :owner ->
                  RuntimeCleanup.cleanup_expired_runtime_state(DateTime.utc_now())

                :scanner ->
                  Accounting.RequestLifecycle.recover_dead_execution(
                    fixture.request,
                    fixture.attempt,
                    DateTime.utc_now()
                  )
              end
            end)
          end)

        send(parent, {:race_result, kind, result})
      end

      blocker = start_supervised!({Task, fn -> runner.(first, true) end}, id: :expiry_blocker)
      blocker_monitor = Process.monitor(blocker)
      assert_receive {:race_backend, ^first, ^blocker, blocker_backend}, 15_000
      waiter = start_supervised!({Task, fn -> runner.(second, false) end}, id: :expiry_waiter)
      waiter_monitor = Process.monitor(waiter)
      assert_receive {:race_backend, ^second, ^waiter, waiter_backend}, 15_000
      assert waiter_backend != blocker_backend

      assert_expiry_blocked(
        waiter_backend,
        blocker_backend,
        System.monotonic_time(:millisecond) + 15_000
      )

      TestDiagnostics.puts("expired owner race #{first}: distinct backends #{blocker_backend}/#{waiter_backend}; pg_blocking_pids observed")

      send(blocker, :release)
      assert_receive {:race_result, ^first, {:ok, {:ok, _}}}, 15_000
      assert_receive {:race_result, ^second, {:ok, {:ok, _}}}, 15_000
      assert_receive {:DOWN, ^blocker_monitor, :process, ^blocker, :normal}, 15_000
      assert_receive {:DOWN, ^waiter_monitor, :process, ^waiter, :normal}, 15_000

      UnboxedFixture.run_unboxed(fn ->
        assert Repo.reload!(fixture.request).last_error_code == "dead_execution_recovered"
        assert Repo.reload!(fixture.turn).error_code == "dead_execution_recovered"

        assert Enum.sort(Enum.map(ledger_entries_for_request(fixture.request.id), & &1.entry_kind)) == ["release", "reservation", "settlement"]
      end)
    end
  end

  defp assert_expiry_blocked(waiter, blocker, deadline) do
    blocked =
      UnboxedFixture.run_unboxed(fn ->
        Repo.query!("SELECT $2 = ANY(pg_blocking_pids($1))", [waiter, blocker]).rows == [[true]]
      end)

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      assert_expiry_blocked(waiter, blocker, deadline)
    end
  end

  defp file_record_fixture(pool, api_key, attrs) do
    now = ~U[2026-05-03 01:00:00Z]
    expires_at = Map.get(attrs, :expires_at, DateTime.add(now, 7200, :second))

    %FileRecord{}
    |> FileRecord.changeset(%{
      pool_id: pool.id,
      api_key_id: api_key.id,
      file_id: Map.get(attrs, :file_id, "file-#{System.unique_integer([:positive])}"),
      purpose: "user_data",
      filename: "sample.txt",
      byte_size: Map.get(attrs, :byte_size, 12),
      status: Map.get(attrs, :status, "pending_upload"),
      finalize_status: Map.get(attrs, :finalize_status, "pending"),
      expires_at: expires_at,
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp session_fixture(pool, api_key, assignment, now) do
    now = usec(now)

    %CodexSession{
      pool_id: pool.id,
      api_key_id: api_key.id,
      session_key: "session-#{System.unique_integer([:positive])}",
      pool_upstream_assignment_id: assignment.id,
      status: "active",
      owner_instance_id: "node-a",
      owner_lease_token: Ecto.UUID.generate(),
      owner_lease_expires_at: DateTime.add(now, 45, :second),
      last_heartbeat_at: now,
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp alias_fixture(session, pool, api_key, expires_at) do
    now = usec(~U[2026-05-03 01:00:00Z])
    expires_at = usec(expires_at)

    %BridgeSessionAlias{}
    |> BridgeSessionAlias.changeset(%{
      codex_session_id: session.id,
      pool_id: pool.id,
      api_key_id: api_key.id,
      alias_kind: "turn_state",
      alias_hash: :crypto.hash(:sha256, "alias-#{System.unique_integer([:positive])}"),
      status: "active",
      expires_at: expires_at,
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp lease_fixture(session, pool, api_key, assignment, expires_at, now) do
    now = usec(now)
    expires_at = usec(expires_at)

    %BridgeOwnerLease{}
    |> BridgeOwnerLease.changeset(%{
      codex_session_id: session.id,
      pool_id: pool.id,
      api_key_id: api_key.id,
      pool_upstream_assignment_id: assignment.id,
      owner_instance_id: "node-a",
      lease_token: session.owner_lease_token,
      status: "active",
      acquired_at: now,
      renewed_at: now,
      expires_at: expires_at,
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp idempotency_key_fixture(pool, api_key, expires_at) do
    now = usec(~U[2026-05-03 01:00:00Z])
    expires_at = usec(expires_at)

    %IdempotencyKey{}
    |> IdempotencyKey.changeset(%{
      pool_id: pool.id,
      api_key_id: api_key.id,
      scope: "backend_file_create",
      key_hash: :crypto.hash(:sha256, "key-#{System.unique_integer([:positive])}"),
      status: "in_progress",
      expires_at: expires_at,
      response_metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  test "cleanup recovers attempts owned by an instance that stopped reporting" do
    setup = accounting_setup()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    dispatched_at = DateTime.add(now, -10, :minute)
    unique = System.unique_integer([:positive])
    absent_instance = Identity.new("codex_pooler@10.0.0.#{unique}", "boot#{unique}")

    {:ok, _presence} =
      InstancePresence.record_heartbeat(absent_instance, DateTime.add(now, -10, :minute))

    {:ok, reserved} =
      Accounting.reserve(
        setup.auth,
        setup.model,
        %{"model" => setup.model.exposed_model_id, "stream" => true, "max_output_tokens" => 10},
        %{
          correlation_id: "corr-cleanup-absent-instance",
          now: dispatched_at,
          transport: "http_sse"
        }
      )

    {:ok, attempt} =
      Accounting.create_attempt(reserved.request, setup.assignment, %{
        now: dispatched_at,
        owner_instance_id: absent_instance.node_name,
        owner_instance_boot_id: absent_instance.boot_id
      })

    # A real successful observer heartbeat is required before stale target
    # presence can authorize the legacy recovery path.
    assert {:ok, _observer} = InstancePresence.record_heartbeat()
    assert {:ok, summary} = Jobs.cleanup_runtime_state(now)
    assert summary.absent_instance_attempts_recovered == 1
    assert is_integer(summary.instance_presence_rows_pruned)

    assert %Request{status: "failed", last_error_code: "absent_instance_recovered"} =
             Repo.get!(Request, reserved.request.id)

    assert %Attempt{status: "failed", network_error_code: "absent_instance_recovered"} =
             Repo.reload!(attempt)

    assert ledger_entries_for_request(reserved.request.id)
           |> Enum.map(& &1.entry_kind)
           |> Enum.sort() == ["release", "reservation", "settlement"]
  end

  test "one cleanup pass settles a superseded owner through absent-instance recovery first" do
    setup = accounting_setup()
    now = InstancePresence.database_now()
    dispatched_at = DateTime.add(now, -10, :minute)
    expired_at = DateTime.add(now, -1, :second)
    node_name = "codex_pooler@10.78.#{System.unique_integer([:positive])}.9"
    first = Identity.new(node_name, Ecto.UUID.generate())
    second = Identity.new(node_name, Ecto.UUID.generate())

    assert {:ok, _} = InstancePresence.record_heartbeat(first, dispatched_at)
    assert {:ok, _} = InstancePresence.record_heartbeat(second, now)
    assert {:ok, _} = InstancePresence.record_heartbeat()

    assert {:ok, reserved} =
             Accounting.reserve(
               setup.auth,
               setup.model,
               %{
                 "model" => setup.model.exposed_model_id,
                 "stream" => true,
                 "max_output_tokens" => 10
               },
               %{
                 correlation_id: "corr-cleanup-superseded-owner",
                 now: dispatched_at,
                 transport: "websocket"
               }
             )

    assert {:ok, attempt} =
             Accounting.create_attempt(reserved.request, setup.assignment, %{
               now: dispatched_at,
               owner_instance_id: first.node_name,
               owner_instance_boot_id: first.boot_id
             })

    attempt =
      attempt
      |> Ecto.Changeset.change(owner_execution_id: nil, owner_process_id: nil)
      |> Repo.update!()

    session = session_fixture(setup.pool, setup.api_key, setup.assignment, dispatched_at)

    session =
      session
      |> Ecto.Changeset.change(
        owner_instance_id: first.node_name,
        owner_instance_boot_id: first.boot_id,
        owner_lease_expires_at: expired_at
      )
      |> Repo.update!()

    lease = lease_fixture(session, setup.pool, setup.api_key, setup.assignment, expired_at, now)

    lease
    |> Ecto.Changeset.change(
      owner_instance_id: first.node_name,
      owner_instance_boot_id: first.boot_id
    )
    |> Repo.update!()

    turn = turn_fixture(session, reserved.request, attempt, now)

    assert InstancePresence.status(first) == :unknown
    assert InstancePresence.superseded?(first)

    capture_stream_outcomes(fn ->
      assert {:ok, summary} = Jobs.cleanup_runtime_state(now)
      assert summary.absent_instance_attempts_recovered == 1
      assert summary.expired_owner_sessions_recovered == 0

      assert_receive {:stream_outcome,
                      %{
                        outcome: "interrupted",
                        downstream_transport: "websocket",
                        upstream_transport: "websocket"
                      }}

      assert_receive {:stream_outcome_transaction, false}

      assert {:ok, repeated} = Jobs.cleanup_runtime_state(now)
      assert repeated.absent_instance_attempts_recovered == 0
      refute_received {:stream_outcome, _metadata}
    end)

    assert %Request{status: "failed", last_error_code: "absent_instance_recovered"} =
             Repo.reload!(reserved.request)

    assert %Attempt{status: "failed", network_error_code: "absent_instance_recovered"} =
             Repo.reload!(attempt)

    assert %CodexTurn{status: "interrupted", error_code: "absent_instance_recovered"} =
             Repo.reload!(turn)
  end

  test "a crashed owner's stranded attempt is recovered after a live peer takes its session over" do
    setup = accounting_setup()
    now = InstancePresence.database_now()
    dispatched_at = DateTime.add(now, -10, :minute)
    live_until = DateTime.add(now, 45, :second)
    node_name = "codex_pooler@10.79.#{System.unique_integer([:positive])}.9"
    crashed = Identity.new(node_name, Ecto.UUID.generate())
    successor = Identity.new(node_name, Ecto.UUID.generate())

    # The replica the released client's fallback landed on is a different VM
    # entirely. Only another node can name its own incarnation, so this is the
    # one owner the test supplies, exactly as owner forwarding supplies it on
    # takeover.
    peer =
      Identity.new("codex_pooler@10.79.#{System.unique_integer([:positive])}.10", Ecto.UUID.generate())

    assert {:ok, _} = InstancePresence.record_heartbeat(crashed, dispatched_at)
    assert {:ok, _} = InstancePresence.record_heartbeat(successor, now)
    assert {:ok, _} = InstancePresence.record_heartbeat(peer, now)
    assert {:ok, _} = InstancePresence.record_heartbeat()

    assert {:ok, reserved} =
             Accounting.reserve(
               setup.auth,
               setup.model,
               %{
                 "model" => setup.model.exposed_model_id,
                 "stream" => true,
                 "max_output_tokens" => 10
               },
               %{
                 correlation_id: "corr-cleanup-rehomed-session",
                 now: dispatched_at,
                 transport: "websocket"
               }
             )

    assert {:ok, attempt} =
             Accounting.create_attempt(reserved.request, setup.assignment, %{
               now: dispatched_at,
               owner_instance_id: crashed.node_name,
               owner_instance_boot_id: crashed.boot_id
             })

    session = session_fixture(setup.pool, setup.api_key, setup.assignment, dispatched_at)

    # The fallback turn is served by the live peer on this same session row:
    # the owner stamp moves to the peer and the lease is renewed into the
    # future, while the stranded attempt keeps naming the VM that died.
    session =
      session
      |> Ecto.Changeset.change(
        owner_instance_id: peer.node_name,
        owner_instance_boot_id: peer.boot_id,
        owner_lease_expires_at: live_until
      )
      |> Repo.update!()

    lease =
      lease_fixture(session, setup.pool, setup.api_key, setup.assignment, live_until, now)

    lease =
      lease
      |> Ecto.Changeset.change(
        owner_instance_id: peer.node_name,
        owner_instance_boot_id: peer.boot_id
      )
      |> Repo.update!()

    turn = turn_fixture(session, reserved.request, attempt, now)

    # The shelter really is there: the peer is present, it holds an unexpired
    # stamp and lease on the session, and the session-scoped question still
    # answers "held" for this request.
    refute InstancePresence.absent?(peer, now)
    assert InstancePresence.status(crashed) == :unknown
    assert InstancePresence.superseded?(crashed)
    assert RuntimeCleanup.active_runtime_request?(reserved.request, now)

    capture_stream_outcomes(fn ->
      assert {:ok, summary} = Jobs.cleanup_runtime_state(now)
      assert summary.absent_instance_attempts_recovered == 1
      assert summary.dead_execution_attempts_recovered == 0

      assert_receive {:stream_outcome,
                      %{
                        outcome: "interrupted",
                        downstream_transport: "websocket",
                        upstream_transport: "websocket"
                      }}

      assert_receive {:stream_outcome_transaction, false}

      assert {:ok, repeated} = Jobs.cleanup_runtime_state(now)
      assert repeated.absent_instance_attempts_recovered == 0
      refute_received {:stream_outcome, _metadata}
    end)

    assert %Request{status: "failed", last_error_code: "absent_instance_recovered"} =
             Repo.reload!(reserved.request)

    assert %Attempt{status: "failed", network_error_code: "absent_instance_recovered"} =
             Repo.reload!(attempt)

    assert %CodexTurn{status: "interrupted", error_code: "absent_instance_recovered"} =
             Repo.reload!(turn)

    assert ledger_entries_for_request(reserved.request.id)
           |> Enum.map(& &1.entry_kind)
           |> Enum.sort() == ["release", "reservation", "settlement"]

    # Only the dead owner's work was settled: the peer keeps the session it is
    # serving, with its own incarnation and its lease still active.
    settled_session = Repo.reload!(session)
    assert settled_session.owner_instance_boot_id == peer.boot_id
    assert settled_session.owner_lease_expires_at == session.owner_lease_expires_at
    assert Repo.reload!(lease).status == "active"
  end

  defp turn_fixture(session, request, attempt, now) do
    timestamp = now |> DateTime.add(-30, :second) |> usec()

    %CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: request.transport,
      final_attempt_id: attempt.id,
      status: "in_progress",
      started_at: timestamp,
      created_at: timestamp,
      updated_at: timestamp
    }
    |> Repo.insert!()
  end

  defp ledger_entries_for_request(request_id) do
    import Ecto.Query

    Repo.all(from entry in LedgerEntry, where: entry.request_id == ^request_id)
  end

  defp usec(%DateTime{} = timestamp) do
    %{timestamp | microsecond: {elem(timestamp.microsecond, 0), 6}}
  end

  defp capture_stream_outcomes(fun) do
    handler_id = "runtime-cleanup-outcome-#{System.unique_integer([:positive, :monotonic])}"
    parent = self()

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :stream, :outcome],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:stream_outcome, metadata})
          send(parent, {:stream_outcome_transaction, Repo.in_transaction?()})
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end
end
