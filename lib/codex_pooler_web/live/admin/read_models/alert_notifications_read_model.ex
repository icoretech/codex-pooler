defmodule CodexPoolerWeb.Admin.AlertNotificationsReadModel do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  alias CodexPooler.Admin.AlertNotificationQuery

  @type impacted_pool :: AlertNotificationQuery.impacted_pool()
  @type row :: %{
          required(:id) => Ecto.UUID.t(),
          required(:anchor_id) => String.t(),
          required(:reason_title) => String.t(),
          required(:severity) => String.t(),
          required(:severity_label) => String.t(),
          required(:state) => String.t(),
          required(:state_label) => String.t(),
          required(:impacted_pools) => [impacted_pool()],
          required(:visible_impacted_pool_count) => non_neg_integer(),
          required(:hidden_impacted_pool_count) => non_neg_integer(),
          required(:total_impacted_pool_count) => non_neg_integer(),
          required(:last_seen_at) => DateTime.t(),
          required(:unread?) => boolean()
        }
  @type page_state :: %{
          required(:rows) => [row()],
          required(:unread_count) => non_neg_integer(),
          required(:badge_count) => non_neg_integer(),
          required(:has_rows?) => boolean(),
          required(:empty?) => boolean(),
          required(:page_size) => pos_integer()
        }

  @spec load(term()) :: page_state()
  def load(scope) do
    scope
    |> AlertNotificationQuery.load()
    |> page_state()
  end

  @spec severity_label(String.t() | nil) :: String.t()
  def severity_label("critical"), do: gettext("Critical")
  def severity_label("warning"), do: gettext("Warning")
  def severity_label("info"), do: gettext("Info")
  def severity_label(_severity), do: gettext("Unknown severity")

  @spec state_label(String.t() | nil) :: String.t()
  def state_label("open") do
    gettext_comment("Open means an unresolved alert incident, not the action for opening a page.")
    pgettext("incident state", "Open")
  end

  def state_label("acknowledged"), do: gettext("Acknowledged")
  def state_label(_state), do: gettext("Unknown state")

  @spec page_state(AlertNotificationQuery.page_state()) :: page_state()
  defp page_state(%{rows: rows, unread_count: unread_count, page_size: page_size}) do
    rows = Enum.map(rows, &notification_row/1)

    %{
      rows: rows,
      unread_count: unread_count,
      badge_count: unread_count,
      has_rows?: rows != [],
      empty?: rows == [],
      page_size: page_size
    }
  end

  @spec notification_row(AlertNotificationQuery.row()) :: row()
  defp notification_row(row) do
    %{
      id: row.id,
      anchor_id: "alert-incident-#{row.id}",
      reason_title: reason_title(row),
      severity: row.severity,
      severity_label: severity_label(row.severity),
      state: row.state,
      state_label: state_label(row.state),
      impacted_pools: row.impacted_pools,
      visible_impacted_pool_count: row.visible_impacted_pool_count,
      hidden_impacted_pool_count: row.hidden_impacted_pool_count,
      total_impacted_pool_count: row.total_impacted_pool_count,
      last_seen_at: row.last_seen_at,
      unread?: row.unread?
    }
  end

  defp reason_title(%{rule_kind: "pool_no_usable_assignments"}), do: gettext("No usable assignments")

  defp reason_title(%{rule_kind: "pool_low_usable_assignments"}),
    do: gettext("Low usable assignment coverage")

  defp reason_title(%{rule_kind: "pool_all_assignments_in_state"}),
    do: gettext("Assignments match an attention state")

  defp reason_title(%{rule_kind: "upstream_quota_threshold"}), do: gettext("Quota threshold reached")

  defp reason_title(%{rule_kind: "upstream_auth_state"}), do: gettext("Upstream auth attention needed")

  defp reason_title(%{rule_kind: "upstream_saved_reset_banked_first_seen"}),
    do: gettext("First-seen banked saved reset")

  defp reason_title(_row), do: gettext("Alert condition matched")
end
