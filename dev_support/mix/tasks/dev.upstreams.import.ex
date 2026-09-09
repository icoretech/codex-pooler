defmodule Mix.Tasks.Dev.Upstreams.Import do
  @moduledoc false

  use Mix.Task

  alias CodexPooler.Dev.UpstreamAccountBundle

  @shortdoc "Import an encrypted upstream account bundle into a development pool"

  @impl Mix.Task
  def run(args) do
    Logger.configure(level: :emergency)

    with :ok <- UpstreamAccountBundle.require_dev_environment(),
         {:ok, _command} <- UpstreamAccountBundle.parse_import_args(args) do
      configure_isolated_runtime!()
      Mix.Task.run("app.start")
    else
      {:error, message} -> Mix.raise(message)
    end

    # Match the export task's narrow Dialyzer boundary. Parsing and environment
    # gating above remain direct and execute before application boot.
    case apply(UpstreamAccountBundle, :run_import, [args]) do
      {:ok, receipt} -> Mix.shell().info(CodexPooler.JSON.encode!(receipt))
      {:error, message} -> Mix.raise(message)
    end
  end

  # The task is a one-shot local database import. Configure the application
  # before boot so an inherited PHX_SERVER or development Oban configuration
  # cannot open a listener or run provider-capable jobs.
  defp configure_isolated_runtime! do
    repo_config = Application.fetch_env!(:codex_pooler, CodexPooler.Repo)

    expected_database = System.get_env("CODEX_POOLER_DEV_POSTGRES_DB", "codex_pooler_dev")

    if Keyword.fetch!(repo_config, :database) != expected_database do
      Mix.raise(
        "development bundle task database configuration does not match CODEX_POOLER_DEV_POSTGRES_DB"
      )
    end

    endpoint_config = Application.fetch_env!(:codex_pooler, CodexPoolerWeb.Endpoint)

    Application.put_env(
      :codex_pooler,
      CodexPoolerWeb.Endpoint,
      Keyword.put(endpoint_config, :server, false)
    )

    oban_config = Application.fetch_env!(:codex_pooler, Oban)

    Application.put_env(
      :codex_pooler,
      Oban,
      oban_config
      |> Keyword.put(:queues, false)
      |> Keyword.put(:plugins, false)
      |> Keyword.put(:stager, false)
    )
  end
end
