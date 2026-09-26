defmodule CodexPooler.Gateway.Runtime.Streaming.StreamUsageObserverTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Finalization.ResponseUsage

  # Usage equality remains exact; declaration evidence has its own boundary tests.
  defp usage_fields(nil), do: nil
  defp usage_fields(usage), do: Map.delete(usage, :model_observation)
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

  @tag slow: "exhaustively checks every byte split across newline and ignored-field variants"
  test "ignored fields and capped event labels preserve records across every transport split" do
    ignored_value = ~s({"usage":{"input_tokens":999},"type":"response.failed"})
    capped_label = String.pad_trailing(" response.completed", 80)

    for newline <- ["\n", "\r", "\r\n"],
        ignored_field <- [":", "id:", "retry:", "unknown:"] do
      stream =
        ignored_field <>
          ignored_value <>
          "\nevent:" <>
          capped_label <>
          "ignored suffix\n" <>
          "data: " <>
          CodexPooler.JSON.encode!(%{
            "type" => "response.in_progress",
            "usage" => usage(16, 5, 21),
            "service_tier" => "priority"
          }) <>
          "\n\n" <>
          usage_event("response.in_progress", usage(1, 1, 2), "flex")

      stream = String.replace(stream, "\n", newline)
      expected = StreamUsageObserver.observe(StreamUsageObserver.new(), stream)
      assert usage_fields(StreamUsageObserver.usage(expected)) == @known_usage
      assert expected.previous_terminal?
      assert StreamUsageObserver.diagnostics(expected).candidate_count == 1

      for split_at <- 0..byte_size(stream) do
        <<first::binary-size(^split_at), second::binary>> = stream

        actual =
          StreamUsageObserver.new()
          |> StreamUsageObserver.observe(first)
          |> StreamUsageObserver.observe(second)

        assert actual == expected
      end
    end
  end

  test "unterminated ignored fields and capped event labels retain only bounded context" do
    for prefix <- [":", "id:", "event:" <> String.duplicate("x", 80)] do
      state = StreamUsageObserver.observe(StreamUsageObserver.new(), prefix)
      expected = %{state | cr?: false}

      for chunk <- ["", "tail", String.duplicate("x", 65_536)] do
        assert StreamUsageObserver.observe(state, chunk) == expected
      end
    end
  end

  test "ignored lines and exhausted event prefixes have a span scanning reduction budget" do
    padding = String.duplicate("x", 1_048_576)
    terminal = usage_event("response.completed", usage(16, 5, 21), "priority")

    for prefix <- [":", "id:", "event:"], chunk_size <- [1_024, 4_096, 16_384, 65_536] do
      stream = prefix <> padding <> "\r\n\r\n" <> terminal
      chunks = chunk_bytes(stream, chunk_size)
      initial = StreamUsageObserver.new()
      {:reductions, before_count} = Process.info(self(), :reductions)
      state = Enum.reduce(chunks, initial, &StreamUsageObserver.observe(&2, &1))
      {:reductions, after_count} = Process.info(self(), :reductions)

      assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage

      assert after_count - before_count < 200_000,
             "#{prefix} at #{chunk_size} bytes used #{after_count - before_count} reductions"
    end
  end

  test "exact candidate object budget is independent of chunk placement" do
    base = CodexPooler.JSON.encode!(Map.put(usage(16, 5, 21), "padding", ""))

    for size <- [16_383, 16_384, 16_385] do
      object =
        CodexPooler.JSON.encode!(Map.put(usage(16, 5, 21), "padding", String.duplicate("x", size - byte_size(base))))

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
        assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage == size <= 16_384
      end
    end
  end

  test "event and tier context never retains oversized strings or source allocations" do
    oversized = String.duplicate("x", 290_303)

    frames = [
      "event: response." <> oversized <> "\ndata: {}",
      ~s(data: {"type":") <> oversized <> ~s(","service_tier":") <> oversized <> ~s("}),
      ~s(data: {"type":"response.completed","service_tier":") <>
        oversized <> ~s(","usage":) <> CodexPooler.JSON.encode!(usage(16, 5, 21)) <> "}"
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
          CodexPooler.JSON.encode!(usage(16, 5, 21)) <> ~s(,"service_tier":"priority"}\n\n)

      stream = String.replace(prior <> terminal, "\n", newline)

      for split_at <- 0..byte_size(stream) do
        <<first::binary-size(^split_at), second::binary>> = stream

        state =
          StreamUsageObserver.new()
          |> StreamUsageObserver.observe(first)
          |> StreamUsageObserver.observe(second)

        assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage
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

    assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage
    assert :binary.referenced_byte_size(state.marker_suffix) <= 64
  end

  test "null and primitive usage cannot consume a following event usage object" do
    terminal = terminal_event_with_usage_before_tail(@known_usage, String.duplicate("x", 70_000))

    for invalid <- [nil, false, 3, "absent", []] do
      prior = usage_event("response.created", invalid, "flex")
      state = StreamUsageObserver.observe(StreamUsageObserver.new(), prior <> terminal)
      assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage
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

        assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage,
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

      assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage
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

        assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage
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

        assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage
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

    assert usage_fields(StreamUsageObserver.usage(state)) == %{
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

    assert usage_fields(ResponseUsage.from_sse(retained)) == %{
             status: "usage_unknown",
             source: "sse_usage_missing"
           }

    assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage
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

      assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage
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

      assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage
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

    assert usage_fields(StreamUsageObserver.usage(state)) == %{@known_usage | service_tier: nil}
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
        "\n\n" <> usage_event("response.completed", usage(16, 5, 21), "priority")
      )

    assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage
    assert StreamUsageObserver.candidate_bytes(state) == 0
  end

  test "recovers the next explicit event boundary split across transport chunks" do
    truncated =
      ~s(event: response.in_progress\ndata: {"type":"response.in_progress","usage":{"padding":") <>
        String.duplicate("x", StreamUsageObserver.max_candidate_bytes() - 256)

    terminal = "\n\n" <> usage_event("response.completed", usage(16, 5, 21), "priority")

    for split_at <- 1..(byte_size("event:") - 1) do
      <<first::binary-size(^split_at), second::binary>> = terminal

      state =
        StreamUsageObserver.new()
        |> StreamUsageObserver.observe(truncated)
        |> StreamUsageObserver.observe(first)
        |> StreamUsageObserver.observe(second)

      assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage
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

    assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage
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

    assert usage_fields(StreamUsageObserver.usage(state)) == @known_usage
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

    assert StreamUsageObserver.resolve(empty, fallback).status == "usage_unknown"
    assert StreamUsageObserver.resolve(nil, fallback) == fallback
    assert StreamUsageObserver.resolve(progress_state, fallback).total_tokens == 5
    assert usage_fields(StreamUsageObserver.resolve(terminal_state, fallback)) == @known_usage
    assert usage_fields(StreamUsageObserver.resolve(later_state, fallback)) == @known_usage
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
      ~s({"type":"response.completed","response":{"service_tier":#{CodexPooler.JSON.encode!(usage.service_tier)},"usage":) <>
        CodexPooler.JSON.encode!(%{
          "input_tokens" => usage.input_tokens,
          "cached_input_tokens" => usage.cached_input_tokens,
          "output_tokens" => usage.output_tokens,
          "reasoning_tokens" => usage.reasoning_tokens,
          "total_tokens" => usage.total_tokens
        }) <>
        ~s(,"output":#{CodexPooler.JSON.encode!(tail)}}})

    "event: response.completed\ndata: " <> payload <> "\n\n"
  end

  defp terminal_event_with_tier_after_usage(usage) do
    payload =
      ~s({"type":"response.completed","response":{"usage":) <>
        CodexPooler.JSON.encode!(%{
          "input_tokens" => usage.input_tokens,
          "cached_input_tokens" => usage.cached_input_tokens,
          "output_tokens" => usage.output_tokens,
          "reasoning_tokens" => usage.reasoning_tokens,
          "total_tokens" => usage.total_tokens
        }) <>
        ~s(,"service_tier":#{CodexPooler.JSON.encode!(usage.service_tier)}}})

    "event: response.completed\ndata: " <> payload <> "\n\n"
  end

  describe "served model" do
    test "the first response object's model is kept through the terminal event" do
      stream =
        sse_event("response.created", %{
          "type" => "response.created",
          "response" => %{"id" => "resp_1", "model" => "gpt-6-luna", "status" => "in_progress"}
        }) <>
          sse_event("response.in_progress", %{
            "type" => "response.in_progress",
            "response" => %{"id" => "resp_1", "model" => "gpt-6-luna"}
          }) <>
          sse_event("response.completed", %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_1",
              "model" => "gpt-6-astra",
              "service_tier" => "priority",
              "usage" => usage(16, 5, 21)
            }
          })

      expected = StreamUsageObserver.observe(StreamUsageObserver.new(), stream)
      assert StreamUsageObserver.served_model(expected) == "gpt-6-luna"
      assert usage_fields(StreamUsageObserver.usage(expected)) == Map.put(@known_usage, :served_model, "gpt-6-luna")
      assert StreamUsageObserver.result(expected).served_model == "gpt-6-luna"

      for split_at <- 0..byte_size(stream) do
        <<first::binary-size(^split_at), second::binary>> = stream

        actual =
          StreamUsageObserver.new()
          |> StreamUsageObserver.observe(first)
          |> StreamUsageObserver.observe(second)

        assert actual == expected
      end
    end

    test "a stream that ends before its terminal event still names the served model" do
      stream =
        sse_event("response.created", %{
          "type" => "response.created",
          "response" => %{"id" => "resp_1", "model" => "gpt-6-luna"}
        })

      state = StreamUsageObserver.observe(StreamUsageObserver.new(), stream)

      assert %{status: "usage_unknown", source: "sse_usage_missing", served_model: "gpt-6-luna"} =
               StreamUsageObserver.result(state)
    end

    test "a terminal event that declares no model records none" do
      state =
        StreamUsageObserver.observe(
          StreamUsageObserver.new(),
          usage_event("response.completed", usage(16, 5, 21), "priority")
        )

      assert StreamUsageObserver.served_model(state) == nil
      refute Map.has_key?(StreamUsageObserver.usage(state), :served_model)
      refute Map.has_key?(StreamUsageObserver.result(state), :served_model)
    end

    test "a root model stands in only when no response object declares one" do
      chat_shape =
        sse_event("chunk", %{
          "model" => "gpt-6-luna",
          "usage" => usage(16, 5, 21),
          "service_tier" => "priority"
        })

      state = StreamUsageObserver.observe(StreamUsageObserver.new(), chat_shape)
      assert StreamUsageObserver.served_model(state) == "gpt-6-luna"

      both =
        sse_event("response.created", %{
          "type" => "response.created",
          "model" => "root-model",
          "response" => %{"id" => "resp_1", "model" => "gpt-6-luna"}
        })

      state = StreamUsageObserver.observe(StreamUsageObserver.new(), both)
      assert StreamUsageObserver.served_model(state) == "gpt-6-luna"
    end

    test "model keys nested in output items are not declarations" do
      stream =
        sse_event("response.output_item.done", %{
          "type" => "response.output_item.done",
          "item" => %{"type" => "image_generation_call", "model" => "gpt-image-1"},
          "response" => %{"output" => [%{"model" => "nested"}]}
        }) <>
          usage_event("response.completed", usage(16, 5, 21), "priority")

      state = StreamUsageObserver.observe(StreamUsageObserver.new(), stream)
      assert StreamUsageObserver.served_model(state) == nil
    end

    test "a declared model that is not a plain identifier is fingerprinted" do
      stream =
        sse_event("response.created", %{
          "type" => "response.created",
          "response" => %{"id" => "resp_1", "model" => "gpt 5.6 luna"}
        })

      state = StreamUsageObserver.observe(StreamUsageObserver.new(), stream)
      assert "sha256_" <> digest = StreamUsageObserver.served_model(state)
      assert String.length(digest) == 12
    end
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
    "event: " <> event <> "\n" <> "data: " <> CodexPooler.JSON.encode!(payload) <> "\n\n"
  end

  defp marker_offset(event, marker) do
    {offset, _length} = :binary.match(event, marker)
    offset
  end

  defp chunk_bytes(<<>>, _size), do: []

  defp chunk_bytes(data, size) when byte_size(data) <= size, do: [data]

  defp chunk_bytes(data, size) do
    <<chunk::binary-size(^size), rest::binary>> = data
    [chunk | chunk_bytes(rest, size)]
  end
end
