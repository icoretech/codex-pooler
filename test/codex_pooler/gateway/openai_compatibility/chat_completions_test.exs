defmodule CodexPooler.Gateway.OpenAICompatibility.ChatCompletionsTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.ChatCompletions
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

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

    test "normalizes split response.created blocks above the generic SSE buffer limit" do
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

      split_at = StreamProtocol.max_incomplete_sse_block_bytes() + 1
      first = binary_part(event, 0, split_at)
      second = binary_part(event, split_at, byte_size(event) - split_at)

      assert byte_size(event) > StreamProtocol.max_incomplete_sse_block_bytes()
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
  end

  defp sse_event(type, data), do: ["event: ", type, "\n", "data: ", Jason.encode!(data), "\n\n"]

  defp normalized_sse_payloads(normalized) do
    normalized
    |> String.split("\n\n", trim: true)
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
    |> Enum.map(&Jason.decode!/1)
  end
end
