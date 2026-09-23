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
    only: [auth: 2, gateway_setup: 1, gateway_setup: 2, start_upstream: 1]

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @response_id "resp_terminal_prefix_fixture"
  @created_at 1_790_000_000
  @upstream_model "provider-gpt-test-model"
  @marker "synthetic terminal-only marker"
  @compaction_content "synthetic-opaque-compaction-content"

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

  # A `/v1/responses` stream whose input ends in `compaction_trigger` is
  # collected from the upstream compaction and replayed to the client as its
  # own stream; it follows the same grammar, as the provider's public stream
  # does (created, output_item.added, output_item.done, completed).
  test "a compaction trigger stream announces its compaction item and opens with the upstream identity" do
    upstream = start_upstream(FakeUpstream.compaction_stream(compaction_payload(%{"id" => "cmp_upstream_fixture"})))
    setup = gateway_setup(upstream, compact?: true)

    body = stream_body!(setup, compaction_trigger_payload(setup))
    events = parse_events(body)
    grammar = assert_responses_grammar!(events)

    assert event_types(events) == [
             "response.created",
             "response.output_item.added",
             "response.output_item.done",
             "response.completed"
           ]

    assert sequence_numbers(events) == [0, 1, 2, 3]

    [%{data: created} | _rest] = events

    assert created["response"] == %{
             "id" => @response_id,
             "object" => "response",
             "status" => "in_progress",
             "created_at" => @created_at,
             "model" => @upstream_model,
             "output" => []
           }

    compaction = %{"type" => "compaction", "encrypted_content" => @compaction_content, "id" => "cmp_upstream_fixture"}
    assert grammar.items == [compaction]

    %{data: terminal} = List.last(events)
    assert terminal["response"]["id"] == @response_id
    assert terminal["response"]["output"] == [compaction]
    assert terminal["response"]["usage"]["total_tokens"] == 8
    assert List.last(String.split(body, "\n\n", trim: true)) == "data: [DONE]"
  end

  test "an id-less upstream compaction item gets a derived id that replay strips before the upstream" do
    for source_id <- [:absent, nil, ""] do
      payload =
        case source_id do
          :absent -> compaction_payload(%{})
          id -> compaction_payload(%{"id" => id})
        end

      upstream = start_upstream(FakeUpstream.compaction_stream(payload))
      setup = gateway_setup(upstream, compact?: true)

      events = stream_events!(setup, compaction_trigger_payload(setup))
      grammar = assert_responses_grammar!(events)

      assert [%{"type" => "compaction", "id" => derived}] = grammar.items
      assert "cmp_" <> suffix = derived
      assert suffix =~ ~r/\A[0-9a-f]{40}\z/
      assert List.last(events).data["response"]["output"] == hd(grammar.items) |> List.wrap()

      # The same item replayed as input reaches the upstream as it produced it.
      replay_upstream = start_upstream(FakeUpstream.sse_stream([completed([message("msg_after_compaction", @marker)])]))
      replay_setup = gateway_setup(replay_upstream)

      conn =
        build_conn()
        |> auth(replay_setup)
        |> post("/v1/responses", %{
          "model" => replay_setup.model.exposed_model_id,
          "stream" => true,
          "store" => false,
          "input" => [
            hd(grammar.items),
            %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic follow-up"}]}
          ]
        })

      assert conn.status == 200
      assert [captured] = FakeUpstream.requests(replay_upstream)
      assert [replayed, _user] = captured.json["input"]
      assert replayed == %{"type" => "compaction", "encrypted_content" => @compaction_content}
    end
  end

  test "a provider compaction id is replayed unchanged" do
    upstream = start_upstream(FakeUpstream.sse_stream([completed([message("msg_after_provider_compaction", @marker)])]))
    setup = gateway_setup(upstream)
    item = %{"type" => "compaction", "encrypted_content" => @compaction_content, "id" => "cmp_provider_assigned"}

    conn =
      build_conn()
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "stream" => true,
        "store" => false,
        "input" => [item, %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic follow-up"}]}]
      })

    assert conn.status == 200
    assert [captured] = FakeUpstream.requests(upstream)
    assert hd(captured.json["input"]) == item
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

  defp stream_events!(setup, payload \\ nil) do
    payload =
      payload ||
        %{"model" => setup.model.exposed_model_id, "input" => "synthetic terminal prefix request", "stream" => true}

    setup |> stream_body!(payload) |> parse_events()
  end

  defp stream_body!(setup, payload) do
    conn = build_conn() |> auth(setup) |> post("/v1/responses", payload)

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    conn.resp_body
  end

  defp parse_events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      fields = block |> String.split("\n") |> Map.new(&List.to_tuple(String.split(&1, ": ", parts: 2)))

      case fields do
        %{"event" => event, "data" => data} -> [%{event: event, data: CodexPooler.JSON.decode!(data)}]
        _done -> []
      end
    end)
  end

  defp compaction_trigger_payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "stream" => true,
      "store" => false,
      # Unanchored: the provider refuses `previous_response_id` over HTTP and
      # an anchored `/v1` request is answered before dispatch (findings#232
      # rows 232-275 and 232-277).
      "input" => [
        %{"type" => "function_call_output", "call_id" => "call_compaction_fixture", "output" => "synthetic tool output"},
        %{"type" => "compaction_trigger"}
      ]
    }
  end

  defp compaction_payload(item_fields) do
    %{
      "id" => @response_id,
      "object" => "response",
      "created_at" => @created_at,
      "model" => @upstream_model,
      "output" => [Map.merge(%{"type" => "compaction", "encrypted_content" => @compaction_content}, item_fields)],
      "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
    }
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
