defmodule CodexPoolerWeb.Admin.UpstreamCockpitComponents.Formatting do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.DateTimeDisplay

  @spec format_reset_at(DateTime.t(), map()) :: String.t()
  def format_reset_at(%DateTime{} = reset_at, datetime_preferences),
    do: DateTimeDisplay.format_datetime(reset_at, datetime_preferences)

  @spec format_oauth_flow_time(DateTime.t() | nil, map()) :: String.t()
  def format_oauth_flow_time(%DateTime{} = timestamp, datetime_preferences),
    do: DateTimeDisplay.format_datetime(timestamp, datetime_preferences)

  def format_oauth_flow_time(_timestamp, _datetime_preferences), do: gettext("not reported")

  @spec format_event_timestamp(DateTime.t(), map()) :: String.t()
  def format_event_timestamp(%DateTime{} = timestamp, datetime_preferences),
    do: DateTimeDisplay.format_datetime(timestamp, datetime_preferences)

  @spec request_logs_path(map()) :: String.t()
  def request_logs_path(cockpit),
    do: ~p"/admin/request-logs?upstream_identity_id=#{cockpit.identity.id}"

  @spec audit_logs_path(map()) :: String.t()
  def audit_logs_path(cockpit), do: ~p"/admin/audit-logs?target=#{cockpit.identity.id}"

  @spec jobs_path(map()) :: String.t()
  def jobs_path(cockpit),
    do: ~p"/admin/jobs?target_kind=upstream_identity&target_id=#{cockpit.identity.id}"

  @spec assignment_status_class(String.t()) :: String.t()
  def assignment_status_class(status), do: AdminBadges.status_chip_class(status)

  @spec status_text(String.t() | atom()) :: String.t()
  def status_text(status) when status in ["active", :active], do: gettext("active")
  def status_text(status) when status in ["pending", :pending], do: gettext("pending")
  def status_text(status) when status in ["paused", :paused], do: gettext("paused")
  def status_text(status) when status in ["disabled", :disabled], do: gettext("disabled")
  def status_text(status) when status in ["deleted", :deleted], do: gettext("deleted")
  def status_text(status) when status in ["degraded", :degraded], do: gettext("degraded")
  def status_text(status) when status in ["errored", :errored], do: gettext("errored")
  def status_text(status) when status in ["failed", :failed], do: gettext("failed")
  def status_text(status) when status in ["partial", :partial], do: gettext("partial")
  def status_text(status) when status in ["blocked", :blocked], do: gettext("blocked")
  def status_text(status) when status in ["succeeded", :succeeded], do: gettext("succeeded")
  def status_text(status) when status in ["imported", :imported], do: gettext("imported")
  def status_text(status) when status in ["refreshing", :refreshing], do: gettext("refreshing")
  def status_text(status) when status in ["refresh_failed", :refresh_failed], do: gettext("refresh failed")
  def status_text(status) when status in ["reauth_required", :reauth_required], do: gettext("reauth required")
  def status_text(status) when status in ["unknown", :unknown], do: gettext("unknown")
  def status_text(status) when status in ["unavailable", :unavailable], do: gettext("unavailable")
  def status_text(status) when status in ["healthy", :healthy], do: gettext("healthy")
  def status_text(status) when status in ["fresh", :fresh], do: gettext("fresh")
  def status_text(status) when status in ["stale", :stale], do: gettext("stale")
  def status_text(status) when status in ["known", :known], do: gettext("known")
  def status_text(status) when status in ["not_started", :not_started], do: gettext("not started")
  def status_text(status) when status in ["expired", :expired], do: gettext("expired")
  def status_text(status) when status in ["completed", :completed], do: gettext("completed")
  def status_text(status) when status in ["cancelled", :cancelled], do: gettext("cancelled")
  def status_text(status) when status in ["queued", :queued], do: gettext("queued")
  def status_text(status) when status in ["running", :running], do: gettext("running")
  def status_text(status) when status in ["closed", :closed], do: gettext("closed")
  def status_text(status) when status in ["open", :open], do: gettext("open")
  def status_text(status) when status in ["recovering", :recovering], do: gettext("recovering")
  def status_text(status) when status in ["refresh_due", :refresh_due], do: gettext("refresh due")
  def status_text(status) when status in ["cooldown", :cooldown], do: gettext("cooldown")
  def status_text(status) when status in ["eligible", :eligible], do: gettext("eligible")
  def status_text(status) when status in ["ineligible", :ineligible], do: gettext("ineligible")
  def status_text(status) when status in ["scheduled", :scheduled], do: gettext("scheduled")
  def status_text(status) when status in ["retryable", :retryable], do: gettext("retryable")
  def status_text(status) when status in ["executing", :executing], do: gettext("executing")
  def status_text(status) when status in ["discarded", :discarded], do: gettext("discarded")
  def status_text(status) when status in ["available", :available], do: gettext("available")
  def status_text(status) when status in ["exhausted", :exhausted], do: gettext("exhausted")
  def status_text(status) when status in ["waiting", :waiting], do: gettext("waiting")
  def status_text(status) when status in ["present", :present], do: gettext("present")
  def status_text(status) when status in ["missing", :missing], do: gettext("missing")
  def status_text(status) when status in ["skipped", :skipped], do: gettext("skipped")

  def status_text(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
  end

  @spec status_badge_class(String.t()) :: String.t()
  def status_badge_class(status), do: AdminBadges.status_chip_class(status)

  @spec humanize_state(String.t() | atom()) :: String.t()
  def humanize_state(state) when state in ["active", :active], do: gettext("Active")
  def humanize_state(state) when state in ["pending", :pending], do: gettext("Pending")
  def humanize_state(state) when state in ["paused", :paused], do: gettext("Paused")
  def humanize_state(state) when state in ["disabled", :disabled], do: gettext("Disabled")
  def humanize_state(state) when state in ["deleted", :deleted], do: gettext("Deleted")
  def humanize_state(state) when state in ["degraded", :degraded], do: gettext("Degraded")
  def humanize_state(state) when state in ["errored", :errored], do: gettext("Errored")
  def humanize_state(state) when state in ["failed", :failed], do: gettext("Failed")
  def humanize_state(state) when state in ["partial", :partial], do: gettext("Partial")
  def humanize_state(state) when state in ["blocked", :blocked], do: gettext("Blocked")
  def humanize_state(state) when state in ["healthy", :healthy], do: gettext("Healthy")
  def humanize_state(state) when state in ["unknown", :unknown], do: gettext("Unknown")
  def humanize_state(state) when state in ["unavailable", :unavailable], do: gettext("Unavailable")
  def humanize_state(state) when state in ["fresh", :fresh], do: gettext("Fresh")
  def humanize_state(state) when state in ["stale", :stale], do: gettext("Stale")
  def humanize_state(state) when state in ["known", :known], do: gettext("Known")
  def humanize_state(state) when state in ["expired", :expired], do: gettext("Expired")
  def humanize_state(state) when state in ["refresh_due", :refresh_due], do: gettext("Refresh due")
  def humanize_state(state) when state in ["refreshing", :refreshing], do: gettext("Refreshing")
  def humanize_state(state) when state in ["refresh_failed", :refresh_failed], do: gettext("Refresh failed")
  def humanize_state(state) when state in ["reauth_required", :reauth_required], do: gettext("Reauth required")
  def humanize_state(state) when state in ["cooldown", :cooldown], do: gettext("Cooldown")
  def humanize_state(state) when state in ["eligible", :eligible], do: gettext("Eligible")
  def humanize_state(state) when state in ["ineligible", :ineligible], do: gettext("Ineligible")
  def humanize_state(state) when state in ["exhausted", :exhausted], do: gettext("Exhausted")
  def humanize_state(state) when state in ["available", :available], do: gettext("Available")
  def humanize_state(state) when state in ["waiting", :waiting], do: gettext("Waiting")
  def humanize_state(state) when state in ["empty", :empty], do: gettext("Empty")
  def humanize_state(state) when state in ["ok", :ok], do: gettext("Ok")
  def humanize_state(state) when state in ["ready", :ready], do: gettext("Ready")

  def humanize_state(state) do
    state
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
