defmodule CodexPooler.Events.PostgresBridgeTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Alerts.Incidents.NotificationEvents
  alias CodexPooler.Events
  alias CodexPooler.Events.{Event, PostgresBridge}
  alias CodexPooler.Repo
  alias CodexPooler.Status.Events, as: StatusEvents

  # Named detection budget for a NOTIFY committed on another connection to come
  # back through the notifications process, the bridge and PubSub; the green
  # path finishes on the relayed message.
  @relay_detection_timeout_ms 15_000

  setup do
    # The application bridge listens on the same database channels and would
    # relay every NOTIFY of this test a second time, so it stays suspended while
    # the test-owned bridge is the only relay. Resuming it later relays what it
    # queued to subscribers that no longer exist.
    on_exit(fn -> resume_application_bridge() end)
    :ok = :sys.suspend(PostgresBridge)

    suffix = System.unique_integer([:positive])
    notifications = :"postgres_bridge_test_notifications_#{suffix}"
    bridge = :"postgres_bridge_test_bridge_#{suffix}"
    sender = start_supervised!(%{id: :sender, start: {Postgrex, :start_link, [connection_config()]}})

    %{notifications: notifications, bridge_name: bridge, sender: sender}
  end

  test "listens again after its notifications process is restarted under the same name", ctx do
    first = start_notifications!(ctx, :permanent)
    bridge = start_bridge!(ctx)
    pool_id = subscribe!()

    assert_relays_once!(ctx, bridge, pool_id, "before_restart", 1)

    monitor_ref = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^first, :killed}, @relay_detection_timeout_ms

    # The test supervisor restarts it under the same name, as the application
    # supervisor does in production.
    restarted = await_registered!(ctx.notifications, first)
    await_bridge_listening!(bridge, restarted)

    assert_relays_once!(ctx, bridge, pool_id, "after_restart", 2)
  end

  test "retries the listen until a notifications process is registered again", ctx do
    first = start_notifications!(ctx, :temporary)
    bridge = start_bridge!(ctx)
    pool_id = subscribe!()

    monitor_ref = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^first, :killed}, @relay_detection_timeout_ms

    # Nothing restarts a temporary child, so the bridge's first listen after the
    # exit finds no process and must keep retrying on its own.
    await_retry_pending!(bridge)
    refute GenServer.whereis(ctx.notifications)

    replacement = start_notifications!(ctx, :temporary, :replacement)
    await_bridge_listening!(bridge, replacement)

    assert_relays_once!(ctx, bridge, pool_id, "after_replacement", 3)
  end

  test "skips a notification whose origin node reached this node through PubSub", ctx do
    notifications = start_notifications!(ctx, :permanent)
    peer = :"postgres-bridge-test-peer@127.0.0.1"
    bridge = start_bridge!(ctx, pubsub_nodes: fn -> [peer] end)
    await_bridge_listening!(bridge, notifications)
    pool_id = subscribe!()

    {event, payload} = remote_pool_event(pool_id, "from_connected_peer", Atom.to_string(peer))
    {marker, marker_payload} = remote_pool_event(pool_id, "from_unclustered_node", "postgres-bridge-test-worker@127.0.0.1")
    notify!(ctx.sender, Events.postgres_channel(), payload)
    notify!(ctx.sender, Events.postgres_channel(), marker_payload)

    assert_receive {Events, ^marker}, @relay_detection_timeout_ms
    refute_received {Events, ^event}
    refute_received {Events, ^marker}
  end

  test "delivers a notification once whether its own copy or a peer's copy arrives first", ctx do
    notifications = start_notifications!(ctx, :permanent)
    bridge = start_bridge!(ctx)
    await_bridge_listening!(bridge, notifications)
    pool_id = subscribe!()
    :ok = Phoenix.PubSub.subscribe(CodexPooler.PubSub, PostgresBridge.peer_topic())
    channel = Events.postgres_channel()

    # A peer's copy first, then the notification from PostgreSQL.
    {peer_first, peer_first_payload} = remote_pool_event(pool_id, "peer_first")
    send(bridge, {PostgresBridge, :relayed, channel, peer_first_payload})
    assert_receive {Events, ^peer_first}, @relay_detection_timeout_ms
    notify!(ctx.sender, channel, peer_first_payload)

    # The notification from PostgreSQL first: it is handed to the peers, and
    # their copy coming back is not delivered again.
    {own_first, own_first_payload} = remote_pool_event(pool_id, "own_first")
    notify!(ctx.sender, channel, own_first_payload)
    assert_receive {PostgresBridge, :relayed, ^channel, ^own_first_payload}, @relay_detection_timeout_ms
    assert_receive {Events, ^own_first}, @relay_detection_timeout_ms
    send(bridge, {PostgresBridge, :relayed, channel, own_first_payload})

    # A notification this node's connection lost reaches it through a peer.
    {peer_only, peer_only_payload} = remote_pool_event(pool_id, "peer_only")
    send(bridge, {PostgresBridge, :relayed, channel, peer_only_payload})
    assert_receive {Events, ^peer_only}, @relay_detection_timeout_ms

    # Two identical notifications from PostgreSQL are two notifications.
    repeated = status_payload(41)
    notify!(ctx.sender, StatusEvents.postgres_channel(), repeated)
    notify!(ctx.sender, StatusEvents.postgres_channel(), repeated)

    # A trailing marker from PostgreSQL: once it is delivered, every earlier
    # notification and copy has been handled by the bridge.
    {marker, marker_payload} = remote_pool_event(pool_id, "dedupe_marker")
    notify!(ctx.sender, channel, marker_payload)
    assert_receive {Events, ^marker}, @relay_detection_timeout_ms
    _ = :sys.get_state(bridge)

    refute_received {Events, ^peer_first}
    refute_received {Events, ^own_first}
    refute_received {Events, ^peer_only}
    refute_received {Events, ^marker}
    assert_received {:openai_status_updated, %{aggregate_revision: 41}}
    assert_received {:openai_status_updated, %{aggregate_revision: 41}}
    refute_received {:openai_status_updated, %{aggregate_revision: 41}}
    # A copy received from a peer is never handed on again.
    refute_received {PostgresBridge, :relayed, ^channel, ^peer_first_payload}
    refute_received {PostgresBridge, :relayed, ^channel, ^peer_only_payload}
  end

  defp start_notifications!(ctx, restart, id \\ :notifications) do
    opts = Keyword.merge(connection_config(), name: ctx.notifications, auto_reconnect: true)

    start_supervised!(%{id: id, start: {Postgrex.Notifications, :start_link, [opts]}, restart: restart})
  end

  # No PubSub peer by default: whatever else runs in the test VM must not
  # decide whether a notification is relayed.
  defp start_bridge!(ctx, opts \\ []) do
    opts = Keyword.merge([name: ctx.bridge_name, notifications: ctx.notifications, pubsub_nodes: fn -> [] end], opts)
    start_supervised!(%{id: :bridge, start: {PostgresBridge, :start_link, [opts]}})
  end

  defp subscribe! do
    pool_id = Ecto.UUID.generate()
    assert :ok = Events.subscribe_pool(pool_id)
    assert :ok = StatusEvents.subscribe()
    assert :ok = NotificationEvents.subscribe_pool(pool_id)
    pool_id
  end

  # A pool event committed by another node (another origin) and a status event
  # must each come back exactly once. The trailing marker travels the same
  # notifications process and bridge, so once its relay arrives any second copy
  # of the event would already be in this mailbox.
  defp assert_relays_once!(ctx, bridge, pool_id, label, revision) do
    notifications = GenServer.whereis(ctx.notifications)
    assert is_pid(notifications)
    control = control_listen!(notifications)

    {event, payload} = remote_pool_event(pool_id, label)
    {marker, marker_payload} = remote_pool_event(pool_id, label <> "_marker")
    alert_payload = remote_alert_payload(pool_id)
    notify!(ctx.sender, Events.postgres_channel(), payload)
    notify!(ctx.sender, StatusEvents.postgres_channel(), status_payload(revision))
    notify!(ctx.sender, NotificationEvents.postgres_channel(), alert_payload)
    notify!(ctx.sender, Events.postgres_channel(), marker_payload)

    # PostgreSQL delivered both notifications to the notifications process the
    # bridge is supposed to listen on; losing them is the bridge's doing.
    assert_receive {:notification, ^notifications, _ref, _channel, ^payload}, @relay_detection_timeout_ms
    assert_receive {:notification, ^notifications, _ref, _channel, ^alert_payload}, @relay_detection_timeout_ms
    assert_receive {:notification, ^notifications, _ref, _channel, ^marker_payload}, @relay_detection_timeout_ms

    assert_receive {Events, ^marker},
                   @relay_detection_timeout_ms,
                   "the bridge #{inspect(bridge)} relayed no cross-node event after #{label}"

    assert_received {Events, ^event}
    refute_received {Events, ^event}
    refute_received {Events, ^marker}

    assert_receive {:openai_status_updated, %{aggregate_revision: ^revision}}, @relay_detection_timeout_ms
    refute_received {:openai_status_updated, %{aggregate_revision: ^revision}}

    assert_received {NotificationEvents, :invalidated}
    refute_received {NotificationEvents, :invalidated}

    :ok = control_unlisten!(notifications, control)
  end

  defp control_listen!(notifications) do
    for channel <- [Events.postgres_channel(), StatusEvents.postgres_channel(), NotificationEvents.postgres_channel()] do
      assert {:ok, ref} = Postgrex.Notifications.listen(notifications, channel)
      ref
    end
  end

  defp control_unlisten!(notifications, refs) do
    Enum.each(refs, &(:ok = Postgrex.Notifications.unlisten(notifications, &1)))
  end

  # The bridge registers as a listener on all three channels, and the
  # notifications process monitors every listener, so three monitors from the
  # restarted process mean every registration is in place. The test's own listen issued the
  # LISTEN statements first, so each registration is complete when it appears.
  defp await_bridge_listening!(bridge, notifications) do
    control = control_listen!(notifications)
    deadline = System.monotonic_time(:millisecond) + @relay_detection_timeout_ms

    try do
      await_listener_monitors(bridge, notifications, deadline)
    after
      :ok = control_unlisten!(notifications, control)
    end
  end

  defp await_listener_monitors(bridge, notifications, deadline) do
    {:monitored_by, monitors} = Process.info(bridge, :monitored_by)

    cond do
      Enum.count(monitors, &(&1 == notifications)) >= 3 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        # Fall through: the relay assertion that follows names the lost event.
        :timeout

      true ->
        receive do
        after
          10 -> await_listener_monitors(bridge, notifications, deadline)
        end
    end
  end

  defp await_registered!(name, previous) do
    deadline = System.monotonic_time(:millisecond) + @relay_detection_timeout_ms
    await_registered(name, previous, deadline)
  end

  defp await_registered(name, previous, deadline) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _missing_or_previous ->
        assert System.monotonic_time(:millisecond) < deadline, "#{inspect(name)} was not restarted"

        receive do
        after
          10 -> await_registered(name, previous, deadline)
        end
    end
  end

  defp await_retry_pending!(bridge) do
    deadline = System.monotonic_time(:millisecond) + @relay_detection_timeout_ms
    await_retry_pending(bridge, deadline)
  end

  defp await_retry_pending(bridge, deadline) do
    case :sys.get_state(bridge) do
      %{notifications_monitor: nil, relisten_token: token} when is_reference(token) ->
        :ok

      _state ->
        assert System.monotonic_time(:millisecond) < deadline, "the bridge never noticed the exit"

        receive do
        after
          10 -> await_retry_pending(bridge, deadline)
        end
    end
  end

  defp remote_pool_event(pool_id, label, origin_node \\ nil) do
    event = %Event{
      version: 1,
      id: Ecto.UUID.generate(),
      pool_id: pool_id,
      topics: ["pools"],
      reason: "postgres_bridge_" <> label,
      emitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      payload: %{"label" => label}
    }

    assert {:ok, local_payload} = Events.event_to_postgres_payload(event)

    payload =
      local_payload
      |> CodexPooler.JSON.decode!()
      |> Map.put("origin_id", "postgres-bridge-test-remote-" <> Ecto.UUID.generate())
      |> then(&if(origin_node, do: Map.put(&1, "origin_node", origin_node), else: &1))
      |> CodexPooler.JSON.encode!()

    {event, payload}
  end

  # The notification an unclustered node (the worker) sends for an incident on
  # this Pool.
  defp remote_alert_payload(pool_id) do
    assert {:ok, local_payload} = NotificationEvents.postgres_payload("pool", pool_id)

    local_payload
    |> CodexPooler.JSON.decode!()
    |> Map.put("origin_id", "postgres-bridge-test-worker-" <> Ecto.UUID.generate())
    |> Map.put("origin_node", "postgres-bridge-test-worker@127.0.0.1")
    |> CodexPooler.JSON.encode!()
  end

  defp status_payload(revision) do
    CodexPooler.JSON.encode!(%{
      event_version: 1,
      changed_count: 1,
      active_count: 0,
      aggregate_revision: revision,
      emitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    })
  end

  defp notify!(sender, channel, payload) do
    assert {:ok, _result} = Postgrex.query(sender, "SELECT pg_notify($1, $2)", [channel, payload])
  end

  defp connection_config do
    Keyword.take(Repo.config(), [:hostname, :port, :database, :username, :password, :ssl])
  end

  defp resume_application_bridge do
    if Process.whereis(PostgresBridge) do
      try do
        :sys.resume(PostgresBridge)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end
end
