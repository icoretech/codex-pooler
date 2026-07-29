defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.SSEParser do
  @moduledoc false

  # Upstream Responses streams carry single non-terminal SSE events well past
  # 64 KiB (reasoning items with encrypted content scale with request context),
  # so the ordinary bound must stay comfortably above real provider event sizes.
  @max_incomplete_sse_block_bytes 8_388_608
  @max_incomplete_terminal_sse_block_bytes 64 * 1024 * 1024

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

  # Incremental form for streaming callers that accumulate `residue <> data`
  # chunk by chunk. Callers must feed back only residues returned by this
  # function (or ""); a residue assembled any other way may hide complete
  # blocks and break the shortcut. Appending may skip the full
  # normalize-and-split scan only when it cannot create a block separator
  # anywhere: the new data carries no CR and no separator of its own, and the
  # junction with the retained residue is inert. Any returned residue, once
  # CRLF-normalized, contains no complete separator, so the skipped append
  # preserves that invariant and a later full scan finds exactly the blocks it
  # would have found without the shortcut.
  @spec complete_sse_blocks(binary(), binary(), keyword()) :: {[binary()], binary()}
  def complete_sse_blocks(residue, data, opts)
      when is_binary(residue) and is_binary(data) do
    if appendable_without_scan?(residue, data) do
      bounded? = Keyword.fetch!(opts, :bounded?)
      {[], maybe_bound_incomplete_sse_block(residue <> data, bounded?)}
    else
      complete_sse_blocks(residue <> data, opts)
    end
  end

  defp appendable_without_scan?("", _data), do: false

  defp appendable_without_scan?(residue, data) do
    not String.ends_with?(residue, "\r") and
      not (String.ends_with?(residue, "\n") and String.starts_with?(data, "\n")) and
      not String.contains?(data, ["\r", "\n\n"])
  end

  # CRLF collapses to its fixpoint in one pass: repeatedly replacing "\r\n"
  # with "\n" consumes one trailing CR of a "\r"+ run per pass, so the fixpoint
  # is the whole run collapsing into the newline. A retained residue therefore
  # can never hide a separator behind a partially collapsed sequence such as
  # "\r\r\n", and adversarial CR runs stay linear instead of looping one scan
  # per CR.
  @crlf_run ~r/\r+\n/
  defp normalize_crlf(data) do
    if String.contains?(data, "\r") do
      String.replace(data, @crlf_run, "\n")
    else
      data
    end
  end

  @spec complete_sse_blocks(binary(), keyword()) :: {[binary()], binary()}
  def complete_sse_blocks(data, opts) do
    data = normalize_crlf(data)
    bounded? = Keyword.fetch!(opts, :bounded?)

    if String.contains?(data, "\n\n") do
      parts = String.split(data, "\n\n")
      ends_with_separator? = String.ends_with?(data, "\n\n")

      {complete, buffer} =
        if ends_with_separator? do
          {parts, ""}
        else
          {Enum.drop(parts, -1), List.last(parts) || ""}
        end

      {Enum.reject(complete, &(&1 == "")), maybe_bound_incomplete_sse_block(buffer, bounded?)}
    else
      {[], maybe_bound_incomplete_sse_block(data, bounded?)}
    end
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

  defp maybe_bound_incomplete_sse_block(buffer, false), do: buffer

  defp maybe_bound_incomplete_sse_block(buffer, true) do
    if oversized_incomplete_sse_block?(buffer), do: "", else: buffer
  end
end
