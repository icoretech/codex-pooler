defmodule CodexPooler.Gateway.Transports.Streaming.CollectedBody do
  @moduledoc false

  # `RetainedBody` keeps the last 64 KiB of a stream for bounded error
  # diagnostics, so anything it drops is by design. The collect delivery modes
  # are different: their body is the authoritative compact result, and the
  # `response.output_item.done` frame that carries `encrypted_content` is
  # evicted as soon as later frames pass that bound. This accumulator keeps a
  # collected turn whole up to its own bound, and latches an explicit overflow
  # instead of returning a suffix that starts mid-block.
  #
  # The bound matches `StreamProtocol.SSEParser`'s ordinary incomplete-block
  # bound: a single provider event larger than that cannot be parsed anyway, so
  # retaining more would only grow the per-connection footprint. One collected
  # turn is in flight per upstream websocket connection, and an overflow frees
  # the accumulated chunks immediately, so the worst case stays one bound per
  # connection.
  @max_bytes 8_388_608

  @overflow_event_type "codex_pooler.collected_body_overflow"

  @type t :: :disabled | %{chunks: [binary()], bytes: non_neg_integer(), overflow?: boolean()}

  @spec disabled() :: t()
  def disabled, do: :disabled

  @spec empty() :: t()
  def empty, do: %{chunks: [], bytes: 0, overflow?: false}

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @spec overflow_event_type() :: String.t()
  def overflow_event_type, do: @overflow_event_type

  @spec append(t(), iodata()) :: t()
  def append(:disabled, _data), do: :disabled
  def append(%{overflow?: true} = body, _data), do: body

  def append(%{chunks: chunks, bytes: bytes}, data) do
    data = IO.iodata_to_binary(data)
    collected_bytes = bytes + byte_size(data)

    if collected_bytes > @max_bytes do
      %{chunks: [], bytes: collected_bytes, overflow?: true}
    else
      %{chunks: [data | chunks], bytes: collected_bytes, overflow?: false}
    end
  end

  @doc """
  Reads the collected body.

  An overflowed accumulator reads back as a single bounded internal marker
  block rather than a truncated stream, so the collector reports the distinct
  overflow reason instead of degrading to `missing_terminal`.
  """
  @spec read(t()) :: binary()
  def read(:disabled), do: ""

  def read(%{overflow?: true, bytes: bytes}) do
    "data: " <>
      CodexPooler.JSON.encode!(%{
        "type" => @overflow_event_type,
        "bytes" => bytes,
        "max_bytes" => @max_bytes
      }) <> "\n\n"
  end

  def read(%{chunks: chunks}), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  @spec overflow?(t()) :: boolean()
  def overflow?(%{overflow?: overflow?}), do: overflow?
  def overflow?(:disabled), do: false

  @spec bytes(t()) :: non_neg_integer()
  def bytes(%{bytes: bytes}), do: bytes
  def bytes(:disabled), do: 0
end
