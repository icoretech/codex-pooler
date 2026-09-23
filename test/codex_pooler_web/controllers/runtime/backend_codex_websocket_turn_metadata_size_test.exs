defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketTurnMetadataSizeTest do
  # findings#258 row 258-91. The released Codex client carries its tool inventory in the canonical
  # turn metadata when `[features.tool_registry] turn_metadata_includes_tool_info` is on for a
  # Responses Lite model: 22,504 bytes with 120 MCP tools on a loopback capture server, where the
  # socket used to refuse every such `response.create` as `malformed_canonical` above 4,096 bytes.
  # Websocket, one node, Full catalog default, owner forwarding off and on.
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [cleanup_local_owner_sessions: 0]

  alias CodexPooler.FakeUpstream

  @session_id "019a0000-0000-7000-8000-00000000c001"
  @thread_id "019a0000-0000-7000-8000-00000000c002"
  @installation_id "00000000-0000-4000-8000-00000000c003"
  @context_window_id "00000000-0000-4000-8000-00000000c004"
  @turn_id "019a0000-0000-7000-8000-00000000c005"
  @window_id "#{@thread_id}:0"
  @response_id "resp_turn_metadata_size_00001"

  for topology <- [:direct, :owner_forwarded] do
    @tag topology: topology
    test "#{topology} socket admits a turn whose canonical metadata carries the MCP tool inventory", %{topology: topology} do
      put_owner_forwarding!(topology == :owner_forwarded)
      metadata = turn_metadata(tool_namespaces_info(3, 40))
      assert byte_size(metadata) > 16_384

      upstream =
        start_upstream(
          # provenance: released Codex client turn metadata key set observed on a capture server; tool inventory shape from responses_metadata.rs; reply frames synthetic
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              websocket_connection_ordinal: 1,
              json: [valid: true, equals: %{"type" => "response.create"}],
              respond: completed_frames()
            )
          ])
        )

      setup = gateway_setup(upstream)
      port = start_public_endpoint!()

      {conn, websocket, ref, _headers} =
        public_websocket_connect_with_request_headers!(
          port,
          setup,
          "turn-metadata-size-#{topology}",
          "/backend-api/codex/responses",
          [{"session-id", @session_id}, {"thread-id", @thread_id}, {"x-client-request-id", @thread_id}]
        )

      try do
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame(setup, metadata))
        {conn, websocket, created} = public_websocket_receive_text!(conn, websocket, ref)
        {_conn, _websocket, completed} = public_websocket_receive_text!(conn, websocket, ref)

        assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(created)
        assert %{"type" => "response.completed", "response" => %{"id" => @response_id}} = CodexPooler.JSON.decode!(completed)

        assert [request] = FakeUpstream.requests(upstream)
        # The relayed value keeps the inventory; the Pooler only scrubs the turn id from it.
        relayed = CodexPooler.JSON.decode!(request.json["client_metadata"]["x-codex-turn-metadata"])
        sent = CodexPooler.JSON.decode!(metadata)
        assert relayed["tool_namespaces_info"] == sent["tool_namespaces_info"]
        assert Map.delete(relayed, "turn_id") == Map.delete(sent, "turn_id")
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  defp frame(setup, metadata) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic tool-heavy prompt"}]}],
      "tools" => [],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "reasoning" => %{"effort" => "low"},
      "store" => false,
      "stream" => true,
      "include" => ["reasoning.encrypted_content"],
      "prompt_cache_key" => @thread_id,
      "client_metadata" => %{
        "session_id" => @session_id,
        "thread_id" => @thread_id,
        "turn_id" => @turn_id,
        "root_turn_id" => @turn_id,
        "x-codex-installation-id" => @installation_id,
        "x-codex-window-id" => @window_id,
        "x-codex-turn-metadata" => metadata
      }
    })
  end

  defp turn_metadata(tool_namespaces_info) do
    CodexPooler.JSON.encode!(%{
      "agent_name" => "/root",
      "analytics_enabled" => true,
      "auto_review_enabled" => false,
      "context_window_id" => @context_window_id,
      "installation_id" => @installation_id,
      "model" => "gpt-test-model",
      "node_repl_auto_review_required" => false,
      "node_repl_disabled" => false,
      "reasoning_effort" => "low",
      "request_kind" => "turn",
      "root_turn_id" => @turn_id,
      "sandbox" => "seccomp",
      "sandbox_mode" => "read-only",
      "session_id" => @session_id,
      "thread_id" => @thread_id,
      "thread_source" => "user",
      "tool_namespaces_info" => tool_namespaces_info,
      "turn_id" => @turn_id,
      "turn_started_at_unix_ms" => 1_790_000_000_000,
      "turn_trigger" => "exec",
      "window_id" => @window_id,
      "window_number" => 0
    })
  end

  defp tool_namespaces_info(servers, tools) do
    Map.new(1..servers, fn server ->
      namespace = "mcp__p23s#{server}__"

      functions =
        Map.new(1..tools, fn tool ->
          name = "p23s#{server}_lookup_record_#{tool}"
          {name, %{"name" => name, "direct" => false, "code_mode_name" => nil, "deferred" => true, "source" => %{"kind" => "mcp", "server_name" => "p23s#{server}"}}}
        end)

      {namespace, %{"name" => namespace, "functions" => functions}}
    end)
  end

  defp completed_frames do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => @response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => @response_id,
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 20, "output_tokens" => 1, "total_tokens" => 21}
        }
      })
    ])
  end

  defp put_owner_forwarding!(enabled?) do
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled?)

    on_exit(fn ->
      if enabled?, do: cleanup_local_owner_sessions()

      case previous do
        :error -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        {:ok, value} -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end
end
