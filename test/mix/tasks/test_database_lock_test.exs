defmodule CodexPooler.MixTasks.TestDatabaseLockTest do
  use ExUnit.Case, async: false

  alias CodexPooler.MixTasks.TestDatabaseLock
  alias CodexPooler.Repo

  @lock_namespace "codex_pooler_test_runner"
  @lock_database "postgres"
  @lock_wait_attempts 50
  @scenario_timeout_ms 5_000
  @detection_timeout_ms 15_000
  @connection_keys [
    :after_connect,
    :connect_timeout,
    :hostname,
    :password,
    :parameters,
    :port,
    :socket_dir,
    :socket_options,
    :ssl,
    :ssl_opts,
    :timeout,
    :types,
    :url,
    :username
  ]

  test "serializes concurrent callers for the configured test database" do
    parent = self()
    repo_config = Keyword.put(Repo.config(), :database, "codex_pooler_test_lock_regression")
    observer = start_lock_observer!(repo_config)

    on_exit(fn -> stop_lock_observer(observer) end)

    first =
      Task.async(fn ->
        TestDatabaseLock.with_lock!(repo_config, fn ->
          send(parent, :first_locked)

          receive do
            :release_first -> :first_released
          after
            @scenario_timeout_ms -> raise "timed out waiting to release first lock holder"
          end
        end)
      end)

    assert_receive :first_locked, @detection_timeout_ms

    second =
      Task.async(fn ->
        send(parent, :second_entering_lock)

        TestDatabaseLock.with_lock!(repo_config, fn ->
          send(parent, :second_locked)
          :second_released
        end)
      end)

    assert_receive :second_entering_lock, @detection_timeout_ms
    assert_advisory_lock_waiter!(observer, repo_config)

    send(first.pid, :release_first)

    assert Task.await(first, @detection_timeout_ms) == :first_released
    assert Task.await(second, @detection_timeout_ms) == :second_released
    assert_receive :second_locked, @detection_timeout_ms
  end

  test "does not serialize callers for different invocation databases" do
    parent = self()

    first_config =
      Keyword.put(
        Repo.config(),
        :database,
        configured_partition_database("0123456789abcdef", 1)
      )

    second_config =
      Keyword.put(
        Repo.config(),
        :database,
        configured_partition_database("fedcba9876543210", 1)
      )

    first =
      Task.async(fn ->
        TestDatabaseLock.with_lock!(first_config, fn ->
          send(parent, :first_distinct_lock_acquired)

          receive do
            :release_first_distinct_lock -> :first_distinct_lock_released
          after
            @scenario_timeout_ms -> raise "timed out waiting to release first distinct lock"
          end
        end)
      end)

    assert_receive :first_distinct_lock_acquired, @detection_timeout_ms

    second =
      Task.async(fn ->
        TestDatabaseLock.with_lock!(second_config, fn ->
          send(parent, :second_distinct_lock_acquired)
          :second_distinct_lock_released
        end)
      end)

    assert_receive :second_distinct_lock_acquired, @detection_timeout_ms
    send(first.pid, :release_first_distinct_lock)

    assert Task.await(first, @detection_timeout_ms) == :first_distinct_lock_released
    assert Task.await(second, @detection_timeout_ms) == :second_distinct_lock_released
  end

  defp assert_advisory_lock_waiter!(conn, repo_config, attempts \\ @lock_wait_attempts)

  defp assert_advisory_lock_waiter!(conn, repo_config, attempts) when attempts > 0 do
    if advisory_lock_waiter?(conn, repo_config) do
      :ok
    else
      receive do
      after
        20 -> assert_advisory_lock_waiter!(conn, repo_config, attempts - 1)
      end
    end
  end

  defp assert_advisory_lock_waiter!(_conn, repo_config, 0) do
    flunk(
      "expected a PostgreSQL advisory lock waiter for #{Keyword.fetch!(repo_config, :database)}"
    )
  end

  defp advisory_lock_waiter?(conn, repo_config) do
    %{rows: [[waiting?]]} =
      Postgrex.query!(
        conn,
        """
        SELECT EXISTS (
          SELECT 1
          FROM pg_locks
          WHERE locktype = 'advisory'
            AND classid = hashtext($1)::oid
            AND objid = hashtext($2)::oid
            AND NOT granted
        )
        """,
        [@lock_namespace, Keyword.fetch!(repo_config, :database)]
      )

    waiting?
  end

  defp start_lock_observer!(repo_config) do
    {:ok, _started} = Application.ensure_all_started(:postgrex)

    repo_config
    |> Keyword.take(@connection_keys)
    |> Keyword.put(:database, lock_database(repo_config))
    |> Postgrex.start_link()
    |> case do
      {:ok, conn} -> conn
      {:error, _reason} -> raise "failed to start test database lock observer"
    end
  end

  defp lock_database(repo_config) do
    Keyword.get(repo_config, :maintenance_database) || @lock_database
  end

  defp stop_lock_observer(conn) do
    if Process.alive?(conn) do
      GenServer.stop(conn)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp configured_partition_database(namespace, partition) do
    previous_namespace = System.get_env("CODEX_POOLER_TEST_RUN_NAMESPACE")
    previous_partition = System.get_env("MIX_TEST_PARTITION")

    System.put_env("CODEX_POOLER_TEST_RUN_NAMESPACE", namespace)
    System.put_env("MIX_TEST_PARTITION", Integer.to_string(partition))

    try do
      config = Config.Reader.read!("config/test.exs", env: :test)
      config[:codex_pooler][CodexPooler.Repo][:database]
    after
      restore_env("CODEX_POOLER_TEST_RUN_NAMESPACE", previous_namespace)
      restore_env("MIX_TEST_PARTITION", previous_partition)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
