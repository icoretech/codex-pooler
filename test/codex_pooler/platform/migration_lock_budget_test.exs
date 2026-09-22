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

  # A migration connection (and so a watcher) logged in as a role without superuser or
  # pg_read_all_stats, like the production migration role; its credentials come from the
  # application environment so that `config/0`, which the watcher reads, sees them too.
  defmodule UnprivilegedRepo do
    use Ecto.Repo, otp_app: :codex_pooler, adapter: Ecto.Adapters.Postgres

    @impl true
    def init(_type, config) do
      connection = Keyword.take(CodexPooler.Repo.config(), [:hostname, :port, :database, :socket_dir])
      {:ok, config |> Keyword.merge(connection) |> Keyword.merge(pool_size: 2, parameters: [application_name: "migration_lock_budget_unprivileged"])}
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
    assert message =~ ~r/pid=#{holder_pid} role="[^"]+" application_name="#{context.holder_name}"/
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

  # findings#255 row 255-63: production runs migrations as the application role, which is neither
  # superuser nor a member of pg_read_all_stats, so a blocker of another role (a backup or a psql
  # session run as the superuser) has its state, transaction start and snapshot hidden.
  test "names a blocker of another database role as hidden and says why", context do
    %{repo: repo, table: table, index: index} = unprivileged_migration_target!()
    %{holder: holder, pid: holder_pid} = hold!(context.holder_name, ["SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", "SELECT 1"])

    error =
      assert_raise MigrationLockBudget.Error, fn ->
        MigrationLockBudget.run(
          repo,
          fn -> repo.query!("CREATE INDEX CONCURRENTLY #{index} ON #{table} (id)", [], log: false, timeout: :infinity) end,
          lock_wait_ms: @holder_budget_ms,
          transaction_wait_ms: 400,
          poll_interval_ms: 50
        )
      end

    assert error.reason == :transaction_wait
    assert [%{pid: ^holder_pid, visibility: :hidden, state: nil, transaction_age_s: nil, holds_snapshot: true} = blocker] = error.blockers
    assert blocker.application_name == context.holder_name

    message = Exception.message(error)
    assert message =~ "pid=#{holder_pid} role=\"#{blocker.role}\" application_name=\"#{context.holder_name}\""
    assert message =~ "backend_type=hidden state=hidden transaction_age_s=hidden holds_snapshot=true"
    assert message =~ "grant pg_read_all_stats to the migration role"
    refute message =~ "state=\"unknown\""
    send(holder, :release)
    await_holder_released!(holder)
  end

  # findings#255 row 255-61: the watcher's cancel must land only on the wait it sampled. A waiter
  # session stands in for the migration backend: it waits for a table lock, then (once the holder
  # releases) runs its next statement, which a late unconditional cancel would interrupt.
  test "a cancel for a wait that already ended leaves the backend's next statement alone", context do
    %{holder: holder} = hold!(context.holder_name, ["LOCK TABLE #{context.table} IN SHARE MODE"])
    %{waiter: waiter, pid: waiter_pid} = wait_then_sleep!(context.table)
    sampled = sampled_wait!(waiter_pid)

    send(holder, :release)
    await_holder_released!(holder)
    assert_receive {:lock_acquired, ^waiter}, @holder_budget_ms

    with_watch_conn(fn conn ->
      assert MigrationLockBudget.cancel_if_still_waiting(conn, waiter_pid, sampled) == :not_waiting
    end)

    assert_receive {:next_statement, ^waiter, :completed}, @holder_budget_ms
  end

  test "a cancel for the wait still in progress interrupts it", context do
    %{holder: holder} = hold!(context.holder_name, ["LOCK TABLE #{context.table} IN SHARE MODE"])
    %{waiter: waiter, pid: waiter_pid} = wait_then_sleep!(context.table)
    sampled = sampled_wait!(waiter_pid)

    with_watch_conn(fn conn ->
      assert MigrationLockBudget.cancel_if_still_waiting(conn, waiter_pid, %{sampled | waitstart: "2000-01-01 00:00:00+00"}) == :not_waiting
      assert MigrationLockBudget.cancel_if_still_waiting(conn, waiter_pid, sampled) == :canceled
    end)

    assert_receive {:lock_result, ^waiter, :query_canceled}, @holder_budget_ms
    send(holder, :release)
    await_holder_released!(holder)
  end

  # A session that waits for an EXCLUSIVE lock on `table`, reports whether the wait ended in a
  # cancel, and after acquiring it runs one more statement (a short sleep) and reports how that
  # statement ended.
  defp wait_then_sleep!(table) do
    test = self()
    {:ok, conn} = Postgrex.start_link(connect_options("migration_lock_budget_waiter"))
    Process.unlink(conn)
    on_exit(fn -> if Process.alive?(conn), do: GenServer.stop(conn) end)

    waiter = spawn(fn -> run_waiter(conn, table, test) end)

    receive do
      {:waiter_pid, ^waiter, pid} -> %{waiter: waiter, pid: pid}
    after
      @holder_budget_ms -> flunk("waiter session did not start")
    end
  end

  # A throwaway login role without privileges, a table it owns (only the owner may index it) and
  # `UnprivilegedRepo` started as that role; everything is dropped when the test ends.
  defp unprivileged_migration_target! do
    suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    role = "migration_lock_budget_role_#{suffix}"
    password = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    table = "migration_lock_budget_owned_#{suffix}"

    on_exit(fn ->
      Application.delete_env(:codex_pooler, UnprivilegedRepo)
      {:ok, conn} = Postgrex.start_link(connect_options("migration_lock_budget_cleanup"))

      try do
        Postgrex.query!(conn, "DROP TABLE IF EXISTS #{table}", [])

        Postgrex.query!(
          conn,
          "DO $$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{role}') THEN EXECUTE 'DROP OWNED BY #{role}'; END IF; END $$",
          []
        )

        Postgrex.query!(conn, "DROP ROLE IF EXISTS #{role}", [])
      after
        GenServer.stop(conn)
      end
    end)

    MigrationRepo.query!("CREATE ROLE #{role} LOGIN NOSUPERUSER NOINHERIT PASSWORD '#{password}'", [], log: false)
    MigrationRepo.query!("GRANT USAGE, CREATE ON SCHEMA public TO #{role}", [], log: false)
    MigrationRepo.query!("CREATE TABLE #{table} (id bigint)", [], log: false)
    MigrationRepo.query!("ALTER TABLE #{table} OWNER TO #{role}", [], log: false)
    Application.put_env(:codex_pooler, UnprivilegedRepo, username: role, password: password)
    start_supervised!(UnprivilegedRepo)

    [[false, false]] =
      UnprivilegedRepo.query!("SELECT rolsuper, pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER') FROM pg_roles WHERE rolname = current_user", [], log: false).rows

    %{repo: UnprivilegedRepo, table: table, index: "#{table}_id_idx"}
  end

  defp run_waiter(conn, table, test) do
    [[pid]] = Postgrex.query!(conn, "SELECT pg_backend_pid()", []).rows
    send(test, {:waiter_pid, self(), pid})
    Postgrex.transaction(conn, &lock_then_sleep(&1, table, test), timeout: :infinity)
  end

  defp lock_then_sleep(tx, table, test) do
    case Postgrex.query(tx, "LOCK TABLE #{table} IN EXCLUSIVE MODE", []) do
      {:ok, _result} ->
        send(test, {:lock_acquired, self()})
        send(test, {:next_statement, self(), statement_outcome(Postgrex.query(tx, "SELECT pg_sleep(0.6)", []))})

      {:error, %Postgrex.Error{postgres: %{code: code}}} ->
        send(test, {:lock_result, self(), code})
        Postgrex.rollback(tx, code)
    end
  end

  defp statement_outcome({:ok, _result}), do: :completed
  defp statement_outcome({:error, %Postgrex.Error{postgres: %{code: code}}}), do: code

  # The waiter's lock wait as the watcher samples it, once PostgreSQL has recorded its start.
  defp sampled_wait!(backend_pid, attempts \\ 100) do
    rows =
      MigrationRepo.query!(
        "SELECT l.locktype, coalesce(l.virtualxid, ''), coalesce(l.waitstart::text, '') FROM pg_locks l WHERE l.pid = $1 AND NOT l.granted",
        [backend_pid],
        log: false
      ).rows

    case rows do
      [[locktype, target, waitstart]] when waitstart != "" ->
        %{locktype: locktype, target: target, waitstart: waitstart}

      _not_yet when attempts > 0 ->
        Process.sleep(20)
        sampled_wait!(backend_pid, attempts - 1)

      _never ->
        flunk("waiter session never waited for the lock")
    end
  end

  defp with_watch_conn(fun) do
    {:ok, conn} = Postgrex.start_link(connect_options("codex_pooler_migrate_watch"))

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
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
