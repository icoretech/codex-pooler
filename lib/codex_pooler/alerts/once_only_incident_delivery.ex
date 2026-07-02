defmodule CodexPooler.Alerts.OnceOnlyIncidentDelivery do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Alerts.Schemas.{
    AlertChannel,
    AlertDeliveryAttempt,
    AlertIncident,
    AlertIncidentTarget,
    AlertRule,
    AlertRuleChannel
  }

  alias CodexPooler.Repo

  @type payload :: %{
          required(:incident) => AlertIncident.t(),
          optional(:delivery_due?) => boolean(),
          optional(:delivery_channel_ids_due) => [Ecto.UUID.t()]
        }

  @alert_delivery_worker "CodexPooler.Jobs.AlertDeliveryWorker"

  @spec put_due_metadata({:ok, payload()} | {:error, term()}) ::
          {:ok, payload()} | {:error, term()}
  def put_due_metadata({:ok, %{incident: %AlertIncident{state: "resolved"}} = payload}) do
    {:ok, Map.merge(payload, %{delivery_due?: false, delivery_channel_ids_due: []})}
  end

  def put_due_metadata({:ok, payload}) do
    channel_ids_due =
      payload.incident
      |> active_channel_ids()
      |> MapSet.difference(delivery_recorded_channel_ids(payload.incident))
      |> MapSet.to_list()
      |> Enum.sort()

    {:ok,
     Map.merge(payload, %{
       delivery_due?: channel_ids_due != [],
       delivery_channel_ids_due: channel_ids_due
     })}
  end

  def put_due_metadata({:error, _reason} = error), do: error

  defp active_channel_ids(%AlertIncident{id: incident_id}) do
    Repo.all(
      from target in AlertIncidentTarget,
        join: rule in AlertRule,
        on: rule.id == target.rule_id,
        join: link in AlertRuleChannel,
        on: link.alert_rule_id == rule.id,
        join: channel in AlertChannel,
        on: channel.id == link.alert_channel_id,
        where:
          target.incident_id == ^incident_id and rule.state == "active" and
            channel.state == "active",
        distinct: true,
        select: channel.id
    )
    |> MapSet.new()
  end

  defp delivery_recorded_channel_ids(%AlertIncident{id: incident_id}) do
    incident_id
    |> attempted_channel_ids()
    |> MapSet.union(scheduled_channel_ids(incident_id))
  end

  defp attempted_channel_ids(incident_id) do
    Repo.all(
      from attempt in AlertDeliveryAttempt,
        where: attempt.incident_id == ^incident_id,
        distinct: true,
        select: attempt.channel_id
    )
    |> MapSet.new()
  end

  defp scheduled_channel_ids(incident_id) do
    Repo.all(
      from job in Oban.Job,
        where:
          job.worker == @alert_delivery_worker and
            fragment("?->>? = ?", job.args, "alert_incident_id", ^incident_id),
        distinct: true,
        select: fragment("?->>?", job.args, "alert_channel_id")
    )
    |> MapSet.new()
  end
end
