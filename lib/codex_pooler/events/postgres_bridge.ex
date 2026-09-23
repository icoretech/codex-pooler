defmodule CodexPooler.Events.PostgresBridge do
  @moduledoc false

  # Relays the PostgreSQL notifications of pool events, OpenAI status events
  # and alert notification invalidations to this node's PubSub subscribers.
  #
  # Every node runs one bridge, and each delivers what it relays on its own
  # node only. A notification whose origin node is in this node's PubSub
  # cluster is skipped, because the origin's PubSub broadcast already reached
  # this node. Every other notification is delivered here and also handed to
  # the bridges of the PubSub cluster, so a notification one node's connection
  # lost still reaches its pages through a peer. A notification from
  # PostgreSQL and a peer's copy of it are delivered once, whichever arrives
  # first; two notifications from PostgreSQL are always both delivered.
  #
  # A notification that raises while it is relayed (a decoder or subscriber
  # bug) is logged and skipped: the bridge keeps its state and relays the next
  # one, instead of exiting and losing every notification queued behind it
  # until its supervisor restarts it and it listens again (findings#206 row
  # 206-303).

  use GenServer

  alias CodexPooler.Alerts.Incidents.NotificationEvents
  alias CodexPooler.Events
  alias CodexPooler.Events.Event
  alias CodexPooler.Status.Events, as: StatusEvents
  alias Phoenix.PubSub

  require Logger

  @notifications CodexPooler.Events.PostgresNotifications
  @pubsub CodexPooler.PubSub
  @peer_topic "postgres_bridge:relayed"
  @relisten_initial_interval_ms 100
  @relisten_max_interval_ms 5_000
  @delivered_limit 4_096
  @delivered_ttl_ms 30_000

  @type state :: %{
          required(:notifications) => GenServer.server(),
          required(:listen_ref) => reference() | nil,
          required(:status_listen_ref) => reference() | nil,
          required(:alert_listen_ref) => reference() | nil,
          required(:notifications_monitor) => reference() | nil,
          required(:relisten_token) => reference() | nil,
          required(:relisten_attempt) => non_neg_integer(),
          required(:pubsub_nodes) => (-> [node()]),
          required(:relays) => %{optional(String.t()) => (String.t() -> :ok | {:error, term()})},
          required(:delivered) => %{optional(binary()) => {:postgres | :peer, integer()}},
          required(:delivered_order) => :queue.queue({binary(), integer()}),
          required(:delivered_count) => non_neg_integer()
        }

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts) do
    opts = if Keyword.keyword?(opts), do: opts, else: []
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec peer_topic() :: String.t()
  def peer_topic, do: @peer_topic

  @spec relay_payload(String.t()) :: :ok | {:error, term()}
  def relay_payload(payload) when is_binary(payload) do
    with {:ok, event} <- decode_event(payload) do
      Events.deliver_relayed_event(event)
    end
  end

  @impl true
  def init(opts) do
    :ok = PubSub.subscribe(@pubsub, @peer_topic)

    state = %{
      notifications: Keyword.get(opts, :notifications, @notifications),
      listen_ref: nil,
      status_listen_ref: nil,
      alert_listen_ref: nil,
      notifications_monitor: nil,
      relisten_token: nil,
      relisten_attempt: 0,
      pubsub_nodes: Keyword.get(opts, :pubsub_nodes, &pubsub_peer_nodes/0),
      relays: Map.merge(default_relays(), Map.new(Keyword.get(opts, :relays, %{}))),
      delivered: %{},
      delivered_order: :queue.new(),
      delivered_count: 0
    }

    {:ok, listen(state)}
  end

  @impl true
  def handle_info({:notification, _pid, listen_ref, channel, payload}, state) when is_reference(listen_ref) do
    {:noreply, guarded_relay(state, channel, fn -> relay_notification(channel_for(listen_ref, state), channel, payload, state) end)}
  end

  # A peer's bridge relayed a notification it received from PostgreSQL. It is
  # delivered here unless this bridge already delivered a copy of it, and it is
  # never handed on again.
  def handle_info({__MODULE__, :relayed, channel, payload}, state) when is_binary(channel) and is_binary(payload) do
    {:noreply, guarded_relay(state, channel, fn -> relay_peer_copy(state, channel, payload) end)}
  end

  # The notifications process sent every notification it relayed before it
  # exited, so they are already handled by the clauses above when this arrives.
  # Its supervisor restarts it under the same name with no listeners, and
  # nothing tells a listener, so the bridge listens again itself; a restarted
  # process that is not registered yet is retried with a capped backoff.
  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, %{notifications_monitor: monitor_ref} = state) do
    Logger.warning("postgres event relay lost its notifications listener; listening again reason=#{exit_reason_label(reason)}")

    {:noreply, relisten(%{state | listen_ref: nil, status_listen_ref: nil, alert_listen_ref: nil, notifications_monitor: nil})}
  end

  def handle_info({__MODULE__, :relisten, token}, %{relisten_token: token, notifications_monitor: nil} = state) do
    {:noreply, relisten(%{state | relisten_token: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The log names only the channel and the kind of failure: the payload and
  # the exception can carry ids and are never logged.
  defp guarded_relay(state, channel, relay) do
    relay.()
  catch
    kind, _reason ->
      Logger.error("postgres event relay skipped a notification that raised channel=#{channel_label(channel, state)} kind=#{kind}")
      state
  end

  defp channel_label(channel, %{relays: relays}) when is_map_key(relays, channel), do: channel
  defp channel_label(_channel, _state), do: "unknown"

  # A registration this bridge no longer holds maps to no channel and relays
  # nothing, as does a channel other than the one the registration was for.
  defp channel_for(listen_ref, %{listen_ref: listen_ref}), do: Events.postgres_channel()
  defp channel_for(listen_ref, %{status_listen_ref: listen_ref}), do: StatusEvents.postgres_channel()
  defp channel_for(listen_ref, %{alert_listen_ref: listen_ref}), do: NotificationEvents.postgres_channel()
  defp channel_for(_listen_ref, _state), do: nil

  defp relay_notification(channel, channel, payload, state) do
    case origin(payload) do
      {:ok, origin_id, origin_node} ->
        if reached_by_origin?(origin_id, origin_node, state) do
          state
        else
          relay_new_notification(state, channel, payload)
        end

      {:error, reason} ->
        log_ignored(channel, reason)
        state
    end
  end

  defp relay_notification(_expected_channel, _channel, _payload, state), do: state

  # This node's own notification, or one from a node whose PubSub broadcast
  # already reached this node. Status notifications carry no origin: their
  # producer broadcasts through PostgreSQL only.
  defp reached_by_origin?(origin_id, origin_node, state) do
    origin_id == Events.origin_id() or
      (is_binary(origin_node) and Enum.any?(state.pubsub_nodes.(), &(Atom.to_string(&1) == origin_node)))
  end

  # The other nodes whose PubSub server has joined this node's PubSub group,
  # which the origin's cluster-wide broadcast reaches. A node that is only
  # connected (a remote shell, a VM sharing just the database) is not one of
  # them. Anything unexpected reads as no node, so the notification is
  # delivered rather than lost.
  defp pubsub_peer_nodes do
    Phoenix.PubSub
    |> :pg.get_members(Module.concat(@pubsub, "Adapter"))
    |> Enum.map(&node/1)
    |> Enum.reject(&(&1 == node()))
  catch
    _kind, _reason -> []
  end

  defp origin(payload) do
    case CodexPooler.JSON.decode(payload) do
      {:ok, %{} = attrs} -> {:ok, attrs["origin_id"], attrs["origin_node"]}
      {:ok, _other} -> {:error, :invalid_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  # A notification from PostgreSQL is delivered unless a peer's copy of it was
  # delivered first; a repeated identical notification is delivered again.
  # Only what it delivers is handed to the peers.
  defp relay_new_notification(state, channel, payload) do
    key = delivery_key(channel, payload)
    now = System.monotonic_time(:millisecond)

    case recent_delivery(state, key, now) do
      :peer ->
        remember_delivery(state, key, :postgres, now)

      _none_or_postgres ->
        case deliver(state, channel, payload) do
          :ok ->
            _ = PubSub.broadcast_from(@pubsub, self(), @peer_topic, {__MODULE__, :relayed, channel, payload})
            remember_delivery(state, key, :postgres, now)

          {:error, reason} ->
            log_ignored(channel, reason)
            state
        end
    end
  end

  defp relay_peer_copy(state, channel, payload) do
    key = delivery_key(channel, payload)
    now = System.monotonic_time(:millisecond)

    case recent_delivery(state, key, now) do
      nil ->
        case deliver(state, channel, payload) do
          :ok -> :ok
          {:error, reason} -> log_ignored(channel, reason)
        end

        remember_delivery(state, key, :peer, now)

      _delivered ->
        state
    end
  end

  defp delivery_key(channel, payload), do: :crypto.hash(:sha256, [channel, 0, payload])

  defp recent_delivery(state, key, now) do
    case state.delivered do
      %{^key => {source, at}} when now - at <= @delivered_ttl_ms -> source
      _unknown_or_expired -> nil
    end
  end

  defp remember_delivery(state, key, source, now) do
    prune_deliveries(
      %{
        state
        | delivered: Map.put(state.delivered, key, {source, now}),
          delivered_order: :queue.in({key, now}, state.delivered_order),
          delivered_count: state.delivered_count + 1
      },
      now
    )
  end

  defp prune_deliveries(state, now) do
    case :queue.peek(state.delivered_order) do
      {:value, {key, at}} when now - at > @delivered_ttl_ms or state.delivered_count > @delivered_limit ->
        delivered =
          case state.delivered do
            %{^key => {_source, ^at}} -> Map.delete(state.delivered, key)
            delivered -> delivered
          end

        prune_deliveries(
          %{state | delivered: delivered, delivered_order: :queue.drop(state.delivered_order), delivered_count: state.delivered_count - 1},
          now
        )

      _within_bounds ->
        state
    end
  end

  defp deliver(state, channel, payload) do
    case state.relays do
      %{^channel => relay} -> relay.(payload)
      _unknown -> {:error, :unknown_channel}
    end
  end

  # Tests replace a channel's relay through the `:relays` option.
  defp default_relays do
    %{
      Events.postgres_channel() => &relay_payload/1,
      StatusEvents.postgres_channel() => &StatusEvents.relay_payload/1,
      NotificationEvents.postgres_channel() => &NotificationEvents.relay_payload/1
    }
  end

  defp log_ignored(channel, reason) do
    Logger.warning("postgres event relay ignored payload channel=#{channel} reason=#{inspect(reason)}")
  end

  defp decode_event(payload) do
    with {:ok, attrs} <- CodexPooler.JSON.decode(payload),
         {:ok, emitted_at} <- decode_emitted_at(attrs["emitted_at"]),
         {:ok, topics} <- decode_topics(attrs["topics"]),
         {:ok, payload} <- decode_payload(attrs["payload"]),
         {:ok, version} <- decode_version(attrs["version"]),
         pool_id when is_binary(pool_id) <- attrs["pool_id"],
         id when is_binary(id) <- attrs["id"],
         reason when is_binary(reason) <- attrs["reason"] do
      {:ok,
       %Event{
         version: version,
         id: id,
         pool_id: pool_id,
         topics: topics,
         reason: reason,
         emitted_at: emitted_at,
         payload: payload
       }}
    else
      nil -> {:error, :invalid_event_payload}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_event_payload}
    end
  end

  defp decode_emitted_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, timestamp}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_emitted_at(_value), do: {:error, :invalid_emitted_at}

  defp decode_topics(topics) do
    case Events.validate_topics(topics) do
      {:ok, _validated_topics} -> {:ok, topics}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_payload(payload) when is_map(payload), do: {:ok, payload}
  defp decode_payload(_payload), do: {:error, :invalid_payload}

  defp decode_version(version) when is_integer(version) and version > 0, do: {:ok, version}
  defp decode_version(_version), do: {:error, :invalid_version}

  defp relisten(state) do
    case listen(state) do
      %{notifications_monitor: monitor_ref} = listening when is_reference(monitor_ref) ->
        Logger.info("postgres event relay listening again retries=#{state.relisten_attempt}")
        listening

      waiting ->
        waiting
    end
  end

  # One registration per channel on the current notifications process: the
  # state keeps only the refs of the last successful listen, and a listen runs
  # only while none is held, so a relayed notification is never delivered twice.
  defp listen(%{notifications_monitor: nil} = state) do
    case GenServer.whereis(state.notifications) do
      pid when is_pid(pid) -> listen_on(state, pid)
      _unavailable -> schedule_relisten(state)
    end
  end

  defp listen_on(state, pid) do
    monitor_ref = Process.monitor(pid)

    with {:ok, listen_ref} <- listen_channel(pid, Events.postgres_channel()),
         {:ok, status_listen_ref} <- listen_channel(pid, StatusEvents.postgres_channel(), [listen_ref]),
         {:ok, alert_listen_ref} <- listen_channel(pid, NotificationEvents.postgres_channel(), [listen_ref, status_listen_ref]) do
      %{
        state
        | listen_ref: listen_ref,
          status_listen_ref: status_listen_ref,
          alert_listen_ref: alert_listen_ref,
          notifications_monitor: monitor_ref,
          relisten_token: nil,
          relisten_attempt: 0
      }
    else
      :error ->
        Process.demonitor(monitor_ref, [:flush])
        schedule_relisten(state)
    end
  end

  defp listen_channel(pid, channel, previous_refs \\ []) do
    case Postgrex.Notifications.listen(pid, channel) do
      {:ok, listen_ref} -> {:ok, listen_ref}
      {:eventually, listen_ref} -> {:ok, listen_ref}
    end
  catch
    :exit, _reason ->
      Enum.each(previous_refs, &unlisten(pid, &1))
      :error
  end

  # A listen that failed after earlier channels succeeded drops those
  # registrations, so the retry does not leave a second one behind.
  defp unlisten(pid, listen_ref) do
    Postgrex.Notifications.unlisten(pid, listen_ref)
  catch
    :exit, _reason -> :error
  end

  defp schedule_relisten(state) do
    attempt = state.relisten_attempt + 1
    delay_ms = min(@relisten_initial_interval_ms * Integer.pow(2, min(attempt - 1, 10)), @relisten_max_interval_ms)
    token = make_ref()
    Process.send_after(self(), {__MODULE__, :relisten, token}, delay_ms)
    %{state | relisten_token: token, relisten_attempt: attempt}
  end

  defp exit_reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp exit_reason_label({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp exit_reason_label(_reason), do: "other"
end
