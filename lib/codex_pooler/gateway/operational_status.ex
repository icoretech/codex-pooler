defmodule CodexPooler.Gateway.OperationalStatus do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain

  @type option :: {:drain_marker_path, String.t() | nil}

  @spec draining?([option()]) :: boolean()
  def draining?(opts \\ []) do
    marker_draining?(Keyword.get(opts, :drain_marker_path)) or RolloutDrain.draining?()
  end

  @spec marker_draining?(String.t() | nil) :: boolean()
  def marker_draining?(path) when is_binary(path) and path != "", do: File.exists?(path)
  def marker_draining?(_path), do: false
end
