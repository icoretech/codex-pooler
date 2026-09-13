defmodule Mix.Tasks.CodexPooler.Test do
  @moduledoc """
  Resets and runs the test suite while holding the shared test database lock.

  A run-scoped database (`CODEX_POOLER_TEST_RUN_NAMESPACE` plus `MIX_TEST_PARTITION`) is dropped
  again when the run finishes, pass or fail, because no later run will ever reuse its name. The
  shared base databases are left for the next run to reset. Databases that killed runs leave
  behind are removed by `mix codex_pooler.test.prune_databases`.
  """

  use Mix.Task

  alias CodexPooler.MixTasks.{TestDatabaseLock, TestDatabasePrune}
  alias Mix.Tasks.Test

  @shortdoc "Resets the test database and runs tests under its shared lock"

  @impl Mix.Task
  def run(args) do
    repo_config = CodexPooler.Repo.config()
    ensure_test_database!(repo_config)

    TestDatabaseLock.with_lock!(repo_config, fn ->
      Mix.Task.run("ecto.drop", ["--quiet", "--force-drop"])
      Mix.Task.run("ecto.create", ["--quiet"])
      Mix.Task.run("ecto.migrate", ["--quiet", "--log-level", "warning"])

      try do
        Test.run(args)
      after
        drop_run_scoped_database(repo_config)
      end
    end)
  end

  defp ensure_test_database!(repo_config) do
    unless Mix.env() == :test and
             Keyword.get(repo_config, :pool) == Ecto.Adapters.SQL.Sandbox do
      Mix.raise("codex_pooler.test requires MIX_ENV=test with the SQL sandbox pool")
    end
  end

  # `Mix.Tasks.Test` reports failures through `System.at_exit/1` and returns, so this runs after
  # passing and failing runs alike, and after a raise. Only a killed VM skips it.
  defp drop_run_scoped_database(repo_config) do
    database = Keyword.fetch!(repo_config, :database)

    if TestDatabasePrune.run_scoped?(database) do
      # Stop the application first: a forced drop under a live Repo terminates its pool and
      # notification connections, which then log reconnect failures after the test summary.
      _ = Application.stop(:codex_pooler)
      Mix.Task.rerun("ecto.drop", ["--quiet", "--force-drop"])
    end

    :ok
  rescue
    exception ->
      Mix.shell().error(
        "codex_pooler.test: failed to drop run-scoped test database " <>
          "#{Keyword.fetch!(repo_config, :database)}: #{Exception.message(exception)}; " <>
          "remove it with mix codex_pooler.test.prune_databases"
      )

      System.at_exit(fn _status -> exit({:shutdown, 1}) end)
  end
end
