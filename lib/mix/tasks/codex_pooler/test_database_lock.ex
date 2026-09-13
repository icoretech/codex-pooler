defmodule CodexPooler.MixTasks.TestDatabaseLock do
  @moduledoc false

  @lock_namespace "codex_pooler_test_runner"
  @lock_database "postgres"
  @lock_query "SELECT pg_advisory_lock(hashtext($1), hashtext($2))"
  @unlock_query "SELECT pg_advisory_unlock(hashtext($1), hashtext($2))"

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

  @spec with_lock!(keyword(), (-> term())) :: term()
  def with_lock!(repo_config, fun) when is_list(repo_config) and is_function(fun, 0) do
    lock_params = repo_config |> Keyword.fetch!(:database) |> lock_params()
    conn = start_maintenance_connection!(repo_config)

    try do
      Postgrex.query!(conn, @lock_query, lock_params, timeout: :infinity)
      fun.()
    after
      unlock(conn, lock_params)
      stop_maintenance_connection(conn)
    end
  end

  @doc """
  The advisory lock keys a `codex_pooler.test` run holds for `database` while it resets and uses it.
  """
  @spec lock_params(String.t()) :: [String.t()]
  def lock_params(database) when is_binary(database), do: [@lock_namespace, database]

  @doc """
  Connects to the maintenance database of the configured test server, never the test database.
  """
  @spec start_maintenance_connection!(keyword()) :: pid()
  def start_maintenance_connection!(repo_config) when is_list(repo_config) do
    {:ok, _started} = Application.ensure_all_started(:postgrex)

    repo_config
    |> lock_connection_config()
    |> Postgrex.start_link()
    |> case do
      {:ok, conn} ->
        conn

      {:error, _reason} ->
        raise "failed to start test database lock connection"
    end
  end

  defp lock_connection_config(repo_config) do
    repo_config
    |> Keyword.take(@connection_keys)
    |> Keyword.put(:database, lock_database(repo_config))
  end

  defp lock_database(repo_config) do
    Keyword.get(repo_config, :maintenance_database) || @lock_database
  end

  defp unlock(conn, lock_params) do
    if Process.alive?(conn) do
      Postgrex.query(conn, @unlock_query, lock_params, timeout: 15_000)
    end

    :ok
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  @spec stop_maintenance_connection(pid()) :: :ok
  def stop_maintenance_connection(conn) do
    if Process.alive?(conn) do
      GenServer.stop(conn)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end
end
