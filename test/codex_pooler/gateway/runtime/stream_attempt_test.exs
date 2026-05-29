defmodule CodexPooler.Gateway.Runtime.Streaming.StreamAttemptTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Streaming.StreamAttempt

  describe "classify_first_event/2" do
    test "buffers incomplete first SSE events before writing" do
      state = StreamAttempt.first_event_state()

      assert {:buffered, state} = StreamAttempt.classify_first_event("data: {\"type\"", state)

      assert {{:write, data}, state} =
               StreamAttempt.classify_first_event(
                 ":\"response.created\"}\n\n",
                 state
               )

      assert data == "data: {\"type\":\"response.created\"}\n\n"
      assert state == %{classified?: true, buffer: ""}
      refute Process.get({:codex_first_stream_event_state, "attempt-stream-classification"})
      refute Process.get({:codex_first_stream_event_buffer, "attempt-stream-classification"})
    end

    test "classifies retryable first terminal failures without writing them" do
      state = StreamAttempt.first_event_state()

      data =
        "event: response.failed\n" <>
          "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_error\"}}}\n\n"

      assert {{:retry, %{code: "server_error", event_type: "response.failed"}}, state} =
               StreamAttempt.classify_first_event(data, state)

      assert state == %{classified?: true, buffer: ""}
    end

    test "classifies overloaded first terminal failures as retryable" do
      state = StreamAttempt.first_event_state()

      data =
        "event: response.failed\n" <>
          "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"overloaded_error\"}}}\n\n"

      assert {{:retry, %{code: "overloaded_error", event_type: "response.failed"}}, state} =
               StreamAttempt.classify_first_event(data, state)

      assert state == %{classified?: true, buffer: ""}
    end

    test "classifies exact top-level websocket_connection_limit_reached wrapped errors as retryable before visible output" do
      state = StreamAttempt.first_event_state()

      data =
        Jason.encode!(%{
          "type" => "error",
          "status" => 400,
          "code" => "websocket_connection_limit_reached",
          "message" => "open a replacement websocket connection"
        })

      assert {{:retry,
               %{
                 code: "websocket_connection_limit_reached",
                 event_type: "error",
                 upstream_code: "websocket_connection_limit_reached"
               }}, state} = StreamAttempt.classify_first_event(data, state)

      assert state == %{classified?: true, buffer: ""}
    end

    test "classifies exact nested websocket_connection_limit_reached wrapped errors as retryable before visible output" do
      state = StreamAttempt.first_event_state()

      data =
        sse_event("error", %{
          "type" => "error",
          "status_code" => 400,
          "error" => %{
            "code" => "websocket_connection_limit_reached",
            "message" => "open a replacement websocket connection"
          }
        })

      assert {{:retry,
               %{
                 code: "websocket_connection_limit_reached",
                 event_type: "error",
                 upstream_code: "websocket_connection_limit_reached"
               }}, state} = StreamAttempt.classify_first_event(data, state)

      assert state == %{classified?: true, buffer: ""}
    end

    test "keeps unrelated_invalid_request wrapped 400 errors non-retryable" do
      state = StreamAttempt.first_event_state()

      data =
        Jason.encode!(%{
          "type" => "error",
          "status" => 400,
          "code" => "unrelated_invalid_request",
          "message" => "synthetic invalid request"
        })

      assert {{:write_terminal_failure, ^data,
               %{
                 code: "unrelated_invalid_request",
                 event_type: "error",
                 upstream_code: "unrelated_invalid_request"
               }}, state} = StreamAttempt.classify_first_event(data, state)

      assert state == %{classified?: true, buffer: ""}
    end

    test "allows websocket_connection_limit_reached retry after internal codex.rate_limits observation" do
      state = StreamAttempt.first_event_state()

      rate_limits =
        sse_event("codex.rate_limits", %{
          "type" => "codex.rate_limits",
          "rate_limits" => [
            %{
              "name" => "primary",
              "used_percent" => 42,
              "window_minutes" => 300,
              "resets_at" => "2026-05-25T12:00:00Z"
            }
          ]
        })

      {{:write, ^rate_limits}, state} = StreamAttempt.classify_first_event(rate_limits, state)

      limit_error =
        sse_event("error", %{
          "type" => "error",
          "status" => 400,
          "code" => "websocket_connection_limit_reached"
        })

      assert {{:retry,
               %{
                 code: "websocket_connection_limit_reached",
                 event_type: "error",
                 upstream_code: "websocket_connection_limit_reached"
               }}, state} = StreamAttempt.classify_first_event(limit_error, state)

      assert state == %{classified?: true, buffer: ""}
    end

    test "does not retry websocket_connection_limit_reached after downstream-visible response.created" do
      state = StreamAttempt.first_event_state()

      assert {{:write, _created}, state} =
               StreamAttempt.classify_first_event(
                 sse_event("response.created", %{
                   "type" => "response.created",
                   "response" => %{"id" => "resp_visible_created"}
                 }),
                 state
               )

      terminal =
        sse_event("error", %{
          "type" => "error",
          "status" => 400,
          "code" => "websocket_connection_limit_reached"
        })

      assert {{:write_terminal_failure, ^terminal,
               %{code: "websocket_connection_limit_reached", event_type: "error"}}, state} =
               StreamAttempt.classify_first_event(terminal, state)

      assert state == %{classified?: true, buffer: ""}
    end

    test "does not retry websocket_connection_limit_reached after downstream-visible text delta" do
      state = StreamAttempt.first_event_state()

      assert {{:write, _delta}, state} =
               StreamAttempt.classify_first_event(
                 sse_event("response.output_text.delta", %{
                   "type" => "response.output_text.delta",
                   "delta" => "visible synthetic text"
                 }),
                 state
               )

      terminal =
        sse_event("error", %{
          "type" => "error",
          "status" => 400,
          "code" => "websocket_connection_limit_reached"
        })

      assert {{:write_terminal_failure, ^terminal,
               %{code: "websocket_connection_limit_reached", event_type: "error"}}, state} =
               StreamAttempt.classify_first_event(terminal, state)

      assert state == %{classified?: true, buffer: ""}
    end

    test "does not retry websocket_connection_limit_reached after downstream-visible output item" do
      state = StreamAttempt.first_event_state()

      assert {{:write, _output}, state} =
               StreamAttempt.classify_first_event(
                 sse_event("response.output_item.added", %{
                   "type" => "response.output_item.added",
                   "item" => %{"type" => "message", "id" => "msg_visible_output"}
                 }),
                 state
               )

      terminal =
        sse_event("error", %{
          "type" => "error",
          "status" => 400,
          "code" => "websocket_connection_limit_reached"
        })

      assert {{:write_terminal_failure, ^terminal,
               %{code: "websocket_connection_limit_reached", event_type: "error"}}, state} =
               StreamAttempt.classify_first_event(terminal, state)

      assert state == %{classified?: true, buffer: ""}
    end

    test "keeps local first-and-only usage-limit terminal event failed and non-retryable" do
      state = StreamAttempt.first_event_state()

      terminal =
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

      assert {{:write_terminal_failure, ^terminal,
               %{
                 code: "usage_limit_exceeded",
                 event_type: "response.failed",
                 upstream_code: "usage_limit_exceeded"
               }}, state} = StreamAttempt.classify_first_event(terminal, state)

      assert state == %{classified?: true, buffer: ""}
    end

    test "detects terminal failures after the first event is classified" do
      state = StreamAttempt.first_event_state()

      assert {{:write, _data}, state} =
               StreamAttempt.classify_first_event(
                 ~s[event: response.created\ndata: {"type":"response.created"}\n\n],
                 state
               )

      terminal =
        "event: response.failed\n" <>
          "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"bad_request\"}}}\n\n"

      assert {{:write_terminal_failure, ^terminal, %{code: "bad_request"}}, state} =
               StreamAttempt.classify_first_event(terminal, state)

      assert state == %{classified?: true, buffer: ""}
    end

    test "rejects non-binary stream chunks instead of returning an invalid write classification" do
      state = StreamAttempt.first_event_state()

      assert_raise FunctionClauseError, fn ->
        StreamAttempt.classify_first_event(:not_a_stream_chunk, state)
      end
    end
  end

  defp sse_event(event, payload) do
    "event: " <> event <> "\n" <> "data: " <> Jason.encode!(payload) <> "\n\n"
  end
end
