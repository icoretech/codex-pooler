defmodule CodexPooler.Release.MigrationLockBudgetTest do
  # Concurrent index statements cannot run inside the sandbox transaction, so these tests use a
  # repo of their own over the test database, a scratch table per test and real PostgreSQL
  # sessions that hold the snapshot or lock the migration has to wait for.
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  import ExUnit.CaptureLog

  alias CodexPooler.Release.MigrationLockBudget

  @connect_keys [:hostname, :port, :username, :password, :database, :socket_dir]
  @holder_budget_ms 15_000

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :codex_pooler, adapter: Ecto.Adapters.Postgres

    @impl true
    def init(_type, config) do
      connection = Keyword.take(CodexPooler.Repo.config(), [:hostname, :port, :username, :password, :database, :socket_dir])
      {:ok, config |> Keyword.merge(connection) |> Keyword.merge(pool_size: 2, parameters: [application_name: "migration_lock_budget_test"])}
    end
  end

  # The watcher reads `config/0` (the `:runtime` init) for its own connection while the pool starts
  # from the `:supervisor` init: pointing only the former at a closed port leaves the migration
  # connection working and the watcher unable to start.
  defmodule UnwatchedRepo do
    use Ecto.Repo, otp_app: :codex_pooler, adapter: Ecto.Adapters.Postgres

    @impl true
    def init(type, config) do
      connection = Keyword.take(CodexPooler.Repo.config(), [:hostname, :port, :username, :password, :database, :socket_dir])
      connection = if type == :runtime, do: Keyword.put(connection, :port, 1), else: connection
      {:ok, config |> Keyword.merge(connection) |> Keyword.merge(pool_size: 2, parameters: [application_name: "migration_lock_budget_test"])}
    end
  end

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    table = "migration_lock_budget_probe_#{suffix}"

    # Registered first so it runs last, after every holder session has ended.
    on_exit(fn -> drop_table!(table) end)

    start_supervised!(MigrationRepo)
    MigrationRepo.query!("CREATE TABLE #{table} (id bigint)", [], log: false)

    %{table: table, index: "#{table}_id_idx", holder_name: "migration_lock_budget_holder_#{suffix}"}
  end

  test "waits out a transaction holding an older snapshot past the table-lock budget and builds the index", context do
    %{holder: holder} = hold!(context.holder_name, ["SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", "SELECT 1"])
    Process.send_after(holder, :release, 600)
    started = System.monotonic_time(:millisecond)

    assert :built =
             MigrationLockBudget.run(
               MigrationRepo,
               fn ->
                 MigrationRepo.query!("CREATE INDEX CONCURRENTLY #{context.index} ON #{context.table} (id)", [], log: false, timeout: :infinity)
                 :built
               end,
               lock_wait_ms: 200,
               transaction_wait_ms: @holder_budget_ms,
               poll_interval_ms: 50
             )

    # The build finished only after the holder committed, three table-lock budgets later.
    assert System.monotonic_time(:millisecond) - started >= 550
    assert index_state(context.index) == [[true, true]]
    await_holder_released!(holder)
  end

  test "gives up on the wait for older transactions at its budget and names the session, never its query", context do
    %{holder: holder, pid: holder_pid} =
      hold!(context.holder_name, ["SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", "SELECT 'migration-lock-budget-query-marker'"])

    started = System.monotonic_time(:millisecond)

    error =
      assert_raise MigrationLockBudget.Error, fn ->
        MigrationLockBudget.run(
          MigrationRepo,
          fn -> MigrationRepo.query!("CREATE INDEX CONCURRENTLY #{context.index} ON #{context.table} (id)", [], log: false, timeout: :infinity) end,
          lock_wait_ms: @holder_budget_ms,
          transaction_wait_ms: 400,
          poll_interval_ms: 50
        )
      end

    assert System.monotonic_time(:millisecond) - started < @holder_budget_ms
    assert error.reason == :transaction_wait
    assert error.postgres_code == :query_canceled
    assert error.waited_ms >= 400
    assert error.budget_ms == 400

    assert [%{pid: ^holder_pid, state: "idle in transaction", holds_snapshot: true} = blocker] = error.blockers
    assert blocker.application_name == context.holder_name
    assert blocker.backend_type == "client backend"
    assert is_integer(blocker.transaction_age_s)

    message = Exception.message(error)
    assert message =~ "pid=#{holder_pid} application_name=\"#{context.holder_name}\""
    assert message =~ "holds_snapshot=true"
    assert message =~ "does not block application reads or writes"
    refute message =~ "migration-lock-budget-query-marker"

    # The interrupted build leaves an INVALID index for the migration's convergence step.
    assert index_state(context.index) == [[false, true]]
    send(holder, :release)
    await_holder_released!(holder)
  end

  test "cancels a table lock wait at the short budget and names the lock holder", context do
    %{holder: holder, pid: holder_pid} = hold!(context.holder_name, ["LOCK TABLE #{context.table} IN SHARE MODE"])
    started = System.monotonic_time(:millisecond)

    error =
      assert_raise MigrationLockBudget.Error, fn ->
        MigrationLockBudget.run(
          MigrationRepo,
          fn -> MigrationRepo.query!("CREATE INDEX CONCURRENTLY #{context.index} ON #{context.table} (id)", [], log: false, timeout: :infinity) end,
          lock_wait_ms: 200,
          transaction_wait_ms: @holder_budget_ms,
          poll_interval_ms: 50
        )
      end

    assert System.monotonic_time(:millisecond) - started < @holder_budget_ms
    assert error.reason == :lock_wait
    assert error.postgres_code == :query_canceled
    assert error.waited_ms >= 200
    assert [%{pid: ^holder_pid, application_name: holder_name}] = error.blockers
    assert holder_name == context.holder_name
    assert Exception.message(error) =~ "for a table or row lock"
    assert index_state(context.index) == []
    send(holder, :release)
    await_holder_released!(holder)
  end

  test "returns the result, passes other errors through and restores the connection's lock_timeout" do
    MigrationRepo.checkout(fn ->
      MigrationRepo.query!("SET lock_timeout = '1234ms'", [], log: false)

      assert MigrationLockBudget.run(MigrationRepo, fn -> show_lock_timeout() end, poll_interval_ms: 50) == "310s"
      assert show_lock_timeout() == "1234ms"

      assert_raise RuntimeError, "not a lock problem", fn ->
        MigrationLockBudget.run(MigrationRepo, fn -> raise "not a lock problem" end, poll_interval_ms: 50)
      end

      assert show_lock_timeout() == "1234ms"

      assert %Postgrex.Error{postgres: %{code: :undefined_table}} =
               assert_raise(Postgrex.Error, fn ->
                 MigrationLockBudget.run(MigrationRepo, fn -> MigrationRepo.query!("SELECT 1 FROM migration_lock_budget_absent", [], log: false) end, poll_interval_ms: 50)
               end)

      assert show_lock_timeout() == "1234ms"
    end)
  end

  test "without a watcher every wait keeps the short lock_timeout and the open transactions are listed", context do
    stop_supervised!(MigrationRepo)
    start_supervised!(UnwatchedRepo)

    %{holder: holder, pid: holder_pid} = hold!(context.holder_name, ["SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", "SELECT 1"])

    {error, log} =
      with_log(fn ->
        assert_raise MigrationLockBudget.Error, fn ->
          MigrationLockBudget.run(
            UnwatchedRepo,
            fn -> UnwatchedRepo.query!("CREATE INDEX CONCURRENTLY #{context.index} ON #{context.table} (id)", [], log: false, timeout: :infinity) end,
            lock_wait_ms: 300,
            transaction_wait_ms: @holder_budget_ms,
            poll_interval_ms: 50
          )
        end
      end)

    assert log =~ "migration lock watcher did not start"
    assert error.reason == :unclassified
    assert error.postgres_code == :lock_not_available
    assert Enum.any?(error.blockers, &match?(%{pid: ^holder_pid, holds_snapshot: true}, &1))
    send(holder, :release)
    await_holder_released!(holder)
  end

  defp show_lock_timeout do
    [[value]] = MigrationRepo.query!("SHOW lock_timeout", [], log: false).rows
    value
  end

  # A session on its own connection that runs `statements` in a transaction and keeps it open until
  # it receives `:release`.
  defp hold!(application_name, statements) do
    test = self()
    {:ok, conn} = Postgrex.start_link(connect_options(application_name))
    Process.unlink(conn)
    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)

    holder =
      spawn(fn ->
        Postgrex.transaction(
          conn,
          fn tx ->
            Enum.each(statements, &Postgrex.query!(tx, &1, []))
            [[pid]] = Postgrex.query!(tx, "SELECT pg_backend_pid()", []).rows
            send(test, {:held, self(), pid})

            receive do
              :release -> :ok
            end
          end,
          timeout: :infinity
        )

        send(test, {:released, self()})
      end)

    on_exit(fn -> send(holder, :release) end)

    receive do
      {:held, ^holder, pid} -> %{holder: holder, pid: pid}
    after
      @holder_budget_ms -> flunk("holder session did not open its transaction")
    end
  end

  defp await_holder_released!(holder) do
    receive do
      {:released, ^holder} -> :ok
    after
      @holder_budget_ms -> flunk("holder session did not end its transaction")
    end
  end

  defp index_state(index) do
    MigrationRepo.query!(
      "SELECT i.indisvalid, i.indisready FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid WHERE c.relname = $1",
      [index],
      log: false
    ).rows
  end

  defp drop_table!(table) do
    {:ok, conn} = Postgrex.start_link(connect_options("migration_lock_budget_cleanup"))

    try do
      Postgrex.query!(conn, "DROP TABLE IF EXISTS #{table}", [])
    after
      GenServer.stop(conn)
    end
  end

  defp connect_options(application_name) do
    CodexPooler.Repo.config()
    |> Keyword.take(@connect_keys)
    |> Keyword.merge(backoff_type: :stop, parameters: [application_name: application_name])
  end
end
