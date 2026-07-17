defmodule CodexPoolerWeb.Admin.UpstreamCockpitComponents.Formatting do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.DateTimeDisplay

  def format_reset_at(%DateTime{} = reset_at, datetime_preferences),
    do: DateTimeDisplay.format_datetime(reset_at, datetime_preferences)

  def format_oauth_flow_time(%DateTime{} = timestamp, datetime_preferences),
    do: DateTimeDisplay.format_datetime(timestamp, datetime_preferences)

  def format_oauth_flow_time(_timestamp, _datetime_preferences), do: "not reported"

  def format_event_timestamp(%DateTime{} = timestamp, datetime_preferences),
    do: DateTimeDisplay.format_datetime(timestamp, datetime_preferences)

  def request_logs_path(cockpit),
    do: ~p"/admin/request-logs?upstream_identity_id=#{cockpit.identity.id}"

  def audit_logs_path(cockpit), do: ~p"/admin/audit-logs?target=#{cockpit.identity.id}"

  def jobs_path(cockpit),
    do: ~p"/admin/jobs?target_kind=upstream_identity&target_id=#{cockpit.identity.id}"

  @doc """
  Strips a redundant sentence prefix from a preformatted label ("token refresh
  succeeded 5d ago" → "succeeded 5d ago") so dt/dd rows do not repeat it.
  """
  def strip_label_prefix(label, prefix) when is_binary(label) do
    String.replace_prefix(label, prefix, "")
  end

  def strip_label_prefix(label, _prefix), do: label

  def assignment_status_class(status), do: AdminBadges.status_chip_class(status)

  def status_label(prefix, status), do: "#{prefix} #{status_text(status)}"

  def status_text(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
  end

  def status_badge_class(status),
    do: CodexPoolerWeb.Admin.BadgeComponents.status_chip_class(status)

  def humanize_state(state) do
    state
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def pluralize_count(1, singular, _plural), do: "1 #{singular}"
  def pluralize_count(count, _singular, plural), do: "#{count || 0} #{plural}"
end
