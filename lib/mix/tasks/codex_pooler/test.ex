defmodule Mix.Tasks.CodexPooler.Test do
  @moduledoc """
  Resets and runs the test suite while holding the shared test database lock.
  """

  use Mix.Task

  alias CodexPooler.MixTasks.TestDatabaseLock
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
      Test.run(args)
    end)
  end

  defp ensure_test_database!(repo_config) do
    unless Mix.env() == :test and
             Keyword.get(repo_config, :pool) == Ecto.Adapters.SQL.Sandbox do
      Mix.raise("codex_pooler.test requires MIX_ENV=test with the SQL sandbox pool")
    end
  end
end
