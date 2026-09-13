defmodule CodexPooler.MixTasks.TestDatabasePruneTest do
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  alias CodexPooler.MixTasks.{TestDatabaseLock, TestDatabasePrune}
  alias CodexPooler.Repo

  @connection_keys [:hostname, :port, :username, :password, :socket_dir, :ssl, :socket_options]

  test "a configured namespaced partition database is run-scoped and the base databases are not" do
    assert TestDatabasePrune.run_scoped?(configured_database("0123456789abcdef", "1"))
    assert TestDatabasePrune.run_scoped?(configured_database("fedcba9876543210", "12"))

    for database <- [
          configured_database(nil, nil),
          configured_database(nil, "4"),
          configured_database("0123456789abcdef", nil),
          "codex_pooler_dev",
          "postgres",
          "codex_pooler_test_e239a0fc_0123456789abcdef_p0",
          "codex_pooler_test_e239a0fc_0123456789ABCDEF_p1",
          ~s(codex_pooler_test_e239a0fc_0123456789abcdef_p1"; DROP DATABASE postgres; --),
          nil
        ] do
      refute TestDatabasePrune.run_scoped?(database), "#{inspect(database)} must not be prunable"
    end
  end

  # Creates three real databases on the test server: which databases PostgreSQL lets a session drop
  # is the property under test, so it cannot be faked.
  test "drops an idle run-scoped database and keeps one a session holds or a test run has locked" do
    namespace = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    [idle, connected, locked] = for p <- ["1", "2", "3"], do: configured_database(namespace, p)
    admin = TestDatabaseLock.start_maintenance_connection!(Repo.config())

    on_exit(fn -> drop_databases!([idle, connected, locked]) end)

    for database <- [idle, connected, locked] do
      Postgrex.query!(admin, ~s(CREATE DATABASE "#{database}"), [])
    end

    {:ok, holder} =
      Repo.config()
      |> Keyword.take(@connection_keys)
      |> Keyword.put(:database, connected)
      |> Postgrex.start_link()

    # A connected session is what `pg_stat_activity` shows, so wait for a real round trip.
    Postgrex.query!(holder, "SELECT 1", [])

    runner = TestDatabaseLock.start_maintenance_connection!(Repo.config())

    on_exit(fn -> TestDatabaseLock.stop_maintenance_connection(runner) end)

    Postgrex.query!(
      runner,
      "SELECT pg_advisory_lock(hashtext($1), hashtext($2))",
      TestDatabaseLock.lock_params(locked)
    )

    # `postgres` exists but is not run-scoped, so naming it in `:only` must not make it a candidate.
    results =
      TestDatabasePrune.prune!(Repo.config(), only: [idle, connected, locked, "postgres"])

    assert Enum.sort(results) ==
             Enum.sort([{idle, :dropped}, {connected, :connected}, {locked, :runner_locked}])

    assert existing_databases(admin, [idle, connected, locked, "postgres"]) ==
             Enum.sort([connected, locked, "postgres"])

    TestDatabaseLock.stop_maintenance_connection(admin)
  end

  defp existing_databases(conn, names) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        "SELECT datname FROM pg_database WHERE datname = ANY($1) ORDER BY datname",
        [names]
      )

    List.flatten(rows)
  end

  defp drop_databases!(databases) do
    conn = TestDatabaseLock.start_maintenance_connection!(Repo.config())

    try do
      for database <- databases, TestDatabasePrune.run_scoped?(database) do
        Postgrex.query!(conn, ~s[DROP DATABASE IF EXISTS "#{database}" WITH (FORCE)], [])
      end
    after
      TestDatabaseLock.stop_maintenance_connection(conn)
    end
  end

  defp configured_database(namespace, partition) do
    previous =
      Map.new(
        ["CODEX_POOLER_TEST_RUN_NAMESPACE", "MIX_TEST_PARTITION"],
        &{&1, System.get_env(&1)}
      )

    restore = fn -> Enum.each(previous, fn {key, value} -> put_env(key, value) end) end

    # Also on_exit: the ExUnit timeout kills the test before `after` runs.
    on_exit(restore)

    put_env("CODEX_POOLER_TEST_RUN_NAMESPACE", namespace)
    put_env("MIX_TEST_PARTITION", partition)

    try do
      Config.Reader.read!("config/test.exs", env: :test)[:codex_pooler][Repo][:database]
    after
      restore.()
    end
  end

  defp put_env(key, nil), do: System.delete_env(key)
  defp put_env(key, value), do: System.put_env(key, value)
end
