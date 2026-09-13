defmodule Mix.Tasks.CodexPooler.Test.PruneDatabases do
  @moduledoc """
  Drops the run-scoped test databases that interrupted runs left behind.

  A run with `CODEX_POOLER_TEST_RUN_NAMESPACE` and `MIX_TEST_PARTITION` set gets its own database,
  `codex_pooler_test_<fingerprint>_<namespace>_p<partition>`, and drops it when it finishes. A
  run that is killed, crashes, or loses the machine never reaches that drop, and nothing else will
  reuse the name.

  This task drops every such database on the configured test server that no session is connected
  to and no `codex_pooler.test` run holds. The shared base databases (`codex_pooler_test`,
  `codex_pooler_test<partition>`) are never touched.

      MIX_ENV=test mix codex_pooler.test.prune_databases
  """

  use Mix.Task

  alias CodexPooler.MixTasks.TestDatabasePrune

  @shortdoc "Drops idle run-scoped test databases left by interrupted runs"

  @impl Mix.Task
  def run(_args) do
    unless Mix.env() == :test do
      Mix.raise("codex_pooler.test.prune_databases requires MIX_ENV=test")
    end

    Mix.Task.run("app.config")

    results = TestDatabasePrune.prune!(CodexPooler.Repo.config())
    dropped = for {database, :dropped} <- results, do: database
    kept = for {database, outcome} <- results, outcome != :dropped, do: {database, outcome}

    Mix.shell().info(
      "codex_pooler.test.prune_databases: dropped #{length(dropped)} idle run-scoped test " <>
        "databases, kept #{length(kept)} in use"
    )

    Enum.each(kept, fn {database, outcome} ->
      Mix.shell().info("  kept #{database} (#{describe(outcome)})")
    end)
  end

  defp describe(:connected), do: "a session is connected"
  defp describe(:runner_locked), do: "a codex_pooler.test run holds it"
end
