defmodule Mix.Tasks.Dev.McpFixture do
  @moduledoc """
  Acquires, releases, or inspects the reversible local MCP smoke fixture.

      MIX_ENV=dev mix dev.mcp_fixture acquire
      MIX_ENV=dev mix dev.mcp_fixture status
      MIX_ENV=dev mix dev.mcp_fixture release

  `--allow-isolated-dev-database` lets every action target a disposable
  isolated QA database (`codex_pooler_relqa_*` over loopback TCP) instead of
  `codex_pooler_dev`; its receipt then lives below `tmp/mcp-fixture/<database>/`.
  """

  use Mix.Task

  alias CodexPooler.Dev.MCPFixture
  alias CodexPooler.Dev.QaBackgroundWorkers

  @requirements ["app.config"]
  @shortdoc "Manage the reversible local MCP smoke fixture"

  @impl Mix.Task
  def run(args) do
    with {:ok, action, options} <- parse_args(args),
         :ok <- maybe_start_application(action),
         result <- run_action(action, options) do
      case result do
        {:ok, status} -> Mix.shell().info(CodexPooler.JSON.encode!(status))
        {:error, message} -> Mix.raise(message)
      end
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: [allow_isolated_dev_database: :boolean]) do
      {options, ["acquire"], []} -> {:ok, :acquire, isolated_option(options)}
      {options, ["release"], []} -> {:ok, :release, isolated_option(options)}
      {options, ["status"], []} -> {:ok, :status, isolated_option(options)}
      _invalid -> {:error, "use acquire, release, or status [--allow-isolated-dev-database]"}
    end
  end

  defp isolated_option(options) do
    if Keyword.get(options, :allow_isolated_dev_database, false),
      do: [allow_isolated_dev_database: true],
      else: []
  end

  defp maybe_start_application(:status), do: :ok

  # The fixture VM boots the application only to write its lease; Oban queues,
  # plugins and the stager stay off so it never runs jobs against the database
  # it leases, and the running instance is verified before any write.
  defp maybe_start_application(_action) do
    :ok = QaBackgroundWorkers.disable_before_boot!()
    Mix.Task.run("app.start")
    QaBackgroundWorkers.verify_disabled!()
  end

  defp run_action(:acquire, options), do: MCPFixture.acquire(options)
  defp run_action(:release, options), do: MCPFixture.release(options)
  defp run_action(:status, options), do: MCPFixture.status(options)
end
