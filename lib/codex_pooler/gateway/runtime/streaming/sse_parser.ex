defmodule CodexPooler.Gateway.Runtime.Streaming.SSEParser do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @event_prefix "event:"
  @type direct_gate :: :chunk_newline | :event_prefix | :json_closing_brace
  @type line_match :: nil | :event_line | :other_line | {:event_prefix, 1..5}
  @type state :: %{
          required(:block_state) => StreamProtocol.sse_block_state(),
          required(:residue_empty?) => boolean(),
          required(:blocks_seen) => non_neg_integer(),
          required(:matched) => line_match() | {:ok, map()},
          required(:line_skip_leading_lf?) => boolean()
        }

  @spec new_state() :: state()
  def new_state do
    %{
      block_state: StreamProtocol.new_sse_block_state(),
      residue_empty?: true,
      blocks_seen: 0,
      matched: nil,
      line_skip_leading_lf?: false
    }
  end

  @spec complete_blocks(state(), binary(), binary()) :: {[binary()], state(), boolean()}
  def complete_blocks(state, _buffer, data) when is_binary(data) do
    {line_data, pending_line_skip?} =
      consume_optional_leading_lf(data, state.line_skip_leading_lf?)

    {line_match, line_break?, trailing_line_skip?} =
      advance_event_line(state.matched, line_data)

    {blocks, block_state} =
      StreamProtocol.complete_sse_blocks(state.block_state, data, bounded?: false)

    state = %{
      state
      | block_state: block_state,
        residue_empty?: block_state.buffer == "",
        blocks_seen: state.blocks_seen + block_count(blocks),
        matched: line_match,
        line_skip_leading_lf?: pending_line_skip? or trailing_line_skip?
    }

    {blocks, state, line_break?}
  end

  defp consume_optional_leading_lf("", true), do: {"", true}
  defp consume_optional_leading_lf(<<"\n", rest::binary>>, true), do: {rest, false}
  defp consume_optional_leading_lf(data, true), do: {data, false}
  defp consume_optional_leading_lf(data, false), do: {data, false}

  @spec direct_rescan?(state(), binary(), boolean(), [direct_gate()]) :: boolean()
  def direct_rescan?(
        state,
        data,
        newline?,
        gates \\ [:chunk_newline, :event_prefix, :json_closing_brace]
      )
      when is_map(state) and is_binary(data) and is_boolean(newline?) and is_list(gates) do
    (:chunk_newline in gates and newline?) or
      (:event_prefix in gates and possible_event_line?(state.matched)) or
      (:json_closing_brace in gates and closing_json_object_tail?(data))
  end

  defp block_count([]), do: 0
  defp block_count(blocks), do: length(blocks)

  defp possible_event_line?({:event_prefix, _length}), do: true
  defp possible_event_line?(:event_line), do: true
  defp possible_event_line?(_matched), do: false

  defp closing_json_object_tail?(data) do
    case data do
      <<>> -> false
      _data -> closing_json_object_tail?(data, byte_size(data) - 1)
    end
  end

  defp closing_json_object_tail?(data, index) when index >= 0 do
    case :binary.at(data, index) do
      ?} -> true
      byte when byte in [9, 10, 11, 12, 13, 32] -> closing_json_object_tail?(data, index - 1)
      byte when byte >= 128 -> String.ends_with?(String.trim_trailing(data), "}")
      _byte -> false
    end
  end

  defp closing_json_object_tail?(_data, _index), do: false

  defp advance_event_line({:ok, _event} = matched, _data), do: {matched, false, false}

  defp advance_event_line(matched, data) do
    consume_event_line(data, matched, false)
  end

  defp consume_event_line("", matched, newline?), do: {matched, newline?, false}

  defp consume_event_line(data, matched, newline?) when matched in [:event_line, :other_line] do
    case :binary.match(data, ["\r", "\n"]) do
      :nomatch ->
        {matched, newline?, false}

      {index, 1} ->
        {rest, trailing_cr?} = rest_after_line_ending(data, index)

        case rest do
          "" -> {nil, true, trailing_cr?}
          _rest -> consume_event_line(rest, nil, true)
        end
    end
  end

  defp consume_event_line(<<"\n", rest::binary>>, _matched, _newline?),
    do: consume_event_line(rest, nil, true)

  defp consume_event_line(<<"\r\n", rest::binary>>, _matched, _newline?),
    do: consume_event_line(rest, nil, true)

  defp consume_event_line(<<"\r">>, _matched, _newline?), do: {nil, true, true}

  defp consume_event_line(<<"\r", rest::binary>>, _matched, _newline?),
    do: consume_event_line(rest, nil, true)

  defp consume_event_line(<<byte, rest::binary>>, nil, newline?) when byte in [32, 9],
    do: consume_event_line(rest, nil, newline?)

  defp consume_event_line(<<byte, rest::binary>>, nil, newline?),
    do: consume_event_prefix(byte, rest, 0, newline?)

  defp consume_event_line(<<byte, rest::binary>>, {:event_prefix, length}, newline?),
    do: consume_event_prefix(byte, rest, length, newline?)

  defp consume_event_prefix(byte, rest, length, newline?) do
    if byte == :binary.at(@event_prefix, length) do
      next_length = length + 1

      if next_length == byte_size(@event_prefix),
        do: consume_event_line(rest, :event_line, newline?),
        else: consume_event_line(rest, {:event_prefix, next_length}, newline?)
    else
      consume_event_line(rest, :other_line, newline?)
    end
  end

  defp rest_after_line_ending(data, line_ending_index) do
    trailing_cr? =
      :binary.at(data, line_ending_index) == ?\r and line_ending_index + 1 == byte_size(data)

    offset =
      if :binary.at(data, line_ending_index) == ?\r and
           line_ending_index + 1 < byte_size(data) and
           :binary.at(data, line_ending_index + 1) == ?\n,
         do: line_ending_index + 2,
         else: line_ending_index + 1

    {binary_part(data, offset, byte_size(data) - offset), trailing_cr?}
  end
end
