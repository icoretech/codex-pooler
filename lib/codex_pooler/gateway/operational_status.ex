defmodule CodexPooler.Gateway.OperationalStatus do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain

  @spec draining?() :: boolean()
  def draining? do
    marker_draining?() or RolloutDrain.draining?()
  end

  defp marker_draining? do
    case drain_marker_path() do
      path when is_binary(path) and path != "" -> File.exists?(path)
      _path -> false
    end
  end

  defp drain_marker_path do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:drain_marker_path)
  end
end
