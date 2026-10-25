defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.CommittedCloseSettlesTest do
  # A websocket failure with nothing received fails over to the next route
  # candidate only while the turn's payload never reached the provider
  # (`transport_failure.upstream_committed` not true), as HTTP fails over only
  # before submission (findings#325 row 325-6). An upstream close after the
  # payload was written, before any frame, settles the request instead: the
  # provider may already be running the turn on that account, so a failover
  # risked running it twice on two accounts. The client gets HTTP's answer to
  # the same post-submission failure, `502 upstream_request_failed`; its resend
  # steps over the zero-output predecessor (the verified lifecycle cut) and the
  # route failure the refused account recorded steers the resend to the other
  # account. A close that arrives behind the upstream `101`, before the payload
  # left, still fails over.
  #
  # One BEAM node, FakeUpstream (and a raw upgrade peer for the pre-commit
  # close), the direct path and an owner session, Full and Lite.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport,
    only: [owner_socket: 3, pool_attempts: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, CodexSession, RoutingCircuitState}
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  @moduletag capture_log: true

  # Failure-detection budget for an expected message or a server-side
  # teardown the test observes; a green run never spends it.
  @detection_timeout_ms 15_000

  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  for mode <- ["full", "lite"], forwarding <- [false, true] do
    @mode mode
    @forwarding forwarding
    @tag :websocket_connect_failover
    test "#{mode} forwarding=#{forwarding}: a committed close settles the turn on its account, and the client's resend is served by the other one" do
      put_owner_forwarding!(@forwarding)

      # Strict: the refusing account receives the turn once and closes (1011)
      # without a frame; it never sees the resend.
      refusing = start_upstream(FakeUpstream.strict_sequence([strict_native_request(1, FakeUpstream.websocket_close())]))

      # Strict: the other account serves the resend once, and only the resend.
      served = start_upstream(FakeUpstream.strict_sequence([strict_native_request(1, completed_response_frames("resp_committed_close_resend", [], 3, 1))]))

      {setup, second} = websocket_failover_candidates!(refusing, served, @mode)
      assert :ok = Events.subscribe_pool(setup.pool)
      {_server, port} = start_public_endpoint_with_server!()
      turn_state = Ecto.UUID.generate()
      payload = released_client_turn(setup, Ecto.UUID.generate(), "committed-close-#{@mode}-#{@forwarding}")

      {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      {conn, _websocket, _types, failure_frame} = receive_public_websocket_until_terminal(conn, websocket, ref, [])
      assert %{"type" => "error", "status" => 502, "error" => %{"code" => "upstream_request_failed"}} = failure_frame

      assert_receive {Events, %{reason: "request_finalized", payload: %{"request_id" => failed_request_id, "status" => "failed"}}}, @detection_timeout_ms

      # No failover: one attempt, on the account that received the payload.
      failed = Repo.get!(Request, failed_request_id)
      assert {failed.status, failed.last_error_code, failed.response_status_code} == {"failed", "upstream_stream_error", 502}
      assert failed.request_metadata["routing"]["model_serving_mode"] == @mode
      assert [attempt] = pool_attempts(setup.pool.id)
      assert {attempt.pool_upstream_assignment_id, attempt.status, attempt.network_error_code} == {setup.assignment.id, "failed", "upstream_stream_error"}
      assert %{"phase" => "upstream_close", "upstream_committed" => true} = Map.take(attempt.response_metadata["transport_failure"], ~w(phase upstream_committed))
      assert FakeUpstream.count(served) == 0

      # The settlement recorded the account's route failure; the ordering
      # demotion the setup gave the other account is removed, so only the
      # refused account's own demotion orders the resend.
      assert route_circuit_failures(setup.assignment.id) == [{"upstream_stream_error", 1}]
      {1, _} = Repo.delete_all(from(d in BridgeDemotion, where: d.pool_upstream_assignment_id == ^second.assignment.id))
      await_downstream_closed!(conn, failed, @forwarding)

      {retry_conn, retry_websocket, retry_ref} = public_websocket_connect!(port, setup, turn_state)
      {retry_conn, retry_websocket} = public_websocket_send_text!(retry_conn, retry_websocket, retry_ref, payload)
      {retry_conn, _retry_websocket, _types, terminal} = receive_public_websocket_until_terminal(retry_conn, retry_websocket, retry_ref, [])
      Mint.HTTP.close(retry_conn)
      assert %{"type" => "response.completed", "response" => %{"id" => "resp_committed_close_resend"}} = terminal

      assert [%Request{id: ^failed_request_id}, %Request{id: resend_id, correlation_id: correlation_id}] =
               Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: [asc: r.admitted_at]))

      # The resend is a new request linked to the failed predecessor: the
      # owner's client retry with forwarding on, the turn claim's failed
      # predecessor resend with it off.
      assert String.starts_with?(correlation_id, if(@forwarding, do: "client-retry-v1:", else: "codex-request-retry:"))
      assert Repo.one!(from(link in RequestClientRetryLink, where: link.predecessor_request_id == ^failed_request_id, select: link.successor_request_id)) == resend_id
      assert_receive {Events, %{reason: "request_finalized", payload: %{"request_id" => ^resend_id, "status" => "succeeded"}}}, @detection_timeout_ms
      assert [%{pool_upstream_assignment_id: resend_assignment_id, status: "succeeded"}] = Repo.all(from(a in Attempt, where: a.request_id == ^resend_id))
      assert resend_assignment_id == second.assignment.id
      assert :ok = FakeUpstream.verify!(refusing)
      assert :ok = FakeUpstream.verify!(served)
    end
  end

  # A half-open first candidate: the committed close settles there and the
  # probe resolves as a failed probe, reopening the circuit.
  for mode <- ["full", "lite"], path <- [:direct, :owner] do
    @mode mode
    @path path
    @tag :websocket_connect_failover
    test "#{mode} #{path}: a committed close on a half-open candidate settles there and reopens its circuit" do
      if @path == :owner, do: put_owner_forwarding!(true)

      # Strict: the payload reaches the refusing account, which closes (1011)
      # without a frame.
      refusing = start_upstream(FakeUpstream.strict_sequence([strict_native_request(1, FakeUpstream.websocket_close())]))
      served = start_upstream(FakeUpstream.strict_sequence([strict_native_request(1, completed_response_frames("resp_committed_close_never", [], 3, 1))]))
      {setup, _second} = websocket_failover_candidates!(refusing, served, @mode)
      circuit = half_open_websocket_circuit!(setup, setup.assignment)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      frame = run_turn!(@path, auth, setup, "half-open-#{@mode}-#{@path}")

      assert %{"type" => "error", "status" => 502, "error" => %{"code" => "upstream_request_failed"}} = frame
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert {request.status, request.last_error_code} == {"failed", "upstream_stream_error"}
      assert [%{status: "failed"}] = pool_attempts(setup.pool.id)
      assert FakeUpstream.count(served) == 0
      assert :ok = FakeUpstream.verify!(refusing)

      assert %RoutingCircuitState{status: "open", reason_code: "upstream_stream_error", failure_count: 2, metadata: %{"probe_in_flight_count" => 0}} =
               Repo.get!(RoutingCircuitState, circuit.id)
    end
  end

  # The control: the same close, read behind the upstream `101` before the
  # payload left (`upstream_committed` false), still fails over.
  for mode <- ["full", "lite"], path <- [:direct, :owner] do
    @mode mode
    @path path
    @tag :websocket_connect_failover
    test "#{mode} #{path}: a close behind the 101, before the payload left, still fails over" do
      if @path == :owner, do: put_owner_forwarding!(true)

      refusing = start_upgrade_close_upstream!()

      # Strict: the other account serves the turn once.
      served = start_upstream(FakeUpstream.strict_sequence([strict_native_request(1, completed_response_frames("resp_precommit_close_failover", [], 3, 1))]))
      {setup, second} = websocket_failover_candidates!(refusing, served, @mode)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      frame = run_turn!(@path, auth, setup, "precommit-#{@mode}-#{@path}")

      assert %{"type" => "response.completed", "response" => %{"id" => "resp_precommit_close_failover"}} = frame
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "succeeded"
      assert [first_attempt, second_attempt] = pool_attempts(setup.pool.id)
      assert {first_attempt.pool_upstream_assignment_id, first_attempt.status} == {setup.assignment.id, "retryable_failed"}

      assert %{"phase" => "upstream_close", "termination_source" => "peer_close_frame", "upstream_committed" => false} =
               Map.take(first_attempt.response_metadata["transport_failure"], ~w(phase termination_source upstream_committed))

      assert {second_attempt.pool_upstream_assignment_id, second_attempt.status} == {second.assignment.id, "succeeded"}
      assert_received {:upgrade_close_served, 1}
      assert :ok = FakeUpstream.verify!(served)
    end
  end

  for mode <- ["full", "lite"], forwarding <- [false, true], half_open <- [false, true] do
    @tag :websocket_connect_failover
    test "#{mode} forwarding=#{forwarding} half_open=#{half_open}: peer Close1009 settles once without penalizing the route" do
      assert_message_too_large_health!(unquote(mode), unquote(forwarding), unquote(half_open))
    end
  end

  for mode <- ["full", "lite"], path <- [:direct, :owner] do
    test "#{mode} #{path}: peer Close1012 remains a route failure" do
      assert_restart_close_health!(unquote(mode), unquote(path))
    end
  end

  defp assert_restart_close_health!(mode, path) do
    put_owner_forwarding!(path == :owner)
    upstream = start_upstream(FakeUpstream.strict_sequence([strict_native_request(1, FakeUpstream.websocket_close(code: 1012))]))
    other = start_upstream(completed_response_frames("resp_unexpected_other", [], 3, 1))
    {setup, _second} = websocket_failover_candidates!(upstream, other, mode)
    cleanup_pool_owners!(setup)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    assert %{"type" => "error", "status" => 502} = run_turn!(path, auth, setup, Ecto.UUID.generate())
    assert route_circuit_failures(setup.assignment.id) == [{"upstream_stream_error", 1}]
    assert FakeUpstream.count(other) == 0
    assert :ok = FakeUpstream.verify!(upstream)
  end

  defp assert_message_too_large_health!(mode, forwarding, half_open) do
    put_owner_forwarding!(forwarding)

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          strict_native_request(1, FakeUpstream.websocket_close(code: 1009)),
          strict_native_request(2, completed_response_frames("resp_after_size_close", [], 3, 1))
        ])
      )

    other = start_upstream(completed_response_frames("resp_unexpected_other", [], 3, 1))
    {setup, _second} = websocket_failover_candidates!(upstream, other, mode)
    cleanup_pool_owners!(setup)
    circuit = if half_open, do: half_open_websocket_circuit!(setup, setup.assignment)
    assert :ok = Events.subscribe_pool(setup.pool)
    {_server, port} = start_public_endpoint_with_server!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, Ecto.UUID.generate())
    payload = released_client_turn(setup, Ecto.UUID.generate(), Ecto.UUID.generate())
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
    {conn, _websocket, _types, terminal} = receive_public_websocket_until_terminal(conn, websocket, ref, [])
    assert %{"type" => "error", "status" => 502, "error" => %{"code" => "upstream_request_failed"}} = terminal
    assert_receive {Events, %{reason: "request_finalized", payload: %{"request_id" => request_id, "status" => "failed"}}}, @detection_timeout_ms
    request = Repo.get!(Request, request_id)
    assert {request.status, request.last_error_code, request.response_status_code, request.retry_count} == {"failed", "upstream_stream_error", 502, 0}
    assert request.request_metadata["routing"]["model_serving_mode"] == mode
    assert [attempt] = pool_attempts(setup.pool.id)
    assert {attempt.status, attempt.network_error_code, attempt.pool_upstream_assignment_id} == {"failed", "upstream_stream_error", setup.assignment.id}
    assert %{"phase" => "upstream_close", "termination_source" => "peer_close_frame", "peer_close_code" => 1009, "upstream_committed" => true} = attempt.response_metadata["transport_failure"]
    assert [settlement] = Repo.all(from(e in LedgerEntry, where: e.request_id == ^request_id and e.entry_kind == "settlement"))
    assert settlement.attempt_id == attempt.id
    assert {request.usage_status, attempt.usage_status, settlement.usage_status} == {"usage_unknown", "usage_unknown", "usage_unknown"}
    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.count(other) == 0

    if half_open do
      assert %RoutingCircuitState{status: "half_open", reason_code: "test_probe", failure_count: 1, metadata: %{"probe_in_flight_count" => 0}} = Repo.get!(RoutingCircuitState, circuit.id)
    else
      assert route_circuit_failures(setup.assignment.id) == []
    end

    refute Repo.exists?(from(d in BridgeDemotion, where: d.pool_upstream_assignment_id == ^setup.assignment.id))

    CodexPooler.TestDiagnostics.puts(fn ->
      CodexPooler.JSON.encode!(%{scenario: "native_peer_close1009", mode: mode, forwarding: forwarding, half_open: half_open, topology: "one_node", request_status: request.status, request_code: request.last_error_code, status_code: request.response_status_code, usage_status: settlement.usage_status, attempt_count: 1, settlement_count: 1, upstream_committed: attempt.response_metadata["transport_failure"]["upstream_committed"], primary_requests: FakeUpstream.count(upstream), other_requests: FakeUpstream.count(other), circuit_failures: Enum.map(route_circuit_failures(setup.assignment.id), fn {reason, count} -> %{reason: reason, count: count} end), probe_in_flight: if(circuit, do: Repo.get!(RoutingCircuitState, circuit.id).metadata["probe_in_flight_count"]), demotion_count: Repo.aggregate(from(d in BridgeDemotion, where: d.pool_upstream_assignment_id == ^setup.assignment.id), :count)})
    end)

    await_downstream_closed!(conn, request, forwarding)

    # A distinct ordinary turn can use the same account after the refusal,
    # including the probe slot just released by neutral completion.
    {conn, websocket, ref} = public_websocket_connect!(port, setup, Ecto.UUID.generate())
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, released_client_turn(setup, Ecto.UUID.generate(), Ecto.UUID.generate()))
    {conn, _websocket, _types, terminal} = receive_public_websocket_until_terminal(conn, websocket, ref, [])
    assert %{"type" => "response.completed"} = terminal
    assert_receive {Events, %{reason: "request_finalized", payload: %{"request_id" => next_request_id, "status" => "succeeded"}}}, @detection_timeout_ms
    await_downstream_closed!(conn, Repo.get!(Request, next_request_id), forwarding)
    assert :ok = FakeUpstream.verify!(upstream)
    assert FakeUpstream.count(other) == 0
  end

  defp cleanup_pool_owners!(setup) do
    on_exit(fn ->
      Repo.all(from(s in CodexSession, where: s.pool_id == ^setup.pool.id, select: s.id))
      |> Enum.each(&stop_websocket_owner_session/1)
    end)
  end

  defp put_owner_forwarding!(enabled?) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled?)
  end

  # The released client's opening turn: its frame names the thread and turn,
  # so the turn takes a durable claim and its resend takes the production path.
  defp released_client_turn(setup, thread_id, turn_id) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "client_metadata" => %{
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => turn_id, "request_kind" => "turn"})
      },
      "input" => native_text_input("committed close #{turn_id}"),
      "stream" => true
    })
  end

  # The client leaves the failed connection before it resends, as the released
  # client does; with forwarding on, the owner's downstream is gone first.
  defp await_downstream_closed!(conn, _failed, false), do: Mint.HTTP.close(conn)

  defp await_downstream_closed!(conn, failed, true) do
    session_id = failed.request_metadata["codex_session_id"]
    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(session_id)
    assert %{downstream: %{pid: downstream_pid}} = :sys.get_state(owner_pid)
    monitor = Process.monitor(downstream_pid)
    Mint.HTTP.close(conn)
    assert_receive {:DOWN, ^monitor, :process, ^downstream_pid, _reason}, @detection_timeout_ms
  end

  # The internal entry returns a settled failure to its caller, which the
  # socket renders as this error frame (the public-socket arm reads the wire).
  defp run_turn!(:direct, auth, setup, marker) do
    parent = self()

    case execute_websocket_response(auth, turn_payload(setup, marker), %{request_id: "ws-#{marker}"}, fn frame -> send(parent, {:websocket_frame, frame}) end) do
      {:error, %{status: status, code: code}} ->
        refute_received {:websocket_frame, _frame}
        %{"type" => "error", "status" => status, "error" => %{"code" => code}}

      :ok ->
        assert_received {:websocket_frame, frame}
        CodexPooler.JSON.decode!(frame)
    end
  end

  defp run_turn!(:owner, auth, setup, marker) do
    {:ok, state} = owner_socket(auth, "ws-owner-#{marker}", "owner-#{marker}")

    try do
      assert {:ok, state} = CodexResponsesSocket.handle_in({turn_payload(setup, marker), [opcode: :text]}, state)
      assert {_state, [_ | _] = frames} = collect_native_turn_frames!(state)
      List.last(frames)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  defp turn_payload(setup, marker) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("committed close #{marker}"),
      "stream" => true,
      "generate" => true
    })
  end

  # A provider double that answers the upgrade with its `101` and a Close
  # frame in one TCP send, so the session reads the Close behind the 101 and
  # fails the request before the payload is written (`upstream_committed`
  # false, findings#304). FakeUpstream cannot: Bandit writes the 101 and a
  # frame in separate sends. One connection is served, then the peer stops.
  defp start_upgrade_close_upstream! do
    owner = self()
    ref = make_ref()
    start_supervised!(Supervisor.child_spec({Task, fn -> upgrade_close_peer(owner, ref) end}, id: ref, restart: :temporary))
    assert_receive {^ref, :listening, port}, @detection_timeout_ms
    %FakeUpstream{url: "http://127.0.0.1:#{port}"}
  end

  defp upgrade_close_peer(owner, ref) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    send(owner, {ref, :listening, port})
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, key} = read_upgrade_key(socket, "")
    accept = Base.encode64(:crypto.hash(:sha, key <> @guid))
    head = ["HTTP/1.1 101 Switching Protocols\r\n", "upgrade: websocket\r\n", "connection: Upgrade\r\n", "sec-websocket-accept: ", accept, "\r\n\r\n"]
    # One `send`: the 101 and the Close share a TCP segment.
    :ok = :gen_tcp.send(socket, [head, <<0x88, 2, 1013::16>>])
    send(owner, {:upgrade_close_served, 1})
    _ = :gen_tcp.recv(socket, 0, @detection_timeout_ms)
    :gen_tcp.close(socket)
    :gen_tcp.close(listen)
  end

  defp read_upgrade_key(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      case Regex.run(~r/sec-websocket-key: ([^\r\n]+)/i, acc) do
        [_all, key] -> {:ok, key}
        nil -> {:error, :missing_websocket_key}
      end
    else
      with {:ok, data} <- :gen_tcp.recv(socket, 0, @detection_timeout_ms), do: read_upgrade_key(socket, acc <> data)
    end
  end
end
