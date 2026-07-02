defmodule CodexPooler.Alerts.OnceOnlyIncidentLifecycle do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Alerts.{
    IncidentMatchInput,
    NotificationEvents,
    OnceOnlyIncidentDelivery,
    OnceOnlyIncidentTargets
  }

  alias CodexPooler.Alerts.Schemas.AlertIncident

  alias CodexPooler.Repo

  @type match_attrs :: IncidentMatchInput.match_attrs()
  @type lifecycle_error :: IncidentMatchInput.lifecycle_error()
  @type record_once_payload :: %{
          required(:incident) => AlertIncident.t(),
          required(:inserted?) => boolean(),
          required(:target_inserted?) => boolean(),
          required(:delivery_due?) => boolean(),
          required(:delivery_channel_ids_due) => [Ecto.UUID.t()]
        }
  @type record_once_result ::
          {:ok, record_once_payload()} | {:error, Ecto.Changeset.t() | lifecycle_error()}

  @spec record_incident_once(match_attrs() | map()) :: record_once_result()
  def record_incident_once(attrs) when is_map(attrs) do
    with {:ok, match} <- IncidentMatchInput.normalize_match(attrs) do
      match
      |> record_incident_once_transaction()
      |> unwrap_transaction()
      |> maybe_broadcast_incident_invalidation()
    end
  end

  def record_incident_once(_attrs),
    do:
      {:error,
       IncidentMatchInput.lifecycle_error(
         :invalid_request,
         "incident match attributes must be a map"
       )}

  defp record_incident_once_transaction(match) do
    Repo.transaction(fn -> record_incident_once_in_transaction(match) end)
  end

  defp record_incident_once_in_transaction(match) do
    :ok = advisory_lock_once_event(match.dedupe_key)

    incident = all_state_incident_for_update(match.dedupe_key)

    incident
    |> record_once(match)
    |> OnceOnlyIncidentDelivery.put_due_metadata()
    |> rollback_on_error()
  end

  defp rollback_on_error({:ok, result}), do: result
  defp rollback_on_error({:error, reason}), do: Repo.rollback(reason)

  defp record_once(nil, match) do
    with {:ok, incident} <- insert_incident(match),
         {:ok, inserted_targets} <-
           OnceOnlyIncidentTargets.insert_missing(incident, match.targets, match.matched_at) do
      {:ok,
       %{
         incident: Repo.get!(AlertIncident, incident.id),
         inserted?: true,
         target_inserted?: inserted_targets != []
       }}
    end
  end

  defp record_once(%AlertIncident{} = incident, match) do
    with {:ok, inserted_targets} <-
           OnceOnlyIncidentTargets.insert_missing(incident, match.targets, match.matched_at) do
      {:ok,
       %{
         incident: incident,
         inserted?: false,
         target_inserted?: inserted_targets != []
       }}
    end
  end

  defp insert_incident(match) do
    %AlertIncident{}
    |> AlertIncident.changeset(%{
      dedupe_key: match.dedupe_key,
      scope_type: match.scope_type,
      rule_kind: match.rule_kind,
      severity: match.severity,
      state: AlertIncident.open_state(),
      pool_id: match.pool_id,
      upstream_identity_id: match.upstream_identity_id,
      occurrence_count: 1,
      first_seen_at: match.matched_at,
      last_seen_at: match.matched_at,
      safe_evidence_snapshot: match.safe_evidence_snapshot,
      suppression_metadata: match.suppression_metadata,
      created_at: match.matched_at,
      updated_at: match.matched_at
    })
    |> Repo.insert()
  end

  defp all_state_incident_for_update(dedupe_key) do
    Repo.one(
      from incident in AlertIncident,
        where: incident.dedupe_key == ^dedupe_key,
        order_by: [asc: incident.first_seen_at, asc: incident.id],
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  defp advisory_lock_once_event(dedupe_key) do
    _result = Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [dedupe_key])
    :ok
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp maybe_broadcast_incident_invalidation(
         {:ok, %{incident: %AlertIncident{} = incident}} = result
       ) do
    _ = NotificationEvents.broadcast_incident_invalidation(incident)
    result
  end

  defp maybe_broadcast_incident_invalidation(result), do: result
end
