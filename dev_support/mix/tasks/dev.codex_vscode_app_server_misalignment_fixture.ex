defmodule Mix.Tasks.Dev.CodexVscodeAppServerMisalignmentFixture do
  @moduledoc """
  Manages the released Codex app-server misalignment smoke resources.
  """

  use Mix.Task

  alias CodexPooler.Dev.CodexVscodeAppServerMisalignmentFixture

  @requirements ["app.config"]
  @shortdoc "Manage Codex app-server misalignment smoke resources"

  @impl Mix.Task
  def run(args) do
    with {:ok, action, options} <- CodexVscodeAppServerMisalignmentFixture.parse_args(args),
         result <- run_action(action, options) do
      case result do
        {:ok, status} -> Mix.shell().info(Jason.encode!(status))
        {:error, message} -> Mix.raise(message)
      end
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp run_action(:status, options), do: CodexVscodeAppServerMisalignmentFixture.status(options)

  defp run_action(action, options) do
    run_id = Keyword.fetch!(options, :run_id)

    CodexVscodeAppServerMisalignmentFixture.with_isolated_config(
      run_id,
      fn _application_name ->
        {:ok, _started} = Application.ensure_all_started(:codex_pooler)

        try do
          apply(CodexVscodeAppServerMisalignmentFixture, action, [options])
        after
          Application.stop(:codex_pooler)
        end
      end
    )
  end
end
