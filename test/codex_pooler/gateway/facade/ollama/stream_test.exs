defmodule CodexPooler.Gateway.Facade.Ollama.StreamTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Facade.Ollama.Stream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona
  alias CodexPooler.Gateway.Runtime.Streaming.DownstreamStream

  test "projects byte-split Responses SSE into complete chat NDJSON without duplicates" do
    source =
      [
        event("response.created", %{
          "type" => "response.created",
          "response" => %{"id" => "provider-response-id", "status" => "in_progress"}
        }),
        event("response.reasoning_summary_text.delta", %{
          "type" => "response.reasoning_summary_text.delta",
          "delta" => "Check "
        }),
        event("response.reasoning_summary_text.delta", %{
          "type" => "response.reasoning_summary_text.delta",
          "delta" => "safely"
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
            "status" => "completed",
            "model" => "provider-hidden-model",
            "usage" => %{"input_tokens" => 9, "output_tokens" => 4, "total_tokens" => 13}
          }
        })
      ]
      |> IO.iodata_to_binary()

    {output, state} = normalize_chunks(Stream.new(formatting(:chat, think?: true)), bytes(source))
    lines = ndjson(output)

    assert Enum.all?(String.split(output, "\n", trim: true), fn line ->
             match?({:ok, %{}}, Jason.decode(line))
           end)

    assert Enum.map(summary_lines(lines), &get_in(&1, ["message", "thinking"])) == [
             "Check ",
             "safely"
           ]

    assert Enum.map(text_lines(lines), &get_in(&1, ["message", "content"])) == ["Hel", "lo"]

    assert [tool_line] = Enum.filter(lines, &get_in(&1, ["message", "tool_calls"]))

    assert [
             %{
               "id" => local_call_id,
               "function" => %{
                 "name" => "lookup_weather",
                 "arguments" => %{"city" => "London"}
               }
             }
           ] = get_in(tool_line, ["message", "tool_calls"])

    assert String.starts_with?(local_call_id, "call_")
    refute local_call_id in ["provider-call-id", "provider-function-id"]

    assert [terminal] = Enum.filter(lines, &(&1["done"] == true))
    assert terminal["model"] == "gemma3"
    assert terminal["done_reason"] == "stop"
    assert terminal["prompt_eval_count"] == 9
    assert terminal["eval_count"] == 4
    assert get_in(terminal, ["message", "content"]) == ""
    assert Enum.all?(lines, &(&1["model"] == "gemma3"))

    refute output =~ "provider-response-id"
    refute output =~ "provider-hidden-model"
    refute output =~ "provider-function-id"
    refute output =~ "provider-call-id"
    assert Stream.visible_seen?(state)
    assert Stream.terminal_outcome(state) == :completed
  end

  test "keeps generate thinking separate and truncates visible text at a split stop" do
    source =
      IO.iodata_to_binary([
        event("response.reasoning_summary_text.delta", %{
          "type" => "response.reasoning_summary_text.delta",
          "delta" => "Plan"
        }),
        event("response.output_text.delta", %{
          "type" => "response.output_text.delta",
          "delta" => "answer<EN"
        }),
        event("response.output_text.delta", %{
          "type" => "response.output_text.delta",
          "delta" => "D>private"
        }),
        event("response.incomplete", %{
          "type" => "response.incomplete",
          "response" => %{
            "status" => "incomplete",
            "incomplete_details" => %{"reason" => "max_output_tokens"},
            "usage" => %{"input_tokens" => 3, "output_tokens" => 2}
          }
        })
      ])

    state = Stream.new(formatting(:generate, think?: true, stops: ["<END>"]))
    {output, state} = normalize_chunks(state, bytes(source))
    lines = ndjson(output)

    assert Enum.map(summary_lines(lines), & &1["thinking"]) == ["Plan"]
    assert Enum.map(text_lines(lines), & &1["response"]) == ["answer"]
    refute output =~ "private"

    assert [terminal] = Enum.filter(lines, &(&1["done"] == true))
    assert terminal["response"] == ""
    assert terminal["done_reason"] == "stop"
    assert Stream.terminal_outcome(state) == :incomplete
  end

  test "bounds one incomplete SSE frame at exactly 1,048,576 bytes and emits one safe terminal" do
    attach_buffer_telemetry()
    state = Stream.new(formatting(:chat))
    prefix = "event: response.output_text.delta\ndata: "

    within_limit =
      prefix <> String.duplicate("x", Stream.max_incomplete_frame_bytes() - byte_size(prefix))

    assert {"", state} = Stream.normalize_data(within_limit, state)
    assert byte_size(state.buffer) == Stream.max_incomplete_frame_bytes()

    assert {~s({"error":"request failed","done":true}\n), state} =
             Stream.normalize_data("x", state)

    assert state.buffer == ""
    assert {:failed, failure} = Stream.terminal_outcome(state)
    assert failure.code == "ollama_stream_frame_too_large"

    assert_receive {[:codex_pooler, :gateway, :stream_buffer, :oversized],
                    %{bytes: 1_048_577, max_bytes: 1_048_576}, %{buffer: "ollama_sse"}}

    assert {"", same_state} = Stream.normalize_data("private-upstream-tail", state)
    assert same_state == state
  end

  test "emits complete blocks before safely terminating an oversized trailing frame" do
    complete =
      event("response.output_text.delta", %{
        "type" => "response.output_text.delta",
        "delta" => "kept"
      })

    prefix = "event: response.output_text.delta\ndata: "
    oversized = prefix <> String.duplicate("x", Stream.max_incomplete_frame_bytes())

    assert {output, state} =
             Stream.normalize_data(complete <> oversized, Stream.new(formatting(:chat)))

    assert [visible, terminal] = ndjson(output)
    assert get_in(visible, ["message", "content"]) == "kept"
    assert terminal == %{"error" => "request failed", "done" => true}
    assert Stream.visible_seen?(state)
    assert {:failed, failure} = Stream.terminal_outcome(state)
    assert failure.code == "ollama_stream_frame_too_large"
  end

  test "bounds assembled tool arguments and never publishes a partial provider payload" do
    state = Stream.new(formatting(:chat))

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

    assert {"", state} = Stream.normalize_data(added, state)

    assert {~s({"error":"request failed","done":true}\n), state} =
             Stream.normalize_data(delta, state)

    assert {:failed, failure} = Stream.terminal_outcome(state)
    assert failure.code == "ollama_tool_arguments_too_large"
    refute inspect(state) =~ String.duplicate("x", 256)
  end

  test "synthesizes exactly one safe terminal failure after visible output" do
    state = Stream.new(formatting(:chat))

    assert {line, state} =
             Stream.normalize_data(
               event("response.output_text.delta", %{
                 "type" => "response.output_text.delta",
                 "delta" => "visible"
               }),
               state
             )

    assert [%{"done" => false}] = ndjson(line)

    assert {~s({"error":"request failed","done":true}\n), state} =
             Stream.synthetic_terminal_failure(state)

    assert {:failed, _failure} = Stream.terminal_outcome(state)
    assert {nil, ^state} = Stream.synthetic_terminal_failure(state)
  end

  test "DownstreamStream installs only the typed Ollama persona and keeps partial bytes private" do
    formatting = formatting(:chat, think?: true)

    opts =
      RequestOptions.build(
        %{
          persona: Persona.fixed(:ollama_chat),
          public_ollama_stream: true,
          ollama_surface: :chat,
          ollama_formatting: formatting
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
    refute DownstreamStream.public_ollama_visible_seen?(state)

    assert {~s({"error":"request failed","done":true}\n), state} =
             DownstreamStream.synthetic_terminal_failure(state, :closed)

    assert {:failed, failure} = DownstreamStream.terminal_outcome(state)
    assert failure.code == "ollama_stream_interrupted"
    assert {nil, ^state} = DownstreamStream.synthetic_terminal_failure(state, :closed)
  end

  defp formatting(surface, opts \\ []) do
    %{
      surface: surface,
      stream?: true,
      think?: Keyword.get(opts, :think?, false),
      stops: Keyword.get(opts, :stops, []),
      started_at: System.monotonic_time()
    }
  end

  defp bytes(binary), do: for(<<byte <- binary>>, do: <<byte>>)

  defp normalize_chunks(state, chunks) do
    Enum.reduce(chunks, {[], state}, fn chunk, {output, state} ->
      {data, state} = Stream.normalize_data(chunk, state)
      {[output, data], state}
    end)
    |> then(fn {output, state} -> {IO.iodata_to_binary(output), state} end)
  end

  defp ndjson(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp summary_lines(lines) do
    Enum.filter(lines, fn line ->
      is_binary(line["thinking"]) or is_binary(get_in(line, ["message", "thinking"]))
    end)
  end

  defp text_lines(lines) do
    Enum.filter(lines, fn
      %{"done" => false, "response" => text} when is_binary(text) and text != "" ->
        true

      %{"done" => false, "message" => %{"content" => text}}
      when is_binary(text) and text != "" ->
        true

      _line ->
        false
    end)
  end

  defp event(name, payload) do
    "event: " <> name <> "\n" <> "data: " <> Jason.encode!(payload) <> "\n\n"
  end

  defp attach_buffer_telemetry do
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
