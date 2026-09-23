defmodule CodexPoolerWeb.V1.ResponsesFallbackItemIdReplayTest do
  # The public `/v1/responses` surface gives an output item the upstream sent
  # without an id the fallback id `<type>_<output_index>` (the SDK types and
  # stream helpers require a string id). An SDK client replays those items as
  # input; the Codex backend rejects a `store: false` replay carrying
  # `message_<n>` or `compaction_<n>` (400 `invalid_value` on `input[i].id`)
  # and accepts the same item without an id. The `/v1` input adapter drops
  # exactly that fallback id, so the upstream receives the item as it
  # produced it, and forwards every other id unchanged (findings#254).
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.FakeUpstream
  alias CodexPoolerWeb.Runtime.V1BridgedAnchorSupport, as: BridgedAnchor

  @response_id "resp_fallback_item_id_fixture"
  @marker "synthetic fallback id marker"
  @compaction_content "synthetic-opaque-compaction-content"
  @reasoning_content "synthetic-opaque-reasoning-content"
  @function_call_id "call_" <> String.duplicate("Ab1", 8)
  @custom_call_id "call_" <> String.duplicate("Cd2", 8)

  test "id-less upstream output items round-trip through a public stream and replay without the fallback ids" do
    compaction = %{"type" => "compaction", "encrypted_content" => @compaction_content}
    message = message(nil, @marker)

    upstream = start_upstream(FakeUpstream.sse_stream([completed([compaction, message])]))
    setup = gateway_setup(upstream)

    public_output = setup |> stream_body!(%{"model" => setup.model.exposed_model_id, "input" => "synthetic first turn", "stream" => true}) |> completed_output!()

    # The public surface named the items with their fallback ids.
    assert Enum.map(public_output, & &1["id"]) == ["compaction_0", "message_1"]

    replay_upstream = start_upstream(FakeUpstream.sse_stream([completed([message("msg_after_replay", @marker)])]))
    replay_setup = gateway_setup(replay_upstream)

    replay_status =
      replay_setup
      |> post_responses(%{
        "model" => replay_setup.model.exposed_model_id,
        "stream" => true,
        "store" => false,
        "input" => [user_message("synthetic first turn")] ++ public_output ++ [user_message("synthetic follow-up")]
      })
      |> Map.fetch!(:status)

    assert replay_status == 200
    assert [captured] = FakeUpstream.requests(replay_upstream)
    assert [_user, replayed_compaction, replayed_message, _follow_up] = captured.json["input"]

    assert replayed_compaction == compaction
    refute Map.has_key?(replayed_message, "id")
    assert replayed_message["type"] == "message"
    assert replayed_message["role"] == "assistant"
    assert [%{"type" => "output_text", "text" => @marker}] = replayed_message["content"]
  end

  # An anchored `/v1` tool continuation reaches the provider only bridged onto
  # the upstream websocket connection that produced its anchor (findings#232
  # rows 232-275 and 232-277), so the replay is certified on that path.
  test "a reasoning item carrying encrypted content replays without its fallback id on a tool continuation", %{conn: conn} do
    BridgedAnchor.enable_bridge!()
    upstream = start_upstream(BridgedAnchor.upstream_mode("resp_fallback_item_previous", BridgedAnchor.completed_frames(%{"id" => "resp_fallback_after_reasoning", "output" => [message("msg_after_reasoning", @marker)]})))
    setup = gateway_setup(upstream)

    reasoning = %{"id" => "reasoning_0", "type" => "reasoning", "summary" => [], "encrypted_content" => @reasoning_content}

    conn
    |> BridgedAnchor.post_anchored(setup, %{
      "model" => setup.model.exposed_model_id,
      "store" => false,
      "previous_response_id" => "resp_fallback_item_previous",
      "input" => [reasoning, %{"type" => "function_call_output", "call_id" => "call_fallback_fixture", "output" => "synthetic tool output"}]
    })
    |> BridgedAnchor.assert_completed!("resp_fallback_after_reasoning")

    captured = BridgedAnchor.anchored_request!(upstream)
    assert [replayed_reasoning, _tool_output] = captured.json["input"]
    assert replayed_reasoning == Map.delete(reasoning, "id")
  end

  test "id-less upstream tool calls keep their call_id as the public id and replay without it" do
    # The public surface names an id-less call item by its call_id. The Codex
    # backend refuses a replayed function_call whose id equals its call_id
    # (400 invalid_value on input[i].id, observed in production) and accepts
    # it without an id, so the replay must reach the upstream without one.
    function_call = %{"type" => "function_call", "call_id" => @function_call_id, "name" => "lookup", "arguments" => "{}", "status" => "completed"}
    custom_call = %{"type" => "custom_tool_call", "call_id" => @custom_call_id, "name" => "apply", "input" => "synthetic custom input"}

    upstream = start_upstream(FakeUpstream.sse_stream([completed([function_call, custom_call])]))
    setup = gateway_setup(upstream)

    public_output = setup |> stream_body!(%{"model" => setup.model.exposed_model_id, "input" => "synthetic tool turn", "stream" => true}) |> completed_output!()

    assert Enum.map(public_output, & &1["id"]) == [@function_call_id, @custom_call_id]

    replay_upstream = start_upstream(FakeUpstream.sse_stream([completed([message("msg_after_tool_replay", @marker)])]))
    replay_setup = gateway_setup(replay_upstream)

    tool_outputs = [
      %{"type" => "function_call_output", "call_id" => @function_call_id, "output" => "synthetic tool output"},
      %{"type" => "custom_tool_call_output", "call_id" => @custom_call_id, "output" => "synthetic custom output"}
    ]

    replay_status =
      replay_setup
      |> post_responses(%{
        "model" => replay_setup.model.exposed_model_id,
        "stream" => true,
        "store" => false,
        "input" => [user_message("synthetic tool turn")] ++ public_output ++ tool_outputs
      })
      |> Map.fetch!(:status)

    assert replay_status == 200
    assert [captured] = FakeUpstream.requests(replay_upstream)
    assert [_user, replayed_function_call, replayed_custom_call, _function_output, _custom_output] = captured.json["input"]

    refute Map.has_key?(replayed_function_call, "id")
    assert Map.take(replayed_function_call, ["type", "call_id", "name", "arguments"]) == Map.take(function_call, ["type", "call_id", "name", "arguments"])
    refute Map.has_key?(replayed_custom_call, "id")
    assert Map.take(replayed_custom_call, ["type", "call_id", "name", "input"]) == Map.take(custom_call, ["type", "call_id", "name", "input"])
  end

  test "a tool call's provider id or an id that is not its own call_id reaches the upstream unchanged" do
    upstream = start_upstream(FakeUpstream.sse_stream([completed([message("msg_after_tool_controls", @marker)])]))
    setup = gateway_setup(upstream)

    provider_call = %{"type" => "function_call", "id" => "fc_" <> String.duplicate("3d", 25), "call_id" => @function_call_id, "name" => "lookup", "arguments" => "{}"}
    # The id is another call's call_id, not this item's own.
    crossed_call = %{"type" => "custom_tool_call", "id" => @function_call_id, "call_id" => @custom_call_id, "name" => "apply", "input" => "synthetic custom input"}

    input = [
      user_message("synthetic tool control turn"),
      provider_call,
      crossed_call,
      %{"type" => "function_call_output", "call_id" => @function_call_id, "output" => "synthetic tool output"},
      %{"type" => "custom_tool_call_output", "call_id" => @custom_call_id, "output" => "synthetic custom output"}
    ]

    status =
      setup
      |> post_responses(%{"model" => setup.model.exposed_model_id, "stream" => true, "store" => false, "input" => input})
      |> Map.fetch!(:status)

    assert status == 200
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["input"] |> Enum.slice(1, 2) |> Enum.map(& &1["id"]) == [provider_call["id"], @function_call_id]
  end

  test "provider ids and ids that are not the item's own fallback shape reach the upstream unchanged" do
    upstream = start_upstream(FakeUpstream.sse_stream([completed([message("msg_after_controls", @marker)])]))
    setup = gateway_setup(upstream)

    provider_message = message("msg_" <> String.duplicate("0a", 25), @marker)
    provider_compaction = %{"type" => "compaction", "encrypted_content" => @compaction_content, "id" => "cmp_" <> String.duplicate("1b", 25)}
    # Another type's fallback shape, a non-numeric suffix and a prefix-only
    # match are not this item's fallback id.
    foreign_shape = %{"type" => "compaction", "encrypted_content" => @compaction_content <> "-foreign", "id" => "message_1"}
    non_numeric = message("message_first", @marker)
    longer_prefix = message("messages_1", @marker)

    input = [user_message("synthetic control turn"), provider_message, provider_compaction, foreign_shape, non_numeric, longer_prefix, user_message("synthetic follow-up")]

    status =
      setup
      |> post_responses(%{"model" => setup.model.exposed_model_id, "stream" => true, "store" => false, "input" => input})
      |> Map.fetch!(:status)

    assert status == 200
    assert [captured] = FakeUpstream.requests(upstream)

    assert captured.json["input"] |> Enum.slice(1, 5) |> Enum.map(& &1["id"]) == [
             provider_message["id"],
             provider_compaction["id"],
             "message_1",
             "message_first",
             "messages_1"
           ]
  end

  defp post_responses(setup, payload), do: build_conn() |> auth(setup) |> post("/v1/responses", payload)

  defp stream_body!(setup, payload) do
    conn = post_responses(setup, payload)

    assert conn.status == 200
    conn.resp_body
  end

  defp completed_output!(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.find_value(fn block ->
      fields = block |> String.split("\n") |> Map.new(&List.to_tuple(String.split(&1, ": ", parts: 2)))

      case fields do
        %{"event" => "response.completed", "data" => data} -> CodexPooler.JSON.decode!(data)["response"]["output"]
        _other -> nil
      end
    end) || flunk("no response.completed event in the public stream")
  end

  defp user_message(text), do: %{"role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}

  defp message(id, text) do
    item = %{
      "type" => "message",
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
    }

    if id, do: Map.put(item, "id", id), else: item
  end

  defp completed(output) do
    {"response.completed",
     %{
       "type" => "response.completed",
       "response" => %{
         "id" => @response_id,
         "object" => "response",
         "created_at" => 1_790_000_000,
         "model" => "provider-gpt-test-model",
         "status" => "completed",
         "output" => output,
         "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
       }
     }}
  end
end
