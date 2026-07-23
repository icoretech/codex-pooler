defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocolTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  describe "complete_sse_blocks/2" do
    test "bounds oversized incomplete SSE blocks when requested" do
      oversized = String.duplicate("data: unavailable-upstream-prefix", 12_000)

      assert {[], ""} = StreamProtocol.complete_sse_blocks(oversized, bounded?: true)
    end
  end

  describe "terminal_outcome/1" do
    test "classifies ordinary response.incomplete as success-like incomplete" do
      frame =
        sse_event("response.incomplete", %{
          "type" => "response.incomplete",
          "response" => %{
            "id" => "resp_normal_incomplete",
            "status" => "incomplete",
            "incomplete_details" => %{"reason" => "max_output_tokens"},
            "usage" => %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4}
          }
        })

      assert {:ok, outcome} = StreamProtocol.terminal_outcome(frame)
      assert outcome.kind == :incomplete
      assert outcome.event_type == "response.incomplete"
      assert outcome.incomplete_reason == "max_output_tokens"
      assert StreamProtocol.terminal_failure(frame) == :error
    end

    test "classifies failure-coded response.incomplete as failed" do
      frame =
        sse_event("response.incomplete", %{
          "type" => "response.incomplete",
          "response" => %{
            "id" => "resp_failed_incomplete",
            "status" => "incomplete",
            "incomplete_details" => %{"reason" => "context_length_exceeded"}
          }
        })

      assert {:ok, %{kind: :failed, failure: failure}} = StreamProtocol.terminal_outcome(frame)
      assert failure.code == "context_length_exceeded"
      assert failure.event_type == "response.incomplete"

      normalized = StreamProtocol.normalize_codex_responses_sse_data(frame)
      assert [%{"event" => "response.failed", "data" => data}] = public_sse_events(normalized)
      assert data["type"] == "response.failed"
      assert data["response"]["status"] == "failed"
      assert data["error"]["code"] == "context_length_exceeded"
      assert data["response"]["error"]["code"] == "context_length_exceeded"
    end
  end

  @tag :task_1_pin
  test "PIN-P04 backend POST SSE preserves decoded done and legacy JSON bytes across LF and CRLF" do
    fixtures = [
      {"response.done",
       ~s({"type":"response.done","response":{"id":"resp_pin_backend_post_done"}})},
      {nil, ~s({ "id" : "resp_pin_backend_post_legacy" })}
    ]

    for {event_type, json} <- fixtures, newline <- ["\n", "\r\n"] do
      event_line = if event_type, do: "event: #{event_type}#{newline}", else: ""
      source = event_line <> "data: " <> json <> newline <> newline

      normalized = StreamProtocol.normalize_codex_responses_sse_data(source)
      assert {[block], ""} = StreamProtocol.complete_sse_blocks(normalized, bounded?: false)
      assert StreamProtocol.sse_field(block, "data") == json
    end
  end

  describe "normalize_public_openai_responses_sse_data/2" do
    test "preserves oversized split reasoning events until the SSE block is complete" do
      state = StreamProtocol.public_openai_responses_stream_state()

      event =
        sse_event("response.output_item.added", %{
          "type" => "response.output_item.added",
          "output_index" => 0,
          "sequence_number" => 2,
          "item" => %{
            "id" => "rs_oversized_reasoning",
            "type" => "reasoning",
            "summary" => [],
            "encrypted_content" => String.duplicate("synthetic-obfuscated-content", 4_000)
          }
        })

      split_at = StreamProtocol.max_incomplete_sse_block_bytes() + 1
      first = binary_part(event, 0, split_at)
      second = binary_part(event, split_at, byte_size(event) - split_at)

      {first_out, state} =
        StreamProtocol.normalize_public_openai_responses_sse_data(first, state)

      {second_out, _state} =
        StreamProtocol.normalize_public_openai_responses_sse_data(second, state)

      combined = first_out <> second_out

      assert combined == event
      assert [block] = StreamProtocol.complete_sse_blocks(combined, bounded?: false) |> elem(0)
      assert "response.output_item.added" == StreamProtocol.sse_field(block, "event")

      assert %{"item" => %{"type" => "reasoning"}} =
               block
               |> StreamProtocol.sse_field("data")
               |> StreamProtocol.decode_sse_data()
    end

    test "preserves safety-buffering metadata on public Responses stream events" do
      state = StreamProtocol.public_openai_responses_stream_state()

      event =
        sse_event("response.output_text.delta", %{
          "type" => "response.output_text.delta",
          "delta" => "visible synthetic safety-buffered text",
          "safety_buffering" => %{
            "model" => "safety-buffering-model-sentinel",
            "use_cases" => ["cyber"],
            "reasons" => ["user-risk-sentinel"]
          }
        })

      assert {chunk, _state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(event, state)

      assert [%{"event" => "response.output_text.delta", "data" => data}] =
               public_sse_events(chunk)

      assert data["delta"] == "visible synthetic safety-buffered text"

      assert data["safety_buffering"] == %{
               "model" => "safety-buffering-model-sentinel",
               "use_cases" => ["cyber"],
               "reasons" => ["user-risk-sentinel"]
             }
    end

    test "passes keepalive events through without changing terminal state" do
      state = StreamProtocol.public_openai_responses_stream_state()

      event =
        sse_event("keepalive", %{
          "type" => "keepalive",
          "sequence_number" => 1
        })

      assert {chunk, state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(event, state)

      assert [
               %{
                 "event" => "keepalive",
                 "data" => %{"type" => "keepalive", "sequence_number" => 1}
               }
             ] = public_sse_events(chunk)

      refute chunk =~ "event: response.created\n"
      refute chunk =~ "event: response.output_text.delta\n"
      refute chunk =~ "event: response.completed\n"
      refute chunk =~ "event: response.failed\n"

      assert state.terminal_kind == nil
      assert state.terminal_failure == nil
      assert state.summary.terminal_seen == false
      assert state.summary.terminal_kind == nil
      assert state.summary.finish_class == nil
      assert state.summary.visible_seen == false
      assert state.summary.delta_count == 0
    end

    test "synthesizes missing reasoning and message output item ids" do
      state = StreamProtocol.public_openai_responses_stream_state()

      reasoning = %{
        "type" => "reasoning",
        "summary" => [],
        "encrypted_content" => "synthetic-obfuscated-content"
      }

      message = %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => "synthetic terminal text"}]
      }

      stream =
        IO.iodata_to_binary([
          sse_event("response.output_item.added", %{
            "type" => "response.output_item.added",
            "output_index" => 0,
            "item" => reasoning
          }),
          sse_event("response.output_item.done", %{
            "type" => "response.output_item.done",
            "output_index" => 1,
            "item" => message
          }),
          sse_event("response.completed", %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_idless_output_items",
              "status" => "completed",
              "output" => [reasoning, message]
            }
          })
        ])

      assert {chunk, _state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(stream, state)

      events = public_sse_events(chunk)

      assert event_item(events, "response.output_item.added")["id"] == "reasoning_0"
      assert event_item(events, "response.output_item.done")["id"] == "message_1"

      assert %{"data" => %{"response" => %{"output" => [reasoning_output, message_output]}}} =
               Enum.find(events, &(&1["event"] == "response.completed"))

      assert reasoning_output["id"] == "reasoning_0"
      assert message_output["id"] == "message_1"
    end

    test "normalizes terminal response buffers without trailing SSE separator" do
      state = StreamProtocol.public_openai_responses_stream_state()

      terminal =
        [
          "event: response.completed\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_explicit_state",
              "output" => [
                %{
                  "content" => [
                    %{"type" => "output_text", "text" => "split terminal text"}
                  ]
                }
              ]
            }
          })
        ]
        |> IO.iodata_to_binary()

      assert {chunk, state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(terminal, state)

      assert state.terminal_kind == :completed
      assert state.response_id == "resp_explicit_state"
      assert state.summary.created_seen == true
      assert state.summary.visible_seen == true
      assert state.summary.terminal_seen == true
      assert state.summary.terminal_kind == "completed"
      assert state.summary.finish_class == "completed"
      assert chunk =~ "event: response.created\n"
      assert chunk =~ "event: response.output_text.delta\n"
      assert chunk =~ "event: response.completed\n"
      assert chunk =~ "split terminal text"
      refute Process.get({:openai_responses_stream_state, "resp_explicit_state"})
    end

    test "does not classify a conflicting raw-looking completion status as terminal" do
      raw_status = "raw completion content-like marker"
      state = StreamProtocol.public_openai_responses_stream_state()

      terminal =
        sse_event("response.completed", %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_raw_status_summary",
            "status" => raw_status,
            "output" => [
              %{"content" => [%{"type" => "output_text", "text" => "visible output"}]}
            ]
          }
        })

      assert {_chunk, state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(terminal, state)

      assert state.summary.terminal_kind == nil
      assert state.summary.terminal_status == nil
      refute Jason.encode!(state.summary) =~ raw_status
    end

    test "structurally normalizes oversized terminal without trailing SSE separator" do
      state = StreamProtocol.public_openai_responses_stream_state()

      terminal =
        [
          "event: response.completed\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_large_terminal_without_separator",
              "output" => [
                %{
                  "content" => [
                    %{
                      "type" => "output_text",
                      "text" => String.duplicate("terminal passthrough text ", 4_000)
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

      assert {first_output, state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(first, state)

      assert first_output == ""
      assert byte_size(state.buffer) == byte_size(first)
      refute state.passthrough?
      assert StreamProtocol.public_openai_responses_passthrough_terminal_kind(state) == nil

      assert {second_output, state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(second, state)

      events = public_sse_events(second_output)
      assert List.last(events)["event"] == "response.completed"
      assert List.last(events)["data"]["sequence_number"] == 2
      assert state.terminal_kind == :completed
      assert state.sequence.terminal_latched?
      refute state.passthrough?
      assert StreamProtocol.public_openai_responses_passthrough_terminal_kind(state) == nil
    end

    test "accepts SSE fields without a space after the colon" do
      state = StreamProtocol.public_openai_responses_stream_state()

      terminal =
        [
          "event:response.completed\n",
          "data:",
          Jason.encode!(%{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_no_space_sse_fields",
              "output" => [
                %{"content" => [%{"type" => "output_text", "text" => "no-space terminal text"}]}
              ]
            }
          })
        ]
        |> IO.iodata_to_binary()

      assert {chunk, state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(terminal, state)

      assert state.terminal_kind == :completed
      assert state.response_id == "resp_no_space_sse_fields"
      assert state.summary.created_seen == true
      assert state.summary.visible_seen == true
      assert state.summary.terminal_seen == true
      assert state.summary.terminal_kind == "completed"
      assert state.summary.finish_class == "completed"
      assert chunk =~ "event: response.completed\n"
      assert chunk =~ "no-space terminal text"
    end

    test "keeps nonterminal response buffers incomplete until the SSE separator arrives" do
      state = StreamProtocol.public_openai_responses_stream_state()

      event =
        [
          "event: response.output_text.delta\n",
          "data: ",
          Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "split text"})
        ]
        |> IO.iodata_to_binary()

      assert {"", state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(event, state)

      assert {chunk, _state} =
               StreamProtocol.normalize_public_openai_responses_sse_data("\n\n", state)

      assert chunk =~ "event: response.output_text.delta\n"
      assert chunk =~ "split text"
    end

    test "emits early response.failed without synthetic success prefix" do
      state = StreamProtocol.public_openai_responses_stream_state()

      failed =
        sse_event("response.failed", %{
          "type" => "response.failed",
          "error" => %{
            "type" => "invalid_request_error",
            "code" => "invalid_request_error",
            "message" => "synthetic stream rejection"
          },
          "response" => %{"id" => "resp_early_failed", "status" => "failed"}
        })

      assert {chunk, _state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(failed, state)

      assert String.starts_with?(chunk, "event: response.failed\n")
      refute chunk =~ "event: response.created\n"
      refute chunk =~ "event: response.output_text.delta\n"
    end

    test "adds redacted nested response error for top-level context overflow failures" do
      state = StreamProtocol.public_openai_responses_stream_state()

      failed =
        sse_event("response.failed", %{
          "type" => "response.failed",
          "error" => %{
            "type" => "invalid_request_error",
            "code" => "context_length_exceeded",
            "message" => "synthetic untrusted overflow detail"
          },
          "response" => %{"id" => "resp_context_overflow", "status" => "failed"}
        })

      assert {chunk, _state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(failed, state)

      assert [%{"event" => "response.failed", "data" => data}] = public_sse_events(chunk)
      assert data["error"]["code"] == "context_length_exceeded"
      assert data["error"]["message"] == "upstream request failed"

      assert %{"error" => response_error} = data["response"]
      assert response_error["code"] == "context_length_exceeded"
      assert response_error["message"] == "upstream request failed"
    end

    test "emits early top-level error without synthetic success prefix" do
      state = StreamProtocol.public_openai_responses_stream_state()

      error =
        sse_event("error", %{
          "type" => "error",
          "error" => %{
            "type" => "server_error",
            "code" => "server_error",
            "message" => "synthetic stream error"
          }
        })

      assert {chunk, _state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(error, state)

      assert String.starts_with?(chunk, "event: error\n")
      refute chunk =~ "event: response.created\n"
      refute chunk =~ "event: response.output_text.delta\n"
    end
  end

  describe "synthetic_public_openai_responses_failure_sse/2" do
    test "generates a sanitized response.failed SSE body with a reused response id" do
      raw_reason = "Bearer synthetic-token raw upstream exception should not leak"

      body =
        StreamProtocol.synthetic_public_openai_responses_failure_sse(
          "resp_known_interrupted",
          raw_reason
        )

      assert [%{"event" => "response.failed", "data" => data}] = public_sse_events(body)
      assert data["type"] == "response.failed"
      assert data["response"]["id"] == "resp_known_interrupted"
      assert data["response"]["status"] == "failed"
      assert data["error"]["code"] == "upstream_stream_error"
      assert data["response"]["error"]["code"] == "upstream_stream_error"

      serialized = Jason.encode!(data)

      assert serialized =~
               "upstream request failed: stream interrupted before terminal response event"

      refute serialized =~ "upstream stream interrupted before terminal response event"
      refute serialized =~ "Bearer"
      refute serialized =~ "synthetic-token"
      refute serialized =~ "raw upstream exception"
    end

    test "maps only a committed websocket bridge owner drain to owner_drained" do
      owner_drained =
        StreamProtocol.synthetic_public_openai_responses_failure_sse(
          "resp_owner_drained",
          {:upstream_websocket_bridge, :owner_drained}
        )

      assert [%{"event" => "response.failed", "data" => drained_data}] =
               public_sse_events(owner_drained)

      assert drained_data["error"] == %{
               "code" => "owner_drained",
               "message" => "websocket owner is draining"
             }

      assert drained_data["response"]["error"] == drained_data["error"]

      ordinary =
        StreamProtocol.synthetic_public_openai_responses_failure_sse(
          "resp_owner_drained",
          {:upstream_websocket_bridge, :upstream_websocket_error}
        )

      generic_owner_drained =
        StreamProtocol.synthetic_public_openai_responses_failure_sse(
          "resp_owner_drained",
          :owner_drained
        )

      assert ordinary == generic_owner_drained

      assert [%{"event" => "response.failed", "data" => ordinary_data}] =
               public_sse_events(ordinary)

      assert ordinary_data["error"] == %{
               "code" => "upstream_stream_error",
               "message" =>
                 "upstream request failed: stream interrupted before terminal response event"
             }
    end
  end

  describe "wrapped websocket/direct JSON terminal error frames" do
    test "extracts the first present validated upstream error param by exact precedence" do
      fixtures = [
        {"response.error.param",
         %{"response" => %{"error" => %{"param" => " input[0].content "}}}, "input[0].content"},
        {"error.param", %{"error" => %{"param" => "tools[12].name"}}, "tools[12].name"},
        {"response.status_details.error.param",
         %{"response" => %{"status_details" => %{"error" => %{"param" => "items[9999]"}}}},
         "items[9999]"},
        {"status_details.error.param",
         %{"status_details" => %{"error" => %{"param" => "reasoning.effort"}}},
         "reasoning.effort"},
        {"top-level error param", %{"type" => "error", "param" => "model"}, "model"}
      ]

      for {_label, payload, expected} <- fixtures do
        decoded = Map.put_new(payload, "type", "response.failed")
        assert {:ok, outcome} = StreamProtocol.terminal_outcome(decoded["type"], decoded)
        assert outcome.failure.upstream_error_param == expected
      end

      precedence = %{
        "type" => "error",
        "param" => "fifth",
        "status_details" => %{"error" => %{"param" => "fourth"}},
        "error" => %{"param" => "second"},
        "response" => %{
          "error" => %{"code" => "server_error", "param" => "first"},
          "status_details" => %{"error" => %{"param" => "third"}}
        }
      }

      assert {:ok, failure} = StreamProtocol.terminal_failure(Jason.encode!(precedence))
      assert failure.upstream_error_param == "first"
    end

    test "accepts exact grammar and byte boundaries and rejects unsafe candidates" do
      segment_160 = "a" <> String.duplicate("b", 159)

      accepted = ["a", "A1_b.c2[0].D[9999]", segment_160]

      rejected = [
        "",
        "   ",
        "1field",
        "field..name",
        "field[-1]",
        "field[00]",
        "field[10000]",
        "field[]",
        "field name",
        "https://example.com/path",
        "user@example.com",
        "a" <> String.duplicate("b", 160),
        7,
        %{"raw" => "field"}
      ]

      for candidate <- accepted do
        payload = %{
          "type" => "error",
          "error" => %{"code" => "server_error", "param" => candidate}
        }

        assert {:ok, failure} = StreamProtocol.terminal_failure(Jason.encode!(payload))
        assert failure.upstream_error_param == String.trim(candidate)
      end

      for candidate <- rejected do
        payload = %{
          "type" => "error",
          "error" => %{"code" => "server_error", "param" => candidate}
        }

        assert {:ok, failure} = StreamProtocol.terminal_failure(Jason.encode!(payload))
        assert failure.upstream_error_param == nil
      end

      non_error_top_level = %{
        "type" => "response.failed",
        "param" => "model",
        "error" => %{"code" => "server_error"}
      }

      assert {:ok, failure} = StreamProtocol.terminal_failure(Jason.encode!(non_error_top_level))
      assert failure.upstream_error_param == nil
    end

    test "does not fall through after an invalid first-present param or copy raw sentinels" do
      raw_value = "https://example.com/raw-value-sentinel"
      raw_message = "raw-message-sentinel"

      payload = %{
        "type" => "response.failed",
        "response" => %{
          "error" => %{"code" => "server_error", "param" => raw_value, "message" => raw_message}
        },
        "error" => %{"param" => "valid.lower_priority"},
        "param" => "also_lower_priority"
      }

      assert {:ok, event} = StreamProtocol.first_complete_event(Jason.encode!(payload))
      assert event.upstream_error_param == nil

      assert {:ok, failure} = StreamProtocol.terminal_failure(Jason.encode!(payload))
      assert failure.upstream_error_param == nil

      summary_text = inspect({event, failure})
      refute summary_text =~ raw_value
      refute summary_text =~ raw_message
      refute summary_text =~ "valid.lower_priority"
      refute summary_text =~ "also_lower_priority"
    end

    test "canonicalizes typeless detail-only websocket frames as terminal failures" do
      frame = Jason.encode!(%{"detail" => "synthetic upstream detail must stay out of metadata"})

      assert {:ok, event} = StreamProtocol.first_complete_event(frame)
      assert event.event_type == "response.failed"
      assert event.error_code == "upstream_terminal_failure"
      assert event.upstream_error_code == "upstream_terminal_failure"

      assert {:ok, failure} = StreamProtocol.terminal_failure(frame)
      assert failure.code == "upstream_terminal_failure"
      assert failure.event_type == "response.failed"

      assert %{"type" => "response.failed", "error" => error, "response" => response} =
               frame
               |> StreamProtocol.canonicalize_codex_responses_json_message()
               |> Jason.decode!()

      assert error["code"] == "upstream_terminal_failure"
      assert error["message"] == "upstream websocket returned terminal detail"
      assert response["status"] == "failed"
      assert response["error"]["code"] == "upstream_terminal_failure"

      canonical_text = inspect({error, response})
      refute canonical_text =~ "synthetic upstream detail"
    end

    test "masks previous-response nested errors when status is present" do
      frame =
        Jason.encode!(%{
          "type" => "error",
          "status" => 400,
          "error" => %{
            "code" => "previous_response_not_found",
            "message" => "missing previous response",
            "param" => "previous_response_id"
          }
        })

      assert {:ok, failure} = StreamProtocol.terminal_failure(frame)
      assert failure.code == "stream_incomplete"
      assert failure.upstream_code == "previous_response_not_found"

      assert %{"type" => "response.failed", "error" => error, "response" => response} =
               frame
               |> StreamProtocol.canonicalize_codex_responses_json_message()
               |> Jason.decode!()

      assert error["code"] == "stream_incomplete"
      assert error["message"] == "upstream stream incomplete"
      assert response["error"]["code"] == "stream_incomplete"
    end

    test "masks previous-response nested errors when status_code replaces status" do
      frame =
        Jason.encode!(%{
          "type" => "error",
          "status_code" => 400,
          "error" => %{
            "code" => "previous_response_not_found",
            "message" => "missing previous response",
            "param" => "previous_response_id"
          }
        })

      assert {:ok, failure} = StreamProtocol.terminal_failure(frame)
      assert failure.code == "stream_incomplete"
      assert failure.upstream_code == "previous_response_not_found"

      assert %{"type" => "response.failed", "error" => error, "response" => response} =
               frame
               |> StreamProtocol.canonicalize_codex_responses_json_message()
               |> Jason.decode!()

      assert error["code"] == "stream_incomplete"
      assert error["message"] == "upstream stream incomplete"
      assert response["error"]["code"] == "stream_incomplete"
    end

    test "uses nested rate limit code from status_code wrapped errors" do
      frame =
        Jason.encode!(%{
          "type" => "error",
          "status_code" => 429,
          "error" => %{
            "code" => "rate_limit_exceeded",
            "message" => "rate limited"
          }
        })

      assert {:ok, failure} = StreamProtocol.terminal_failure(frame)
      assert failure.code == "rate_limit_exceeded"
      assert failure.upstream_code == "rate_limit_exceeded"

      assert %{"type" => "response.failed", "error" => error, "response" => response} =
               frame
               |> StreamProtocol.canonicalize_codex_responses_json_message()
               |> Jason.decode!()

      assert error["code"] == "rate_limit_exceeded"
      assert response["error"]["code"] == "rate_limit_exceeded"
    end

    test "classifies top-level status_code errors without nested error safely" do
      frame =
        Jason.encode!(%{
          "type" => "error",
          "status_code" => 500,
          "message" => "upstream failed"
        })

      assert {:ok, failure} = StreamProtocol.terminal_failure(frame)
      assert failure.code == "server_error"
      assert failure.upstream_code == "server_error"

      assert %{"type" => "response.failed", "error" => error, "response" => response} =
               frame
               |> StreamProtocol.canonicalize_codex_responses_json_message()
               |> Jason.decode!()

      assert error["code"] == "server_error"
      assert error["message"] == "upstream failed"
      assert response["error"]["code"] == "server_error"
    end

    test "uses nested server_error code when status is absent" do
      frame =
        Jason.encode!(%{
          "type" => "error",
          "error" => %{
            "code" => "server_error",
            "message" => "failed"
          }
        })

      assert {:ok, failure} = StreamProtocol.terminal_failure(frame)
      assert failure.code == "server_error"
      assert failure.upstream_code == "server_error"

      assert %{"type" => "response.failed", "error" => error, "response" => response} =
               frame
               |> StreamProtocol.canonicalize_codex_responses_json_message()
               |> Jason.decode!()

      assert error["code"] == "server_error"
      assert response["error"]["code"] == "server_error"
    end
  end

  describe "local usage-limit terminal stream regressions" do
    test "keeps first-and-only usage-limit response.failed non-retryable before controller layers" do
      frame = canonical_usage_limit_terminal_sse()

      assert {:ok, event} = StreamProtocol.first_complete_event(frame)
      assert event.event_type == "response.failed"
      assert event.data_type == "response.failed"
      assert event.error_code == "usage_limit_exceeded"
      assert event.upstream_error_code == "usage_limit_exceeded"
      assert StreamProtocol.retryable_first_terminal_failure(event) == :error

      assert {:ok, failure} = StreamProtocol.terminal_failure(frame)
      assert failure.code == "usage_limit_exceeded"
      assert failure.upstream_code == "usage_limit_exceeded"
      assert failure.event_type == "response.failed"
    end
  end

  describe "assignment model unavailable first terminal failures" do
    test "accepts model_not_found without provenance and gates invalid_request_error by provenance" do
      model_not_found = terminal_event(%{"code" => "model_not_found", "param" => "model"})
      code_less = terminal_event(%{"type" => "invalid_request_error", "param" => "model"})

      assert {:ok, model_not_found_event} = StreamProtocol.first_complete_event(model_not_found)

      assert {:ok, model_not_found_failure} =
               StreamProtocol.retryable_first_terminal_failure(model_not_found_event, false)

      assert model_not_found_failure.upstream_code == "model_not_found"

      assert {:ok, code_less_event} = StreamProtocol.first_complete_event(code_less)
      assert StreamProtocol.retryable_first_terminal_failure(code_less_event) == :error
      assert StreamProtocol.retryable_first_terminal_failure(code_less_event, false) == :error

      assert {:ok, code_less_failure} =
               StreamProtocol.retryable_first_terminal_failure(code_less_event, true)

      assert code_less_failure.upstream_code == "invalid_request_error"
      assert code_less_failure.upstream_error_param == "model"
    end

    test "keeps continuation and message-only model claims non-retryable" do
      fixtures = [
        terminal_event(%{
          "code" => "previous_response_not_found",
          "param" => "previous_response_id"
        }),
        terminal_event(%{"message" => "model not found", "param" => "model"})
      ]

      for frame <- fixtures do
        assert {:ok, event} = StreamProtocol.first_complete_event(frame)
        assert StreamProtocol.retryable_first_terminal_failure(event, true) == :error
      end
    end
  end

  describe "websocket_error_frame_headers/1" do
    test "extracts allowlisted scalar headers from status wrapped errors" do
      frame =
        wrapped_error_frame(%{
          "status" => 429,
          "headers" => %{
            "X-Request-ID" => "req-first",
            "x-request-id" => "req-last",
            "OpenAI-Request-ID" => "openai-req",
            "X-OpenAI-Request-ID" => "x-openai-req",
            "X-Codex-Rate-Limit-Reached-Type" => "primary",
            "X-RateLimit-Limit-Requests" => 1200,
            "X-RateLimit-Remaining-Requests" => 0,
            "X-RateLimit-Reset-Requests" => 1_717_171_717,
            "X-Codex-Primary-Used-Percent" => 88.5,
            "X-Codex-Primary-Window-Minutes" => 300,
            "X-Codex-Primary-Reset-At" => "2026-05-25T12:00:00Z",
            "X-Codex-Secondary-Used-Percent" => true,
            "X-Codex-Secondary-Window-Minutes" => false,
            "X-Codex-Secondary-Reset-At" => "2026-05-25T12:30:00Z"
          }
        })

      assert websocket_error_frame_headers(frame) == %{
               "openai-request-id" => "openai-req",
               "x-codex-primary-reset-at" => "2026-05-25T12:00:00Z",
               "x-codex-primary-used-percent" => "88.5",
               "x-codex-primary-window-minutes" => "300",
               "x-codex-rate-limit-reached-type" => "primary",
               "x-codex-secondary-reset-at" => "2026-05-25T12:30:00Z",
               "x-codex-secondary-used-percent" => "true",
               "x-codex-secondary-window-minutes" => "false",
               "x-openai-request-id" => "x-openai-req",
               "x-ratelimit-limit-requests" => "1200",
               "x-ratelimit-remaining-requests" => "0",
               "x-ratelimit-reset-requests" => "1717171717",
               "x-request-id" => "req-last"
             }
    end

    test "drops sensitive, arbitrary, arrays, objects, and null values from status_code wrapped errors" do
      frame =
        wrapped_error_frame(%{
          "status_code" => 429,
          "headers" => %{
            "Authorization" => "synthetic-auth-redacted",
            "Cookie" => "synthetic-session-cookie",
            "Set-Cookie" => "synthetic-session-cookie=drop",
            "Proxy-Authorization" => "synthetic-proxy-auth-redacted",
            "Should-Not-Persist" => "synthetic-sentinel",
            "OpenAI-Organization" => "not-explicitly-allowed",
            "X-Request-ID" => ["array-value"],
            "X-OpenAI-Request-ID" => %{"nested" => "object-value"},
            "OpenAI-Request-ID" => nil,
            "X-Codex-Primary-Reset-At" => "2026-05-25T13:00:00Z"
          }
        })

      assert websocket_error_frame_headers(frame) == %{
               "x-codex-primary-reset-at" => "2026-05-25T13:00:00Z"
             }
    end
  end

  defp canonical_usage_limit_terminal_sse do
    sse_event("response.failed", %{
      "type" => "response.failed",
      "response" => %{
        "id" => "resp_usage_limit_terminal",
        "status" => "failed",
        "error" => %{"code" => "usage_limit_exceeded"},
        "usage" => %{
          "input_tokens" => 10,
          "cached_input_tokens" => 4,
          "output_tokens" => 2,
          "reasoning_tokens" => 1,
          "total_tokens" => 12
        }
      }
    })
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

  defp event_item(events, event_type) do
    events
    |> Enum.find_value(fn
      %{"event" => ^event_type, "data" => %{"item" => item}} -> item
      _event -> nil
    end)
  end

  defp strip_sse_prefix(nil, _prefix), do: nil
  defp strip_sse_prefix(line, prefix), do: String.replace_prefix(line, prefix, "")

  defp sse_event(event, payload) do
    "event: " <> event <> "\n" <> "data: " <> Jason.encode!(payload) <> "\n\n"
  end

  defp terminal_event(error) do
    sse_event("response.failed", %{
      "type" => "response.failed",
      "response" => %{"status" => "failed", "error" => error}
    })
  end

  defp websocket_error_frame_headers(frame) do
    StreamProtocol.websocket_error_frame_headers(frame)
  end

  defp wrapped_error_frame(attrs) do
    attrs
    |> Map.merge(%{
      "type" => "error",
      "error" => %{
        "code" => "rate_limit_exceeded",
        "message" => "rate limited"
      }
    })
    |> Jason.encode!()
  end
end
