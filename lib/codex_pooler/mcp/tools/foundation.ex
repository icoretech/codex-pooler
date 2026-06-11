defmodule CodexPooler.MCP.Tools.Foundation do
  @moduledoc """
  Foundation MCP catalog family for service status.
  """

  alias CodexPooler.MCP.ToolRegistry
  alias CodexPooler.MCP.Tools.ServiceStatus

  @empty_input_schema %{
    "type" => "object",
    "properties" => %{},
    "required" => [],
    "additionalProperties" => false
  }

  @read_only_annotations %{
    "readOnlyHint" => true,
    "destructiveHint" => false,
    "idempotentHint" => true,
    "openWorldHint" => false
  }

  @spec tools() :: [map()]
  def tools do
    [service_status_tool()]
  end

  defp service_status_tool do
    %{
      name: "codex_pooler_get_mcp_service_status",
      title: "Get MCP service status",
      description:
        ToolRegistry.metadata_description(
          use_when:
            "an MCP client needs to verify the Codex Pooler MCP service gates, authenticated actor, protocol version, and catalog size before calling metadata tools",
          returns:
            "global gate state, account gate state, a masked actor summary, supported protocol version, and supported tool count",
          never_returns: "MCP token prefixes, token hashes, or Pool API keys",
          filters_limits:
            "no arguments are accepted; the response is a single bounded metadata status object"
        ),
      input_schema: @empty_input_schema,
      output_schema: ServiceStatus.output_schema(),
      annotations: @read_only_annotations,
      handler: {ServiceStatus, :call}
    }
  end
end
