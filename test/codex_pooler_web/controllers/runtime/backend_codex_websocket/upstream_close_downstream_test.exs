defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.UpstreamCloseDownstreamTest do
  # A `previous_response_id` resolves only on the upstream websocket connection
  # that produced it. When the provider closes that connection between two
  # requests (its connection-age limit with 1000, a service restart with 1012),
  # a client connected to it directly sees the close and sends its next
  # request whole on a new connection; behind the Pooler the client used to
  # keep its socket, anchor the next request on the closed connection's
  # response and meet `previous_response_not_found` first (findings#270). The
  # native socket now closes its idle client with 1001 once the upstream
  # connection closed, so the next request goes out whole on a new socket.
  #
  # One node, owner forwarding off, native websocket `/backend-api/codex/responses`
  # and its `/backend-api/codex/v1/responses` alias, the Pool's serving mode
  # forced to Full and to Lite, FakeUpstream, the released client's turn frames
  # (turn metadata naming thread and turn), synthetic text. The client drops
  # its connection without answering the Close, as the released client does.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport
  import CodexPooler.AccountingTestSupport, only: [key_usage_events: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Accounts.User
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  # Detection budget for a settlement or a server-side teardown the test only
  # observes.
  @detection_timeout_ms 15_000

  @upstream_close {:close, 1001, "upstream connection closed"}
  @api_key_close {:close, 1008, "api key is no longer active"}
  @turn_path "/backend-api/codex/responses"
  @tool_call %{"type" => "function_call", "call_id" => "call_upstream_close_sample", "name" => "sample_lookup", "arguments" => "{}"}
  @tool_output %{"type" => "function_call_output", "call_id" => "call_upstream_close_sample", "output" => "sample output"}

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
    :ok
  end

  # The provider's close right after a turn that asked for a tool: the idle
  # socket closes 1001 after the turn's terminal, the client resends the turn
  # whole with the tool output on a new socket, and it is served on a new
  # upstream connection, on the session's assignment, without an anchor. No
  # request is refused, and the resend pays its own known usage only.
  for mode <- ["full", "lite"], close_code <- [1000, 1012] do
    @tag serving_mode: mode, close_code: close_code
    test "a #{mode} socket closes 1001 after the provider closes its connection with #{close_code} and the whole resend is served", ctx do
      assert_idle_close_and_resend!(ctx.serving_mode, ctx.close_code, @turn_path)
    end
  end

  # The alias route runs the same native socket.
  test "the /backend-api/codex/v1/responses alias closes 1001 the same way" do
    assert_idle_close_and_resend!("full", 1000, "/backend-api/codex/v1/responses")
  end

  # A connection the provider drops without a Close frame is gone as well.
  test "a transport close of the upstream connection closes the idle socket with reason transport_closed" do
    first_input = native_text_input("upstream transport close")

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (a TCP close right after the terminal)
        FakeUpstream.strict_sequence([
          anchorless_request(1, FakeUpstream.websocket_text_frames_then_abrupt_close(Enum.map(completed_response_events("resp_ws_upstream_transport_close", [@tool_call], 2, 1), &CodexPooler.JSON.encode!/1)))
        ])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "ws-upstream-transport-close-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread, @turn_path)
    frame = released_client_frame(setup, thread)

    {frames, log} =
      with_info_log(fn ->
        {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(first_input, Ecto.UUID.generate(), %{}))
        {conn, _websocket, frames} = receive_frames_until_close!(conn, websocket, client.ref)
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
        frames
      end)

    assert {[%{"type" => "response.completed"}], [@upstream_close]} = split_turn_frames(frames)
    assert log =~ "upstream websocket connection closed between requests reason_code=transport_closed closed_by=peer "
    assert_upstream_close_lines!(log, [downstream_closed_line("transport_closed", client.lifecycle_id, 1)])
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # A provider idle close long after the turn: the socket is idle already and
  # closes at once.
  test "an upstream connection closed while the socket is idle closes the socket at once" do
    first_input = native_text_input("idle upstream close")

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (the provider's idle close, 1012)
        FakeUpstream.strict_sequence([anchorless_request(1, completed_response_frames("resp_ws_idle_upstream_close", [@tool_call], 2, 1))])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "ws-idle-upstream-close-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread, @turn_path)
    frame = released_client_frame(setup, thread)

    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(first_input, Ecto.UUID.generate(), %{}))
    {conn, websocket, terminal} = receive_native_terminal!(conn, websocket, client.ref)
    assert %{"type" => "response.completed"} = terminal
    assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
    _state = await_socket_connection_state!(client.socket, &(MapSet.size(&1.tasks) == 0))
    close_ref = make_ref()

    {frames, log} =
      with_info_log(fn ->
        assert :ok = FakeUpstream.close_websocket_connection(upstream, 1, close_ref: close_ref, notify: self(), code: 1012, reason: "synthetic restart")
        assert_receive {:fake_upstream_websocket_peer_closed, 1, ^close_ref}, @detection_timeout_ms
        {conn, _websocket, frames} = receive_frames_until_close!(conn, websocket, client.ref)
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
        frames
      end)

    assert frames == [@upstream_close]
    assert log =~ "upstream websocket connection closed between requests reason_code=peer_close_frame closed_by=peer close_code=1012 "
    assert_upstream_close_lines!(log, [downstream_closed_line("peer_close_frame", client.lifecycle_id, 1)])
    assert_quiet_close!(log)
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # With owner forwarding off the socket hears of a closed upstream connection
  # from the session that held it, and the same session writes every response
  # chunk to the socket: the socket's writer runs in the session process. One
  # sender for both is what orders the close of one connection before any
  # chunk served on the next, so the socket never takes an earlier close for
  # the connection its latest response rode on (findings#270 rows 270-199 and
  # 270-205). The session's sends and the socket's receives are traced (the
  # session's sensitivity is lifted from inside it first) and must match,
  # message for message.
  test "the session is the one sender of the socket's response chunks and of its close signal" do
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (one turn, then the provider's close, 1000)
        FakeUpstream.strict_sequence([anchorless_request(1, completed_response_frames("resp_ws_single_sender", [@tool_call], 2, 1))])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "ws-single-sender-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread, @turn_path)
    session = socket_connection_state!(client.socket).upstream_websocket_session
    tracer = trace_socket_deliveries!(session, client.socket)
    frame = released_client_frame(setup, thread)

    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(native_text_input("single sender"), Ecto.UUID.generate(), %{}))
    {conn, websocket, terminal} = receive_native_terminal!(conn, websocket, client.ref)
    assert %{"type" => "response.completed"} = terminal
    _state = await_socket_connection_state!(client.socket, &(MapSet.size(&1.tasks) == 0))
    close_ref = make_ref()
    assert :ok = FakeUpstream.close_websocket_connection(upstream, 1, close_ref: close_ref, notify: self(), code: 1000, reason: "synthetic age limit")
    assert_receive {:fake_upstream_websocket_peer_closed, 1, ^close_ref}, @detection_timeout_ms
    {conn, _websocket, frames} = receive_frames_until_close!(conn, websocket, client.ref)
    Mint.HTTP.close(conn)
    :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
    assert frames == [@upstream_close]

    {sent, received} = socket_deliveries!(tracer)
    assert [{:upstream_websocket_connection_closed, ^session, %{cause: :peer_close_frame}} | chunks] = Enum.reverse(received)
    assert chunks != [] and Enum.all?(chunks, &match?({:codex_response_chunk, _task_pid, _data}, &1))
    assert sent == received
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # The provider's close arrives while the turn's response task is still
  # settling (the socket stops tracking a task only after its settlement,
  # 100 ms to over a second under load, while a provider close can come less
  # than a second after the turn). The socket latches the close and stays
  # open until the task is delivered, then closes after the terminal.
  test "a close that arrives while the turn is still settling waits for the turn and then closes" do
    hold = hold_settled_websocket_turn!()
    first_input = native_text_input("deferred upstream close")

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (close 1000 right after the terminal)
        FakeUpstream.strict_sequence([anchorless_request(1, closing_turn("resp_ws_deferred_upstream_close", 1000))])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "ws-deferred-upstream-close-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread, @turn_path)
    frame = released_client_frame(setup, thread)

    {frames, log} =
      with_info_log(fn ->
        {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(first_input, Ecto.UUID.generate(), %{}))
        {conn, websocket, terminal} = receive_native_terminal!(conn, websocket, client.ref)
        assert %{"type" => "response.completed"} = terminal
        assert_receive {^hold, :held, task}, @detection_timeout_ms

        latched = await_socket_connection_state!(client.socket, &Map.has_key?(&1, :upstream_close_pending))
        assert %{cause: :peer_close_frame, lifecycle_id: lifecycle_id, generation: 1, forwarding: :off} = latched.upstream_close_pending
        assert lifecycle_id == client.lifecycle_id
        assert MapSet.member?(latched.tasks, task)

        # Still open while the turn settles: the barrier is answered.
        {conn, websocket} = socket_transport_barrier!(conn, websocket, client.ref)

        :ok = release_settled_websocket_turn(hold, task)
        {conn, _websocket, frames} = receive_frames_until_close!(conn, websocket, client.ref)
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
        frames
      end)

    assert frames == [@upstream_close]
    assert_upstream_close_lines!(log, [downstream_closed_line("peer_close_frame", client.lifecycle_id, 1)])
    assert_quiet_close!(log)
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # The client's next request reaches the socket after the close was latched
  # but before the socket decided to close. A request anchored on the closed
  # connection's response can only meet the continuation guard's refusal, so
  # the close stays pending, the request waits behind the settling turn, and
  # the close takes its place (findings#270 row 270-302): nothing goes out
  # for it and no row is written. The client's whole resend on a new socket
  # is served. The socket used to drop the close for any client frame, and
  # the guard answered `previous_response_not_found` on a fresh connection.
  test "a client frame anchored on the closed connection's response is answered by the close" do
    hold = hold_settled_websocket_turn!()
    first_input = native_text_input("frame before decision")

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (close 1000 right after the terminal)
        FakeUpstream.strict_sequence([
          anchorless_request(1, closing_turn("resp_ws_frame_before_decision", 1000)),
          anchorless_request(2, completed_response_frames("resp_ws_frame_before_decision_resend", [], 4, 3))
        ])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "ws-frame-before-decision-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread, @turn_path)
    frame = released_client_frame(setup, thread)
    turn_id = Ecto.UUID.generate()

    {frames, log} =
      with_info_log(fn ->
        {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(first_input, turn_id, %{}))
        {conn, websocket, terminal} = receive_native_terminal!(conn, websocket, client.ref)
        assert %{"type" => "response.completed"} = terminal
        assert_receive {^hold, :held, task}, @detection_timeout_ms
        _latched = await_socket_connection_state!(client.socket, &Map.has_key?(&1, :upstream_close_pending))

        {conn, websocket} = public_websocket_send_text!(conn, websocket, client.ref, frame.([@tool_output], turn_id, %{"previous_response_id" => "resp_ws_frame_before_decision"}))
        {conn, websocket} = socket_transport_barrier!(conn, websocket, client.ref)
        assert Map.has_key?(socket_connection_state!(client.socket), :upstream_close_pending)

        :ok = release_settled_websocket_turn(hold, task)
        {conn, _websocket, frames} = receive_frames_until_close!(conn, websocket, client.ref)
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
        frames
      end)

    assert frames == [@upstream_close]
    assert_upstream_close_lines!(log, [downstream_closed_line("peer_close_frame", client.lifecycle_id, 1)])
    assert log =~ "queued_request=closed_anchor"
    assert [_opener] = FakeUpstream.requests(upstream)

    retry = connect!(port, setup, thread, @turn_path)
    {conn, websocket} = public_websocket_send_text!(retry.conn, retry.websocket, retry.ref, frame.(first_input ++ [@tool_call, @tool_output], turn_id, %{}))
    {conn, _websocket, resend_terminal} = receive_native_terminal!(conn, websocket, retry.ref)
    assert %{"type" => "response.completed", "response" => %{"id" => "resp_ws_frame_before_decision_resend"}} = resend_terminal
    assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
    Mint.HTTP.close(conn)

    assert [opener, resend] = await_settled_pool_requests!(setup, 2)
    assert {opener.status, resend.status} == {"succeeded", "succeeded"}
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # A client frame that is not anchored on the closed connection's response
  # (here the turn resent whole) can be served on a fresh connection: it drops
  # the close and is served, and the socket stays open. Nothing orders it
  # behind the settling turn (it is no continuation), so its frames can reach
  # the client before that turn settles: the test reads them up to the
  # terminal before it checks that the socket still answers.
  test "a client frame not anchored on the closed connection's response keeps the socket open and is served" do
    hold = hold_settled_websocket_turn!()
    first_input = native_text_input("unanchored frame before decision")

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (close 1000 right after the terminal)
        FakeUpstream.strict_sequence([
          anchorless_request(1, closing_turn("resp_ws_unanchored_frame", 1000)),
          anchorless_request(2, completed_response_frames("resp_ws_unanchored_frame_served", [], 4, 3))
        ])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "ws-unanchored-frame-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread, @turn_path)
    frame = released_client_frame(setup, thread)
    turn_id = Ecto.UUID.generate()

    {served, log} =
      with_info_log(fn ->
        {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(first_input, turn_id, %{}))
        {conn, websocket, terminal} = receive_native_terminal!(conn, websocket, client.ref)
        assert %{"type" => "response.completed"} = terminal
        assert_receive {^hold, :held, task}, @detection_timeout_ms
        _latched = await_socket_connection_state!(client.socket, &Map.has_key?(&1, :upstream_close_pending))

        {conn, websocket} = public_websocket_send_text!(conn, websocket, client.ref, frame.(first_input ++ [@tool_call, @tool_output], turn_id, %{}))
        # The socket handled the frame: it dropped the close.
        _dropped = await_socket_connection_state!(client.socket, &(not Map.has_key?(&1, :upstream_close_pending)))

        :ok = release_settled_websocket_turn(hold, task)
        {conn, websocket, served} = receive_native_terminal!(conn, websocket, client.ref)

        # Still open after the served request.
        {conn, _websocket} = socket_transport_barrier!(conn, websocket, client.ref)
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
        served
      end)

    assert %{"type" => "response.completed", "response" => %{"id" => "resp_ws_unanchored_frame_served"}} = served
    assert_upstream_close_lines!(log, [kept_open_line("peer_close_frame", "client_frame", client.lifecycle_id, 1)])
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # The client's frame crosses the Close on the wire: the socket is held while
  # the signal and then the frame queue up behind it, so the signal is handled
  # first, the socket closes, and the frame reaches only a stopped socket. It
  # starts nothing: no upstream request, no row. The Close follows an upstream
  # close that already happened, so nothing admitted on this socket can reach
  # a live connection and lose its answer. The client's retry is then served.
  test "a client frame that crosses the Close starts nothing and the retry is served" do
    first_input = native_text_input("frame crossing the close")

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          anchorless_request(1, completed_response_frames("resp_ws_frame_crossing_close", [@tool_call], 2, 1)),
          anchorless_request(2, completed_response_frames("resp_ws_frame_crossing_close_resend", [], 4, 3))
        ])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "ws-frame-crossing-close-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread, @turn_path)
    frame = released_client_frame(setup, thread)
    turn_id = Ecto.UUID.generate()

    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(first_input, turn_id, %{}))
    {conn, websocket, terminal} = receive_native_terminal!(conn, websocket, client.ref)
    assert %{"type" => "response.completed"} = terminal
    assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
    idle = await_socket_connection_state!(client.socket, &(MapSet.size(&1.tasks) == 0))
    session = idle.upstream_websocket_session
    close_ref = make_ref()

    {frames, log} =
      with_info_log(fn ->
        :ok = :sys.suspend(client.socket)

        {conn, websocket} =
          try do
            # A suspended process still answers system messages. Trace every
            # frame the listener hands the socket from this point onward.
            :ok = trace_socket_frames!(client.socket)
            assert :ok = FakeUpstream.close_websocket_connection(upstream, 1, close_ref: close_ref, notify: self(), code: 1000, reason: "synthetic age limit")
            assert_receive {:fake_upstream_websocket_peer_closed, 1, ^close_ref}, @detection_timeout_ms
            # The session sends the signal right after it drops the connection.
            :ok = await_session_disconnected!(session)
            assert {:message_queue_len, queued} = Process.info(client.socket, :message_queue_len)
            assert queued > 0

            {conn, websocket} = public_websocket_send_text!(conn, websocket, client.ref, frame.([@tool_output], turn_id, %{"previous_response_id" => "resp_ws_frame_crossing_close"}))
            {conn, websocket}
          after
            :ok = :sys.resume(client.socket)
          end

        {conn, _websocket, frames} = receive_frames_until_close!(conn, websocket, client.ref)
        # Bandit 1.14 discards frames after a server-initiated close instead
        # of calling WebSock with the closing state. The queued frame remains
        # a real wire-level crossing, but must produce no application callback.
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_teardown!(client.socket)
        socket = client.socket
        trace_delivery = :erlang.trace_delivered(socket)
        assert_receive {:trace_delivered, ^socket, ^trace_delivery}, @detection_timeout_ms
        refute_receive {:trace, ^socket, :call, {CodexResponsesSocket, :handle_in, [{_crossing, [opcode: :text]}, _handed]}}, 0
        frames
      end)

    assert frames == [@upstream_close]
    assert_upstream_close_lines!(log, [downstream_closed_line("peer_close_frame", client.lifecycle_id, 1)])
    assert [_opener] = FakeUpstream.requests(upstream)
    assert [_opener_row] = pool_requests(setup)

    retry = connect!(port, setup, thread, @turn_path)
    {conn, websocket} = public_websocket_send_text!(retry.conn, retry.websocket, retry.ref, frame.(first_input ++ [@tool_call, @tool_output], turn_id, %{}))
    {conn, _websocket, resend_terminal} = receive_native_terminal!(conn, websocket, retry.ref)
    assert %{"type" => "response.completed", "response" => %{"id" => "resp_ws_frame_crossing_close_resend"}} = resend_terminal
    assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
    Mint.HTTP.close(conn)

    assert [_opener, resend_request] = FakeUpstream.requests(upstream)
    assert resend_request.json["input"] == first_input ++ [@tool_call, @tool_output]
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # A socket whose last turn did not complete gives the client no response to
  # anchor on: it stays open.
  test "a socket whose last turn failed stays open after the upstream connection closes" do
    first_input = native_text_input("failed turn before close")

    failed_turn =
      FakeUpstream.websocket_sse_then_close(
        [
          %{"type" => "response.output_text.delta", "delta" => "synthetic partial"},
          %{"type" => "response.failed", "response" => %{"id" => "resp_ws_failed_before_close", "status" => "failed", "error" => %{"code" => "server_error", "message" => "synthetic failure"}}}
        ],
        code: 1000,
        reason: "synthetic age limit"
      )

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([anchorless_request(1, failed_turn)])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "ws-failed-before-close-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread, @turn_path)
    frame = released_client_frame(setup, thread)

    log =
      with_info_log(fn ->
        {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(first_input, Ecto.UUID.generate(), %{}))
        {conn, websocket, terminal} = receive_native_terminal!(conn, websocket, client.ref)
        assert %{"type" => "response.failed"} = terminal
        assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "failed"}}}, @detection_timeout_ms
        :ok = await_session_disconnected!(socket_connection_state!(client.socket).upstream_websocket_session)
        _state = await_socket_connection_state!(client.socket, &(MapSet.size(&1.tasks) == 0))
        {conn, _websocket} = socket_transport_barrier!(conn, websocket, client.ref)
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
      end)
      |> elem(1)

    assert_upstream_close_lines!(log, [kept_open_line("peer_close_frame", "no_completed_response", client.lifecycle_id, 1)])
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # A key revoked while the turn settles: the socket closes with the
  # revocation's 1008 once the turn is delivered, never with 1001.
  test "a revoked key closes 1008 even when the upstream connection closed first" do
    hold = hold_settled_websocket_turn!()
    first_input = native_text_input("revoked after upstream close")

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (close 1000 right after the terminal)
        FakeUpstream.strict_sequence([anchorless_request(1, closing_turn("resp_ws_revoked_after_close", 1000))])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "ws-revoked-after-close-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread, @turn_path)
    frame = released_client_frame(setup, thread)

    {frames, log} =
      with_info_log(fn ->
        {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(first_input, Ecto.UUID.generate(), %{}))
        {conn, websocket, terminal} = receive_native_terminal!(conn, websocket, client.ref)
        assert %{"type" => "response.completed"} = terminal
        assert_receive {^hold, :held, task}, @detection_timeout_ms
        _latched = await_socket_connection_state!(client.socket, &Map.has_key?(&1, :upstream_close_pending))

        assert {:ok, _paused} = CodexPooler.Access.pause_api_key(api_key_owner_scope(setup), setup.api_key)
        revoked = await_socket_connection_state!(client.socket, &Map.get(&1, :api_key_revoked?, false))
        refute Map.has_key?(revoked, :upstream_close_pending)

        :ok = release_settled_websocket_turn(hold, task)
        {conn, _websocket, frames} = receive_frames_until_close!(conn, websocket, client.ref)
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
        frames
      end)

    assert frames == [@api_key_close]
    assert_upstream_close_lines!(log, [kept_open_line("peer_close_frame", "revoked", client.lifecycle_id, 1)])
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # The public `/v1` websocket does not subscribe and stays open: the close is
  # fitted to the released Codex client, and `/v1` clients keep today's answer
  # to an anchor only the closed connection held.
  test "the public /v1/responses websocket stays open after its upstream connection closes" do
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (close 1000 right after the terminal)
        FakeUpstream.strict_sequence([
          anchorless_request(
            1,
            FakeUpstream.websocket_sse_then_close(
              [{"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_ws_public_upstream_close", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}}}}],
              code: 1000,
              reason: "synthetic upstream close"
            )
          )
        ])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    client = connect!(port, setup, "", "/v1/responses")
    session = socket_connection_state!(client.socket).upstream_websocket_session
    refute Map.has_key?(:sys.get_state(session), :connection_close_subscriber)

    payload = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => native_text_input("public upstream close"), "stream" => true, "generate" => true})

    log =
      with_info_log(fn ->
        {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, payload)
        {conn, websocket, terminal} = receive_native_terminal!(conn, websocket, client.ref)
        assert %{"type" => "response.completed"} = terminal
        assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
        :ok = await_session_disconnected!(session)
        _state = await_socket_connection_state!(client.socket, &(MapSet.size(&1.tasks) == 0))
        {conn, _websocket} = socket_transport_barrier!(conn, websocket, client.ref)
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
      end)
      |> elem(1)

    assert_upstream_close_lines!(log, [])
    assert :ok = FakeUpstream.verify!(upstream)
  end

  defp assert_idle_close_and_resend!(mode, close_code, path) do
    first_input = native_text_input("upstream close #{mode} #{close_code}")

    upstream =
      start_upstream(
        # The opener asks for a tool and the provider closes its connection
        # right after the terminal (its connection-age limit or a restart); the
        # whole resend is served on a new upstream connection.
        # provenance: synthetic_adversarial (close codes and their order after the terminal as attributed in findings#270; frames synthetic)
        FakeUpstream.strict_sequence([
          anchorless_request(1, closing_turn("resp_ws_upstream_close_opener", close_code)),
          anchorless_request(2, completed_response_frames("resp_ws_upstream_close_resend", [], 4, 3))
        ])
      )

    setup = upstream_close_setup(upstream, mode)
    second = gateway_upstream(setup.pool, upstream, "upstream-token-second", compact?: false)
    prime_routing_quota!(second.identity)
    setup = %{setup | model: put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])}

    {_server, port} = start_public_endpoint_with_server!()
    thread = "ws-upstream-close-#{mode}-#{close_code}-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread, path)
    frame = released_client_frame(setup, thread)
    turn_id = Ecto.UUID.generate()

    # The socket itself is its upstream session's close subscriber.
    assert :sys.get_state(socket_connection_state!(client.socket).upstream_websocket_session).connection_close_subscriber == client.socket

    {frames, log} =
      with_info_log(fn ->
        {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(first_input, turn_id, %{}))
        {conn, _websocket, frames} = receive_frames_until_close!(conn, websocket, client.ref)
        # The released client drops its connection without answering the Close.
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
        frames
      end)

    assert {turn_frames, [@upstream_close]} = split_turn_frames(frames)
    assert %{"type" => "response.completed", "response" => %{"id" => "resp_ws_upstream_close_opener"}} = List.last(turn_frames)
    assert log =~ ~r/(coalesced close drained reason_code=peer_close_frame halt=terminal close_code=#{close_code}|closed between requests reason_code=peer_close_frame closed_by=peer close_code=#{close_code}) /
    assert_upstream_close_lines!(log, [downstream_closed_line("peer_close_frame", client.lifecycle_id, 1)])
    assert_quiet_close!(log)
    assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms

    retry = connect!(port, setup, thread, path)
    {conn, websocket} = public_websocket_send_text!(retry.conn, retry.websocket, retry.ref, frame.(first_input ++ [@tool_call, @tool_output], turn_id, %{}))
    {conn, _websocket, resend_terminal} = receive_native_terminal!(conn, websocket, retry.ref)
    assert %{"type" => "response.completed", "response" => %{"id" => "resp_ws_upstream_close_resend"}} = resend_terminal
    assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
    Mint.HTTP.close(conn)

    assert [opener_request, resend_request] = FakeUpstream.requests(upstream)
    refute opener_request.websocket_connection_id == resend_request.websocket_connection_id
    assert client_input(resend_request.json, mode) == first_input ++ [@tool_call, @tool_output]
    # The resend stays on the session's assignment: the same upstream credential.
    assert Map.new(opener_request.headers)["authorization"] == Map.new(resend_request.headers)["authorization"]

    assert [opener, resend] = pool_requests(setup)
    assert {opener.status, resend.status} == {"succeeded", "succeeded"}
    assert [opener_attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^opener.id))
    assert [resend_attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^resend.id))
    assert opener_attempt.pool_upstream_assignment_id == resend_attempt.pool_upstream_assignment_id
    assert %{known: 7, provisional: 0, admissions: 1} = key_usage_events(resend.id)
    assert :ok = FakeUpstream.verify!(upstream)
  end

  defp upstream_close_setup(upstream, mode) do
    setup = gateway_setup(upstream)
    if mode, do: set_model_serving_mode!(model_serving_scope(), setup, mode)
    assert :ok = CodexPooler.Events.subscribe_pool(setup.pool)
    setup
  end

  # Opens a native socket keyed by `thread` as its turn state and returns the
  # client connection with the socket's connection process and its upstream
  # session's lifecycle id.
  # Traces the session's sends and the socket's receives of the two kinds of
  # message the session delivers to the socket. A sensitive process emits no
  # trace events, so the session lifts its sensitivity from inside itself.
  defp trace_socket_deliveries!(session, socket) do
    tracer = spawn_link(fn -> collect_socket_deliveries(session, socket, [], []) end)
    :sys.replace_state(session, fn state -> tap(state, fn _state -> Process.flag(:sensitive, false) end) end)
    1 = :erlang.trace(session, true, [:send, {:tracer, tracer}])
    1 = :erlang.trace(socket, true, [:receive, {:tracer, tracer}])
    tracer
  end

  # Every trace event emitted so far reaches the tracer before it answers.
  defp socket_deliveries!(tracer) do
    ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    after
      @detection_timeout_ms -> flunk("trace events were not delivered")
    end

    send(tracer, {:deliveries, self()})

    receive do
      {:socket_deliveries, sent, received} -> {sent, received}
    after
      @detection_timeout_ms -> flunk("the tracer did not answer")
    end
  end

  defp collect_socket_deliveries(session, socket, sent, received) do
    receive do
      {:trace, ^session, :send, message, ^socket} ->
        sent = if socket_delivery?(message), do: [message | sent], else: sent
        collect_socket_deliveries(session, socket, sent, received)

      {:trace, ^socket, :receive, message} ->
        received = if socket_delivery?(message), do: [message | received], else: received
        collect_socket_deliveries(session, socket, sent, received)

      {:deliveries, caller} ->
        send(caller, {:socket_deliveries, Enum.reverse(sent), Enum.reverse(received)})

      _other_trace_event ->
        collect_socket_deliveries(session, socket, sent, received)
    end
  end

  defp socket_delivery?({:codex_response_chunk, task_pid, data}) when is_pid(task_pid) and is_binary(data), do: true
  defp socket_delivery?({:upstream_websocket_connection_closed, session, signal}) when is_pid(session) and is_map(signal), do: true
  defp socket_delivery?(_message), do: false

  defp connect!(port, setup, thread, path) do
    before = WebsocketCleanupFence.listener_sockets()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread, path)
    socket = WebsocketCleanupFence.await_new_listener_socket!(before)
    session = socket_connection_state!(socket).upstream_websocket_session
    %{lifecycle_id: lifecycle_id} = :sys.get_state(session)
    %{conn: conn, websocket: websocket, ref: ref, socket: socket, lifecycle_id: lifecycle_id}
  end

  # Lite prefixes the request that opens a context with its tool manifest.
  defp client_input(%{"input" => [%{"type" => "additional_tools"} | input]}, "lite"), do: input
  defp client_input(%{"input" => input}, "full"), do: input

  defp closing_turn(response_id, close_code) do
    FakeUpstream.websocket_sse_then_close(completed_response_events(response_id, [@tool_call], 2, 1), code: close_code, reason: "synthetic upstream close")
  end

  defp pool_requests(setup),
    do: Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id, order_by: [asc: request.admitted_at]))

  # The Pool's requests once `count` of them exist and none is still open: a
  # request settles after its terminal reached the client.
  defp await_settled_pool_requests!(setup, count, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @detection_timeout_ms
    requests = pool_requests(setup)

    cond do
      length(requests) == count and Enum.all?(requests, &(&1.status not in ["accepted", "in_progress"])) ->
        requests

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          10 -> await_settled_pool_requests!(setup, count, deadline)
        end

      true ->
        flunk("the Pool's requests did not settle: #{inspect(Enum.map(requests, &{&1.status, &1.last_error_code}))}")
    end
  end

  defp api_key_owner_scope(setup) do
    setup.api_key.created_by_user_id
    |> then(&Repo.get!(User, &1))
    |> Scope.for_user(["instance_owner"])
  end
end
