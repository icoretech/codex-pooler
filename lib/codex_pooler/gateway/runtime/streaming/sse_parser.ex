defmodule CodexPooler.Gateway.Runtime.Streaming.SSEParser do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @event_prefix "event:"
  @type direct_gate :: :chunk_newline | :event_prefix | :json_closing_brace
  @type line_match :: nil | :event_line | :other_line | {:event_prefix, 1..5}
  @type state :: %{
          required(:residue_empty?) => boolean(),
          required(:residue_chunks) => [binary()],
          required(:pending_bytes) => non_neg_integer(),
          required(:residue_tail) => byte() | nil,
          required(:blocks_seen) => non_neg_integer(),
          required(:matched) => line_match() | {:ok, map()}
        }

  @spec new_state() :: state()
  def new_state do
    %{
      residue_empty?: true,
      residue_chunks: [],
      pending_bytes: 0,
      residue_tail: nil,
      blocks_seen: 0,
      matched: nil
    }
  end

  @spec complete_blocks(state(), binary(), binary()) :: {[binary()], state(), boolean()}
  def complete_blocks(%{matched: matched} = state, buffer, data)
      when matched in [:event_line, :other_line] and is_binary(data) do
    case :binary.match(data, ["\r", "\n"]) do
      :nomatch -> retain_separator_free_data(state, data)
      {_index, 1} -> complete_blocks_with_scan(state, data, buffer)
    end
  end

  def complete_blocks(state, buffer, data) when is_binary(buffer) and is_binary(data) do
    complete_blocks_with_scan(state, data, buffer)
  end

  defp retain_separator_free_data(state, data) do
    {blocks, residue_chunks, pending_bytes, residue_tail} = retain_without_scan(state, data)

    state = %{
      state
      | residue_empty?: residue_chunks == [] and pending_bytes == 0,
        residue_chunks: residue_chunks,
        pending_bytes: pending_bytes,
        residue_tail: residue_tail
    }

    {blocks, state, false}
  end

  defp complete_blocks_with_scan(state, data, buffer) do
    {line_match, newline?} = advance_event_line(state.matched, data)
    line_break? = newline? or :binary.match(data, "\r") != :nomatch

    {blocks, residue_chunks, pending_bytes, residue_tail} = advance_blocks(state, buffer, data)

    state = %{
      state
      | residue_empty?: residue_chunks == [] and pending_bytes == 0,
        residue_chunks: residue_chunks,
        pending_bytes: pending_bytes,
        residue_tail: residue_tail,
        blocks_seen: state.blocks_seen + block_count(blocks),
        matched: line_match
    }

    {blocks, state, line_break?}
  end

  defp advance_blocks(state, buffer, data) do
    if separator_scan_required?(state.residue_tail, data) do
      pending_bytes = state.pending_bytes + byte_size(data)
      pending = pending_binary(buffer, pending_bytes)
      combined = combine_residue(state.residue_chunks, pending)
      {blocks, residue} = StreamProtocol.complete_sse_blocks(combined, bounded?: false)
      {blocks, residue_chunks(residue), 0, binary_tail(residue)}
    else
      retain_without_scan(state, data)
    end
  end

  defp retain_without_scan(state, "") do
    {[], state.residue_chunks, state.pending_bytes, state.residue_tail}
  end

  defp retain_without_scan(state, data) do
    {[], state.residue_chunks, state.pending_bytes + byte_size(data), binary_tail(data)}
  end

  defp pending_binary(buffer, pending_bytes) when pending_bytes == byte_size(buffer), do: buffer

  defp pending_binary(buffer, pending_bytes) do
    binary_part(buffer, byte_size(buffer) - pending_bytes, pending_bytes)
  end

  defp combine_residue([], pending), do: pending
  defp combine_residue(chunks, pending), do: IO.iodata_to_binary([Enum.reverse(chunks), pending])

  defp separator_scan_required?(residue_tail, data) do
    residue_tail == ?\r or
      (residue_tail == ?\n and String.starts_with?(data, "\n")) or
      String.contains?(data, ["\r", "\n\n"])
  end

  defp residue_chunks(""), do: []
  defp residue_chunks(residue), do: [:binary.copy(residue)]

  defp binary_tail(""), do: nil
  defp binary_tail(data), do: :binary.at(data, byte_size(data) - 1)

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

  defp advance_event_line({:ok, _event} = matched, _data), do: {matched, false}

  defp advance_event_line(matched, data) do
    consume_event_line(data, matched, false)
  end

  defp consume_event_line("", matched, newline?), do: {matched, newline?}

  defp consume_event_line(data, matched, newline?) when matched in [:event_line, :other_line] do
    case :binary.match(data, "\n") do
      :nomatch -> {matched, newline?}
      {index, 1} -> consume_event_line(rest_after(data, index), nil, true)
    end
  end

  defp consume_event_line(<<"\n", rest::binary>>, _matched, _newline?),
    do: consume_event_line(rest, nil, true)

  defp consume_event_line(<<byte, rest::binary>>, nil, newline?) when byte in [32, 9, 13],
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

  defp rest_after(data, newline_index) do
    offset = newline_index + 1
    binary_part(data, offset, byte_size(data) - offset)
  end
end
