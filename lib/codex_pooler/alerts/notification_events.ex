defmodule CodexPooler.Alerts.NotificationEvents do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Alerts.Schemas.{AlertIncident, AlertIncidentTarget}
  alias CodexPooler.Repo
  alias Phoenix.PubSub

  @pubsub CodexPooler.PubSub
  @message_tag __MODULE__
  @pool_topic_prefix "alert_notifications:pool:"
  @operator_topic_prefix "alert_notifications:operator:"
  @invalidation_message {@message_tag, :invalidated}

  @type pool_ref :: AlertIncident.t() | Ecto.UUID.t()
  @type operator_ref :: Ecto.UUID.t()
  @type broadcast_result :: :ok | {:error, term()}

  @spec subscribe_pool(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe_pool(pool_id) when is_binary(pool_id) do
    PubSub.subscribe(@pubsub, pool_topic(pool_id))
  end

  @spec subscribe_operator(operator_ref()) :: :ok | {:error, term()}
  def subscribe_operator(operator_id) when is_binary(operator_id) do
    PubSub.subscribe(@pubsub, operator_topic(operator_id))
  end

  @spec broadcast_incident_invalidation(pool_ref()) :: broadcast_result()
  def broadcast_incident_invalidation(%AlertIncident{id: incident_id}) do
    broadcast_incident_invalidation(incident_id)
  end

  def broadcast_incident_invalidation(incident_id) when is_binary(incident_id) do
    incident_id
    |> impacted_pool_ids()
    |> broadcast_pool_invalidations()
  end

  @spec broadcast_operator_invalidation(operator_ref()) :: broadcast_result()
  def broadcast_operator_invalidation(operator_id) when is_binary(operator_id) do
    PubSub.broadcast(@pubsub, operator_topic(operator_id), @invalidation_message)
  end

  @spec pool_topic(Ecto.UUID.t()) :: String.t()
  def pool_topic(pool_id) when is_binary(pool_id), do: @pool_topic_prefix <> pool_id

  @spec operator_topic(operator_ref()) :: String.t()
  def operator_topic(operator_id) when is_binary(operator_id),
    do: @operator_topic_prefix <> operator_id

  @spec message_tag() :: module()
  def message_tag, do: @message_tag

  defp impacted_pool_ids(incident_id) do
    Repo.all(
      from target in AlertIncidentTarget,
        where: target.incident_id == ^incident_id,
        distinct: true,
        select: target.pool_id
    )
  end

  defp broadcast_pool_invalidations(pool_ids) do
    Enum.reduce_while(pool_ids, :ok, fn pool_id, :ok ->
      case PubSub.broadcast(@pubsub, pool_topic(pool_id), @invalidation_message) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
