defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketUsageAttributionTest do
  use ExUnit.Case, async: false

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request

  @timeouts %{connect_timeout_ms: 1_000, receive_timeout_ms: 1_000}
  @usage %{"input_tokens" => 7, "output_tokens" => 3, "total_tokens" => 10}

  test "reused connection resets terminal aggregate and retains the original body cap" do
    marker = "synthetic-large-attribution"

    large =
      CodexPooler.JSON.encode!(%{
        "usage" => @usage,
        "attribution" => String.duplicate(marker, 4_000)
      })

    # Attribution sits inside usage and exceeds both retained windows.
    large_usage =
      String.trim_trailing(CodexPooler.JSON.encode!(@usage), "}") <>
        ",\"attribution\":" <> large <> "}"

    first =
      ~s({"type":"response.completed","response":{"status":"completed","usage":) <>
        large_usage <> "}}"

    second =
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed", "usage" => nil}
      })

    {:ok, upstream} =
      FakeUpstream.start_link(
        {:sequence,
         [
           FakeUpstream.websocket_text_frames([first]),
           FakeUpstream.websocket_text_frames([second])
         ]}
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)
    session = start_supervised!({UpstreamWebsocketSession, []})
    observer = self()

    request = %Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: [],
      payload: "{}",
      timeouts: @timeouts,
      writer: fn text -> send(observer, {:frame_digest, digest(text)}) end
    }

    assert {:ok, first_result} = UpstreamWebsocketSession.request(session, request)
    assert first_result.response_usage.status == "usage_known"
    assert first_result.response_usage.total_tokens == 10
    assert byte_size(first_result.body) <= 65_536
    assert_receive {:frame_digest, first_digest}
    assert first_digest == digest(CodexPooler.JSON.encode!(CodexPooler.JSON.decode!(first)))
    refute inspect(first_result.response_usage) =~ marker
    assert byte_size(:erlang.term_to_binary(first_result.response_usage)) < 512

    assert {:ok, second_result} = UpstreamWebsocketSession.request(session, request)
    assert second_result.response_usage.status == "usage_unknown"
    assert second_result.upstream_websocket_connection.reused
    assert_receive {:frame_digest, second_digest}
    assert second_digest == digest(second)
    assert length(FakeUpstream.requests(upstream)) == 2
    assert FakeUpstream.websocket_connection_count(upstream) == 1
  end

  test "mapped delivery preserves upstream aggregate counters without retaining attribution" do
    original =
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed", "usage" => @usage}
      })

    mapped =
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed", "usage" => nil}
      })

    {:ok, upstream} = FakeUpstream.start_link(FakeUpstream.websocket_text_frames([original]))
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    session = start_supervised!({UpstreamWebsocketSession, []})
    observer = self()

    request = %Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: [],
      payload: "{}",
      timeouts: @timeouts,
      message_mapper: fn _ -> mapped end,
      writer: fn text -> send(observer, {:frame_digest, digest(text)}) end
    }

    assert {:ok, result} = UpstreamWebsocketSession.request(session, request)
    assert result.response_usage.total_tokens == 10
    assert_receive {:frame_digest, delivered}
    assert delivered == digest(mapped)
    assert digest(result.body) == digest("data: " <> mapped <> "\n\n")
    assert length(FakeUpstream.requests(upstream)) == 1
  end

  for {tier_kind, tier_bytes} <- [{:valid, 8}, {:unknown, 70}, {:oversized, 140_000}] do
    test "#{tier_kind} service tier does not retain the decoded frame backing binary" do
      tier =
        if unquote(tier_kind) == :valid,
          do: "priority",
          else: String.duplicate("x", unquote(tier_bytes))

      frame =
        CodexPooler.JSON.encode!(%{
          "type" => "response.completed",
          "response" => %{
            "status" => "completed",
            "service_tier" => tier,
            "usage" => Map.put(@usage, "attribution", String.duplicate("a", 200_000))
          }
        })

      {:ok, upstream} = FakeUpstream.start_link(FakeUpstream.websocket_text_frames([frame]))
      on_exit(fn -> FakeUpstream.stop(upstream) end)
      session = start_supervised!({UpstreamWebsocketSession, []})

      request = %Request{
        url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
        headers: [],
        payload: "{}",
        timeouts: @timeouts,
        writer: fn _text -> :ok end
      }

      assert {:ok, result} = UpstreamWebsocketSession.request(session, request)
      assert result.response_usage.status == "usage_known"
      assert result.response_usage.total_tokens == 10
      assert largest_referenced_binary(result.response_usage) < 512

      if unquote(tier_kind) == :valid,
        do: assert(result.response_usage.service_tier == "priority"),
        else: assert(is_nil(result.response_usage.service_tier))

      assert length(FakeUpstream.requests(upstream)) == 1
    end
  end

  defp largest_referenced_binary(value) when is_binary(value),
    do: :binary.referenced_byte_size(value)

  defp largest_referenced_binary(value) when is_map(value),
    do: value |> Map.to_list() |> largest_referenced_binary()

  defp largest_referenced_binary(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> largest_referenced_binary()

  defp largest_referenced_binary(value) when is_list(value),
    do: value |> Enum.map(&largest_referenced_binary/1) |> Enum.max(fn -> 0 end)

  defp largest_referenced_binary(_value), do: 0

  defp digest(frame), do: :crypto.hash(:sha256, frame)
end
