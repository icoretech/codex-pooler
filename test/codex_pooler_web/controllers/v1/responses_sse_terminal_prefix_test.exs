defmodule CodexPoolerWeb.V1.ResponsesSSETerminalPrefixTest do
  # When an upstream stream reaches its terminal without having opened the
  # response or streamed its text, the public `/v1/responses` relay prefixes
  # the terminal with the events the Responses streaming contract requires.
  # The SDK stream helpers (openai-python `responses.stream()`, openai-node
  # `responses.stream()`, `@ai-sdk/openai`) reject or drop anything less: a
  # `response.created` snapshot with an output list, every output item
  # appended in order, content parts appended to their message, and text
  # deltas addressed to an announced part (findings#254).
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @response_id "resp_terminal_prefix_fixture"
  @created_at 1_790_000_000
  @upstream_model "provider-gpt-test-model"
  @marker "synthetic terminal-only marker"

  test "a terminal-only upstream stream reaches the client as a complete Responses grammar (Full)" do
    upstream = start_upstream(FakeUpstream.sse_stream([completed([message("msg_prefix_full", @marker)])]))
    setup = gateway_setup(upstream)

    events = stream_events!(setup)

    assert_canonical_message_prefix!(events, "msg_prefix_full")
    assert [captured] = FakeUpstream.requests(upstream)
    refute Map.has_key?(Map.new(captured.headers), "x-openai-internal-codex-responses-lite")
  end

  test "a terminal-only upstream stream reaches the client as a complete Responses grammar (Lite)" do
    upstream = start_upstream(FakeUpstream.sse_stream([completed([message("msg_prefix_lite", @marker)])]))
    setup = gateway_setup(upstream)
    put_serving_mode!(setup, "lite")

    events = stream_events!(setup)

    assert_canonical_message_prefix!(events, "msg_prefix_lite")
    assert [captured] = FakeUpstream.requests(upstream)
    assert Map.new(captured.headers)["x-openai-internal-codex-responses-lite"] == "true"
  end

  test "terminal-only reasoning and tool output is announced in order and never surfaces reasoning text as output text" do
    reasoning = %{
      "id" => "rs_prefix",
      "type" => "reasoning",
      "summary" => [],
      "content" => [%{"type" => "reasoning_text", "text" => "synthetic reasoning body"}]
    }

    call = %{
      "id" => "fc_prefix",
      "type" => "function_call",
      "call_id" => "call_prefix",
      "name" => "lookup",
      "arguments" => "{}",
      "status" => "completed"
    }

    upstream = start_upstream(FakeUpstream.sse_stream([completed([reasoning, call])]))
    setup = gateway_setup(upstream)

    events = stream_events!(setup)
    grammar = assert_responses_grammar!(events)

    assert event_types(events) == [
             "response.created",
             "response.output_item.added",
             "response.output_item.done",
             "response.output_item.added",
             "response.output_item.done",
             "response.completed"
           ]

    assert Enum.map(grammar.items, & &1["id"]) == ["rs_prefix", "fc_prefix"]
    assert grammar.text == %{}
    refute Enum.any?(events, &(&1.event == "response.output_text.delta"))
  end

  test "an upstream that already relayed its output items gets no synthesized text" do
    item = message("msg_prefix_relayed", @marker)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.created", %{"type" => "response.created", "response" => opening_response()}},
          {"response.output_item.done", %{"type" => "response.output_item.done", "output_index" => 0, "item" => item}},
          completed([item])
        ])
      )

    setup = gateway_setup(upstream)

    events = stream_events!(setup)

    assert event_types(events) == ["response.created", "response.output_item.done", "response.completed"]
    assert sequence_numbers(events) == [0, 1, 2]
  end

  test "a canonical provider stream is relayed without any synthesized event" do
    item = message("msg_prefix_canonical", @marker)
    part = hd(item["content"])
    position = %{"item_id" => "msg_prefix_canonical", "output_index" => 0, "content_index" => 0}

    source = [
      {"response.created", %{"type" => "response.created", "response" => opening_response()}},
      {"response.output_item.added", %{"type" => "response.output_item.added", "output_index" => 0, "item" => %{item | "status" => "in_progress", "content" => []}}},
      {"response.content_part.added", Map.merge(position, %{"type" => "response.content_part.added", "part" => %{part | "text" => ""}})},
      {"response.output_text.delta", Map.merge(position, %{"type" => "response.output_text.delta", "delta" => @marker})},
      {"response.output_text.done", Map.merge(position, %{"type" => "response.output_text.done", "text" => @marker})},
      {"response.content_part.done", Map.merge(position, %{"type" => "response.content_part.done", "part" => part})},
      {"response.output_item.done", %{"type" => "response.output_item.done", "output_index" => 0, "item" => item}},
      completed([item])
    ]

    upstream = start_upstream(FakeUpstream.sse_stream(source))
    setup = gateway_setup(upstream)

    events = stream_events!(setup)
    grammar = assert_responses_grammar!(events)

    assert event_types(events) == Enum.map(source, &elem(&1, 0))
    assert grammar.text == %{{0, 0} => @marker}
  end

  defp assert_canonical_message_prefix!(events, item_id) do
    grammar = assert_responses_grammar!(events)

    assert event_types(events) == [
             "response.created",
             "response.output_item.added",
             "response.content_part.added",
             "response.output_text.delta",
             "response.output_text.done",
             "response.content_part.done",
             "response.output_item.done",
             "response.completed"
           ]

    # The opening snapshot states the identity the terminal closes.
    [%{data: created} | _rest] = events

    assert created["response"] == %{
             "id" => @response_id,
             "object" => "response",
             "status" => "in_progress",
             "created_at" => @created_at,
             "model" => @upstream_model,
             "output" => []
           }

    assert grammar.text == %{{0, 0} => @marker}
    assert [%{"id" => ^item_id, "type" => "message"}] = grammar.items

    %{data: terminal} = List.last(events)
    assert terminal["response"]["id"] == @response_id
    assert [%{"id" => ^item_id, "content" => [%{"text" => @marker}]}] = terminal["response"]["output"]
  end

  # Replays the accumulation rules the SDK stream helpers enforce and returns
  # what a client would have accumulated: the announced items in order and
  # the streamed text per {output_index, content_index}.
  defp assert_responses_grammar!(events) do
    assert [%{event: "response.created", data: %{"response" => %{"output" => []}}} | _rest] = events
    assert %{event: "response.completed"} = List.last(events)

    sequence = sequence_numbers(events)
    assert sequence == Enum.sort(Enum.uniq(sequence)), "sequence numbers must strictly increase"

    Enum.reduce(events, %{items: [], parts: %{}, text: %{}, done: MapSet.new()}, fn event, acc ->
      apply_grammar_event!(event.event, event.data, acc)
    end)
  end

  defp apply_grammar_event!("response.output_item.added", %{"output_index" => index, "item" => item}, acc) do
    assert index == length(acc.items), "output items must be appended in order"
    assert is_binary(item["id"]) and item["id"] != ""
    if item["type"] == "message", do: assert(item["content"] == [])
    %{acc | items: acc.items ++ [item]}
  end

  defp apply_grammar_event!("response.content_part.added", %{"output_index" => index, "content_index" => content_index} = data, acc) do
    item = Enum.at(acc.items, index) || flunk("content part for unannounced output #{index}")
    assert item["type"] == "message"
    assert data["item_id"] == item["id"]
    parts = Map.get(acc.parts, index, [])
    assert content_index == length(parts), "content parts must be appended in order"
    %{acc | parts: Map.put(acc.parts, index, parts ++ [data["part"]])}
  end

  defp apply_grammar_event!(type, %{"output_index" => index, "content_index" => content_index} = data, acc)
       when type in ["response.output_text.delta", "response.output_text.done", "response.content_part.done"] do
    item = Enum.at(acc.items, index) || flunk("#{type} for unannounced output #{index}")
    assert data["item_id"] == item["id"]
    part = acc.parts |> Map.get(index, []) |> Enum.at(content_index) || flunk("#{type} for unannounced part")

    case type do
      "response.output_text.delta" ->
        assert part["type"] == "output_text"
        %{acc | text: Map.update(acc.text, {index, content_index}, data["delta"], &(&1 <> data["delta"]))}

      "response.output_text.done" ->
        assert Map.get(acc.text, {index, content_index}, "") == data["text"]
        acc

      "response.content_part.done" ->
        acc
    end
  end

  defp apply_grammar_event!(type, data, _acc) when type in ["response.output_text.delta", "response.output_text.done", "response.content_part.done"] do
    flunk("#{type} without an item envelope: #{inspect(Map.keys(data))}")
  end

  defp apply_grammar_event!("response.output_item.done", %{"output_index" => index, "item" => item}, acc) do
    announced = Enum.at(acc.items, index) || flunk("output item done for unannounced output #{index}")
    assert announced["id"] == item["id"]
    %{acc | done: MapSet.put(acc.done, index)}
  end

  defp apply_grammar_event!("response.output_item.done", _data, _acc), do: flunk("output item done without output_index")

  defp apply_grammar_event!("response.completed", _data, acc) do
    assert MapSet.size(acc.done) == length(acc.items), "every announced item must be closed before the terminal"
    acc
  end

  defp apply_grammar_event!(_type, _data, acc), do: acc

  defp stream_events!(setup) do
    conn =
      build_conn()
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic terminal prefix request",
        "stream" => true
      })

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"

    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      fields = block |> String.split("\n") |> Map.new(&List.to_tuple(String.split(&1, ": ", parts: 2)))

      case fields do
        %{"event" => event, "data" => data} -> [%{event: event, data: CodexPooler.JSON.decode!(data)}]
        _done -> []
      end
    end)
  end

  defp event_types(events), do: Enum.map(events, & &1.event)
  defp sequence_numbers(events), do: Enum.map(events, & &1.data["sequence_number"])

  defp message(id, text) do
    %{
      "id" => id,
      "type" => "message",
      "role" => "assistant",
      "status" => "completed",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
    }
  end

  defp opening_response do
    %{
      "id" => @response_id,
      "object" => "response",
      "created_at" => @created_at,
      "model" => @upstream_model,
      "status" => "in_progress",
      "output" => []
    }
  end

  defp completed(output) do
    {"response.completed",
     %{
       "type" => "response.completed",
       "response" => %{
         "id" => @response_id,
         "object" => "response",
         "created_at" => @created_at,
         "model" => @upstream_model,
         "status" => "completed",
         "output" => output,
         "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
       }
     }}
  end

  defp put_serving_mode!(setup, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%ModelServingOverride{
      pool_id: setup.pool.id,
      exposed_model_id: setup.model.exposed_model_id,
      mode: mode,
      created_at: timestamp,
      updated_at: timestamp
    })
  end
end
