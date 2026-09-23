defmodule CodexPooler.Alerts.Incidents.NotificationEvents do
  @moduledoc false

  # Incidents are opened and resolved by the alert evaluation jobs on the worker
  # role, which is not in the app pods' PubSub cluster, so an invalidation also
  # travels as a PostgreSQL notification that every node's
  # `CodexPooler.Events.PostgresBridge` delivers to its own subscribers. The
  # origin still broadcasts through PubSub, and the notification names its node
  # so that a bridge on a node that PubSub already reached skips it.

  import Ecto.Query

  alias CodexPooler.Alerts.Schemas.{AlertIncident, AlertIncidentTarget}
  alias CodexPooler.Events
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL
  alias Phoenix.PubSub

  require Logger

  @pubsub CodexPooler.PubSub
  @message_tag __MODULE__
  @pool_topic_prefix "alert_notifications:pool:"
  @operator_topic_prefix "alert_notifications:operator:"
  @invalidation_message {@message_tag, :invalidated}
  @postgres_channel "codex_pooler_alert_notifications"
  @payload_version 1

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
    broadcast_invalidation("operator", operator_id)
  end

  @spec postgres_channel() :: String.t()
  def postgres_channel, do: @postgres_channel

  @doc """
  Encodes the PostgreSQL notification for one invalidated topic. `id` makes
  every invalidation distinct, so a bridge that received the same one from
  PostgreSQL and from a peer delivers it once.
  """
  @spec postgres_payload(String.t(), Ecto.UUID.t()) :: {:ok, String.t()} | {:error, term()}
  def postgres_payload(scope, target_id) when scope in ["pool", "operator"] and is_binary(target_id) do
    CodexPooler.JSON.encode(%{
      version: @payload_version,
      id: Ecto.UUID.generate(),
      scope: scope,
      target_id: target_id,
      origin_id: Events.origin_id(),
      origin_node: Atom.to_string(node())
    })
  end

  @doc """
  Delivers a relayed invalidation to the subscribers of its topic on this node
  only; every node's bridge relays its own copy.
  """
  @spec relay_payload(String.t()) :: :ok | {:error, :invalid_alert_notification}
  def relay_payload(payload) when is_binary(payload) do
    with {:ok, attrs} <- CodexPooler.JSON.decode(payload),
         {:ok, topic} <- relayed_topic(attrs) do
      PubSub.local_broadcast(@pubsub, topic, @invalidation_message)
    else
      _invalid -> {:error, :invalid_alert_notification}
    end
  end

  def relay_payload(_payload), do: {:error, :invalid_alert_notification}

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
      case broadcast_invalidation("pool", pool_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp broadcast_invalidation(scope, target_id) do
    with :ok <- PubSub.broadcast(@pubsub, topic(scope, target_id), @invalidation_message) do
      notify_postgres(scope, target_id)
    end
  end

  # A lost notification only leaves an unclustered node's pages stale until
  # their next reload, so a failed NOTIFY is logged and never fails the caller.
  defp notify_postgres(scope, target_id) do
    with {:ok, payload} <- postgres_payload(scope, target_id),
         {:ok, _result} <- SQL.query(Repo, "SELECT pg_notify($1, $2)", [@postgres_channel, payload]) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("alert notification postgres relay failed: #{inspect(reason)}")
        :ok
    end
  end

  defp relayed_topic(%{"version" => @payload_version, "id" => id, "scope" => scope, "target_id" => target_id})
       when is_binary(id) and scope in ["pool", "operator"] and is_binary(target_id) do
    case Ecto.UUID.cast(target_id) do
      {:ok, target_id} -> {:ok, topic(scope, target_id)}
      :error -> :error
    end
  end

  defp relayed_topic(_attrs), do: :error

  defp topic("pool", pool_id), do: pool_topic(pool_id)
  defp topic("operator", operator_id), do: operator_topic(operator_id)
end
