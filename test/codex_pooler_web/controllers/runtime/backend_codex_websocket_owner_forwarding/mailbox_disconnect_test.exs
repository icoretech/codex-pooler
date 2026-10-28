defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.MailboxDisconnectTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, with_info_log: 1]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_peer_window_owner!: 2, request_logs: 1]

  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo
  alias CodexPooler.UnboxedFixture
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  @detection_timeout_ms 15_000
  @thread_id "019a0000-0000-7000-8000-00000000e363"
  @window_id "#{@thread_id}:0"

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    :ok
  end

  @tag slow: "boots a real second BEAM node and crosses a bounded socket drain during a database retry"
  test "a mailbox cut preserves its settlement retry and delivery receipt beyond the socket drain" do
    {predecessor, logs} = with_info_log(fn -> run_scenario(:peer, "full", settlement_stall?: true) end)
    assert logs =~ "gateway settlement met a transient database failure; retrying stage=finalize_partial_stream_failure request_id=#{predecessor.id}"
    assert logs =~ "gateway settlement completed after a transient database failure stage=finalize_partial_stream_failure request_id=#{predecessor.id}"
  end

  for mode <- ["full", "lite"] do
    @tag slow: "boots a real second BEAM node and cancels an actual receipt COMMIT"
    test "a mailbox cut retries its original delivery receipt after transient persistence cancellation (#{mode})" do
      {predecessor, logs} = with_info_log(fn -> run_scenario(:peer, unquote(mode), receipt_stall?: true, historical_mailbox_runs: 22) end)
      assert logs =~ "gateway delivery receipt met a transient database failure; retrying stage=delivery_receipt request_id=#{predecessor.id}"
      assert logs =~ "gateway delivery receipt completed after a transient database failure stage=delivery_receipt request_id=#{predecessor.id}"
      assert length(Regex.scan(~r/websocket downstream terminal pushed request_id=#{predecessor.id} /, logs)) == 1
      refute logs =~ "downstream delivery receipt not persisted"
    end
  end

  for topology <- [:local, :peer], mode <- ["full", "lite"] do
    @tag topology: topology, mode: mode
    if topology == :peer, do: @tag(slow: "boots a real second BEAM node and shares committed fixture rows")

    test "a reasoning-done mailbox cut closes its provider socket and leaves the immediate full-history successor intact (#{topology} owner, #{mode})", %{topology: topology, mode: mode} do
      {predecessor, logs} = with_info_log(fn -> run_scenario(topology, mode) end)

      if topology == :local do
        [attempt_id] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^predecessor.id, select: attempt.id))
        line = Enum.find(String.split(logs, "\n"), &String.contains?(&1, "upstream websocket request connection closed"))
        assert is_binary(line)
        assert line =~ "request_id=#{predecessor.id}"
        assert line =~ "attempt_id=#{attempt_id}"
        assert line =~ "reason_code=request_caller_down closed_by=pooler close_completed=true"
        assert line =~ "last_upstream_event_type=response.output_item "
        assert line =~ "text_frame_count=3"
        assert line =~ "terminal_seen=false"
      end
    end
  end

  defp run_scenario(topology, mode, opts \\ []) do
    predecessor_gate = make_ref()
    successor_gate = make_ref()

    # This existing fake mode pushes native websocket text frames and holds
    # only the terminal. Unlike the frame-by-frame barrier it returns to the
    # server loop, so a real peer TCP close is observable while held.
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expected_request(FakeUpstream.delayed_terminal_sse_stream(reasoning_frames(), completed_frame("resp_mailbox_predecessor"), notify: self(), release_ref: predecessor_gate)),
          expected_request(FakeUpstream.delayed_terminal_sse_stream([], completed_frame("resp_mailbox_successor"), notify: self(), release_ref: successor_gate))
        ])
      )

    setup = topology_setup!(topology, upstream)
    {stall, receipt_stall} = install_stall!(setup, opts)
    set_model_serving_mode!(model_serving_scope(), setup, mode)
    :ok = Events.subscribe_pool(setup.pool.id, ["request_logs"])
    port = start_public_endpoint!()
    {conn_a, ws_a, ref_a} = connect!(port, setup, mode)
    original_history = original_history(opts)
    {conn_a, ws_a} = public_websocket_send_text!(conn_a, ws_a, ref_a, encode(payload(setup, original_history, "turn-mailbox")))
    assert_receive {:fake_upstream_timeout_barrier, :before_terminal, predecessor_handler, ^predecessor_gate}, @detection_timeout_ms
    predecessor_monitor = Process.monitor(predecessor_handler)
    {conn_a, _ws_a, types} = receive_types!(conn_a, ws_a, ref_a, 3)
    assert types == ["response.created", "response.output_item.added", "response.output_item.done"]

    owner = owner_pid(topology, setup)
    assert node(owner) == if(topology == :peer, do: setup.peer_owner.node, else: node())
    %{downstream: %{pid: socket_a}} = :sys.get_state(owner)

    cancellation_observer =
      if stall do
        :sys.replace_state(socket_a, fn {name, data} ->
          state = data.connection.websock_state
          opts = %{state.opts | transport: Map.merge(state.opts.transport, %{websocket_owner_response_task_drain_ms: 1_000, websocket_response_task_drain_ms: 50})}
          {name, %{data | connection: %{data.connection | websock_state: %{state | opts: opts}}}}
        end)

        observe_socket_cancellation!(socket_a)
      end

    hold = if is_nil(stall) and is_nil(receipt_stall), do: hold_session_cleanup!(socket_a)

    # The mailbox update arrives after reasoning is done but before the whole
    # response completes. Hold A's detach so B really overlaps its cleanup.
    _closed = Mint.HTTP.close(conn_a)

    cleanup = finish_cut!(setup, receipt_stall, stall, cancellation_observer, hold)

    {conn_b, ws_b, ref_b} = connect!(port, setup, mode)
    history = original_history ++ [reasoning_item(), mailbox_item()]
    {conn_b, ws_b} = public_websocket_send_text!(conn_b, ws_b, ref_b, encode(payload(setup, history, "turn-mailbox")))

    successor_handler =
      receive do
        {:fake_upstream_timeout_barrier, :before_terminal, handler, ^successor_gate} -> handler
      after
        @detection_timeout_ms -> flunk("the provider never received the mailbox successor while predecessor cleanup was held")
      end

    assert successor_handler != predecessor_handler

    # The provider has physically received B, but cannot complete it. Its
    # predecessor must die without releasing its terminal. This detects a
    # cancellation that only settles rows while leaving generation running.
    assert_receive {:DOWN, ^predecessor_monitor, :process, ^predecessor_handler, _reason}, @detection_timeout_ms
    assert Process.alive?(successor_handler)

    if cleanup do
      cleanup_monitor = Process.monitor(cleanup)
      send(cleanup, {hold, :release})
      assert_receive {:DOWN, ^cleanup_monitor, :process, ^cleanup, _reason}, @detection_timeout_ms
    end

    assert Process.alive?(successor_handler)
    send(successor_handler, {:fake_upstream_release_timeout, successor_gate})
    # The public terminal can arrive before accounting commits. Observe the
    # request's finalized event before asserting its persisted ledger rows.
    assert_receive {Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
    {conn_b, _ws_b, text} = public_websocket_receive_text!(conn_b, ws_b, ref_b)
    terminal = CodexPooler.JSON.decode!(text)
    assert {terminal["type"], get_in(terminal, ["response", "id"])} == {"response.completed", "resp_mailbox_successor"}
    _closed = Mint.HTTP.close(conn_b)
    WebsocketCleanupFence.await_session_cleanups!()
    assert_accounting!(setup.pool.id, mode)

    assert [first, second] = FakeUpstream.requests(upstream)
    assert first.method == "WEBSOCKET" and second.method == "WEBSOCKET"
    assert first.websocket_connection_id != second.websocket_connection_id
    # Lite prepends its declared tools and instruction messages on both sends.
    prefix_count = if mode == "lite", do: 2, else: 0
    assert length(first.json["input"]) == length(original_history) + prefix_count
    assert length(second.json["input"]) == length(original_history) + 2 + prefix_count
    refute Map.has_key?(second.json, "previous_response_id")
    assert FakeUpstream.count(upstream) == 2
    assert :ok = FakeUpstream.verify!(upstream)
    CodexPooler.TestDiagnostics.puts(fn -> CodexPooler.JSON.encode!(%{scenario: "mailbox_owner_physical_disconnect", topology: topology, mode: mode, receipt_retry: not is_nil(receipt_stall), mailbox_runs: Keyword.get(opts, :historical_mailbox_runs, 0) + 1, actual_remote_owner: node(owner) != node(), provider_down_observed: true, terminal_reason: "client_disconnected", physical_sends: 2, request_count: 2, settlements_per_request: 1, provider_connections_distinct: first.websocket_connection_id != second.websocket_connection_id}) end)
    hd(request_logs(setup.pool.id))
  end

  defp finish_cut!(setup, receipt_stall, _stall, _observer, _hold) when not is_nil(receipt_stall) do
    first = await_stalled_commit!(receipt_stall, 1)
    [request] = request_logs(setup.pool.id)
    [attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))
    {_token, initial} = delivery_entry(attempt.id)
    assert %{rows: [[true]]} = Postgrex.query!(receipt_stall.observer, "SELECT pg_cancel_backend($1)", [first])
    second = await_stalled_commit!(receipt_stall, 2)
    assert first != second
    assert is_nil(attempt.response_metadata["downstream_delivery"])
    {_token, pending} = delivery_entry(attempt.id)
    assert Process.alive?(pending.actor)
    assert pending.finished? == false
    assert pending.deadline_ms == initial.deadline_ms
    assert pending.envelope == initial.envelope
    assert pending.envelope.context.attempt_id == attempt.id
    assert pending.envelope.receipt["completed_items"] == 1
    assert %{rows: [[true]]} = Postgrex.query!(receipt_stall.holder, "SELECT pg_advisory_unlock($1)", [receipt_stall.key])
    await_interrupted_receipt!(request.id)
    assert Repo.reload!(attempt).response_metadata["downstream_delivery"] == initial.envelope.receipt
    nil
  end

  defp finish_cut!(setup, nil, stall, cancellation_observer, _hold) when not is_nil(stall) do
    first = await_stalled_commit!(stall, 1)
    assert %{rows: [[true]]} = Postgrex.query!(stall.observer, "SELECT pg_cancel_backend($1)", [first])
    second = await_stalled_commit!(stall, 2)
    assert %{rows: [[true]]} = Postgrex.query!(stall.observer, "SELECT pg_cancel_backend($1)", [second])
    _third = await_stalled_commit!(stall, 3)
    # Release only after cancellation observes the settling executor.
    assert_receive {^cancellation_observer, {:settling, _deadline}}, @detection_timeout_ms
    assert %{rows: [[true]]} = Postgrex.query!(stall.holder, "SELECT pg_advisory_unlock($1)", [stall.key])
    assert_receive {Events, %{reason: "request_finalized", payload: %{"status" => "failed"}}}, @detection_timeout_ms
    [request] = request_logs(setup.pool.id)
    await_interrupted_receipt!(request.id)
    nil
  end

  defp finish_cut!(_setup, nil, nil, _observer, hold) do
    assert_receive {^hold, :held, cleanup}, @detection_timeout_ms
    cleanup
  end

  defp delivery_entry(attempt_id), do: Enum.find(:sys.get_state(ActivityRegistry).delivery_receipts, fn {_token, entry} -> entry.identity.attempt_id == attempt_id end)

  defp original_history(opts) do
    runs = Keyword.get(opts, :historical_mailbox_runs, 0)

    history =
      if runs > 0 do
        Enum.flat_map(1..runs, fn index ->
          [Map.put(reasoning_item(), "id", "rs_historical_#{index}"), mailbox_item()]
        end)
      else
        []
      end

    [user_item("question")] ++ history ++ [function_call(), function_output()]
  end

  defp observe_socket_cancellation!(socket) do
    ref = make_ref()
    registry = Process.whereis(ActivityRegistry)
    on_exit(fn -> :sys.remove(registry, ref) end)
    observer = %{test: self(), ref: ref, socket: socket, pending: nil}
    :ok = :sys.install(registry, {ref, &observe_socket_cancellation/3, observer})
    ref
  end

  defp observe_socket_cancellation(%{socket: socket} = observer, {:in, {:"$gen_call", {socket, _reply} = from, {:cancel_unless_settling, _task, :websocket_terminated}}}, _name),
    do: %{observer | pending: from}

  defp observe_socket_cancellation(%{pending: from} = observer, {:out, result, from, _state}, _name) when not is_nil(from) do
    send(observer.test, {observer.ref, result})
    :done
  end

  defp observe_socket_cancellation(observer, _event, _name), do: observer

  defp install_settlement_stall!(pool_id) do
    install_database_stall!("requests", "NEW.pool_id = '#{pool_id}'::uuid AND NEW.status = 'failed' AND OLD.status IS DISTINCT FROM NEW.status")
  end

  defp install_stall!(setup, opts) do
    cond do
      Keyword.get(opts, :settlement_stall?, false) -> {install_settlement_stall!(setup.pool.id), nil}
      Keyword.get(opts, :receipt_stall?, false) -> {nil, install_receipt_stall!(setup.model.id)}
      true -> {nil, nil}
    end
  end

  defp install_receipt_stall!(model_id) do
    install_database_stall!("attempts", "NEW.model_id = '#{model_id}'::uuid AND NEW.response_metadata ? 'downstream_delivery' AND NOT COALESCE(OLD.response_metadata ? 'downstream_delivery', false)")
  end

  defp install_database_stall!(table, condition) do
    suffix = System.unique_integer([:positive])
    name = "mailbox_settlement_gate_#{suffix}"
    key = 336_000_000 + suffix

    UnboxedFixture.register_unboxed_cleanup!(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{name} ON #{table}")
      Repo.query!("DROP FUNCTION IF EXISTS #{name}()")
      Repo.query!("DROP SEQUENCE IF EXISTS #{name}_passes")
    end)

    Repo.query!("CREATE SEQUENCE #{name}_passes")
    Repo.query!("CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM nextval('#{name}_passes'); PERFORM pg_advisory_xact_lock(#{key}); RETURN NULL; END $$")
    Repo.query!("CREATE CONSTRAINT TRIGGER #{name} AFTER UPDATE ON #{table} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (#{condition}) EXECUTE FUNCTION #{name}()")
    options = Repo.config() |> Keyword.take([:hostname, :port, :username, :password, :database, :socket_dir])
    observer = start_supervised!({Postgrex, options}, id: {:observer, key})
    holder = start_supervised!({Postgrex, options}, id: {:holder, key})
    %{rows: [[backend]]} = Postgrex.query!(holder, "SELECT pg_backend_pid()", [])
    Postgrex.query!(holder, "SELECT pg_advisory_lock($1)", [key])
    %{observer: observer, holder: holder, backend: backend, key: key, name: name}
  end

  defp await_stalled_commit!(stall, pass), do: await_stalled_commit!(stall, pass, System.monotonic_time(:millisecond) + @detection_timeout_ms)

  defp await_stalled_commit!(stall, pass, deadline) do
    %{rows: waiters} = Postgrex.query!(stall.observer, "SELECT pid FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))", [stall.backend])
    %{rows: [[value, called?]]} = Postgrex.query!(stall.observer, "SELECT last_value, is_called FROM #{stall.name}_passes", [])

    if called? and value >= pass and match?([[_]], waiters) do
      [[backend]] = waiters
      backend
    else
      assert System.monotonic_time(:millisecond) < deadline, "settlement never reached COMMIT #{pass}"
      Process.sleep(10)
      await_stalled_commit!(stall, pass, deadline)
    end
  end

  defp await_interrupted_receipt!(request_id), do: await_interrupted_receipt!(request_id, System.monotonic_time(:millisecond) + @detection_timeout_ms)

  defp await_interrupted_receipt!(request_id, deadline) do
    [attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request_id))

    case attempt.response_metadata["downstream_delivery"] do
      %{"outcome" => "aborted", "terminal_class" => "none", "completed_items" => 1} ->
        :ok

      _other ->
        assert System.monotonic_time(:millisecond) < deadline, "interrupted delivery receipt was not persisted"
        Process.sleep(10)
        await_interrupted_receipt!(request_id, deadline)
    end
  end

  defp assert_accounting!(pool_id, mode) do
    assert [predecessor, successor] = request_logs(pool_id)
    assert {predecessor.status, predecessor.response_status_code, predecessor.last_error_code} == {"failed", 499, "client_disconnected"}
    assert {successor.status, successor.response_status_code} == {"succeeded", 200}
    assert Repo.one!(from(entry in LedgerEntry, where: entry.request_id == ^predecessor.id and entry.entry_kind == "settlement" and entry.amount_status == "recorded", select: entry.usage_status)) == "usage_unknown"

    for request <- [predecessor, successor] do
      assert request.request_metadata["routing"]["model_serving_mode"] == mode
      kinds = Repo.all(from(entry in LedgerEntry, where: entry.request_id == ^request.id, select: entry.entry_kind))
      assert Enum.frequencies(kinds) == %{"reservation" => 1, "release" => 1, "settlement" => 1}
      assert Repo.aggregate(from(entry in LedgerEntry, where: entry.request_id == ^request.id and entry.entry_kind == "settlement" and entry.amount_status == "recorded"), :count) == 1
    end
  end

  defp topology_setup!(:peer, upstream) do
    enter_peer_owner_topology!()
    setup = gateway_setup(upstream)
    Map.put(setup, :peer_owner, start_peer_window_owner!(setup, @window_id))
  end

  defp topology_setup!(:local, upstream), do: gateway_setup(upstream)

  defp owner_pid(:peer, setup), do: setup.peer_owner.owner_pid

  defp owner_pid(:local, setup) do
    [session_id] = Repo.all(from(session in CodexSession, where: session.pool_id == ^setup.pool.id, select: session.id))
    assert {:ok, owner} = WebsocketOwnerSession.lookup(session_id)
    owner
  end

  defp hold_session_cleanup!(socket) do
    hold = make_ref()
    handler_id = {__MODULE__, hold}
    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok = :telemetry.attach(handler_id, [:codex_pooler, :repo, :query], &__MODULE__.hold_session_cleanup_query/4, %{hold: hold, test: self(), socket: socket})
    hold
  end

  @doc false
  def hold_session_cleanup_query(_event, _measurements, _metadata, %{hold: hold, test: test, socket: socket}) do
    if socket in Process.get(:"$callers", []) and match?({CodexPoolerWeb.WebsocketControlPath, _function, _arity}, Process.get(:"$initial_call")) and is_nil(Process.get({__MODULE__, hold})) do
      Process.put({__MODULE__, hold}, :held)
      monitor = Process.monitor(test)
      send(test, {hold, :held, self()})

      receive do
        {^hold, :release} -> :ok
        {:DOWN, ^monitor, :process, ^test, _reason} -> :ok
      after
        @detection_timeout_ms -> :ok
      end

      Process.demonitor(monitor, [:flush])
    end

    :ok
  end

  defp connect!(port, setup, mode) do
    headers = [{"x-codex-window-id", @window_id}]
    headers = if mode == "lite", do: [{"x-openai-internal-codex-responses-lite", "true"} | headers], else: headers
    {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, Ecto.UUID.generate(), "/backend-api/codex/responses", headers)
    {conn, websocket, ref}
  end

  defp expected_request(respond), do: FakeUpstream.expect_request(path: "/backend-api/codex/responses", json: [valid: true, equals: %{"type" => "response.create"}], respond: respond)

  defp payload(setup, input, turn_id) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "stream" => true,
      "store" => false,
      "tools" => [],
      "client_metadata" => %{
        "session_id" => @thread_id,
        "thread_id" => @thread_id,
        "turn_id" => turn_id,
        "x-codex-window-id" => @window_id,
        "x-codex-turn-metadata" => encode(%{"session_id" => @thread_id, "thread_id" => @thread_id, "turn_id" => turn_id, "request_kind" => "turn", "agent_name" => "/root"})
      },
      "input" => input
    }
  end

  defp user_item(text), do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic " <> text}]}
  defp function_call, do: %{"type" => "function_call", "call_id" => "call_mailbox", "name" => "shell", "arguments" => "{}"}
  defp function_output, do: %{"type" => "function_call_output", "call_id" => "call_mailbox", "output" => "synthetic output"}
  defp mailbox_item, do: %{"type" => "agent_message", "author" => "/root/worker", "recipient" => "/root", "content" => [%{"type" => "input_text", "text" => "synthetic task update"}]}
  defp reasoning_item, do: %{"type" => "reasoning", "id" => "rs_mailbox", "summary" => [], "status" => "completed"}

  defp reasoning_frames do
    [
      %{"type" => "response.created", "response" => %{"id" => "resp_mailbox_predecessor", "status" => "in_progress", "output" => []}},
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => Map.put(reasoning_item(), "status", "in_progress")},
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => reasoning_item()}
    ]
  end

  defp completed_frame(id), do: %{"type" => "response.completed", "response" => %{"id" => id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}
  defp encode(map), do: CodexPooler.JSON.encode!(map)

  defp receive_types!(conn, websocket, ref, count) do
    Enum.reduce(1..count, {conn, websocket, []}, fn _index, {conn, websocket, types} ->
      {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
      {conn, websocket, types ++ [CodexPooler.JSON.decode!(text)["type"]]}
    end)
  end
end
