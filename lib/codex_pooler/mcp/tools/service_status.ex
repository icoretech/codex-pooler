defmodule CodexPooler.MCP.Tools.ServiceStatus do
  @moduledoc """
  Metadata-only MCP service status tool.
  """

  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.PrivacyMatrix
  alias CodexPooler.MCP.ProtocolVersions
  alias CodexPooler.MCP.ToolRegistry

  @spec output_schema() :: map()
  def output_schema do
    %{
      "type" => "object",
      "required" => [
        "globalGate",
        "accountGate",
        "actor",
        "protocolVersion",
        "supportedProtocolVersions",
        "supportedToolCount"
      ],
      "additionalProperties" => false,
      "properties" => %{
        "globalGate" => %{
          "type" => "object",
          "required" => ["enabled"],
          "additionalProperties" => false,
          "properties" => %{"enabled" => %{"type" => "boolean"}}
        },
        "accountGate" => %{
          "type" => "object",
          "required" => ["enabled"],
          "additionalProperties" => false,
          "properties" => %{"enabled" => %{"type" => "boolean"}}
        },
        "actor" => %{
          "type" => "object",
          "required" => ["id", "display_name", "email", "status"],
          "additionalProperties" => false,
          "properties" => %{
            "id" => %{"type" => "string"},
            "display_name" => %{"type" => "string"},
            "email" => %{"type" => "string"},
            "status" => %{"type" => "string"}
          }
        },
        "protocolVersion" => %{"type" => "string", "const" => ProtocolVersions.current()},
        "supportedProtocolVersions" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "const" => ProtocolVersions.supported()
        },
        "supportedToolCount" => %{"type" => "integer"}
      }
    }
  end

  @spec call(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def call(_arguments, %{auth: %{operator: operator}}) do
    structured = %{
      "globalGate" => %{"enabled" => InstanceSettings.current().mcp.enabled},
      "accountGate" => %{"enabled" => MCP.operator_mcp_enabled?(operator)},
      "actor" => actor_summary(operator),
      "protocolVersion" => ProtocolVersions.current(),
      "supportedProtocolVersions" => ProtocolVersions.supported(),
      "supportedToolCount" => length(ToolRegistry.all_tools())
    }

    {:ok, structured, text_summary(structured)}
  end

  def call(_arguments, _context) do
    {:error, %{code: :tool_execution_failed, message: "MCP authenticated actor is unavailable"}}
  end

  defp actor_summary(operator) do
    :operators
    |> PrivacyMatrix.project!(%{
      id: operator.id,
      display_name: operator.display_name || "Operator",
      email: operator.email,
      status: operator.status
    })
    |> stringify_keys()
  end

  defp text_summary(structured) do
    global = gate_text(structured["globalGate"]["enabled"])
    account = gate_text(structured["accountGate"]["enabled"])
    actor = structured["actor"]["display_name"]
    count = structured["supportedToolCount"]

    "MCP service #{global}; account gate #{account}; actor #{actor}; #{count} metadata-only tool available"
  end

  defp gate_text(true), do: "enabled"
  defp gate_text(false), do: "disabled"

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
