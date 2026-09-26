defmodule CodexPoolerWeb.V1.ChatCallIdsControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, gateway_setup: 1, start_upstream: 1]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OpenAICompatibility.Chat

  for mode <- ["full", "lite"], stream? <- [false, true] do
    @mode mode
    @stream? stream?
    test "#{mode} stream=#{stream?} sends distinct bounded matched history IDs over real HTTP", %{conn: conn} do
      scope = model_serving_scope()
      upstream = start_upstream(completed_upstream())
      setup = gateway_setup(upstream)
      set_model_serving_mode!(scope, setup, @mode)
      prefix = String.duplicate("a", 64)
      messages = pair(prefix <> "x", "first") ++ pair(prefix <> "y", "second") ++ pair(prefix, "third")
      request = %{"model" => setup.model.exposed_model_id, "messages" => messages, "stream" => @stream?, "tools" => [%{"type" => "function", "function" => %{"name" => "fixture", "parameters" => %{"type" => "object", "properties" => %{}}}}]}
      response = conn |> auth(setup) |> post("/v1/chat/completions", request)
      assert response.status == 200
      if @stream?, do: assert(response.resp_body =~ "data: [DONE]"), else: assert(json_response(response, 200)["object"] == "chat.completion")
      assert [captured] = FakeUpstream.requests(upstream)
      calls = Enum.filter(captured.json["input"], &(&1["type"] == "function_call"))
      outputs = Enum.filter(captured.json["input"], &(&1["type"] == "function_call_output"))
      assert length(calls) == 3
      assert length(outputs) == 3
      ids = Enum.map(calls, & &1["call_id"])
      assert Enum.map(outputs, & &1["call_id"]) == ids
      assert length(Enum.uniq(ids)) == 3
      assert Enum.all?(ids, &(byte_size(&1) <= 64))
      assert List.last(ids) == prefix
      assert Enum.map(calls, & &1["arguments"]) == ["{}", "{}", "{}"]
      assert Enum.map(outputs, & &1["output"]) == Enum.map(["first", "second", "third"], &[%{"type" => "input_text", "text" => &1}])
      if @mode == "full", do: assert(length(captured.json["tools"]) == 1), else: assert(captured.json["tools"] in [nil, []])
      FakeUpstream.verify!(upstream)
    end
  end

  test "colliding compact IDs reject before upstream dispatch", %{conn: conn} do
    original = String.duplicate("c", 65)
    assert {:ok, normalized} = Chat.coerce(%{"model" => "sample-model", "messages" => pair(original, "synthetic")})
    candidate = hd(normalized.payload["input"])["call_id"]
    upstream = start_upstream({:json, 200, %{"status" => "completed", "output" => []}})
    setup = gateway_setup(upstream)
    response = conn |> auth(setup) |> post("/v1/chat/completions", %{"model" => setup.model.exposed_model_id, "messages" => pair(original, "synthetic") ++ pair(candidate, "synthetic")})
    assert %{"error" => %{"code" => "invalid_request", "param" => "messages", "message" => "tool call IDs collide after normalization"}} = json_response(response, 400)
    assert FakeUpstream.requests(upstream) == []
    FakeUpstream.verify!(upstream)
  end

  defp pair(id, output) do
    [%{"role" => "assistant", "content" => nil, "tool_calls" => [%{"id" => id, "type" => "function", "function" => %{"name" => "fixture", "arguments" => "{}"}}]}, %{"role" => "tool", "tool_call_id" => id, "content" => output}]
  end

  defp completed_upstream do
    # provenance: synthetic_adversarial; serialized call/result IDs at the real HTTP boundary
    FakeUpstream.strict_sequence([
      FakeUpstream.expect_request(
        method: "POST",
        path: "/backend-api/codex/responses",
        json: [valid: true],
        respond: FakeUpstream.sse_stream([{"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_call_ids_fixture", "status" => "completed", "model" => "sample-model", "output" => [], "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}}}])
      )
    ])
  end
end
