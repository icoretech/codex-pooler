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

  test "captures terminal usage before retained body truncation discards it" do
    event = terminal_event_with_usage_before_tail(@known_usage, String.duplicate("x", 70_000))

    state = StreamUsageObserver.observe(StreamUsageObserver.new(), event)
    retained = RetainedBody.append(RetainedBody.empty(), event)

    assert byte_size(event) > RetainedBody.max_bytes()
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
