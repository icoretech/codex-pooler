defmodule CodexPooler.Events do
  @moduledoc """
  Phoenix PubSub events for pool-scoped UI invalidation.

  The event keeps the source invalidation fields (`version`, `id`, `pool_id`,
  `topics`, `reason`, and `emitted_at`) and adds a Phoenix-native `payload` map
  for LiveViews that need deterministic selector updates, such as job status.
  """

  alias CodexPooler.Events.DashboardSessions, as: DashboardSessionEvents
  alias CodexPooler.Events.Event
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL
  alias Phoenix.PubSub

  require Logger

  @pubsub CodexPooler.PubSub
  @message_tag __MODULE__
  @topic_prefix "pool_events"
  @all_topic @topic_prefix <> ":all"
  @postgres_channel "codex_pooler_events"

  @request_logs "request_logs"
  @usage "usage"
  @job_status "job_status"
  @model_sync "model_sync"
  @pools "pools"
  @upstreams "upstreams"
  @dashboard_sessions "dashboard_sessions"
  @topics [
    @request_logs,
    @usage,
    @job_status,
    @model_sync,
    @pools,
    @upstreams,
    @dashboard_sessions
  ]

  @type topic :: String.t()
  @type topics :: [topic()] | topic()
  @type pool_ref :: Pool.t() | Ecto.UUID.t()
  @type reason :: String.t()
  @type payload :: map()
  @type broadcast_result :: {:ok, Event.t()} | {:error, term()}
  @type subscription_topics :: :all | MapSet.t(topic())

  @spec topics() :: [topic()]
  def topics, do: @topics

  @spec subscribe_pool(pool_ref()) :: :ok | {:error, term()}
  def subscribe_pool(pool_or_id) do
    pool_or_id
    |> pool_id()
    |> case do
      nil -> {:error, :pool_id_required}
      pool_id -> PubSub.subscribe(@pubsub, pubsub_topic(pool_id))
    end
  end

  @spec subscribe_pool(pool_ref(), topics()) :: :ok | {:error, term()}
  def subscribe_pool(pool_or_id, topics) do
    with pool_id when is_binary(pool_id) <- pool_id(pool_or_id),
         {:ok, topics} <- validate_topics(topics) do
      subscribe_topics(pool_id, topics)
    else
      nil -> {:error, :pool_id_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec unsubscribe_pool(pool_ref()) :: :ok | {:error, term()}
  def unsubscribe_pool(pool_or_id) do
    pool_or_id
    |> pool_id()
    |> case do
      nil -> {:error, :pool_id_required}
      pool_id -> PubSub.unsubscribe(@pubsub, pubsub_topic(pool_id))
    end
  end

  @spec unsubscribe_pool(pool_ref(), topics()) :: :ok | {:error, term()}
  def unsubscribe_pool(pool_or_id, topics) do
    with pool_id when is_binary(pool_id) <- pool_id(pool_or_id),
         {:ok, topics} <- validate_topics(topics) do
      unsubscribe_topics(pool_id, topics)
    else
      nil -> {:error, :pool_id_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec subscribe_all_pools() :: :ok | {:error, term()}
  def subscribe_all_pools do
    PubSub.subscribe(@pubsub, @all_topic)
  end

  @spec subscribe_dashboard_sessions(Ecto.UUID.t()) :: :ok | {:error, term()}
  defdelegate subscribe_dashboard_sessions(api_key_id),
    to: DashboardSessionEvents,
    as: :subscribe

  @spec unsubscribe_dashboard_sessions(Ecto.UUID.t()) :: :ok | {:error, term()}
  defdelegate unsubscribe_dashboard_sessions(api_key_id),
    to: DashboardSessionEvents,
    as: :unsubscribe

  @spec dashboard_sessions_pubsub_topic(Ecto.UUID.t()) :: String.t()
  defdelegate dashboard_sessions_pubsub_topic(api_key_id),
    to: DashboardSessionEvents,
    as: :pubsub_topic

  @spec broadcast_request_logs(pool_ref(), reason(), payload()) :: broadcast_result()
  def broadcast_request_logs(pool_or_id, reason, payload \\ %{}) do
    broadcast_pool_event(pool_or_id, [@request_logs], reason, payload)
  end

  @spec broadcast_usage(pool_ref(), reason(), payload()) :: broadcast_result()
  def broadcast_usage(pool_or_id, reason, payload \\ %{}) do
    broadcast_pool_event(pool_or_id, [@usage], reason, payload)
  end

  @spec broadcast_job_status(pool_ref(), reason(), payload()) :: broadcast_result()
  def broadcast_job_status(pool_or_id, reason \\ "job_status_updated", payload \\ %{}) do
    broadcast_pool_event(pool_or_id, [@job_status], reason, payload)
  end

  @spec broadcast_model_sync(pool_ref(), reason(), payload()) :: broadcast_result()
  def broadcast_model_sync(pool_or_id, reason, payload \\ %{}) do
    broadcast_pool_event(pool_or_id, [@model_sync], reason, payload)
  end

  @spec broadcast_pools(pool_ref(), reason(), payload()) :: broadcast_result()
  def broadcast_pools(pool_or_id, reason, payload \\ %{}) do
    broadcast_pool_event(pool_or_id, [@pools], reason, payload)
  end

  @spec broadcast_model_serving_modes_updated_after_commit(pool_ref(), non_neg_integer()) ::
          broadcast_result() | :noop
  def broadcast_model_serving_modes_updated_after_commit(_pool_or_id, 0), do: :noop

  def broadcast_model_serving_modes_updated_after_commit(pool_or_id, changed_count)
      when is_integer(changed_count) and changed_count > 0 do
    broadcast_pool_event_after_commit(pool_or_id, [@pools], "pool_updated", %{
      changed: ["model_serving_modes"],
      changed_count: changed_count
    })
  end

  @spec broadcast_upstreams(pool_ref(), reason(), payload()) :: broadcast_result()
  def broadcast_upstreams(pool_or_id, reason, payload \\ %{}) do
    broadcast_pool_event(pool_or_id, [@upstreams], reason, payload)
  end

  @spec broadcast_upstreams_after_commit(pool_ref(), reason(), payload()) :: broadcast_result()
  def broadcast_upstreams_after_commit(pool_or_id, reason, payload \\ %{}) do
    broadcast_pool_event(pool_or_id, [@upstreams], reason, payload, :after_commit)
  end

  @spec broadcast_dashboard_sessions(
          pool_ref(),
          Ecto.UUID.t(),
          reason(),
          payload()
        ) :: broadcast_result()
  defdelegate broadcast_dashboard_sessions(pool_or_id, api_key_id, reason, payload \\ %{}),
    to: DashboardSessionEvents,
    as: :broadcast

  @spec broadcast_pool_event(pool_ref(), topics(), reason(), payload()) :: broadcast_result()
  def broadcast_pool_event(pool_or_id, topics, reason, payload \\ %{}) do
    broadcast_pool_event(pool_or_id, topics, reason, payload, :immediate)
  end

  @spec broadcast_pool_event_after_commit(pool_ref(), topics(), reason(), payload()) ::
          broadcast_result()
  def broadcast_pool_event_after_commit(pool_or_id, topics, reason, payload \\ %{}) do
    broadcast_pool_event(pool_or_id, topics, reason, payload, :after_commit)
  end

  defp broadcast_pool_event(pool_or_id, topics, reason, payload, delivery) do
    with pool_id when is_binary(pool_id) <- pool_id(pool_or_id),
         {:ok, topics} <- normalize_topics(topics),
         {:ok, reason} <- normalize_reason(reason) do
      event = %Event{
        version: 1,
        id: Ecto.UUID.generate(),
        pool_id: pool_id,
        topics: topics,
        reason: reason,
        emitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        payload: normalize_payload(payload)
      }

      broadcast_event(event, delivery)
    else
      nil -> {:error, :pool_id_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec all_pubsub_topic() :: String.t()
  def all_pubsub_topic, do: @all_topic

  @spec postgres_channel() :: String.t()
  def postgres_channel, do: @postgres_channel

  @spec origin_id() :: String.t()
  def origin_id do
    case :persistent_term.get({__MODULE__, :origin_id}, nil) do
      origin_id when is_binary(origin_id) ->
        origin_id

      nil ->
        origin_id = System.get_env("POD_NAME") || Ecto.UUID.generate()
        :persistent_term.put({__MODULE__, :origin_id}, origin_id)
        origin_id
    end
  end

  @spec message_tag() :: module()
  def message_tag, do: @message_tag

  @spec pubsub_topic(pool_ref()) :: String.t() | nil
  def pubsub_topic(pool_or_id) do
    case pool_id(pool_or_id) do
      nil -> nil
      pool_id -> @topic_prefix <> ":" <> pool_id
    end
  end

  @spec pubsub_topic(pool_ref(), topic()) :: String.t() | {:error, term()}
  def pubsub_topic(pool_or_id, topic) do
    with pool_id when is_binary(pool_id) <- pool_id(pool_or_id),
         {:ok, [topic]} <- validate_topics(topic) do
      scoped_pubsub_topic(pool_id, topic)
    else
      nil -> {:error, :pool_id_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate_topics(topics()) :: {:ok, [topic()]} | {:error, :invalid_topics}
  def validate_topics(topic) when is_binary(topic), do: validate_topics([topic])

  def validate_topics(topics) when is_list(topics) do
    if topics != [] and Enum.all?(topics, &(is_binary(&1) and &1 in @topics)) do
      {:ok, Enum.uniq(topics)}
    else
      {:error, :invalid_topics}
    end
  end

  def validate_topics(_topics), do: {:error, :invalid_topics}

  @spec broadcast_local_event(Event.t()) :: :ok | {:error, term()}
  def broadcast_local_event(%Event{} = event) do
    message = {@message_tag, event}

    with :ok <- PubSub.broadcast_from(@pubsub, self(), pubsub_topic(event.pool_id), message),
         :ok <- broadcast_scoped_topics(event, message),
         :ok <- DashboardSessionEvents.broadcast_local(event, message) do
      PubSub.broadcast_from(@pubsub, self(), @all_topic, message)
    end
  end

  @spec event_to_postgres_payload(Event.t()) :: {:ok, String.t()} | {:error, term()}
  def event_to_postgres_payload(%Event{} = event) do
    event_to_postgres_payload(event, origin_id())
  end

  defp event_to_postgres_payload(%Event{} = event, event_origin_id) do
    event
    |> Map.from_struct()
    |> Map.update!(:emitted_at, &DateTime.to_iso8601/1)
    |> Map.put(:origin_id, event_origin_id)
    |> Jason.encode()
  end

  defp normalize_topics(topics), do: validate_topics(topics)

  defp normalize_reason(reason) when is_binary(reason) do
    reason = String.trim(reason)
    if reason == "", do: {:error, :reason_required}, else: {:ok, reason}
  end

  defp normalize_reason(_reason), do: {:error, :reason_required}

  defp normalize_payload(payload) when is_map(payload) do
    Map.new(payload, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_payload(_payload), do: %{}

  defp broadcast_event(%Event{} = event, :after_commit) do
    if Repo.in_transaction?() do
      broadcast_transactional_event(event)
    else
      broadcast_immediate_event(event)
    end
  end

  defp broadcast_event(%Event{} = event, :immediate), do: broadcast_immediate_event(event)

  defp broadcast_transactional_event(%Event{} = event) do
    with :ok <- broadcast_postgres_event(event, "transaction:" <> event.id) do
      {:ok, event}
    end
  end

  defp broadcast_immediate_event(%Event{} = event) do
    with :ok <- broadcast_local_event(event),
         :ok <- broadcast_postgres_event(event, origin_id()) do
      {:ok, event}
    end
  end

  defp pool_id(%{id: id}) when is_binary(id), do: id
  defp pool_id(id) when is_binary(id), do: String.trim(id)
  defp pool_id(_pool_or_id), do: nil

  defp subscribe_topics(pool_id, topics) do
    Enum.reduce_while(topics, :ok, fn topic, :ok ->
      case PubSub.subscribe(@pubsub, scoped_pubsub_topic(pool_id, topic)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp unsubscribe_topics(pool_id, topics) do
    Enum.each(topics, fn topic ->
      :ok = PubSub.unsubscribe(@pubsub, scoped_pubsub_topic(pool_id, topic))
    end)

    :ok
  end

  defp broadcast_scoped_topics(%Event{} = event, message) do
    Enum.reduce_while(event.topics, :ok, fn topic, :ok ->
      case PubSub.broadcast_from(
             @pubsub,
             self(),
             scoped_pubsub_topic(event.pool_id, topic),
             message
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp scoped_pubsub_topic(pool_id, topic), do: pubsub_topic(pool_id) <> ":" <> topic

  defp broadcast_postgres_event(%Event{} = event, event_origin_id) do
    with {:ok, payload} <- event_to_postgres_payload(event, event_origin_id),
         {:ok, _result} <-
           SQL.query(Repo, "SELECT pg_notify($1, $2)", [@postgres_channel, payload]) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("pool event postgres relay failed: #{inspect(reason)}")
        :ok
    end
  end
end
