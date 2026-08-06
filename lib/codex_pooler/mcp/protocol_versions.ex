defmodule CodexPooler.MCP.ProtocolVersions do
  @moduledoc false

  @current "2026-07-28"
  @modern [@current]
  @legacy ["2025-11-25", "2025-06-18"]
  @supported @modern ++ @legacy

  @type protocol_version :: String.t()

  @spec current() :: protocol_version()
  def current, do: @current

  @spec modern() :: [protocol_version()]
  def modern, do: @modern

  @spec legacy() :: [protocol_version()]
  def legacy, do: @legacy

  @spec supported() :: [protocol_version()]
  def supported, do: @supported
end
