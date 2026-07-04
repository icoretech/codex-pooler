defmodule CodexPooler.Alerts.Delivery.DeliveryScheduling do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Alerts.Delivery.AttemptLifecycle
  alias CodexPooler.Alerts.Delivery.EmailDelivery
  alias CodexPooler.Alerts.Delivery.WebhookDelivery

  alias CodexPooler.Alerts.Schemas.{
    AlertChannel,
    AlertDeliveryAttempt,
    AlertIncident,
    AlertIncidentTarget,
    AlertRule,
    AlertRuleChannel
  }

  alias CodexPooler.Repo

  @type incident_ref :: AlertIncident.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type incident_delivery_channel :: %{
          channel_id: Ecto.UUID.t(),
          cooldown_minutes: pos_integer()
        }

  @spec deliver_incident_to_channel(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), keyword()) ::
          {:ok, AlertDeliveryAttempt.t()}
          | {:error, EmailDelivery.delivery_error() | WebhookDelivery.delivery_error()}
  def deliver_incident_to_channel(incident_id, channel_id, attempt_number, opts \\ []) do
    case Repo.get(AlertChannel, channel_id) do
      %AlertChannel{channel_type: "webhook"} ->
        WebhookDelivery.deliver_incident_to_channel(incident_id, channel_id, attempt_number, opts)

      _channel ->
        EmailDelivery.deliver_incident_to_channel(incident_id, channel_id, attempt_number, opts)
    end
  end

  @spec list_incident_delivery_channels_due(incident_ref(), keyword()) :: [
          incident_delivery_channel()
        ]
  def list_incident_delivery_channels_due(incident_or_id, opts \\ []) do
    case incident_id(incident_or_id) do
      {:ok, incident_id} ->
        timestamp = timestamp(opts)

        incident_id
        |> linked_active_delivery_channels()
        |> Enum.reject(&recent_sent_attempt_within_cooldown?(incident_id, &1, timestamp))

      {:error, _reason} ->
        []
    end
  end

  @spec next_delivery_attempt_number(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) :: pos_integer()
  def next_delivery_attempt_number(incident_id, channel_id, oban_attempt)
      when is_binary(incident_id) and is_binary(channel_id) and is_integer(oban_attempt) and
             oban_attempt > 0 do
    last_attempt_number =
      Repo.one(
        from attempt in AlertDeliveryAttempt,
          where: attempt.incident_id == ^incident_id and attempt.channel_id == ^channel_id,
          select: max(attempt.attempt_number)
      )

    max(oban_attempt, (last_attempt_number || 0) + 1)
  end

  def next_delivery_attempt_number(_incident_id, _channel_id, oban_attempt)
      when is_integer(oban_attempt) and oban_attempt > 0,
      do: oban_attempt

  def next_delivery_attempt_number(_incident_id, _channel_id, _oban_attempt), do: 1

  defp linked_active_delivery_channels(incident_id) do
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
        group_by: [channel.id, channel.created_at],
        order_by: [asc: channel.created_at, asc: channel.id],
        select: %{channel_id: channel.id, cooldown_minutes: max(rule.cooldown_minutes)}
    )
  end

  defp recent_sent_attempt_within_cooldown?(incident_id, delivery_channel, timestamp) do
    AttemptLifecycle.sent_attempt_within_cooldown?(
      incident_id,
      delivery_channel.channel_id,
      delivery_channel.cooldown_minutes,
      timestamp
    )
  end

  defp timestamp(opts) when is_list(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = timestamp -> DateTime.truncate(timestamp, :microsecond)
      _value -> now()
    end
  end

  defp timestamp(_opts), do: now()

  defp incident_id(%AlertIncident{id: id}) when is_binary(id), do: {:ok, id}
  defp incident_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp incident_id(id) when is_binary(id), do: {:ok, id}
  defp incident_id(_incident_or_id), do: {:error, :alert_incident_id_required}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
