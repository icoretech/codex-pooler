defmodule CodexPooler.Gateway.Runtime.Streaming.EventSummary do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCanonicalization

  @spec from_complete_block(binary()) :: map()
  def from_complete_block(block) when is_binary(block),
    do: ErrorCanonicalization.event_summary_from_block(block)

  @spec from_direct_candidate(binary()) :: {:ok, map()} | :incomplete
  def from_direct_candidate(buffer) when is_binary(buffer),
    do: StreamProtocol.first_complete_event(buffer)
end
