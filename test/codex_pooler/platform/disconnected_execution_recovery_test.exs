defmodule CodexPooler.Platform.DisconnectedExecutionRecoveryTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.RequestLifecycle.DeadExecutionRecovery
  alias CodexPooler.Platform.ExecutionIdentity
  alias CodexPooler.Repo
  alias CodexPooler.UnboxedFixture

  # Failure-detection budget for each call into the peer. `:peer.call/4`
  # defaults to 5 s, and the peer's bootstrap (application starts and a fresh
  # PostgreSQL pool) outgrew it on a loaded host (findings#206 row 206-184).
  @peer_call_budget_ms 15_000

  for database <- [
        :available,
        :unavailable,
        :uncertain_commit,
        :cleanup_failure,
        :candidate_failure
      ] do
    @tag slow: "boots an isolated BEAM peer and exercises PostgreSQL proof publication and recovery"
    test "an owner without distribution publishes task death with its database #{database}" do
      %{user: owner} = CodexPooler.AccountsFixtures.committed_bootstrap_owner_fixture!()
      slug = "disconnected-execution-#{Ecto.UUID.generate()}"

      UnboxedFixture.register_unboxed_cleanup!(fn ->
        ids = Repo.all(from p in CodexPooler.Pools.Pool, where: p.slug == ^slug, select: p.id)
        CodexPooler.PoolerFixtures.delete_committed_pools!(ids)

        Repo.delete_all(
          from identity in CodexPooler.Upstreams.Schemas.UpstreamIdentity,
            where: identity.account_label == ^slug
        )
      end)

      setup =
        UnboxedFixture.run_unboxed(fn ->
          pool =
            CodexPooler.PoolerFixtures.pool_fixture(%{slug: slug, created_by_user_id: owner.id})

          %{api_key: key} =
            CodexPooler.PoolerFixtures.active_api_key_fixture(pool, %{
              created_by_user_id: owner.id
            })

          model = CodexPooler.PoolerFixtures.model_fixture(pool)

          %{assignment: assignment} =
            CodexPooler.PoolerFixtures.upstream_assignment_fixture(pool, %{account_label: slug})

          %{pool: pool, auth: %{pool: pool, api_key: key}, model: model, assignment: assignment}
        end)

      parent = self()

      peer_owner =
        start_supervised!(
          {Task,
           fn ->
             {:ok, peer, _node} =
               :peer.start_link(%{connection: :standard_io, args: [~c"+S", ~c"2:2"]})

             send(parent, {:peer, peer})

             receive do
               :stop -> :peer.stop(peer)
             end
           end}
        )

      assert_receive {:peer, peer}, 15_000
      peer_os_pid = :peer.call(peer, :os, :getpid, [], @peer_call_budget_ms) |> List.to_string()

      on_exit(fn ->
        assert not Process.alive?(peer)
        assert_peer_process_absent(peer_os_pid, System.monotonic_time(:millisecond) + 15_000)
      end)

      :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()], @peer_call_budget_ms)

      :ok =
        :peer.call(peer, CodexPooler.DisconnectedExecutionPeer, :bootstrap, [Application.get_all_env(:codex_pooler), Repo.config()], @peer_call_budget_ms)

      identity = :peer.call(peer, CodexPooler.Platform.InstancePresence.Identity, :local, [], @peer_call_budget_ms)

      UnboxedFixture.register_unboxed_cleanup!(fn ->
        assert not Process.alive?(peer)
        assert_peer_process_absent(peer_os_pid, System.monotonic_time(:millisecond) + 15_000)

        assert_peer_connections_absent(
          identity.boot_id,
          System.monotonic_time(:millisecond) + 15_000
        )

        Repo.delete_all(
          from p in CodexPooler.Platform.ExecutionTerminalProof,
            where:
              p.owner_instance_id == ^identity.node_name and
                p.owner_instance_boot_id == ^identity.boot_id
        )
      end)

      assert [] == :peer.call(peer, Node, :list, [], @peer_call_budget_ms)
      refute :peer.call(peer, Node, :alive?, [], @peer_call_budget_ms)

      {request, attempt, worker} =
        :peer.call(peer, CodexPooler.DisconnectedExecutionPeer, :start, [setup], @peer_call_budget_ms)

      now = DateTime.add(DateTime.utc_now(), 121)
      assert ExecutionIdentity.status(attempt) == :unknown

      assert {:ok, %{dead_execution_attempts_recovered: 0}} =
               UnboxedFixture.run_unboxed(fn -> DeadExecutionRecovery.recover(now) end)

      if unquote(database) == :unavailable do
        assert %{queued: 1, warned: true, publisher_alive: true} =
                 :peer.call(peer, CodexPooler.DisconnectedExecutionPeer, :finish_without_database, [worker, attempt], @peer_call_budget_ms)

        assert {:ok, %{dead_execution_attempts_recovered: 0}} =
                 UnboxedFixture.run_unboxed(fn -> DeadExecutionRecovery.recover(now) end)

        :ok =
          :peer.call(peer, CodexPooler.DisconnectedExecutionPeer, :restore_database, [attempt], @peer_call_budget_ms)
      else
        if unquote(database) == :uncertain_commit do
          assert %{
                   committed_before_ack: true,
                   pending_before_restart: 1,
                   pending_after_restart: 0
                 } =
                   :peer.call(
                     peer,
                     CodexPooler.DisconnectedExecutionPeer,
                     :finish_with_uncertain_commit,
                     [worker, attempt],
                     20_000
                   )
        else
          :ok =
            :peer.call(peer, CodexPooler.DisconnectedExecutionPeer, :finish, [worker, attempt], @peer_call_budget_ms)
        end
      end

      assert [] == :peer.call(peer, Node, :list, [], @peer_call_budget_ms)

      handler = {__MODULE__, make_ref()}
      on_exit(fn -> :telemetry.detach(handler) end)

      :ok =
        :telemetry.attach(
          handler,
          [:codex_pooler, :gateway, :stream, :outcome],
          &__MODULE__.capture_outcome/4,
          parent
        )

      case unquote(database) do
        :cleanup_failure ->
          UnboxedFixture.register_unboxed_cleanup!(fn ->
            Repo.query!("ALTER TABLE IF EXISTS execution_test_hidden_presences RENAME TO instance_presences")
          end)

          UnboxedFixture.run_unboxed(fn ->
            Repo.query!("ALTER TABLE instance_presences RENAME TO execution_test_hidden_presences")
          end)

          {result, logs} =
            ExUnit.CaptureLog.with_log(fn ->
              UnboxedFixture.run_unboxed(fn -> CodexPooler.Jobs.cleanup_runtime_state(now) end)
            end)

          assert {:error, {:runtime_state_cleanup_steps_failed, failures, summary}} = result
          assert :absent_instances in failures
          assert summary.dead_execution_attempts_recovered == 1
          assert logs =~ "runtime state cleanup completed with failures"

          UnboxedFixture.run_unboxed(fn ->
            Repo.query!("ALTER TABLE execution_test_hidden_presences RENAME TO instance_presences")
          end)

        :candidate_failure ->
          {_other_request, other_attempt, other_worker} =
            :peer.call(peer, CodexPooler.DisconnectedExecutionPeer, :start, [setup], @peer_call_budget_ms)

          :ok =
            :peer.call(peer, CodexPooler.DisconnectedExecutionPeer, :finish, [other_worker, other_attempt], @peer_call_budget_ms)

          UnboxedFixture.register_unboxed_cleanup!(fn ->
            Repo.query!("DROP TRIGGER IF EXISTS execution_test_fail_finalization ON attempts")
            Repo.query!("DROP FUNCTION IF EXISTS execution_test_fail_finalization()")
          end)

          UnboxedFixture.run_unboxed(fn ->
            Repo.update_all(from(a in CodexPooler.Accounting.Attempt, where: a.id == ^attempt.id),
              set: [owner_execution_checked_at: nil]
            )

            Repo.query!("""
            CREATE FUNCTION execution_test_fail_finalization() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF NEW.id = '#{attempt.id}'::uuid AND NEW.status = 'failed' THEN
                RAISE EXCEPTION 'synthetic execution finalization failure';
              END IF;
              RETURN NEW;
            END $$
            """)

            Repo.query!("CREATE TRIGGER execution_test_fail_finalization BEFORE UPDATE ON attempts FOR EACH ROW EXECUTE FUNCTION execution_test_fail_finalization()")
          end)

          assert {:error, {:dead_execution_candidates_failed, [_failure]}, %{dead_execution_attempts_recovered: 1}} =
                   UnboxedFixture.run_unboxed(fn ->
                     DeadExecutionRecovery.recover(DateTime.add(DateTime.utc_now(), 121))
                   end)

          assert UnboxedFixture.run_unboxed(fn -> Repo.reload!(other_attempt).status end) ==
                   "failed"

          assert UnboxedFixture.run_unboxed(fn -> Repo.reload!(attempt).status end) ==
                   "in_progress"

          assert UnboxedFixture.run_unboxed(fn ->
                   Repo.reload!(attempt).owner_execution_checked_at
                 end)

          UnboxedFixture.run_unboxed(fn ->
            Repo.query!("DROP TRIGGER execution_test_fail_finalization ON attempts")
          end)

          assert {:ok, %{dead_execution_attempts_recovered: 1}} =
                   UnboxedFixture.run_unboxed(fn -> DeadExecutionRecovery.recover(now) end)

        _ ->
          assert {:ok, %{dead_execution_attempts_recovered: 1}} =
                   UnboxedFixture.run_unboxed(fn ->
                     Process.put(:execution_test_observer, parent)
                     DeadExecutionRecovery.recover(now)
                   end)

          assert_receive {:scheduled_outcome,
                          %{
                            outcome: "interrupted",
                            downstream_transport: "http_sse",
                            upstream_transport: "http_sse"
                          }, false}
      end

      assert {:ok, %{dead_execution_attempts_recovered: 0}} =
               UnboxedFixture.run_unboxed(fn ->
                 Process.put(:execution_test_observer, parent)
                 DeadExecutionRecovery.recover(now)
               end)

      refute_received {:scheduled_outcome, _, _}

      assert UnboxedFixture.run_unboxed(fn -> Repo.reload!(request).last_error_code end) ==
               "dead_execution_recovered"

      assert UnboxedFixture.run_unboxed(fn ->
               Accounting.list_ledger_entries_for_request(request.id)
               |> Enum.map(& &1.entry_kind)
               |> Enum.sort()
             end) == ["release", "reservation", "settlement"]

      monitor = Process.monitor(peer_owner)
      send(peer_owner, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^peer_owner, :normal}, 15_000
      assert_peer_process_absent(peer_os_pid, System.monotonic_time(:millisecond) + 15_000)

      CodexPooler.TestDiagnostics.puts("disconnected execution: distribution=false live_skipped=true terminal_recovered_once=true peer_process_absent=true")
    end
  end

  @doc false
  def capture_outcome(_event, _measurements, metadata, parent) do
    if Process.get(:execution_test_observer) == parent,
      do: send(parent, {:scheduled_outcome, metadata, Repo.in_transaction?()})
  end

  defp assert_peer_process_absent(pid, deadline) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} ->
        assert System.monotonic_time(:millisecond) < deadline,
               "owned peer OS process survived shutdown"

        receive do
        after
          10 -> :ok
        end

        assert_peer_process_absent(pid, deadline)

      {_output, _absent} ->
        :ok
    end
  end

  defp assert_peer_connections_absent(boot_id, deadline) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM pg_stat_activity WHERE application_name = $1", [
        "execution_peer_" <> boot_id
      ])

    if count > 0 do
      assert System.monotonic_time(:millisecond) < deadline,
             "owned peer database connections survived shutdown"

      receive do
      after
        10 -> :ok
      end

      assert_peer_connections_absent(boot_id, deadline)
    end
  end
end
