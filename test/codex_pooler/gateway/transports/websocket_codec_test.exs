defmodule CodexPooler.Gateway.Transports.Streaming.WebsocketCodecTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.{CompactionTrigger, RequestOptions}
  alias CodexPooler.Gateway.Transports.Streaming.{StreamProtocol, WebsocketCodec}

  @remote_compaction_v2_fixture_path Path.expand(
                                       "../../../fixtures/codex/rust-v0.149.1-ff29a44391deccde0aba0f8390337d7f3c319ea4/remote_compaction_v2_request.json",
                                       __DIR__
                                     )
  @external_resource @remote_compaction_v2_fixture_path

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
    test "keeps ordinary native Responses websocket creates on passthrough" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [%{"type" => "message", "content" => "ordinary native input"}],
        "stream" => true
      }

      push_frame = fn _frame -> :ok end

      assert {:ok, coerced} =
               WebsocketCodec.coerce_request(
                 payload,
                 native_responses_options(payload),
                 push_frame
               )

      assert coerced.endpoint == "/backend-api/codex/responses"
      assert coerced.payload == payload
      refute Map.has_key?(coerced, :result_adapter)
      assert coerced.request_options.transport.transport == "websocket"
      assert coerced.request_options.transport.upstream_endpoint == coerced.endpoint
      assert coerced.request_options.transport.route_class == "proxy_websocket"
      assert is_function(coerced.request_options.transport.websocket_writer, 1)
      refute coerced.request_options.payload_context.compaction_trigger_bridge?
    end

    test "bridges valid terminal native compaction triggers through canonical compact HTTP" do
      for {client_metadata, result_transport} <- [
            {v2_client_metadata(), :sse},
            {%{"x-codex-turn-metadata" => "not-json"}, :buffered},
            {%{"x-codex-turn-metadata" => Jason.encode!(%{"compaction" => %{}})}, :buffered},
            {remote_compaction_v2_client_metadata(), :sse},
            {nil, :buffered}
          ] do
        payload = native_compaction_trigger_payload(client_metadata)

        assert {:ok, coerced} =
                 WebsocketCodec.coerce_request(
                   payload,
                   native_responses_options(payload),
                   fn _frame -> :ok end
                 )

        assert coerced.endpoint == "/backend-api/codex/responses/compact"

        expected_payload = %{
          "model" => "gpt-example",
          "instructions" => "compact synthetic history",
          "input" => [
            %{"type" => "message", "content" => "visible native input"},
            %{"type" => "compaction_trigger"}
          ],
          "store" => false
        }

        expected_payload =
          if result_transport == :sse,
            do: Map.put(expected_payload, "stream", true),
            else: expected_payload

        assert coerced.payload == expected_payload

        assert is_function(coerced.result_adapter, 1)
        assert coerced.request_options.transport.transport == "http_compact_json"

        assert coerced.request_options.transport.upstream_endpoint ==
                 "/backend-api/codex/responses"

        assert coerced.request_options.transport.route_class == "proxy_compact"
        assert is_nil(coerced.request_options.transport.websocket_writer)
        assert coerced.request_options.payload_context.compaction_trigger_bridge?

        assert coerced.request_options.payload_context.compaction_result_transport ==
                 result_transport

        assert coerced.request_options.payload_context.compaction_result_mode ==
                 :native_websocket
      end
    end

    test "projects the pinned rich Codex compact request identically to the HTTP contract" do
      payload = native_compaction_trigger_payload(remote_compaction_v2_client_metadata())

      assert {:ok, coerced} =
               WebsocketCodec.coerce_request(
                 payload,
                 native_responses_options(payload),
                 fn _frame -> :ok end
               )

      assert {:ok, compact_payload} =
               CompactionTrigger.prepare_bridge("/backend-api/codex/responses", payload)

      http_projection = CompactionTrigger.project_responses_payload(compact_payload, :sse)

      assert coerced.request_options.payload_context.compaction_result_transport == :sse
      assert coerced.payload == http_projection
      assert Jason.encode!(coerced.payload) == Jason.encode!(http_projection)
    end

    test "bridges a singleton native compaction trigger" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [%{"type" => "compaction_trigger"}],
        "stream" => true
      }

      assert {:ok, coerced} =
               WebsocketCodec.coerce_request(
                 payload,
                 native_responses_options(payload),
                 fn _frame -> :ok end
               )

      assert coerced.endpoint == "/backend-api/codex/responses/compact"
      assert coerced.payload["input"] == [%{"type" => "compaction_trigger"}]
      assert coerced.request_options.payload_context.compaction_result_transport == :buffered
    end

    test "rejects malformed native compaction trigger placement without retaining metadata" do
      marker_sentinel = "raw-native-marker-must-not-survive"

      invalid_inputs = [
        [
          %{"type" => "compaction_trigger"},
          %{"type" => "message", "content" => "visible native input"}
        ],
        [
          %{"type" => "message", "content" => "visible native input"},
          %{"type" => "compaction_trigger"},
          %{"type" => "compaction_trigger"}
        ],
        [
          %{"type" => "reasoning", "encrypted_content" => "hidden-only"},
          %{"type" => "compaction_trigger"}
        ]
      ]

      for input <- invalid_inputs do
        payload = %{
          "type" => "response.create",
          "model" => "gpt-example",
          "input" => input,
          "stream" => true,
          "client_metadata" => %{"x-codex-turn-metadata" => marker_sentinel}
        }

        assert {:error, error} =
                 WebsocketCodec.coerce_request(
                   payload,
                   native_responses_options(payload),
                   fn _frame -> :ok end
                 )

        assert error == %{
                 status: 400,
                 code: "invalid_request",
                 message:
                   "compaction_trigger must be the final input item and must follow visible input",
                 param: "input"
               }

        refute inspect(error) =~ marker_sentinel
      end
    end

    test "emits the exact native websocket compaction result wire" do
      payload = native_compaction_trigger_payload(v2_client_metadata())

      assert {:ok, %{result_adapter: result_adapter}} =
               WebsocketCodec.coerce_request(
                 payload,
                 native_responses_options(payload),
                 fn _frame -> :ok end
               )

      source = %{
        "id" => "resp_native_compaction",
        "object" => "response.compaction",
        "output" => [
          %{
            "type" => "compaction_summary",
            "encrypted_content" => "synthetic-native-encrypted",
            "id" => "cmp_native",
            "internal_chat_message_metadata_passthrough" => %{
              "turn_id" => "turn_native"
            },
            "summary" => "must drop"
          }
        ],
        "usage" => %{"input_tokens" => 8, "output_tokens" => 2, "total_tokens" => 10}
      }

      assert {:ok, adapted} =
               result_adapter.(
                 {:ok, %{status: 200, headers: [], raw_body: Jason.encode!(source)}}
               )

      item = %{
        "type" => "compaction",
        "encrypted_content" => "synthetic-native-encrypted",
        "id" => "cmp_native",
        "internal_chat_message_metadata_passthrough" => %{"turn_id" => "turn_native"}
      }

      assert adapted.websocket_messages == [
               %{"type" => "response.output_item.done", "item" => item},
               %{
                 "type" => "response.completed",
                 "response" => %{
                   "id" => "resp_native_compaction",
                   "status" => "completed",
                   "output" => [item],
                   "usage" => %{
                     "input_tokens" => 8,
                     "output_tokens" => 2,
                     "total_tokens" => 10
                   }
                 }
               }
             ]

      refute Map.has_key?(adapted, :raw_body)
      refute Map.has_key?(adapted, :body)
      refute inspect(adapted.websocket_messages) =~ "object"
      refute inspect(adapted.websocket_messages) =~ "stream_id"
      refute inspect(adapted.websocket_messages) =~ "[DONE]"
      refute inspect(adapted.websocket_messages) =~ "must drop"
    end

    test "omits malformed optional native compaction item metadata" do
      payload = native_compaction_trigger_payload(nil)

      assert {:ok, %{result_adapter: result_adapter}} =
               WebsocketCodec.coerce_request(
                 payload,
                 native_responses_options(payload),
                 fn _frame -> :ok end
               )

      source = %{
        "output" => [
          %{
            "type" => "compaction",
            "encrypted_content" => "synthetic-native-encrypted",
            "id" => 7,
            "internal_chat_message_metadata_passthrough" => %{"turn_id" => false}
          }
        ]
      }

      assert {:ok, %{websocket_messages: [done, completed]}} =
               result_adapter.({:ok, %{status: 200, body: source}})

      assert done == %{
               "type" => "response.output_item.done",
               "item" => %{
                 "type" => "compaction",
                 "encrypted_content" => "synthetic-native-encrypted"
               }
             }

      assert completed["response"]["output"] == [done["item"]]
    end

    test "keeps the public compaction websocket result wrapper compatible" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [
          %{"type" => "message", "content" => "visible public input"},
          %{"type" => "compaction_trigger"}
        ]
      }

      assert {:ok, %{result_adapter: result_adapter}} =
               WebsocketCodec.coerce_request(
                 payload,
                 public_responses_options(payload),
                 fn _frame -> :ok end
               )

      source = %{
        "id" => "resp_public_compaction",
        "output" => [
          %{
            "type" => "compaction",
            "encrypted_content" => "synthetic-public-encrypted",
            "id" => nil
          }
        ]
      }

      assert {:ok, %{websocket_messages: [_done, completed]}} =
               result_adapter.({:ok, %{status: 200, body: source}})

      assert completed["response"]["object"] == "response"
    end

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

    test "coerces padded mixed ultrafast service tiers through the shared Responses adapter" do
      for service_tier <- [" UlTrAfAsT ", "\tulTRafast\n"] do
        payload = %{
          "type" => "response.create",
          "model" => "gpt-example",
          "input" => "hello",
          "service_tier" => service_tier
        }

        assert {:ok, coerced} =
                 WebsocketCodec.coerce_request(
                   payload,
                   public_responses_options(payload),
                   fn _frame -> :ok end
                 )

        assert coerced.endpoint == "/backend-api/codex/responses"
        assert coerced.payload["service_tier"] == "ultrafast"
      end
    end

    test "rejects unsupported and non-string service tiers without leaking the input shape" do
      for service_tier <- ["ultra-fast", %{"requested" => "ultrafast"}] do
        payload = %{
          "type" => "response.create",
          "model" => "gpt-example",
          "input" => "hello",
          "service_tier" => service_tier
        }

        assert {:error, error} =
                 WebsocketCodec.coerce_request(
                   payload,
                   public_responses_options(payload),
                   fn _frame -> :ok end
                 )

        assert error.status == 400
        assert error.code == "invalid_request"
        assert error.param == "service_tier"
        refute error.message =~ "ultra-fast"
        refute error.message =~ "requested"
      end
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

      assert WebsocketCodec.continuity_ordered_payload?(
               Jason.encode!(%{
                 "type" => "response.create",
                 "previous_response_id" => "resp_previous",
                 "input" => [
                   %{
                     "type" => "function_call_output",
                     "name" => "lookup_fixture",
                     "output" => nil
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

  defp native_responses_options(payload) do
    RequestOptions.build(%{}, "/backend-api/codex/responses", payload)
  end

  defp native_compaction_trigger_payload(client_metadata) do
    %{
      "type" => "response.create",
      "model" => "gpt-example",
      "instructions" => "compact synthetic history",
      "input" => [
        %{"type" => "message", "content" => "visible native input"},
        %{"type" => "compaction_trigger"}
      ],
      "stream" => true,
      "client_metadata" => client_metadata,
      "include" => ["reasoning.encrypted_content"],
      "tool_choice" => "auto"
    }
  end

  defp v2_client_metadata do
    %{
      "x-codex-turn-metadata" =>
        Jason.encode!(%{"compaction" => %{"implementation" => "responses_compaction_v2"}})
    }
  end

  defp remote_compaction_v2_client_metadata do
    @remote_compaction_v2_fixture_path
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["request", "client_metadata"])
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
