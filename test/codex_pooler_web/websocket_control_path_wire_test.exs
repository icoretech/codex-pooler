defmodule CodexPoolerWeb.WebsocketControlPathWireTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession}
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence
  import ExUnit.CaptureLog
  import CodexPooler.PoolerFixtures

  @shutdown_budget 15_000

  defmodule Endpoint do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, state) do
      conn |> WebSockAdapter.upgrade(__MODULE__.Socket, state, compress: false) |> halt()
    end

    defmodule Socket do
      @behaviour WebSock
      def init(state) do
        result = CodexResponsesSocket.init(state)

        cond do
          match?({:ok, _}, result) -> send(state.test_parent, {:socket_ready, self(), elem(result, 1)})
          is_map_key(state, :test_parent) -> send(state.test_parent, {:socket_refused, self()})
          true -> :ok
        end

        result
      end

      def handle_in(frame, state) do
        result = CodexResponsesSocket.handle_in(frame, state)
        if is_map_key(state, :test_parent), do: send(state.test_parent, {:socket_handled_in, self(), state, result})
        result
      end

      def handle_info(message, state), do: CodexResponsesSocket.handle_info(message, state)
      def terminate(reason, state), do: CodexResponsesSocket.terminate(reason, state)
    end
  end

  @tag capture_log: true
  test "a stalled owner detach cannot hold the real downstream close frame" do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    %{api_key: key, pool: pool} = active_api_key_fixture()

    on_exit(fn ->
      for session <- Repo.all(from(s in CodexSession, where: s.pool_id == ^pool.id)) do
        case WebsocketOwnerSession.lookup(session.id) do
          {:ok, owner} ->
            :sys.resume(owner)
            stop_owner!(owner)

          {:error, :owner_unavailable} ->
            :ok
        end
      end
    end)

    state = %{
      auth: %{api_key: key, pool: pool},
      test_parent: self(),
      opts: RequestOptions.for_websocket(%{})
    }

    server =
      start_supervised!({Bandit, plug: {Endpoint, state}, port: 0, ip: {127, 0, 0, 1}, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1], mode: :passive)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/", [])
    {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, 15_000)
    {:headers, ^ref, headers} = Enum.find(responses, &match?({:headers, _, _}, &1))
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, 101, headers, mode: :passive)
    assert_receive {:socket_ready, socket, runtime}, 15_000
    parent = self()
    handler = make_ref()

    on_exit(fn -> :telemetry.detach(handler) end)

    :telemetry.attach_many(
      handler,
      [
        [:codex_pooler, :gateway, :websocket_control, :cleanup_finished],
        [:codex_pooler, :gateway, :websocket_control, :failure]
      ],
      fn event, _, metadata, _ ->
        case List.last(event) do
          :cleanup_finished ->
            if metadata.caller == socket,
              do: send(parent, {:socket_cleanup_finished, handler, self()})

          :failure ->
            if self() == socket,
              do: send(parent, {:socket_cleanup_failure, handler, metadata})
        end
      end,
      nil
    )

    assert {:ok, owner} = WebsocketOwnerSession.lookup(runtime.codex_session.id)
    socket_monitor = Process.monitor(socket)
    :ok = :sys.suspend(owner)

    logs =
      capture_log(fn ->
        try do
          {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:close, 1000, ""})
          {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
          {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, 2_000)
          data = for {:data, ^ref, data} <- responses, do: data
          {:ok, _, frames} = Mint.WebSocket.decode(websocket, IO.iodata_to_binary(data))
          assert [{:close, 1000, _}] = frames
          Mint.HTTP.close(conn)

          assert_receive {:socket_cleanup_failure, ^handler, %{phase: :terminate, reason: :cleanup_deferred}},
                         @shutdown_budget

          assert Process.alive?(owner)
        after
          :sys.resume(owner)
          assert_receive {:socket_cleanup_finished, ^handler, cleanup}, @shutdown_budget
          await_down!(cleanup, Process.monitor(cleanup), @shutdown_budget)
          await_down!(socket, socket_monitor, @shutdown_budget)
          stop_owner!(owner)
        end
      end)

    assert ["websocket control path failed phase=terminate reason=cleanup_deferred"] =
             logs
             |> String.split("\n", trim: true)
             |> Enum.map(&String.replace(&1, ~r/^.*\[warning\] /, ""))

    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(runtime.codex_session.id)
    lease = Repo.get_by!(BridgeOwnerLease, codex_session_id: runtime.codex_session.id)
    assert lease.released_at
    assert Repo.aggregate(CodexPooler.Accounting.Request, :count) == 0

    CodexPooler.TestDiagnostics.puts("wire_cleanup caller_down=true task_down=true owner_down=true registry_absent=true lease_released=true requests=0 expected_deferral=1")
  end

  @tag capture_log: true
  test "a real database failure during init sends a 1011 close after upgrade" do
    %{api_key: key, pool: pool} = active_api_key_fixture()

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_socket_start() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'synthetic socket database failure'; END $$
    """)

    Repo.query!("CREATE TRIGGER reject_socket_start BEFORE INSERT ON codex_sessions FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_socket_start()")

    state = %{auth: %{api_key: key, pool: pool}, opts: RequestOptions.for_websocket(%{})}

    server =
      start_supervised!({Bandit, plug: {Endpoint, state}, port: 0, ip: {127, 0, 0, 1}, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1], mode: :passive)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/", [])
    {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, 15_000)
    assert {:status, ^ref, 101} = Enum.find(responses, &match?({:status, _, _}, &1))
    {:headers, ^ref, headers} = Enum.find(responses, &match?({:headers, _, _}, &1))
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, 101, headers, mode: :passive)
    data = for {:data, ^ref, data} <- responses, do: data

    {conn, data} =
      if data == [] do
        {:ok, conn, more} = Mint.WebSocket.recv(conn, 0, 15_000)
        {conn, for({:data, ^ref, data} <- more, do: data)}
      else
        {conn, data}
      end

    {:ok, _, frames} = Mint.WebSocket.decode(websocket, IO.iodata_to_binary(data))
    assert [{:close, 1011, "websocket initialization unavailable"}] = frames
    assert Repo.aggregate(CodexPooler.Accounting.Request, :count) == 0
    assert Repo.aggregate(CodexPooler.Gateway.Persistence.CodexSession, :count) == 0
    Mint.HTTP.close(conn)
  end

  # The released Codex client writes its first `response.create` right after
  # the 101 without waiting for anything else, so a refused init always meets
  # that frame while Bandit is closing: Bandit still hands it to `handle_in/2`
  # with the state init returned, which used to start a response task on the
  # refused connection (plain) or raise in the control path (owner forwarding)
  # (findings#255).
  for forwarding? <- [false, true] do
    @tag capture_log: true
    test "a client frame racing an owner refusal at init is ignored (owner forwarding #{forwarding?})" do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, unquote(forwarding?))
      %{api_key: key, pool: pool} = active_api_key_fixture()

      opts =
        %{request_id: "ws-refused-owner-#{System.unique_integer([:positive])}", previous_response_id: "resp_missing_refused_owner"}
        |> RequestOptions.for_websocket()
        |> RequestOptions.put_continuity(authenticated_owner_attach: true)

      result = refused_upgrade_with_racing_frame!(%{auth: %{api_key: key, pool: pool}, test_parent: self(), opts: opts})

      assert {:close, 1011, "websocket owner is unavailable"} = result.close
      assert [{refused_state, {:ok, refused_state}}] = result.handled_in
      assert result.control_failures == []
      assert ["websocket init failed before request reservation " <> _] = warning_lines(result.logs)
      assert Repo.aggregate(CodexPooler.Accounting.Request, :count) == 0
    end
  end

  @tag capture_log: true
  test "a client frame racing a database failure at init is ignored" do
    %{api_key: key, pool: pool} = active_api_key_fixture()

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_racing_socket_start() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'synthetic socket database failure'; END $$
    """)

    Repo.query!("CREATE TRIGGER reject_racing_socket_start BEFORE INSERT ON codex_sessions FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_racing_socket_start()")

    result = refused_upgrade_with_racing_frame!(%{auth: %{api_key: key, pool: pool}, test_parent: self(), opts: RequestOptions.for_websocket(%{})})

    assert {:close, 1011, "websocket initialization unavailable"} = result.close
    assert [{refused_state, {:ok, refused_state}}] = result.handled_in
    assert [%{phase: :init, reason: :database_error}] = result.control_failures
    assert ["websocket control path failed phase=init reason=database_error"] = warning_lines(result.logs)
    assert Repo.aggregate(CodexPooler.Accounting.Request, :count) == 0
    assert Repo.aggregate(CodexPooler.Gateway.Persistence.CodexSession, :count) == 0
  end

  # A stop returned after init (here the owner crash close) runs `terminate/2`
  # at once, yet Bandit keeps handing the frames that race the close to
  # `handle_in/2` with the stopped state until the client's close arrives.
  @tag capture_log: true
  test "a client frame racing a close after init is ignored instead of reopening the stopped socket" do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    %{api_key: key, pool: pool} = active_api_key_fixture()

    on_exit(fn ->
      for session <- Repo.all(from(s in CodexSession, where: s.pool_id == ^pool.id)) do
        case WebsocketOwnerSession.lookup(session.id) do
          {:ok, owner} -> stop_owner!(owner)
          {:error, :owner_unavailable} -> :ok
        end
      end
    end)

    state = %{auth: %{api_key: key, pool: pool}, test_parent: self(), opts: RequestOptions.for_websocket(%{})}
    server = start_supervised!({Bandit, plug: {Endpoint, state}, port: 0, ip: {127, 0, 0, 1}, startup_log: false})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    parent = self()
    handler = make_ref()
    on_exit(fn -> :telemetry.detach(handler) end)

    :telemetry.attach(
      handler,
      [:codex_pooler, :gateway, :websocket_control, :cleanup_finished],
      fn _event, _measurements, %{caller: caller}, _config -> send(parent, {:cleanup_finished, handler, caller}) end,
      nil
    )

    logs =
      capture_log(fn ->
        {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1], mode: :passive)
        {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/", [])
        {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, 15_000)
        {:headers, ^ref, headers} = Enum.find(responses, &match?({:headers, _, _}, &1))
        {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, 101, headers, mode: :passive)
        assert_receive {:socket_ready, socket, runtime}, 15_000
        socket_monitor = Process.monitor(socket)
        assert {:ok, owner} = WebsocketOwnerSession.lookup(runtime.codex_session.id)
        owner_monitor = Process.monitor(owner)
        Process.exit(owner, :kill)
        assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, @shutdown_budget

        {conn, websocket, close} = await_server_close!(conn, ref, websocket, [], :keep_open)
        assert {:close, 1011, "websocket owner crashed"} = close

        frame = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => "synthetic-model", "input" => []})
        {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, frame})
        {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
        {:ok, _websocket, data} = Mint.WebSocket.encode(websocket, {:close, 1000, ""})
        {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
        await_down!(socket, socket_monitor, @shutdown_budget)
        assert_receive {:cleanup_finished, ^handler, ^socket}, @shutdown_budget
        Mint.HTTP.close(conn)
        send(self(), {:stopped_socket, socket, runtime.codex_session.id})
      end)

    assert_received {:stopped_socket, socket, session_id}
    assert [{stopped_state, {:ok, stopped_state}}] = for({:socket_handled_in, ^socket, state_in, result} <- drain_messages(), do: {state_in, result})
    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(session_id)
    logs = WebsocketCleanupFence.without_deferred_cleanup(logs)
    refute logs =~ "websocket control path failed"
    refute logs =~ "websocket response task failed"
    assert Repo.aggregate(CodexPooler.Accounting.Request, :count) == 0
  end

  test "completion fence rejects a live process without a terminal signal" do
    monitor = Process.monitor(self())

    try do
      assert_raise ExUnit.AssertionError, fn -> await_down!(self(), monitor, 0) end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  test "completion fence waits for a delayed owner exit" do
    parent = self()
    owner = start_supervised!({Task, fn -> receive do: (:release -> :ok) end})

    waiter =
      Task.async(fn ->
        monitor = Process.monitor(owner)
        send(parent, :fence_ready)
        await_down!(owner, monitor, @shutdown_budget)
      end)

    waiter_monitor = Process.monitor(waiter.pid)
    assert_receive :fence_ready
    assert Process.alive?(owner)
    refute_received {_, :ok}
    send(owner, :release)
    assert :ok = Task.await(waiter, @shutdown_budget)
    await_down!(waiter.pid, waiter_monitor, @shutdown_budget)
  end

  # Upgrades, sends one text frame and a close without waiting for the
  # server's close, and returns the server's first close frame, the control
  # path failures the socket process emitted up to its exit, and the logs.
  defp refused_upgrade_with_racing_frame!(state) do
    parent = self()
    handler = make_ref()
    on_exit(fn -> :telemetry.detach(handler) end)

    :telemetry.attach_many(
      handler,
      [
        [:codex_pooler, :gateway, :websocket_control, :failure],
        [:codex_pooler, :gateway, :websocket_control, :cleanup_finished]
      ],
      fn
        [_, _, _, :failure], _measurements, metadata, _config -> send(parent, {:control_failure, handler, self(), metadata})
        [_, _, _, :cleanup_finished], _measurements, %{caller: caller}, _config -> send(parent, {:cleanup_finished, handler, caller})
      end,
      nil
    )

    server = start_supervised!({Bandit, plug: {Endpoint, state}, port: 0, ip: {127, 0, 0, 1}, startup_log: false})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    logs =
      capture_log(fn ->
        {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1], mode: :passive)
        {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/", [])
        {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, 15_000)
        assert {:status, ^ref, 101} = Enum.find(responses, &match?({:status, _, _}, &1))
        {:headers, ^ref, headers} = Enum.find(responses, &match?({:headers, _, _}, &1))
        {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, 101, headers, mode: :passive)
        assert_receive {:socket_refused, socket}, 15_000
        socket_monitor = Process.monitor(socket)

        frame = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => "synthetic-model", "input" => []})
        {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, frame})
        {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
        {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:close, 1000, ""})
        {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)

        server_data = for {:data, ^ref, data} <- responses, do: data
        close = await_server_close!(conn, ref, websocket, server_data)
        await_down!(socket, socket_monitor, @shutdown_budget)
        # The socket's session cleanup can outlast terminate/2; its lines belong
        # to this capture.
        assert_receive {:cleanup_finished, ^handler, ^socket}, @shutdown_budget
        send(parent, {:server_close, handler, close, socket})
      end)

    assert_received {:server_close, ^handler, close, socket}
    messages = drain_messages()
    # A cleanup that outlasted the 100 ms yield is a scheduling outcome, not part
    # of these claims; it is reported apart.
    {deferred, failures} =
      for({:control_failure, ^handler, ^socket, metadata} <- messages, do: metadata)
      |> Enum.split_with(&match?(%{phase: :terminate, reason: :cleanup_deferred}, &1))

    handled = for {:socket_handled_in, ^socket, state_in, result} <- messages, do: {state_in, result}

    %{
      close: close,
      control_failures: failures,
      deferred_cleanups: length(deferred),
      handled_in: handled,
      logs: WebsocketCleanupFence.without_deferred_cleanup(logs)
    }
  end

  defp await_server_close!(conn, ref, websocket, data, mode \\ :close) do
    {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, IO.iodata_to_binary(data))

    case {Enum.find(frames, &match?({:close, _, _}, &1)), mode} do
      {nil, _mode} ->
        {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, 15_000)
        await_server_close!(conn, ref, websocket, for({:data, ^ref, more} <- responses, do: more), mode)

      {close, :keep_open} ->
        {conn, websocket, close}

      {close, :close} ->
        Mint.HTTP.close(conn)
        close
    end
  end

  defp warning_lines(logs) do
    for line <- String.split(logs, "\n", trim: true), line =~ ~r/\[(warning|error)\] /, do: String.replace(line, ~r/^.*\[(warning|error)\] /, "")
  end

  defp drain_messages do
    receive do
      message -> [message | drain_messages()]
    after
      0 -> []
    end
  end

  defp stop_owner!(owner) do
    monitor = Process.monitor(owner)

    try do
      GenServer.stop(owner, :shutdown, @shutdown_budget)
    catch
      :exit, {:noproc, _} -> :ok
      :exit, {:normal, _} -> :ok
    end

    await_down!(owner, monitor, @shutdown_budget)
  end

  defp await_down!(pid, monitor, budget) do
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, budget
    assert reason in [:normal, :shutdown, :noproc, {:shutdown, :local_closed}]
    refute Process.alive?(pid)
    :ok
  end
end
