defmodule CodexPoolerWeb.Mcp.Envelope do
  @moduledoc false

  alias CodexPoolerWeb.Mcp.Protocol

  @cache_scope "private"
  @cache_ttl_ms 3_600_000
  @instructions "Read-only operator metadata for a codex-pooler instance: Pools, upstream accounts, API keys, operators, invites, quota evidence, and request/audit log metadata. All tools are non-mutating. Output is sanitized and never contains secrets, tokens, prompts, or request/response bodies."
  @result_type "complete"
  @server_name "codex-pooler"

  @type json_value ::
          nil
          | boolean()
          | number()
          | String.t()
          | [json_value()]
          | %{optional(String.t()) => json_value()}
  @type result :: %{optional(String.t()) => json_value()}
  @type server_version :: String.t()
  @type json_rpc_id :: nil | String.t() | integer() | float()
  @type protocol_error_body :: %{required(String.t()) => json_value()}

  @spec discover_result(server_version()) :: result()
  def discover_result(server_version) when is_binary(server_version) do
    %{
      "resultType" => @result_type,
      "supportedVersions" => Protocol.supported_protocol_versions(),
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "instructions" => @instructions,
      "ttlMs" => @cache_ttl_ms,
      "cacheScope" => @cache_scope,
      "_meta" => server_info_meta(server_version)
    }
  end

  @spec tools_list_result(result(), server_version()) :: result()
  def tools_list_result(result, server_version)
      when is_map(result) and is_binary(server_version) do
    result
    |> Map.merge(modern_result_fields(server_version))
    |> Map.merge(%{"ttlMs" => @cache_ttl_ms, "cacheScope" => @cache_scope})
  end

  @spec tools_call_result(result(), server_version()) :: result()
  def tools_call_result(result, server_version)
      when is_map(result) and is_binary(server_version) do
    result
    |> Map.drop(["ttlMs", "cacheScope"])
    |> Map.merge(modern_result_fields(server_version))
  end

  @spec header_mismatch_error(json_rpc_id()) :: protocol_error_body()
  def header_mismatch_error(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_020, "message" => "header mismatch"}
    }
  end

  @spec unsupported_protocol_version_error(json_rpc_id()) :: protocol_error_body()
  def unsupported_protocol_version_error(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => -32_022,
        "message" => "unsupported protocol version",
        "data" => %{"supported" => Protocol.supported_protocol_versions()}
      }
    }
  end

  @spec modern_result_fields(server_version()) :: result()
  defp modern_result_fields(server_version) do
    %{"resultType" => @result_type, "_meta" => server_info_meta(server_version)}
  end

  @spec server_info_meta(server_version()) :: result()
  defp server_info_meta(server_version) do
    %{
      "io.modelcontextprotocol/serverInfo" => %{
        "name" => @server_name,
        "version" => server_version
      }
    }
  end
end
