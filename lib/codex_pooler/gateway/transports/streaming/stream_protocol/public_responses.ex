defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.PublicResponse
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @type passthrough_terminal_state :: %{
          required(:event_type) => String.t(),
          required(:json_started?) => boolean(),
          required(:depth) => non_neg_integer(),
          required(:in_string?) => boolean(),
          required(:escaped?) => boolean(),
          required(:complete?) => boolean(),
          required(:scan_tail) => binary(),
          required(:explicit_error?) => boolean(),
          required(:incomplete_reason) => String.t() | nil,
          required(:failure_code) => String.t() | nil
        }
  @type state :: %{
          required(:buffer) => binary(),
          required(:created?) => boolean(),
          required(:text_delta?) => boolean(),
          required(:passthrough?) => boolean(),
          required(:passthrough_terminal) => passthrough_terminal_state() | nil,
          required(:passthrough_terminal_kind) => atom() | nil,
          required(:passthrough_terminal_failure) => StreamProtocol.terminal_failure() | nil,
          required(:passthrough_terminal_seen?) => boolean()
        }

  @spec new_state() :: state()
  def new_state do
    %{
      buffer: "",
      created?: false,
      text_delta?: false,
      passthrough?: false,
      passthrough_terminal: nil,
      passthrough_terminal_kind: nil,
      passthrough_terminal_failure: nil,
      passthrough_terminal_seen?: false
    }
  end

  @terminal_buffer_markers [
    "data: [DONE]",
    "response.completed",
    "response.failed",
    "response.incomplete",
    "event: error",
    ~s("type":"error"),
    ~s("type": "error")
  ]
  @passthrough_scan_tail_bytes 4_096
  @incomplete_reason_pattern ~r/"incomplete_details"\s*:\s*\{[^{}]{0,4096}"reason"\s*:\s*"([^"]+)"/
  @error_code_pattern ~r/"error"\s*:\s*\{[^{}]{0,4096}"code"\s*:\s*"([^"]+)"/
  @error_type_pattern ~r/"error"\s*:\s*\{[^{}]{0,4096}"type"\s*:\s*"([^"]+)"/
  @explicit_error_pattern ~r/"(?:error|status_details)"\s*:\s*\{/

  @spec normalize_data(binary(), state()) :: {binary(), state()}
  def normalize_data(data, %{passthrough?: true} = state) when is_binary(data) do
    normalize_passthrough_data(data, state)
  end

  def normalize_data(data, state) when is_binary(data) do
    buffered_data = state.buffer <> data
    {blocks, buffer} = StreamProtocol.complete_sse_blocks(buffered_data, bounded?: false)

    cond do
      terminal_buffer?(buffer) ->
        normalize_blocks(blocks ++ [buffer], "", state)

      blocks == [] and StreamProtocol.oversized_incomplete_sse_block?(buffer) ->
        record_oversized_incomplete(byte_size(buffered_data))
        {buffered_data, enter_passthrough(buffered_data, state)}

      StreamProtocol.oversized_incomplete_sse_block?(buffer) ->
        record_oversized_incomplete(byte_size(buffered_data))
        {iodata, state} = normalize_complete_blocks(blocks, state)
        {[iodata, buffer] |> IO.iodata_to_binary(), enter_passthrough(buffer, state)}

      true ->
        normalize_blocks(blocks, buffer, state)
    end
  end

  def normalize_data(data, state), do: {data, state}

  defp normalize_passthrough_data(data, state) do
    case sse_block_separator(data) do
      {index, separator_size} ->
        passthrough_size = index + separator_size
        passthrough = binary_part(data, 0, passthrough_size)
        rest = binary_part(data, passthrough_size, byte_size(data) - passthrough_size)

        state =
          state
          |> track_passthrough_terminal_data(passthrough)
          |> then(&%{&1 | passthrough?: false, buffer: "", passthrough_terminal: nil})

        {normalized_rest, state} = normalize_data(rest, state)

        {[passthrough, normalized_rest] |> IO.iodata_to_binary(), state}

      nil ->
        {data, track_passthrough_terminal_data(state, data)}
    end
  end

  @spec passthrough_terminal_kind(state()) :: atom() | nil
  def passthrough_terminal_kind(%{passthrough_terminal_kind: kind}) when is_atom(kind), do: kind
  def passthrough_terminal_kind(_state), do: nil

  @spec passthrough_terminal_failure(state()) :: StreamProtocol.terminal_failure() | nil
  def passthrough_terminal_failure(%{passthrough_terminal_failure: %{} = failure}), do: failure
  def passthrough_terminal_failure(_state), do: nil

  defp enter_passthrough(data, state) do
    data
    |> passthrough_terminal_event_type()
    |> case do
      event_type when is_binary(event_type) ->
        state
        |> Map.put(:passthrough_terminal, new_passthrough_terminal(event_type))
        |> track_passthrough_terminal_data(data)

      nil ->
        %{state | passthrough_terminal: nil}
    end
    |> then(&%{&1 | buffer: "", passthrough?: true})
  end

  defp new_passthrough_terminal(event_type) do
    %{
      event_type: event_type,
      json_started?: false,
      depth: 0,
      in_string?: false,
      escaped?: false,
      complete?: false,
      scan_tail: "",
      explicit_error?: false,
      incomplete_reason: nil,
      failure_code: nil
    }
  end

  defp passthrough_terminal_event_type(data) do
    {event_type, decoded} = stream_block_event(data)
    type = event_type || decoded_string(decoded, "type") || terminal_marker_type(data)

    if terminal_event?(type), do: type
  end

  defp terminal_marker_type(data) when is_binary(data) do
    cond do
      terminal_marker?(data, "response.completed") -> "response.completed"
      terminal_marker?(data, "response.failed") -> "response.failed"
      terminal_marker?(data, "response.incomplete") -> "response.incomplete"
      terminal_marker?(data, "error") -> "error"
      true -> nil
    end
  end

  defp terminal_marker?(data, type) do
    String.contains?(data, "event: #{type}") or
      String.contains?(data, "event:#{type}") or
      String.contains?(data, ~s("type":"#{type}")) or
      String.contains?(data, ~s("type": "#{type}"))
  end

  defp track_passthrough_terminal_data(
         %{passthrough_terminal: %{complete?: false} = terminal} = state,
         data
       )
       when is_binary(data) do
    terminal = scan_passthrough_terminal_json(data, terminal)

    state
    |> Map.put(:passthrough_terminal, terminal)
    |> maybe_put_passthrough_terminal_kind(terminal)
    |> Map.put(
      :passthrough_terminal_seen?,
      state.passthrough_terminal_seen? or terminal.complete?
    )
  end

  defp track_passthrough_terminal_data(state, _data), do: state

  defp maybe_put_passthrough_terminal_kind(state, %{complete?: true} = terminal) do
    case passthrough_terminal_outcome(terminal) do
      {:ok, %{kind: kind} = outcome} ->
        state
        |> Map.put(:passthrough_terminal_kind, kind)
        |> maybe_put_passthrough_terminal_failure(outcome)

      _outcome ->
        state
    end
  end

  defp maybe_put_passthrough_terminal_kind(state, _terminal), do: state

  defp maybe_put_passthrough_terminal_failure(
         state,
         %{kind: :failed, failure: %{} = failure}
       ) do
    Map.put(state, :passthrough_terminal_failure, failure)
  end

  defp maybe_put_passthrough_terminal_failure(state, _outcome), do: state

  defp passthrough_terminal_outcome(%{event_type: event_type} = terminal) do
    failure_code = terminal.failure_code

    StreamProtocol.terminal_outcome_event(%{
      event_type: event_type,
      data_type: event_type,
      error_code: StreamProtocol.client_visible_error_code(failure_code),
      upstream_error_code: failure_code,
      incomplete_reason: terminal.incomplete_reason || failure_code,
      explicit_error?: terminal.explicit_error?
    })
  end

  defp scan_passthrough_terminal_json(data, terminal) do
    terminal = track_passthrough_terminal_metadata(data, terminal)
    scan_passthrough_terminal_json(data, 0, terminal)
  end

  defp scan_passthrough_terminal_json(data, offset, terminal)
       when offset >= byte_size(data) or terminal.complete?,
       do: terminal

  defp scan_passthrough_terminal_json(data, offset, %{json_started?: false} = terminal) do
    case :binary.at(data, offset) do
      ?{ ->
        scan_passthrough_terminal_json(data, offset + 1, %{
          terminal
          | json_started?: true,
            depth: 1
        })

      _byte ->
        scan_passthrough_terminal_json(data, offset + 1, terminal)
    end
  end

  defp scan_passthrough_terminal_json(
         data,
         offset,
         %{in_string?: true, escaped?: true} = terminal
       ) do
    scan_passthrough_terminal_json(data, offset + 1, %{terminal | escaped?: false})
  end

  defp scan_passthrough_terminal_json(
         data,
         offset,
         %{in_string?: true, escaped?: false} = terminal
       ) do
    case :binary.at(data, offset) do
      ?\\ -> scan_passthrough_terminal_json(data, offset + 1, %{terminal | escaped?: true})
      ?" -> scan_passthrough_terminal_json(data, offset + 1, %{terminal | in_string?: false})
      _byte -> scan_passthrough_terminal_json(data, offset + 1, terminal)
    end
  end

  defp scan_passthrough_terminal_json(data, offset, terminal) do
    case :binary.at(data, offset) do
      ?" ->
        scan_passthrough_terminal_json(data, offset + 1, %{terminal | in_string?: true})

      ?{ ->
        scan_passthrough_terminal_json(data, offset + 1, %{
          terminal
          | depth: terminal.depth + 1
        })

      ?} when terminal.depth <= 1 ->
        %{terminal | depth: 0, complete?: true}

      ?} ->
        scan_passthrough_terminal_json(data, offset + 1, %{
          terminal
          | depth: terminal.depth - 1
        })

      _byte ->
        scan_passthrough_terminal_json(data, offset + 1, terminal)
    end
  end

  defp track_passthrough_terminal_metadata(data, terminal) when is_binary(data) do
    sample = if terminal.scan_tail == "", do: data, else: terminal.scan_tail <> data

    incomplete_reason =
      terminal.incomplete_reason || capture_pattern(@incomplete_reason_pattern, sample)

    error_code = capture_pattern(@error_code_pattern, sample)
    error_type = capture_pattern(@error_type_pattern, sample)

    %{
      terminal
      | scan_tail: scan_tail(sample),
        explicit_error?:
          terminal.explicit_error? or Regex.match?(@explicit_error_pattern, sample),
        incomplete_reason: incomplete_reason,
        failure_code: error_code || terminal.failure_code || error_type || incomplete_reason
    }
  end

  defp capture_pattern(pattern, data) do
    case Regex.run(pattern, data, capture: :all_but_first) do
      [value | _rest] when is_binary(value) and value != "" -> value
      _match -> nil
    end
  end

  defp scan_tail(data) when byte_size(data) <= @passthrough_scan_tail_bytes, do: data

  defp scan_tail(data) do
    binary_part(
      data,
      byte_size(data) - @passthrough_scan_tail_bytes,
      @passthrough_scan_tail_bytes
    )
  end

  defp record_oversized_incomplete(bytes) do
    BufferTelemetry.record_oversized_incomplete(
      "public_openai_responses_sse",
      bytes,
      StreamProtocol.max_incomplete_sse_block_bytes()
    )
  end

  defp normalize_complete_blocks(blocks, state) do
    Enum.map_reduce(blocks, state, fn block, stream_state ->
      normalize_block(block, stream_state)
    end)
  end

  defp normalize_blocks(blocks, buffer, state) do
    {iodata, state} = normalize_complete_blocks(blocks, %{state | buffer: buffer})

    state = if stream_terminal?(blocks), do: new_state(), else: state

    {IO.iodata_to_binary(iodata), state}
  end

  defp normalize_block("data: [DONE]", state), do: {[], state}

  defp normalize_block(block, state) do
    {event_type, decoded} = stream_block_event(block)
    type = event_type || decoded_string(decoded, "type")
    {type, decoded} = StreamProtocol.normalize_terminal_event(type, decoded)
    decoded = normalize_public_event(type, decoded)

    cond do
      codex_public_event?(type) ->
        {[], state}

      type == "response.created" ->
        {[public_sse_block("response.created", decoded)], %{state | created?: true}}

      type == "response.output_text.delta" ->
        {[public_sse_block("response.output_text.delta", decoded)], %{state | text_delta?: true}}

      terminal_event?(type) ->
        {prefix, state} = terminal_prefix(type, decoded, state)
        {[prefix, public_sse_block(type, decoded)], state}

      is_binary(type) ->
        {[public_sse_block(type, decoded)], state}

      true ->
        {[], state}
    end
  end

  defp terminal_prefix(type, _decoded, %{created?: false, text_delta?: false} = state)
       when type in ["response.failed", "response.incomplete", "error"],
       do: {[], state}

  defp terminal_prefix(_type, decoded, state) do
    {created_prefix, state} =
      if state.created? do
        {[], state}
      else
        response_id =
          nested_string(decoded, ["response", "id"]) || decoded_string(decoded, "id") || ""

        created = %{
          "type" => "response.created",
          "response" => %{"id" => response_id, "object" => "response", "status" => "in_progress"}
        }

        {[public_sse_block("response.created", created)], %{state | created?: true}}
      end

    {delta_prefix, state} =
      if state.text_delta? do
        {[], state}
      else
        case terminal_output_text(decoded) do
          "" ->
            {[], state}

          text ->
            delta = %{"type" => "response.output_text.delta", "delta" => text}

            {[public_sse_block("response.output_text.delta", delta)],
             %{state | text_delta?: true}}
        end
      end

    {[created_prefix, delta_prefix], state}
  end

  defp public_sse_block(event_type, decoded) when is_binary(event_type) and is_map(decoded) do
    [
      "event: ",
      event_type,
      "\n",
      "data: ",
      Jason.encode!(Map.put_new(decoded, "type", event_type)),
      "\n\n"
    ]
  end

  defp terminal_output_text(decoded) do
    response = if is_map(decoded["response"]), do: decoded["response"], else: decoded

    response
    |> Map.get("output", [])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"content" => content} -> List.wrap(content)
      %{"text" => text} when is_binary(text) -> [%{"text" => text}]
      _item -> []
    end)
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"type" => "output_text", "text" => text} when is_binary(text) -> text
      _content -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("")
  end

  defp normalize_public_event(type, %{} = decoded)
       when type in ["response.output_item.added", "response.output_item.done"] do
    case decoded do
      %{"item" => %{} = item} -> Map.put(decoded, "item", ensure_output_item_id(item, decoded))
      _event -> decoded
    end
  end

  defp normalize_public_event(type, %{} = decoded) do
    if terminal_event?(type) do
      normalize_terminal_output_items(decoded)
      |> normalize_terminal_errors()
    else
      decoded
    end
  end

  defp normalize_terminal_errors(%{} = decoded) do
    decoded
    |> normalize_top_level_error()
    |> normalize_response_error()
  end

  defp normalize_top_level_error(%{"error" => %{} = error} = decoded),
    do: Map.put(decoded, "error", normalize_terminal_error(error))

  defp normalize_top_level_error(decoded), do: decoded

  defp normalize_response_error(%{"response" => %{"error" => %{} = error} = response} = decoded) do
    Map.put(
      decoded,
      "response",
      Map.put(response, "error", normalize_terminal_error(error))
    )
  end

  defp normalize_response_error(
         %{"error" => %{} = public_error, "response" => %{} = response} = decoded
       ) do
    Map.put(decoded, "response", Map.put(response, "error", public_error))
  end

  defp normalize_response_error(decoded), do: decoded

  defp normalize_terminal_error(error) do
    PublicResponse.normalize_error(error, status: PublicResponse.terminal_error_status(error))
  end

  defp normalize_terminal_output_items(%{"response" => %{} = response} = decoded) do
    Map.put(decoded, "response", normalize_response_output_items(response))
  end

  defp normalize_terminal_output_items(%{} = decoded),
    do: normalize_response_output_items(decoded)

  defp normalize_response_output_items(%{"output" => output} = response) when is_list(output) do
    output =
      output
      |> Enum.with_index()
      |> Enum.map(fn {item, index} -> ensure_output_item_id(item, %{"output_index" => index}) end)

    Map.put(response, "output", output)
  end

  defp normalize_response_output_items(response), do: response

  defp ensure_output_item_id(%{} = item, context) do
    case clean_string(Map.get(item, "id")) || clean_string(Map.get(item, "call_id")) ||
           clean_string(Map.get(context, "item_id")) do
      nil -> Map.put(item, "id", fallback_output_item_id(item, context))
      id -> Map.put(item, "id", id)
    end
  end

  defp ensure_output_item_id(item, _context), do: item

  defp fallback_output_item_id(item, context) do
    item_type = clean_string(Map.get(item, "type")) || "item"

    case Map.get(context, "output_index") do
      index when is_integer(index) and index >= 0 -> "#{item_type}_#{index}"
      index when is_binary(index) and index != "" -> "#{item_type}_#{index}"
      _index -> item_type
    end
  end

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  @spec terminal_buffer?(binary()) :: boolean()
  defp terminal_buffer?(""), do: false

  defp terminal_buffer?(buffer) when is_binary(buffer) do
    if terminal_buffer_candidate?(buffer) do
      done_marker?(buffer) or decoded_terminal_buffer?(buffer)
    else
      false
    end
  end

  @spec terminal_buffer_candidate?(binary()) :: boolean()
  defp terminal_buffer_candidate?(buffer) do
    Enum.any?(@terminal_buffer_markers, &String.contains?(buffer, &1))
  end

  @spec done_marker?(binary()) :: boolean()
  defp done_marker?(block), do: String.trim(block) == "data: [DONE]"

  @spec decoded_terminal_buffer?(binary()) :: boolean()
  defp decoded_terminal_buffer?(buffer) do
    {event_type, decoded} = stream_block_event(buffer)

    decoded != %{} and terminal_event?(event_type || decoded_string(decoded, "type"))
  end

  defp stream_terminal?(blocks) do
    Enum.any?(blocks, fn block ->
      {event_type, decoded} = stream_block_event(block)

      terminal_event?(event_type || decoded_string(decoded, "type")) or done_marker?(block)
    end)
  end

  defp terminal_event?(type)
       when type in ["response.completed", "response.failed", "response.incomplete", "error"],
       do: true

  defp terminal_event?(_type), do: false

  defp codex_public_event?(type) when is_binary(type), do: String.starts_with?(type, "codex.")
  defp codex_public_event?(_type), do: false

  defp sse_block_separator(data) do
    ["\n\n", "\r\n\r\n"]
    |> Enum.map(fn separator -> {separator, :binary.match(data, separator)} end)
    |> Enum.flat_map(fn
      {separator, {index, _size}} -> [{index, byte_size(separator)}]
      {_separator, :nomatch} -> []
    end)
    |> Enum.min_by(fn {index, _size} -> index end, fn -> nil end)
  end

  defp stream_block_event(block) do
    data = StreamProtocol.sse_field(block, "data")

    decoded =
      if is_binary(data),
        do: StreamProtocol.decode_sse_data(data),
        else: StreamProtocol.decode_sse_data(block)

    event_type = StreamProtocol.sse_field(block, "event") || decoded_string(decoded, "type")

    {event_type, decoded}
  end

  defp decoded_string(decoded, key) when is_map(decoded) do
    case Map.get(decoded, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp nested_string(map, keys) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case acc do
        %{^key => value} -> {:cont, value}
        _other -> {:halt, nil}
      end
    end)
    |> case do
      value when is_binary(value) -> value
      _value -> nil
    end
  end
end
