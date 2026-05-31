defmodule CodexPooler.Alerts.IncidentLifecycle do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Alerts.NotificationEvents
  alias CodexPooler.Alerts.Schemas.{AlertIncident, AlertIncidentTarget}
  alias CodexPooler.Repo

  @unresolved_states [AlertIncident.open_state(), AlertIncident.acknowledged_state()]
  @input_keys ~w(
    dedupe_key scope_type rule_kind severity pool_id upstream_identity_id matched_at observed_at
    safe_evidence_snapshot suppression_metadata targets rule_id metadata cleared_at
  )a

  @type target_input :: %{
          required(:rule_id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          optional(:metadata) => map()
        }
  @type match_attrs :: %{
          required(:dedupe_key) => String.t(),
          required(:scope_type) => AlertIncident.scope_type(),
          required(:rule_kind) => AlertIncident.rule_kind(),
          required(:severity) => AlertIncident.severity(),
          optional(:pool_id) => Ecto.UUID.t(),
          optional(:upstream_identity_id) => Ecto.UUID.t(),
          optional(:safe_evidence_snapshot) => map(),
          optional(:suppression_metadata) => map(),
          required(:targets) => [target_input()],
          optional(:matched_at) => DateTime.t()
        }
  @type clear_attrs :: %{
          required(:dedupe_key) => String.t(),
          optional(:cleared_at) => DateTime.t()
        }
  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type record_result ::
          {:ok, AlertIncident.t()} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  @type clear_result ::
          {:ok, AlertIncident.t() | nil} | {:error, Ecto.Changeset.t() | lifecycle_error()}

  @spec record_incident_match(match_attrs() | map()) :: record_result()
  def record_incident_match(attrs) when is_map(attrs) do
    with {:ok, match} <- normalize_match(attrs) do
      match
      |> record_incident_match_transaction()
      |> unwrap_transaction()
      |> maybe_broadcast_incident_invalidation()
    end
  end

  def record_incident_match(_attrs),
    do: {:error, lifecycle_error(:invalid_request, "incident match attributes must be a map")}

  @spec clear_incident_condition(clear_attrs() | map() | String.t()) :: clear_result()
  def clear_incident_condition(dedupe_key) when is_binary(dedupe_key) do
    clear_incident_condition(%{dedupe_key: dedupe_key})
  end

  def clear_incident_condition(attrs) when is_map(attrs) do
    with {:ok, clear} <- normalize_clear(attrs) do
      clear
      |> clear_incident_condition_transaction()
      |> unwrap_transaction()
      |> maybe_broadcast_incident_invalidation()
    end
  end

  def clear_incident_condition(_attrs),
    do: {:error, lifecycle_error(:invalid_request, "incident clear attributes must be a map")}

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

  defp normalize_match(attrs) do
    attrs = atomized_attrs(attrs)
    timestamp = timestamp_attr(attrs, :matched_at) || timestamp_attr(attrs, :observed_at) || now()

    with {:ok, dedupe_key} <- required_string(attrs, :dedupe_key, "dedupe key is required"),
         {:ok, scope_type} <- allowed_string(attrs, :scope_type, AlertIncident.scope_types()),
         {:ok, rule_kind} <- allowed_string(attrs, :rule_kind, AlertIncident.rule_kinds()),
         {:ok, severity} <- allowed_string(attrs, :severity, AlertIncident.severities()),
         {:ok, scope_ids} <- scope_ids(scope_type, attrs),
         {:ok, targets} <- normalize_targets(Map.get(attrs, :targets), timestamp) do
      {:ok,
       Map.merge(scope_ids, %{
         dedupe_key: dedupe_key,
         scope_type: scope_type,
         rule_kind: rule_kind,
         severity: severity,
         safe_evidence_snapshot: safe_metadata_map(Map.get(attrs, :safe_evidence_snapshot, %{})),
         suppression_metadata: safe_metadata_map(Map.get(attrs, :suppression_metadata, %{})),
         targets: targets,
         matched_at: timestamp
       })}
    end
  end

  defp normalize_clear(attrs) do
    attrs = atomized_attrs(attrs)

    with {:ok, dedupe_key} <- required_string(attrs, :dedupe_key, "dedupe key is required") do
      {:ok, %{dedupe_key: dedupe_key, cleared_at: timestamp_attr(attrs, :cleared_at) || now()}}
    end
  end

  defp scope_ids("pool", attrs) do
    with {:ok, pool_id} <- required_string(attrs, :pool_id, "pool id is required") do
      {:ok, %{pool_id: pool_id, upstream_identity_id: nil}}
    end
  end

  defp scope_ids("upstream_identity", attrs) do
    with {:ok, upstream_identity_id} <-
           required_string(attrs, :upstream_identity_id, "upstream identity id is required") do
      {:ok, %{pool_id: nil, upstream_identity_id: upstream_identity_id}}
    end
  end

  defp normalize_targets(targets, _timestamp) when is_list(targets) and targets != [] do
    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      case normalize_target(target) do
        {:ok, target} -> {:cont, {:ok, [target | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, targets} ->
        {:ok, targets |> Enum.reverse() |> Enum.uniq_by(&{&1.rule_id, &1.pool_id})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_targets(_targets, _timestamp),
    do: {:error, lifecycle_error(:invalid_request, "incident targets must be a non-empty list")}

  defp normalize_target(target) when is_map(target) do
    target = atomized_attrs(target)

    with {:ok, rule_id} <- required_string(target, :rule_id, "target rule id is required"),
         {:ok, pool_id} <- required_string(target, :pool_id, "target pool id is required") do
      {:ok,
       %{
         rule_id: rule_id,
         pool_id: pool_id,
         metadata: safe_metadata_map(Map.get(target, :metadata, %{}))
       }}
    end
  end

  defp normalize_target(_target),
    do: {:error, lifecycle_error(:invalid_request, "incident target must be a map")}

  defp allowed_string(attrs, key, allowed) do
    with {:ok, value} <- required_string(attrs, key, "#{key} is required") do
      if value in allowed do
        {:ok, value}
      else
        {:error, lifecycle_error(:invalid_request, "#{key} is invalid")}
      end
    end
  end

  defp required_string(attrs, key, message) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, lifecycle_error(:invalid_request, message)}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:error, lifecycle_error(:invalid_request, message)}
    end
  end

  defp safe_metadata_map(value) when is_map(value) do
    case Accounting.sanitize_metadata(value) do
      sanitized when is_map(sanitized) -> sanitized
      _value -> %{}
    end
  end

  defp safe_metadata_map(_value), do: %{}

  defp timestamp_attr(attrs, key) do
    case Map.get(attrs, key) do
      %DateTime{} = timestamp -> DateTime.truncate(timestamp, :microsecond)
      _value -> nil
    end
  end

  defp atomized_attrs(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      case normalize_key(key) do
        key when is_atom(key) -> Map.put(acc, key, value)
        nil -> acc
      end
    end)
  end

  defp normalize_key(key) when is_atom(key) and key in @input_keys, do: key

  defp normalize_key(key) when is_binary(key) do
    Enum.find(@input_keys, &(Atom.to_string(&1) == key))
  end

  defp normalize_key(_key), do: nil

  defp lifecycle_error(code, message), do: %{code: code, message: message}
  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp maybe_broadcast_incident_invalidation({:ok, %AlertIncident{} = incident} = result) do
    _ = NotificationEvents.broadcast_incident_invalidation(incident)
    result
  end

  defp maybe_broadcast_incident_invalidation(result), do: result

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
