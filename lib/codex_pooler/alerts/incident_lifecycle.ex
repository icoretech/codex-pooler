defmodule CodexPooler.Alerts.IncidentLifecycle do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Alerts.IncidentMatchInput
  alias CodexPooler.Alerts.NotificationEvents

  alias CodexPooler.Alerts.Schemas.{
    AlertIncident,
    AlertIncidentTarget
  }

  alias CodexPooler.Alerts.OnceOnlyIncidentLifecycle
  alias CodexPooler.Repo

  @unresolved_states [AlertIncident.open_state(), AlertIncident.acknowledged_state()]

  @type match_attrs :: IncidentMatchInput.match_attrs()
  @type clear_attrs :: IncidentMatchInput.clear_attrs()
  @type lifecycle_error :: IncidentMatchInput.lifecycle_error()
  @type record_result ::
          {:ok, AlertIncident.t()} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  @type record_once_payload :: OnceOnlyIncidentLifecycle.record_once_payload()
  @type record_once_result :: OnceOnlyIncidentLifecycle.record_once_result()
  @type clear_result ::
          {:ok, AlertIncident.t() | nil} | {:error, Ecto.Changeset.t() | lifecycle_error()}

  @spec record_incident_match(match_attrs() | map()) :: record_result()
  def record_incident_match(attrs) when is_map(attrs) do
    with {:ok, match} <- IncidentMatchInput.normalize_match(attrs) do
      match
      |> record_incident_match_transaction()
      |> unwrap_transaction()
      |> maybe_broadcast_incident_invalidation()
    end
  end

  def record_incident_match(_attrs),
    do:
      {:error,
       IncidentMatchInput.lifecycle_error(
         :invalid_request,
         "incident match attributes must be a map"
       )}

  @spec record_incident_once(match_attrs() | map()) :: record_once_result()
  defdelegate record_incident_once(attrs), to: OnceOnlyIncidentLifecycle

  @spec clear_incident_condition(clear_attrs() | map() | String.t()) :: clear_result()
  def clear_incident_condition(dedupe_key) when is_binary(dedupe_key) do
    clear_incident_condition(%{dedupe_key: dedupe_key})
  end

  def clear_incident_condition(attrs) when is_map(attrs) do
    with {:ok, clear} <- IncidentMatchInput.normalize_clear(attrs) do
      clear
      |> clear_incident_condition_transaction()
      |> unwrap_transaction()
      |> maybe_broadcast_incident_invalidation()
    end
  end

  def clear_incident_condition(_attrs),
    do:
      {:error,
       IncidentMatchInput.lifecycle_error(
         :invalid_request,
         "incident clear attributes must be a map"
       )}

  defp record_incident_match_transaction(match) do
    Repo.transaction(fn -> record_incident_match_in_transaction(match) end)
  end

  defp record_incident_match_in_transaction(match) do
    match.dedupe_key
    |> unresolved_incident_for_update()
    |> record_match(match)
    |> rollback_on_error()
  end

  defp clear_incident_condition_transaction(clear) do
    Repo.transaction(fn -> clear_incident_condition_in_transaction(clear) end)
  end

  defp clear_incident_condition_in_transaction(clear) do
    case unresolved_incident_for_update(clear.dedupe_key) do
      %AlertIncident{} = incident -> resolve_incident(incident, clear.cleared_at)
      nil -> nil
    end
  end

  defp rollback_on_error({:ok, result}), do: result
  defp rollback_on_error({:error, reason}), do: Repo.rollback(reason)

  defp record_match(nil, match) do
    with {:ok, incident} <- insert_incident(match),
         {:ok, _targets} <- upsert_targets(incident, match.targets, match.matched_at) do
      {:ok, Repo.get!(AlertIncident, incident.id)}
    end
  end

  defp record_match(%AlertIncident{} = incident, match) do
    attrs = %{
      last_seen_at: match.matched_at,
      occurrence_count: incident.occurrence_count + 1,
      safe_evidence_snapshot: match.safe_evidence_snapshot,
      suppression_metadata: match.suppression_metadata,
      updated_at: match.matched_at
    }

    with {:ok, incident} <- incident |> AlertIncident.changeset(attrs) |> Repo.update(),
         {:ok, _targets} <- upsert_targets(incident, match.targets, match.matched_at) do
      {:ok, incident}
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

  defp upsert_targets(%AlertIncident{} = incident, targets, timestamp) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, acc} ->
      case upsert_target(incident, target, timestamp) do
        {:ok, target_row} -> {:cont, {:ok, [target_row | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_target(%AlertIncident{} = incident, target, timestamp) do
    case target_for_update(incident.id, target.rule_id, target.pool_id) do
      %AlertIncidentTarget{} = existing ->
        existing
        |> AlertIncidentTarget.changeset(%{
          last_matched_at: timestamp,
          resolved_at: nil,
          metadata: target.metadata,
          updated_at: timestamp
        })
        |> Repo.update()

      nil ->
        %AlertIncidentTarget{}
        |> AlertIncidentTarget.changeset(%{
          incident_id: incident.id,
          rule_id: target.rule_id,
          pool_id: target.pool_id,
          first_matched_at: timestamp,
          last_matched_at: timestamp,
          metadata: target.metadata,
          created_at: timestamp,
          updated_at: timestamp
        })
        |> Repo.insert()
    end
  end

  defp resolve_incident(%AlertIncident{} = incident, timestamp) do
    {_, _rows} =
      AlertIncidentTarget
      |> where([target], target.incident_id == ^incident.id and is_nil(target.resolved_at))
      |> Repo.update_all(set: [resolved_at: timestamp, updated_at: timestamp])

    incident
    |> AlertIncident.changeset(%{
      state: AlertIncident.resolved_state(),
      resolved_at: timestamp,
      updated_at: timestamp
    })
    |> Repo.update()
    |> case do
      {:ok, incident} -> incident
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp unresolved_incident_for_update(dedupe_key) do
    Repo.one(
      from incident in AlertIncident,
        where: incident.dedupe_key == ^dedupe_key and incident.state in ^@unresolved_states,
        order_by: [asc: incident.first_seen_at, asc: incident.id],
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  defp target_for_update(incident_id, rule_id, pool_id) do
    Repo.one(
      from target in AlertIncidentTarget,
        where:
          target.incident_id == ^incident_id and target.rule_id == ^rule_id and
            target.pool_id == ^pool_id,
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp maybe_broadcast_incident_invalidation({:ok, %AlertIncident{} = incident} = result) do
    _ = NotificationEvents.broadcast_incident_invalidation(incident)
    result
  end

  defp maybe_broadcast_incident_invalidation(result), do: result
end
