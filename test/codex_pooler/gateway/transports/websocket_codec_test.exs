defmodule CodexPooler.Gateway.Transports.Streaming.WebsocketCodecTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.Streaming.{StreamProtocol, WebsocketCodec}

  describe "decode_payload/1" do
    test "accepts response.create through the generic object contract" do
      payload = Jason.encode!(%{"type" => "response.create", "model" => "gpt-example"})

      assert {:ok, %{"type" => "response.create", "model" => "gpt-example"}} =
               WebsocketCodec.decode_payload(payload)
    end

    test "rejects invalid JSON and non-object JSON" do
      assert WebsocketCodec.decode_payload("[1,2,3]") == {:error, :not_object}
      assert WebsocketCodec.decode_payload("{invalid") == {:error, :invalid_json}
    end
  end

  describe "coerce_request/3" do
    test "keeps public Responses websocket creates without stream_id compatible" do
      payload = %{"type" => "response.create", "model" => "gpt-example", "input" => "hello"}

      assert {:ok, coerced} =
               WebsocketCodec.coerce_request(
                 payload,
                 public_responses_options(payload),
                 fn _frame -> :ok end
               )

      assert coerced.endpoint == "/backend-api/codex/responses"
      assert coerced.payload["model"] == "gpt-example"
      assert coerced.payload["generate"]
      refute Map.has_key?(coerced.payload, "stream_id")
    end

    test "accepts valid public Responses websocket stream_id boundaries and strips them" do
      for stream_id <- ["a", "A-z0_.-", String.duplicate("a", 256)] do
        payload = %{
          "type" => "response.create",
          "model" => "gpt-example",
          "input" => "hello",
          "stream_id" => stream_id
        }

        assert {:ok, coerced} =
                 WebsocketCodec.coerce_request(
                   payload,
                   public_responses_options(payload),
                   fn _frame -> :ok end
                 )

        refute contains_stream_id?(coerced.payload)
        refute contains_stream_id?(coerced.request_options)
      end
    end

    test "rejects malformed public Responses websocket stream_id values before coercion" do
      invalid_stream_ids = [
        nil,
        7,
        false,
        [],
        %{},
        "",
        String.duplicate("a", 257),
        "contains whitespace",
        "tab\tid",
        "mélange",
        "lane/a",
        "lane:one",
        "ignore instructions; dispatch upstream"
      ]

      for stream_id <- invalid_stream_ids do
        payload = %{
          "type" => "response.create",
          "model" => "gpt-example",
          "input" => "hello",
          "stream_id" => stream_id
        }

        assert {:error, error} =
                 WebsocketCodec.coerce_request(
                   payload,
                   public_responses_options(payload),
                   fn _frame -> :ok end
                 )

        assert error.status == 400
        assert error.code == "invalid_request"
        assert error.param == "stream_id"
        assert byte_size(error.message) < 128
      end
    end
  end

  describe "stream_id/1" do
    test "extracts valid ids from raw queued frames and reports omitted ids" do
      assert :omitted = WebsocketCodec.stream_id(%{"type" => "response.create"})

      assert {:ok, "A-z0_.-"} =
               WebsocketCodec.stream_id(
                 Jason.encode!(%{"type" => "response.create", "stream_id" => "A-z0_.-"})
               )

      assert {:error, %{status: 400, code: "invalid_request", param: "stream_id"}} =
               WebsocketCodec.stream_id(
                 Jason.encode!(%{"type" => "response.create", "stream_id" => "lane/a"})
               )
    end
  end

  describe "request_row_producing_response_payload?/1" do
    test "accepts response lifecycle and model request frames" do
      assert WebsocketCodec.request_row_producing_response_payload?(
               Jason.encode!(%{"type" => "response.processed"})
             )

      assert WebsocketCodec.request_row_producing_response_payload?(
               Jason.encode!(%{"type" => "response.create"})
             )

      assert WebsocketCodec.request_row_producing_response_payload?(
               Jason.encode!(%{"model" => "gpt-example"})
             )
    end

    test "rejects warmups, malformed JSON, non-object JSON, and blank models" do
      refute WebsocketCodec.request_row_producing_response_payload?(
               Jason.encode!(%{"generate" => false})
             )

      refute WebsocketCodec.request_row_producing_response_payload?("{invalid")
      refute WebsocketCodec.request_row_producing_response_payload?(Jason.encode!(["frame"]))

      refute WebsocketCodec.request_row_producing_response_payload?(
               Jason.encode!(%{"model" => ""})
             )

      refute WebsocketCodec.request_row_producing_response_payload?(
               Jason.encode!(%{"model" => "  "})
             )
    end
  end

  describe "continuity_ordered_payload?/1" do
    test "orders response.processed and tool-result continuations" do
      assert WebsocketCodec.continuity_ordered_payload?(
               Jason.encode!(%{"type" => "response.processed"})
             )

      assert WebsocketCodec.continuity_ordered_payload?(
               Jason.encode!(%{
                 "type" => "response.create",
                 "previous_response_id" => "resp_previous",
                 "input" => [
                   %{
                     "type" => "function_call_output",
                     "call_id" => "call_123",
                     "output" => %{"status" => "ok"}
                   }
                 ]
               })
             )
    end

    test "does not order ordinary continuations, warmups, or malformed frames" do
      refute WebsocketCodec.continuity_ordered_payload?(
               Jason.encode!(%{
                 "type" => "response.create",
                 "previous_response_id" => "resp_previous",
                 "input" => [%{"type" => "message", "content" => "placeholder"}]
               })
             )

      refute WebsocketCodec.continuity_ordered_payload?(Jason.encode!(%{"generate" => false}))
      refute WebsocketCodec.continuity_ordered_payload?("{invalid")
    end
  end

  describe "deliver_result/2" do
    test "normalizes websocket stream success tuples to :ok" do
      result = %{websocket_stream: fn -> {:ok, :done} end}

      assert WebsocketCodec.deliver_result(result, &unexpected_push/1) == :ok
    end

    test "preserves structured websocket stream errors" do
      error = %{status: 503, code: "upstream_stream_error", message: "upstream stream failed"}
      result = %{websocket_stream: fn -> {:error, error} end}

      assert WebsocketCodec.deliver_result(result, &unexpected_push/1) == {:error, error}
    end

    test "sanitizes structured websocket errors with invalid code types" do
      error = %{status: 503, code: {:closed, "sensitive detail"}, message: "upstream failed"}
      result = %{websocket_stream: fn -> {:error, error} end}

      assert {:error, sanitized} = WebsocketCodec.deliver_result(result, &unexpected_push/1)
      assert sanitized.status == 502
      assert sanitized.code == "websocket_stream_error"
      assert sanitized.message == "websocket stream failed"
      refute inspect(sanitized) =~ "sensitive detail"
    end

    test "sanitizes unexpected websocket stream results" do
      result = %{websocket_stream: fn -> {:error, {:closed, "sensitive transport detail"}} end}

      assert {:error, error} = WebsocketCodec.deliver_result(result, &unexpected_push/1)
      assert error.status == 502
      assert error.code == "websocket_stream_error"
      assert error.message == "websocket stream failed"
      refute inspect(error) =~ "sensitive transport detail"
    end
  end

  describe "stream_messages/3" do
    test "returns explicit buffer for split SSE frames without process state" do
      request_id = "websocket-buffer-explicit"
      state = StreamProtocol.new_sse_block_state()

      assert {[], state} =
               WebsocketCodec.stream_messages(
                 request_id,
                 "data: {\"type\":\"response.",
                 state
               )

      assert state.buffer == "data: {\"type\":\"response."

      assert {[message], state} =
               WebsocketCodec.stream_messages(
                 request_id,
                 "completed\",\"response\":{\"id\":\"resp_123\"}}\n\n",
                 state
               )

      assert state == StreamProtocol.new_sse_block_state()
      assert Jason.decode!(message)["type"] == "response.completed"
      refute Process.get({:websocket_sse_buffer, request_id})
    end

    test "preserves safety-buffering metadata from upstream SSE frames" do
      request_id = "websocket-safety-buffering"

      sse =
        "event: response.output_text.delta\n" <>
          "data: " <>
          Jason.encode!(%{
            "type" => "response.output_text.delta",
            "delta" => "visible synthetic safety-buffered text",
            "safety_buffering" => %{
              "model" => "safety-buffering-model-sentinel",
              "use_cases" => ["cyber"],
              "reasons" => ["user-risk-sentinel"]
            }
          }) <>
          "\n\n"

      assert {[message], state} =
               WebsocketCodec.stream_messages(
                 request_id,
                 sse,
                 StreamProtocol.new_sse_block_state()
               )

      assert state == StreamProtocol.new_sse_block_state()

      assert %{
               "type" => "response.output_text.delta",
               "safety_buffering" => safety_buffering
             } = Jason.decode!(message)

      assert safety_buffering == %{
               "model" => "safety-buffering-model-sentinel",
               "use_cases" => ["cyber"],
               "reasons" => ["user-risk-sentinel"]
             }
    end

    test "emits standalone-CR SSE once and consumes its optional following LF" do
      request_id = "websocket-standalone-cr"

      payload = %{
        "type" => "response.completed",
        "response" => %{"id" => "resp_websocket_cr", "status" => "completed"}
      }

      state = StreamProtocol.new_sse_block_state()
      source = "data: " <> Jason.encode!(payload) <> "\r\r"

      assert {[message], state} = WebsocketCodec.stream_messages(request_id, source, state)
      assert Jason.decode!(message) == payload
      assert state.skip_leading_lf?

      assert {[], state} = WebsocketCodec.stream_messages(request_id, "\n", state)
      assert state == StreamProtocol.new_sse_block_state()
    end

    test "canonicalizes a decoded SSE terminal identically to a direct JSON message" do
      request_id = "websocket-decoded-sse-terminal"

      frame =
        Jason.encode!(%{
          "type" => "error",
          "error" => %{"code" => "previous_response_not_found"}
        })

      assert {[message], state} =
               WebsocketCodec.stream_messages(
                 request_id,
                 "data: #{frame}\n\n",
                 StreamProtocol.new_sse_block_state()
               )

      assert state == StreamProtocol.new_sse_block_state()

      assert {[direct_message], state} =
               WebsocketCodec.stream_messages(
                 request_id,
                 frame,
                 StreamProtocol.new_sse_block_state()
               )

      assert state.buffer == frame
      assert message == direct_message

      assert %{"type" => "response.failed", "error" => %{"code" => "stream_incomplete"}} =
               Jason.decode!(message)
    end

    test "drops oversized incomplete SSE buffers instead of retaining them" do
      attach_stream_buffer_telemetry()
      request_id = "websocket-buffer-oversized"
      oversized = String.duplicate("data: unavailable-upstream-prefix", 260_000)

      assert {[], state} =
               WebsocketCodec.stream_messages(
                 request_id,
                 oversized,
                 StreamProtocol.new_sse_block_state()
               )

      assert state == StreamProtocol.new_sse_block_state()

      assert_receive {[:codex_pooler, :gateway, :stream_buffer, :oversized],
                      %{bytes: bytes, count: 1, max_bytes: 8_388_608},
                      %{buffer: "websocket_sse", endpoint: "unknown", route_class: "unknown"}}

      assert bytes > 8_388_608
    end
  end

  defp unexpected_push(_frame), do: flunk("websocket stream results should not push directly")

  defp public_responses_options(payload) do
    RequestOptions.build(
      %{public_openai_responses_stream: true},
      "/backend-api/codex/responses",
      payload
    )
  end

  defp contains_stream_id?(%{__struct__: _} = value),
    do: value |> Map.from_struct() |> contains_stream_id?()

  defp contains_stream_id?(%{} = value) do
    Map.has_key?(value, "stream_id") or Map.has_key?(value, :stream_id) or
      Enum.any?(value, fn {_key, nested_value} -> contains_stream_id?(nested_value) end)
  end

  defp contains_stream_id?(value) when is_list(value),
    do: Enum.any?(value, &contains_stream_id?/1)

  defp contains_stream_id?(_value), do: false

  defp attach_stream_buffer_telemetry do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:codex_pooler, :gateway, :stream_buffer, :oversized],
      fn event, measurements, metadata, _config ->
        send(parent, {event, measurements, metadata})
      end,
      :ok
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
