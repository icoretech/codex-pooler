defmodule CodexPooler.Release do
  @moduledoc """
  Release-only tasks for production operations.

  These functions are intended to be invoked explicitly with the assembled
  release, for example:

      bin/codex_pooler eval "CodexPooler.Release.migrate()"
  """

  alias CodexPooler.Catalog

  @app :codex_pooler

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _apps, _fun_result} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()

    {:ok, _apps, _fun_result} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def import_openai_pricing_from_priv do
    load_app()

    for repo <- repos() do
      {:ok, _apps, result} =
        Ecto.Migrator.with_repo(repo, fn _repo -> Catalog.import_openai_pricing_from_priv() end)

      result
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
