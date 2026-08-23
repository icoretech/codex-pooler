defmodule Mix.Tasks.Dev.OpenaiV1Fixture do
  @moduledoc """
  Acquires, releases, or inspects the reversible local OpenAI V1 smoke fixture.

      MIX_ENV=dev mix dev.openai_v1_fixture acquire --upstream-base-url http://127.0.0.1:4057
      MIX_ENV=dev mix dev.openai_v1_fixture acquire --upstream-base-url http://127.0.0.1:4057 --request-compression
      MIX_ENV=dev mix dev.openai_v1_fixture status
      MIX_ENV=dev mix dev.openai_v1_fixture release
  """

  use Mix.Task

  alias CodexPooler.Dev.OpenAIV1Fixture

  @requirements ["app.config"]
  @shortdoc "Manage the reversible local OpenAI V1 smoke fixture"

  @impl Mix.Task
  def run(args) do
    with {:ok, action, options} <- parse_args(args),
         :ok <- maybe_start_application(action),
         result <- run_action(action, options) do
      case result do
        {:ok, status} -> Mix.shell().info(Jason.encode!(status))
        {:error, message} -> Mix.raise(message)
      end
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args,
           strict: [upstream_base_url: :string, request_compression: :boolean],
           aliases: []
         ) do
      {options, ["acquire"], []} ->
        {:ok, :acquire, normalize_acquire_options(options)}

      {[], ["release"], []} ->
        {:ok, :release, []}

      {[], ["status"], []} ->
        {:ok, :status, []}

      _invalid ->
        {:error,
         "use acquire [--upstream-base-url URL] [--request-compression], release, or status"}
    end
  end

  defp normalize_acquire_options(options) do
    if Keyword.get(options, :request_compression, false) do
      Keyword.put(options, :request_compression, :enabled)
    else
      Keyword.delete(options, :request_compression)
    end
  end

  defp maybe_start_application(:status), do: :ok

  defp maybe_start_application(_action) do
    Mix.Task.run("app.start")
    :ok
  end

  defp run_action(:acquire, options), do: OpenAIV1Fixture.acquire(options)
  defp run_action(:release, _options), do: OpenAIV1Fixture.release()
  defp run_action(:status, _options), do: OpenAIV1Fixture.status()
end
