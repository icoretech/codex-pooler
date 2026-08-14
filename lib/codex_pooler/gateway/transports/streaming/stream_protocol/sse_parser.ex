defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.SSEParser do
  @moduledoc false

  # Upstream Responses streams carry single non-terminal SSE events well past
  # 64 KiB (reasoning items with encrypted content scale with request context),
  # so the ordinary bound must stay comfortably above real provider event sizes.
  @max_incomplete_sse_block_bytes 8_388_608
  @max_incomplete_terminal_sse_block_bytes 64 * 1024 * 1024

  @type block_state :: %{
          required(:buffer) => binary(),
          required(:skip_leading_lf?) => boolean()
        }

  @spec max_incomplete_sse_block_bytes() :: pos_integer()
  def max_incomplete_sse_block_bytes, do: @max_incomplete_sse_block_bytes

  @spec oversized_incomplete_sse_block?(binary()) :: boolean()
  def oversized_incomplete_sse_block?(buffer) when is_binary(buffer),
    do: byte_size(buffer) > @max_incomplete_sse_block_bytes

  @spec max_incomplete_terminal_sse_block_bytes() :: pos_integer()
  def max_incomplete_terminal_sse_block_bytes,
    do: @max_incomplete_terminal_sse_block_bytes

  @spec oversized_incomplete_terminal_sse_block?(binary()) :: boolean()
  def oversized_incomplete_terminal_sse_block?(buffer) when is_binary(buffer),
    do: byte_size(buffer) > @max_incomplete_terminal_sse_block_bytes

  @spec new_block_state() :: block_state()
  def new_block_state, do: %{buffer: "", skip_leading_lf?: false}

  # A trailing standalone CR completes its line immediately. If that CR is the
  # last byte in a chunk, the next chunk may start with its optional LF
  # continuation; retaining that one bit of state prevents the LF from being
  # counted as another line ending.
  @spec complete_sse_blocks(block_state(), binary(), keyword()) :: {[binary()], block_state()}
  def complete_sse_blocks(
        %{buffer: buffer, skip_leading_lf?: skip_leading_lf?} = state,
        data,
        opts
      )
      when is_binary(buffer) and is_boolean(skip_leading_lf?) and is_binary(data) do
    bounded? = Keyword.fetch!(opts, :bounded?)

    if appendable_without_scan?(state, data) do
      next_state = %{state | buffer: buffer <> data}
      {[], maybe_bound_incomplete_sse_state(next_state, bounded?)}
    else
      {data, pending_skip_leading_lf?} =
        consume_optional_leading_lf(data, skip_leading_lf?)

      {blocks, residue, trailing_skip_leading_lf?} = split_complete_blocks(buffer <> data)

      next_state = %{
        buffer: residue,
        skip_leading_lf?: pending_skip_leading_lf? or trailing_skip_leading_lf?
      }

      {blocks, maybe_bound_incomplete_sse_state(next_state, bounded?)}
    end
  end

  defp appendable_without_scan?(%{buffer: ""}, _data), do: false
  defp appendable_without_scan?(%{skip_leading_lf?: true}, _data), do: false

  defp appendable_without_scan?(%{buffer: buffer}, data) do
    not String.ends_with?(buffer, "\r") and
      not (String.ends_with?(buffer, "\n") and String.starts_with?(data, "\n")) and
      not String.contains?(data, ["\r", "\n\n"])
  end

  defp consume_optional_leading_lf("", true), do: {"", true}
  defp consume_optional_leading_lf(<<"\n", rest::binary>>, true), do: {rest, false}
  defp consume_optional_leading_lf(data, true), do: {data, false}
  defp consume_optional_leading_lf(data, false), do: {data, false}

  @spec complete_sse_blocks(binary(), keyword()) :: {[binary()], binary()}
  def complete_sse_blocks(data, opts) when is_binary(data) do
    {blocks, state} = complete_sse_blocks(new_block_state(), data, opts)
    {blocks, state.buffer}
  end

  defp split_complete_blocks(data) do
    {blocks, residue_start, skip_leading_lf?} =
      scan_complete_blocks(data, 0, 0, [])

    residue =
      data
      |> binary_part(residue_start, byte_size(data) - residue_start)
      |> :binary.copy()

    {Enum.reverse(blocks), residue, skip_leading_lf?}
  end

  defp scan_complete_blocks(data, block_start, scan_index, blocks)
       when scan_index >= byte_size(data),
       do: {blocks, block_start, false}

  defp scan_complete_blocks(data, block_start, scan_index, blocks) do
    first_ending_length = line_ending_length(data, scan_index)

    if first_ending_length == 0 do
      scan_complete_blocks(data, block_start, scan_index + 1, blocks)
    else
      scan_after_first_ending(data, block_start, scan_index, first_ending_length, blocks)
    end
  end

  defp scan_after_first_ending(data, block_start, scan_index, first_ending_length, blocks) do
    second_ending_index = scan_index + first_ending_length
    second_ending_length = line_ending_length(data, second_ending_index)

    if second_ending_length == 0 do
      scan_complete_blocks(data, block_start, second_ending_index, blocks)
    else
      block = binary_part(data, block_start, scan_index - block_start)
      blocks = if block == "", do: blocks, else: [canonicalize_line_endings(block) | blocks]
      next_index = second_ending_index + second_ending_length

      if next_index == byte_size(data) do
        trailing_cr? =
          second_ending_length == 1 and :binary.at(data, second_ending_index) == ?\r

        {blocks, next_index, trailing_cr?}
      else
        scan_complete_blocks(data, next_index, next_index, blocks)
      end
    end
  end

  defp line_ending_length(data, index) when index >= byte_size(data), do: 0

  defp line_ending_length(data, index) do
    case :binary.at(data, index) do
      ?\n ->
        1

      ?\r ->
        if index + 1 < byte_size(data) and :binary.at(data, index + 1) == ?\n, do: 2, else: 1

      _byte ->
        0
    end
  end

  defp canonicalize_line_endings(block) do
    block
    |> :binary.replace("\r\n", "\n", [:global])
    |> :binary.replace("\r", "\n", [:global])
    |> String.trim_leading("\n")
  end

  @spec sse_field(binary(), binary()) :: binary() | nil
  def sse_field(block, name) do
    prefix = name <> ":"

    block
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn line ->
      if String.starts_with?(line, prefix) do
        [line |> String.replace_prefix(prefix, "") |> String.trim_leading()]
      else
        []
      end
    end)
    |> case do
      [] -> nil
      values -> Enum.join(values, "\n")
    end
  end

  @spec normalize_sse_event_label(term()) :: binary() | nil
  def normalize_sse_event_label(label) when is_binary(label) do
    case String.trim(label) do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_sse_event_label(_label), do: nil

  @spec decode_sse_data(term()) :: map()
  def decode_sse_data(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} -> decoded
      _other -> %{}
    end
  end

  def decode_sse_data(_data), do: %{}

  @spec valid_json?(term()) :: boolean()
  def valid_json?(body) when is_binary(body), do: match?({:ok, _}, Jason.decode(body))
  def valid_json?(_body), do: false

  @spec stream_block_event(binary()) :: {String.t() | nil, map()}
  def stream_block_event(block) do
    data = sse_field(block, "data")
    decoded = if is_binary(data), do: decode_sse_data(data), else: decode_sse_data(block)

    event_type =
      normalize_sse_event_label(sse_field(block, "event")) || decoded_string(decoded, "type")

    {event_type, decoded}
  end

  defp decoded_string(decoded, key) when is_map(decoded) do
    case Map.get(decoded, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp maybe_bound_incomplete_sse_state(state, false), do: state

  defp maybe_bound_incomplete_sse_state(%{buffer: buffer} = state, true) do
    if oversized_incomplete_sse_block?(buffer), do: new_block_state(), else: state
  end
end
