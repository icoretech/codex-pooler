defmodule Mix.Tasks.Dev.SavedResetConfirmationFixtures do
  @moduledoc """
  Seeds or cleans run-scoped synthetic saved-reset confirmation fixtures.

      MIX_ENV=dev mix dev.saved_reset_confirmation_fixtures --scenario all --browser-auth
      MIX_ENV=dev mix dev.saved_reset_confirmation_fixtures --cleanup JOURNAL_PATH
  """

  use Mix.Task

  alias CodexPooler.Dev.SavedResetConfirmationFixtures
  alias CodexPooler.MixTasks.TestDatabaseLock

  @requirements ["app.config"]
  @shortdoc "Manage synthetic saved-reset confirmation fixtures"

  @impl Mix.Task
  def run(args) do
    options =
      if Mix.env() == :test and System.get_env("CODEX_POOLER_FIXTURE_TEST_MODE") == "1" do
        [environment: :test, allow_test_database: true]
      else
        []
      end

    result =
      with {:ok, action} <- parse_fixture_action(args),
           :ok <- ensure_fixture_database_ready(options) do
        run_fixture(action, options)
      end

    case result do
      {:ok, receipt} -> Mix.shell().info(Jason.encode!(receipt))
      {:error, message} -> Mix.raise(message)
    end
  end

  defp run_fixture(action, options) do
    Mix.Task.run("app.start")

    case action do
      {:scenario, scenario, browser_auth?} ->
        SavedResetConfirmationFixtures.seed(
          scenario,
          Keyword.put(options, :browser_auth, browser_auth?)
        )

      {:cleanup, path} ->
        SavedResetConfirmationFixtures.cleanup(path, options)
    end
  end

  defp parse_fixture_action(args) do
    case OptionParser.parse(args,
           strict: [scenario: :string, cleanup: :string, browser_auth: :boolean],
           aliases: []
         ) do
      {options, [], []} -> parse_options(options)
      _invalid -> {:error, "use exactly --scenario NAME or --cleanup JOURNAL_PATH"}
    end
  end

  defp parse_options(options) do
    case {Keyword.get(options, :scenario), Keyword.get(options, :cleanup),
          Keyword.get(options, :browser_auth, false)} do
      {scenario, nil, browser_auth?} when is_binary(scenario) and is_boolean(browser_auth?) ->
        {:ok, {:scenario, scenario, browser_auth?}}

      {nil, path, false} when is_binary(path) ->
        {:ok, {:cleanup, path}}

      _invalid ->
        {:error, "use exactly --scenario NAME [--browser-auth] or --cleanup JOURNAL_PATH"}
    end
  end

  defp ensure_fixture_database_ready(environment: :test, allow_test_database: true) do
    repo_config = CodexPooler.Repo.config()

    with :ok <- isolated_test_database(repo_config) do
      TestDatabaseLock.with_lock!(repo_config, fn ->
        Mix.Task.run("ecto.create", ["--quiet"])
        Mix.Task.run("ecto.migrate", ["--quiet", "--log-level", "warning"])
      end)

      :ok
    end
  end

  defp ensure_fixture_database_ready(_options), do: :ok

  defp isolated_test_database(repo_config) do
    database = Keyword.fetch!(repo_config, :database)
    namespace = System.get_env("CODEX_POOLER_TEST_RUN_NAMESPACE")

    with namespace when is_binary(namespace) <- namespace,
         true <- Regex.match?(~r/\A[0-9a-f]{16}\z/, namespace),
         {partition, ""} when partition > 0 <-
           Integer.parse(System.get_env("MIX_TEST_PARTITION") || ""),
         true <-
           Regex.match?(~r/\Acodex_pooler_test_[0-9a-f]{8}_[0-9a-f]{16}_p[1-9][0-9]*\z/, database),
         true <- String.ends_with?(database, "_#{namespace}_p#{partition}") do
      :ok
    else
      _invalid ->
        {:error,
         "test fixture mode requires a positive MIX_TEST_PARTITION and a namespaced isolated test database"}
    end
  end
end
