defmodule CodexPoolerWeb.Admin.AlertNotificationsReadModel do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertIncident
  alias CodexPooler.Alerts.Schemas.AlertIncidentReceipt
  alias CodexPooler.Alerts.Schemas.AlertIncidentTarget
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @page_size 50

  @type impacted_pool :: Alerts.pool_target()
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
  def load(%Scope{user: %{id: operator_id}} = scope) when is_binary(operator_id) do
    case visible_notifications_query(scope, operator_id) do
      {:ok, query} -> load_visible_notifications(scope, query)
      {:error, _reason} -> empty_page_state()
    end
  end

  def load(_scope), do: empty_page_state()

  @spec severity_label(String.t() | nil) :: String.t()
  def severity_label("critical"), do: "Critical"
  def severity_label("warning"), do: "Warning"
  def severity_label("info"), do: "Info"
  def severity_label(_severity), do: "Unknown severity"

  @spec state_label(String.t() | nil) :: String.t()
  def state_label("open"), do: "Open"
  def state_label("acknowledged"), do: "Acknowledged"
  def state_label(_state), do: "Unknown state"

  defp visible_notifications_query(scope, operator_id) do
    with {:ok, query} <- Alerts.bell_eligible_incidents_query(scope) do
      query =
        query
        |> exclude(:order_by)
        |> visible_notification_receipts_query(operator_id)

      {:ok, query}
    end
  end

  defp visible_notification_receipts_query(query, operator_id) do
    from incident in query,
      left_join: receipt in AlertIncidentReceipt,
      on: receipt.operator_id == ^operator_id and receipt.incident_id == incident.id,
      where:
        is_nil(receipt.id) or is_nil(receipt.dismissed_at) or
          receipt.dismissed_at < incident.last_seen_at
  end

  defp load_visible_notifications(scope, query) do
    rows = query |> load_rows() |> notification_rows(scope)
    unread_count = unread_count(query)

    %{
      rows: rows,
      unread_count: unread_count,
      badge_count: unread_count,
      has_rows?: rows != [],
      empty?: rows == [],
      page_size: @page_size
    }
  end

  defp load_rows(query) do
    Repo.all(
      from [incident, receipt] in query,
        order_by: [
          asc:
            fragment(
              "case ? when 'critical' then 0 when 'warning' then 1 when 'info' then 2 else 3 end",
              incident.severity
            ),
          asc:
            fragment(
              "case ? when 'open' then 0 when 'acknowledged' then 1 else 2 end",
              incident.state
            ),
          desc: incident.last_seen_at,
          asc: incident.id
        ],
        limit: ^@page_size,
        select: {incident, receipt}
    )
  end

  defp unread_count(query) do
    Repo.one(
      from [incident, receipt] in query,
        where:
          is_nil(receipt.id) or is_nil(receipt.read_at) or receipt.read_at < incident.last_seen_at,
        select: count(incident.id)
    ) || 0
  end

  defp notification_rows(rows, scope) do
    impacted_pools_by_incident = impacted_pools_by_incident(rows, scope)

    Enum.map(rows, fn {incident, receipt} ->
      %{
        id: incident.id,
        anchor_id: "alert-incident-#{incident.id}",
        reason_title: reason_title(incident),
        severity: incident.severity,
        severity_label: severity_label(incident.severity),
        state: incident.state,
        state_label: state_label(incident.state),
        impacted_pools: Map.get(impacted_pools_by_incident, incident.id, []),
        last_seen_at: incident.last_seen_at,
        unread?: Alerts.incident_notification_unread?(incident, receipt)
      }
    end)
  end

  defp impacted_pools_by_incident([], _scope), do: %{}

  defp impacted_pools_by_incident(rows, scope) do
    incident_ids = rows |> Enum.map(fn {incident, _receipt} -> incident.id end) |> Enum.uniq()
    visible_pool_ids = visible_pool_ids(scope)

    if visible_pool_ids == [] do
      %{}
    else
      Repo.all(
        from target in AlertIncidentTarget,
          join: pool in Pool,
          on: pool.id == target.pool_id,
          where: target.incident_id in ^incident_ids and target.pool_id in ^visible_pool_ids,
          order_by: [asc: pool.created_at, asc: pool.id],
          select: %{
            incident_id: target.incident_id,
            id: pool.id,
            slug: pool.slug,
            name: pool.name
          }
      )
      |> Enum.group_by(& &1.incident_id)
      |> Map.new(fn {incident_id, pools} ->
        {incident_id, Enum.map(pools, &Map.take(&1, [:id, :slug, :name]))}
      end)
    end
  end

  defp visible_pool_ids(scope) do
    case Alerts.list_manageable_pools(scope) do
      {:ok, pools} -> Enum.map(pools, & &1.id)
      {:error, _reason} -> []
    end
  end

  defp reason_title(%AlertIncident{rule_kind: "pool_no_usable_assignments"}),
    do: "No usable assignments"

  defp reason_title(%AlertIncident{rule_kind: "pool_low_usable_assignments"}),
    do: "Low usable assignment coverage"

  defp reason_title(%AlertIncident{rule_kind: "pool_all_assignments_in_state"}),
    do: "Assignments match an attention state"

  defp reason_title(%AlertIncident{rule_kind: "upstream_quota_threshold"}),
    do: "Quota threshold reached"

  defp reason_title(%AlertIncident{rule_kind: "upstream_auth_state"}),
    do: "Upstream auth attention needed"

  defp reason_title(%AlertIncident{}), do: "Alert condition matched"

  defp empty_page_state do
    %{
      rows: [],
      unread_count: 0,
      badge_count: 0,
      has_rows?: false,
      empty?: true,
      page_size: @page_size
    }
  end
end
