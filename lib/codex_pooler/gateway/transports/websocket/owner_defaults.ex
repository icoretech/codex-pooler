defmodule CodexPooler.Gateway.Transports.Websocket.OwnerDefaults do
  @moduledoc false

  @forward_timeout_ms 5_000
  @owner_call_timeout_ms 5_000
  @downstream_send_timeout_ms 1_000

  @spec forward_timeout_ms() :: pos_integer()
  def forward_timeout_ms, do: @forward_timeout_ms

  @spec owner_call_timeout_ms() :: pos_integer()
  def owner_call_timeout_ms, do: @owner_call_timeout_ms

  @spec downstream_send_timeout_ms() :: pos_integer()
  def downstream_send_timeout_ms, do: @downstream_send_timeout_ms
end
