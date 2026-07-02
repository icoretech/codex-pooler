defmodule CodexPooler.Alerts.IncidentNotifications do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts.AuditLog, as: AlertAudit
  alias CodexPooler.Alerts.Authorization
  alias CodexPooler.Alerts.NotificationEvents

  alias CodexPooler.Alerts.Schemas.{
    AlertIncident,
    AlertIncidentReceipt,
    AlertIncidentTarget
  }

  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @type access_error :: Authorization.access_error()
  @type incident_ref :: AlertIncident.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type pool_target :: %{
          id: Ecto.UUID.t(),
          slug: String.t(),
          name: String.t()
        }
  @type incident_projection :: %{
          id: Ecto.UUID.t(),
          dedupe_key: String.t(),
          scope_type: String.t(),
          rule_kind: String.t(),
          severity: String.t(),
          state: String.t(),
          pool_id: Ecto.UUID.t() | nil,
          upstream_identity_id: Ecto.UUID.t() | nil,
          occurrence_count: non_neg_integer(),
          first_seen_at: DateTime.t(),
          last_seen_at: DateTime.t(),
          acknowledged_at: DateTime.t() | nil,
          resolved_at: DateTime.t() | nil,
          safe_evidence_snapshot: map(),
          suppression_metadata: map(),
          impacted_pools: [pool_target()],
          visible_impacted_pool_count: non_neg_integer(),
          hidden_impacted_pool_count: non_neg_integer(),
          total_impacted_pool_count: non_neg_integer(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }
  @type incident_result ::
          {:ok, incident_projection()} | {:error, Ecto.Changeset.t() | access_error()}
  @type notification_receipt_result ::
          {:ok, AlertIncidentReceipt.t()} | {:error, Ecto.Changeset.t() | access_error()}

  @spec list_incidents(term(), keyword()) ::
          {:ok, [incident_projection()]} | {:error, access_error()}
  def list_incidents(scope, opts \\ [])

  def list_incidents(%Scope{} = scope, opts) when is_list(opts) do
    with {:ok, pool_ids} <-
           Authorization.authorized_pool_filter(scope, Keyword.get(opts, :pool_id)) do
      incidents =
        incident_query(pool_ids, opts)
        |> Repo.all()
        |> incident_projections(pool_ids)

      {:ok, incidents}
    end
  end

  def list_incidents(_scope, _opts),
    do: {:error, Authorization.access_error(:invalid_request, "user scope is required")}

  @spec acknowledge_incident(term(), AlertIncident.t() | Ecto.UUID.t()) :: incident_result()
  def acknowledge_incident(scope, incident_or_id),
    do: transition_incident(scope, incident_or_id, :acknowledge)

  @spec resolve_incident(term(), AlertIncident.t() | Ecto.UUID.t()) :: incident_result()
  def resolve_incident(scope, incident_or_id),
    do: transition_incident(scope, incident_or_id, :resolve)

  @spec mark_incident_notification_read(term(), incident_ref()) :: notification_receipt_result()
  def mark_incident_notification_read(scope, incident_or_id) do
    scope
    |> upsert_incident_notification_receipt(incident_or_id, :read)
    |> maybe_broadcast_operator_notification_invalidation(scope)
  end

  @spec dismiss_incident_notification(term(), incident_ref()) :: notification_receipt_result()
  def dismiss_incident_notification(scope, incident_or_id) do
    scope
    |> upsert_incident_notification_receipt(incident_or_id, :dismiss)
    |> maybe_broadcast_operator_notification_invalidation(scope)
  end

  @spec dismiss_all_visible_incident_notifications(term()) ::
          {:ok, non_neg_integer()} | {:error, Ecto.Changeset.t() | access_error()}
  def dismiss_all_visible_incident_notifications(%Scope{} = scope) do
    with {:ok, operator_id} <- Authorization.scope_user_id(scope),
         {:ok, pool_ids} <- Authorization.authorized_pool_filter(scope, nil) do
      timestamp = now()

      Repo.transaction(fn ->
        dismiss_all_visible_incident_notifications_in_transaction(
          operator_id,
          pool_ids,
          timestamp
        )
      end)
      |> maybe_broadcast_operator_notification_invalidation(scope)
    end
  end

  def dismiss_all_visible_incident_notifications(_scope),
    do: {:error, Authorization.access_error(:invalid_request, "user scope is required")}

  @spec incident_notification_read?(AlertIncident.t(), AlertIncidentReceipt.t() | nil) ::
          boolean()
  def incident_notification_read?(%AlertIncident{}, nil), do: false

  def incident_notification_read?(%AlertIncident{} = incident, %AlertIncidentReceipt{
        read_at: read_at
      }) do
    timestamp_covers_incident?(read_at, incident.last_seen_at)
  end

  @spec incident_notification_unread?(AlertIncident.t(), AlertIncidentReceipt.t() | nil) ::
          boolean()
  def incident_notification_unread?(%AlertIncident{} = incident, receipt),
    do: not incident_notification_read?(incident, receipt)

  @spec incident_notification_dismissed?(AlertIncident.t(), AlertIncidentReceipt.t() | nil) ::
          boolean()
  def incident_notification_dismissed?(%AlertIncident{}, nil), do: false

  def incident_notification_dismissed?(%AlertIncident{} = incident, %AlertIncidentReceipt{
        dismissed_at: dismissed_at
      }) do
    timestamp_covers_incident?(dismissed_at, incident.last_seen_at)
  end

  @spec safe_projected_metadata_for_admin(map()) :: map()
  def safe_projected_metadata_for_admin(metadata), do: safe_projected_metadata(metadata)

  defp incident_query(pool_ids, opts) do
    state = Keyword.get(opts, :state)

    from(incident in AlertIncident, as: :incident)
    |> maybe_filter_incident_state(state)
    |> where(
      [incident],
      incident.pool_id in ^pool_ids or
        exists(
          from target in AlertIncidentTarget,
            where: target.incident_id == parent_as(:incident).id and target.pool_id in ^pool_ids,
            select: 1
        )
    )
    |> order_by([incident], desc: incident.last_seen_at, desc: incident.id)
  end

  defp bell_eligible_incidents_query_for_pool_ids(pool_ids) do
    from(incident in AlertIncident, as: :incident)
    |> where([incident], incident.state in ["open", "acknowledged"])
    |> where(
      [incident],
      exists(
        from target in AlertIncidentTarget,
          where: target.incident_id == parent_as(:incident).id and target.pool_id in ^pool_ids,
          select: 1
      )
    )
    |> order_by([incident], desc: incident.last_seen_at, desc: incident.id)
  end

  defp visible_incident_notifications_query(operator_id, pool_ids) do
    base_query = bell_eligible_incidents_query_for_pool_ids(pool_ids)

    from incident in base_query,
      left_join: receipt in AlertIncidentReceipt,
      on: receipt.operator_id == ^operator_id and receipt.incident_id == incident.id,
      where:
        is_nil(receipt.id) or is_nil(receipt.dismissed_at) or
          receipt.dismissed_at < incident.last_seen_at
  end

  defp maybe_filter_incident_state(query, nil), do: query

  defp maybe_filter_incident_state(query, state),
    do: from(incident in query, where: incident.state == ^state)

  defp transition_incident(%Scope{} = scope, incident_or_id, action) do
    with %AlertIncident{} = incident <- normalize_incident(incident_or_id),
         {:ok, pool_ids} <- Authorization.authorized_pool_filter(scope, nil),
         true <- incident_visible?(incident, pool_ids) do
      update_incident_transition(scope, incident, pool_ids, action)
    else
      nil -> {:error, incident_not_found_error()}
      false -> {:error, incident_not_found_error()}
      {:error, _reason} = error -> error
    end
  end

  defp transition_incident(_scope, _incident_or_id, _action),
    do: {:error, Authorization.access_error(:invalid_request, "user scope is required")}

  defp upsert_incident_notification_receipt(%Scope{} = scope, incident_or_id, action) do
    with {:ok, operator_id} <- Authorization.scope_user_id(scope),
         %AlertIncident{} = incident <- load_incident(incident_or_id),
         {:ok, pool_ids} <- Authorization.authorized_pool_filter(scope, nil),
         true <- bell_eligible_incident?(incident, pool_ids) do
      timestamp = now()
      attrs = receipt_attrs(operator_id, incident.id, action, timestamp)

      %AlertIncidentReceipt{}
      |> AlertIncidentReceipt.changeset(attrs)
      |> Repo.insert(
        on_conflict: [set: receipt_conflict_set(action, timestamp)],
        conflict_target: [:operator_id, :incident_id],
        returning: true
      )
    else
      nil -> {:error, incident_not_found_error()}
      false -> {:error, incident_not_found_error()}
      {:error, _reason} = error -> error
    end
  end

  defp upsert_incident_notification_receipt(_scope, _incident_or_id, _action),
    do: {:error, Authorization.access_error(:invalid_request, "user scope is required")}

  defp dismiss_all_visible_incident_notifications_in_transaction(operator_id, pool_ids, timestamp) do
    incident_ids =
      Repo.all(
        from incident in visible_incident_notifications_query(operator_id, pool_ids),
          select: incident.id
      )

    Enum.reduce_while(incident_ids, 0, fn incident_id, count ->
      attrs = receipt_attrs(operator_id, incident_id, :dismiss, timestamp)

      result =
        %AlertIncidentReceipt{}
        |> AlertIncidentReceipt.changeset(attrs)
        |> Repo.insert(
          on_conflict: [set: receipt_conflict_set(:dismiss, timestamp)],
          conflict_target: [:operator_id, :incident_id],
          returning: true
        )

      case result do
        {:ok, _receipt} -> {:cont, count + 1}
        {:error, reason} -> {:halt, Repo.rollback(reason)}
      end
    end)
  end

  defp receipt_attrs(operator_id, incident_id, :read, timestamp) do
    %{
      operator_id: operator_id,
      incident_id: incident_id,
      read_at: timestamp,
      created_at: timestamp,
      updated_at: timestamp
    }
  end

  defp receipt_attrs(operator_id, incident_id, :dismiss, timestamp) do
    %{
      operator_id: operator_id,
      incident_id: incident_id,
      read_at: timestamp,
      dismissed_at: timestamp,
      created_at: timestamp,
      updated_at: timestamp
    }
  end

  defp receipt_conflict_set(:read, timestamp), do: [read_at: timestamp, updated_at: timestamp]

  defp receipt_conflict_set(:dismiss, timestamp),
    do: [read_at: timestamp, dismissed_at: timestamp, updated_at: timestamp]

  defp load_incident(incident_or_id) do
    case incident_id(incident_or_id) do
      {:ok, incident_id} -> Repo.get(AlertIncident, incident_id)
      {:error, _reason} -> nil
    end
  end

  defp bell_eligible_incident?(%AlertIncident{id: incident_id, state: state}, pool_ids)
       when state in ["open", "acknowledged"] do
    Repo.exists?(
      from target in AlertIncidentTarget,
        where: target.incident_id == ^incident_id and target.pool_id in ^pool_ids
    )
  end

  defp bell_eligible_incident?(%AlertIncident{}, _pool_ids), do: false

  defp incident_not_found_error,
    do: Authorization.access_error(:incident_not_found, "alert incident was not found")

  defp update_incident_transition(scope, incident, pool_ids, action) do
    attrs = incident_transition_attrs(action, now())

    Repo.transaction(fn ->
      update_incident_transition_in_transaction(incident, attrs, pool_ids)
    end)
    |> AlertAudit.audit_incident_transition(scope, incident, action)
    |> maybe_broadcast_incident_projection_invalidation()
  end

  defp update_incident_transition_in_transaction(incident, attrs, pool_ids) do
    case incident |> AlertIncident.changeset(attrs) |> Repo.update() do
      {:ok, updated_incident} -> incident_projection(updated_incident, pool_ids)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp normalize_incident(%AlertIncident{} = incident), do: incident
  defp normalize_incident(id) when is_binary(id), do: Repo.get(AlertIncident, id)
  defp normalize_incident(_id), do: nil

  defp incident_transition_attrs(:acknowledge, timestamp),
    do: %{state: "acknowledged", acknowledged_at: timestamp, updated_at: timestamp}

  defp incident_transition_attrs(:resolve, timestamp),
    do: %{state: "resolved", resolved_at: timestamp, updated_at: timestamp}

  defp timestamp_covers_incident?(nil, _last_seen_at), do: false

  defp timestamp_covers_incident?(%DateTime{} = timestamp, %DateTime{} = last_seen_at),
    do: DateTime.compare(timestamp, last_seen_at) in [:gt, :eq]

  defp timestamp_covers_incident?(_timestamp, _last_seen_at), do: false

  defp incident_visible?(%AlertIncident{pool_id: pool_id}, pool_ids) when is_binary(pool_id),
    do: pool_id in pool_ids

  defp incident_visible?(%AlertIncident{id: incident_id}, pool_ids) do
    Repo.exists?(
      from target in AlertIncidentTarget,
        where: target.incident_id == ^incident_id and target.pool_id in ^pool_ids
    )
  end

  defp incident_projections(incidents, pool_ids),
    do: Enum.map(incidents, &incident_projection(&1, pool_ids))

  defp incident_projection(%AlertIncident{} = incident, pool_ids) do
    pool_targets = incident.id |> incident_pool_targets() |> Enum.uniq_by(& &1.pool_id)
    visible_targets = Enum.filter(pool_targets, &(&1.pool_id in pool_ids))
    total_count = length(pool_targets)
    visible_count = length(visible_targets)

    %{
      id: incident.id,
      dedupe_key: incident.dedupe_key,
      scope_type: incident.scope_type,
      rule_kind: incident.rule_kind,
      severity: incident.severity,
      state: incident.state,
      pool_id: incident.pool_id,
      upstream_identity_id: incident.upstream_identity_id,
      occurrence_count: incident.occurrence_count,
      first_seen_at: incident.first_seen_at,
      last_seen_at: incident.last_seen_at,
      acknowledged_at: incident.acknowledged_at,
      resolved_at: incident.resolved_at,
      safe_evidence_snapshot: incident.safe_evidence_snapshot || %{},
      suppression_metadata: incident.suppression_metadata || %{},
      impacted_pools: Enum.map(visible_targets, &pool_target_projection/1),
      visible_impacted_pool_count: visible_count,
      hidden_impacted_pool_count: max(total_count - visible_count, 0),
      total_impacted_pool_count: total_count,
      created_at: incident.created_at,
      updated_at: incident.updated_at
    }
  end

  defp incident_pool_targets(incident_id) do
    Repo.all(
      from target in AlertIncidentTarget,
        join: pool in Pool,
        on: pool.id == target.pool_id,
        where: target.incident_id == ^incident_id,
        order_by: [asc: pool.created_at, asc: pool.id],
        select: %{pool_id: pool.id, pool_slug: pool.slug, pool_name: pool.name}
    )
  end

  defp pool_target_projection(target),
    do: %{id: target.pool_id, slug: target.pool_slug, name: target.pool_name}

  defp maybe_broadcast_operator_notification_invalidation(
         {:ok, _value} = result,
         %Scope{user: %{id: operator_id}}
       )
       when is_binary(operator_id) do
    _ = NotificationEvents.broadcast_operator_invalidation(operator_id)
    result
  end

  defp maybe_broadcast_operator_notification_invalidation(result, _scope), do: result

  defp maybe_broadcast_incident_projection_invalidation({:ok, %{id: incident_id}} = result)
       when is_binary(incident_id) do
    _ = NotificationEvents.broadcast_incident_invalidation(incident_id)
    result
  end

  defp maybe_broadcast_incident_projection_invalidation(result), do: result

  defp safe_projected_metadata(%{} = metadata), do: Accounting.sanitize_metadata(metadata)
  defp safe_projected_metadata(_metadata), do: %{}

  defp incident_id(%AlertIncident{id: id}) when is_binary(id), do: {:ok, id}
  defp incident_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp incident_id(id) when is_binary(id), do: {:ok, id}
  defp incident_id(_incident_or_id), do: {:error, :alert_incident_id_required}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
