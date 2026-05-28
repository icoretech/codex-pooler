defmodule Mix.Tasks.CodexPooler.Test do
  @moduledoc """
  Runs the test suite while holding the shared test database lock.
  """

  use Mix.Task

  alias CodexPooler.MixTasks.TestDatabaseLock

  @shortdoc "Runs ecto setup and tests under the shared test database lock"

  @impl Mix.Task
  def run(args) do
    TestDatabaseLock.with_lock!(CodexPooler.Repo.config(), fn ->
      Mix.Task.run("ecto.create", ["--quiet"])
      Mix.Task.run("ecto.migrate", ["--quiet"])
      Mix.Tasks.Test.run(args)
    end)
  end
end
