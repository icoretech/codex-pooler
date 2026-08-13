defmodule CodexPooler.Gateway.OpenAICompatibility.ChatCompletionsTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.ChatCompletions

  describe "normalize_response/2" do
    test "preserves a literal provider service tier and omits absent or non-string tiers" do
      payload = %{"model" => "gpt-example"}

      assert ChatCompletions.normalize_response(
               %{"id" => "resp_fast", "status" => "completed", "service_tier" => "fast"},
               payload
             )["service_tier"] == "fast"

      for response <- [
            %{"id" => "resp_absent", "status" => "completed"},
            %{"id" => "resp_non_string", "status" => "completed", "service_tier" => 1}
          ] do
        refute Map.has_key?(ChatCompletions.normalize_response(response, payload), "service_tier")
      end
    end

    test "projects completed custom tool calls without parsing free-form input" do
      input = "print(\"hello\")\nreturn 42"

      normalized =
        ChatCompletions.normalize_response(
          %{
            "id" => "resp_custom_fixture",
            "status" => "completed",
            "output" => [
              %{
                "type" => "custom_tool_call",
                "call_id" => "call_custom_fixture",
                "name" => "code_exec",
                "input" => input
              }
            ]
          },
          %{"model" => "gpt-example"}
        )

      assert get_in(normalized, ["choices", Access.at(0), "message", "tool_calls"]) == [
               %{
                 "id" => "call_custom_fixture",
                 "type" => "custom",
                 "custom" => %{"name" => "code_exec", "input" => input},
                 "index" => 0
               }
             ]
    end
  end

  describe "normalize_stream_data/2" do
    test "carries split stream parser state explicitly" do
      state = ChatCompletions.stream_state(%{"model" => "gpt-example"})

      split_event =
        [
          "event: response.output_text.delta\n",
          "data: ",
          Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "split answer"})
        ]
        |> IO.iodata_to_binary()

      assert {"", state} = ChatCompletions.normalize_stream_data(split_event, state)
      assert {chunk, _state} = ChatCompletions.normalize_stream_data("\n\n", state)

      assert chunk =~ "\"object\":\"chat.completion.chunk\""
      assert chunk =~ "\"role\":\"assistant\""
      assert chunk =~ "\"content\":\"split answer\""
      refute Process.get({:openai_chat_completions_stream_state, "gpt-example"})
    end

    test "normalizes response.created blocks split across chunk boundaries" do
      state = ChatCompletions.stream_state(%{"model" => "gpt-example"})

      event =
        [
          "event: response.created\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.created",
            "response" => %{
              "id" => "resp_split_created",
              "model" => "gpt-example",
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

      split_at = div(byte_size(event), 2)
      first = binary_part(event, 0, split_at)
      second = binary_part(event, split_at, byte_size(event) - split_at)

      assert {"", state} = ChatCompletions.normalize_stream_data(first, state)

      assert {chunk, state} = ChatCompletions.normalize_stream_data(second <> "\n\n", state)

      assert chunk =~ "\"object\":\"chat.completion.chunk\""
      assert chunk =~ "\"role\":\"assistant\""
      refute chunk =~ "response.created"
      refute state.discarding_oversized?
    end

    test "discards pathological incomplete response.created blocks without raw passthrough" do
      state = ChatCompletions.stream_state(%{"model" => "gpt-example"})

      oversized =
        [
          "event: response.created\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.created",
            "response" => %{
              "id" => "resp_pathological_created",
              "model" => "gpt-example",
              "tools" => [
                %{
                  "type" => "function",
                  "name" => "synthetic_tool",
                  "description" => String.duplicate("synthetic description ", 60_000)
                }
              ]
            }
          })
        ]
        |> IO.iodata_to_binary()

      assert {role_chunk, state} = ChatCompletions.normalize_stream_data(oversized, state)

      assert role_chunk =~ "\"object\":\"chat.completion.chunk\""
      assert role_chunk =~ "\"role\":\"assistant\""
      refute role_chunk =~ "response.created"
      refute role_chunk =~ "synthetic description"
      assert state.discarding_oversized?

      delta =
        [
          "event: response.output_text.delta\n",
          "data: ",
          Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "after overflow"}),
          "\n\n"
        ]
        |> IO.iodata_to_binary()

      assert {delta_chunk, state} = ChatCompletions.normalize_stream_data("\n\n" <> delta, state)

      assert delta_chunk =~ "\"content\":\"after overflow\""
      refute delta_chunk =~ "response.output_text.delta"
      refute state.discarding_oversized?
    end

    test "emits function-call arguments only when the item is added" do
      state = ChatCompletions.stream_state(%{"model" => "gpt-example"})
      arguments = ~s({"timezone":"UTC"})

      item = %{
        "type" => "function_call",
        "id" => "call_terminal_only",
        "name" => "lookup_time",
        "arguments" => arguments
      }

      stream =
        [
          sse_event("response.output_item.added", %{
            "type" => "response.output_item.added",
            "output_index" => 0,
            "item" => item
          }),
          sse_event("response.output_item.done", %{
            "type" => "response.output_item.done",
            "output_index" => 0,
            "item" => item
          })
        ]
        |> IO.iodata_to_binary()

      assert {normalized, _state} = ChatCompletions.normalize_stream_data(stream, state)

      tool_calls =
        normalized
        |> normalized_sse_payloads()
        |> Enum.flat_map(&(get_in(&1, ["choices", Access.at(0), "delta", "tool_calls"]) || []))

      assert Enum.map(tool_calls, &get_in(&1, ["function", "arguments"])) == [arguments]
      assert Enum.map(tool_calls, & &1["id"]) == ["call_terminal_only"]
    end

    test "streams custom tool headers and free-form input fragments" do
      state = ChatCompletions.stream_state(%{"model" => "gpt-example"})

      stream =
        [
          sse_event("response.output_item.added", %{
            "type" => "response.output_item.added",
            "output_index" => 0,
            "item" => %{
              "type" => "custom_tool_call",
              "call_id" => "call_custom_fixture",
              "name" => "code_exec",
              "input" => ""
            }
          }),
          sse_event("response.custom_tool_call_input.delta", %{
            "type" => "response.custom_tool_call_input.delta",
            "output_index" => 0,
            "call_id" => "call_custom_fixture",
            "delta" => "print(\"hel"
          }),
          sse_event("response.custom_tool_call_input.delta", %{
            "type" => "response.custom_tool_call_input.delta",
            "output_index" => 0,
            "call_id" => "call_custom_fixture",
            "delta" => "lo\")\nreturn 42"
          })
        ]
        |> IO.iodata_to_binary()

      assert {normalized, _state} = ChatCompletions.normalize_stream_data(stream, state)

      assert normalized
             |> normalized_sse_payloads()
             |> Enum.flat_map(
               &(get_in(&1, ["choices", Access.at(0), "delta", "tool_calls"]) || [])
             ) ==
               [
                 %{
                   "index" => 0,
                   "id" => "call_custom_fixture",
                   "type" => "custom",
                   "custom" => %{"name" => "code_exec", "input" => ""}
                 },
                 %{"index" => 0, "custom" => %{"input" => "print(\"hel"}},
                 %{"index" => 0, "custom" => %{"input" => "lo\")\nreturn 42"}}
               ]
    end

    test "adds a literal tier only to chunks emitted after it is observed" do
      state =
        ChatCompletions.stream_state(%{
          "model" => "gpt-example",
          "stream_options" => %{"include_usage" => true}
        })

      early =
        sse_event("response.output_text.delta", %{
          "type" => "response.output_text.delta",
          "delta" => "before tier"
        })
        |> IO.iodata_to_binary()

      assert {early_output, state} = ChatCompletions.normalize_stream_data(early, state)
      refute Enum.any?(normalized_sse_payloads(early_output), &Map.has_key?(&1, "service_tier"))

      terminal =
        sse_event("response.completed", %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_late_tier",
            "status" => "completed",
            "service_tier" => "fast",
            "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
          }
        })
        |> IO.iodata_to_binary()

      assert {terminal_output, _state} = ChatCompletions.normalize_stream_data(terminal, state)

      assert Enum.all?(normalized_sse_payloads(terminal_output), fn payload ->
               payload["service_tier"] == "fast"
             end)
    end

    test "omits absent and non-string observed stream tiers" do
      for tier <- [nil, 1] do
        state = ChatCompletions.stream_state(%{"model" => "gpt-example"})

        stream =
          sse_event("response.created", %{
            "type" => "response.created",
            "response" => %{"id" => "resp_tier_omitted", "service_tier" => tier}
          })
          |> IO.iodata_to_binary()

        assert {output, _state} = ChatCompletions.normalize_stream_data(stream, state)
        refute Enum.any?(normalized_sse_payloads(output), &Map.has_key?(&1, "service_tier"))
      end
    end

    test "blank event labels use the data type while nonblank mismatches remain rejected" do
      failed = %{
        "type" => "response.failed",
        "prompt" => "private-chat-prompt-sentinel",
        "response" => %{
          "id" => "resp_chat_blank",
          "status" => "failed",
          "error" => %{"code" => "server_error", "message" => "provider detail"}
        }
      }

      for event_line <- ["", "event:\n", "event: \t \n"] do
        state = ChatCompletions.stream_state(%{"model" => "gpt-example"})

        stream =
          IO.iodata_to_binary([
            event_line,
            "data: ",
            Jason.encode!(failed),
            "\n\n",
            sse_event("response.completed", %{
              "type" => "response.completed",
              "response" => %{"id" => "resp_chat_late", "status" => "completed"}
            })
          ])

        assert {output, state} = ChatCompletions.normalize_stream_data(stream, state)
        assert [%{"error" => error}] = normalized_sse_payloads(output)
        assert error["message"] == "upstream request failed"
        refute output =~ "private-chat-prompt-sentinel"
        assert state.terminal_seen?
      end

      state = ChatCompletions.stream_state(%{"model" => "gpt-example"})
      mismatch = "event: response.completed\ndata: " <> Jason.encode!(failed) <> "\n\n"
      assert {"", state} = ChatCompletions.normalize_stream_data(mismatch, state)
      refute state.terminal_seen?
    end

    test "clears only a buffer whose current batch contains a terminal" do
      terminal =
        sse_event("response.completed", %{
          "type" => "response.completed",
          "response" => %{"id" => "resp_current_batch", "status" => "completed"}
        })
        |> IO.iodata_to_binary()

      state = ChatCompletions.stream_state(%{"model" => "gpt-example"})
      assert {_output, terminal_state} = ChatCompletions.normalize_stream_data(terminal, state)
      assert terminal_state.terminal_seen?
      assert terminal_state.buffer == ""

      assert {"", later_state} =
               ChatCompletions.normalize_stream_data("data: partial", terminal_state)

      assert later_state.terminal_seen?
      assert later_state.buffer == "data: partial"

      assert {"", repeated_terminal_state} =
               ChatCompletions.normalize_stream_data(
                 terminal <> "data: partial",
                 terminal_state
               )

      assert repeated_terminal_state.terminal_seen?
      assert repeated_terminal_state.buffer == ""

      state = ChatCompletions.stream_state(%{"model" => "gpt-example"})

      assert {_output, same_batch_state} =
               ChatCompletions.normalize_stream_data(terminal <> "data: partial", state)

      assert same_batch_state.terminal_seen?
      assert same_batch_state.buffer == ""
    end
  end

  describe "synthetic_terminal_failure_chunk/2" do
    test "emits the nested chat error payload and latches the terminal" do
      state = ChatCompletions.stream_state(%{"model" => "gpt-example"})
      message = "synthetic public stream failure"

      assert {chunk, state} =
               ChatCompletions.synthetic_terminal_failure_chunk(state, message)

      assert state.terminal_seen?

      assert normalized_sse_payloads(chunk) == [
               %{
                 "error" => %{
                   "message" => message,
                   "type" => "server_error",
                   "code" => "server_error",
                   "param" => nil
                 }
               }
             ]

      refute chunk =~ "data: [DONE]"
      refute chunk =~ "finish_reason"
    end
  end

  defp sse_event(type, data), do: ["event: ", type, "\n", "data: ", Jason.encode!(data), "\n\n"]

  defp normalized_sse_payloads(normalized) do
    normalized
    |> String.split("\n\n", trim: true)
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
    |> Enum.reject(&String.contains?(&1, "[DONE]"))
    |> Enum.map(&Jason.decode!/1)
  end
end
