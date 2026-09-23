defmodule CodexPooler.Alerts.Incidents.NotificationEvents do
  @moduledoc false

  # Incidents are opened and resolved by the alert evaluation jobs on the worker
  # role, which is not in the app pods' PubSub cluster, so an invalidation also
  # travels as a PostgreSQL notification that every node's
  # `CodexPooler.Events.PostgresBridge` delivers to its own subscribers. The
  # origin still broadcasts through PubSub, and the notification names its node
  # so that a bridge on a node that PubSub already reached skips it.
  #
  # One invalidation reaches a page once per topic it shares with it: an
  # incident on an identity shared by several Pools invalidates each of them.
  # Every copy names the invalidation, so a page reloads once per invalidation
  # (findings#206 row 206-270).

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
  @postgres_channel "codex_pooler_alert_notifications"
  @payload_version 1

  @type pool_ref :: AlertIncident.t() | Ecto.UUID.t()
  @type operator_ref :: Ecto.UUID.t()
  @type broadcast_result :: :ok | {:error, term()}
  @type invalidation_id :: String.t()
  @type invalidation_message :: {module(), :invalidated, invalidation_id()}

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
    invalidation_id = Ecto.UUID.generate()

    incident_id
    |> impacted_pool_ids()
    |> broadcast_pool_invalidations(invalidation_id)
  end

  @spec broadcast_operator_invalidation(operator_ref()) :: broadcast_result()
  def broadcast_operator_invalidation(operator_id) when is_binary(operator_id) do
    broadcast_invalidation("operator", operator_id, Ecto.UUID.generate())
  end

  @spec postgres_channel() :: String.t()
  def postgres_channel, do: @postgres_channel

  @doc """
  Encodes the PostgreSQL notification for one invalidated topic. `id` makes
  every notification distinct, so a bridge that received the same one from
  PostgreSQL and from a peer delivers it once; `invalidation_id` is shared by
  the notifications of one invalidation, so a page reloads once for all of them.
  """
  @spec postgres_payload(String.t(), Ecto.UUID.t(), invalidation_id()) :: {:ok, String.t()} | {:error, term()}
  def postgres_payload(scope, target_id, invalidation_id)
      when scope in ["pool", "operator"] and is_binary(target_id) and is_binary(invalidation_id) do
    CodexPooler.JSON.encode(%{
      version: @payload_version,
      id: Ecto.UUID.generate(),
      invalidation_id: invalidation_id,
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
         {:ok, topic} <- relayed_topic(attrs),
         {:ok, invalidation_id} <- relayed_invalidation_id(attrs) do
      PubSub.local_broadcast(@pubsub, topic, invalidation_message(invalidation_id))
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

  defp broadcast_pool_invalidations(pool_ids, invalidation_id) do
    Enum.reduce_while(pool_ids, :ok, fn pool_id, :ok ->
      case broadcast_invalidation("pool", pool_id, invalidation_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp broadcast_invalidation(scope, target_id, invalidation_id) do
    with :ok <- PubSub.broadcast(@pubsub, topic(scope, target_id), invalidation_message(invalidation_id)) do
      notify_postgres(scope, target_id, invalidation_id)
    end
  end

  @spec invalidation_message(invalidation_id()) :: invalidation_message()
  defp invalidation_message(invalidation_id), do: {@message_tag, :invalidated, invalidation_id}

  # A lost notification only leaves an unclustered node's pages stale until
  # their next reload, so a failed NOTIFY is logged and never fails the caller.
  defp notify_postgres(scope, target_id, invalidation_id) do
    with {:ok, payload} <- postgres_payload(scope, target_id, invalidation_id),
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

  # A notification from a node that predates invalidation ids is an
  # invalidation of its own.
  defp relayed_invalidation_id(%{"invalidation_id" => invalidation_id}) do
    case Ecto.UUID.cast(invalidation_id) do
      {:ok, invalidation_id} -> {:ok, invalidation_id}
      :error -> :error
    end
  end

  defp relayed_invalidation_id(%{"id" => id}), do: {:ok, id}

  defp topic("pool", pool_id), do: pool_topic(pool_id)
  defp topic("operator", operator_id), do: operator_topic(operator_id)
end
