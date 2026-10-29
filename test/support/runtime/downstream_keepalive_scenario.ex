defmodule CodexPoolerWeb.Runtime.DownstreamKeepaliveScenario do
  @moduledoc false

  # A native turn that streams longer than the downstream idle bound
  # (findings#302), shared by the one-node module
  # (`backend_codex_websocket/downstream_keepalive_test.exs`) and the peer-only
  # one (`backend_codex_websocket_downstream_keepalive_peer_test.exs`, whose
  # module boots the owner's VM once). The bound is shortened through the
  # test-only settings override, the provider's frames are paced by the fake,
  # and the client reads the turn as the released client does.

  import ExUnit.Assertions
  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport,
    only: [start_shared_peer_window_owner!: 3]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestOutcome}
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionTrace
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  # Detection budget for a frame, a close, a settlement or a socket's cleanup
  # the test only observes.
  @detection_timeout_ms 15_000
  @turn_path "/backend-api/codex/responses"
  @terminal_types ~w(response.completed response.failed response.incomplete error)
  @trace_mode_key {NativeCompactionTrace, :active_mode}
  @type trace_mode_state :: :absent | {:present, :configured | NativeCompactionTrace.mode()}

  def detection_timeout_ms, do: @detection_timeout_ms
  def terminal_types, do: @terminal_types

  # Overrides gateway settings for this test (the socket reads its idle bound
  # and the proxy its remote turn budget from them) and turns owner forwarding
  # on or off, both restored at exit.
  def put_settings!(overrides, forwarding?) do
    previous = CodexPooler.TestAppEnv.restore_on_exit(OperationalSettings)
    settings = struct!(Keyword.get(previous, :settings, %OperationalSettings{}), overrides)

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous
      |> Keyword.put(:settings, settings)
      |> Keyword.put(:use_instance_settings?, false)
    )

    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding?)
    :ok
  end

  def turn_request(respond) do
    FakeUpstream.expect_request(method: "WEBSOCKET", path: @turn_path, json: [valid: true, equals: %{"type" => "response.create"}], respond: respond)
  end

  # `peer_node:` starts the session's owner on that (shared) peer VM before the
  # socket connects.
  @spec start_turn!(map(), keyword()) :: map()
  def start_turn!(setup, opts \\ []) do
    assert :ok = Events.subscribe_pool(setup.pool)
    thread = Ecto.UUID.generate()

    owner =
      case Keyword.get(opts, :peer_node) do
        nil -> nil
        peer_node -> start_shared_peer_window_owner!(setup, "#{thread}:0", peer_node).owner_pid
      end

    {_server, port} = start_public_endpoint_with_server!()
    before = WebsocketCleanupFence.listener_sockets()
    headers = [{"session-id", thread}, {"thread-id", thread}, {"x-client-request-id", thread}, {"x-codex-window-id", "#{thread}:0"}, {"openai-beta", "responses_websockets=2026-02-06"}]
    {conn, websocket, ref, _response_headers} = public_websocket_connect_with_request_headers!(port, setup, thread, @turn_path, headers)
    socket = WebsocketCleanupFence.await_new_listener_socket!(before)
    late_start = if Keyword.get(opts, :late_first_progress, false), do: hold_initial_dispatch!(socket)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, turn_frame(setup, thread))
    client = %{conn: conn, websocket: websocket, ref: ref, socket: socket, owner: owner, sent_at: System.monotonic_time(:millisecond)}

    if late_start do
      {client, phase} = release_after_empty_ticks!(late_start, client)
      Map.put(client, :late_start, phase)
    else
      client
    end
  end

  # Readiness Pings keep startup outside a post-progress idle assertion. Stop
  # them at this exact provider's first barrier, before the measured frames.
  @spec await_initial_provider_barrier!(map(), reference()) :: map()
  def await_initial_provider_barrier!(client, hold),
    do: await_initial_provider_barrier!(client, hold, System.monotonic_time(:millisecond) + @detection_timeout_ms)

  defp await_initial_provider_barrier!(client, hold, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    assert remaining > 0, "the initial provider request never reached its frame barrier"
    client = send_frame!(client, {:ping, "fixture-readiness"})

    receive do
      {:fake_upstream_frame_barrier, 0, _handler, ^hold} -> client
    after
      min(250, remaining) -> await_initial_provider_barrier!(client, hold, deadline)
    end
  end

  # The dispatch remains held after admission and connection setup, just
  # before its real payload write and the provider's receive budget.
  # Client readiness Pings keep bootstrap outside the measured idle window.
  # A real client Ping synchronizes the driver's unchanged read deadline; its
  # returned Pong is not a progress Ping. Two subsequent empty ticks establish
  # the late-start phase; dispatch releases immediately, and the first actual
  # progress Pong must renew that deadline before it expires.
  defp hold_initial_dispatch!(socket) do
    {_transport, handler} = :sys.get_state(socket)
    state = handler.connection.websock_state

    target =
      if owner = Map.get(state, :websocket_owner_pid),
        do: :sys.get_state(owner).upstream_pid,
        else: state.upstream_websocket_session

    hold = make_ref()
    monitor = Process.monitor(target)
    :sys.get_state(target)
    trace_node = node(target)
    trace_mode = :erpc.call(trace_node, __MODULE__, :dispatch_trace_mode_state, [], @detection_timeout_ms)

    ExUnit.Callbacks.on_exit({__MODULE__, hold}, fn ->
      try do
        remove_dispatch_hold(trace_node, hold, trace_mode)
      after
        send(target, {hold, :release})
        remove_empty_tick_watch(socket)
      end
    end)

    config = %{test: self(), hold: hold, request_seen?: false, pending_tick?: false, clock_pending?: false, clock_synced?: false, pong_pending?: false, ticks: 0, decoder: %Mint.WebSocket{}}
    :ok = :sys.install(socket, {&__MODULE__.empty_tick_watch/3, config})

    :ok = :erpc.call(trace_node, __MODULE__, :install_dispatch_hold!, [target, hold, self()], @detection_timeout_ms)

    %{socket: socket, target: target, hold: hold, monitor: monitor, trace_node: trace_node, trace_mode: trace_mode}
  end

  @doc false
  @spec dispatch_trace_mode_state() :: trace_mode_state()
  def dispatch_trace_mode_state do
    case :persistent_term.get(@trace_mode_key, :absent) do
      :absent -> :absent
      mode -> {:present, mode}
    end
  end

  @doc false
  @spec install_dispatch_hold!(pid(), reference(), pid()) :: :ok
  def install_dispatch_hold!(target, hold, test) do
    :ok = :telemetry.attach({__MODULE__, hold}, NativeCompactionTrace.event(), &__MODULE__.hold_before_payload_write/4, %{target: target, hold: hold, test: test})
    :ok = NativeCompactionTrace.activate_mode(:full)
  end

  # This diagnostic event is emitted synchronously before Mint encodes or
  # writes the payload. Its other fields are deliberately never retained.
  @doc false
  @spec hold_before_payload_write(term(), term(), map(), map()) :: :ok
  def hold_before_payload_write(_event, _measurements, %{event: :upstream_websocket_frame_sent, fields: %{upstream_pid: target}}, %{target: target, hold: hold, test: test}) when self() == target do
    test_monitor = Process.monitor(test)
    send(test, {hold, :write_ready, target})

    receive do
      {^hold, :release} -> :ok
      {:DOWN, ^test_monitor, :process, ^test, _reason} -> :ok
    after
      @detection_timeout_ms -> :ok
    end

    Process.demonitor(test_monitor, [:flush])
    :ok
  end

  def hold_before_payload_write(_event, _measurements, _metadata, _config), do: :ok

  @doc false
  @spec restore_dispatch_trace(reference(), trace_mode_state()) :: :ok
  def restore_dispatch_trace(hold, mode_state) do
    _ = :telemetry.detach({__MODULE__, hold})

    case mode_state do
      :absent -> :persistent_term.erase(@trace_mode_key)
      {:present, mode} -> :persistent_term.put(@trace_mode_key, mode)
    end

    :ok
  end

  defp remove_dispatch_hold(trace_node, hold, mode) do
    cond do
      trace_node == node() -> restore_dispatch_trace(hold, mode)
      trace_node in Node.list(:connected) -> :erpc.call(trace_node, __MODULE__, :restore_dispatch_trace, [hold, mode], @detection_timeout_ms)
      true -> :ok
    end
  end

  @doc false
  @spec empty_tick_watch(map(), term(), term()) :: map() | :done
  def empty_tick_watch(config, {:in, {:tcp, _socket, data}}, _name) do
    {:ok, decoder, frames} = Mint.WebSocket.decode(config.decoder, data)

    Enum.reduce(frames, %{config | decoder: decoder}, fn
      {:text, _text}, config -> %{config | request_seen?: true}
      {:ping, ""}, config -> %{config | clock_pending?: true}
      {:pong, _payload}, config -> %{config | pong_pending?: true}
      _frame, config -> config
    end)
  end

  def empty_tick_watch(%{clock_pending?: true} = config, {:noreply, {transport, handler}}, _name) do
    observed? = Map.get(handler.connection.websock_state, :downstream_pong_observed?, false)
    send(config.test, {config.hold, :clock_synchronized, transport.read_timeout, transport.read_deadline, observed?})
    %{config | clock_pending?: false, clock_synced?: true, ticks: 0}
  end

  def empty_tick_watch(%{pong_pending?: true, clock_synced?: true} = config, {:noreply, {transport, handler}}, _name) do
    if Map.get(handler.connection.websock_state, :downstream_pong_observed?, false) do
      send(config.test, {config.hold, :first_pong_received, System.monotonic_time(:millisecond), transport.read_deadline})
      :done
    else
      %{config | pong_pending?: false}
    end
  end

  def empty_tick_watch(%{request_seen?: true, ticks: ticks} = config, {:in, {CodexPoolerWeb.CodexResponsesSocket, :downstream_keepalive, _interval, _previous}}, _name) when ticks < 2,
    do: %{config | pending_tick?: true}

  def empty_tick_watch(%{pending_tick?: true} = config, {:noreply, {transport, handler}}, _name) do
    evidence = Map.get(handler.connection.websock_state, :downstream_delivery_evidence, %{})
    frames = evidence |> Map.values() |> Enum.map(&Map.get(&1, :frames, 0)) |> Enum.sum()

    if config.clock_synced? do
      ticks = config.ticks + 1
      send(config.test, {config.hold, :empty_tick, ticks, frames, transport.read_deadline, System.monotonic_time(:millisecond)})
      %{config | ticks: ticks, pending_tick?: false}
    else
      send(config.test, {config.hold, :initial_empty_tick, frames, System.monotonic_time(:millisecond)})
      %{config | pending_tick?: false}
    end
  end

  def empty_tick_watch(config, _event, _name), do: config

  defp await_write_ready!(%{hold: hold, target: target, monitor: monitor} = barrier, client, deadline, readiness_pings) do
    remaining = deadline - System.monotonic_time(:millisecond)
    assert remaining > 0, "the initial dispatch never reached payload write readiness"

    receive do
      {^hold, :write_ready, ^target} ->
        {client, readiness_pings}

      {^hold, :initial_empty_tick, 0, _tick_at} ->
        client = send_frame!(client, {:ping, "fixture-readiness"})
        await_write_ready!(barrier, client, deadline, readiness_pings + 1)

      {:DOWN, ^monitor, :process, ^target, reason} ->
        flunk("the initial dispatch session exited before its hold: #{inspect(reason)}")
    after
      remaining -> flunk("the initial dispatch never reached payload write readiness")
    end
  end

  defp release_after_empty_ticks!(%{hold: hold, target: target, monitor: monitor} = barrier, client) do
    {client, phase} =
      try do
        {client, readiness_pings} = await_write_ready!(barrier, client, System.monotonic_time(:millisecond) + @detection_timeout_ms, 0)

        # Detaching does not cancel the synchronous callback already held in
        # the upstream process. Finish restoration before the measured phase.
        :ok = remove_dispatch_hold(barrier.trace_node, hold, barrier.trace_mode)
        client = send_frame!(client, {:ping, "fixture-readiness"})
        write_ready_at = System.monotonic_time(:millisecond)
        assert_receive {^hold, :initial_empty_tick, 0, tick_at} when tick_at >= write_ready_at, @detection_timeout_ms
        client = send_frame!(client, {:ping, ""})
        assert_receive {^hold, :clock_synchronized, 1_500, synchronized_deadline, false}, @detection_timeout_ms
        assert_receive {^hold, :empty_tick, 1, 0, ^synchronized_deadline, first_tick_at}, @detection_timeout_ms
        assert_receive {^hold, :empty_tick, 2, 0, deadline, second_tick_at}, @detection_timeout_ms
        assert deadline == synchronized_deadline
        assert second_tick_at > first_tick_at
        next_tick_margin = deadline - second_tick_at - 500
        assert next_tick_margin < 50, "the next periodic tick still left #{next_tick_margin} ms for the Pong"

        {Map.put(client, :late_start_observer, hold), %{write_ready_at: write_ready_at, readiness_pings: readiness_pings + 1, first_tick_at: first_tick_at, second_tick_at: second_tick_at, initial_deadline: deadline, next_tick_margin_ms: next_tick_margin}}
      after
        send(target, {hold, :release})
        Process.demonitor(monitor, [:flush])
      end

    ExUnit.Callbacks.on_exit({__MODULE__, hold}, fn -> remove_empty_tick_watch(barrier.socket) end)
    {client, Map.put(phase, :released_at, System.monotonic_time(:millisecond))}
  end

  defp remove_empty_tick_watch(socket) do
    :sys.remove(socket, &__MODULE__.empty_tick_watch/3)
  catch
    :exit, _reason -> :ok
  end

  # Reads the turn as the released client does: its websocket pump answers
  # every Ping with a Pong (codex-rs `codex-api/src/endpoint/responses_websocket.rs`);
  # `answer_pings?: false` is a client that does not. Ends on a terminal event,
  # a Close or the connection's end.
  @spec read_turn!(map(), keyword()) :: map()
  def read_turn!(client, opts) do
    answer_pings? = Keyword.fetch!(opts, :answer_pings?)
    do_read_turn!(client, answer_pings?, %{events: [], pings: 0, pongs: 0, first_event_ms: nil, first_progress_at: nil, ping_read_at: [], pong_written_at: [], pong_delay_ms: Keyword.get(opts, :pong_delay_ms, 0)})
  end

  defp do_read_turn!(client, answer_pings?, acc) do
    case receive_mint_socket_message!(client.conn, @detection_timeout_ms, "timed out waiting for the turn") do
      {tag, _socket} when tag in [:tcp_closed, :ssl_closed] ->
        finish_turn(client, acc, :socket_closed)

      {tag, _socket, _reason} when tag in [:tcp_error, :ssl_error] ->
        finish_turn(client, acc, :socket_closed)

      message ->
        {:ok, conn, responses} = Mint.WebSocket.stream(client.conn, message)
        client = %{client | conn: conn}
        {websocket, frames} = decode_frames(client.websocket, client.ref, responses)

        case apply_frames(frames, %{client | websocket: websocket}, acc, answer_pings?) do
          {:cont, client, acc} -> do_read_turn!(client, answer_pings?, acc)
          {:halt, client, acc, ending} -> finish_turn(client, acc, ending)
        end
    end
  end

  defp decode_frames(websocket, ref, responses) do
    Enum.reduce(responses, {websocket, []}, fn
      {:data, ^ref, data}, {websocket, frames} ->
        {:ok, websocket, decoded} = Mint.WebSocket.decode(websocket, data)
        {websocket, frames ++ decoded}

      _response, acc ->
        acc
    end)
  end

  defp apply_frames([], client, acc, _answer_pings?), do: {:cont, client, acc}

  defp apply_frames([{:ping, payload} | frames], client, acc, answer_pings?) do
    ping_at = System.monotonic_time(:millisecond)

    if answer_pings? and acc.pong_delay_ms > 0 do
      receive do
      after
        acc.pong_delay_ms -> :ok
      end
    end

    client = if answer_pings?, do: send_frame!(client, {:pong, payload}), else: client
    pongs_at = if answer_pings?, do: acc.pong_written_at ++ [System.monotonic_time(:millisecond)], else: acc.pong_written_at
    apply_frames(frames, client, %{acc | pings: acc.pings + 1, pongs: acc.pongs + if(answer_pings?, do: 1, else: 0), ping_read_at: acc.ping_read_at ++ [ping_at], pong_written_at: pongs_at}, answer_pings?)
  end

  defp apply_frames([{:text, text} | frames], client, acc, answer_pings?) do
    event = CodexPooler.JSON.decode!(text)
    now = System.monotonic_time(:millisecond)
    type = event["type"]
    first_progress_at = if is_nil(acc.first_progress_at) and is_binary(type) and not String.starts_with?(type, "codex."), do: now, else: acc.first_progress_at
    acc = %{acc | events: acc.events ++ [event], first_event_ms: acc.first_event_ms || now - client.sent_at, first_progress_at: first_progress_at}

    if event["type"] in @terminal_types,
      do: {:halt, client, acc, {:terminal, event["type"]}},
      else: apply_frames(frames, client, acc, answer_pings?)
  end

  defp apply_frames([{:close, code, _reason} | _frames], client, acc, _answer_pings?), do: {:halt, client, acc, {:close, code}}
  defp apply_frames([_frame | frames], client, acc, answer_pings?), do: apply_frames(frames, client, acc, answer_pings?)

  defp finish_turn(client, acc, ending) do
    turn = Map.merge(acc, %{client: client, end: ending, elapsed_ms: System.monotonic_time(:millisecond) - client.sent_at})
    CodexPooler.TestDiagnostics.puts(fn -> "downstream keepalive turn " <> describe_turn(turn) end)
    turn
  end

  # How a read turn went, for assertion messages: a close before the first
  # event is a bound shorter than the turn's setup, one after it a gap.
  def describe_turn(turn) do
    summary = "ended #{inspect(turn.end)} after #{turn.elapsed_ms} ms with #{length(turn.events)} events (first after #{inspect(turn.first_event_ms)} ms) and #{turn.pings} pings"

    if phase = Map.get(turn.client, :late_start),
      do: summary <> " phase=#{inspect(phase)} first_progress_at=#{inspect(turn.first_progress_at)} ping_read_at=#{inspect(turn.ping_read_at)} pong_written_at=#{inspect(turn.pong_written_at)}",
      else: summary
  end

  defp send_frame!(client, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(client.websocket, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(client.conn, client.ref, data)
    %{client | conn: conn, websocket: websocket}
  end

  def close_client!(client) do
    Mint.HTTP.close(client.conn)
    WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
  end

  @spec assert_pong_received!(map()) :: :ok
  def assert_pong_received!(client) do
    {_transport, handler} = :sys.get_state(client.socket)
    assert handler.connection.websock_state.downstream_pong_observed? == true
    :ok
  end

  @spec assert_late_start_completed!(map(), keyword()) :: map()
  def assert_late_start_completed!(setup, opts \\ []) do
    client = start_turn!(setup, Keyword.put(opts, :late_first_progress, true))

    try do
      turn = read_turn!(client, answer_pings?: true, pong_delay_ms: 50)
      assert is_integer(turn.first_progress_at), "the turn " <> describe_turn(turn)
      assert turn.first_progress_at > client.late_start.second_tick_at
      assert turn.first_progress_at < client.late_start.initial_deadline
      assert turn.end == {:terminal, "response.completed"}, "the turn " <> describe_turn(turn)
      assert turn.pongs > 0
      assert [first_ping_at | _] = turn.ping_read_at
      assert [first_pong_written_at | _] = turn.pong_written_at
      assert first_ping_at >= turn.first_progress_at
      assert first_pong_written_at - first_ping_at >= 50
      assert first_ping_at < client.late_start.initial_deadline
      assert first_pong_written_at < client.late_start.initial_deadline
      observer = client.late_start_observer
      assert_receive {^observer, :first_pong_received, first_pong_received_at, renewed_deadline}, @detection_timeout_ms
      assert first_pong_received_at < client.late_start.initial_deadline
      assert renewed_deadline > client.late_start.initial_deadline
      assert Enum.map(turn.events, & &1["type"]) -- ["codex.response.metadata"] == Enum.map(stream_events("synthetic_late_start", 3), &elem(&1, 0))
      assert client.sent_at + turn.first_event_ms > client.late_start.second_tick_at
      assert client.sent_at + turn.first_event_ms < client.late_start.initial_deadline
      :ok = assert_pong_received!(turn.client)
      request = assert_request_settled!(setup, "succeeded", nil)
      refute Map.has_key?(request.request_metadata, "downstream_interruption")
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      refute Map.has_key?(attempt.response_metadata || %{}, "downstream_interruption")
      assert Repo.aggregate(from(e in LedgerEntry, where: e.request_id == ^request.id and e.entry_kind == "settlement" and e.amount_status == "recorded"), :count) == 1
      phase = Map.merge(client.late_start, %{first_pong_received_at: first_pong_received_at, renewed_deadline: renewed_deadline})
      %{turn: turn, request: request, phase: phase}
    after
      remove_empty_tick_watch(client.socket)
      close_client!(client)
    end
  end

  def assert_request_settled!(setup, status, last_error_code) do
    assert_receive {Events, %{reason: "request_finalized", payload: %{"status" => ^status}}}, @detection_timeout_ms
    assert [%Request{status: ^status, last_error_code: ^last_error_code, transport: "websocket"} = request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    request
  end

  def assert_idle_attribution!(request, activity) do
    receipt = %{"origin" => "server", "cause" => "idle_timeout", "client_activity" => activity}
    request = await_idle_attribution!(request, receipt, System.monotonic_time(:millisecond) + @detection_timeout_ms)
    assert request.request_metadata["downstream_interruption"] == receipt
    refute RequestOutcome.client_cancelled?(request)
    assert RequestOutcome.display_status(request) == "failed"
    assert [attempt] = Repo.all(from a in Attempt, where: a.request_id == ^request.id)
    assert attempt.response_metadata["downstream_interruption"] == receipt
    assert attempt.network_error_code == "client_disconnected"
    assert Repo.aggregate(from(e in LedgerEntry, where: e.request_id == ^request.id and e.entry_kind == "settlement" and e.amount_status == "recorded"), :count) == 1
    assert Repo.aggregate(from(e in LedgerEntry, where: e.request_id == ^request.id and e.entry_kind == "release"), :count) == 1
  end

  # Settlement can publish request_finalized before the independent idle
  # attribution transaction commits. Its post-commit event fences both the
  # request and attempt metadata; the earlier request struct is a snapshot.
  defp await_idle_attribution!(request, receipt, deadline) do
    request = Repo.reload!(request)

    if request.request_metadata["downstream_interruption"] == receipt do
      request
    else
      request_id = request.id
      remaining = deadline - System.monotonic_time(:millisecond)
      assert remaining > 0, "idle attribution did not commit for request #{request_id}"
      assert_receive {Events, %{reason: "request_metadata_updated", payload: %{"request_id" => ^request_id}}}, remaining
      await_idle_attribution!(request, receipt, deadline)
    end
  end

  def hold_session_row!(session_id) do
    parent = self()
    {:ok, id} = Ecto.UUID.dump(session_id)

    task =
      Task.async(fn ->
        {:ok, connection} = Postgrex.start_link(Keyword.take(CodexPooler.Repo.config(), [:hostname, :port, :username, :password, :database]))

        try do
          {:ok, :ok} =
            Postgrex.transaction(
              connection,
              fn connection ->
                Postgrex.query!(connection, "SELECT id FROM codex_sessions WHERE id = $1 FOR UPDATE", [id])
                send(parent, {:session_row_locked, self()})

                receive do
                  :release -> :ok
                after
                  30_000 -> raise "session lock was not released"
                end
              end,
              timeout: 35_000
            )

          :ok
        after
          GenServer.stop(connection)
        end
      end)

    pid = task.pid
    assert_receive {:session_row_locked, ^pid}, detection_timeout_ms()
    task
  end

  # A message streamed as `deltas` text deltas, as `{type, payload}` events for
  # the fake's paced stream.
  def stream_events(response_id, deltas) do
    item_id = "msg_#{response_id}"
    item = %{"type" => "message", "id" => item_id, "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => String.duplicate("x", deltas)}]}

    [
      %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => %{item | "status" => "in_progress", "content" => []}}
    ]
    |> Kernel.++(for _delta <- 1..deltas, do: %{"type" => "response.output_text.delta", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "delta" => "x"})
    |> Kernel.++([
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 20, "output_tokens" => deltas, "total_tokens" => 20 + deltas}}}
    ])
    |> Enum.map(&{&1["type"], &1})
  end

  # The same events as encoded native frames, for `barrier_websocket_frames/2`.
  def encoded_events(response_id, deltas),
    do: response_id |> stream_events(deltas) |> Enum.map(fn {_type, event} -> CodexPooler.JSON.encode!(event) end)

  @spec turn_frame(map(), String.t()) :: String.t()
  def turn_frame(setup, thread) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "input" => native_text_input("synthetic prompt"),
      "tools" => [],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "store" => false,
      "stream" => true,
      "prompt_cache_key" => thread,
      "client_metadata" => %{"session_id" => thread, "thread_id" => thread, "turn_id" => Ecto.UUID.generate()}
    })
  end
end
