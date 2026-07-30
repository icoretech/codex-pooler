defmodule CodexPooler.Gateway.Persistence.StatusVocabulary.Session do
  @moduledoc false

  @statuses ~w(active interrupted closed)
  @reconnectable_statuses ~w(active interrupted)

  @type status :: String.t()

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec reconnectable_statuses() :: [status()]
  def reconnectable_statuses, do: @reconnectable_statuses

  @spec active_status() :: status()
  def active_status, do: "active"

  @spec interrupted_status() :: status()
  def interrupted_status, do: "interrupted"

  @spec closed_status() :: status()
  def closed_status, do: "closed"
end
