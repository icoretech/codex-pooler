defmodule CodexPooler.Upstreams.StatusVocabulary.Identity do
  @moduledoc false

  @statuses ~w(pending active paused refresh_due refreshing refresh_failed reauth_required deleted disabled errored)
  @model_routable_statuses ~w(active refreshing)
  @file_routable_statuses ~w(active)

  @type status :: String.t()

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec model_routable_statuses() :: [status()]
  def model_routable_statuses, do: @model_routable_statuses

  @spec file_routable_statuses() :: [status()]
  def file_routable_statuses, do: @file_routable_statuses

  @spec pending_status() :: status()
  def pending_status, do: "pending"

  @spec active_status() :: status()
  def active_status, do: "active"

  @spec paused_status() :: status()
  def paused_status, do: "paused"

  @spec refresh_due_status() :: status()
  def refresh_due_status, do: "refresh_due"

  @spec refreshing_status() :: status()
  def refreshing_status, do: "refreshing"

  @spec refresh_failed_status() :: status()
  def refresh_failed_status, do: "refresh_failed"

  @spec reauth_required_status() :: status()
  def reauth_required_status, do: "reauth_required"

  @spec deleted_status() :: status()
  def deleted_status, do: "deleted"

  @spec disabled_status() :: status()
  def disabled_status, do: "disabled"

  @spec errored_status() :: status()
  def errored_status, do: "errored"
end
