defmodule CodexPooler.Release do
  @moduledoc """
  Release-only tasks for production operations.

  These functions are intended to be invoked explicitly with the assembled
  release, for example:

      bin/codex_pooler eval "CodexPooler.Release.migrate()"
  """

  alias CodexPooler.Catalog

  @app :codex_pooler

  # A release task runs with the runtime config of whatever `OBAN_MODE` its
  # container carries (the migration job renders `web`); its own PostgreSQL
  # application_name keeps its backends distinguishable from serving pods.
  @task_application_names %{
    migrate: "codex_pooler_migrate",
    rollback: "codex_pooler_migrate",
    import_openai_pricing: "codex_pooler_pricing_import"
  }

  def migrate do
    load_app()

    for repo <- repos() do
      name_repo_connections(repo, :migrate)

      {:ok, _apps, _fun_result} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    name_repo_connections(repo, :rollback)

    {:ok, _apps, _fun_result} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def import_openai_pricing_from_priv do
    load_app()

    for repo <- repos() do
      name_repo_connections(repo, :import_openai_pricing)

      {:ok, result, _started} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          {:ok, import_result} = Catalog.import_openai_pricing_from_priv()
          import_result
        end)

      result
    end
  end

  @doc false
  @spec repo_config_for_task(keyword(), :migrate | :rollback | :import_openai_pricing) ::
          keyword()
  def repo_config_for_task(repo_config, task) when is_list(repo_config) do
    parameters =
      repo_config
      |> Keyword.get(:parameters, [])
      |> Keyword.put(:application_name, Map.fetch!(@task_application_names, task))

    Keyword.put(repo_config, :parameters, parameters)
  end

  defp name_repo_connections(repo, task) do
    Application.put_env(
      @app,
      repo,
      repo_config_for_task(Application.get_env(@app, repo, []), task)
    )
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
