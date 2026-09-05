defmodule CodexPooler.Gateway.Runtime.Streaming.StreamUsageObserverTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Finalization.ResponseUsage
  alias CodexPooler.Gateway.Runtime.Streaming.StreamUsageObserver
  alias CodexPooler.Gateway.Transports.Streaming.RetainedBody

  @known_usage %{
    status: "usage_known",
    source: "upstream_usage",
    input_tokens: 16,
    cached_input_tokens: 0,
    output_tokens: 5,
    reasoning_tokens: 0,
    total_tokens: 21,
    service_tier: "priority"
  }

  test "exact candidate object budget is independent of chunk placement" do
    base = Jason.encode!(Map.put(usage(16, 5, 21), "padding", ""))

    for size <- [16_383, 16_384, 16_385] do
      object =
        Jason.encode!(
          Map.put(usage(16, 5, 21), "padding", String.duplicate("x", size - byte_size(base)))
        )

      prefix =
        ~s(event: response.completed\ndata: {"type":"response.completed","service_tier":"priority","usage":)

      stream = prefix <> object <> "}\n\n"

      for split_at <- [
            0,
            byte_size(prefix),
            byte_size(prefix) + size - 1,
            byte_size(prefix) + size
          ] do
        <<first::binary-size(^split_at), second::binary>> = stream
        state = StreamUsageObserver.observe(StreamUsageObserver.new(), first)
        assert StreamUsageObserver.candidate_bytes(state) <= 16_384
        state = StreamUsageObserver.observe(state, second)
        assert StreamUsageObserver.usage(state) == @known_usage == size <= 16_384
      end
    end
  end

  test "event and tier context never retains oversized strings or source allocations" do
    oversized = String.duplicate("x", 290_303)

    frames = [
      "event: response." <> oversized <> "\ndata: {}",
      ~s(data: {"type":") <> oversized <> ~s(","service_tier":") <> oversized <> ~s("}),
      ~s(data: {"type":"response.completed","service_tier":") <>
        oversized <> ~s(","usage":) <> Jason.encode!(usage(16, 5, 21)) <> "}"
    ]

    for frame <- frames do
      state = StreamUsageObserver.observe(StreamUsageObserver.new(), frame)

      for {_key, value} <- state, is_binary(value) do
        assert :binary.referenced_byte_size(value) <= 64
      end

      if measured = StreamUsageObserver.usage(state) do
        assert measured.service_tier == nil
        assert measured.total_tokens == 21
      end
    end

    incomplete = ~s(data: {"padding":") <> oversized <> ~s(","usage":{"input_tokens":16)
    state = StreamUsageObserver.observe(StreamUsageObserver.new(), incomplete)
    assert StreamUsageObserver.candidate_bytes(state) > 0
    assert :binary.referenced_byte_size(state.candidate.buffer) <= 16_384
  end

  test "data-only SSE boundaries reset tier and recover incomplete usage at every split" do
    for newline <- ["\n", "\r\n", "\r"], prior_usage <- ["null}", ~s({"input_tokens":)] do
      prior =
        ~s(data: {"type":"response.created","service_tier":"flex","usage":) <>
          prior_usage <> "\n\n"

      terminal =
        ~s(data: {"type":"response.completed","usage":) <>
          Jason.encode!(usage(16, 5, 21)) <> ~s(,"service_tier":"priority"}\n\n)

      stream = String.replace(prior <> terminal, "\n", newline)

      for split_at <- 0..byte_size(stream) do
        <<first::binary-size(^split_at), second::binary>> = stream

        state =
          StreamUsageObserver.new()
          |> StreamUsageObserver.observe(first)
          |> StreamUsageObserver.observe(second)

        assert StreamUsageObserver.usage(state) == @known_usage
      end
    end
  end

  test "completes pending usage before a later event in the completing chunk" do
    terminal = terminal_event_with_usage_before_tail(@known_usage, String.duplicate("x", 70_000))
    split_at = marker_offset(terminal, ~s("usage")) + 20
    <<first::binary-size(^split_at), completion::binary>> = terminal
    later = sse_event("response.done", %{"type" => "response.done"})

    state =
      StreamUsageObserver.new()
      |> StreamUsageObserver.observe(first)
      |> StreamUsageObserver.observe(completion <> later)

    assert StreamUsageObserver.usage(state) == @known_usage
    assert :binary.referenced_byte_size(state.marker_suffix) <= 64
  end

  test "null and primitive usage cannot consume a following event usage object" do
    terminal = terminal_event_with_usage_before_tail(@known_usage, String.duplicate("x", 70_000))

    for invalid <- [nil, false, 3, "absent", []] do
      prior = usage_event("response.created", invalid, "flex")
      state = StreamUsageObserver.observe(StreamUsageObserver.new(), prior <> terminal)
      assert StreamUsageObserver.usage(state) == @known_usage
    end
  end

  test "recovers coalesced invalid candidates at every transport split with permitted line endings" do
    for newline <- ["\n", "\r\n", "\r"], label <- ["data: ", "data:"] do
      prior = usage_event("response.created", nil, "flex")
      event = terminal_event_with_tier_after_usage(@known_usage)
      stream = String.replace(prior <> prior <> event, "\n", newline)
      stream = String.replace(stream, "data: ", label)

      for split_at <- 0..byte_size(stream) do
        <<first::binary-size(^split_at), second::binary>> = stream

        state =
          StreamUsageObserver.new()
          |> StreamUsageObserver.observe(first)
          |> StreamUsageObserver.observe(second)

        assert StreamUsageObserver.usage(state) == @known_usage,
               "usage lost for split #{split_at}, newline bytes #{byte_size(newline)}"

        assert StreamUsageObserver.diagnostics(state).candidate_count == 3
        assert StreamUsageObserver.candidate_bytes(state) <= 16_384
      end
    end
  end

  test "escaped strings and unrelated nested objects do not supply usage" do
    payload = %{
      "type" => "response.completed",
      "note" => ~s(escaped \\"usage\\": {"input_tokens":500} and } {),
      "nested" => %{"input_tokens" => 500, "output_tokens" => 1, "total_tokens" => 501}
    }

    state =
      StreamUsageObserver.observe(
        StreamUsageObserver.new(),
        sse_event("response.completed", payload)
      )

    assert StreamUsageObserver.usage(state) == nil
    assert StreamUsageObserver.diagnostics(state).classification == "missing"

    measured = Map.put(usage(16, 5, 21), "note", ~s(escaped \\" } {))
    event = usage_event("response.completed", measured, "priority")

    for split_at <- 0..byte_size(event) do
      <<first::binary-size(^split_at), second::binary>> = event

      state =
        StreamUsageObserver.new()
        |> StreamUsageObserver.observe(first)
        |> StreamUsageObserver.observe(second)

      assert StreamUsageObserver.usage(state) == @known_usage
    end
  end

  test "classifies observed failures with finite diagnostics and resets independently" do
    cases = [
      {"missing", sse_event("response.completed", %{"type" => "response.completed"})},
      {"null", usage_event("response.completed", nil, "priority")},
      {"malformed", usage_event("response.completed", false, "priority")},
      {"malformed", usage_event("response.completed", %{"input_tokens" => nil}, "priority")},
      {"candidate_limit",
       usage_event(
         "response.completed",
         Map.put(usage(16, 5, 21), "padding", String.duplicate("x", 16_384)),
         "priority"
       )},
      {"parser_discontinuity", ~s(event: response.completed\ndata: {"usage":{"input_tokens":)}
    ]

    for {classification, stream} <- cases do
      state = StreamUsageObserver.observe(StreamUsageObserver.new(), stream)
      assert StreamUsageObserver.usage(state) == nil
      diagnostic = StreamUsageObserver.diagnostics(state)
      assert diagnostic.classification == classification
      assert diagnostic.marker_seen == (classification != "missing")
      refute diagnostic.valid_object_seen
      assert diagnostic.version == 1
      assert diagnostic.candidate_count == if(classification == "missing", do: 0, else: 1)

      assert StreamUsageObserver.diagnostics(StreamUsageObserver.reset(state)).classification ==
               "missing"
    end

    repeated = String.duplicate(usage_event("response.created", nil, "flex"), 300)
    state = StreamUsageObserver.observe(StreamUsageObserver.new(), repeated)
    assert StreamUsageObserver.diagnostics(state).candidate_count == 255
    assert StreamUsageObserver.diagnostics(state).classification == "null"
  end

  test "incomplete usage resumes at a real new event for every boundary split" do
    for newline <- ["\n", "\r\n", "\r"] do
      incomplete = ~s(event: response.created\ndata: {"usage":{"input_tokens":)
      terminal = terminal_event_with_tier_after_usage(@known_usage)
      stream = String.replace(incomplete <> "\n\n" <> terminal, "\n", newline)

      for split_at <- 0..byte_size(stream) do
        <<first::binary-size(^split_at), second::binary>> = stream

        state =
          StreamUsageObserver.new()
          |> StreamUsageObserver.observe(first)
          |> StreamUsageObserver.observe(second)

        assert StreamUsageObserver.usage(state) == @known_usage
        assert StreamUsageObserver.diagnostics(state).classification == "known"
      end
    end
  end

  test "blank and absent event labels use payload terminal type and owning service tier" do
    for prefix <- ["", "event:\n", "event: \n"] do
      event = terminal_event_with_tier_after_usage(@known_usage)
      event = String.replace(event, "event: response.completed\n", prefix)

      for split_at <- 0..byte_size(event) do
        <<first::binary-size(^split_at), second::binary>> = event

        state =
          StreamUsageObserver.new()
          |> StreamUsageObserver.observe(first)
          |> StreamUsageObserver.observe(second)

        state =
          StreamUsageObserver.observe(
            state,
            usage_event("response.in_progress", usage(1, 1, 2), "flex")
          )

        assert StreamUsageObserver.usage(state) == @known_usage
      end
    end
  end

  test "invalid nested counters stay unknown and valid canonical precedence is unchanged" do
    measured = %{
      "input_tokens" => 16,
      "input_tokens_details" => %{"cached_tokens" => 4},
      "output_tokens" => 5,
      "output_tokens_details" => %{"reasoning_tokens" => 2},
      "reasoning_tokens" => 3,
      "total_tokens" => 21
    }

    state =
      StreamUsageObserver.observe(
        StreamUsageObserver.new(),
        usage_event("response.completed", measured, "priority")
      )

    assert StreamUsageObserver.usage(state) == %{
             @known_usage
             | cached_input_tokens: 4,
               reasoning_tokens: 2
           }

    for value <- [nil, -1, 1.2, false, %{}, []] do
      invalid = put_in(measured, ["input_tokens_details", "cached_tokens"], value)

      state =
        StreamUsageObserver.observe(
          StreamUsageObserver.new(),
          usage_event("response.completed", invalid, "priority")
        )

      assert StreamUsageObserver.usage(state) == nil
      assert StreamUsageObserver.diagnostics(state).classification == "malformed"
    end
  end

  test "captures terminal usage before retained body truncation discards it" do
    event = terminal_event_with_usage_before_tail(@known_usage, String.duplicate("x", 70_000))

    state = StreamUsageObserver.observe(StreamUsageObserver.new(), event)
    retained = RetainedBody.append(RetainedBody.empty(), event)

    assert byte_size(event) > RetainedBody.max_bytes()
    retained = RetainedBody.read(retained)
    assert byte_size(retained) == RetainedBody.max_bytes()

    assert ResponseUsage.from_sse(retained) == %{
             status: "usage_unknown",
             source: "sse_usage_missing"
           }

    assert StreamUsageObserver.usage(state) == @known_usage
  end

  test "recovers usage and service tier markers split at every byte boundary" do
    event = terminal_event(@known_usage, "")

    usage_offset = marker_offset(event, ~s("usage"))
    tier_offset = marker_offset(event, ~s("service_tier"))

    split_offsets =
      Enum.uniq(
        Enum.to_list(usage_offset..(usage_offset + byte_size(~s("usage")))) ++
          Enum.to_list(tier_offset..(tier_offset + byte_size(~s("service_tier"))))
      )

    for split_at <- split_offsets do
      <<first::binary-size(^split_at), second::binary>> = event

      state =
        StreamUsageObserver.new()
        |> StreamUsageObserver.observe(first)
        |> StreamUsageObserver.observe(second)

      assert StreamUsageObserver.usage(state) == @known_usage
    end
  end

  test "recovers a service tier after usage across every marker byte boundary" do
    event = terminal_event_with_tier_after_usage(@known_usage)
    tier_offset = marker_offset(event, ~s("service_tier"))

    for split_at <- tier_offset..(tier_offset + byte_size(~s("service_tier"))) do
      <<first::binary-size(^split_at), second::binary>> = event

      state =
        StreamUsageObserver.new()
        |> StreamUsageObserver.observe(first)
        |> StreamUsageObserver.observe(second)

      assert StreamUsageObserver.usage(state) == @known_usage
    end
  end

  test "does not inherit a prior event service tier" do
    state =
      StreamUsageObserver.new()
      |> StreamUsageObserver.observe(usage_event("response.in_progress", usage(2, 3, 5), "flex"))
      |> StreamUsageObserver.observe(
        sse_event("response.completed", %{
          "type" => "response.completed",
          "response" => %{"usage" => usage(16, 5, 21)}
        })
      )

    assert StreamUsageObserver.usage(state) == %{@known_usage | service_tier: nil}
  end

  test "keeps candidate context bounded and abandons oversized usage objects" do
    oversized =
      sse_event("response.completed", %{
        "type" => "response.completed",
        "response" => %{
          "usage" => %{
            "input_tokens" => 16,
            "cached_input_tokens" => 0,
            "output_tokens" => 5,
            "reasoning_tokens" => 0,
            "total_tokens" => 21,
            "padding" => String.duplicate("x", StreamUsageObserver.max_candidate_bytes())
          }
        }
      })

    state = StreamUsageObserver.observe(StreamUsageObserver.new(), oversized)

    assert StreamUsageObserver.usage(state) == nil
    assert StreamUsageObserver.candidate_bytes(state) <= StreamUsageObserver.max_candidate_bytes()
    assert :binary.referenced_byte_size(state.marker_suffix) <= 64
  end

  test "abandons a truncated usage candidate when the next explicit event begins" do
    truncated =
      ~s(event: response.in_progress\ndata: {"type":"response.in_progress","usage":{"padding":") <>
        String.duplicate("x", StreamUsageObserver.max_candidate_bytes() - 256)

    state = StreamUsageObserver.observe(StreamUsageObserver.new(), truncated)

    assert StreamUsageObserver.candidate_bytes(state) > 0
    assert StreamUsageObserver.candidate_bytes(state) <= StreamUsageObserver.max_candidate_bytes()

    state =
      StreamUsageObserver.observe(
        state,
        usage_event("response.completed", usage(16, 5, 21), "priority")
      )

    assert StreamUsageObserver.usage(state) == @known_usage
    assert StreamUsageObserver.candidate_bytes(state) == 0
  end

  test "recovers the next explicit event boundary split across transport chunks" do
    truncated =
      ~s(event: response.in_progress\ndata: {"type":"response.in_progress","usage":{"padding":") <>
        String.duplicate("x", StreamUsageObserver.max_candidate_bytes() - 256)

    terminal = usage_event("response.completed", usage(16, 5, 21), "priority")

    for split_at <- 1..(byte_size("event:") - 1) do
      <<first::binary-size(^split_at), second::binary>> = terminal

      state =
        StreamUsageObserver.new()
        |> StreamUsageObserver.observe(truncated)
        |> StreamUsageObserver.observe(first)
        |> StreamUsageObserver.observe(second)

      assert StreamUsageObserver.usage(state) == @known_usage
      assert StreamUsageObserver.candidate_bytes(state) == 0
    end
  end

  test "terminal usage replaces progress usage and cannot be replaced afterward" do
    progress = usage_event("response.in_progress", usage(2, 3, 5), "default")
    terminal = usage_event("response.incomplete", usage(16, 5, 21), "priority")
    later = usage_event("response.in_progress", usage(100, 100, 200), "flex")

    state =
      StreamUsageObserver.new()
      |> StreamUsageObserver.observe(progress)
      |> StreamUsageObserver.observe(terminal)
      |> StreamUsageObserver.observe(later)

    assert StreamUsageObserver.usage(state) == @known_usage
  end

  test "latest valid nonterminal wins while malformed and missing usage cannot erase it" do
    first = usage_event("response.in_progress", usage(2, 3, 5), "default")
    second = usage_event("response.in_progress", usage(16, 5, 21), "priority")

    malformed =
      usage_event(
        "response.in_progress",
        %{"input_tokens" => -1, "output_tokens" => 5, "total_tokens" => 4},
        "flex"
      )

    missing = sse_event("response.in_progress", %{"type" => "response.in_progress"})

    state =
      StreamUsageObserver.new()
      |> StreamUsageObserver.observe(first)
      |> StreamUsageObserver.observe(second)
      |> StreamUsageObserver.observe(malformed)
      |> StreamUsageObserver.observe(missing)

    assert StreamUsageObserver.usage(state) == @known_usage
  end

  test "preserves all response usage precedence paths" do
    fallback = %{@known_usage | input_tokens: 1, output_tokens: 1, total_tokens: 2}
    progress = usage_event("response.in_progress", usage(2, 3, 5), "default")
    terminal = usage_event("response.completed", usage(16, 5, 21), "priority")
    later = usage_event("response.in_progress", usage(100, 100, 200), "flex")

    empty = StreamUsageObserver.new()
    progress_state = StreamUsageObserver.observe(empty, progress)
    terminal_state = StreamUsageObserver.observe(progress_state, terminal)
    later_state = StreamUsageObserver.observe(terminal_state, later)

    assert StreamUsageObserver.resolve(empty, fallback) == fallback
    assert StreamUsageObserver.resolve(progress_state, fallback).total_tokens == 5
    assert StreamUsageObserver.resolve(terminal_state, fallback) == @known_usage
    assert StreamUsageObserver.resolve(later_state, fallback) == @known_usage
  end

  test "reset clears failed-candidate usage and parser context" do
    stale = usage_event("response.in_progress", usage(50, 25, 75), "flex")

    state =
      StreamUsageObserver.new()
      |> StreamUsageObserver.observe(stale)
      |> StreamUsageObserver.reset()

    assert StreamUsageObserver.usage(state) == nil
    assert StreamUsageObserver.candidate_bytes(state) == 0

    state =
      StreamUsageObserver.observe(
        state,
        sse_event("response.completed", %{"type" => "response.completed"})
      )

    assert StreamUsageObserver.usage(state) == nil
  end

  test "omitted and malformed usage remain unknown through retained-body fallback" do
    omitted = sse_event("response.completed", %{"type" => "response.completed"})

    malformed =
      usage_event(
        "response.completed",
        %{"input_tokens" => 16, "output_tokens" => 5, "total_tokens" => 20},
        "priority"
      )

    for event <- [omitted, malformed] do
      state = StreamUsageObserver.observe(StreamUsageObserver.new(), event)

      assert StreamUsageObserver.usage(state) == nil
      assert ResponseUsage.from_sse(event)[:status] == "usage_unknown"
    end
  end

  defp terminal_event(usage, tail) do
    sse_event("response.completed", %{
      "type" => "response.completed",
      "response" => %{
        "service_tier" => usage.service_tier,
        "usage" => %{
          "input_tokens" => usage.input_tokens,
          "cached_input_tokens" => usage.cached_input_tokens,
          "output_tokens" => usage.output_tokens,
          "reasoning_tokens" => usage.reasoning_tokens,
          "total_tokens" => usage.total_tokens
        },
        "output" => tail
      }
    })
  end

  defp terminal_event_with_usage_before_tail(usage, tail) do
    payload =
      ~s({"type":"response.completed","response":{"service_tier":#{Jason.encode!(usage.service_tier)},"usage":) <>
        Jason.encode!(%{
          "input_tokens" => usage.input_tokens,
          "cached_input_tokens" => usage.cached_input_tokens,
          "output_tokens" => usage.output_tokens,
          "reasoning_tokens" => usage.reasoning_tokens,
          "total_tokens" => usage.total_tokens
        }) <>
        ~s(,"output":#{Jason.encode!(tail)}}})

    "event: response.completed\ndata: " <> payload <> "\n\n"
  end

  defp terminal_event_with_tier_after_usage(usage) do
    payload =
      ~s({"type":"response.completed","response":{"usage":) <>
        Jason.encode!(%{
          "input_tokens" => usage.input_tokens,
          "cached_input_tokens" => usage.cached_input_tokens,
          "output_tokens" => usage.output_tokens,
          "reasoning_tokens" => usage.reasoning_tokens,
          "total_tokens" => usage.total_tokens
        }) <>
        ~s(,"service_tier":#{Jason.encode!(usage.service_tier)}}})

    "event: response.completed\ndata: " <> payload <> "\n\n"
  end

  defp usage_event(type, usage, service_tier) do
    sse_event(type, %{
      "type" => type,
      "response" => %{"service_tier" => service_tier, "usage" => usage}
    })
  end

  defp usage(input, output, total) do
    %{
      "input_tokens" => input,
      "cached_input_tokens" => 0,
      "output_tokens" => output,
      "reasoning_tokens" => 0,
      "total_tokens" => total
    }
  end

  defp sse_event(event, payload) do
    "event: " <> event <> "\n" <> "data: " <> Jason.encode!(payload) <> "\n\n"
  end

  defp marker_offset(event, marker) do
    {offset, _length} = :binary.match(event, marker)
    offset
  end
end
