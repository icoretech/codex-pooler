defmodule CodexPooler.MixTasks.TestDatabasePrune do
  @moduledoc false

  alias CodexPooler.MixTasks.TestDatabaseLock

  # A run namespace gives each invocation its own database, named by `config/test.exs` as
  # `codex_pooler_test_<base fingerprint>_<run namespace>_p<partition>`. Nothing else reuses such a
  # name, so a run killed before it drops its own database leaves it behind for good. The base
  # databases (`codex_pooler_test`, `codex_pooler_test<partition>`) never match: every serial run
  # reuses and resets them.
  @run_scoped_database ~r/\Acodex_pooler_test_[0-9a-f]{8}_[0-9a-f]{16}_p[1-9][0-9]*\z/
  @object_in_use "55006"

  @type outcome :: :dropped | :connected | :runner_locked

  @spec run_scoped?(term()) :: boolean()
  def run_scoped?(database) when is_binary(database),
    do: Regex.match?(@run_scoped_database, database)

  def run_scoped?(_database), do: false

  @doc """
  Drops every run-scoped test database on the configured server that nothing is using.

  A database is kept when a `codex_pooler.test` run holds its advisory lock (the run holds it from
  before its first drop until after its last) or when any session is connected to it. The drop
  itself runs without `FORCE`, so PostgreSQL refuses a database that gained a connection after
  the check instead of terminating it.

  `:only` restricts the candidates to the given names; names that are not run-scoped are ignored
  even when listed.
  """
  @spec prune!(keyword(), keyword()) :: [{String.t(), outcome()}]
  def prune!(repo_config, opts \\ []) when is_list(repo_config) and is_list(opts) do
    conn = TestDatabaseLock.start_maintenance_connection!(repo_config)

    try do
      conn
      |> run_scoped_databases(Keyword.get(opts, :only))
      |> Enum.map(fn database -> {database, prune_database(conn, database)} end)
    after
      TestDatabaseLock.stop_maintenance_connection(conn)
    end
  end

  defp run_scoped_databases(conn, only) do
    %{rows: rows} =
      Postgrex.query!(conn, "SELECT datname FROM pg_database ORDER BY datname", [])

    candidates = rows |> List.flatten() |> Enum.filter(&run_scoped?/1)

    case only do
      nil -> candidates
      names when is_list(names) -> Enum.filter(candidates, &(&1 in names))
    end
  end

  defp prune_database(conn, database) do
    lock_params = TestDatabaseLock.lock_params(database)

    %{rows: [[locked?]]} =
      Postgrex.query!(
        conn,
        "SELECT pg_try_advisory_lock(hashtext($1), hashtext($2))",
        lock_params
      )

    if locked? do
      try do
        drop_if_idle(conn, database)
      after
        Postgrex.query!(
          conn,
          "SELECT pg_advisory_unlock(hashtext($1), hashtext($2))",
          lock_params
        )
      end
    else
      :runner_locked
    end
  end

  defp drop_if_idle(conn, database) do
    %{rows: [[connections]]} =
      Postgrex.query!(
        conn,
        "SELECT count(*) FROM pg_stat_activity WHERE datname = $1",
        [database]
      )

    if connections > 0 do
      :connected
    else
      # `run_scoped?/1` admits only `[a-z0-9_]`, so the quoted identifier cannot be escaped.
      case Postgrex.query(conn, ~s(DROP DATABASE IF EXISTS "#{database}"), []) do
        {:ok, _result} -> :dropped
        {:error, %Postgrex.Error{postgres: %{pg_code: @object_in_use}}} -> :connected
        {:error, error} -> raise error
      end
    end
  end
end
