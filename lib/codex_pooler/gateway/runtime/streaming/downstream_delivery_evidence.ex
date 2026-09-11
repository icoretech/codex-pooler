defmodule CodexPooler.Gateway.Runtime.Streaming.DownstreamDeliveryEvidence do
  @moduledoc false

  # Bounded, metadata-only bookkeeping of what the HTTP SSE relay actually
  # wrote to the downstream connection: chunks written after visible output,
  # the first terminal class written and when, and whether a downstream write
  # failed. `Finalization.Streaming` replaces the attempt's response metadata
  # wholesale, so the evidence stays in the relay state and becomes one
  # `downstream_delivery` receipt only after the finalizer returned. Nothing
  # from the wire is retained beyond a bounded SSE block residue used to spot a
  # terminal split across chunks.

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Websocket.DeliveryReceipt

  @state_key :downstream_delivery
  @transport "http_sse"

  @type evidence :: %{
          frames: non_neg_integer(),
          terminal_class: String.t() | nil,
          pushed_at: DateTime.t() | nil,
          write_failed?: boolean(),
          sse: StreamProtocol.sse_block_state()
        }

  @spec new() :: evidence()
  def new do
    %{
      frames: 0,
      terminal_class: nil,
      pushed_at: nil,
      write_failed?: false,
      sse: StreamProtocol.new_sse_block_state()
    }
  end

  @spec fetch(map()) :: evidence()
  def fetch(state) when is_map(state) do
    case Map.get(state, @state_key) do
      %{frames: _frames} = evidence -> evidence
      _missing -> new()
    end
  end

  @doc """
  Records one successful downstream write. Chunks count as frames only once the
  relay marked visible output; the first terminal block written fixes the
  receipt's class and timestamp.
  """
  @spec record_write(map(), iodata()) :: map()
  def record_write(state, data) when is_map(state) do
    case IO.iodata_to_binary(data) do
      "" -> state
      written -> put(state, written_evidence(fetch(state), written, visible_output?(state)))
    end
  end

  @spec record_write_failure(map()) :: map()
  def record_write_failure(state) when is_map(state),
    do: put(state, %{fetch(state) | write_failed?: true})

  @spec receipt(map()) :: DeliveryReceipt.receipt()
  def receipt(state) when is_map(state) do
    evidence = fetch(state)

    DeliveryReceipt.build(%{
      outcome: outcome(evidence),
      terminal_class: evidence.terminal_class,
      pushed_at: evidence.pushed_at,
      frames_after_visible: evidence.frames,
      transport: @transport
    })
  end

  @doc """
  Logs and persists the receipt through the shared `DeliveryReceipt.record/2`
  path. Never raises.
  """
  @spec record(map(), DeliveryReceipt.context()) :: :ok
  def record(state, context) when is_map(state) and is_map(context),
    do: DeliveryReceipt.record(context, receipt(state))

  defp written_evidence(evidence, written, visible?) do
    evidence = if visible?, do: %{evidence | frames: evidence.frames + 1}, else: evidence

    if is_binary(evidence.terminal_class) do
      evidence
    else
      {blocks, sse} = StreamProtocol.complete_sse_blocks(evidence.sse, written, bounded?: true)
      record_terminal(%{evidence | sse: sse}, blocks)
    end
  end

  defp record_terminal(evidence, blocks) do
    case Enum.find_value(blocks, &DeliveryReceipt.terminal_class(&1 <> "\n\n")) do
      class when is_binary(class) ->
        %{evidence | terminal_class: class, pushed_at: DateTime.utc_now()}

      nil ->
        evidence
    end
  end

  defp outcome(%{terminal_class: class}) when is_binary(class), do: "delivered"
  defp outcome(%{write_failed?: true}), do: "aborted"
  defp outcome(_evidence), do: "completed"

  defp visible_output?(state), do: Map.get(state, :visible_output_marked?) == true

  defp put(state, evidence), do: Map.put(state, @state_key, evidence)
end
