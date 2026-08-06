defmodule CodexPoolerWeb.Mcp.EnvelopeTest do
  use ExUnit.Case, async: true

  alias CodexPooler.MCP.Redaction
  alias CodexPoolerWeb.Mcp.{Envelope, Protocol}

  @server_version "0.5.18"
  @instructions "Read-only operator metadata for a codex-pooler instance: Pools, upstream accounts, API keys, operators, invites, quota evidence, and request/audit log metadata. All tools are non-mutating. Output is sanitized and never contains secrets, tokens, prompts, or request/response bodies."

  describe "discover_result/1" do
    test "Given a server version When building discovery Then it returns the complete private cacheable envelope" do
      # Given
      server_version = @server_version

      # When
      result = Envelope.discover_result(server_version)

      # Then
      assert result == %{
               "resultType" => "complete",
               "supportedVersions" => Protocol.supported_protocol_versions(),
               "capabilities" => %{"tools" => %{"listChanged" => false}},
               "instructions" => @instructions,
               "ttlMs" => 3_600_000,
               "cacheScope" => "private",
               "_meta" => %{
                 "io.modelcontextprotocol/serverInfo" => %{
                   "name" => "codex-pooler",
                   "version" => server_version
                 }
               }
             }

      refute Map.has_key?(result, "serverInfo")
      assert :ok = Redaction.assert_mcp_output_safe!(result)
    end
  end

  describe "tools_list_result/2" do
    test "Given legacy-shaped caller fields When building a modern tools list Then transport-owned fields are replaced without mutating the input" do
      # Given
      result = %{
        "tools" => [%{"name" => "codex_pooler_get_mcp_service_status"}],
        "resultType" => "legacy-result-type",
        "_meta" => %{"callerMeta" => "CALLER_META_MARKER"},
        "ttlMs" => 1,
        "cacheScope" => "public",
        "serverInfo" => %{"name" => "legacy-server"}
      }

      original_result = result

      # When
      modern_result = Envelope.tools_list_result(result, @server_version)

      # Then
      assert modern_result["tools"] == result["tools"]
      assert modern_result["serverInfo"] == result["serverInfo"]
      assert modern_result["resultType"] == "complete"
      assert modern_result["ttlMs"] == 3_600_000
      assert modern_result["cacheScope"] == "private"

      assert modern_result["_meta"] == %{
               "io.modelcontextprotocol/serverInfo" => %{
                 "name" => "codex-pooler",
                 "version" => @server_version
               }
             }

      refute inspect(modern_result["_meta"]) =~ "CALLER_META_MARKER"
      assert result == original_result
      assert :ok = Redaction.assert_mcp_output_safe!(modern_result)
    end
  end

  describe "tools_call_result/2" do
    test "Given a successful tool result When building a modern call result Then it preserves the success fields without cache hints" do
      # Given
      result = %{
        "content" => [%{"type" => "text", "text" => "Service status is available"}],
        "structuredContent" => %{"enabled" => true},
        "isError" => false,
        "resultType" => "legacy-result-type",
        "_meta" => %{"callerMeta" => "CALLER_META_MARKER"},
        "ttlMs" => 1,
        "cacheScope" => "public"
      }

      original_result = result

      # When
      modern_result = Envelope.tools_call_result(result, @server_version)

      # Then
      assert Map.take(modern_result, ["content", "structuredContent", "isError"]) ==
               Map.take(result, ["content", "structuredContent", "isError"])

      assert modern_result["resultType"] == "complete"

      assert modern_result["_meta"] == %{
               "io.modelcontextprotocol/serverInfo" => %{
                 "name" => "codex-pooler",
                 "version" => @server_version
               }
             }

      refute Map.has_key?(modern_result, "ttlMs")
      refute Map.has_key?(modern_result, "cacheScope")
      assert result == original_result
      assert :ok = Redaction.assert_mcp_output_safe!(modern_result)
    end

    test "Given an error tool result When building a modern call result Then it preserves isError without cache hints" do
      # Given
      result = %{
        "content" => [%{"type" => "text", "text" => "invalid_arguments: Invalid tool arguments"}],
        "isError" => true
      }

      original_result = result

      # When
      modern_result = Envelope.tools_call_result(result, @server_version)

      # Then
      assert modern_result["isError"] == true
      assert modern_result["content"] == result["content"]
      assert modern_result["resultType"] == "complete"
      refute Map.has_key?(modern_result, "ttlMs")
      refute Map.has_key?(modern_result, "cacheScope")
      assert result == original_result
      assert :ok = Redaction.assert_mcp_output_safe!(modern_result)
    end
  end

  describe "protocol error envelopes" do
    test "Given a JSON-RPC id When building a header mismatch error Then it is stable and contains no data" do
      # Given
      id = "request-42"

      # When
      error = Envelope.header_mismatch_error(id)

      # Then
      assert error == %{
               "jsonrpc" => "2.0",
               "id" => id,
               "error" => %{"code" => -32_020, "message" => "header mismatch"}
             }

      refute Map.has_key?(error["error"], "data")
      assert :ok = Redaction.assert_mcp_output_safe!(error)
    end

    test "Given a caller-marked JSON-RPC id When building an unsupported-version error Then its data contains supported versions only" do
      # Given
      id = "CALLER_VERSION_MARKER"

      # When
      error = Envelope.unsupported_protocol_version_error(id)

      # Then
      assert error == %{
               "jsonrpc" => "2.0",
               "id" => id,
               "error" => %{
                 "code" => -32_022,
                 "message" => "unsupported protocol version",
                 "data" => %{"supported" => Protocol.supported_protocol_versions()}
               }
             }

      refute Map.has_key?(error["error"]["data"], "requested")
      refute inspect(error["error"]["data"]) =~ "CALLER_VERSION_MARKER"
      assert :ok = Redaction.assert_mcp_output_safe!(error)
    end
  end
end
