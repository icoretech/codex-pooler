defmodule CodexPooler.Gateway.Facade.Ollama.Stream do
  @moduledoc """
  Incrementally projects canonical Responses SSE into native Ollama NDJSON.

  The parser retains at most one incomplete SSE block and a globally bounded
  set of tool arguments. Provider identifiers are used only as transient map
  keys and are never copied into emitted objects.
  """

  alias CodexPooler.Gateway.Facade
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @max_incomplete_frame_bytes 1_048_576
  @max_tool_argument_bytes 1_048_576
  @max_tool_calls 128
  @terminal_error ~s({"error":"request failed","done":true}\n)

  @type surface :: :chat | :generate
  @type terminal_failure :: StreamProtocol.terminal_failure()
  @type state :: %{
          required(:buffer) => binary(),
          required(:surface) => surface(),
          required(:think?) => boolean(),
          required(:stops) => [String.t()],
          required(:pending_text) => binary(),
          required(:stop_matched?) => boolean(),
          required(:visible_seen?) => boolean(),
          required(:terminal_seen?) => boolean(),
          required(:terminal_kind) => :completed | :incomplete | :failed | nil,
          required(:terminal_failure) => terminal_failure() | nil,
          required(:tool_arguments) => map(),
          required(:tool_argument_bytes) => non_neg_integer(),
          required(:started_at) => integer(),
          required(:created_at) => String.t()
        }

  @spec max_incomplete_frame_bytes() :: pos_integer()
  def max_incomplete_frame_bytes, do: @max_incomplete_frame_bytes

  @spec max_tool_argument_bytes() :: pos_integer()
  def max_tool_argument_bytes, do: @max_tool_argument_bytes

  @spec new(map()) :: state()
  def new(%{surface: surface} = formatting) when surface in [:chat, :generate] do
    %{
      buffer: "",
      surface: surface,
      think?: Map.get(formatting, :think?, false) == true,
      stops: normalized_stops(Map.get(formatting, :stops, [])),
      pending_text: "",
      stop_matched?: false,
      visible_seen?: false,
      terminal_seen?: false,
      terminal_kind: nil,
      terminal_failure: nil,
      tool_arguments: %{},
      tool_argument_bytes: 0,
      started_at: Map.get(formatting, :started_at, System.monotonic_time()),
      created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
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
          "ollama_sse",
          buffered_size,
          @max_incomplete_frame_bytes
        )

        {failure, state} = fail(state, "ollama_stream_frame_too_large")
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

  def synthetic_terminal_failure(state) do
    fail(state, "ollama_stream_interrupted")
  end

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

  defp normalize_event("response.output_item.added", decoded, state) do
    register_tool(decoded, state)
  end

  defp normalize_event("response.function_call_arguments.delta", decoded, state) do
    append_tool_arguments(decoded, state)
  end

  defp normalize_event("response.function_call_arguments.done", decoded, state) do
    finish_tool(decoded, state)
  end

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

  defp consume_visible_text(_delta, %{stop_matched?: true} = state), do: {"", state}
  defp consume_visible_text("", state), do: {"", state}

  defp consume_visible_text(delta, %{stops: []} = state),
    do: {delta, state}

  defp consume_visible_text(delta, state) do
    combined = state.pending_text <> delta

    case earliest_stop(combined, state.stops) do
      {index, _stop} ->
        {binary_part(combined, 0, index), %{state | pending_text: "", stop_matched?: true}}

      nil ->
        retained_bytes = longest_stop_prefix_suffix_bytes(combined, state.stops)
        emitted_bytes = byte_size(combined) - retained_bytes
        visible = binary_part(combined, 0, emitted_bytes)
        pending = binary_part(combined, emitted_bytes, retained_bytes)
        {visible, %{state | pending_text: pending}}
    end
  end

  defp flush_pending_text(%{stop_matched?: true} = state), do: {"", state}
  defp flush_pending_text(%{pending_text: ""} = state), do: {"", state}

  defp flush_pending_text(state) do
    {state.pending_text, %{state | pending_text: ""}}
  end

  defp emit_text("", state), do: {"", state}

  defp emit_text(text, state) do
    payload =
      case state.surface do
        :chat ->
          stream_base(state)
          |> Map.put("message", %{"role" => "assistant", "content" => text})

        :generate ->
          stream_base(state)
          |> Map.put("response", text)
      end

    {ndjson(payload), mark_visible(state)}
  end

  defp emit_thinking("", state), do: {"", state}

  defp emit_thinking(summary, state) do
    payload =
      case state.surface do
        :chat ->
          stream_base(state)
          |> Map.put("message", %{
            "role" => "assistant",
            "content" => "",
            "thinking" => summary
          })

        :generate ->
          stream_base(state)
          |> Map.put("response", "")
          |> Map.put("thinking", summary)
      end

    {ndjson(payload), mark_visible(state)}
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
    tool = Map.get(state.tool_arguments, key, new_tool(decoded_string(decoded, "name") || "tool"))

    if tool.emitted? do
      {"", state}
    else
      put_tool(state, key, tool.name, tool.arguments <> delta, tool)
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

      arguments =
        decoded_string(decoded, "arguments") || decoded_string(item, "arguments") ||
          existing.arguments

      with {:ok, state, tool} <- replace_tool(state, key, name, arguments, existing) do
        emit_tool(key, tool, state)
      else
        {:error, state, code} -> fail(state, code)
      end
    end
  end

  defp put_tool(state, key, name, arguments, existing \\ nil) do
    existing = existing || Map.get(state.tool_arguments, key, new_tool(name))

    case replace_tool(state, key, name, arguments, existing) do
      {:ok, state, _tool} -> {"", state}
      {:error, state, code} -> fail(state, code)
    end
  end

  defp replace_tool(state, key, name, arguments, existing)
       when is_binary(arguments) and is_binary(name) do
    prior_bytes = byte_size(existing.arguments)
    next_bytes = state.tool_argument_bytes - prior_bytes + byte_size(arguments)
    new_call? = not Map.has_key?(state.tool_arguments, key)

    cond do
      next_bytes > @max_tool_argument_bytes ->
        BufferTelemetry.record_oversized_incomplete(
          "ollama_tool_arguments",
          next_bytes,
          @max_tool_argument_bytes
        )

        {:error, state, "ollama_tool_arguments_too_large"}

      new_call? and map_size(state.tool_arguments) >= @max_tool_calls ->
        {:error, state, "ollama_tool_call_limit_exceeded"}

      true ->
        tool = %{existing | name: name, arguments: arguments}

        {:ok,
         %{
           state
           | tool_arguments: Map.put(state.tool_arguments, key, tool),
             tool_argument_bytes: next_bytes
         }, tool}
    end
  end

  defp emit_tool(_key, _tool, %{surface: :generate} = state), do: {"", state}

  defp emit_tool(key, tool, state) do
    call = %{
      "id" => tool.local_id,
      "function" => %{
        "name" => tool.name,
        "arguments" => safe_arguments(tool.arguments)
      }
    }

    payload =
      stream_base(state)
      |> Map.put("message", %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [call]
      })

    tool = %{tool | arguments: "", emitted?: true}

    state = %{
      state
      | tool_arguments: Map.put(state.tool_arguments, key, tool),
        tool_argument_bytes:
          state.tool_argument_bytes - byte_size(tool_argument_source(state, key)),
        visible_seen?: true
    }

    {ndjson(payload), state}
  end

  defp normalize_terminal(type, decoded, state) do
    case StreamProtocol.terminal_outcome(type, decoded) do
      {:ok, %{kind: kind}} when kind in [:completed, :incomplete] ->
        {pending, state} = flush_pending_text(state)
        {visible, state} = emit_text(pending, state)
        terminal = terminal_line(decoded, kind, state)

        {[visible, terminal] |> IO.iodata_to_binary(),
         %{
           state
           | terminal_seen?: true,
             terminal_kind: kind,
             buffer: "",
             tool_arguments: %{},
             tool_argument_bytes: 0
         }}

      {:ok, %{kind: :failed, failure: failure}} ->
        {@terminal_error,
         %{
           state
           | terminal_seen?: true,
             terminal_kind: :failed,
             terminal_failure: failure,
             buffer: "",
             pending_text: "",
             tool_arguments: %{},
             tool_argument_bytes: 0
         }}

      _outcome ->
        fail(state, "ollama_upstream_terminal_invalid")
    end
  end

  defp terminal_line(decoded, kind, state) do
    response = response_map(decoded)
    usage = Map.get(response, "usage", %{})

    payload =
      %{
        "model" => Facade.public_model(),
        "created_at" => state.created_at,
        "done" => true,
        "done_reason" => done_reason(kind, response, state),
        "total_duration" => elapsed_nanoseconds(state.started_at),
        "load_duration" => 0,
        "prompt_eval_count" => nonnegative_integer(Map.get(usage, "input_tokens")),
        "prompt_eval_duration" => 0,
        "eval_count" => nonnegative_integer(Map.get(usage, "output_tokens")),
        "eval_duration" => 0
      }
      |> put_terminal_surface(state.surface)

    ndjson(payload)
  end

  defp fail(state, code) do
    failure = %{
      code: code,
      upstream_code: nil,
      upstream_error_param: nil,
      event_type: "error",
      data_type: "error"
    }

    {@terminal_error,
     %{
       state
       | buffer: "",
         pending_text: "",
         terminal_seen?: true,
         terminal_kind: :failed,
         terminal_failure: failure,
         tool_arguments: %{},
         tool_argument_bytes: 0
     }}
  end

  defp stream_base(state) do
    %{
      "model" => Facade.public_model(),
      "created_at" => state.created_at,
      "done" => false
    }
  end

  defp put_terminal_surface(payload, :chat),
    do: Map.put(payload, "message", %{"role" => "assistant", "content" => ""})

  defp put_terminal_surface(payload, :generate), do: Map.put(payload, "response", "")

  defp done_reason(_kind, _response, %{stop_matched?: true}), do: "stop"

  defp done_reason(:incomplete, %{"incomplete_details" => %{"reason" => reason}}, _state)
       when reason in ["max_output_tokens", "max_tokens"],
       do: "length"

  defp done_reason(:incomplete, _response, _state), do: "length"
  defp done_reason(_kind, _response, _state), do: "stop"

  defp response_map(%{"response" => %{} = response}), do: response
  defp response_map(%{} = decoded), do: decoded

  defp tool_key(decoded, item) do
    decoded_string(decoded, "item_id") || decoded_string(item, "id") ||
      "output:" <> to_string(Map.get(decoded, "output_index", Map.get(item, "output_index", 0)))
  end

  defp new_tool(name) do
    %{
      name: name,
      arguments: "",
      local_id: "call_" <> (Ecto.UUID.generate() |> String.replace("-", "")),
      emitted?: false
    }
  end

  defp tool_argument_source(state, key) do
    case Map.get(state.tool_arguments, key) do
      %{arguments: arguments} when is_binary(arguments) -> arguments
      _tool -> ""
    end
  end

  defp safe_arguments(arguments) do
    case Jason.decode(arguments) do
      {:ok, %{} = decoded} -> decoded
      _invalid -> %{}
    end
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

  defp mark_visible(state), do: %{state | visible_seen?: true}

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value), do: 0

  defp elapsed_nanoseconds(started_at) when is_integer(started_at) do
    elapsed = max(System.monotonic_time() - started_at, 0)
    System.convert_time_unit(elapsed, :native, :nanosecond)
  end

  defp ndjson(payload), do: Jason.encode!(payload) <> "\n"
end
