defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.UpstreamCloseDownstreamTest do
  # A `previous_response_id` resolves only on the upstream websocket connection
  # that produced it, and the provider closes that connection between two
  # requests (its connection-age limit with 1000, a restart with 1012). The
  # native socket closes its idle client with 1001 then, so the client's next
  # request goes out whole on a new socket instead of meeting
  # `previous_response_not_found` first (findings#270; the forwarding-off half
  # is `backend_codex_websocket/upstream_close_downstream_test.exs`). With
  # owner forwarding on the websocket owner holds the upstream session: it
  # tells its attached downstream, only while it holds nothing of that socket,
  # after the `:complete` of a turn whose terminal it had relayed, and the
  # socket decides on its own state as with forwarding off.
  #
  # Topology: the real public listener, owner forwarding on, the session's
  # owner on this node with its real upstream session (on a second VM sharing
  # the committed database for the remote and earlier-release arms),
  # FakeUpstream, Pools forced to Full and to Lite, the released client's turn
  # frames (turn metadata naming thread and turn), synthetic text. The client
  # drops its connection without answering the Close, as the released client
  # does.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport,
    only: [enter_peer_owner_topology!: 0, owner_socket: 3, receive_native_collect_socket_push: 1, receive_owner_socket_push: 1, start_peer_window_owner!: 2, websocket_input_payload: 3, websocket_payload: 3]

  import CodexPooler.AccountingTestSupport, only: [key_usage_events: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  # Detection budget for a settlement, a relay or a teardown the test only
  # observes.
  @detection_timeout_ms 15_000

  @upstream_close {:close, 1001, "upstream connection closed"}
  @turn_path "/backend-api/codex/responses"
  @tool_call %{"type" => "function_call", "call_id" => "call_owner_upstream_close_sample", "name" => "sample_lookup", "arguments" => "{}"}
  @tool_output %{"type" => "function_call_output", "call_id" => "call_owner_upstream_close_sample", "output" => "sample output"}
  @window_thread "019a0000-0000-7000-8000-00000000f270"
  @window_id "#{@window_thread}:0"

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    :ok
  end

  # The provider's close right after a turn that asked for a tool: the owner
  # passes it on after the turn's `:complete`, the idle socket closes 1001
  # after the turn's terminal, and the client's whole resend on a new socket is
  # served on a new upstream connection of the same owner, on the session's
  # assignment, without an anchor. No request is refused.
  for mode <- ["full", "lite"], close_code <- [1000, 1012] do
    @tag serving_mode: mode, close_code: close_code
    test "a #{mode} socket closes 1001 after its owner's upstream connection closes with #{close_code} and the whole resend is served", ctx do
      first_input = native_text_input("owner upstream close #{ctx.serving_mode} #{ctx.close_code}")

      upstream =
        start_upstream(
          # The opener asks for a tool and the provider closes the owner's
          # connection right after the terminal; the whole resend is served on
          # the owner's next connection.
          # provenance: synthetic_adversarial (close codes and their order after the terminal as attributed in findings#270; frames synthetic)
          FakeUpstream.strict_sequence([
            anchorless_request(1, closing_turn("resp_owner_upstream_close_opener", ctx.close_code)),
            anchorless_request(2, completed_response_frames("resp_owner_upstream_close_resend", [], 4, 3))
          ])
        )

      setup = upstream_close_setup(upstream, ctx.serving_mode)
      second = gateway_upstream(setup.pool, upstream, "upstream-token-second", compact?: false)
      prime_routing_quota!(second.identity)
      setup = %{setup | model: put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])}
      {_server, port} = start_public_endpoint_with_server!()
      thread = "owner-upstream-close-#{ctx.serving_mode}-#{ctx.close_code}-#{System.unique_integer([:positive])}"
      client = connect!(port, setup, thread)
      frame = released_client_frame(setup, thread)
      turn_id = Ecto.UUID.generate()

      # The owner started its upstream session and is its close subscriber.
      assert :sys.get_state(client.session).connection_close_subscriber == client.owner

      {frames, log} =
        with_info_log(fn ->
          {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(first_input, turn_id, %{}))
          {conn, _websocket, frames} = receive_frames_until_close!(conn, websocket, client.ref)
          Mint.HTTP.close(conn)
          :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
          frames
        end)

      assert {turn_frames, [@upstream_close]} = split_turn_frames(frames)
      assert %{"type" => "response.completed", "response" => %{"id" => "resp_owner_upstream_close_opener"}} = List.last(turn_frames)
      assert log =~ ~r/(coalesced close drained reason_code=peer_close_frame halt=terminal close_code=#{ctx.close_code}|closed between requests reason_code=peer_close_frame closed_by=peer close_code=#{ctx.close_code}) /
      # One line: the socket's close. The owner passed the close on and has
      # nothing to say about it.
      assert_upstream_close_lines!(log, [downstream_closed_line("peer_close_frame", client.lifecycle_id, 1, "on")])
      assert_quiet_close!(log)
      assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms

      retry = connect!(port, setup, thread)
      assert retry.owner == client.owner
      {conn, websocket} = public_websocket_send_text!(retry.conn, retry.websocket, retry.ref, frame.(first_input ++ [@tool_call, @tool_output], turn_id, %{}))
      {conn, _websocket, resend_terminal} = receive_native_terminal!(conn, websocket, retry.ref)
      assert %{"type" => "response.completed", "response" => %{"id" => "resp_owner_upstream_close_resend"}} = resend_terminal
      assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
      Mint.HTTP.close(conn)

      assert [opener_request, resend_request] = FakeUpstream.requests(upstream)
      refute opener_request.websocket_connection_id == resend_request.websocket_connection_id
      assert client_input(resend_request.json, ctx.serving_mode) == first_input ++ [@tool_call, @tool_output]
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
  end

  # A provider idle close long after the turn: the owner holds nothing and
  # the socket is idle, so the socket closes at once.
  test "an upstream connection the provider closes while everything is idle closes the socket at once" do
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (the provider's idle close, 1012)
        FakeUpstream.strict_sequence([anchorless_request(1, completed_response_frames("resp_owner_idle_upstream_close", [@tool_call], 2, 1))])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "owner-idle-upstream-close-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread)
    {conn, websocket} = completed_turn!(client, setup, thread, "idle upstream close")
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
    assert_upstream_close_lines!(log, [downstream_closed_line("peer_close_frame", client.lifecycle_id, 1, "on")])
    assert_quiet_close!(log)
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # The owner hears the close while its turn's task has not returned yet: the
  # terminal already reached the socket, the owner keeps the close on that
  # turn and passes it on only after the turn's `:complete`. The owner's
  # upstream task is suspended once the provider has the request, so its
  # result reaches the owner only after the close whatever the reads coalesce
  # into; the owner's real upstream session reports the close.
  test "a close the owner hears before its turn's result goes to the socket after the turn's :complete" do
    release_ref = make_ref()
    terminal = completed_terminal_frame("resp_owner_deferred_upstream_close")

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (close 1000 after the terminal, each held until released)
        FakeUpstream.strict_sequence([anchorless_request(1, FakeUpstream.websocket_terminal_then_close_barrier(terminal, code: 1000, reason: "synthetic age limit", notify: self(), release_ref: release_ref))])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "owner-deferred-upstream-close-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread)
    frame = released_client_frame(setup, thread)

    {frames, log} =
      with_info_log(fn ->
        {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(native_text_input("owner deferred close"), Ecto.UUID.generate(), %{}))
        assert_receive {:fake_upstream_websocket_barrier, :before_terminal, handler, ^release_ref}, @detection_timeout_ms
        %{active_turn: %{task_pid: owner_task}} = :sys.get_state(client.owner)
        true = :erlang.suspend_process(owner_task)

        {conn, websocket} =
          try do
            send(handler, {:fake_upstream_release_websocket, release_ref})
            {conn, websocket, relayed} = receive_native_terminal!(conn, websocket, client.ref)
            assert %{"type" => "response.completed", "response" => %{"id" => "resp_owner_deferred_upstream_close"}} = relayed
            assert_receive {:fake_upstream_websocket_barrier, :before_close, ^handler, ^release_ref}, @detection_timeout_ms
            send(handler, {:fake_upstream_release_websocket, release_ref})
            :ok = await_session_disconnected!(client.session)

            deferred = await_owner_state!(client.owner, &match?(%{active_turn: %{upstream_close: _deferred}}, &1))
            assert deferred.active_turn.upstream_close.signal == %{cause: :peer_close_frame, lifecycle_id: client.lifecycle_id, generation: 1}
            assert deferred.active_turn.terminal_forwarded?
            # The socket has not been told: it still answers.
            socket_transport_barrier!(conn, websocket, client.ref)
          after
            # Only the process that suspended the task can resume it.
            true = :erlang.resume_process(owner_task)
          end

        {conn, _websocket, frames} = receive_frames_until_close!(conn, websocket, client.ref)
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
        frames
      end)

    assert frames == [@upstream_close]
    assert log =~ "upstream websocket connection closed between requests reason_code=peer_close_frame closed_by=peer close_code=1000 "
    assert_upstream_close_lines!(log, [downstream_closed_line("peer_close_frame", client.lifecycle_id, 1, "on")])
    assert_quiet_close!(log)
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # The owner passes the close on after the turn's `:complete`, while the
  # socket's response task still settles the turn: the socket latches it and
  # stays open until the task is delivered, then closes after the terminal.
  test "a close that reaches the socket while its turn still settles waits for the turn and then closes" do
    hold = hold_settled_websocket_turn!()

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (close 1000 right after the terminal)
        FakeUpstream.strict_sequence([anchorless_request(1, closing_turn("resp_owner_socket_deferred_close", 1000))])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "owner-socket-deferred-close-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread)
    frame = released_client_frame(setup, thread)

    {frames, log} =
      with_info_log(fn ->
        {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(native_text_input("socket deferred close"), Ecto.UUID.generate(), %{}))
        {conn, websocket, terminal} = receive_native_terminal!(conn, websocket, client.ref)
        assert %{"type" => "response.completed"} = terminal
        assert_receive {^hold, :held, task}, @detection_timeout_ms

        latched = await_socket_connection_state!(client.socket, &Map.has_key?(&1, :upstream_close_pending))
        assert latched.upstream_close_pending == %{cause: :peer_close_frame, lifecycle_id: client.lifecycle_id, generation: 1, forwarding: :on}
        assert MapSet.member?(latched.tasks, task)
        # The owner holds nothing of the socket any more.
        assert %{active_turn: nil} = :sys.get_state(client.owner)
        {conn, websocket} = socket_transport_barrier!(conn, websocket, client.ref)

        :ok = release_settled_websocket_turn(hold, task)
        {conn, _websocket, frames} = receive_frames_until_close!(conn, websocket, client.ref)
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
        frames
      end)

    assert frames == [@upstream_close]
    assert_upstream_close_lines!(log, [downstream_closed_line("peer_close_frame", client.lifecycle_id, 1, "on")])
    assert_quiet_close!(log)
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # The client's next request reaches the socket after it latched the close
  # but before it closed. A request anchored on the closed connection's
  # response can only meet the continuation guard's refusal, so the close
  # stays pending, the request waits behind the settling turn, and the close
  # takes its place (findings#270 row 270-302): no owner submission and no
  # row. The whole resend on a new socket is served on the owner's next
  # connection. The socket used to drop the close for any client frame, and
  # the guard answered `previous_response_not_found` on the owner's fresh
  # connection.
  test "a client frame anchored on the closed connection's response is answered by the close" do
    hold = hold_settled_websocket_turn!()
    first_input = native_text_input("owner frame before decision")

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (close 1000 right after the terminal)
        FakeUpstream.strict_sequence([
          anchorless_request(1, closing_turn("resp_owner_frame_before_decision", 1000)),
          anchorless_request(2, completed_response_frames("resp_owner_frame_before_decision_resend", [], 4, 3))
        ])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "owner-frame-before-decision-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread)
    frame = released_client_frame(setup, thread)
    turn_id = Ecto.UUID.generate()

    {frames, log} =
      with_info_log(fn ->
        {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(first_input, turn_id, %{}))
        {conn, websocket, terminal} = receive_native_terminal!(conn, websocket, client.ref)
        assert %{"type" => "response.completed"} = terminal
        assert_receive {^hold, :held, task}, @detection_timeout_ms
        _latched = await_socket_connection_state!(client.socket, &Map.has_key?(&1, :upstream_close_pending))

        {conn, websocket} = public_websocket_send_text!(conn, websocket, client.ref, frame.([@tool_output], turn_id, %{"previous_response_id" => "resp_owner_frame_before_decision"}))
        {conn, websocket} = socket_transport_barrier!(conn, websocket, client.ref)
        assert Map.has_key?(socket_connection_state!(client.socket), :upstream_close_pending)

        :ok = release_settled_websocket_turn(hold, task)
        {conn, _websocket, frames} = receive_frames_until_close!(conn, websocket, client.ref)
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
        frames
      end)

    assert frames == [@upstream_close]
    assert_upstream_close_lines!(log, [downstream_closed_line("peer_close_frame", client.lifecycle_id, 1, "on")])
    assert log =~ "queued_request=closed_anchor"
    assert [_opener] = FakeUpstream.requests(upstream)

    retry = connect!(port, setup, thread)
    {conn, websocket} = public_websocket_send_text!(retry.conn, retry.websocket, retry.ref, frame.(first_input ++ [@tool_call, @tool_output], turn_id, %{}))
    {conn, _websocket, resend_terminal} = receive_native_terminal!(conn, websocket, retry.ref)
    assert %{"type" => "response.completed", "response" => %{"id" => "resp_owner_frame_before_decision_resend"}} = resend_terminal
    assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
    Mint.HTTP.close(conn)

    assert [opener, resend] = await_settled_pool_requests!(setup, 2)
    assert {opener.status, resend.status} == {"succeeded", "succeeded"}
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # The client's frame crosses the Close on the wire: the socket is held
  # while the owner's word and then the frame queue up behind it, so the word
  # is handled first, the socket closes, and the frame reaches only a stopped
  # socket. It starts nothing: no owner submission, no upstream request, no
  # row. The owner's word always follows an upstream close that already
  # happened. The client's retry is then served.
  test "a client frame that crosses the Close starts nothing and the retry is served" do
    first_input = native_text_input("owner frame crossing the close")

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          anchorless_request(1, completed_response_frames("resp_owner_frame_crossing_close", [@tool_call], 2, 1)),
          anchorless_request(2, completed_response_frames("resp_owner_frame_crossing_close_resend", [], 4, 3))
        ])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "owner-frame-crossing-close-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread)
    frame = released_client_frame(setup, thread)
    turn_id = Ecto.UUID.generate()
    {conn, websocket} = completed_turn!(client, setup, thread, first_input, turn_id)
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
            # The session signals the owner right after it drops the
            # connection; the owner then tells the held socket.
            :ok = await_session_disconnected!(client.session)
            _owner_state = :sys.get_state(client.owner)
            :ok = await_queued_message!(client.socket)

            {conn, websocket} = public_websocket_send_text!(conn, websocket, client.ref, frame.([@tool_output], turn_id, %{"previous_response_id" => "resp_owner_frame_crossing_close"}))
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
    assert_upstream_close_lines!(log, [downstream_closed_line("peer_close_frame", client.lifecycle_id, 1, "on")])
    assert [_opener] = FakeUpstream.requests(upstream)
    assert [_opener_row] = pool_requests(setup)

    retry = connect!(port, setup, thread)
    {conn, websocket} = public_websocket_send_text!(retry.conn, retry.websocket, retry.ref, frame.(first_input ++ [@tool_call, @tool_output], turn_id, %{}))
    {conn, _websocket, resend_terminal} = receive_native_terminal!(conn, websocket, retry.ref)
    assert %{"type" => "response.completed", "response" => %{"id" => "resp_owner_frame_crossing_close_resend"}} = resend_terminal
    assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
    Mint.HTTP.close(conn)

    assert [_opener, resend_request] = FakeUpstream.requests(upstream)
    assert resend_request.json["input"] == first_input ++ [@tool_call, @tool_output]
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # Two sockets of one session: the second attaches in place of the first,
  # which the owner no longer serves. Only the socket attached when the close
  # comes is told; the replaced one stays open and hears nothing.
  test "only the socket attached to the owner closes" do
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          anchorless_request(1, completed_response_frames("resp_owner_replaced_socket", [@tool_call], 2, 1)),
          anchorless_request(1, closing_turn("resp_owner_attached_socket", 1000))
        ])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "owner-two-sockets-#{System.unique_integer([:positive])}"
    replaced = connect!(port, setup, thread)
    {replaced_conn, replaced_websocket} = completed_turn!(replaced, setup, thread, "replaced socket")
    attached = connect!(port, setup, thread)
    assert attached.owner == replaced.owner
    assert %{downstream: %{pid: attached_socket, epoch: 2}} = :sys.get_state(attached.owner)
    assert attached_socket == attached.socket
    frame = released_client_frame(setup, thread)

    {frames, log} =
      with_info_log(fn ->
        {conn, websocket} = public_websocket_send_text!(attached.conn, attached.websocket, attached.ref, frame.(native_text_input("attached socket"), Ecto.UUID.generate(), %{}))
        {conn, _websocket, frames} = receive_frames_until_close!(conn, websocket, attached.ref)
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(attached.socket)
        frames
      end)

    assert {[%{"type" => "response.completed"}], [@upstream_close]} = split_turn_frames(frames)
    assert_upstream_close_lines!(log, [downstream_closed_line("peer_close_frame", attached.lifecycle_id, 1, "on")])

    # The replaced socket answers and has received nothing.
    {replaced_conn, _websocket} = socket_transport_barrier!(replaced_conn, replaced_websocket, replaced.ref)
    Mint.HTTP.close(replaced_conn)
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # A draining owner (rollout) keeps its downstream open: the socket's next
  # request meets the drain's own answer, and nothing is closed for a close
  # the owner will not serve again anyway.
  test "a draining owner keeps its downstream open and says why" do
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([anchorless_request(1, completed_response_frames("resp_owner_draining_close", [@tool_call], 2, 1))])
      )

    setup = upstream_close_setup(upstream, nil)
    {_server, port} = start_public_endpoint_with_server!()
    thread = "owner-draining-close-#{System.unique_integer([:positive])}"
    client = connect!(port, setup, thread)
    {conn, websocket} = completed_turn!(client, setup, thread, "draining close")
    :ok = WebsocketOwnerSession.begin_drain(client.owner)
    close_ref = make_ref()

    log =
      with_info_log(fn ->
        assert :ok = FakeUpstream.close_websocket_connection(upstream, 1, close_ref: close_ref, notify: self(), code: 1000, reason: "synthetic age limit")
        assert_receive {:fake_upstream_websocket_peer_closed, 1, ^close_ref}, @detection_timeout_ms
        :ok = await_session_disconnected!(client.session)
        assert %{draining?: true} = :sys.get_state(client.owner)
        {conn, _websocket} = socket_transport_barrier!(conn, websocket, client.ref)
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
      end)
      |> elem(1)

    assert_upstream_close_lines!(log, [kept_open_line("peer_close_frame", "draining", client.lifecycle_id, 1, "on")])
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # A native compaction the owner collected on its connection leaves it
  # waiting for that compaction's final request (`pending_final`), bound to
  # that connection: once the provider closed it, the final could no longer be
  # admitted on the socket (it failed `native_compaction_capability_rejected`
  # on the fresh connection and the client met a 502). So the owner counts it
  # idle and drops that admission with the connection: the socket closes, and
  # the final the client sends on its next socket runs as an ordinary turn on
  # the owner's next connection. Driven through the socket callbacks (this
  # process is the socket), as the compaction tests are.
  test "a close while the owner waits for a native compaction's final request closes the socket and the final is served on the next one" do
    compact_item = %{"type" => "compaction", "encrypted_content" => "synthetic-owner-upstream-close-pending-final"}
    frames = fn events -> Enum.map(events, &CodexPooler.JSON.encode!/1) end

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (compaction v2-shaped frames as in compaction_test.exs; the provider's idle close after the compaction)
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.create", "input.0.type" => "message"}, forbidden: ["previous_response_id"]],
            respond: FakeUpstream.websocket_text_frames(frames.([%{"type" => "response.completed", "response" => %{"id" => "resp_owner_pending_final_anchor", "status" => "completed", "output" => []}}]))
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.create", "previous_response_id" => "resp_owner_pending_final_anchor", "input.0.type" => "custom_tool_call_output"}],
            respond:
              FakeUpstream.websocket_text_frames(
                frames.([
                  %{"type" => "response.output_item.done", "item" => compact_item},
                  %{"type" => "response.completed", "response" => %{"id" => "resp_owner_pending_final_compact", "status" => "completed", "output" => [compact_item]}}
                ])
              )
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 2,
            json: [valid: true, equals: %{"type" => "response.create", "input.0.type" => "compaction"}, forbidden: ["previous_response_id"]],
            respond: FakeUpstream.websocket_text_frames(frames.([%{"type" => "response.completed", "response" => %{"id" => "resp_owner_pending_final_final", "status" => "completed", "output" => []}}]))
          )
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "full")
    assert :ok = CodexPooler.Events.subscribe_pool(setup.pool)
    {:ok, auth} = CodexPooler.Access.authenticate_authorization_header(setup.authorization)
    turn_state = "owner-upstream-close-pending-final"
    {:ok, state} = owner_socket(auth, "ws-owner-upstream-close-pending-final", turn_state)
    Process.put(:pending_final_socket_state, state)
    turn_id = "owner-upstream-close-pending-final-turn"
    metadata = pending_final_turn_metadata(turn_id)

    try do
      anchor = websocket_payload(setup, "synthetic pending final anchor", %{"client_metadata" => %{"turn_id" => turn_id, "x-codex-turn-metadata" => metadata.("turn", 1)}})
      assert {:ok, state} = CodexResponsesSocket.handle_in({anchor, [opcode: :text]}, state)
      assert {:push, {:text, anchor_terminal}, state} = receive_owner_socket_push(state)
      assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(anchor_terminal)
      assert {:ok, state} = receive_socket_turn_done(state)

      compact =
        websocket_input_payload(setup, [%{"type" => "custom_tool_call_output", "call_id" => "call_owner_pending_final", "output" => "synthetic tool output"}, %{"type" => "compaction_trigger"}], %{
          "previous_response_id" => "resp_owner_pending_final_anchor",
          "client_metadata" => %{"turn_id" => turn_id, "x-codex-turn-metadata" => metadata.("compaction", 1)}
        })

      assert {:ok, state} = CodexResponsesSocket.handle_in({compact, [opcode: :text]}, state)
      assert {:push, {:text, _done}, state} = receive_native_collect_socket_push(state)
      assert {:push, {:text, compact_terminal}, state} = receive_native_collect_socket_push(state)
      assert %{"type" => "response.completed", "response" => %{"output" => [^compact_item]}} = CodexPooler.JSON.decode!(compact_terminal)
      assert {:ok, state} = receive_socket_turn_done(state)
      Process.put(:pending_final_socket_state, state)
      assert MapSet.size(state.tasks) == 0

      assert {:ok, owner} = WebsocketOwnerSession.lookup(state.codex_session.id)
      owner_state = :sys.get_state(owner)
      assert NativeCompactionAdmission.phase(owner_state.native_compaction_admission) == :pending_final
      session = owner_state.upstream_pid
      %{lifecycle_id: lifecycle_id} = :sys.get_state(session)
      %{correlation_id: correlation_id, epoch: epoch} = state.websocket_owner_downstream
      close_ref = make_ref()

      {stopped, log} =
        with_info_log(fn ->
          assert :ok = FakeUpstream.close_websocket_connection(upstream, 1, close_ref: close_ref, notify: self(), code: 1000, reason: "synthetic age limit")
          assert_receive {:fake_upstream_websocket_peer_closed, 1, ^close_ref}, @detection_timeout_ms
          assert_receive {:websocket_owner_upstream_closed, ^correlation_id, ^epoch, signal} = word, @detection_timeout_ms
          assert signal == %{cause: :peer_close_frame, lifecycle_id: lifecycle_id, generation: 1}
          assert {:stop, :normal, {1001, "upstream connection closed"}, stopped} = CodexResponsesSocket.handle_info(word, state)
          Process.put(:pending_final_socket_state, stopped)
          stopped
        end)

      assert_upstream_close_lines!(log, [downstream_closed_line("peer_close_frame", lifecycle_id, 1, "on")])

      # The owner dropped the admission bound to the closed connection on its
      # session's signal, before the socket's close detaches it (findings#274).
      assert %{native_compaction_admission: nil} = :sys.get_state(owner)
      :ok = CodexResponsesSocket.terminate(:normal, stopped)
      Process.delete(:pending_final_socket_state)

      {:ok, state} = owner_socket(auth, "ws-owner-upstream-close-pending-final-next", turn_state)
      Process.put(:pending_final_socket_state, state)

      final =
        websocket_input_payload(setup, [compact_item, %{"type" => "message", "role" => "user", "content" => "synthetic final"}], %{
          "client_metadata" => %{"turn_id" => turn_id, "x-codex-turn-metadata" => metadata.("turn", 2)}
        })

      assert {:ok, state} = CodexResponsesSocket.handle_in({final, [opcode: :text]}, state)
      assert {:push, {:text, final_terminal}, state} = receive_owner_socket_push(state)
      assert %{"type" => "response.completed", "response" => %{"id" => "resp_owner_pending_final_final"}} = CodexPooler.JSON.decode!(final_terminal)
      assert {:ok, state} = receive_socket_turn_done(state)
      Process.put(:pending_final_socket_state, state)
      assert :ok = FakeUpstream.verify!(upstream)
      assert Enum.map(pool_requests(setup), &{&1.endpoint, &1.status}) == [{"/backend-api/codex/responses", "succeeded"}, {"/backend-api/codex/responses/compact", "succeeded"}, {"/backend-api/codex/responses", "succeeded"}]
    after
      case Process.delete(:pending_final_socket_state) do
        nil -> :ok
        socket_state -> CodexResponsesSocket.terminate(:closed, socket_state)
      end
    end
  end

  # The session's owner lives on another VM: its word reaches the socket
  # across nodes, and the socket closes 1001 as with a local owner. The
  # whole resend is served by that owner on its next connection.
  @tag slow: "boots a second VM that owns the session and shares the committed database"
  test "an owner on another node tells the socket, which closes 1001, and the resend is served" do
    enter_peer_owner_topology!()

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          anchorless_request(1, closing_turn("resp_remote_owner_upstream_close", 1000)),
          anchorless_request(2, completed_response_frames("resp_remote_owner_upstream_close_resend", [], 4, 3))
        ])
      )

    setup = upstream_close_setup(upstream, nil)
    peer_owner = start_peer_window_owner!(setup, @window_id)
    {_server, port} = start_public_endpoint_with_server!()
    client = connect_window!(port, setup, peer_owner.owner_pid)
    assert node(client.owner) == peer_owner.node
    assert :sys.get_state(client.session).connection_close_subscriber == client.owner
    frame = released_client_frame(setup, @window_thread)
    first_input = native_text_input("remote owner upstream close")
    turn_id = Ecto.UUID.generate()

    {frames, log} =
      with_info_log(fn ->
        {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(first_input, turn_id, %{}))
        {conn, _websocket, frames} = receive_frames_until_close!(conn, websocket, client.ref)
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
        frames
      end)

    assert {[%{"type" => "response.completed"}], [@upstream_close]} = split_turn_frames(frames)
    assert_upstream_close_lines!(log, [downstream_closed_line("peer_close_frame", client.lifecycle_id, 1, "on")])
    assert_quiet_close!(log)
    assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms

    retry = connect_window!(port, setup, peer_owner.owner_pid)
    {conn, websocket} = public_websocket_send_text!(retry.conn, retry.websocket, retry.ref, frame.(first_input ++ [@tool_call, @tool_output], turn_id, %{}))
    {conn, _websocket, resend_terminal} = receive_native_terminal!(conn, websocket, retry.ref)
    assert %{"type" => "response.completed", "response" => %{"id" => "resp_remote_owner_upstream_close_resend"}} = resend_terminal
    assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
    Mint.HTTP.close(conn)

    assert [_opener, _resend] = FakeUpstream.requests(upstream)
    assert :ok = FakeUpstream.verify!(upstream)
  end

  # During a rolling upgrade the session's owner can run on a node of the
  # earlier release, which never tells its downstream. The socket then stays
  # open and the client's anchored request meets the guard exactly as before
  # this change (`previous_response_not_found` with nothing sent, no usage);
  # nothing fails on either node, and the whole resend is served.
  @tag slow: "boots a second VM that owns the session and shares the committed database"
  test "an owner node of an earlier release keeps the socket open and the guard answers as before" do
    enter_peer_owner_topology!()
    first_input = native_text_input("earlier release owner upstream close")

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (close 1000 right after the terminal; the
        # guard's fresh connection carries nothing and serves the resend)
        FakeUpstream.strict_sequence([
          anchorless_request(1, closing_turn("resp_earlier_owner_upstream_close", 1000)),
          anchorless_request(2, completed_response_frames("resp_earlier_owner_upstream_close_resend", [], 4, 3))
        ])
      )

    setup = upstream_close_setup(upstream, nil)
    peer_owner = start_peer_window_owner!(setup, @window_id)
    :ok = load_owner_without_upstream_close_word!(peer_owner.node)
    {_server, port} = start_public_endpoint_with_server!()
    client = connect_window!(port, setup, peer_owner.owner_pid)
    frame = released_client_frame(setup, @window_thread)
    turn_id = Ecto.UUID.generate()

    {refusal, log} =
      with_info_log(fn ->
        {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(first_input, turn_id, %{}))
        {conn, websocket, terminal} = receive_native_terminal!(conn, websocket, client.ref)
        assert %{"type" => "response.completed"} = terminal
        assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
        :ok = await_session_disconnected!(client.session)
        # The owner has handled the signal (same sender as this read) and
        # told nobody: the socket answers.
        assert %{active_turn: nil} = :sys.get_state(client.owner)
        {conn, websocket} = socket_transport_barrier!(conn, websocket, client.ref)

        {conn, websocket} = public_websocket_send_text!(conn, websocket, client.ref, frame.([@tool_output], turn_id, %{"previous_response_id" => "resp_earlier_owner_upstream_close"}))
        {conn, websocket, refusal} = receive_native_terminal!(conn, websocket, client.ref)
        assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "failed"}}}, @detection_timeout_ms
        {conn, _websocket} = socket_transport_barrier!(conn, websocket, client.ref)
        Mint.HTTP.close(conn)
        :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
        refusal
      end)

    assert refusal == native_previous_response_retry_event()
    assert_upstream_close_lines!(log, [])
    refute WebsocketCleanupFence.without_deferred_cleanup(log) =~ "[error]"
    assert :erpc.call(peer_owner.node, Process, :alive?, [peer_owner.owner_pid])

    retry = connect_window!(port, setup, peer_owner.owner_pid)
    {conn, websocket} = public_websocket_send_text!(retry.conn, retry.websocket, retry.ref, frame.(first_input ++ [@tool_call, @tool_output], turn_id, %{}))
    {conn, _websocket, resend_terminal} = receive_native_terminal!(conn, websocket, retry.ref)
    assert %{"type" => "response.completed", "response" => %{"id" => "resp_earlier_owner_upstream_close_resend"}} = resend_terminal
    assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
    Mint.HTTP.close(conn)

    assert [opener, refused, _resend] = pool_requests(setup)
    assert {opener.status, refused.status, refused.last_error_code} == {"succeeded", "failed", "stream_incomplete"}
    assert key_usage_events(refused.id) == %{known: 0, provisional: 0, admissions: 1}
    assert :ok = FakeUpstream.verify!(upstream)
  end

  defp upstream_close_setup(upstream, mode) do
    setup = gateway_setup(upstream)
    if mode, do: set_model_serving_mode!(model_serving_scope(), setup, mode)
    assert :ok = CodexPooler.Events.subscribe_pool(setup.pool)
    setup
  end

  # Opens a native socket keyed by `thread` (its turn state) and returns the
  # client connection with the socket's connection process, the session's
  # owner on this node, the owner's upstream session and its lifecycle id.
  defp connect!(port, setup, thread) do
    before = WebsocketCleanupFence.listener_sockets()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, thread, @turn_path)
    socket = WebsocketCleanupFence.await_new_listener_socket!(before)
    assert {:ok, owner} = WebsocketOwnerSession.lookup(socket_connection_state!(socket).codex_session.id)
    client(conn, websocket, ref, socket, owner)
  end

  # The same for the session a peer VM owns, keyed by the window header.
  defp connect_window!(port, setup, owner) do
    before = WebsocketCleanupFence.listener_sockets()
    {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, Ecto.UUID.generate(), @turn_path, [{"x-codex-window-id", @window_id}])
    socket = WebsocketCleanupFence.await_new_listener_socket!(before)
    client(conn, websocket, ref, socket, owner)
  end

  defp client(conn, websocket, ref, socket, owner) do
    session = :sys.get_state(owner).upstream_pid
    %{lifecycle_id: lifecycle_id} = :sys.get_state(session)
    %{conn: conn, websocket: websocket, ref: ref, socket: socket, owner: owner, session: session, lifecycle_id: lifecycle_id}
  end

  # One completed turn on `client`, settled and delivered: the socket is idle
  # and holds that turn's response as its last completed one.
  defp completed_turn!(client, setup, thread, input_or_text, turn_id \\ Ecto.UUID.generate())

  defp completed_turn!(client, setup, thread, text, turn_id) when is_binary(text),
    do: completed_turn!(client, setup, thread, native_text_input(text), turn_id)

  defp completed_turn!(client, setup, thread, input, turn_id) do
    frame = released_client_frame(setup, thread)
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame.(input, turn_id, %{}))
    {conn, websocket, terminal} = receive_native_terminal!(conn, websocket, client.ref)
    assert %{"type" => "response.completed"} = terminal
    assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
    _idle = await_socket_connection_state!(client.socket, &(MapSet.size(&1.tasks) == 0 and is_map(Map.get(&1, :last_completed_native_response))))
    {conn, websocket}
  end

  # Lite prefixes the request that opens a context with its tool manifest.
  defp client_input(%{"input" => [%{"type" => "additional_tools"} | input]}, "lite"), do: input
  defp client_input(%{"input" => input}, "full"), do: input

  defp closing_turn(response_id, close_code) do
    FakeUpstream.websocket_sse_then_close(completed_response_events(response_id, [@tool_call], 2, 1), code: close_code, reason: "synthetic upstream close")
  end

  defp completed_terminal_frame(response_id) do
    [terminal] = response_id |> completed_response_events([@tool_call], 2, 1) |> Enum.take(-1)
    CodexPooler.JSON.encode!(terminal)
  end

  # The turn metadata of the compaction test: the anchor and its mid-turn
  # compaction on the first window, the final request on the next one.
  defp pending_final_turn_metadata(turn_id) do
    fn request_kind, window_number ->
      %{
        "turn_id" => turn_id,
        "window_id" => "owner-upstream-close-pending-final-window-#{window_number}",
        "context_window_id" => "00000000-0000-4000-8000-00000000027#{window_number}",
        "window_number" => window_number,
        "request_kind" => request_kind
      }
      |> then(&if(request_kind == "compaction", do: Map.put(&1, "compaction", %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses_compaction_v2", "phase" => "mid_turn", "strategy" => "memento"}), else: &1))
      |> CodexPooler.JSON.encode!()
    end
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

  # Polls the owner's state until `predicate` holds: no message marks the
  # owner's handling of its upstream session's signal.
  defp await_owner_state!(owner, predicate, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @detection_timeout_ms
    state = :sys.get_state(owner)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          5 -> await_owner_state!(owner, predicate, deadline)
        end

      true ->
        flunk("the websocket owner did not reach the expected state")
    end
  end

  # The owner's word for a held socket is in its mailbox: nothing else is
  # sent to an idle socket.
  defp await_queued_message!(socket, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @detection_timeout_ms

    case Process.info(socket, :message_queue_len) do
      {:message_queue_len, queued} when queued > 0 ->
        :ok

      _empty_or_gone ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            5 -> await_queued_message!(socket, deadline)
          end
        else
          flunk("the owner's word never reached the held socket")
        end
    end
  end

  # An owner node of the earlier release: this release's owner compiled
  # without its handling of the upstream session's close signal, so the signal
  # falls into the catch-all and nobody is told, as on a node whose owner never
  # subscribed.
  defp load_owner_without_upstream_close_word!(node) do
    {:ok, {WebsocketOwnerSession, [abstract_code: {:raw_abstract_v1, forms}]}} =
      WebsocketOwnerSession |> :code.which() |> :beam_lib.chunks([:abstract_code])

    {forms, dropped} =
      Enum.map_reduce(forms, 0, fn
        {:function, line, :handle_info, 2, clauses}, dropped ->
          kept = Enum.reject(clauses, &upstream_close_signal_clause?/1)
          {{:function, line, :handle_info, 2, kept}, dropped + length(clauses) - length(kept)}

        form, dropped ->
          {form, dropped}
      end)

    assert dropped == 1
    {:ok, WebsocketOwnerSession, binary} = :compile.forms(forms, [:binary, :return_errors])
    assert {:module, WebsocketOwnerSession} = :erpc.call(node, :code, :load_binary, [WebsocketOwnerSession, ~c"previous_release_owner", binary])
    :ok
  end

  defp upstream_close_signal_clause?({:clause, _line, [{:tuple, _tuple_line, [{:atom, _atom_line, :upstream_websocket_connection_closed} | _rest]}, _state], _guards, _body}), do: true
  defp upstream_close_signal_clause?(_clause), do: false
end
