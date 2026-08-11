defmodule Mix.Tasks.Dev.Upstreams.Export do
  @moduledoc false

  use Mix.Task

  alias CodexPooler.Dev.UpstreamAccountBundle

  @shortdoc "Export active upstream accounts into an encrypted development bundle"

  @impl Mix.Task
  def run(args) do
    Logger.configure(level: :emergency)

    with :ok <- UpstreamAccountBundle.require_dev_environment(),
         {:ok, _command} <- UpstreamAccountBundle.parse_export_args(args) do
      Mix.Task.run("app.start")
    else
      {:error, message} -> Mix.raise(message)
    end

    # The dev-only repository boundary is intentionally opaque to Dialyzer;
    # invoke only this top-level task call dynamically so its real success path
    # remains representable without suppressing warnings.
    case apply(UpstreamAccountBundle, :run_export, [args]) do
      {:ok, receipt} -> Mix.shell().info(Jason.encode!(receipt))
      {:error, message} -> Mix.raise(message)
    end
  end
end
