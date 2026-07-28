defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.SSEParser do
  @moduledoc false

  @max_incomplete_sse_block_bytes 65_536

  @spec max_incomplete_sse_block_bytes() :: pos_integer()
  def max_incomplete_sse_block_bytes, do: @max_incomplete_sse_block_bytes

  @spec oversized_incomplete_sse_block?(binary()) :: boolean()
  def oversized_incomplete_sse_block?(buffer) when is_binary(buffer),
    do: byte_size(buffer) > @max_incomplete_sse_block_bytes

  @spec complete_sse_blocks(binary(), keyword()) :: {[binary()], binary()}
  def complete_sse_blocks(data, opts) do
    data = String.replace(data, "\r\n", "\n")
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
