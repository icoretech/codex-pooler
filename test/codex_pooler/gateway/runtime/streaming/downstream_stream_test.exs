defmodule CodexPooler.Gateway.Runtime.Streaming.DownstreamStreamTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Streaming.DownstreamStream
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  describe "endpoint/2" do
    test "selects the typed upstream endpoint from request options" do
      opts = RequestOptions.build(%{}, "/backend-api/codex/responses", %{})

      assert DownstreamStream.endpoint(%{}, opts) == "/backend-api/codex/responses"
    end
  end

  describe "initial_state/2 and normalize_data/4" do
    test "keep public OpenAI chat stream parser state beside the relay target" do
      opts =
        RequestOptions.build(
          %{
            public_openai_chat_stream: true,
            openai_chat_payload: %{"model" => "gpt-example"}
          },
          "/v1/chat/completions",
          %{}
        )

      state = DownstreamStream.initial_state(:websocket, opts)

      assert %{target: :websocket, public_openai_chat: %{buffer: "", model: "gpt-example"}} =
               state

      split_event =
        [
          "event: response.output_text.delta\n",
          "data: ",
          Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "split answer"})
        ]
        |> IO.iodata_to_binary()

      assert {"", state} =
               DownstreamStream.normalize_data(split_event, "/v1/chat/completions", opts, state)

      assert {chunk, _state} =
               DownstreamStream.normalize_data("\n\n", "/v1/chat/completions", opts, state)

      assert chunk =~ "\"object\":\"chat.completion.chunk\""
      assert chunk =~ "\"content\":\"split answer\""
    end

    test "blocks keepalive comments while public OpenAI chat SSE is incomplete" do
      opts =
        RequestOptions.build(
          %{
            public_openai_chat_stream: true,
            openai_chat_payload: %{"model" => "gpt-example"}
          },
          "/v1/chat/completions",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      incomplete =
        [
          "event: response.output_text.delta\n",
          "data: ",
          Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "split answer"})
        ]
        |> IO.iodata_to_binary()

      split_at = div(byte_size(incomplete), 2)
      first = binary_part(incomplete, 0, split_at)
      second = binary_part(incomplete, split_at, byte_size(incomplete) - split_at)

      assert {"", state} =
               DownstreamStream.normalize_data(first, "/v1/chat/completions", opts, state)

      refute DownstreamStream.keepalive_allowed?(state)

      assert {chunk, state} =
               DownstreamStream.normalize_data(
                 second <> "\n\n",
                 "/v1/chat/completions",
                 opts,
                 state
               )

      assert chunk =~ "\"object\":\"chat.completion.chunk\""
      assert chunk =~ "\"content\":\"split answer\""
      assert DownstreamStream.keepalive_allowed?(state)
    end

    test "normalizes oversized public OpenAI chat blocks without raw passthrough" do
      opts =
        RequestOptions.build(
          %{
            public_openai_chat_stream: true,
            openai_chat_payload: %{"model" => "gpt-example"}
          },
          "/v1/chat/completions",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      oversized =
        [
          "event: response.output_text.delta\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.output_text.delta",
            "delta" => String.duplicate("synthetic chat delta ", 5_000)
          })
        ]
        |> IO.iodata_to_binary()

      split_at = StreamProtocol.max_incomplete_sse_block_bytes() + 1
      first = binary_part(oversized, 0, split_at)
      second = binary_part(oversized, split_at, byte_size(oversized) - split_at)

      assert {"", state} =
               DownstreamStream.normalize_data(first, "/v1/chat/completions", opts, state)

      refute DownstreamStream.keepalive_allowed?(state)

      assert {"", state} =
               DownstreamStream.normalize_data(second, "/v1/chat/completions", opts, state)

      refute DownstreamStream.keepalive_allowed?(state)

      assert {chunk, state} =
               DownstreamStream.normalize_data("\n\n", "/v1/chat/completions", opts, state)

      assert chunk =~ "\"object\":\"chat.completion.chunk\""
      assert chunk =~ "synthetic chat delta"
      refute chunk =~ "response.output_text.delta"
      assert DownstreamStream.keepalive_allowed?(state)
    end

    test "passes through non-SSE JSON bodies on backend codex responses stream relay" do
      opts = RequestOptions.build(%{}, "/backend-api/codex/responses", %{"stream" => true})
      state = DownstreamStream.initial_state(:relay, opts)

      json_body = Jason.encode!(%{"id" => "resp_sparse_metadata", "object" => "response"})

      assert {^json_body, ^state} =
               DownstreamStream.normalize_data(
                 json_body,
                 "/backend-api/codex/responses",
                 opts,
                 state
               )
    end

    test "passes through oversized incomplete backend codex SSE prefixes without retaining them" do
      attach_stream_buffer_telemetry()
      opts = RequestOptions.build(%{}, "/backend-api/codex/responses", %{"stream" => true})
      state = DownstreamStream.initial_state(:relay, opts)
      oversized = String.duplicate("data: unavailable-upstream-prefix", 12_000)

      assert {^oversized, state} =
               DownstreamStream.normalize_data(
                 oversized,
                 "/backend-api/codex/responses",
                 opts,
                 state
               )

      assert state.codex_responses_sse_buffer == ""

      assert_receive {[:codex_pooler, :gateway, :stream_buffer, :oversized],
                      %{bytes: bytes, count: 1, max_bytes: 65_536},
                      %{
                        buffer: "codex_responses_sse",
                        endpoint: "/backend-api/codex/responses",
                        route_class: route_class
                      }}

      assert bytes > 65_536
      assert is_binary(route_class)
    end

    test "blocks keepalive comments while public OpenAI Responses SSE is incomplete" do
      opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      incomplete =
        [
          "event: response.created\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.created",
            "response" => %{
              "id" => "resp_public_incomplete_keepalive",
              "tools" => [
                %{
                  "type" => "function",
                  "name" => "synthetic_tool",
                  "description" => String.duplicate("synthetic description ", 4_000)
                }
              ]
            }
          })
        ]
        |> IO.iodata_to_binary()

      split_at = div(byte_size(incomplete), 2)
      first = binary_part(incomplete, 0, split_at)
      second = binary_part(incomplete, split_at, byte_size(incomplete) - split_at)

      assert {"", state} = DownstreamStream.normalize_data(first, "/v1/responses", opts, state)
      refute DownstreamStream.keepalive_allowed?(state)

      assert {_chunk, state} =
               DownstreamStream.normalize_data(second <> "\n\n", "/v1/responses", opts, state)

      assert DownstreamStream.keepalive_allowed?(state)
    end

    test "blocks keepalive comments during oversized public OpenAI Responses passthrough" do
      opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      oversized =
        [
          "event: response.created\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.created",
            "response" => %{
              "id" => "resp_public_oversized_keepalive",
              "tools" => [
                %{
                  "type" => "function",
                  "name" => "synthetic_tool",
                  "description" => String.duplicate("synthetic description ", 5_000)
                }
              ]
            }
          })
        ]
        |> IO.iodata_to_binary()

      split_at = StreamProtocol.max_incomplete_sse_block_bytes() + 1
      first = binary_part(oversized, 0, split_at)
      second = binary_part(oversized, split_at, byte_size(oversized) - split_at)

      assert {^first, state} =
               DownstreamStream.normalize_data(first, "/v1/responses", opts, state)

      refute DownstreamStream.keepalive_allowed?(state)

      assert {^second, state} =
               DownstreamStream.normalize_data(second, "/v1/responses", opts, state)

      refute DownstreamStream.keepalive_allowed?(state)

      assert {"\n\n", state} =
               DownstreamStream.normalize_data("\n\n", "/v1/responses", opts, state)

      assert DownstreamStream.keepalive_allowed?(state)
    end

    test "tracks oversized public OpenAI Responses terminal passthrough" do
      opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      terminal =
        [
          "event: response.completed\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_public_large_terminal",
              "status" => "completed",
              "output" => [
                %{
                  "type" => "message",
                  "content" => [
                    %{
                      "type" => "output_text",
                      "text" => String.duplicate("large terminal text ", 4_000)
                    }
                  ]
                }
              ],
              "usage" => %{"input_tokens" => 7, "output_tokens" => 5, "total_tokens" => 12}
            }
          })
        ]
        |> IO.iodata_to_binary()

      assert byte_size(terminal) > StreamProtocol.max_incomplete_sse_block_bytes()

      split_at = StreamProtocol.max_incomplete_sse_block_bytes() + 1
      first = binary_part(terminal, 0, split_at)
      second = binary_part(terminal, split_at, byte_size(terminal) - split_at)

      assert {^first, state} =
               DownstreamStream.normalize_data(first, "/v1/responses", opts, state)

      assert is_nil(DownstreamStream.terminal_outcome(state))

      assert {^second, state} =
               DownstreamStream.normalize_data(second, "/v1/responses", opts, state)

      assert DownstreamStream.terminal_outcome(state) == :completed
      assert {nil, ^state} = DownstreamStream.synthetic_terminal_failure(state, :interrupted)
    end

    test "tracks failure-coded oversized public OpenAI Responses incomplete passthrough" do
      opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      terminal =
        [
          "event: response.incomplete\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.incomplete",
            "response" => %{
              "id" => "resp_public_large_failed_incomplete",
              "status" => "incomplete",
              "output" => [
                %{
                  "type" => "message",
                  "content" => [
                    %{
                      "type" => "output_text",
                      "text" => String.duplicate("large incomplete text ", 4_000)
                    }
                  ]
                }
              ],
              "incomplete_details" => %{"reason" => "context_length_exceeded"}
            }
          })
        ]
        |> IO.iodata_to_binary()

      assert byte_size(terminal) > StreamProtocol.max_incomplete_sse_block_bytes()

      split_at = StreamProtocol.max_incomplete_sse_block_bytes() + 1
      first = binary_part(terminal, 0, split_at)
      second = binary_part(terminal, split_at, byte_size(terminal) - split_at)

      assert {^first, state} =
               DownstreamStream.normalize_data(first, "/v1/responses", opts, state)

      assert is_nil(DownstreamStream.terminal_outcome(state))

      assert {^second, state} =
               DownstreamStream.normalize_data(second, "/v1/responses", opts, state)

      assert {:failed, failure} = DownstreamStream.terminal_outcome(state)
      assert failure.code == "context_length_exceeded"
      assert failure.event_type == "response.incomplete"
      assert {nil, ^state} = DownstreamStream.synthetic_terminal_failure(state, :interrupted)
    end

    test "prefers specific error.code in oversized public OpenAI Responses failures" do
      opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      terminal =
        [
          "event: response.failed\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.failed",
            "response" => %{
              "id" => "resp_public_large_failed_with_specific_code",
              "status" => "failed",
              "output" => [
                %{
                  "type" => "message",
                  "content" => [
                    %{
                      "type" => "output_text",
                      "text" => String.duplicate("large failed text ", 4_000)
                    }
                  ]
                }
              ],
              "error" => %{
                "type" => "invalid_request_error",
                "code" => "context_length_exceeded"
              }
            },
            "error" => %{
              "type" => "invalid_request_error",
              "code" => "context_length_exceeded"
            }
          })
        ]
        |> IO.iodata_to_binary()

      assert byte_size(terminal) > StreamProtocol.max_incomplete_sse_block_bytes()

      split_at = StreamProtocol.max_incomplete_sse_block_bytes() + 1
      first = binary_part(terminal, 0, split_at)
      second = binary_part(terminal, split_at, byte_size(terminal) - split_at)

      assert {^first, state} =
               DownstreamStream.normalize_data(first, "/v1/responses", opts, state)

      assert is_nil(DownstreamStream.terminal_outcome(state))

      assert {^second, state} =
               DownstreamStream.normalize_data(second, "/v1/responses", opts, state)

      assert {:failed, failure} = DownstreamStream.terminal_outcome(state)
      assert failure.code == "context_length_exceeded"
      assert failure.upstream_code == "context_length_exceeded"
      assert failure.event_type == "response.failed"
    end

    test "copies top-level public Responses terminal error into response failure" do
      opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      failed =
        sse_event("response.failed", %{
          "type" => "response.failed",
          "response" => %{
            "id" => "resp_public_failed_top_level_error",
            "status" => "failed"
          },
          "error" => %{
            "type" => "invalid_request_error",
            "code" => "context_length_exceeded"
          }
        })

      assert {chunk, state} =
               DownstreamStream.normalize_data(failed, "/v1/responses", opts, state)

      assert [%{"event" => "response.failed", "data" => data}] = public_sse_events(chunk)
      assert data["error"]["code"] == "context_length_exceeded"

      assert {:failed, failure} = DownstreamStream.terminal_outcome(state)
      assert failure.event_type == "response.failed"

      assert {data["response"]["error"]["code"], failure.code} ==
               {"context_length_exceeded", "context_length_exceeded"}
    end

    test "synthesizes a sanitized terminal failure with the observed public response id" do
      opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      created =
        sse_event("response.created", %{
          "type" => "response.created",
          "response" => %{"id" => "resp_public_interrupted", "status" => "in_progress"}
        })

      assert {created_chunk, state} =
               DownstreamStream.normalize_data(created, "/v1/responses", opts, state)

      assert created_chunk =~ "event: response.created\n"

      assert {failure, state} =
               DownstreamStream.synthetic_terminal_failure(
                 state,
                 "cookie=raw-upstream-reason"
               )

      assert [%{"event" => "response.failed", "data" => data}] = public_sse_events(failure)
      assert data["type"] == "response.failed"
      assert data["response"]["id"] == "resp_public_interrupted"
      assert data["response"]["status"] == "failed"
      assert data["error"]["code"] == "upstream_stream_error"
      refute Jason.encode!(data) =~ "raw-upstream-reason"

      assert {nil, ^state} = DownstreamStream.synthetic_terminal_failure(state, :interrupted)
    end

    test "tags terminal-missing interruptions only after visible public Responses data" do
      opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      reason = %Finch.TransportError{reason: :closed}
      state = DownstreamStream.initial_state(:relay, opts)

      created =
        sse_event("response.created", %{
          "type" => "response.created",
          "response" => %{"id" => "resp_public_tagged", "status" => "in_progress"}
        })

      assert {_chunk, state} =
               DownstreamStream.normalize_data(created, "/v1/responses", opts, state)

      assert DownstreamStream.terminal_missing_interruption_reason(state, reason) ==
               {:upstream_stream_interrupted, reason}
    end

    test "preserves idle timeout reasons after visible public Responses data" do
      opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      transport_error = %Finch.TransportError{reason: :timeout}
      reason = {:upstream_idle_timeout, transport_error}
      state = DownstreamStream.initial_state(:relay, opts)

      created =
        sse_event("response.created", %{
          "type" => "response.created",
          "response" => %{"id" => "resp_public_timeout", "status" => "in_progress"}
        })

      assert {_chunk, state} =
               DownstreamStream.normalize_data(created, "/v1/responses", opts, state)

      assert DownstreamStream.terminal_missing_interruption_reason(state, reason) == reason
    end

    test "does not tag terminal-missing interruptions before visible public Responses data" do
      opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      reason = %Finch.TransportError{reason: :closed}
      state = DownstreamStream.initial_state(:relay, opts)

      incomplete =
        [
          "event: response.created\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.created",
            "response" => %{"id" => "resp_public_incomplete", "status" => "in_progress"}
          })
        ]
        |> IO.iodata_to_binary()

      assert {"", state} =
               DownstreamStream.normalize_data(incomplete, "/v1/responses", opts, state)

      assert DownstreamStream.terminal_missing_interruption_reason(state, reason) == reason

      keepalive_only_state = DownstreamStream.initial_state(:relay, opts)

      assert {"", keepalive_only_state} =
               DownstreamStream.normalize_data(
                 ": keepalive\n\n",
                 "/v1/responses",
                 opts,
                 keepalive_only_state
               )

      assert DownstreamStream.terminal_missing_interruption_reason(keepalive_only_state, reason) ==
               reason
    end

    test "does not tag terminal-missing interruptions for terminal or non-public states" do
      reason = %Finch.TransportError{reason: :closed}

      responses_opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      terminal_state = DownstreamStream.initial_state(:relay, responses_opts)

      completed =
        sse_event("response.completed", %{
          "type" => "response.completed",
          "response" => %{"id" => "resp_public_completed", "status" => "completed"}
        })

      assert {_chunk, terminal_state} =
               DownstreamStream.normalize_data(
                 completed,
                 "/v1/responses",
                 responses_opts,
                 terminal_state
               )

      assert DownstreamStream.terminal_missing_interruption_reason(terminal_state, reason) ==
               reason

      chat_opts =
        RequestOptions.build(
          %{public_openai_chat_stream: true, openai_chat_payload: %{"model" => "gpt-example"}},
          "/v1/chat/completions",
          %{"stream" => true}
        )

      chat_state = DownstreamStream.initial_state(:relay, chat_opts)
      assert DownstreamStream.terminal_missing_interruption_reason(chat_state, reason) == reason

      backend_opts =
        RequestOptions.build(%{}, "/backend-api/codex/responses", %{"stream" => true})

      backend_state = DownstreamStream.initial_state(:relay, backend_opts)

      assert DownstreamStream.terminal_missing_interruption_reason(backend_state, reason) ==
               reason
    end

    test "reuses a response id observed on a response-bearing nonterminal event" do
      opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      delta =
        sse_event("response.output_text.delta", %{
          "type" => "response.output_text.delta",
          "delta" => "partial public text",
          "response" => %{"id" => "resp_from_delta"}
        })

      assert {_chunk, state} =
               DownstreamStream.normalize_data(delta, "/v1/responses", opts, state)

      assert {failure, _state} =
               DownstreamStream.synthetic_terminal_failure(state, :upstream_interrupted)

      assert [%{"event" => "response.failed", "data" => data}] = public_sse_events(failure)
      assert data["response"]["id"] == "resp_from_delta"
      assert data["error"]["code"] == "upstream_stream_error"
    end

    test "does not synthesize after an upstream terminal has already been observed" do
      opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      failed =
        sse_event("response.failed", %{
          "type" => "response.failed",
          "response" => %{
            "id" => "resp_already_failed",
            "status" => "failed",
            "error" => %{"code" => "server_error", "message" => "synthetic terminal"}
          },
          "error" => %{"code" => "server_error", "message" => "synthetic terminal"}
        })

      assert {_chunk, state} =
               DownstreamStream.normalize_data(failed, "/v1/responses", opts, state)

      assert {nil, ^state} = DownstreamStream.synthetic_terminal_failure(state, :interrupted)
    end

    test "does not synthesize for keepalive comments or malformed non-response data" do
      opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      assert {"", state} =
               DownstreamStream.normalize_data(": keepalive\n\n", "/v1/responses", opts, state)

      assert {nil, ^state} = DownstreamStream.synthetic_terminal_failure(state, :interrupted)

      assert {"", state} =
               DownstreamStream.normalize_data(
                 "not-json-and-not-sse\n\n",
                 "/v1/responses",
                 opts,
                 state
               )

      assert {nil, ^state} = DownstreamStream.synthetic_terminal_failure(state, :interrupted)
    end
  end

  defp public_sse_events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      case public_sse_event(block) do
        nil -> []
        event -> [event]
      end
    end)
  end

  defp public_sse_event(block) do
    lines = String.split(block, "\n")
    event = lines |> Enum.find(&String.starts_with?(&1, "event: ")) |> strip_sse_prefix("event: ")
    data = lines |> Enum.find(&String.starts_with?(&1, "data: ")) |> strip_sse_prefix("data: ")

    if is_binary(event) and is_binary(data) and data != "[DONE]" do
      %{"event" => event, "data" => Jason.decode!(data)}
    end
  end

  defp strip_sse_prefix(nil, _prefix), do: nil
  defp strip_sse_prefix(line, prefix), do: String.replace_prefix(line, prefix, "")

  defp sse_event(event, payload) do
    "event: " <> event <> "\n" <> "data: " <> Jason.encode!(payload) <> "\n\n"
  end

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
