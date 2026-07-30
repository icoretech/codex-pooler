defmodule CodexPooler.Upstreams.StatusVocabulary.Assignment do
  @moduledoc false

  @statuses ~w(pending active paused refresh_due refreshing refresh_failed reauth_required deleted disabled errored)
  @health_statuses ~w(unknown active cooldown degraded disabled errored)
  @eligibility_statuses ~w(eligible ineligible)

  @type status :: String.t()
  @type health_status :: String.t()
  @type eligibility_status :: String.t()

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec health_statuses() :: [health_status()]
  def health_statuses, do: @health_statuses

  @spec eligibility_statuses() :: [eligibility_status()]
  def eligibility_statuses, do: @eligibility_statuses

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

  @spec unknown_health_status() :: health_status()
  def unknown_health_status, do: "unknown"

  @spec active_health_status() :: health_status()
  def active_health_status, do: "active"

  @spec cooldown_health_status() :: health_status()
  def cooldown_health_status, do: "cooldown"

  @spec degraded_health_status() :: health_status()
  def degraded_health_status, do: "degraded"

  @spec disabled_health_status() :: health_status()
  def disabled_health_status, do: "disabled"

  @spec errored_health_status() :: health_status()
  def errored_health_status, do: "errored"

  @spec eligible_status() :: eligibility_status()
  def eligible_status, do: "eligible"

  @spec ineligible_status() :: eligibility_status()
  def ineligible_status, do: "ineligible"
end
