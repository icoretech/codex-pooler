defmodule CodexPooler.Events.DashboardSessions do
  @moduledoc false

  alias CodexPooler.Events
  alias CodexPooler.Events.Event
  alias Phoenix.PubSub

  @pubsub CodexPooler.PubSub
  @topic "dashboard_sessions"
  @topic_prefix "api_key_dashboard_sessions"

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(api_key_id) when is_binary(api_key_id) do
    PubSub.subscribe(@pubsub, pubsub_topic(api_key_id))
  end

  def subscribe(_api_key_id), do: {:error, :api_key_id_required}

  @spec unsubscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def unsubscribe(api_key_id) when is_binary(api_key_id) do
    PubSub.unsubscribe(@pubsub, pubsub_topic(api_key_id))
  end

  def unsubscribe(_api_key_id), do: {:error, :api_key_id_required}

  @spec pubsub_topic(Ecto.UUID.t()) :: String.t()
  def pubsub_topic(api_key_id) when is_binary(api_key_id) do
    @topic_prefix <> ":" <> api_key_id
  end

  @spec broadcast(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          map()
        ) :: Events.broadcast_result()
  def broadcast(pool_id, api_key_id, reason, payload)
      when is_binary(pool_id) and is_binary(api_key_id) and is_map(payload) do
    payload = Map.merge(payload, %{api_key_id: api_key_id, pool_id: pool_id})
    Events.broadcast_pool_event_after_commit(pool_id, [@topic], reason, payload)
  end

  @spec broadcast_local(Event.t(), term()) :: :ok | {:error, term()}
  def broadcast_local(%Event{topics: topics, payload: payload}, message) do
    if @topic in topics do
      case Map.get(payload, "api_key_id") do
        api_key_id when is_binary(api_key_id) ->
          PubSub.broadcast_from(@pubsub, self(), pubsub_topic(api_key_id), message)

        _missing_api_key_id ->
          {:error, :api_key_id_required}
      end
    else
      :ok
    end
  end
end
