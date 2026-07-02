defmodule CodexPooler.Alerts.OnceOnlyIncidentTargets do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Alerts.Schemas.{AlertIncident, AlertIncidentTarget}
  alias CodexPooler.Repo

  @type target_input :: CodexPooler.Alerts.IncidentMatchInput.target_input()

  @spec insert_missing(AlertIncident.t(), [target_input()], DateTime.t()) ::
          {:ok, [AlertIncidentTarget.t()]} | {:error, Ecto.Changeset.t()}
  def insert_missing(%AlertIncident{} = incident, targets, timestamp) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, acc} ->
      case insert_missing_target(incident, target, timestamp) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, target_row} -> {:cont, {:ok, [target_row | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_missing_target(%AlertIncident{} = incident, target, timestamp) do
    case target_for_update(incident.id, target.rule_id, target.pool_id) do
      %AlertIncidentTarget{} ->
        {:ok, nil}

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
end
