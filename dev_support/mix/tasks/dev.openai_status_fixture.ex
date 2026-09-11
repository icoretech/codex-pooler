defmodule Mix.Tasks.Dev.OpenaiStatusFixture do
  @moduledoc "Seed provider-free OpenAI status data for local admin QA."

  use Mix.Task

  alias CodexPooler.Dev.OpenAIStatusFixture

  @requirements ["app.config"]
  @shortdoc "Seed deterministic local OpenAI status incidents"

  @impl Mix.Task
  def run(args) do
    scenario =
      case OptionParser.parse(args, strict: [scenario: :string]) do
        {opts, [], []} -> Keyword.get(opts, :scenario)
        _ -> nil
      end

    with {:ok, scenario} <- normalize_scenario(scenario),
         :ok <- Mix.Task.run("app.start"),
         {:ok, result} <- OpenAIStatusFixture.seed(scenario) do
      Mix.shell().info(CodexPooler.JSON.encode!(result))
    else
      {:error, message} -> Mix.raise(message)
      _ -> Mix.raise("use --scenario active|mixed|stale")
    end
  end

  defp normalize_scenario(scenario) when scenario in ["active", "mixed", "stale"],
    do: {:ok, String.to_existing_atom(scenario)}

  defp normalize_scenario(_), do: {:error, "use --scenario active|mixed|stale"}
end
