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

  @private_receipt_env "CODEX_POOLER_OPENAI_V1_FIXTURE_RECEIPT_PATH"
  @private_receipt_relative ~r/^tmp\/openai-v1-isolated-fixture\/build-[^\/]+\/fixture\/setup\.json$/

  @requirements ["app.config"]
  @shortdoc "Manage the reversible local OpenAI V1 smoke fixture"

  @impl Mix.Task
  def run(args) do
    with {:ok, action, options} <- parse_args(args),
         {:ok, options} <- fixture_options(options),
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
           strict: [
             upstream_base_url: :string,
             request_compression: :boolean,
             allow_isolated_dev_database: :boolean
           ],
           aliases: []
         ) do
      {options, ["acquire"], []} ->
        {:ok, :acquire, normalize_acquire_options(options)}

      {options, ["release"], []} ->
        {:ok, :release, normalize_release_options(options)}

      {options, ["status"], []} ->
        {:ok, :status, normalize_release_options(options)}

      _invalid ->
        {:error,
         "use acquire [--upstream-base-url URL] [--request-compression], release, or status"}
    end
  end

  defp normalize_acquire_options(options) do
    options
    |> maybe_enable_request_compression()
    |> maybe_allow_isolated_dev_database()
  end

  defp maybe_start_application(:status), do: :ok

  defp maybe_start_application(_action) do
    Mix.Task.run("app.start")
    :ok
  end

  defp run_action(:acquire, options), do: OpenAIV1Fixture.acquire(options)
  defp run_action(:release, options), do: OpenAIV1Fixture.release(options)
  defp run_action(:status, options), do: OpenAIV1Fixture.status(options)

  defp maybe_enable_request_compression(options) do
    if Keyword.get(options, :request_compression, false) do
      Keyword.put(options, :request_compression, :enabled)
    else
      Keyword.delete(options, :request_compression)
    end
  end

  defp maybe_allow_isolated_dev_database(options) do
    if Keyword.get(options, :allow_isolated_dev_database, false) do
      Keyword.put(options, :allow_isolated_dev_database, true)
    else
      Keyword.delete(options, :allow_isolated_dev_database)
    end
  end

  defp normalize_release_options(options) do
    options
    |> Keyword.take([:allow_isolated_dev_database])
    |> maybe_allow_isolated_dev_database()
  end

  defp fixture_options(options) do
    case private_receipt_path() do
      {:ok, nil} -> {:ok, options}
      {:ok, path} -> {:ok, Keyword.put(options, :receipt_path, path)}
      {:error, message} -> {:error, message}
    end
  end

  defp private_receipt_path do
    case System.get_env(@private_receipt_env) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        path = Path.expand(value, File.cwd!())

        with relative <- Path.relative_to(path, File.cwd!()),
             true <- Regex.match?(@private_receipt_relative, relative) do
          {:ok, path}
        else
          _invalid -> {:error, "OpenAI V1 fixture private receipt path is invalid"}
        end
    end
  end
end
