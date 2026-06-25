defmodule CodexPoolerWeb.Admin.AlertNotificationsReadModel do
  @moduledoc false

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
  def severity_label("critical"), do: "Critical"
  def severity_label("warning"), do: "Warning"
  def severity_label("info"), do: "Info"
  def severity_label(_severity), do: "Unknown severity"

  @spec state_label(String.t() | nil) :: String.t()
  def state_label("open"), do: "Open"
  def state_label("acknowledged"), do: "Acknowledged"
  def state_label(_state), do: "Unknown state"

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
      last_seen_at: row.last_seen_at,
      unread?: row.unread?
    }
  end

  defp reason_title(%{rule_kind: "pool_no_usable_assignments"}), do: "No usable assignments"

  defp reason_title(%{rule_kind: "pool_low_usable_assignments"}),
    do: "Low usable assignment coverage"

  defp reason_title(%{rule_kind: "pool_all_assignments_in_state"}),
    do: "Assignments match an attention state"

  defp reason_title(%{rule_kind: "upstream_quota_threshold"}), do: "Quota threshold reached"

  defp reason_title(%{rule_kind: "upstream_auth_state"}), do: "Upstream auth attention needed"

  defp reason_title(_row), do: "Alert condition matched"
end
