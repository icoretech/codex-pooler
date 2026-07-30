defmodule CodexPooler.Gateway.Persistence.StatusVocabulary.Circuit do
  @moduledoc false

  @statuses ~w(closed open half_open)

  @type status :: String.t()

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec closed_status() :: status()
  def closed_status, do: "closed"

  @spec open_status() :: status()
  def open_status, do: "open"

  @spec half_open_status() :: status()
  def half_open_status, do: "half_open"
end
