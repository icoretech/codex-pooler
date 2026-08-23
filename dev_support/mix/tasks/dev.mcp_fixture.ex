defmodule Mix.Tasks.Dev.McpFixture do
  @moduledoc """
  Acquires, releases, or inspects the reversible local MCP smoke fixture.

      MIX_ENV=dev mix dev.mcp_fixture acquire
      MIX_ENV=dev mix dev.mcp_fixture status
      MIX_ENV=dev mix dev.mcp_fixture release
  """

  use Mix.Task

  alias CodexPooler.Dev.MCPFixture

  @requirements ["app.config"]
  @shortdoc "Manage the reversible local MCP smoke fixture"

  @impl Mix.Task
  def run(args) do
    with {:ok, action} <- parse_args(args),
         :ok <- maybe_start_application(action),
         result <- run_action(action) do
      case result do
        {:ok, status} -> Mix.shell().info(Jason.encode!(status))
        {:error, message} -> Mix.raise(message)
      end
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp parse_args(["acquire"]), do: {:ok, :acquire}
  defp parse_args(["release"]), do: {:ok, :release}
  defp parse_args(["status"]), do: {:ok, :status}
  defp parse_args(_args), do: {:error, "use acquire, release, or status"}

  defp maybe_start_application(:status), do: :ok

  defp maybe_start_application(_action) do
    Mix.Task.run("app.start")
    :ok
  end

  defp run_action(:acquire), do: MCPFixture.acquire()
  defp run_action(:release), do: MCPFixture.release()
  defp run_action(:status), do: MCPFixture.status()
end
