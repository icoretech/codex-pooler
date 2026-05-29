defmodule CodexPooler.Events do
  @moduledoc """
  Phoenix PubSub events for pool-scoped UI invalidation.

  The event keeps the source invalidation fields (`version`, `id`, `pool_id`,
  `topics`, `reason`, and `emitted_at`) and adds a Phoenix-native `payload` map
  for LiveViews that need deterministic selector updates, such as job status.
  """

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
  @topics [@request_logs, @usage, @job_status, @model_sync, @pools, @upstreams]

  @type topic :: String.t()
  @type topics :: [topic()] | topic()
  @type pool_ref :: Pool.t() | Ecto.UUID.t()
  @type reason :: String.t()
  @type payload :: map()
  @type broadcast_result :: {:ok, Event.t()} | {:error, term()}

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

  @spec subscribe_all_pools() :: :ok | {:error, term()}
  def subscribe_all_pools do
    PubSub.subscribe(@pubsub, @all_topic)
  end

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

  @spec broadcast_upstreams(pool_ref(), reason(), payload()) :: broadcast_result()
  def broadcast_upstreams(pool_or_id, reason, payload \\ %{}) do
    broadcast_pool_event(pool_or_id, [@upstreams], reason, payload)
  end

  @spec broadcast_pool_event(pool_ref(), topics(), reason(), payload()) :: broadcast_result()
  def broadcast_pool_event(pool_or_id, topics, reason, payload \\ %{}) do
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

      with :ok <- broadcast_local_event(event),
           :ok <- broadcast_postgres_event(event) do
        {:ok, event}
      end
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

  @spec broadcast_local_event(Event.t()) :: :ok | {:error, term()}
  def broadcast_local_event(%Event{} = event) do
    message = {@message_tag, event}

    case PubSub.broadcast_from(@pubsub, self(), pubsub_topic(event.pool_id), message) do
      :ok -> PubSub.broadcast_from(@pubsub, self(), @all_topic, message)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec event_to_postgres_payload(Event.t()) :: {:ok, String.t()} | {:error, term()}
  def event_to_postgres_payload(%Event{} = event) do
    event
    |> Map.from_struct()
    |> Map.update!(:emitted_at, &DateTime.to_iso8601/1)
    |> Map.put(:origin_id, origin_id())
    |> Jason.encode()
  end

  defp normalize_topics(topic) when is_binary(topic), do: normalize_topics([topic])

  defp normalize_topics(topics) when is_list(topics) do
    topics = topics |> Enum.map(&to_string/1) |> Enum.uniq()

    if topics != [] and Enum.all?(topics, &(&1 in @topics)) do
      {:ok, topics}
    else
      {:error, :invalid_topics}
    end
  end

  defp normalize_topics(_topics), do: {:error, :invalid_topics}

  defp normalize_reason(reason) when is_binary(reason) do
    reason = String.trim(reason)
    if reason == "", do: {:error, :reason_required}, else: {:ok, reason}
  end

  defp normalize_reason(_reason), do: {:error, :reason_required}

  defp normalize_payload(payload) when is_map(payload) do
    Map.new(payload, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_payload(_payload), do: %{}

  defp pool_id(%{id: id}) when is_binary(id), do: id
  defp pool_id(id) when is_binary(id), do: String.trim(id)
  defp pool_id(_pool_or_id), do: nil

  defp broadcast_postgres_event(%Event{} = event) do
    with {:ok, payload} <- event_to_postgres_payload(event),
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
