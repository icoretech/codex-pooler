defmodule CodexPooler.Gateway.Runtime.Finalization.ResponseUsageProvenanceTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Finalization.ResponseUsage

  @usage %{"input_tokens" => 10, "output_tokens" => 2, "total_tokens" => 12}
  @nested %{"input_tokens" => 1_000, "output_tokens" => 200, "total_tokens" => 1_200}

  test "complete envelopes cannot borrow counters from null, arrays or nested fields" do
    for event <- [
          %{"usage" => nil, "other" => @nested},
          %{"usage" => [@nested]},
          %{"output" => [%{"usage" => @nested}]},
          %{"usage" => nil, "response" => %{"usage" => @nested}}
        ],
        parse <- [&ResponseUsage.from_sse/1, &ResponseUsage.from_websocket_body/1] do
      assert %{status: "usage_unknown"} = parse.(sse(event))
    end
  end

  test "complete aggregate counters and tier outrank nested counter-shaped objects" do
    event = %{
      "service_tier" => "default",
      "usage" => @usage,
      "z" => %{"usage" => @nested, "service_tier" => "priority"}
    }

    for parse <- [&ResponseUsage.from_sse/1, &ResponseUsage.from_websocket_body/1] do
      assert %{total_tokens: 12, service_tier: "default"} = parse.(sse(event))
    end
  end

  test "strict stream counters reject impossible token subsets" do
    for usage <- [
          Map.put(@usage, "cached_input_tokens", 11),
          Map.merge(@usage, %{"cached_input_tokens" => 6, "cache_write_tokens" => 5}),
          Map.put(@usage, "reasoning_tokens", 3)
        ] do
      assert %{status: "usage_unknown", source: "invalid_usage_tokens"} =
               ResponseUsage.from_stream_event(%{"usage" => usage})
    end
  end

  test "root aggregate usage cannot borrow a nested response service tier" do
    for tier <- [nil, "priority"] do
      event = %{
        "usage" => @usage,
        "service_tier" => tier,
        "response" => %{"service_tier" => "flex", "usage" => @nested}
      }

      assert %{total_tokens: 12, service_tier: ^tier} = ResponseUsage.from_stream_event(event)
    end
  end

  test "a terminal aggregate is not replaced by a later progress event" do
    body =
      sse(%{"type" => "response.completed", "usage" => @usage}) <>
        sse(%{"type" => "response.in_progress", "usage" => @nested})

    assert %{total_tokens: 12} = ResponseUsage.from_sse(body)
    assert %{total_tokens: 12} = ResponseUsage.from_websocket_body(body)
  end

  test "malformed terminal records cannot reuse previous progress usage" do
    progress = sse(%{"type" => "response.in_progress", "usage" => @usage})

    for terminal <- [
          "event: response.completed\ndata: {\n\n",
          "data: {\nevent: response.failed\n\n",
          "event: response.incomplete\ndata: []\n\n"
        ],
        parse <- [&ResponseUsage.from_sse/1, &ResponseUsage.from_websocket_body/1] do
      assert %{status: "usage_unknown"} = parse.(progress <> terminal)
    end
  end

  test "stream tier metadata is bounded and does not retain the decoded frame" do
    for tier <- ["priority", String.duplicate("x", 70), String.duplicate("x", 140_000)] do
      decoded =
        CodexPooler.JSON.decode!(
          CodexPooler.JSON.encode!(%{
            "usage" => Map.put(@usage, "attribution", String.duplicate("x", 200_000)),
            "service_tier" => tier
          })
        )

      assert %{status: "usage_known", total_tokens: 12} =
               usage =
               ResponseUsage.from_stream_event(decoded)

      if tier == "priority" do
        assert usage.service_tier == "priority"
        assert :binary.referenced_byte_size(usage.service_tier) <= 80
      else
        assert usage.service_tier == nil
      end

      assert byte_size(:erlang.term_to_binary(usage)) < 512
    end
  end

  defp sse(event), do: "data: " <> CodexPooler.JSON.encode!(event) <> "\n\n"
end
