defmodule CodexPooler.Gateway.Facade.Anthropic.Stream do
  @moduledoc """
  Incrementally projects canonical Responses SSE into Anthropic Messages SSE.

  The parser retains one bounded incomplete SSE frame and bounded tool JSON.
  Provider identifiers are transient lookup keys only; all public IDs and the
  thinking signature are minted locally.
  """

  alias CodexPooler.Gateway.Facade
  alias CodexPooler.Gateway.Facade.Anthropic.Response
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @max_incomplete_frame_bytes 1_048_576
  @max_tool_argument_bytes 1_048_576
  @max_tool_calls 128

  @type terminal_failure :: StreamProtocol.terminal_failure()
  @type state :: map()

  @spec max_incomplete_frame_bytes() :: pos_integer()
  def max_incomplete_frame_bytes, do: @max_incomplete_frame_bytes

  @spec max_tool_argument_bytes() :: pos_integer()
  def max_tool_argument_bytes, do: @max_tool_argument_bytes

  @spec new(map()) :: state()
  def new(formatting) when is_map(formatting) do
    %{
      buffer: "",
      think?: Map.get(formatting, :think?, false) == true,
      stops: normalized_stops(Map.get(formatting, :stops, [])),
      pending_text: "",
      stop_sequence: nil,
      visible_seen?: false,
      message_started?: false,
      message_id: local_id("msg_"),
      thinking_signature: local_id("sig_"),
      active_block: nil,
      active_index: nil,
      next_index: 0,
      tool_arguments: %{},
      tool_order: [],
      tool_argument_bytes: 0,
      tool_used?: false,
      terminal_seen?: false,
      terminal_kind: nil,
      terminal_failure: nil
    }
  end

  @spec normalize_data(binary(), state()) :: {binary(), state()}
  def normalize_data(_data, %{terminal_seen?: true} = state), do: {"", state}

  def normalize_data(data, %{buffer: buffer} = state) when is_binary(data) do
    buffered_size = byte_size(buffer) + byte_size(data)
    {blocks, residue} = StreamProtocol.complete_sse_blocks(buffer, data, bounded?: false)
    {output, state} = normalize_blocks(blocks, %{state | buffer: ""})

    cond do
      state.terminal_seen? ->
        {output, state}

      byte_size(residue) > @max_incomplete_frame_bytes ->
        BufferTelemetry.record_oversized_incomplete(
          "anthropic_sse",
          buffered_size,
          @max_incomplete_frame_bytes
        )

        {failure, state} = fail(state, "anthropic_stream_frame_too_large")
        {output <> failure, state}

      true ->
        {output, %{state | buffer: residue}}
    end
  end

  def normalize_data(_data, state), do: {"", state}

  @spec visible_seen?(state()) :: boolean()
  def visible_seen?(%{visible_seen?: visible?}), do: visible? == true

  @spec terminal_outcome(state()) ::
          :completed | :incomplete | {:failed, terminal_failure()} | nil
  def terminal_outcome(%{terminal_kind: :failed, terminal_failure: failure}),
    do: {:failed, failure}

  def terminal_outcome(%{terminal_kind: kind}) when kind in [:completed, :incomplete], do: kind
  def terminal_outcome(_state), do: nil

  @spec synthetic_terminal_failure(state()) :: {binary() | nil, state()}
  def synthetic_terminal_failure(%{terminal_seen?: true} = state), do: {nil, state}

  def synthetic_terminal_failure(state),
    do: fail(state, "anthropic_stream_interrupted")

  defp normalize_blocks(blocks, state) do
    Enum.reduce_while(blocks, {[], state}, fn block, {output, state} ->
      {data, state} = normalize_block(block, state)
      output = [output, data]

      if state.terminal_seen?,
        do: {:halt, {output, %{state | buffer: ""}}},
        else: {:cont, {output, state}}
    end)
    |> then(fn {output, state} -> {IO.iodata_to_binary(output), state} end)
  end

  defp normalize_block("data: [DONE]", state), do: {"", state}

  defp normalize_block(block, state) do
    event_type =
      block
      |> StreamProtocol.sse_field("event")
      |> StreamProtocol.normalize_sse_event_label()

    decoded = block |> StreamProtocol.sse_field("data") |> StreamProtocol.decode_sse_data()
    data_type = decoded_string(decoded, "type")

    if event_types_agree?(event_type, data_type) do
      normalize_event(event_type || data_type, decoded, state)
    else
      {"", state}
    end
  end

  defp normalize_event("response.output_text.delta", decoded, state) do
    delta = decoded_string(decoded, "delta") || ""
    {visible, state} = consume_visible_text(delta, state)
    emit_text(visible, state)
  end

  defp normalize_event(type, decoded, %{think?: true} = state)
       when type in [
              "response.reasoning_summary_text.delta",
              "response.reasoning_summary.delta"
            ] do
    emit_thinking(decoded_string(decoded, "delta") || "", state)
  end

  defp normalize_event(type, _decoded, %{think?: false} = state)
       when type in [
              "response.reasoning_summary_text.delta",
              "response.reasoning_summary.delta"
            ],
       do: {"", state}

  defp normalize_event("response.output_item.added", decoded, state),
    do: register_tool(decoded, state)

  defp normalize_event("response.function_call_arguments.delta", decoded, state),
    do: append_tool_arguments(decoded, state)

  defp normalize_event("response.function_call_arguments.done", decoded, state),
    do: finish_tool(decoded, state)

  defp normalize_event("response.output_item.done", decoded, state) do
    case Map.get(decoded, "item") do
      %{"type" => "function_call"} -> finish_tool(decoded, state)
      _item -> {"", state}
    end
  end

  defp normalize_event(type, decoded, state)
       when type in ["response.completed", "response.incomplete", "response.failed", "error"] do
    normalize_terminal(type, decoded, state)
  end

  defp normalize_event(_type, _decoded, state), do: {"", state}

  defp consume_visible_text(_delta, %{stop_sequence: stop} = state) when is_binary(stop),
    do: {"", state}

  defp consume_visible_text("", state), do: {"", state}
  defp consume_visible_text(delta, %{stops: []} = state), do: {delta, state}

  defp consume_visible_text(delta, state) do
    combined = state.pending_text <> delta

    case earliest_stop(combined, state.stops) do
      {index, stop} ->
        {binary_part(combined, 0, index), %{state | pending_text: "", stop_sequence: stop}}

      nil ->
        retained_bytes = longest_stop_prefix_suffix_bytes(combined, state.stops)
        emitted_bytes = byte_size(combined) - retained_bytes
        visible = binary_part(combined, 0, emitted_bytes)
        pending = binary_part(combined, emitted_bytes, retained_bytes)
        {visible, %{state | pending_text: pending}}
    end
  end

  defp flush_pending_text(%{stop_sequence: stop} = state) when is_binary(stop), do: {"", state}
  defp flush_pending_text(%{pending_text: ""} = state), do: {"", state}

  defp flush_pending_text(state),
    do: {state.pending_text, %{state | pending_text: ""}}

  defp emit_text("", state), do: {"", state}

  defp emit_text(text, state) do
    {prefix, state} = ensure_block(:text, state)

    delta = %{
      "type" => "content_block_delta",
      "index" => state.active_index,
      "delta" => %{"type" => "text_delta", "text" => text}
    }

    {prefix <> sse("content_block_delta", delta), mark_visible(state)}
  end

  defp emit_thinking("", state), do: {"", state}

  defp emit_thinking(summary, state) do
    {prefix, state} = ensure_block(:thinking, state)

    delta = %{
      "type" => "content_block_delta",
      "index" => state.active_index,
      "delta" => %{"type" => "thinking_delta", "thinking" => summary}
    }

    {prefix <> sse("content_block_delta", delta), mark_visible(state)}
  end

  defp ensure_block(kind, %{active_block: kind} = state), do: {"", state}

  defp ensure_block(kind, state) when kind in [:thinking, :text] do
    {closed, state} = close_active_block(state)
    {started, state} = ensure_message_started(state)
    index = state.next_index

    content_block =
      case kind do
        :thinking -> %{"type" => "thinking", "thinking" => "", "signature" => ""}
        :text -> %{"type" => "text", "text" => ""}
      end

    start = %{
      "type" => "content_block_start",
      "index" => index,
      "content_block" => content_block
    }

    data = IO.iodata_to_binary([closed, started, sse("content_block_start", start)])

    {data,
     %{
       state
       | active_block: kind,
         active_index: index,
         next_index: index + 1,
         visible_seen?: true
     }}
  end

  defp close_active_block(%{active_block: nil} = state), do: {"", state}

  defp close_active_block(%{active_block: :thinking, active_index: index} = state) do
    signature = %{
      "type" => "content_block_delta",
      "index" => index,
      "delta" => %{
        "type" => "signature_delta",
        "signature" => state.thinking_signature
      }
    }

    stop = %{"type" => "content_block_stop", "index" => index}

    {IO.iodata_to_binary([
       sse("content_block_delta", signature),
       sse("content_block_stop", stop)
     ]), %{state | active_block: nil, active_index: nil}}
  end

  defp close_active_block(%{active_block: :text, active_index: index} = state) do
    stop = %{"type" => "content_block_stop", "index" => index}
    {sse("content_block_stop", stop), %{state | active_block: nil, active_index: nil}}
  end

  defp ensure_message_started(%{message_started?: true} = state), do: {"", state}

  defp ensure_message_started(state) do
    message = %{
      "id" => state.message_id,
      "type" => "message",
      "role" => "assistant",
      "model" => Facade.public_model(),
      "content" => [],
      "stop_reason" => nil,
      "stop_sequence" => nil,
      "usage" => Response.zero_usage()
    }

    payload = %{"type" => "message_start", "message" => message}

    {sse("message_start", payload), %{state | message_started?: true, visible_seen?: true}}
  end

  defp register_tool(decoded, state) do
    case Map.get(decoded, "item") do
      %{"type" => "function_call"} = item ->
        key = tool_key(decoded, item)
        name = decoded_string(item, "name") || "tool"
        arguments = decoded_string(item, "arguments") || ""
        put_tool(state, key, name, arguments)

      _item ->
        {"", state}
    end
  end

  defp append_tool_arguments(decoded, state) do
    key = tool_key(decoded, %{})
    delta = decoded_string(decoded, "delta") || ""

    existing =
      Map.get(state.tool_arguments, key, new_tool(decoded_string(decoded, "name") || "tool"))

    if existing.emitted? do
      {"", state}
    else
      append_tool_chunk(state, key, existing, delta)
    end
  end

  defp finish_tool(decoded, state) do
    item = Map.get(decoded, "item", %{})
    key = tool_key(decoded, item)
    existing = Map.get(state.tool_arguments, key, new_tool("tool"))

    if existing.emitted? do
      {"", state}
    else
      name = decoded_string(item, "name") || decoded_string(decoded, "name") || existing.name

      final_arguments =
        decoded_string(decoded, "arguments") || decoded_string(item, "arguments")

      result =
        if is_binary(final_arguments) do
          replace_tool_source(state, key, existing, name, final_arguments)
        else
          ensure_tool_registered(state, key, %{existing | name: safe_tool_name(name)})
        end

      case result do
        {:ok, state, tool} -> emit_tool(key, tool, state)
        {:error, state, code} -> fail(state, code)
      end
    end
  end

  defp put_tool(state, key, name, arguments) do
    existing = Map.get(state.tool_arguments, key, new_tool(name))

    case replace_tool_source(state, key, existing, name, arguments) do
      {:ok, state, _tool} -> {"", state}
      {:error, state, code} -> fail(state, code)
    end
  end

  defp append_tool_chunk(state, key, existing, ""),
    do: ensure_tool_registered(state, key, existing) |> empty_tool_result()

  defp append_tool_chunk(state, key, existing, delta) when is_binary(delta) do
    next_bytes = state.tool_argument_bytes + byte_size(delta)

    cond do
      next_bytes > @max_tool_argument_bytes ->
        record_oversized_tool(next_bytes)
        fail(state, "anthropic_tool_arguments_too_large")

      not Map.has_key?(state.tool_arguments, key) and
          map_size(state.tool_arguments) >= @max_tool_calls ->
        fail(state, "anthropic_tool_call_limit_exceeded")

      true ->
        tool = %{
          existing
          | argument_chunks: [delta | existing.argument_chunks],
            argument_bytes: existing.argument_bytes + byte_size(delta)
        }

        state = put_registered_tool(state, key, tool, next_bytes)
        {"", state}
    end
  end

  defp replace_tool_source(state, key, existing, name, arguments)
       when is_binary(arguments) and is_binary(name) do
    next_bytes = state.tool_argument_bytes - existing.argument_bytes + byte_size(arguments)

    cond do
      next_bytes > @max_tool_argument_bytes ->
        record_oversized_tool(next_bytes)
        {:error, state, "anthropic_tool_arguments_too_large"}

      not Map.has_key?(state.tool_arguments, key) and
          map_size(state.tool_arguments) >= @max_tool_calls ->
        {:error, state, "anthropic_tool_call_limit_exceeded"}

      true ->
        chunks = if arguments == "", do: [], else: [arguments]

        tool = %{
          existing
          | name: safe_tool_name(name),
            argument_chunks: chunks,
            argument_bytes: byte_size(arguments)
        }

        {:ok, put_registered_tool(state, key, tool, next_bytes), tool}
    end
  end

  defp ensure_tool_registered(state, key, tool) do
    cond do
      Map.has_key?(state.tool_arguments, key) ->
        {:ok, state, tool}

      map_size(state.tool_arguments) >= @max_tool_calls ->
        {:error, state, "anthropic_tool_call_limit_exceeded"}

      true ->
        {:ok, put_registered_tool(state, key, tool, state.tool_argument_bytes), tool}
    end
  end

  defp empty_tool_result({:ok, state, _tool}), do: {"", state}
  defp empty_tool_result({:error, state, code}), do: fail(state, code)

  defp put_registered_tool(state, key, tool, total_bytes) do
    new? = not Map.has_key?(state.tool_arguments, key)

    %{
      state
      | tool_arguments: Map.put(state.tool_arguments, key, tool),
        tool_order: if(new?, do: state.tool_order ++ [key], else: state.tool_order),
        tool_argument_bytes: total_bytes
    }
  end

  defp emit_tool(key, tool, state) do
    {closed, state} = close_active_block(state)
    {started, state} = ensure_message_started(state)
    index = state.next_index

    start = %{
      "type" => "content_block_start",
      "index" => index,
      "content_block" => %{
        "type" => "tool_use",
        "id" => tool.local_id,
        "name" => safe_tool_name(tool.name),
        "input" => %{}
      }
    }

    delta = %{
      "type" => "content_block_delta",
      "index" => index,
      "delta" => %{
        "type" => "input_json_delta",
        "partial_json" => safe_partial_json(tool_source(tool))
      }
    }

    stop = %{"type" => "content_block_stop", "index" => index}
    emitted = %{tool | argument_chunks: [], argument_bytes: 0, emitted?: true}

    state = %{
      state
      | tool_arguments: Map.put(state.tool_arguments, key, emitted),
        tool_argument_bytes: state.tool_argument_bytes - tool.argument_bytes,
        next_index: index + 1,
        tool_used?: true,
        visible_seen?: true
    }

    {IO.iodata_to_binary([
       closed,
       started,
       sse("content_block_start", start),
       sse("content_block_delta", delta),
       sse("content_block_stop", stop)
     ]), state}
  end

  defp flush_tools(state) do
    Enum.reduce_while(state.tool_order, {[], state}, fn key, {output, state} ->
      case Map.get(state.tool_arguments, key) do
        %{emitted?: false} = tool ->
          {data, state} = emit_tool(key, tool, state)

          if state.terminal_seen?,
            do: {:halt, {[output, data], state}},
            else: {:cont, {[output, data], state}}

        _tool ->
          {:cont, {output, state}}
      end
    end)
    |> then(fn {output, state} -> {IO.iodata_to_binary(output), state} end)
  end

  defp normalize_terminal(type, decoded, state) do
    case StreamProtocol.terminal_outcome(type, decoded) do
      {:ok, %{kind: kind}} when kind in [:completed, :incomplete] ->
        {pending, state} = flush_pending_text(state)
        {visible, state} = emit_text(pending, state)
        {tools, state} = flush_tools(state)
        {closed, state} = close_active_block(state)
        {started, state} = ensure_message_started(state)
        response = response_map(decoded)

        delta = %{
          "type" => "message_delta",
          "delta" => %{
            "stop_reason" => stop_reason(kind, response, state),
            "stop_sequence" => state.stop_sequence
          },
          "usage" => Response.safe_usage(response)
        }

        stop = %{"type" => "message_stop"}

        output =
          IO.iodata_to_binary([
            visible,
            tools,
            closed,
            started,
            sse("message_delta", delta),
            sse("message_stop", stop)
          ])

        {output, terminal_state(state, kind, nil)}

      {:ok, %{kind: :failed, failure: failure}} ->
        {error_sse(), terminal_state(state, :failed, failure)}

      _outcome ->
        fail(state, "anthropic_upstream_terminal_invalid")
    end
  end

  defp terminal_state(state, kind, failure) do
    %{
      state
      | buffer: "",
        pending_text: "",
        active_block: nil,
        active_index: nil,
        tool_arguments: %{},
        tool_order: [],
        tool_argument_bytes: 0,
        terminal_seen?: true,
        terminal_kind: kind,
        terminal_failure: failure
    }
  end

  defp fail(state, code) do
    failure = %{
      code: code,
      upstream_code: nil,
      upstream_error_param: nil,
      event_type: "error",
      data_type: "error"
    }

    {error_sse(), terminal_state(state, :failed, failure)}
  end

  defp error_sse do
    sse("error", %{
      "type" => "error",
      "error" => %{"type" => "api_error", "message" => "request failed"}
    })
  end

  defp stop_reason(_kind, _response, %{stop_sequence: stop}) when is_binary(stop),
    do: "stop_sequence"

  defp stop_reason(_kind, _response, %{tool_used?: true}), do: "tool_use"

  defp stop_reason(:incomplete, %{"incomplete_details" => %{"reason" => reason}}, _state)
       when reason in ["max_output_tokens", "max_tokens"],
       do: "max_tokens"

  defp stop_reason(:incomplete, _response, _state), do: "max_tokens"
  defp stop_reason(_kind, _response, _state), do: "end_turn"

  defp response_map(%{"response" => %{} = response}), do: response
  defp response_map(%{} = decoded), do: decoded

  defp tool_key(decoded, item) do
    decoded_string(decoded, "item_id") || decoded_string(item, "id") ||
      "output:" <> to_string(Map.get(decoded, "output_index", Map.get(item, "output_index", 0)))
  end

  defp new_tool(name) do
    %{
      name: safe_tool_name(name),
      argument_chunks: [],
      argument_bytes: 0,
      local_id: local_id("toolu_"),
      emitted?: false
    }
  end

  defp tool_source(%{argument_chunks: chunks}),
    do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp safe_partial_json(arguments) do
    case Jason.decode(arguments) do
      {:ok, %{} = decoded} -> Jason.encode!(decoded)
      _invalid -> "{}"
    end
  end

  defp safe_tool_name(name) when is_binary(name) do
    name = String.trim(name)

    if name != "" and byte_size(name) <= 256 and String.printable?(name),
      do: name,
      else: "tool"
  end

  defp record_oversized_tool(bytes) do
    BufferTelemetry.record_oversized_incomplete(
      "anthropic_tool_arguments",
      bytes,
      @max_tool_argument_bytes
    )
  end

  defp earliest_stop(text, stops) do
    stops
    |> Enum.flat_map(fn stop ->
      case :binary.match(text, stop) do
        {index, _length} -> [{index, stop}]
        :nomatch -> []
      end
    end)
    |> Enum.min_by(fn {index, stop} -> {index, -byte_size(stop)} end, fn -> nil end)
  end

  defp longest_stop_prefix_suffix_bytes(text, stops) do
    max_bytes = stops |> Enum.map(&byte_size/1) |> Enum.max(fn -> 0 end)
    limit = min(byte_size(text), max(max_bytes - 1, 0))

    limit..0//-1
    |> Enum.find(fn size ->
      suffix = binary_part(text, byte_size(text) - size, size)
      Enum.any?(stops, &String.starts_with?(&1, suffix))
    end)
    |> Kernel.||(0)
  end

  defp normalized_stops(stops) when is_list(stops),
    do: Enum.filter(stops, &(is_binary(&1) and &1 != ""))

  defp normalized_stops(_stops), do: []

  defp event_types_agree?(event_type, data_type)
       when is_binary(event_type) and is_binary(data_type),
       do: event_type == data_type

  defp event_types_agree?(_event_type, _data_type), do: true

  defp decoded_string(decoded, key) when is_map(decoded) do
    case Map.get(decoded, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp decoded_string(_decoded, _key), do: nil

  defp mark_visible(state), do: %{state | visible_seen?: true}

  defp local_id(prefix),
    do: prefix <> (Ecto.UUID.generate() |> String.replace("-", ""))

  defp sse(event, payload),
    do: "event: " <> event <> "\n" <> "data: " <> Jason.encode!(payload) <> "\n\n"
end
