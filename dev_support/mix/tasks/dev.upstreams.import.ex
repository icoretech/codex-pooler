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
      Mix.Task.run("app.start")
    else
      {:error, message} -> Mix.raise(message)
    end

    # Match the export task's narrow Dialyzer boundary. Parsing and environment
    # gating above remain direct and execute before application boot.
    case apply(UpstreamAccountBundle, :run_import, [args]) do
      {:ok, receipt} -> Mix.shell().info(Jason.encode!(receipt))
      {:error, message} -> Mix.raise(message)
    end
  end
end
