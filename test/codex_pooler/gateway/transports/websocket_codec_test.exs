defmodule CodexPooler.Gateway.Transports.Streaming.WebsocketCodecTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec

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

    test "emits a safe local failure and settles malformed or unknown websocket results as failed" do
      for result <- [
            %{raw_body: "{malformed-provider-account-private-model-sentinel"},
            %{body: %{"unknown_envelope" => "provider-account-private-model-sentinel"}}
          ] do
        assert {:error,
                %{status: 502, code: "websocket_stream_error", message: "websocket stream failed"}} =
                 WebsocketCodec.deliver_result(result, fn frame ->
                   send(self(), {:safe_failure_frame, frame})
                 end)

        assert_receive {:safe_failure_frame, frame}
        decoded = Jason.decode!(frame)
        assert decoded["type"] == "error"
        assert decoded["code"] == "server_error"
        refute frame =~ "provider-account-private-model-sentinel"
      end
    end

    test "never serializes non-object websocket messages from an upstream result" do
      sentinel = "provider-account-private-model-sentinel"

      assert {:error,
              %{status: 502, code: "websocket_stream_error", message: "websocket stream failed"}} =
               WebsocketCodec.deliver_result(%{websocket_messages: [[sentinel]]}, fn frame ->
                 send(self(), {:safe_non_object_frame, frame})
               end)

      assert_receive {:safe_non_object_frame, frame}
      assert %{"type" => "error", "code" => "server_error"} = Jason.decode!(frame)
      refute frame =~ sentinel
    end
  end

  describe "stream_messages/3" do
    test "returns explicit buffer for split SSE frames without process state" do
      request_id = "websocket-buffer-explicit"

      assert {[], buffer} =
               WebsocketCodec.stream_messages(request_id, "data: {\"type\":\"response.", "")

      assert buffer == "data: {\"type\":\"response."

      assert {[message], ""} =
               WebsocketCodec.stream_messages(
                 request_id,
                 "completed\",\"response\":{\"id\":\"resp_123\"}}\n\n",
                 buffer
               )

      assert Jason.decode!(message)["type"] == "response.completed"
      refute Process.get({:websocket_sse_buffer, request_id})
    end

    test "drops undocumented safety-buffering metadata while preserving the content delta" do
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

      assert {[message], ""} = WebsocketCodec.stream_messages(request_id, sse, "")

      assert %{"type" => "response.output_text.delta", "delta" => content} =
               decoded = Jason.decode!(message)

      assert content == "visible synthetic safety-buffered text"
      refute Map.has_key?(decoded, "safety_buffering")
      refute message =~ "safety-buffering-model-sentinel"
      refute message =~ "user-risk-sentinel"
    end

    test "canonicalizes a decoded SSE terminal identically to a direct JSON message" do
      request_id = "websocket-decoded-sse-terminal"

      frame =
        Jason.encode!(%{
          "type" => "error",
          "error" => %{"code" => "previous_response_not_found"}
        })

      assert {[message], ""} =
               WebsocketCodec.stream_messages(request_id, "data: #{frame}\n\n", "")

      assert {[direct_message], ""} = WebsocketCodec.stream_messages(request_id, frame, "")
      assert message == direct_message

      assert %{"type" => "response.failed", "error" => %{"code" => "stream_incomplete"}} =
               Jason.decode!(message)
    end

    test "fails closed once for scalar, malformed, and unknown complete SSE data" do
      sentinel = "provider-account-private-model-sentinel"

      invalid_blocks = [
        "data: #{Jason.encode!([sentinel])}\n\n",
        "data: {malformed-#{sentinel}\n\n",
        "data: #{Jason.encode!(%{"unknown_envelope" => sentinel})}\n\n"
      ]

      for {block, index} <- Enum.with_index(invalid_blocks) do
        request_id = "websocket-invalid-sse-#{index}"

        assert {[failure], failed_buffer} =
                 WebsocketCodec.stream_messages(request_id, block, "")

        assert failed_buffer != ""
        assert %{"type" => "error", "code" => "server_error"} = Jason.decode!(failure)
        refute failure =~ sentinel

        valid_followup =
          "data: " <>
            Jason.encode!(%{
              "type" => "response.output_text.delta",
              "delta" => "must not be emitted"
            }) <>
            "\n\n"

        assert {[], ^failed_buffer} =
                 WebsocketCodec.stream_messages(request_id, valid_followup, failed_buffer)
      end
    end

    test "fails closed once for scalar direct JSON while retaining valid control SSE blocks" do
      request_id = "websocket-scalar-direct-json"
      sentinel = "provider-account-private-model-sentinel"

      assert {[failure], failed_buffer} =
               WebsocketCodec.stream_messages(request_id, Jason.encode!(sentinel), "")

      assert %{"type" => "error", "code" => "server_error"} = Jason.decode!(failure)
      refute failure =~ sentinel

      assert {[], ^failed_buffer} =
               WebsocketCodec.stream_messages(
                 request_id,
                 Jason.encode!(%{"type" => "response.completed", "response" => %{}}),
                 failed_buffer
               )

      assert {[], ""} =
               WebsocketCodec.stream_messages("websocket-comment", ": keepalive\n\n", "")

      assert {[], ""} =
               WebsocketCodec.stream_messages("websocket-done", "data: [DONE]\n\n", "")
    end

    test "fails closed and latches oversized incomplete SSE buffers" do
      attach_stream_buffer_telemetry()
      request_id = "websocket-buffer-oversized"
      oversized = String.duplicate("data: unavailable-upstream-prefix", 260_000)

      assert {[failure], failed_buffer} =
               WebsocketCodec.stream_messages(request_id, oversized, "")

      assert failed_buffer != ""
      assert %{"type" => "error", "code" => "server_error"} = Jason.decode!(failure)

      assert {[], ^failed_buffer} =
               WebsocketCodec.stream_messages(
                 request_id,
                 "data: " <>
                   Jason.encode!(%{
                     "type" => "response.output_text.delta",
                     "delta" => "must not be emitted"
                   }) <>
                   "\n\n",
                 failed_buffer
               )

      assert_receive {[:codex_pooler, :gateway, :stream_buffer, :oversized],
                      %{bytes: bytes, count: 1, max_bytes: 8_388_608},
                      %{buffer: "websocket_sse", endpoint: "unknown", route_class: "unknown"}}

      assert bytes > 8_388_608
    end
  end

  defp unexpected_push(_frame), do: flunk("websocket stream results should not push directly")

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
