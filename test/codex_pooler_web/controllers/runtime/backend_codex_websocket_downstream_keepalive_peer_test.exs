defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketDownstreamKeepalivePeerTest do
  # The arms of `backend_codex_websocket/downstream_keepalive_test.exs`
  # (findings#302) with the session's owner and its provider connection on a
  # second VM sharing the committed database, the socket on this node. The
  # proxy's response task waits for the owner's reply to the turn submission
  # under the remote turn budget, `max(receive timeout, websocket idle timeout)
  # + 1 s`, which was a total bound: a remote turn streaming past it was
  # abandoned `owner_forward_timeout` while its frames still reached the
  # client. The budget now counts from the latest frames the socket delivered.
  # The module boots the VM once (booting it per test pushed arms past the
  # six-second budget, findings#270 row 270-323); each test starts its own
  # session's owner on it.
  #
  # Topology: the real public listener, FakeUpstream, the Pool's default mode
  # (Full), owner forwarding on, the session's owner on the peer VM. On this
  # node the downstream idle bound is 1.5 s; the long turn's arm also takes the
  # upstream receive timeout to 1 s, so its remote turn budget is 2.5 s. The
  # bound also covers the turn's setup before its first frame (the forward to
  # the peer, the owner's upstream connect), which the client's request frame
  # starts. Admission and a peer's fresh connection can consume most of the
  # bound before first progress. The late-start arms below establish that
  # phase through real empty ticks and the driver's read deadline, then verify
  # that the first progress Ping reaches a responsive client in time.
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Events.Outbox
  alias CodexPooler.Platform.ExecutionRegistry

  import Ecto.Query, only: [from: 2]

  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [gateway_setup: 1, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport,
    only: [enter_peer_owner_topology!: 0, start_shared_bridge_peer!: 0, start_shared_peer_window_owner!: 3]

  import CodexPoolerWeb.Runtime.DownstreamKeepaliveScenario
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Runtime.NativeResponseSteering
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPoolerWeb.Runtime.BackendCodexTestSupport
  alias CodexPoolerWeb.Runtime.DownstreamKeepaliveScenario
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence
  alias CodexPoolerWeb.WebsocketConnectionLogger

  @moduletag capture_log: true

  @idle_timeout_ms 1_500
  @receive_timeout_ms 1_000
  @remote_turn_budget_ms 2_500
  @frame_interval_ms 100

  setup_all do
    %{peer_node: start_shared_bridge_peer!()}
  end

  setup %{settings: settings} do
    :ok = put_settings!(settings, true)
    enter_peer_owner_topology!()
  end

  for mode <- ["full", "lite"] do
    @tag late_first_progress: true
    @tag settings: [websocket_idle_timeout_ms: @idle_timeout_ms, upstream_receive_timeout_ms: @receive_timeout_ms]
    @tag slow: "two actual empty keepalive ticks precede late first progress and a client Pong delayed by 50 ms"
    test "peer owner #{mode}: late first progress keeps the responsive client open", %{peer_node: peer_node} do
      scope = model_serving_scope()
      upstream = start_upstream(FakeUpstream.delayed_sse_stream(stream_events("resp_peer_late_first_progress", 3), interval_ms: @frame_interval_ms))
      setup = gateway_setup(upstream)
      set_model_serving_mode!(scope, setup, unquote(mode))
      %{turn: turn, request: request} = assert_late_start_completed!(setup, peer_node: peer_node)
      assert node(turn.client.owner) == peer_node
      assert %{"owner_instance_id" => owner, "proxy_instance_id" => proxy} = request.request_metadata["websocket_owner_forwarding"]
      assert owner != proxy
      assert FakeUpstream.count(upstream) == 1
      FakeUpstream.verify!(upstream)
    end
  end

  @tag settings: [websocket_idle_timeout_ms: @idle_timeout_ms]
  test "a busy actor on a real peer cannot add a five-second diagnostic call wait", %{peer_node: peer_node} do
    {:ok, actor} = :erpc.call(peer_node, GenServer, :start, [NativeResponseSteering, self()])
    :ok = :sys.suspend(actor)

    try do
      task = Task.async(fn -> WebsocketOwnerSession.capture_downstream_idle_timeout(actor, %{pid: self(), epoch: 1, correlation_id: Ecto.UUID.generate()}, "unknown") end)
      assert {:error, :attribution_unavailable} = Task.await(task, 1_000)
    after
      :sys.resume(actor)
      GenServer.stop(actor)
    end
  end

  for topology <- [:direct, :local, :peer] do
    @tag settings: [websocket_idle_timeout_ms: @idle_timeout_ms]
    @tag slow: "the real idle timer must close while an independent transaction holds the exact session row"
    test "#{topology}: an attribution row lock does not delay the idle close", %{peer_node: peer_node} do
      assert_locked_idle_close!(unquote(topology), peer_node)
    end
  end

  defp assert_locked_idle_close!(topology, peer_node) do
    :ok = put_settings!([websocket_idle_timeout_ms: @idle_timeout_ms], topology != :direct)
    hold = make_ref()
    upstream = start_upstream(FakeUpstream.strict_sequence([turn_request(FakeUpstream.barrier_websocket_frames(encoded_events("resp_idle_locked", 1), notify: self(), release_ref: hold))]))
    setup = gateway_setup(upstream)
    BackendCodexTestSupport.register_unboxed_pool_cleanup!(setup)
    client = start_turn!(setup, if(topology == :peer, do: [peer_node: peer_node], else: []))

    for ordinal <- 0..1 do
      assert_receive {:fake_upstream_frame_barrier, ^ordinal, _handler, ^hold}, detection_timeout_ms()
      :ok = FakeUpstream.release_frame(upstream, hold)
    end

    assert_receive {:fake_upstream_frame_barrier, 2, _handler, ^hold}, detection_timeout_ms()
    {conn, websocket, _first} = BackendCodexTestSupport.public_websocket_receive_text!(client.conn, client.websocket, client.ref)
    {conn, websocket, _second} = BackendCodexTestSupport.public_websocket_receive_text!(conn, websocket, client.ref)
    client = %{client | conn: conn, websocket: websocket}
    {_socket, handler} = :sys.get_state(client.socket)
    state = handler.connection.websock_state
    upstream_pid = if topology == :direct, do: state.upstream_websocket_session, else: :sys.get_state(state.websocket_owner_pid).upstream_pid

    if topology != :direct do
      # An inherited owner turn can have no local response task. Keep the
      # accepted owner witness while avoiding the unrelated task drain budget.
      :sys.replace_state(client.socket, fn {socket, handler} ->
        {socket, put_in(handler.connection.websock_state.tasks, MapSet.new())}
      end)
    end

    executor = capture_direct_executor(topology, setup)
    lock = hold_session_row!(state.codex_session.id)

    try do
      {turn, log} = with_log(fn -> read_turn!(client, answer_pings?: true) end)
      assert turn.end == {:close, 1002}
      assert Process.alive?(lock.pid)
      assert_producer_retired!(upstream_pid)

      assert_executor_receipt_pending(executor)
      refute log =~ "websocket downstream idle timeout attribution unavailable"
      send(lock.pid, :release)
      assert Task.await(lock, detection_timeout_ms()) == :ok

      assert_executor_receipt_committed(executor)
      WebsocketCleanupFence.await_session_cleanups!()
      assert {:ok, _} = CodexPooler.UnboxedFixture.run_unboxed(fn -> Outbox.drain() end)
      request = assert_request_settled!(setup, "failed", "client_disconnected")
      assert_idle_attribution!(CodexPooler.Repo.reload!(request), if(turn.pings > 0, do: "pong_observed", else: "unknown"))
      close_client!(turn.client)
    after
      send(lock.pid, :release)
      FakeUpstream.release_remaining_frames(upstream, hold)
    end
  end

  defp capture_direct_executor(:direct, setup) do
    attempt = CodexPooler.Repo.one!(from a in CodexPooler.Accounting.Attempt, join: r in CodexPooler.Accounting.Request, on: a.request_id == r.id, where: r.pool_id == ^setup.pool.id)
    pid = attempt.owner_process_id |> String.to_charlist() |> :erlang.list_to_pid()
    assert ExecutionRegistry.status(attempt.owner_execution_id, pid) == :alive
    %{pid: pid, monitor: Process.monitor(pid), attempt: attempt}
  end

  defp capture_direct_executor(_topology, _setup), do: nil

  defp assert_executor_receipt_pending(nil), do: :ok

  defp assert_executor_receipt_pending(executor) do
    assert Process.alive?(executor.pid)
    assert ExecutionRegistry.status(executor.attempt.owner_execution_id, executor.pid) == :alive
    assert ExecutionRegistry.pending_proofs([executor.attempt.owner_execution_id]) == []
    assert is_nil(CodexPooler.Repo.reload!(executor.attempt).response_metadata["downstream_delivery"])
  end

  defp assert_executor_receipt_committed(nil), do: :ok

  defp assert_executor_receipt_committed(%{pid: pid, monitor: monitor, attempt: attempt}) do
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, detection_timeout_ms()
    assert is_map(CodexPooler.Repo.reload!(attempt).response_metadata["downstream_delivery"])
    assert ExecutionRegistry.status(attempt.owner_execution_id, pid) == :dead
  end

  defp assert_producer_retired!(pid) do
    state = :sys.get_state(pid, 2_000)
    refute Map.has_key?(state, :conn)
  catch
    :exit, {:noproc, _call} -> :ok
  end

  @tag settings: [websocket_idle_timeout_ms: @idle_timeout_ms, upstream_receive_timeout_ms: @receive_timeout_ms]
  @tag slow: "the remote turn budget is a real timer: the turn must stream past it to show its delivered frames renew it"
  test "owner on another VM: a turn streaming past the remote turn budget completes", %{peer_node: peer_node} do
    # Thirty-two frames 100 ms apart: about 3.2 s against the 2.5 s budget.
    deltas = 28
    upstream = start_upstream(FakeUpstream.delayed_sse_stream(stream_events("resp_keepalive_remote_long", deltas), interval_ms: @frame_interval_ms))
    setup = gateway_setup(upstream)

    {turn, log} = with_log(fn -> setup |> start_turn!(peer_node: peer_node) |> read_turn!(answer_pings?: true) end)

    assert node(turn.client.owner) == peer_node
    assert turn.end == {:terminal, "response.completed"}, "the turn " <> describe_turn(turn)
    assert Enum.count(turn.events, &(&1["type"] == "response.output_text.delta")) == deltas
    assert turn.elapsed_ms > @remote_turn_budget_ms, "the turn " <> describe_turn(turn)
    request = assert_request_settled!(setup, "succeeded", nil)
    assert %{"owner_instance_id" => owner_instance, "proxy_instance_id" => proxy_instance} = request.request_metadata["websocket_owner_forwarding"]
    assert owner_instance != proxy_instance
    refute log =~ "owner_forward_timeout"
    refute log =~ WebsocketConnectionLogger.downstream_idle_timeout_message()
    :ok = close_client!(turn.client)
  end

  @tag settings: [websocket_idle_timeout_ms: @idle_timeout_ms]
  @tag slow: "real peer payload write stays held beyond the idle budget before the measured stall"
  test "readiness Pings isolate a peer startup longer than the measured idle budget", %{peer_node: peer} do
    hold = make_ref()
    upstream = start_upstream(FakeUpstream.strict_sequence([turn_request(FakeUpstream.barrier_websocket_frames(encoded_events("resp_keepalive_startup_held", 1), notify: self(), release_ref: hold))]))
    setup = gateway_setup(upstream)
    {client, dispatch_hold} = start_held_turn!(setup, peer)
    client = await_initial_provider_barrier!(client, hold)
    assert_receive {^dispatch_hold, :released, held_ms}, detection_timeout_ms()
    assert held_ms > @idle_timeout_ms
    assert FakeUpstream.physical_counts(upstream).websocket_generation == 1
    :ok = FakeUpstream.release_frame(upstream, hold)
    assert_receive {:fake_upstream_frame_barrier, 1, _handler, ^hold}, detection_timeout_ms()
    :ok = FakeUpstream.release_frame(upstream, hold)
    assert_receive {:fake_upstream_frame_barrier, 2, _handler, ^hold}, detection_timeout_ms()

    turn = read_turn!(client, answer_pings?: true)
    assert turn.end in [{:close, 1002}, :socket_closed], "the turn " <> describe_turn(turn)
    assert Enum.map(turn.events, & &1["type"]) -- ["codex.response.metadata"] == ["response.created", "response.output_item.added"]
    assert turn.pings <= 2
    request = assert_request_settled!(setup, "failed", "client_disconnected")
    assert_idle_attribution!(request, if(turn.pings > 0, do: "pong_observed", else: "unknown"))
    :ok = FakeUpstream.release_remaining_frames(upstream, hold)
    :ok = close_client!(turn.client)
  end

  defp start_held_turn!(setup, peer) do
    assert :ok = CodexPooler.Events.subscribe_pool(setup.pool)
    thread = Ecto.UUID.generate()
    owner = start_shared_peer_window_owner!(setup, thread <> ":0", peer).owner_pid
    target = :sys.get_state(owner).upstream_pid
    hold = make_ref()
    trace_mode = :erpc.call(peer, DownstreamKeepaliveScenario, :dispatch_trace_mode_state, [])

    on_exit(fn ->
      send(target, {hold, :release})
      :erpc.call(peer, DownstreamKeepaliveScenario, :restore_dispatch_trace, [hold, trace_mode])
    end)

    test = self()
    releaser = start_supervised!({Task, fn -> release_after_idle_budget(test, target, hold) end})
    :ok = :erpc.call(peer, DownstreamKeepaliveScenario, :install_dispatch_hold!, [target, hold, releaser])
    port = BackendCodexTestSupport.start_public_endpoint!()
    sockets = WebsocketCleanupFence.listener_sockets()
    headers = [{"session-id", thread}, {"thread-id", thread}, {"x-client-request-id", thread}, {"x-codex-window-id", thread <> ":0"}]
    {conn, websocket, ref, _headers} = BackendCodexTestSupport.public_websocket_connect_with_request_headers!(port, setup, thread, "/backend-api/codex/responses", headers)
    socket = WebsocketCleanupFence.await_new_listener_socket!(sockets)
    {conn, websocket} = BackendCodexTestSupport.public_websocket_send_text!(conn, websocket, ref, turn_frame(setup, thread))
    {%{conn: conn, websocket: websocket, ref: ref, socket: socket, owner: owner, sent_at: System.monotonic_time(:millisecond)}, hold}
  end

  defp release_after_idle_budget(test, target, hold) do
    assert_receive {^hold, :write_ready, ^target}, detection_timeout_ms()
    started = System.monotonic_time(:millisecond)

    receive do
    after
      @idle_timeout_ms + 250 ->
        send(target, {hold, :release})
        send(test, {hold, :released, System.monotonic_time(:millisecond) - started})
    end
  end

  # The upstream receive timeout keeps its default here: travelling with the
  # turn to the owner, a shorter one ends the stalled stream first (`502
  # server_error`), and the downstream idle bound would never be reached.
  for task_tracking <- [:tracked, :untracked] do
    @tag settings: [websocket_idle_timeout_ms: @idle_timeout_ms]
    @tag slow: "the idle bound is a real timer: the close lands one bound after the last pong"
    test "owner on another VM with #{task_tracking} task: a turn that stops delivering frames is still closed by the idle bound", %{peer_node: peer_node} do
      hold = make_ref()
      # provenance: synthetic_adversarial
      upstream = start_upstream(FakeUpstream.strict_sequence([turn_request(FakeUpstream.barrier_websocket_frames(encoded_events("resp_keepalive_remote_stalled", 1), notify: self(), release_ref: hold))]))
      setup = gateway_setup(upstream)

      {turn, log} =
        with_log(fn ->
          client = start_turn!(setup, peer_node: peer_node) |> await_initial_provider_barrier!(hold)

          # Readiness traffic stops before these two frames and their stall.
          :ok = FakeUpstream.release_frame(upstream, hold)
          assert_receive {:fake_upstream_frame_barrier, 1, _handler, ^hold}, detection_timeout_ms()
          :ok = FakeUpstream.release_frame(upstream, hold)

          assert_receive {:fake_upstream_frame_barrier, 2, _handler, ^hold}, detection_timeout_ms()

          {client, initial} =
            if unquote(task_tracking) == :untracked do
              # Read both frames before dropping bookkeeping, proving they
              # reached this downstream before the synthetic fault.
              {conn, websocket, first} = BackendCodexTestSupport.public_websocket_receive_text!(client.conn, client.websocket, client.ref)
              {conn, websocket, second} = BackendCodexTestSupport.public_websocket_receive_text!(conn, websocket, client.ref)

              :sys.replace_state(client.socket, fn {socket, handler} ->
                {socket, put_in(handler.connection.websock_state.tasks, MapSet.new())}
              end)

              {%{client | conn: conn, websocket: websocket}, Enum.map([first, second], &CodexPooler.JSON.decode!/1)}
            else
              {client, []}
            end

          turn = read_turn!(client, answer_pings?: true)
          %{turn | events: initial ++ turn.events}
        end)

      assert node(turn.client.owner) == peer_node
      assert turn.end in [{:close, 1002}, :socket_closed], "the turn " <> describe_turn(turn)
      assert Enum.map(turn.events, & &1["type"]) -- ["codex.response.metadata"] == ["response.created", "response.output_item.added"]
      assert turn.pings <= 2, "the turn " <> describe_turn(turn)
      request = assert_request_settled!(setup, "failed", "client_disconnected")
      assert_idle_attribution!(request, if(turn.pings > 0, do: "pong_observed", else: "unknown"))
      if unquote(task_tracking) == :tracked, do: assert(log =~ "#{WebsocketConnectionLogger.downstream_idle_timeout_message()} tracked_tasks=1")
      :ok = FakeUpstream.release_remaining_frames(upstream, hold)
      :ok = close_client!(turn.client)
    end
  end
end
