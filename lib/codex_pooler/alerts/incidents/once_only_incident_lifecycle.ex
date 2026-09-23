defmodule CodexPooler.Alerts.Incidents.OnceOnlyIncidentLifecycle do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Alerts.Incidents.{
    IncidentMatchInput,
    NotificationEvents,
    OnceOnlyIncidentDelivery,
    OnceOnlyIncidentTargets
  }

  alias CodexPooler.Alerts.Schemas.{AlertIncident, AlertIncidentTarget}

  alias CodexPooler.Repo

  @latest_first_seen_key "latest_reset_first_seen_at"
  @superseded_reason "newer_saved_reset_first_seen"

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

  # The dedupe key names the upstream identity, not a grant, so the incident
  # history of the key is the record of which grants already alerted. A match
  # whose newest first-seen time is later than the newest incident's is a grant
  # nobody was told about: it opens a new incident (superseding an unresolved
  # one) and becomes due on every linked channel. Anything else is the same
  # grant again, whatever happened to the incident, and never delivers twice
  # (findings#260 row 260-30).
  defp record_incident_once_in_transaction(match) do
    :ok = advisory_lock_once_event(match.dedupe_key)

    incident = latest_incident_for_update(match.dedupe_key)

    incident
    |> record_once_or_new_grant(match)
    |> OnceOnlyIncidentDelivery.put_due_metadata()
    |> rollback_on_error()
  end

  defp record_once_or_new_grant(nil, match), do: record_once(nil, match)

  defp record_once_or_new_grant(%AlertIncident{} = incident, match) do
    if newer_grant?(match, incident) do
      with {:ok, _superseded} <- supersede_unresolved(incident, match.matched_at) do
        record_once(nil, match)
      end
    else
      record_once(incident, match)
    end
  end

  defp newer_grant?(match, %AlertIncident{} = incident) do
    with {:ok, matched} <- latest_first_seen_at(match.safe_evidence_snapshot),
         {:ok, alerted} <- latest_first_seen_at(incident.safe_evidence_snapshot) do
      DateTime.compare(matched, alerted) == :gt
    else
      :error -> false
    end
  end

  defp latest_first_seen_at(%{} = evidence) do
    with value when is_binary(value) <- Map.get(evidence, @latest_first_seen_key),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      {:ok, datetime}
    else
      _missing_or_malformed -> :error
    end
  end

  defp latest_first_seen_at(_evidence), do: :error

  defp supersede_unresolved(%AlertIncident{state: "resolved"} = incident, _timestamp), do: {:ok, incident}

  defp supersede_unresolved(%AlertIncident{} = incident, timestamp) do
    {_count, _rows} =
      AlertIncidentTarget
      |> where([target], target.incident_id == ^incident.id and is_nil(target.resolved_at))
      |> Repo.update_all(set: [resolved_at: timestamp, updated_at: timestamp])

    incident
    |> AlertIncident.changeset(%{
      state: AlertIncident.resolved_state(),
      resolved_at: timestamp,
      suppression_metadata: Map.put(incident.suppression_metadata || %{}, "superseded_reason", @superseded_reason),
      updated_at: timestamp
    })
    |> Repo.update()
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

  defp latest_incident_for_update(dedupe_key) do
    Repo.one(
      from incident in AlertIncident,
        where: incident.dedupe_key == ^dedupe_key,
        order_by: [
          asc: fragment("CASE WHEN ? = 'resolved' THEN 1 ELSE 0 END", incident.state),
          desc: incident.first_seen_at,
          desc: incident.id
        ],
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

  defp maybe_broadcast_incident_invalidation({:ok, %{incident: %AlertIncident{} = incident}} = result) do
    _ = NotificationEvents.broadcast_incident_invalidation(incident)
    result
  end

  defp maybe_broadcast_incident_invalidation(result), do: result
end
