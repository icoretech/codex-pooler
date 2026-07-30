defmodule CodexPooler.Gateway.Runtime.Streaming.TerminalOutcome do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @spec retry_window_event(map()) :: {:ok, map()} | nil
  def retry_window_event(event) when is_map(event) do
    if StreamProtocol.downstream_visible_event?(event) or
         not is_nil(StreamProtocol.terminal_outcome_event(event)),
       do: {:ok, event}
  end

  @spec direct_retry_window_event({:ok, map()} | :incomplete) :: {:ok, map()} | :incomplete
  def direct_retry_window_event({:ok, event}) do
    if StreamProtocol.downstream_visible_event?(event),
      do: {:ok, event},
      else: :incomplete
  end

  def direct_retry_window_event(:incomplete), do: :incomplete
end
