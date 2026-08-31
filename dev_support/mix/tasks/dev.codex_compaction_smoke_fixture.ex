defmodule Mix.Tasks.Dev.CodexCompactionSmokeFixture do
  @moduledoc """
  Manages the run-scoped released Codex automatic-compaction smoke fixture.
  """

  use Mix.Task

  alias CodexPooler.Dev.CodexCompactionSmokeFixture

  @requirements ["app.config"]
  @shortdoc "Manage released Codex automatic-compaction smoke resources"

  @impl Mix.Task
  def run(args) do
    with {:ok, action, options} <- CodexCompactionSmokeFixture.parse_args(args),
         result <- run_action(action, options) do
      case result do
        {:ok, status} -> Mix.shell().info(Jason.encode!(status))
        {:error, message} -> Mix.raise(message)
      end
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp run_action(:status, options), do: CodexCompactionSmokeFixture.status(options)
  defp run_action(:receipt, options), do: CodexCompactionSmokeFixture.receipt(options)

  defp run_action(action, options) do
    run_id = Keyword.fetch!(options, :run_id)

    CodexCompactionSmokeFixture.with_isolated_config(run_id, fn _application_name ->
      {:ok, _started} = Application.ensure_all_started(:codex_pooler)

      try do
        apply(CodexCompactionSmokeFixture, action, [options])
      after
        Application.stop(:codex_pooler)
      end
    end)
  end
end
