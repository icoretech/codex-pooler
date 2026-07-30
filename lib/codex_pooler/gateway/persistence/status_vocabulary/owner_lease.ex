defmodule CodexPooler.Gateway.Persistence.StatusVocabulary.OwnerLease do
  @moduledoc false

  @statuses ~w(active expired released)

  @type status :: String.t()

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec active_status() :: status()
  def active_status, do: "active"

  @spec expired_status() :: status()
  def expired_status, do: "expired"

  @spec released_status() :: status()
  def released_status, do: "released"
end
