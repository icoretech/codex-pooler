defmodule CodexPooler.MCP.ToolRegistryTest do
  use ExUnit.Case, async: true

  alias CodexPooler.MCP.ToolRegistry
  alias CodexPooler.MCP.Tools.Foundation
  alias CodexPooler.MCP.Tools.LogMetadata
  alias CodexPooler.MCP.Tools.OperatorMetadata
  alias CodexPooler.MCP.Tools.PoolMetadata
  alias CodexPooler.MCP.Tools.QuotaMetadata

  @required_description_sections ["Use when", "Returns", "Never returns", "Filters/limits"]
  @row_text_tool_names [
    "codex_pooler_list_pools",
    "codex_pooler_get_pool",
    "codex_pooler_list_upstreams",
    "codex_pooler_get_upstream",
    "codex_pooler_list_pool_api_keys",
    "codex_pooler_get_pool_api_key",
    "codex_pooler_list_upstream_quotas",
    "codex_pooler_get_upstream_quota",
    "codex_pooler_list_operators",
    "codex_pooler_get_operator",
    "codex_pooler_list_invites",
    "codex_pooler_get_invite",
    "codex_pooler_list_request_logs",
    "codex_pooler_get_request_log",
    "codex_pooler_list_audit_logs",
    "codex_pooler_get_audit_log"
  ]

  test "default registry has required Task 6 tool names with complete metadata" do
    tools = ToolRegistry.all_tools()

    assert Enum.map(tools, & &1.name) == [
             "codex_pooler_get_mcp_service_status",
             "codex_pooler_list_pools",
             "codex_pooler_get_pool",
             "codex_pooler_list_upstreams",
             "codex_pooler_get_upstream",
             "codex_pooler_list_pool_api_keys",
             "codex_pooler_get_pool_api_key",
             "codex_pooler_list_upstream_quotas",
             "codex_pooler_get_upstream_quota",
             "codex_pooler_list_operators",
             "codex_pooler_get_operator",
             "codex_pooler_list_invites",
             "codex_pooler_get_invite",
             "codex_pooler_list_request_logs",
             "codex_pooler_get_request_log",
             "codex_pooler_list_audit_logs",
             "codex_pooler_get_audit_log"
           ]

    tool = Enum.find(tools, &(&1.name == "codex_pooler_get_mcp_service_status"))
    assert tool.title == "Get MCP service status"
    assert is_binary(tool.description)
    assert tool.handler == {CodexPooler.MCP.Tools.ServiceStatus, :call}

    for section <- @required_description_sections do
      assert tool.description =~ section
    end

    assert tool.input_schema == %{
             "type" => "object",
             "properties" => %{},
             "required" => [],
             "additionalProperties" => false
           }

    assert get_in(tool.output_schema, ["properties", "globalGate", "type"]) == "object"
    assert get_in(tool.output_schema, ["properties", "accountGate", "type"]) == "object"
    assert get_in(tool.output_schema, ["properties", "actor", "type"]) == "object"
    assert get_in(tool.output_schema, ["properties", "protocolVersion", "const"]) == "2025-11-25"
    assert get_in(tool.output_schema, ["properties", "supportedToolCount", "type"]) == "integer"

    assert tool.annotations == %{
             "readOnlyHint" => true,
             "destructiveHint" => false,
             "idempotentHint" => true,
             "openWorldHint" => false
           }
  end

  test "default registry predeclares deterministic Task 6-9 family modules" do
    assert ToolRegistry.family_modules() == [
             Foundation,
             PoolMetadata,
             QuotaMetadata,
             OperatorMetadata,
             LogMetadata
           ]
  end

  test "service status is excluded from the row-format metadata tool set" do
    row_tools =
      ToolRegistry.all_tools()
      |> Enum.reject(&(&1.name == "codex_pooler_get_mcp_service_status"))
      |> Enum.map(& &1.name)

    assert row_tools == @row_text_tool_names
    refute Enum.member?(@row_text_tool_names, "codex_pooler_get_mcp_service_status")
  end

  test "Task 8 operator family and Task 9 log family are valid catalog inputs" do
    assert Enum.map(OperatorMetadata.tools(), & &1.name) == [
             "codex_pooler_list_operators",
             "codex_pooler_get_operator",
             "codex_pooler_list_invites",
             "codex_pooler_get_invite"
           ]

    assert Enum.map(LogMetadata.tools(), & &1.name) == [
             "codex_pooler_list_request_logs",
             "codex_pooler_get_request_log",
             "codex_pooler_list_audit_logs",
             "codex_pooler_get_audit_log"
           ]

    assert [_, _, _, _, _, _, _, _] =
             ToolRegistry.tools_from_families([
               OperatorMetadata,
               LogMetadata
             ])

    assert :ok =
             ToolRegistry.validate_tools(
               ToolRegistry.tools_from_families([
                 OperatorMetadata,
                 LogMetadata
               ])
             )
  end

  test "quota metadata tools are implemented by the quota family" do
    assert Enum.map(QuotaMetadata.tools(), & &1.name) == [
             "codex_pooler_list_upstream_quotas",
             "codex_pooler_get_upstream_quota"
           ]

    tools = ToolRegistry.all_tools()

    expected_handlers = %{
      "codex_pooler_list_upstream_quotas" => :list_upstream_quotas,
      "codex_pooler_get_upstream_quota" => :get_upstream_quota
    }

    for {name, function} <- expected_handlers do
      tool = Enum.find(tools, &(&1.name == name))
      assert tool.handler == {QuotaMetadata, function}

      assert tool.annotations == %{
               "readOnlyHint" => true,
               "destructiveHint" => false,
               "idempotentHint" => true,
               "openWorldHint" => false
             }

      for section <- @required_description_sections do
        assert tool.description =~ section
      end
    end
  end

  test "list tools returns MCP-safe definitions without handler metadata" do
    assert {:ok, %{tools: listed_tools, next_cursor: nil}} = ToolRegistry.list_tools(%{})

    assert Enum.map(listed_tools, & &1["name"]) == [
             "codex_pooler_get_mcp_service_status",
             "codex_pooler_list_pools",
             "codex_pooler_get_pool",
             "codex_pooler_list_upstreams",
             "codex_pooler_get_upstream",
             "codex_pooler_list_pool_api_keys",
             "codex_pooler_get_pool_api_key",
             "codex_pooler_list_upstream_quotas",
             "codex_pooler_get_upstream_quota",
             "codex_pooler_list_operators",
             "codex_pooler_get_operator",
             "codex_pooler_list_invites",
             "codex_pooler_get_invite",
             "codex_pooler_list_request_logs",
             "codex_pooler_get_request_log",
             "codex_pooler_list_audit_logs",
             "codex_pooler_get_audit_log"
           ]

    for listed <- listed_tools do
      assert is_binary(listed["title"])
      assert is_map(listed["inputSchema"])
      assert is_map(listed["outputSchema"])
      assert is_map(listed["annotations"])
      refute Map.has_key?(listed, "handler")
    end
  end

  test "Pool API-key tools are explicit metadata-only handlers" do
    tools = ToolRegistry.all_tools()

    for name <- ["codex_pooler_list_pool_api_keys", "codex_pooler_get_pool_api_key"] do
      tool = Enum.find(tools, &(&1.name == name))
      assert tool.description =~ "Pool API keys, not MCP tokens"
      refute tool.description =~ "not implemented until Task 7"

      assert tool.handler ==
               {CodexPooler.MCP.Tools.PoolMetadata, handler_for_pool_api_key_tool(name)}

      assert get_in(tool.output_schema, ["properties", "status", "type"]) == "string"

      for section <- @required_description_sections do
        assert tool.description =~ section
      end

      assert tool.annotations == %{
               "readOnlyHint" => true,
               "destructiveHint" => false,
               "idempotentHint" => true,
               "openWorldHint" => false
             }
    end
  end

  test "operator and invite tools are implemented by the Task 8 family" do
    tools = ToolRegistry.all_tools()

    expected_handlers = %{
      "codex_pooler_list_operators" => :list_operators,
      "codex_pooler_get_operator" => :get_operator,
      "codex_pooler_list_invites" => :list_invites,
      "codex_pooler_get_invite" => :get_invite
    }

    for {name, function} <- expected_handlers do
      tool = Enum.find(tools, &(&1.name == name))
      assert tool.handler == {CodexPooler.MCP.Tools.OperatorMetadata, function}

      for section <- @required_description_sections do
        assert tool.description =~ section
      end

      assert tool.annotations == %{
               "readOnlyHint" => true,
               "destructiveHint" => false,
               "idempotentHint" => true,
               "openWorldHint" => false
             }
    end
  end

  test "registry gathers explicit per-family modules without dispatcher changes" do
    tools =
      ToolRegistry.tools_from_families([
        __MODULE__.FuturePoolsFamily,
        __MODULE__.FutureLogsFamily
      ])

    assert Enum.map(tools, & &1.name) == [
             "codex_pooler_list_future_pools",
             "codex_pooler_list_future_request_logs"
           ]

    assert :ok = ToolRegistry.validate_tools(tools)
  end

  test "registry duplicate detection spans family module boundaries" do
    tools =
      ToolRegistry.tools_from_families([
        __MODULE__.FuturePoolsFamily,
        __MODULE__.DuplicateFuturePoolsFamily
      ])

    assert {:error, {:duplicate_tool_names, ["codex_pooler_list_future_pools"]}} =
             ToolRegistry.validate_tools(tools)
  end

  test "catalog validation rejects duplicate tool names" do
    tool = hd(ToolRegistry.all_tools())

    assert {:error, {:duplicate_tool_names, ["codex_pooler_get_mcp_service_status"]}} =
             ToolRegistry.validate_tools([tool, tool])
  end

  test "catalog validation rejects missing description sections and non-strict schemas" do
    tool = hd(ToolRegistry.all_tools())

    bad_description = %{tool | description: "Use when only one section is present"}

    assert {:error, {:invalid_description, "codex_pooler_get_mcp_service_status", _missing}} =
             ToolRegistry.validate_tools([bad_description])

    bad_schema = put_in(tool.input_schema["additionalProperties"], true)

    assert {:error, {:invalid_input_schema, "codex_pooler_get_mcp_service_status", _reason}} =
             ToolRegistry.validate_tools([bad_schema])
  end

  test "future tool families can be validated without editing dispatcher branches" do
    tool = hd(ToolRegistry.all_tools())

    future_tool = %{
      tool
      | name: "codex_pooler_list_future_metadata",
        title: "List future metadata",
        handler: {CodexPooler.MCP.Tools.ServiceStatus, :call}
    }

    assert :ok = ToolRegistry.validate_tools([tool, future_tool])
  end

  defp handler_for_pool_api_key_tool("codex_pooler_list_pool_api_keys"), do: :list_pool_api_keys
  defp handler_for_pool_api_key_tool("codex_pooler_get_pool_api_key"), do: :get_pool_api_key

  defmodule FutureUnavailableHandler do
    def call(_arguments, %{tool: %{title: title}}) do
      {:error, unavailable(title)}
    end

    def call(_arguments, _context) do
      {:error, unavailable("Future metadata tool")}
    end

    defp unavailable(title) do
      %{
        code: :not_implemented,
        message: "#{title} is reserved for future metadata coverage"
      }
    end
  end

  defmodule FuturePoolsFamily do
    def tools do
      [future_tool("codex_pooler_list_future_pools", "List future pools")]
    end

    def future_tool(name, title) do
      %{
        name: name,
        title: title,
        description:
          "Use when testing family aggregation. Returns no entity data. Never returns secrets. Filters/limits: none.",
        input_schema: %{
          "type" => "object",
          "properties" => %{},
          "required" => [],
          "additionalProperties" => false
        },
        output_schema: %{
          "type" => "object",
          "required" => ["ok"],
          "properties" => %{"ok" => %{"type" => "boolean"}},
          "additionalProperties" => false
        },
        annotations: %{
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true,
          "openWorldHint" => false
        },
        handler: {FutureUnavailableHandler, :call}
      }
    end
  end

  defmodule FutureLogsFamily do
    def tools do
      [
        FuturePoolsFamily.future_tool(
          "codex_pooler_list_future_request_logs",
          "List future request logs"
        )
      ]
    end
  end

  defmodule DuplicateFuturePoolsFamily do
    def tools do
      [FuturePoolsFamily.future_tool("codex_pooler_list_future_pools", "Duplicate future pools")]
    end
  end
end
