defmodule CodexPoolerWeb.V1.ResponsesNamespaceFunctionTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, public_websocket_connect!: 4, public_websocket_receive_text!: 3, public_websocket_send_text!: 4, start_public_endpoint!: 0, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.FakeUpstream

  @moduletag capture_log: true
  @nested_arguments ~s({ "item_id": "synthetic-item" })
  @top_arguments ~s({ "count": 1.00 })
  @top_tool %{"type" => "function", "name" => "lookup_item", "strict" => true, "parameters" => %{"type" => "object", "properties" => %{"count" => %{"type" => "number"}}, "required" => ["count"], "additionalProperties" => false}}
  @nested_tool %{"type" => "function", "name" => "lookup_item", "strict" => true, "parameters" => %{"type" => "object", "properties" => %{"item_id" => %{"type" => "string"}}, "required" => ["item_id"], "additionalProperties" => false}}
  @tools [@top_tool, %{"type" => "namespace", "name" => "catalog", "description" => "Synthetic catalog functions", "tools" => [@nested_tool, %{@nested_tool | "name" => "find_item"}, %{@nested_tool | "name" => "inspect_item"}]}]
  @calls [
    %{"type" => "function_call", "id" => "fc_synthetic_nested", "call_id" => "call_synthetic_nested", "name" => "lookup_item", "namespace" => "catalog", "arguments" => @nested_arguments, "status" => "completed"},
    %{"type" => "function_call", "id" => "fc_synthetic_top", "call_id" => "call_synthetic_top", "name" => "lookup_item", "arguments" => @top_arguments, "status" => "completed"},
    %{"type" => "function_call", "id" => "fc_synthetic_restored", "call_id" => "call_synthetic_restored", "name" => "find_item", "namespace" => "catalog", "arguments" => @nested_arguments, "status" => "completed"},
    %{"type" => "function_call", "id" => "fc_synthetic_provider", "call_id" => "call_synthetic_provider", "name" => "inspect_item", "namespace" => "provider_catalog", "arguments" => @nested_arguments, "status" => "completed"}
  ]
  @upstream_calls Enum.map(@calls, fn item -> if item["name"] == "find_item", do: Map.delete(item, "namespace"), else: item end)
  @input [
    %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic namespace lookup"}]},
    %{"type" => "function_call", "call_id" => "call_synthetic_prior", "name" => "lookup_item", "namespace" => "catalog", "arguments" => @nested_arguments},
    %{"type" => "function_call_output", "call_id" => "call_synthetic_prior", "output" => "synthetic lookup result"}
  ]

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
    :ok
  end

  for mode <- ~w(full lite), transport <- [:json, :sse, :websocket] do
    @tag serving_mode: mode, transport: transport
    test "#{mode} #{transport}: restores unique function namespaces without overwriting provider namespaces or guessing ambiguous calls", %{serving_mode: mode, transport: transport} do
      assert_namespace_relay!(mode, transport)
    end
  end

  defp assert_namespace_relay!(mode, transport) do
    method = if transport == :websocket, do: "WEBSOCKET", else: "POST"
    reply = if transport == :websocket, do: FakeUpstream.websocket_text_frames(Enum.map(events(), &CodexPooler.JSON.encode!/1)), else: FakeUpstream.sse_stream(Enum.map(events(), &{&1["type"], &1}))
    # provenance: synthetic_adversarial; distinct namespace/function names and colliding declarations, with invented ids, arguments and usage.
    upstream = start_upstream(FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: method, path: "/backend-api/codex/responses", json: [valid: true, forbidden: ["previous_response_id"]], respond: reply)]))
    setup = gateway_setup(upstream)
    set_model_serving_mode!(model_serving_scope(), setup, mode)
    body = %{"model" => setup.model.exposed_model_id, "input" => @input, "tools" => @tools, "stream" => transport != :json}

    case transport do
      :json ->
        conn = build_conn() |> auth(setup) |> post("/v1/responses", body)
        assert json_response(conn, 200)["output"] == @calls

      :sse ->
        conn = build_conn() |> auth(setup) |> post("/v1/responses", body)
        assert [content_type] = get_resp_header(conn, "content-type")
        assert content_type =~ "text/event-stream"
        decoded = for block <- String.split(response(conn, 200), "\n\n", trim: true), "data: " <> data <- String.split(block, "\n"), data != "[DONE]", do: CodexPooler.JSON.decode!(data)
        assert_events!(decoded)

      :websocket ->
        assert_events!(websocket_events!(setup, body))
    end

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.method == method

    if mode == "full" do
      assert captured.json["tools"] == @tools
      assert captured.json["input"] == @input
    else
      refute Map.has_key?(captured.json, "tools")
      assert captured.json["input"] == [%{"type" => "additional_tools", "role" => "developer", "tools" => @tools} | @input]
    end

    assert :ok = FakeUpstream.verify!(upstream)
  end

  defp assert_events!(events) do
    assert List.last(events)["type"] == "response.completed"
    assert List.last(events)["response"]["output"] == @calls
    assert for(%{"type" => "response.output_item.added", "item" => item} <- events, do: item) == Enum.map(@calls, &%{&1 | "arguments" => "", "status" => "in_progress"})
    assert for(%{"type" => "response.output_item.done", "item" => item} <- events, do: item) == @calls
    arguments = Enum.map(@calls, & &1["arguments"])
    assert for(%{"type" => "response.function_call_arguments.delta", "delta" => delta} <- events, do: delta) == arguments
    assert for(%{"type" => "response.function_call_arguments.done", "arguments" => arguments} <- events, do: arguments) == arguments
  end

  defp events do
    response = %{"id" => "resp_synthetic_namespace", "object" => "response", "created_at" => 1_790_000_000, "model" => "provider-gpt-test-model", "status" => "completed", "output" => @upstream_calls, "usage" => %{"input_tokens" => 5, "output_tokens" => 3, "total_tokens" => 8}}

    item_events =
      @upstream_calls
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} ->
        [
          %{"type" => "response.output_item.added", "output_index" => index, "item" => %{item | "arguments" => "", "status" => "in_progress"}},
          %{"type" => "response.function_call_arguments.delta", "output_index" => index, "item_id" => item["id"], "delta" => item["arguments"]},
          %{"type" => "response.function_call_arguments.done", "output_index" => index, "item_id" => item["id"], "arguments" => item["arguments"]},
          %{"type" => "response.output_item.done", "output_index" => index, "item" => item}
        ]
      end)

    [%{"type" => "response.created", "response" => %{response | "status" => "in_progress", "output" => [], "usage" => nil}}] ++ item_events ++ [%{"type" => "response.completed", "response" => response}]
  end

  defp websocket_events!(setup, body) do
    port = start_public_endpoint!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, "namespace-function-#{System.unique_integer([:positive])}", "/v1/responses")

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(Map.put(body, "type", "response.create")))
      receive_events!(conn, websocket, ref, [])
    after
      Mint.HTTP.close(conn)
    end
  end

  defp receive_events!(conn, websocket, ref, events) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    event = CodexPooler.JSON.decode!(text)
    events = [event | events]

    if event["type"] in ~w(response.completed response.failed response.incomplete error),
      do: Enum.reverse(events),
      else: receive_events!(conn, websocket, ref, events)
  end
end
