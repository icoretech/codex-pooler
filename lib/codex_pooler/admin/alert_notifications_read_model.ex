defmodule CodexPooler.Admin.AlertNotificationsReadModel do
  @moduledoc """
  Metadata-only alert notification projections for admin surfaces.
  """

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
          required(:rule_kind) => String.t(),
          required(:severity) => String.t(),
          required(:state) => String.t(),
          required(:impacted_pools) => [impacted_pool()],
          required(:last_seen_at) => DateTime.t(),
          required(:unread?) => boolean()
        }
  @type page_state :: %{
          required(:rows) => [row()],
          required(:unread_count) => non_neg_integer(),
          required(:page_size) => pos_integer()
        }
  @typep query_row :: {AlertIncident.t(), AlertIncidentReceipt.t() | nil}

  @spec load(term()) :: page_state()
  def load(%Scope{user: %{id: operator_id}} = scope) when is_binary(operator_id) do
    case visible_pool_ids(scope) do
      {:ok, []} -> empty_page_state()
      {:ok, pool_ids} -> load_visible_notifications(operator_id, pool_ids)
      {:error, _reason} -> empty_page_state()
    end
  end

  def load(_scope), do: empty_page_state()

  @spec load_visible_notifications(Ecto.UUID.t(), [Ecto.UUID.t()]) :: page_state()
  defp load_visible_notifications(operator_id, pool_ids) do
    query = visible_notifications_query(operator_id, pool_ids)
    rows = query |> load_rows() |> notification_rows(pool_ids)
    unread_count = unread_count(query)

    %{
      rows: rows,
      unread_count: unread_count,
      page_size: @page_size
    }
  end

  @spec visible_notifications_query(Ecto.UUID.t(), [Ecto.UUID.t()]) :: Ecto.Query.t()
  defp visible_notifications_query(operator_id, pool_ids) do
    from incident in AlertIncident,
      as: :incident,
      left_join: receipt in AlertIncidentReceipt,
      on: receipt.operator_id == ^operator_id and receipt.incident_id == incident.id,
      where: incident.state in ^visible_incident_states(),
      where:
        exists(
          from target in AlertIncidentTarget,
            where: target.incident_id == parent_as(:incident).id and target.pool_id in ^pool_ids,
            select: 1
        ),
      where:
        is_nil(receipt.id) or is_nil(receipt.dismissed_at) or
          receipt.dismissed_at < incident.last_seen_at
  end

  @spec load_rows(Ecto.Query.t()) :: [query_row()]
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

  @spec unread_count(Ecto.Query.t()) :: non_neg_integer()
  defp unread_count(query) do
    Repo.one(
      from [incident, receipt] in query,
        where:
          is_nil(receipt.id) or is_nil(receipt.read_at) or receipt.read_at < incident.last_seen_at,
        select: count(incident.id)
    ) || 0
  end

  @spec notification_rows([query_row()], [Ecto.UUID.t()]) :: [row()]
  defp notification_rows(rows, pool_ids) do
    impacted_pools_by_incident = impacted_pools_by_incident(rows, pool_ids)

    Enum.map(rows, fn {incident, receipt} ->
      %{
        id: incident.id,
        rule_kind: incident.rule_kind,
        severity: incident.severity,
        state: incident.state,
        impacted_pools: Map.get(impacted_pools_by_incident, incident.id, []),
        last_seen_at: incident.last_seen_at,
        unread?: Alerts.incident_notification_unread?(incident, receipt)
      }
    end)
  end

  @spec impacted_pools_by_incident([query_row()], [Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => [impacted_pool()]
        }
  defp impacted_pools_by_incident([], _pool_ids), do: %{}
  defp impacted_pools_by_incident(_rows, []), do: %{}

  defp impacted_pools_by_incident(rows, pool_ids) do
    incident_ids = rows |> Enum.map(fn {incident, _receipt} -> incident.id end) |> Enum.uniq()

    Repo.all(
      from target in AlertIncidentTarget,
        join: pool in Pool,
        on: pool.id == target.pool_id,
        where: target.incident_id in ^incident_ids and target.pool_id in ^pool_ids,
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

  @spec visible_pool_ids(Scope.t()) :: {:ok, [Ecto.UUID.t()]} | {:error, Alerts.access_error()}
  defp visible_pool_ids(scope) do
    case Alerts.list_manageable_pools(scope) do
      {:ok, pools} -> {:ok, Enum.map(pools, & &1.id)}
      {:error, _reason} = error -> error
    end
  end

  @spec visible_incident_states() :: [String.t()]
  defp visible_incident_states,
    do: [AlertIncident.open_state(), AlertIncident.acknowledged_state()]

  @spec empty_page_state() :: page_state()
  defp empty_page_state do
    %{
      rows: [],
      unread_count: 0,
      page_size: @page_size
    }
  end
end
