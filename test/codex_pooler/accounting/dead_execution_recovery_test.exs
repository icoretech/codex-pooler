defmodule CodexPooler.Accounting.DeadExecutionRecoveryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounting.RequestLifecycle.DeadExecutionRecovery
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn, RuntimeCleanup}
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Websocket.ResponseTask
  alias CodexPooler.Platform.{ExecutionIdentity, InstancePresence}
  alias CodexPooler.UnboxedFixture
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  for kind <- [:direct, :proxy, :local_owner] do
    test "a sensitive #{kind} production ResponseTask stays live beyond the recovery age" do
      setup = accounting_setup()
      parent = self()
      registry = Module.concat(__MODULE__, "Sensitive#{System.unique_integer([:positive])}")

      start_supervised!({CodexPooler.Gateway.Transports.Websocket.ActivityRegistry, name: registry})

      starter =
        start_supervised!({Task,
         fn ->
           {:ok, pid} =
             ResponseTask.start(
               self(),
               unquote(kind),
               fn _pid ->
                 pair = reserve_attempt(setup)
                 send(parent, {:sensitive_admitted, self(), pair})

                 receive do
                   :complete -> :ok
                 end
               end,
               fn _, _ -> :ok end,
               activity_registry: registry
             )

           # ResponseTask starts an unlinked task. Link it to this supervised
           # fixture owner so assertion failures and ExUnit timeouts cannot
           # leave the sensitive task or its cancellation watcher behind.
           Process.link(pid)
           send(parent, {:sensitive_owner_ready, self(), pid})
           monitor = Process.monitor(pid)

           receive do
             :stop ->
               send(pid, :complete)

               if unquote(kind) != :local_owner do
                 receive do
                   {:websocket_response_activity, ^pid, token} ->
                     ResponseTask.acknowledge_delivery(pid, token)
                 end
               end

               receive do
                 {:DOWN, ^monitor, :process, ^pid, _} -> :ok
               end
           end
         end})

      assert_receive {:sensitive_admitted, pid, {request, attempt}}, 15_000
      assert_receive {:sensitive_owner_ready, ^starter, ^pid}, 15_000
      assert Process.alive?(pid)
      assert starter in elem(Process.info(pid, :links), 1)
      assert attempt.owner_process_id == List.to_string(:erlang.pid_to_list(pid))

      assert :erlang.process_info(pid, {:dictionary, {ExecutionIdentity, :execution_id}}) ==
               {{:dictionary, {ExecutionIdentity, :execution_id}}, :undefined}

      assert ExecutionIdentity.status(attempt) == :alive

      assert {:ok, %{dead_execution_attempts_recovered: 0}} =
               DeadExecutionRecovery.recover(DateTime.add(DateTime.utc_now(), 121))

      assert Repo.reload!(request).status == "in_progress"
      monitor = Process.monitor(pid)
      send(starter, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 15_000
      assert ExecutionIdentity.status(attempt) == :dead
    end
  end

  test "unknown execution evidence leaves the persisted request, turn, and ledger untouched" do
    setup = accounting_setup()
    {request, attempt} = reserve_attempt(setup)
    now = DateTime.utc_now()
    owner = InstancePresence.local_identity()

    attempt =
      attempt
      |> Ecto.Changeset.change(owner_execution_id: Ecto.UUID.generate())
      |> Repo.update!()

    session =
      Repo.insert!(%CodexSession{
        pool_id: setup.pool.id,
        api_key_id: setup.api_key.id,
        session_key: Ecto.UUID.generate(),
        status: "active",
        owner_instance_id: owner.node_name,
        owner_instance_boot_id: owner.boot_id,
        owner_lease_token: Ecto.UUID.generate(),
        last_heartbeat_at: now,
        owner_lease_expires_at: DateTime.add(now, 3600)
      })

    turn =
      Repo.insert!(%CodexTurn{
        codex_session_id: session.id,
        request_id: request.id,
        turn_sequence: 1,
        transport_kind: "http_sse",
        status: "in_progress",
        started_at: now
      })

    assert ExecutionIdentity.status(attempt) == :unknown

    assert {:ok, %{dead_execution_attempts_recovered: 0}} =
             DeadExecutionRecovery.recover(DateTime.add(now, 1), minimum_age_seconds: 0)

    assert Repo.reload!(request).status == "in_progress"
    assert Repo.reload!(attempt).status == "in_progress"
    assert Repo.reload!(turn).status == "in_progress"

    assert Enum.map(Accounting.list_ledger_entries_for_request(request.id), & &1.entry_kind) == [
             "reservation"
           ]
  end

  test "independent connection recovery waits for successful finalization and does not settle twice" do
    %{user: owner} = CodexPooler.AccountsFixtures.committed_bootstrap_owner_fixture!()

    setup =
      UnboxedFixture.run_unboxed(fn ->
        pool = CodexPooler.PoolerFixtures.pool_fixture(%{created_by_user_id: owner.id})

        %{api_key: api_key} =
          CodexPooler.PoolerFixtures.active_api_key_fixture(pool, %{created_by_user_id: owner.id})

        model = CodexPooler.PoolerFixtures.model_fixture(pool)
        %{assignment: assignment} = CodexPooler.PoolerFixtures.upstream_assignment_fixture(pool)
        %{auth: %{pool: pool, api_key: api_key}, model: model, assignment: assignment}
      end)

    parent = self()

    owner_pid =
      start_supervised!(
        {Task,
         fn ->
           pair = Sandbox.unboxed_run(Repo, fn -> reserve_attempt(setup) end)
           send(parent, {:race_attempt, pair})

           receive do
             :stop -> :ok
           end
         end},
        id: :race_owner
      )

    owner_monitor = Process.monitor(owner_pid)
    assert_receive {:race_attempt, {request, attempt}}, 15_000

    assert {:ok, :noop} =
             UnboxedFixture.run_unboxed(fn ->
               Accounting.RequestLifecycle.recover_dead_execution(
                 request,
                 attempt,
                 DateTime.utc_now()
               )
             end)

    send(owner_pid, :stop)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, :normal}, 15_000

    finalizer =
      start_supervised!(
        {Task,
         fn ->
           result =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.checkout(fn ->
                 %{rows: [[backend]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])

                 Accounting.finalize_request(request, attempt, %{
                   before_finalize: fn ->
                     send(parent, {:finalization_locked, backend})

                     receive do
                       :commit -> :ok
                     end
                   end
                 })
               end)
             end)

           send(parent, {:finalized, result})
         end},
        id: :race_finalizer
      )

    finalizer_monitor = Process.monitor(finalizer)
    assert_receive {:finalization_locked, finalizer_backend}, 15_000

    recovery =
      start_supervised!(
        {Task,
         fn ->
           result =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.checkout(fn ->
                 %{rows: [[backend]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
                 send(parent, {:recovery_backend, backend})

                 Accounting.RequestLifecycle.recover_dead_execution(
                   request,
                   attempt,
                   DateTime.utc_now()
                 )
               end)
             end)

           send(parent, {:recovery_finished, result})
         end},
        id: :race_recovery
      )

    recovery_monitor = Process.monitor(recovery)
    assert_receive {:recovery_backend, recovery_backend}, 15_000
    assert recovery_backend != finalizer_backend

    assert_blocked(
      recovery_backend,
      finalizer_backend,
      System.monotonic_time(:millisecond) + 15_000
    )

    CodexPooler.TestDiagnostics.puts("dead execution race: distinct PostgreSQL backends=#{finalizer_backend},#{recovery_backend}; pg_blocking_pids observed recovery waiting on finalization")

    send(finalizer, :commit)
    assert_receive {:finalized, {:ok, _}}, 15_000
    assert_receive {:recovery_finished, {:ok, :noop}}, 15_000
    assert_receive {:DOWN, ^finalizer_monitor, :process, ^finalizer, :normal}, 15_000
    assert_receive {:DOWN, ^recovery_monitor, :process, ^recovery, :normal}, 15_000

    UnboxedFixture.run_unboxed(fn ->
      assert Repo.reload!(request).status == "succeeded"

      assert Enum.sort(Enum.map(Accounting.list_ledger_entries_for_request(request.id), & &1.entry_kind)) == ["release", "reservation", "settlement"]
    end)
  end

  defp assert_blocked(waiter, blocker, deadline) do
    blocked =
      UnboxedFixture.run_unboxed(fn ->
        SQL.query!(Repo, "SELECT $2 = ANY(pg_blocking_pids($1))", [waiter, blocker]).rows == [
          [true]
        ]
      end)

    if not blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "recovery never blocked behind finalization"

      Process.sleep(10)
      assert_blocked(waiter, blocker, deadline)
    end
  end

  @tag slow: "crosses the production 100-row recovery batch with real live execution identities"
  test "bounded passes advance past one hundred active executions" do
    setup = accounting_setup()

    update_default_policy!(setup.api_key, %{
      max_tokens_per_day: 1_000_000,
      max_requests_per_minute: 1_000
    })

    for _ <- 1..101, do: reserve_attempt(setup)
    parent = self()

    pid =
      start_supervised!(
        {Task,
         fn ->
           pair = reserve_attempt(setup)
           send(parent, {:last_attempt, pair})

           receive do
             :finish -> :ok
           end
         end}
      )

    monitor = Process.monitor(pid)
    assert_receive {:last_attempt, {request, attempt}}, 15_000
    send(pid, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 15_000
    CodexPooler.ExecutionProofSupport.publish_terminal!(attempt)
    now = DateTime.add(DateTime.utc_now(), 1)

    assert {:ok, %{dead_execution_attempts_recovered: 0}} =
             DeadExecutionRecovery.recover(now, minimum_age_seconds: 0)

    assert Repo.reload!(attempt).status == "in_progress"

    assert {:ok, %{dead_execution_attempts_recovered: 1}} =
             DeadExecutionRecovery.recover(DateTime.add(now, 1), minimum_age_seconds: 0)

    assert Repo.reload!(request).status == "failed"
  end

  # The recovered execution's `interrupted` outcome follows the after-commit
  # rule every other recovery path follows: a caller-owned transaction has not
  # committed, so the marker is handed back for the outermost commit instead
  # of being emitted early — or, as it used to be here, dropped (findings#224).
  describe "interrupted outcome inside a caller-owned transaction" do
    test "a caller-owned rollback emits nothing and leaves the execution unrecovered" do
      setup = accounting_setup()
      {request, attempt} = proven_dead_candidate!(setup)
      now = DateTime.utc_now()

      capture_stream_outcomes(fn ->
        assert {:error, :caller_rollback} =
                 Repo.transaction(fn ->
                   assert {:ok,
                           %{
                             dead_execution_attempts_recovered: 1,
                             after_commit_markers: [marker]
                           }} =
                            DeadExecutionRecovery.recover(DateTime.add(now, 1), minimum_age_seconds: 0)

                   assert marker == %{
                            kind: :stream_outcome,
                            outcome: "interrupted",
                            downstream_transport: "http_sse",
                            upstream_transport: "http_sse"
                          }

                   Repo.rollback(:caller_rollback)
                 end)

        refute_received {:stream_outcome, _metadata}
      end)

      assert Repo.reload!(request).status == "in_progress"
      assert Repo.reload!(attempt).status == "in_progress"
    end

    test "a caller-owned commit hands back one marker, emitted once by the commit owner and never again" do
      setup = accounting_setup()
      {request, attempt} = proven_dead_candidate!(setup)
      now = DateTime.utc_now()

      capture_stream_outcomes(fn ->
        assert {:ok,
                {:ok,
                 %{
                   dead_execution_attempts_recovered: 1,
                   after_commit_markers: [marker]
                 }}} =
                 Repo.transaction(fn ->
                   DeadExecutionRecovery.recover(DateTime.add(now, 1), minimum_age_seconds: 0)
                 end)

        refute_received {:stream_outcome, _metadata}

        assert Interruption.emit_committed_deferred_outcomes([marker]) == :ok
        assert_receive {:stream_outcome, %{outcome: "interrupted", downstream_transport: "http_sse"}}
        assert_receive {:stream_outcome_transaction, false}

        # The recovered execution is settled; a repeated pass is a no-op with
        # no marker to hand back.
        assert {:ok, %{dead_execution_attempts_recovered: 0} = summary} =
                 DeadExecutionRecovery.recover(DateTime.add(now, 2), minimum_age_seconds: 0)

        refute Map.has_key?(summary, :after_commit_markers)
        refute_received {:stream_outcome, _metadata}
      end)

      assert Repo.reload!(request).status == "failed"
      assert Repo.reload!(attempt).status == "failed"
    end

    test "a bare recovery emits its outcome itself, after its own commit" do
      setup = accounting_setup()
      {request, _attempt} = proven_dead_candidate!(setup)
      now = DateTime.utc_now()

      capture_stream_outcomes(fn ->
        assert {:ok, %{dead_execution_attempts_recovered: 1} = summary} =
                 DeadExecutionRecovery.recover(DateTime.add(now, 1), minimum_age_seconds: 0)

        refute Map.has_key?(summary, :after_commit_markers)
        assert_receive {:stream_outcome, %{outcome: "interrupted", downstream_transport: "http_sse"}}
        assert_receive {:stream_outcome_transaction, false}
        refute_received {:stream_outcome, _metadata}
      end)

      assert Repo.reload!(request).status == "failed"
    end
  end

  # One attempt whose owning process reserved it and then exited normally, with
  # its terminal proof published: exactly the candidate the cleanup job recovers.
  defp proven_dead_candidate!(setup) do
    parent = self()

    pid =
      start_supervised!(
        {Task,
         fn ->
           pair = reserve_attempt(setup)
           send(parent, {:dead_candidate, pair})

           receive do
             :finish -> :ok
           end
         end}
      )

    monitor = Process.monitor(pid)
    assert_receive {:dead_candidate, {request, attempt}}, 15_000
    send(pid, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 15_000
    CodexPooler.ExecutionProofSupport.publish_terminal!(attempt)
    {request, attempt}
  end

  defp capture_stream_outcomes(fun) do
    handler_id = "dead-execution-outcome-#{System.unique_integer([:positive, :monotonic])}"
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

  defp reserve_attempt(setup) do
    {:ok, reserved} =
      Accounting.reserve(
        setup.auth,
        setup.model,
        %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10},
        %{transport: "http_sse", correlation_id: Ecto.UUID.generate()}
      )

    {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    {reserved.request, attempt}
  end

  test "exact death never recovers a superseded attempt or a generation-one attempt" do
    setup = accounting_setup()
    setup.api_key |> Ecto.Changeset.change(max_active_requests: 1) |> Repo.update!()
    {request, first} = reserve_attempt(setup)
    {:ok, latest} = Accounting.create_attempt(request, setup.assignment)
    :ok = ExecutionIdentity.complete()
    CodexPooler.ExecutionProofSupport.publish_terminal!(latest)

    assert {:ok, :noop} =
             Accounting.RequestLifecycle.recover_dead_execution(
               request,
               first,
               DateTime.utc_now()
             )

    replay = latest |> Ecto.Changeset.change(replay_generation: 1) |> Repo.update!()

    assert {:ok, :noop} =
             Accounting.RequestLifecycle.recover_dead_execution(
               request,
               replay,
               DateTime.utc_now()
             )

    assert Repo.reload!(request).status == "in_progress"

    assert {:error, %{code: :api_key_concurrency_limit_exceeded}} =
             Accounting.reserve(setup.auth, setup.model, %{
               "model" => setup.model.exposed_model_id
             })

    latest = replay |> Ecto.Changeset.change(replay_generation: 0) |> Repo.update!()

    assert {:ok, :recovered} =
             Accounting.RequestLifecycle.recover_dead_execution(
               request,
               latest,
               DateTime.utc_now()
             )

    assert {:ok, _} =
             Accounting.reserve(setup.auth, setup.model, %{
               "model" => setup.model.exposed_model_id
             })
  end

  for transport <- ["http_sse", "websocket"] do
    test "#{transport} failed finalization is recovered after its task exits while the session lives" do
      setup = accounting_setup()
      setup.api_key |> Ecto.Changeset.change(max_active_requests: 1) |> Repo.update!()
      parent = self()
      now = DateTime.utc_now()
      {:ok, _} = InstancePresence.record_heartbeat(InstancePresence.local_identity(), now)

      pid =
        start_supervised!(
          {Task,
           fn ->
             {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10},
                 %{transport: unquote(transport), correlation_id: Ecto.UUID.generate()}
               )

             {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
             send(parent, {:admitted, reserved.request, attempt})

             receive do
               :finalize ->
                 try do
                   Accounting.finalize_request(reserved.request, attempt, %{
                     before_finalize: fn ->
                       raise DBConnection.ConnectionError,
                         message: "synthetic database connection failure"
                     end
                   })
                 rescue
                   DBConnection.ConnectionError -> send(parent, :finalization_failed)
                 end
             end
           end}
        )

      monitor = Process.monitor(pid)
      assert_receive {:admitted, request, attempt}, 15_000

      assert {:error, %{code: :api_key_concurrency_limit_exceeded}} =
               Accounting.reserve(setup.auth, setup.model, %{
                 "model" => setup.model.exposed_model_id
               })

      owner = InstancePresence.local_identity()

      session =
        Repo.insert!(%CodexSession{
          pool_id: setup.pool.id,
          api_key_id: setup.api_key.id,
          session_key: Ecto.UUID.generate(),
          status: "active",
          owner_instance_id: owner.node_name,
          owner_instance_boot_id: owner.boot_id,
          owner_lease_token: Ecto.UUID.generate(),
          last_heartbeat_at: now,
          owner_lease_expires_at: DateTime.add(now, 3600)
        })

      turn =
        Repo.insert!(%CodexTurn{
          codex_session_id: session.id,
          request_id: request.id,
          turn_sequence: 1,
          transport_kind: unquote(transport),
          status: "in_progress",
          started_at: now
        })

      session = Repo.reload!(session)

      assert RuntimeCleanup.active_runtime_request?(request, now, [])
      assert ExecutionIdentity.status(attempt) == :alive

      assert {:ok, %{dead_execution_attempts_recovered: 0}} =
               DeadExecutionRecovery.recover(DateTime.add(now, 1), minimum_age_seconds: 0)

      send(pid, :finalize)
      assert_receive :finalization_failed, 15_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 15_000
      assert Repo.reload!(attempt).status == "in_progress"
      assert ExecutionIdentity.status(attempt) == :dead
      assert RuntimeCleanup.active_runtime_request?(request, now, [])
      CodexPooler.ExecutionProofSupport.publish_terminal!(attempt)

      assert {:ok, %{dead_execution_attempts_recovered: 0}} =
               DeadExecutionRecovery.recover(now, minimum_age_seconds: 120)

      for stale <- [
            %{attempt | replay_generation: attempt.replay_generation + 1},
            %{attempt | owner_execution_id: Ecto.UUID.generate()},
            %{attempt | owner_instance_id: "another@example.invalid"},
            %{attempt | owner_instance_boot_id: Ecto.UUID.generate()},
            %{attempt | owner_process_id: "<0.999999.0>"}
          ] do
        assert {:ok, :noop} =
                 Accounting.RequestLifecycle.recover_dead_execution(request, stale, now)
      end

      assert {:ok, %{dead_execution_attempts_recovered: 1}} =
               DeadExecutionRecovery.recover(DateTime.add(now, 1), minimum_age_seconds: 0)

      assert %Request{status: "failed", usage_status: "usage_unknown"} = Repo.reload!(request)
      assert %Attempt{status: "failed", usage_status: "usage_unknown"} = Repo.reload!(attempt)
      assert Repo.reload!(turn).status == "interrupted"
      assert Repo.reload!(session) == session

      assert {:ok, :noop} =
               Accounting.RequestLifecycle.recover_dead_execution(request, attempt, now)

      assert {:ok, %{dead_execution_attempts_recovered: 0}} =
               DeadExecutionRecovery.recover(DateTime.add(now, 1), minimum_age_seconds: 0)

      assert Enum.sort(Enum.map(Accounting.list_ledger_entries_for_request(request.id), & &1.entry_kind)) == ["release", "reservation", "settlement"]

      assert {:ok, _} =
               Accounting.reserve(setup.auth, setup.model, %{
                 "model" => setup.model.exposed_model_id
               })
    end
  end
end
