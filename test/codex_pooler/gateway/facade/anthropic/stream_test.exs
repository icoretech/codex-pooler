defmodule CodexPooler.Gateway.Facade.Anthropic.StreamTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Facade.Anthropic.Stream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona
  alias CodexPooler.Gateway.Runtime.Streaming.DownstreamStream

  test "projects Responses SSE into an exact Anthropic text, thinking, and tool sequence" do
    source = complete_source()
    {output, state} = normalize_chunks(Stream.new(formatting(think?: true)), bytes(source))
    events = sse_events(output)

    assert Enum.map(events, & &1.event) == [
             "message_start",
             "content_block_start",
             "content_block_delta",
             "content_block_delta",
             "content_block_delta",
             "content_block_stop",
             "content_block_start",
             "content_block_delta",
             "content_block_delta",
             "content_block_stop",
             "content_block_start",
             "content_block_delta",
             "content_block_stop",
             "message_delta",
             "message_stop"
           ]

    [start | _rest] = events
    assert start.data["type"] == "message_start"
    assert start.data["message"]["model"] == "gemma3"
    assert start.data["message"]["role"] == "assistant"
    assert start.data["message"]["content"] == []
    assert String.starts_with?(start.data["message"]["id"], "msg_")

    assert [thinking_start] = event_data(events, "content_block_start", "thinking")
    assert thinking_start["index"] == 0
    assert thinking_start["content_block"]["signature"] == ""

    thinking_deltas =
      events
      |> Enum.filter(&(get_in(&1.data, ["delta", "type"]) == "thinking_delta"))
      |> Enum.map(&get_in(&1.data, ["delta", "thinking"]))

    assert thinking_deltas == ["Check ", "safely"]

    assert [signature_delta] =
             Enum.filter(events, &(get_in(&1.data, ["delta", "type"]) == "signature_delta"))

    assert String.starts_with?(signature_delta.data["delta"]["signature"], "sig_")

    text_deltas =
      events
      |> Enum.filter(&(get_in(&1.data, ["delta", "type"]) == "text_delta"))
      |> Enum.map(&get_in(&1.data, ["delta", "text"]))

    assert text_deltas == ["Hel", "lo"]

    assert [tool_start] = event_data(events, "content_block_start", "tool_use")
    assert tool_start["index"] == 2
    assert tool_start["content_block"]["name"] == "lookup_weather"
    assert tool_start["content_block"]["input"] == %{}
    assert String.starts_with?(tool_start["content_block"]["id"], "toolu_")

    assert [tool_delta] =
             Enum.filter(events, &(get_in(&1.data, ["delta", "type"]) == "input_json_delta"))

    assert Jason.decode!(tool_delta.data["delta"]["partial_json"]) == %{"city" => "London"}

    assert [message_delta] = Enum.filter(events, &(&1.event == "message_delta"))
    assert message_delta.data["delta"] == %{"stop_reason" => "tool_use", "stop_sequence" => nil}

    assert message_delta.data["usage"] == %{
             "input_tokens" => 7,
             "cache_creation_input_tokens" => 0,
             "cache_read_input_tokens" => 2,
             "output_tokens" => 4
           }

    assert Stream.visible_seen?(state)
    assert Stream.terminal_outcome(state) == :completed

    for hidden <- [
          "provider-response-id",
          "provider-hidden-model",
          "provider-function-id",
          "provider-call-id",
          "provider-encrypted-content"
        ] do
      refute output =~ hidden
    end
  end

  test "is invariant across every byte boundary" do
    source =
      IO.iodata_to_binary([
        event("response.output_text.delta", %{
          "type" => "response.output_text.delta",
          "delta" => "hello"
        }),
        event("response.completed", %{
          "type" => "response.completed",
          "response" => %{
            "status" => "completed",
            "usage" => %{"input_tokens" => 2, "output_tokens" => 1}
          }
        })
      ])

    for split <- 0..byte_size(source) do
      chunks = [
        binary_part(source, 0, split),
        binary_part(source, split, byte_size(source) - split)
      ]

      {output, state} = normalize_chunks(Stream.new(formatting()), chunks)
      events = sse_events(output)

      assert Enum.map(events, & &1.event) == [
               "message_start",
               "content_block_start",
               "content_block_delta",
               "content_block_stop",
               "message_delta",
               "message_stop"
             ]

      assert ["hello"] ==
               events
               |> Enum.filter(&(get_in(&1.data, ["delta", "type"]) == "text_delta"))
               |> Enum.map(&get_in(&1.data, ["delta", "text"]))

      assert Stream.terminal_outcome(state) == :completed
    end
  end

  test "keeps split stop bytes private and reports the matched stop sequence" do
    source =
      IO.iodata_to_binary([
        event("response.output_text.delta", %{
          "type" => "response.output_text.delta",
          "delta" => "answer<EN"
        }),
        event("response.output_text.delta", %{
          "type" => "response.output_text.delta",
          "delta" => "D>private"
        }),
        event("response.completed", %{
          "type" => "response.completed",
          "response" => %{"status" => "completed", "usage" => %{}}
        })
      ])

    {output, _state} = normalize_chunks(Stream.new(formatting(stops: ["<END>"])), bytes(source))
    events = sse_events(output)

    assert ["answer"] ==
             events
             |> Enum.filter(&(get_in(&1.data, ["delta", "type"]) == "text_delta"))
             |> Enum.map(&get_in(&1.data, ["delta", "text"]))

    assert [terminal] = Enum.filter(events, &(&1.event == "message_delta"))

    assert terminal.data["delta"] == %{
             "stop_reason" => "stop_sequence",
             "stop_sequence" => "<END>"
           }

    refute output =~ "private"
  end

  test "bounds one incomplete SSE frame at exactly 1,048,576 bytes" do
    attach_buffer_telemetry()
    state = Stream.new(formatting())
    prefix = "event: response.output_text.delta\ndata: "

    within_limit =
      prefix <> String.duplicate("x", Stream.max_incomplete_frame_bytes() - byte_size(prefix))

    assert {"", state} = Stream.normalize_data(within_limit, state)
    assert byte_size(state.buffer) == Stream.max_incomplete_frame_bytes()

    assert {terminal, state} = Stream.normalize_data("x", state)
    assert [%{event: "error", data: error}] = sse_events(terminal)

    assert error == %{
             "type" => "error",
             "error" => %{"type" => "api_error", "message" => "request failed"}
           }

    assert state.buffer == ""
    assert {:failed, failure} = Stream.terminal_outcome(state)
    assert failure.code == "anthropic_stream_frame_too_large"

    assert_receive {[:codex_pooler, :gateway, :stream_buffer, :oversized],
                    %{bytes: 1_048_577, max_bytes: 1_048_576}, %{buffer: "anthropic_sse"}}

    assert {"", same_state} = Stream.normalize_data("provider-private-tail", state)
    assert same_state == state
  end

  test "bounds assembled tool JSON and publishes no provider fragment" do
    added =
      event("response.output_item.added", %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "id" => "provider-item",
          "name" => "large_tool",
          "arguments" => ""
        }
      })

    delta =
      event("response.function_call_arguments.delta", %{
        "type" => "response.function_call_arguments.delta",
        "output_index" => 0,
        "item_id" => "provider-item",
        "delta" => String.duplicate("x", Stream.max_tool_argument_bytes() + 1)
      })

    assert {"", state} = Stream.normalize_data(added, Stream.new(formatting()))
    assert {terminal, state} = Stream.normalize_data(delta, state)
    assert [%{event: "error"}] = sse_events(terminal)
    assert {:failed, failure} = Stream.terminal_outcome(state)
    assert failure.code == "anthropic_tool_arguments_too_large"
    refute inspect(state) =~ String.duplicate("x", 256)
  end

  test "synthesizes one safe late error and installs only the typed Anthropic persona" do
    opts =
      RequestOptions.build(
        %{
          persona: Persona.fixed(:anthropic_messages),
          public_anthropic_stream: true,
          anthropic_formatting: formatting()
        },
        "/backend-api/codex/responses",
        %{"stream" => true}
      )

    state = DownstreamStream.initial_state(:relay, opts)
    partial = ~s(event: response.output_text.delta\ndata: {"type":"response.output_text.delta")

    assert {"", state} =
             DownstreamStream.normalize_data(
               partial,
               "/backend-api/codex/responses",
               opts,
               state
             )

    refute DownstreamStream.keepalive_allowed?(state)
    refute DownstreamStream.public_anthropic_visible_seen?(state)

    assert {terminal, state} = DownstreamStream.synthetic_terminal_failure(state, :closed)
    assert [%{event: "error", data: %{"type" => "error"}}] = sse_events(terminal)
    assert {:failed, failure} = DownstreamStream.terminal_outcome(state)
    assert failure.code == "anthropic_stream_interrupted"
    assert {nil, ^state} = DownstreamStream.synthetic_terminal_failure(state, :closed)
  end

  defp complete_source do
    IO.iodata_to_binary([
      event("response.created", %{
        "type" => "response.created",
        "response" => %{
          "id" => "provider-response-id",
          "model" => "provider-hidden-model",
          "status" => "in_progress"
        }
      }),
      event("response.reasoning_summary_text.delta", %{
        "type" => "response.reasoning_summary_text.delta",
        "delta" => "Check "
      }),
      event("response.reasoning_summary_text.delta", %{
        "type" => "response.reasoning_summary_text.delta",
        "delta" => "safely",
        "encrypted_content" => "provider-encrypted-content"
      }),
      event("response.output_text.delta", %{
        "type" => "response.output_text.delta",
        "delta" => "Hel"
      }),
      event("response.output_text.delta", %{
        "type" => "response.output_text.delta",
        "delta" => "lo"
      }),
      event("response.output_item.added", %{
        "type" => "response.output_item.added",
        "output_index" => 1,
        "item" => %{
          "type" => "function_call",
          "id" => "provider-function-id",
          "call_id" => "provider-call-id",
          "name" => "lookup_weather",
          "arguments" => ""
        }
      }),
      event("response.function_call_arguments.delta", %{
        "type" => "response.function_call_arguments.delta",
        "output_index" => 1,
        "item_id" => "provider-function-id",
        "delta" => ~s({"city":)
      }),
      event("response.function_call_arguments.delta", %{
        "type" => "response.function_call_arguments.delta",
        "output_index" => 1,
        "item_id" => "provider-function-id",
        "delta" => ~s("London"})
      }),
      event("response.function_call_arguments.done", %{
        "type" => "response.function_call_arguments.done",
        "output_index" => 1,
        "item_id" => "provider-function-id",
        "arguments" => ~s({"city":"London"})
      }),
      event("response.output_item.done", %{
        "type" => "response.output_item.done",
        "output_index" => 1,
        "item" => %{
          "type" => "function_call",
          "id" => "provider-function-id",
          "call_id" => "provider-call-id",
          "name" => "lookup_weather",
          "arguments" => ~s({"city":"London"})
        }
      }),
      event("response.completed", %{
        "type" => "response.completed",
        "response" => %{
          "id" => "provider-response-id",
          "model" => "provider-hidden-model",
          "status" => "completed",
          "usage" => %{
            "input_tokens" => 9,
            "input_tokens_details" => %{"cached_tokens" => 2},
            "output_tokens" => 4
          }
        }
      })
    ])
  end

  defp formatting(opts \\ []) do
    %{
      stream?: true,
      think?: Keyword.get(opts, :think?, false),
      stops: Keyword.get(opts, :stops, []),
      max_tokens: 96
    }
  end

  defp normalize_chunks(state, chunks) do
    Enum.reduce(chunks, {[], state}, fn chunk, {output, state} ->
      {data, state} = Stream.normalize_data(chunk, state)
      {[output, data], state}
    end)
    |> then(fn {output, state} -> {IO.iodata_to_binary(output), state} end)
  end

  defp event_data(events, event_name, block_type) do
    events
    |> Enum.filter(&(&1.event == event_name))
    |> Enum.map(& &1.data)
    |> Enum.filter(&(get_in(&1, ["content_block", "type"]) == block_type))
  end

  defp sse_events(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      lines = String.split(block, "\n")

      event =
        lines
        |> Enum.find(&String.starts_with?(&1, "event: "))
        |> String.replace_prefix("event: ", "")

      data =
        lines
        |> Enum.find(&String.starts_with?(&1, "data: "))
        |> String.replace_prefix("data: ", "")
        |> Jason.decode!()

      %{event: event, data: data}
    end)
  end

  defp bytes(binary), do: for(<<byte <- binary>>, do: <<byte>>)

  defp event(name, payload),
    do: "event: " <> name <> "\n" <> "data: " <> Jason.encode!(payload) <> "\n\n"

  defp attach_buffer_telemetry do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:codex_pooler, :gateway, :stream_buffer, :oversized],
      fn event, measurements, metadata, _config ->
        send(parent, {event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
