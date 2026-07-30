defmodule CodexPooler.Gateway.Persistence.StatusVocabulary.Turn do
  @moduledoc false

  @statuses ~w(in_progress succeeded failed interrupted)

  @type status :: String.t()

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec in_progress_status() :: status()
  def in_progress_status, do: "in_progress"

  @spec succeeded_status() :: status()
  def succeeded_status, do: "succeeded"

  @spec failed_status() :: status()
  def failed_status, do: "failed"

  @spec interrupted_status() :: status()
  def interrupted_status, do: "interrupted"
end
