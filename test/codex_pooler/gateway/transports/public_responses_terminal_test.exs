defmodule CodexPooler.Gateway.Transports.PublicResponsesTerminalTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponsesSequence

  @non_map_terminal_errors [
    {"string", "raw_non_map_error_string"},
    {"list", ["raw_non_map_error_list"]},
    {"number", 987_654_321},
    {"boolean", true},
    {"null", nil}
  ]

  @tag :task_1_pin
  test "PIN-P01 response.completed remains a completed terminal" do
    frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_pin_completed", "status" => "completed"}
      })

    assert {:ok,
            %{
              kind: :completed,
              event_type: "response.completed",
              data_type: "response.completed"
            }} = StreamProtocol.terminal_outcome(frame)
  end

  test "classifies structural completed, done, legacy, incomplete, and failed terminals" do
    cases = [
      {completed("resp_completed"), :completed, "response.completed"},
      {done("resp_done"), :completed, "response.done"},
      {%{"id" => "resp_legacy"}, :completed, nil},
      {incomplete("resp_incomplete", nil), :incomplete, "response.incomplete"},
      {incomplete("resp_failed_incomplete", "server_error"), :failed, "response.incomplete"},
      {failed_without_nested_code("resp_failed"), :failed, "response.failed"},
      {%{"detail" => "synthetic terminal detail"}, :failed, "response.failed"}
    ]

    for {decoded, kind, data_type} <- cases do
      assert {:ok, %{kind: ^kind, data_type: ^data_type}} =
               decoded |> Jason.encode!() |> StreamProtocol.terminal_outcome()
    end
  end

  test "rejects malformed or conflicting success shapes" do
    malformed = [
      %{"id" => 42},
      %{"custom" => true},
      %{"type" => "response.done"},
      %{"type" => "response.done", "response" => "not-an-object"},
      %{
        "type" => "response.done",
        "response" => %{"id" => "resp_conflict", "status" => "failed"}
      },
      %{
        "type" => "response.done",
        "response" => %{"id" => "resp_null_status", "status" => nil}
      },
      %{
        "type" => "response.completed",
        "response" => %{"id" => "resp_incomplete", "status" => "incomplete"}
      }
    ]

    for decoded <- malformed do
      assert :error = decoded |> Jason.encode!() |> StreamProtocol.terminal_outcome()
    end

    assert :error = StreamProtocol.terminal_outcome(~s({"type":"response.done"))

    assert nil ==
             StreamProtocol.terminal_outcome("response.completed", %{
               "type" => "response.done",
               "response" => %{"id" => "resp_mismatch"}
             })

    assert nil ==
             StreamProtocol.terminal_outcome("response.done", %{
               "type" => "response.completed",
               "response" => %{"id" => "resp_reverse_mismatch"}
             })
  end

  test "public POST rewrites done and exact legacy success only at the public boundary" do
    done_stream = sse_event("response.done", done("resp_public_done"))
    legacy_stream = sse_data(%{"id" => "resp_public_legacy", "custom" => %{"kept" => true}})

    {done_output, done_state} = normalize_sse(done_stream)
    {legacy_output, legacy_state} = normalize_sse(legacy_stream)

    done_events = public_events(done_output)
    legacy_events = public_events(legacy_output)

    assert Enum.count(done_events, &(&1.event == "response.completed")) == 1
    assert Enum.count(legacy_events, &(&1.event == "response.completed")) == 1

    assert %{data: done_data} = Enum.find(done_events, &(&1.event == "response.completed"))
    assert done_data["type"] == "response.completed"
    assert done_data["response"]["status"] == "completed"
    assert is_integer(done_data["sequence_number"])

    assert %{data: legacy_data} =
             Enum.find(legacy_events, &(&1.event == "response.completed"))

    assert Map.keys(legacy_data) |> Enum.sort() ==
             ["response", "sequence_number", "type"]

    assert legacy_data["response"] == %{
             "id" => "resp_public_legacy",
             "custom" => %{"kept" => true},
             "status" => "completed"
           }

    assert done_state.sequence.terminal_latched?
    assert legacy_state.sequence.terminal_latched?
  end

  test "public adapters drop malformed success shapes without latching a false terminal" do
    malformed = %{
      "type" => "response.completed",
      "response" => %{"id" => "resp_public_malformed", "status" => "failed"}
    }

    {sse_output, sse_state} = normalize_sse(sse_event("response.completed", malformed))
    assert sse_output == ""
    refute sse_state.sequence.terminal_latched?

    websocket_state = StreamProtocol.public_openai_responses_websocket_state()

    assert {:drop, ^websocket_state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(
               Jason.encode!(malformed),
               websocket_state
             )
  end

  test "blank public SSE labels use the data type while nonblank mismatches remain rejected" do
    failed =
      failed_without_nested_code("resp_blank_label")
      |> Map.put("prompt", "private-prompt-sentinel")
      |> put_in(["response", "hostile_sibling"], "private-response-sentinel")

    for event_line <- ["", "event:\n", "event: \t \n"] do
      {output, state} = normalize_sse(event_line <> "data: " <> Jason.encode!(failed) <> "\n\n")

      assert [%{event: "response.failed", data: decoded}] = public_events(output)
      assert decoded["response"]["status"] == "failed"
      assert decoded["response"]["error"]["message"] == "upstream request failed"
      refute output =~ "private-prompt-sentinel"
      refute output =~ "private-response-sentinel"
      assert state.sequence.terminal_latched?
      assert state.terminal_kind == :failed

      late = sse_event("response.completed", completed("resp_late_after_blank"))

      assert {"", late_state} =
               StreamProtocol.normalize_public_openai_responses_sse_data(
                 IO.iodata_to_binary(late),
                 state
               )

      assert late_state.sequence == state.sequence
      assert late_state.terminal_kind == state.terminal_kind
    end

    mismatch = "event: response.completed\ndata: " <> Jason.encode!(failed) <> "\n\n"
    {output, state} = normalize_sse(mismatch)
    assert output == ""
    refute state.sequence.terminal_latched?
  end

  for {value_class, malformed_error} <- @non_map_terminal_errors do
    @malformed_error malformed_error

    test "public SSE and websocket sanitize #{value_class} terminal errors at both locations" do
      fallback = %{
        "message" => "upstream request failed",
        "type" => "server_error",
        "code" => "upstream_error"
      }

      observations =
        for location <- [:top_level, :nested],
            transport <- [:sse, :websocket] do
          {_wire, decoded} =
            normalize_public_wire(transport, malformed_terminal(location, @malformed_error))

          {
            location,
            transport,
            terminal_errors(decoded),
            decoded["response"]
          }
        end

      assert observations == [
               {:top_level, :sse, %{top_level: fallback, nested: fallback},
                expected_failed_response(id: "resp_non_map_top_level")},
               {:top_level, :websocket, %{top_level: fallback, nested: fallback},
                expected_failed_response(id: "resp_non_map_top_level")},
               {:nested, :sse, %{top_level: :absent, nested: fallback},
                expected_failed_response(id: "resp_non_map_nested")},
               {:nested, :websocket, %{top_level: :absent, nested: fallback},
                expected_failed_response(id: "resp_non_map_nested")}
             ]
    end
  end

  test "public POST overflow telemetry records the applicable incomplete buffer limit" do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    test_pid = self()
    event = [:codex_pooler, :gateway, :stream_buffer, :oversized]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn ^event,
           %{bytes: bytes, count: count, max_bytes: max_bytes},
           %{buffer: buffer},
           ^test_pid ->
          if self() == test_pid do
            send(test_pid, {
              handler_id,
              %{buffer: buffer, bytes: bytes, count: count, max_bytes: max_bytes}
            })
          end
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    observed_bytes = StreamProtocol.max_incomplete_terminal_sse_block_bytes() + 1

    emit_oversized_incomplete_sse(
      ~s(event: response.completed\ndata: {"type":"response.completed","response":{),
      observed_bytes
    )

    assert_receive {^handler_id,
                    %{
                      buffer: "public_openai_responses_sse",
                      bytes: ^observed_bytes,
                      count: 1,
                      max_bytes: 67_108_864
                    }}

    emit_oversized_incomplete_sse(~s(data: {"ordinary":"), observed_bytes)

    assert_receive {^handler_id,
                    %{
                      buffer: "public_openai_responses_sse",
                      bytes: ^observed_bytes,
                      count: 1,
                      max_bytes: 65_536
                    }}
  end

  test "public POST fails an ordinary incomplete block at byte 65,537 and drops the source tail" do
    limit = StreamProtocol.max_incomplete_sse_block_bytes()
    stream = oversized_incomplete_sse(:late)
    first = binary_part(stream, 0, limit + 1)
    rest = binary_part(stream, limit + 1, byte_size(stream) - limit - 1)
    state = StreamProtocol.public_openai_responses_stream_state()

    assert {"", exact_state} =
             StreamProtocol.normalize_public_openai_responses_sse_data(
               binary_part(stream, 0, limit),
               state
             )

    assert byte_size(exact_state.buffer) == limit
    refute exact_state.sequence.terminal_latched?

    assert {output, state} =
             StreamProtocol.normalize_public_openai_responses_sse_data(first, state)

    assert [%{event: "error", data: decoded}] = public_events(output)
    assert decoded["error"]["code"] == "server_error"
    assert decoded["sequence_number"] == 0
    assert byte_size(output) < 1_024
    refute output =~ "private-oversized-sentinel"
    assert state.buffer == ""
    refute state.passthrough?
    assert state.sequence.terminal_latched?
    assert state.terminal_kind == :failed
    assert state.summary.synthetic_terminal_sent

    late =
      IO.iodata_to_binary([rest, "\n\n", sse_event("response.completed", completed("late"))])

    assert {"", late_state} =
             StreamProtocol.normalize_public_openai_responses_sse_data(late, state)

    assert late_state.sequence == state.sequence
    assert late_state.terminal_kind == state.terminal_kind
  end

  test "public POST parses complete blocks before failing an oversized incomplete block" do
    complete = response_event("response.created", nil)
    oversized = oversized_incomplete_sse(:late)
    oversized = binary_part(oversized, 0, StreamProtocol.max_incomplete_sse_block_bytes() + 1)
    state = StreamProtocol.public_openai_responses_stream_state()

    assert {output, state} =
             StreamProtocol.normalize_public_openai_responses_sse_data(
               IO.iodata_to_binary([complete, oversized]),
               state
             )

    assert Enum.map(public_events(output), & &1.event) == ["response.created", "error"]
    assert state.sequence.max_seen == 1
    assert state.sequence.terminal_latched?
  end

  test "complete oversized public POST blocks remain normally classified" do
    padding = String.duplicate("x", StreamProtocol.max_incomplete_sse_block_bytes() + 1)

    completed =
      completed("resp_complete_oversized")
      |> put_in(["response", "metadata"], %{"padding" => padding})

    {output, state} = normalize_sse(sse_event("response.completed", completed))

    events = public_events(output)
    assert Enum.map(events, & &1.event) == ["response.created", "response.completed"]
    decoded = List.last(events).data
    assert decoded["response"]["status"] == "completed"
    assert state.terminal_kind == :completed
  end

  test "ordinary oversized incomplete public POST blocks fail without passthrough" do
    state = StreamProtocol.public_openai_responses_stream_state()

    source =
      "data: " <>
        String.duplicate("private-ordinary-oversized-sentinel", 2_100)

    assert byte_size(source) > StreamProtocol.max_incomplete_sse_block_bytes()

    assert {output, state} =
             StreamProtocol.normalize_public_openai_responses_sse_data(source, state)

    assert [%{event: "error", data: decoded}] = public_events(output)
    assert decoded["sequence_number"] == 0
    refute output =~ "private-ordinary-oversized-sentinel"
    assert state.buffer == ""
    assert state.sequence.terminal_latched?
  end

  @tag :task_1_fix_red
  test "every present non-empty event and data type mismatch is rejected" do
    nonterminal = "response.output_text.delta"

    mismatch_cases = [
      {"response.completed", done("resp_mismatch_completed_done")},
      {"response.done", completed("resp_mismatch_done_completed")},
      {"response.failed", terminal_shape(nonterminal, :failed)},
      {nonterminal, terminal_shape("response.failed", :failed)},
      {"response.incomplete", terminal_shape(nonterminal, :incomplete)},
      {nonterminal, terminal_shape("response.incomplete", :incomplete)},
      {"error", terminal_shape(nonterminal, :error)},
      {nonterminal, terminal_shape("error", :error)}
    ]

    for {event_type, decoded} <- mismatch_cases do
      assert StreamProtocol.terminal_outcome(event_type, decoded) == nil

      {output, state} = normalize_sse(sse_event(event_type, decoded))
      assert byte_size(output) == 0
      refute state.sequence.terminal_latched?
      assert state.terminal_kind == nil
    end
  end

  test "public POST assigns strictly increasing safe sequences and replaces invalid values" do
    max_safe = PublicResponsesSequence.max_safe_integer()

    events = [
      response_event("response.created", 2),
      response_event("response.in_progress", 2),
      response_event("response.output_text.delta", nil, %{"delta" => "a"}),
      response_event("response.output_text.done", -1, %{"text" => "a"}),
      response_event("response.output_item.added", "5"),
      response_event("response.output_item.done", 7.5),
      response_event("keepalive", max_safe + 1)
    ]

    {output, state} = normalize_sse(IO.iodata_to_binary(events))
    sequences = output |> public_events() |> Enum.map(& &1.data["sequence_number"])

    assert sequences == [2, 3, 4, 5, 6, 7, 8]
    assert state.sequence.max_seen == 8
    refute state.sequence.terminal_latched?
  end

  test "public POST emits one overflow failure at max safe and latches subsequent frames" do
    max_safe = PublicResponsesSequence.max_safe_integer()
    state = StreamProtocol.public_openai_responses_stream_state()
    state = put_in(state.sequence.max_seen, max_safe - 1)

    stream =
      IO.iodata_to_binary([
        response_event("response.output_text.delta", nil, %{"delta" => "not-relayed"}),
        sse_event("response.completed", completed("resp_after_overflow")),
        sse_event("response.failed", failed_without_nested_code("resp_duplicate"))
      ])

    {output, state} = StreamProtocol.normalize_public_openai_responses_sse_data(stream, state)
    events = public_events(output)

    assert [%{event: "response.failed", data: failed}] = events
    assert failed["sequence_number"] == max_safe
    assert failed["error"]["code"] == "response_sequence_exhausted"
    assert state.sequence.overflow_latched?
    assert state.sequence.terminal_latched?
  end

  test "public POST relays only the first valid terminal" do
    stream =
      IO.iodata_to_binary([
        sse_event("response.incomplete", incomplete("resp_first", nil)),
        sse_event("response.completed", completed("resp_second")),
        sse_event("response.failed", failed_without_nested_code("resp_third"))
      ])

    {output, state} = normalize_sse(stream)
    terminals = Enum.filter(public_events(output), &terminal_event?/1)

    assert [%{event: "response.incomplete"}] = terminals
    assert state.sequence.terminal_latched?
    assert state.terminal_kind == :incomplete
  end

  @tag :task_1_fix_red
  test "public POST and GET latch completed then done and duplicate failed only once" do
    cases = [
      {completed("resp_completed_first"), done("resp_done_second"), "response.completed"},
      {failed_without_nested_code("resp_failed_first"),
       failed_without_nested_code("resp_failed_second"), "response.failed"}
    ]

    for {first, second, expected_type} <- cases do
      stream =
        IO.iodata_to_binary([
          sse_event(first["type"], first),
          sse_event(second["type"], second)
        ])

      {post_output, post_state} = normalize_sse(stream)
      post_terminals = Enum.filter(public_events(post_output), &terminal_event?/1)

      assert Enum.map(post_terminals, & &1.event) == [expected_type]
      assert post_state.sequence.terminal_latched?

      websocket_state = StreamProtocol.public_openai_responses_websocket_state()

      assert {:push, first_payload, websocket_state} =
               StreamProtocol.normalize_public_openai_responses_websocket_data(
                 Jason.encode!(first),
                 websocket_state
               )

      assert Jason.decode!(first_payload)["type"] == expected_type

      assert {:drop, ^websocket_state} =
               StreamProtocol.normalize_public_openai_responses_websocket_data(
                 Jason.encode!(second),
                 websocket_state
               )

      assert websocket_state.terminal_latched?
    end
  end

  test "fresh public POST streams each restart sequence numbering at zero" do
    stream =
      IO.iodata_to_binary([
        response_event("response.created", nil),
        sse_event("response.completed", completed("resp_fresh"))
      ])

    for _turn <- 1..2 do
      {output, state} = normalize_sse(stream)
      assert output |> public_events() |> Enum.map(& &1.data["sequence_number"]) == [0, 1]
      assert state.sequence.max_seen == 1
    end
  end

  test "public websocket tracker normalizes success, isolates sequence state, and latches" do
    state = StreamProtocol.public_openai_responses_websocket_state()

    assert {:push, done_payload, state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(
               Jason.encode!(done("resp_ws_done")),
               state
             )

    assert Jason.decode!(done_payload) == %{
             "type" => "response.completed",
             "sequence_number" => 0,
             "response" => %{
               "id" => "resp_ws_done",
               "status" => "completed"
             }
           }

    assert {:drop, ^state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(
               Jason.encode!(completed("resp_ws_late")),
               state
             )

    fresh = StreamProtocol.public_openai_responses_websocket_state()
    legacy = %{"id" => "resp_ws_legacy", "custom" => true}

    assert {:push, legacy_payload, _fresh_state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(
               Jason.encode!(legacy),
               fresh
             )

    assert Jason.decode!(legacy_payload) == %{
             "type" => "response.completed",
             "sequence_number" => 0,
             "response" => Map.put(legacy, "status", "completed")
           }
  end

  test "public websocket drops invalid JSON and JSON non-objects without advancing state" do
    invalid_frames = [
      "{",
      Jason.encode!("string"),
      Jason.encode!([]),
      Jason.encode!(42),
      Jason.encode!(nil)
    ]

    for frame <- invalid_frames do
      state = StreamProtocol.public_openai_responses_websocket_state()

      assert {:drop, ^state} =
               StreamProtocol.normalize_public_openai_responses_websocket_data(frame, state)

      assert {:push, payload, next_state} =
               StreamProtocol.normalize_public_openai_responses_websocket_data(
                 Jason.encode!(response_event_map("response.created")),
                 state
               )

      assert Jason.decode!(payload)["sequence_number"] == 0
      assert next_state.max_seen == 0
      refute next_state.terminal_latched?
    end
  end

  test "public websocket canonicalizes direct incomplete errors before sequence agreement" do
    raw =
      ~s({"type":"response.incomplete","error":{"type":"provider_type_must_not_win"},"response":{"id":"resp_direct_canonicalization","status":"incomplete","incomplete_details":{"reason":"context_length_exceeded"}}})

    state = StreamProtocol.public_openai_responses_websocket_state()

    assert {:push, wire, state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(raw, state)

    decoded = Jason.decode!(wire)

    assert decoded["type"] == "response.failed"
    assert decoded["response"]["status"] == "failed"
    assert decoded["error"]["code"] == "context_length_exceeded"
    assert decoded["response"]["error"]["code"] == "context_length_exceeded"
    assert decoded["sequence_number"] == 0
    refute wire =~ "provider_type_must_not_win"
    assert state.terminal_latched?
    assert state.max_seen == 0
  end

  test "public failed-envelope repair projects exact safe fields and is idempotent" do
    terminal = %{
      "type" => "response.failed",
      "headers" => %{
        "authorization" => "Bearer provider-secret-sentinel",
        "x-provider-debug" => "provider-header-sentinel"
      },
      "sequence_number" => 7,
      "code" => "flat_code_sentinel",
      "message" => "flat message sentinel",
      "param" => "flat.param.sentinel",
      "debug" => %{"trace" => "debug-sentinel"},
      "prompt" => "prompt-sentinel",
      "ordinary_sibling" => %{"credential" => "ordinary-sibling-sentinel"},
      "error" => %{
        "code" => "top_safe_code",
        "type" => "top_provider_type",
        "message" => "top provider message",
        "custom" => "top-error-sentinel"
      },
      "response" => %{
        "id" => "resp_safe_123",
        "created_at" => 123,
        "status" => "inconsistent",
        "error" => %{
          "code" => "nested_safe_code",
          "type" => "nested_provider_type",
          "message" => "nested provider message",
          "custom" => "nested-error-sentinel"
        },
        "incomplete_details" => %{
          "reason" => "content_filter",
          "provider_detail" => "incomplete-detail-sentinel"
        },
        "model" => "provider-model-sentinel",
        "object" => "provider-object-sentinel",
        "output" => [%{"type" => "message", "content" => "output-sentinel"}],
        "output_text" => "output-text-sentinel",
        "instructions" => "instructions-sentinel",
        "metadata" => %{"credential" => "metadata-sentinel"},
        "parallel_tool_calls" => true,
        "tool_choice" => %{"type" => "provider-tool-choice"},
        "tools" => [%{"name" => "tool-sentinel"}],
        "usage" => %{
          "input_tokens" => 11,
          "input_tokens_details" => %{
            "cache_write_tokens" => 2,
            "cached_tokens" => 3,
            "provider_cache_field" => 4
          },
          "output_tokens" => 5,
          "output_tokens_details" => %{
            "reasoning_tokens" => 4,
            "provider_reasoning_field" => 6
          },
          "total_tokens" => 16,
          "provider_usage_field" => "usage-sentinel"
        },
        "temperature" => 0.7,
        "top_p" => 0.9,
        "prompt" => "response-prompt-sentinel",
        "user" => "response-user-sentinel",
        "safety_identifier" => "response-safety-sentinel",
        "service_tier" => "response-tier-sentinel",
        "ordinary_response_sibling" => %{"credential" => "response-sibling-sentinel"}
      }
    }

    expected = %{
      "type" => "response.failed",
      "sequence_number" => 7,
      "error" => %{
        "code" => "top_safe_code",
        "type" => "server_error",
        "message" => "upstream request failed"
      },
      "response" =>
        expected_failed_response(
          id: "resp_safe_123",
          code: "nested_safe_code",
          incomplete_details: %{"reason" => "content_filter"},
          usage: %{
            "input_tokens" => 11,
            "input_tokens_details" => %{
              "cache_write_tokens" => 2,
              "cached_tokens" => 3
            },
            "output_tokens" => 5,
            "output_tokens_details" => %{"reasoning_tokens" => 4},
            "total_tokens" => 16
          }
        )
    }

    for transport <- [:sse, :websocket] do
      {wire, decoded} = normalize_public_wire(transport, terminal)
      assert decoded == expected

      for sentinel <- [
            "provider-secret-sentinel",
            "provider-header-sentinel",
            "flat_code_sentinel",
            "flat message sentinel",
            "flat.param.sentinel",
            "debug-sentinel",
            "prompt-sentinel",
            "ordinary-sibling-sentinel",
            "top provider message",
            "top-error-sentinel",
            "nested provider message",
            "nested-error-sentinel",
            "incomplete-detail-sentinel",
            "provider-model-sentinel",
            "provider-object-sentinel",
            "output-sentinel",
            "output-text-sentinel",
            "instructions-sentinel",
            "metadata-sentinel",
            "provider-tool-choice",
            "tool-sentinel",
            "usage-sentinel",
            "response-prompt-sentinel",
            "response-user-sentinel",
            "response-safety-sentinel",
            "response-tier-sentinel",
            "response-sibling-sentinel"
          ] do
        refute wire =~ sentinel
      end

      {_wire, twice} = normalize_public_wire(transport, decoded)
      assert twice == expected
    end
  end

  test "public failed-envelope repair sanitizes top-level and nested errors independently" do
    terminal = %{
      "type" => "response.failed",
      "error" => %{
        "code" => "top_safe_code",
        "type" => "top_provider_type",
        "message" => "top provider message"
      },
      "response" => %{
        "id" => "resp_distinct_codes",
        "status" => "inconsistent",
        "ordinary_response_sibling" => %{"kept" => true},
        "error" => %{
          "code" => "nested_safe_code",
          "type" => "nested_provider_type",
          "message" => "nested provider message"
        }
      }
    }

    for transport <- [:sse, :websocket] do
      {wire, decoded} = normalize_public_wire(transport, terminal)

      assert decoded["error"] == %{
               "code" => "top_safe_code",
               "type" => "server_error",
               "message" => "upstream request failed"
             }

      assert decoded["response"]["error"] == %{
               "code" => "nested_safe_code",
               "type" => "server_error",
               "message" => "upstream request failed"
             }

      assert decoded["response"] ==
               expected_failed_response(id: "resp_distinct_codes", code: "nested_safe_code")

      refute wire =~ "top_provider_type"
      refute wire =~ "nested_provider_type"
      refute wire =~ "top provider message"
      refute wire =~ "nested provider message"
    end
  end

  test "public failed-envelope repair synthesizes the complete response for absent and non-map sources" do
    for response <- [:absent, nil, "scalar", ["list"]] do
      terminal =
        %{"type" => "response.failed"}
        |> then(fn terminal ->
          if response == :absent, do: terminal, else: Map.put(terminal, "response", response)
        end)

      for transport <- [:sse, :websocket] do
        {_wire, decoded} = normalize_public_wire(transport, terminal)

        assert decoded == %{
                 "type" => "response.failed",
                 "sequence_number" => 0,
                 "response" => expected_failed_response()
               }
      end
    end
  end

  test "public failed-envelope repair validates ids, incomplete reasons, and usage leaves" do
    max_safe_integer = 9_007_199_254_740_991

    cases = [
      {%{}, expected_failed_response()},
      {%{"id" => "resp_valid-id_9"}, expected_failed_response(id: "resp_valid-id_9")},
      {%{"id" => "invalid"}, expected_failed_response()},
      {%{"id" => "resp_" <> String.duplicate("a", 251)}, expected_failed_response()},
      {%{"incomplete_details" => %{"reason" => "max_output_tokens", "extra" => true}},
       expected_failed_response(incomplete_details: %{"reason" => "max_output_tokens"})},
      {%{"incomplete_details" => %{"reason" => "content_filter"}},
       expected_failed_response(incomplete_details: %{"reason" => "content_filter"})},
      {%{"incomplete_details" => %{"reason" => "other"}}, expected_failed_response()},
      {%{"usage" => "invalid"}, expected_failed_response()},
      {%{
         "usage" => %{
           "input_tokens" => 8,
           "input_tokens_details" => %{"cached_tokens" => 2},
           "output_tokens" => 5
         }
       },
       expected_failed_response(
         usage: %{
           "input_tokens" => 8,
           "input_tokens_details" => %{"cache_write_tokens" => 0, "cached_tokens" => 2},
           "output_tokens" => 5,
           "output_tokens_details" => %{"reasoning_tokens" => 0},
           "total_tokens" => 13
         }
       )},
      {%{
         "usage" => %{
           "input_tokens" => -1,
           "input_tokens_details" => %{
             "cache_write_tokens" => 1.5,
             "cached_tokens" => max_safe_integer + 1
           },
           "output_tokens" => 7,
           "output_tokens_details" => %{"reasoning_tokens" => "invalid"},
           "total_tokens" => -1,
           "unknown" => "usage-unknown-sentinel"
         }
       },
       expected_failed_response(
         usage: %{
           "input_tokens" => 0,
           "input_tokens_details" => %{"cache_write_tokens" => 0, "cached_tokens" => 0},
           "output_tokens" => 7,
           "output_tokens_details" => %{"reasoning_tokens" => 0},
           "total_tokens" => 7
         }
       )},
      {%{
         "usage" => %{
           "input_tokens" => max_safe_integer,
           "output_tokens" => max_safe_integer,
           "total_tokens" => nil
         }
       },
       expected_failed_response(
         usage: %{
           "input_tokens" => max_safe_integer,
           "input_tokens_details" => %{"cache_write_tokens" => 0, "cached_tokens" => 0},
           "output_tokens" => max_safe_integer,
           "output_tokens_details" => %{"reasoning_tokens" => 0},
           "total_tokens" => max_safe_integer
         }
       )}
    ]

    for {response, expected} <- cases,
        transport <- [:sse, :websocket] do
      {wire, decoded} =
        normalize_public_wire(transport, %{
          "type" => "response.failed",
          "response" => response
        })

      assert decoded["response"] == expected
      refute wire =~ "usage-unknown-sentinel"
    end
  end

  test "public failed-envelope repair preserves valid sequence, latches terminal, and drops later frames" do
    terminal = %{
      "type" => "response.failed",
      "sequence_number" => 23,
      "response" => %{"id" => "resp_sequence_preserved", "status" => "failed"}
    }

    state = StreamProtocol.public_openai_responses_websocket_state()

    assert {:push, wire, state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(
               Jason.encode!(terminal),
               state
             )

    assert Jason.decode!(wire)["sequence_number"] == 23
    assert state.max_seen == 23
    assert state.terminal_latched?

    assert {:drop, ^state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(
               Jason.encode!(completed("resp_after_failed")),
               state
             )
  end

  test "public websocket redacts nested map errors after canonicalizing failure-coded incomplete" do
    nested_message = "NESTED_PROVIDER_MESSAGE_SENTINEL"
    nested_type = "NESTED_PROVIDER_TYPE_SENTINEL"
    nested_param = "NESTED_PROVIDER_PARAM_SENTINEL"
    nested_extra = "NESTED_PROVIDER_EXTRA_SENTINEL"

    raw =
      Jason.encode!(%{
        "type" => "response.incomplete",
        "response" => %{
          "id" => "resp_nested_map_error",
          "status" => "incomplete",
          "incomplete_details" => %{"reason" => "context_length_exceeded"},
          "error" => %{
            "code" => "context_length_exceeded",
            "message" => nested_message,
            "type" => nested_type,
            "param" => nested_param,
            "provider_extra" => nested_extra
          }
        }
      })

    state = StreamProtocol.public_openai_responses_websocket_state()

    assert {:push, wire, state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(raw, state)

    decoded = Jason.decode!(wire)

    assert decoded["type"] == "response.failed"
    assert decoded["response"]["status"] == "failed"
    assert decoded["sequence_number"] == 0

    assert decoded["error"] == %{
             "message" => "upstream request failed",
             "type" => "server_error",
             "code" => "context_length_exceeded"
           }

    assert decoded["response"]["error"] == decoded["error"]

    for sentinel <- [nested_message, nested_type, nested_param, nested_extra] do
      refute wire =~ sentinel
    end

    assert state.terminal_latched?
    assert state.max_seen == 0

    assert {:drop, ^state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(
               Jason.encode!(completed("resp_after_nested_map_error")),
               state
             )
  end

  test "public websocket redacts unsafe top-level map errors on existing failed terminals" do
    top_message = "TOP_PROVIDER_MESSAGE_SENTINEL"
    top_type = "TOP_PROVIDER_TYPE_SENTINEL"
    top_param = "TOP_PROVIDER_PARAM_SENTINEL"
    top_extra = "TOP_PROVIDER_EXTRA_SENTINEL"

    raw =
      Jason.encode!(%{
        "type" => "response.failed",
        "error" => %{
          "code" => "unsafe/code",
          "message" => top_message,
          "type" => top_type,
          "param" => top_param,
          "provider_extra" => top_extra
        },
        "response" => %{"id" => "resp_top_map_error", "status" => "failed"}
      })

    state = StreamProtocol.public_openai_responses_websocket_state()

    assert {:push, wire, state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(raw, state)

    decoded = Jason.decode!(wire)

    assert decoded["type"] == "response.failed"
    assert decoded["response"]["status"] == "failed"
    assert decoded["sequence_number"] == 0

    assert decoded["error"] == %{
             "message" => "upstream request failed",
             "type" => "server_error",
             "code" => "upstream_error"
           }

    assert decoded["response"] ==
             expected_failed_response(id: "resp_top_map_error")

    for sentinel <- [top_message, top_type, top_param, top_extra] do
      refute wire =~ sentinel
    end

    assert state.terminal_latched?
    assert state.max_seen == 0
  end

  test "public websocket redacts nested map errors without a provider code on existing failed terminals" do
    nested_message = "MISSING_CODE_PROVIDER_MESSAGE_SENTINEL"
    nested_type = "MISSING_CODE_PROVIDER_TYPE_SENTINEL"
    nested_param = "MISSING_CODE_PROVIDER_PARAM_SENTINEL"
    nested_extra = "MISSING_CODE_PROVIDER_EXTRA_SENTINEL"

    raw =
      Jason.encode!(%{
        "type" => "response.failed",
        "response" => %{
          "id" => "resp_nested_missing_code",
          "status" => "failed",
          "error" => %{
            "message" => nested_message,
            "type" => nested_type,
            "param" => nested_param,
            "provider_extra" => nested_extra
          }
        }
      })

    state = StreamProtocol.public_openai_responses_websocket_state()

    assert {:push, wire, state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(raw, state)

    decoded = Jason.decode!(wire)

    assert decoded == %{
             "response" => expected_failed_response(id: "resp_nested_missing_code"),
             "sequence_number" => 0,
             "type" => "response.failed"
           }

    for sentinel <- [nested_message, nested_type, nested_param, nested_extra] do
      refute wire =~ sentinel
    end

    assert state.terminal_latched?
    assert state.max_seen == 0
  end

  test "public websocket tracker emits one overflow error result then drops" do
    max_safe = PublicResponsesSequence.max_safe_integer()

    state =
      StreamProtocol.public_openai_responses_websocket_state()
      |> Map.put(:max_seen, max_safe - 1)

    nonterminal = Jason.encode!(%{"type" => "keepalive"})

    assert {:error, reason, state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(nonterminal, state)

    assert reason == %{
             status: 500,
             code: :websocket_sequence_exhausted,
             message: "websocket response sequence exhausted",
             param: nil
           }

    assert {:drop, ^state} =
             StreamProtocol.normalize_public_openai_responses_websocket_data(
               Jason.encode!(completed("resp_ws_after_overflow")),
               state
             )
  end

  defp normalize_sse(stream) do
    StreamProtocol.normalize_public_openai_responses_sse_data(
      IO.iodata_to_binary(stream),
      StreamProtocol.public_openai_responses_stream_state()
    )
  end

  defp normalize_public_wire(:sse, terminal) do
    {wire, _state} = normalize_sse(sse_event("response.failed", terminal))
    [%{event: "response.failed", data: decoded}] = public_events(wire)
    {wire, decoded}
  end

  defp normalize_public_wire(:websocket, terminal) do
    state = StreamProtocol.public_openai_responses_websocket_state()

    {:push, wire, _state} =
      StreamProtocol.normalize_public_openai_responses_websocket_data(
        Jason.encode!(terminal),
        state
      )

    {wire, Jason.decode!(wire)}
  end

  defp expected_failed_response(overrides \\ []) do
    %{
      "id" => Keyword.get(overrides, :id, "resp_failed"),
      "created_at" => 0,
      "status" => "failed",
      "error" => %{
        "code" => Keyword.get(overrides, :code, "upstream_error"),
        "message" => "upstream request failed",
        "type" => "server_error"
      },
      "incomplete_details" => Keyword.get(overrides, :incomplete_details),
      "model" => "unknown",
      "object" => "response",
      "output" => [],
      "output_text" => "",
      "instructions" => nil,
      "metadata" => nil,
      "parallel_tool_calls" => false,
      "tool_choice" => "auto",
      "tools" => [],
      "usage" => Keyword.get(overrides, :usage),
      "temperature" => nil,
      "top_p" => nil
    }
  end

  defp malformed_terminal(:top_level, error) do
    %{
      "type" => "response.failed",
      "error" => error,
      "response" => %{"id" => "resp_non_map_top_level", "status" => "failed"}
    }
  end

  defp malformed_terminal(:nested, error) do
    %{
      "type" => "response.failed",
      "response" => %{
        "id" => "resp_non_map_nested",
        "status" => "failed",
        "error" => error
      }
    }
  end

  defp terminal_errors(decoded) do
    %{
      top_level: fetch_error(decoded),
      nested: decoded |> Map.fetch!("response") |> fetch_error()
    }
  end

  defp fetch_error(container) do
    case Map.fetch(container, "error") do
      {:ok, error} -> error
      :error -> :absent
    end
  end

  defp completed(id) do
    %{
      "type" => "response.completed",
      "response" => %{"id" => id, "status" => "completed"}
    }
  end

  defp done(id) do
    %{
      "type" => "response.done",
      "response" => %{"id" => id}
    }
  end

  defp incomplete(id, reason) do
    response = %{"id" => id, "status" => "incomplete"}

    response =
      if is_binary(reason) do
        Map.put(response, "incomplete_details", %{"reason" => reason})
      else
        response
      end

    %{"type" => "response.incomplete", "response" => response}
  end

  defp failed_without_nested_code(id) do
    %{
      "type" => "response.failed",
      "response" => %{"id" => id, "status" => "failed"}
    }
  end

  defp terminal_shape(type, :failed) do
    %{"type" => type, "response" => %{"id" => "resp_mismatch_failed", "status" => "failed"}}
  end

  defp terminal_shape(type, :incomplete) do
    %{
      "type" => type,
      "response" => %{"id" => "resp_mismatch_incomplete", "status" => "incomplete"}
    }
  end

  defp terminal_shape(type, :error) do
    %{"type" => type, "error" => %{"code" => "server_error"}}
  end

  defp oversized_incomplete_sse(:late) do
    IO.iodata_to_binary([
      ~s(data: {"private":"private-oversized-sentinel","padding":"),
      String.duplicate("x", StreamProtocol.max_incomplete_sse_block_bytes() + 1_024),
      ~s(","type":"response.failed","response":{"id":"resp_oversized_late","status":"failed"}})
    ])
  end

  defp emit_oversized_incomplete_sse(prefix, observed_bytes) do
    stream = prefix <> String.duplicate("x", observed_bytes - byte_size(prefix))
    state = StreamProtocol.public_openai_responses_stream_state()

    {_output, state} =
      StreamProtocol.normalize_public_openai_responses_sse_data(stream, state)

    assert state.buffer == ""
  end

  defp response_event_map(type), do: %{"type" => type}

  defp response_event(type, sequence, extra \\ %{}) do
    decoded = Map.merge(%{"type" => type}, extra)

    decoded =
      if is_nil(sequence), do: decoded, else: Map.put(decoded, "sequence_number", sequence)

    sse_event(type, decoded)
  end

  defp sse_event(type, decoded) do
    ["event: ", type, "\n", "data: ", Jason.encode!(decoded), "\n\n"]
  end

  defp sse_data(decoded), do: ["data: ", Jason.encode!(decoded), "\n\n"]

  defp public_events(output) do
    output
    |> StreamProtocol.complete_sse_blocks(bounded?: false)
    |> elem(0)
    |> Enum.map(fn block ->
      %{
        event: StreamProtocol.sse_field(block, "event"),
        data: block |> StreamProtocol.sse_field("data") |> StreamProtocol.decode_sse_data()
      }
    end)
  end

  defp terminal_event?(%{event: event}) do
    event in ["response.completed", "response.failed", "response.incomplete", "error"]
  end
end
