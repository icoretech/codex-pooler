defmodule CodexPoolerWeb.Runtime.OwnerLossScenario do
  @moduledoc false

  # An owner-forwarded socket whose websocket owner goes away between two
  # requests (findings#276), shared by the one-node family
  # (`backend_codex_websocket_owner_forwarding/owner_loss_test.exs`) and the
  # peer-only one (`.../remote_owner_loss_test.exs`). The released client's
  # native frames (turn metadata naming thread and turn) or a public `/v1`
  # SDK's `response.create`, synthetic text; the socket is keyed by its
  # `x-codex-window-id`.

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [
      await_socket_connection_state!: 2,
      completed_response_frames: 4,
      receive_frames_until_close!: 3,
      released_client_frame: 2,
      socket_connection_state!: 1,
      socket_transport_barrier!: 3,
      with_info_log: 1
    ]

  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession}
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport
  alias CodexPoolerWeb.Runtime.OwnerCrashAfterSendScenario
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  @native_route "/backend-api/codex/responses"
  @public_route "/v1/responses"
  @terminal_types ~w(response.completed response.failed response.incomplete error)
  # Detection budget for an owner exit or a socket state the test only observes.
  @detection_timeout_ms 15_000

  def native_route, do: @native_route
  def public_route, do: @public_route

  # A real active public drain, unlike the idle drain below, announces its
  # abort and must retire that turn before accepting the next one. The next
  # turn is held too, so stale messages can be tested against a live successor.
  @spec assert_active_public_drain_recovery!(node() | nil) :: :ok
  def assert_active_public_drain_recovery!(peer_node \\ nil) do
    %{setup: setup, client: client, upstream: upstream, first_gate: first_gate, next_gate: next_gate} = active_drain_socket!(peer_node)
    client = send_public_turn!(client, setup, "active")
    assert_receive {:fake_upstream_timeout_barrier, :before_terminal, first_handler, ^first_gate}, @detection_timeout_ms
    on_exit(fn -> send(first_handler, {:fake_upstream_release_timeout, first_gate}) end)
    before = socket_connection_state!(client.socket)
    assert node(before.websocket_owner_pid) == (peer_node || node())

    client = send_public_turn!(client, setup, "queued")
    _queued = await_socket_connection_state!(client.socket, &(:queue.len(&1.queued_response_payloads) == 1))
    owner_monitor = Process.monitor(before.websocket_owner_pid)
    assert :ok = WebsocketOwnerSession.drain_owner(before.websocket_owner_pid)
    assert_receive {:DOWN, ^owner_monitor, :process, _, :normal}, @detection_timeout_ms
    {client, errors} = receive_public_errors!(client, 2, [])
    assert Enum.sort(Enum.map(errors, & &1["stream_id"])) == ["active", "queued"]
    assert Enum.all?(errors, &(get_in(&1, ["error", "code"]) == "owner_drained"))
    lost = await_socket_connection_state!(client.socket, &(Map.get(&1, :websocket_owner_lost?, false) and MapSet.size(&1.tasks) == 0))
    assert is_nil(lost.public_response_task_pid)
    assert lost.websocket_owner_drain_observed?
    assert :queue.is_empty(lost.queued_response_payloads)
    client = settle!(client)
    assert FakeUpstream.count(upstream) == 1

    client = send_public_turn!(client, setup, "successor")
    assert_receive {:fake_upstream_timeout_barrier, :before_terminal, next_handler, ^next_gate}, @detection_timeout_ms
    on_exit(fn -> send(next_handler, {:fake_upstream_release_timeout, next_gate}) end)
    current = socket_connection_state!(client.socket)
    assert current.websocket_owner_lease_token != before.websocket_owner_lease_token
    assert current.websocket_owner_pid != before.websocket_owner_pid
    assert node(current.websocket_owner_pid) == node()
    refute Map.get(current, :websocket_owner_drain_observed?, false)
    refute current.public_turn_aborted?

    send_retired_turn_messages!(client.socket, before)
    # The callback barrier follows every injected message from this sender.
    after_late = socket_connection_state!(client.socket)
    assert after_late.public_response_task_pid == current.public_response_task_pid
    refute after_late.public_turn_aborted?
    send(next_handler, {:fake_upstream_release_timeout, next_gate})
    {conn, websocket, frames} = receive_turn_frames!(client.conn, client.websocket, client.ref, [])
    assert terminal(frames) == {"response.completed", "resp_active_drain_successor"}
    refute Enum.any?(frames, &(&1["type"] == "error"))
    client = settle!(%{client | conn: conn, websocket: websocket})
    assert FakeUpstream.count(upstream) == 2
    assert_successor_crash!(client, setup, current)
    assert settled_statuses!(setup, 2) == ["failed", "succeeded"]

    requests = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
    assert Enum.all?(requests, &(&1.request_metadata["routing"]["model_serving_mode"] == "full"))

    for request <- requests do
      assert Repo.aggregate(from(e in LedgerEntry, where: e.request_id == ^request.id and e.entry_kind == "settlement"), :count) == 1
    end

    :ok
  end

  defp active_drain_socket!(peer_node) do
    # Draining an active owner cancels a response executor that may be in a
    # transaction. Give its peers independent connections, as production does.
    if is_nil(peer_node), do: OwnerCrashAfterSendScenario.per_process_connections!()
    # This scenario checks recovery, not settlement expiry. Keep the normal
    # owner budget so committed interruption and lease cleanup can finish.
    first_gate = make_ref()
    next_gate = make_ref()

    held = fn id, gate ->
      FakeUpstream.delayed_terminal_sse_stream(
        [%{"type" => "response.output_text.delta", "delta" => "synthetic"}],
        %{"type" => "response.completed", "response" => %{"id" => id, "status" => "completed"}},
        notify: self(),
        release_ref: gate
      )
    end

    upstream = start_upstream(FakeUpstream.strict_sequence([held.("resp_active_drain_old", first_gate), held.("resp_active_drain_successor", next_gate)]))
    setup = gateway_setup(upstream)
    if is_nil(peer_node), do: register_unboxed_pool_cleanup!(setup)
    window = window()
    if peer_node, do: BackendCodexWebsocketOwnerForwardingSupport.start_shared_peer_window_owner!(setup, window.id, peer_node)
    {_server, port} = start_public_endpoint_with_server!()
    client = connect!(port, setup, @public_route, window)
    %{setup: setup, upstream: upstream, client: client, first_gate: first_gate, next_gate: next_gate}
  end

  defp send_public_turn!(client, setup, stream_id) do
    payload = frame(setup, client, "synthetic") |> CodexPooler.JSON.decode!() |> Map.put("stream_id", stream_id) |> CodexPooler.JSON.encode!()
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, payload)
    %{client | conn: conn, websocket: websocket}
  end

  defp receive_public_errors!(client, 0, errors), do: {client, errors}

  defp receive_public_errors!(client, count, errors) do
    {conn, websocket, text} = public_websocket_receive_text!(client.conn, client.websocket, client.ref)
    client = %{client | conn: conn, websocket: websocket}
    event = CodexPooler.JSON.decode!(text)

    if event["type"] == "error",
      do: receive_public_errors!(client, count - 1, [event | errors]),
      else: receive_public_errors!(client, count, errors)
  end

  defp send_retired_turn_messages!(socket, state) do
    task = state.public_response_task_pid
    binding = state.websocket_owner_downstream
    {:ok, payload} = WebsocketOwnerContract.safe_error_payload(:owner_drained, nil)
    send(socket, {:websocket_owner_frame, binding.correlation_id, binding.epoch, task, {:error, :owner_drained, payload}})
    send(socket, {:websocket_owner_frame, binding.correlation_id, binding.epoch, task, :complete})
    send(socket, {:codex_response_done, task, {:error, :owner_drained}})
    send(socket, {:DOWN, Map.fetch!(state.task_monitors, task), :process, task, :normal})
    send(socket, {:DOWN, state.websocket_owner_monitor, :process, state.websocket_owner_pid, :normal})
  end

  defp assert_successor_crash!(client, setup, current) do
    {:ok, log} =
      with_info_log(fn ->
        assert lose_owner!(current.websocket_owner_pid, :owner_killed) == :killed
        assert_closed!(client, {1011, "websocket owner crashed"})
      end)

    assert owner_exit_lines(log) == ["websocket downstream closed after owner exit reason_code=owner_crashed owner=local codex_session_id=#{current.codex_session.id}"]
    lease = Repo.get_by!(BridgeOwnerLease, codex_session_id: current.codex_session.id, lease_token: current.websocket_owner_lease_token)
    assert lease.status == "released"
    assert lease.metadata["release_reason"] == "owner_crashed"
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 2
  end

  @doc "Every request is served: the first as `<prefix>_one`, each later one as `<prefix>_next`."
  def upstream!(prefix) do
    start_upstream(FakeUpstream.repeat_last([completed_response_frames("#{prefix}_one", [], 3, 2), completed_response_frames("#{prefix}_next", [], 3, 2)]))
  end

  @doc "A released-client window of its own thread (`<thread>:0`)."
  def window do
    suffix = System.unique_integer([:positive]) |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")
    thread = "019a0000-0000-7000-8000-#{suffix}"
    %{thread: thread, id: "#{thread}:0"}
  end

  @doc "Opens a socket on `route` keyed by the window, with the listener connection process behind it."
  def connect!(port, setup, route, window) do
    before = WebsocketCleanupFence.listener_sockets()
    {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, Ecto.UUID.generate(), route, [{"x-codex-window-id", window.id}])
    socket = WebsocketCleanupFence.await_new_listener_socket!(before)
    %{conn: conn, websocket: websocket, ref: ref, socket: socket, route: route, thread: window.thread}
  end

  @doc "One request on the client's socket: every frame of the turn (decoded, its terminal last), once the socket settled it."
  def turn!(client, setup, text) do
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame(setup, client, text))
    {conn, websocket, frames} = receive_turn_frames!(conn, websocket, client.ref, [])
    {settle!(%{client | conn: conn, websocket: websocket}), frames}
  end

  @doc "The socket tracks no turn and sent nothing after the last terminal: a later frame would precede the barrier's pong."
  def settle!(client) do
    _idle = await_socket_connection_state!(client.socket, &(MapSet.size(&1.tasks) == 0 and not is_pid(Map.get(&1, :public_response_task_pid))))
    {conn, websocket} = socket_transport_barrier!(client.conn, client.websocket, client.ref)
    %{client | conn: conn, websocket: websocket}
  end

  @doc """
  Makes the owner go away and returns its exit reason: killed, its upstream
  connection process killed (the owner retires `owner_crashed`), drained, or
  stopped normally.
  """
  def lose_owner!(owner, loss) when is_pid(owner) do
    ref = Process.monitor(owner)

    case loss do
      :owner_killed -> Process.exit(owner, :kill)
      :upstream_killed -> Process.exit(:sys.get_state(owner).upstream_pid, :kill)
      # The owner's last turn, relayed and settled, before the drain (findings#287).
      :owner_drained -> {:ok, :settled} = WebsocketOwnerSession.drain_owner(owner)
      :owner_stopped -> :ok = GenServer.stop(owner, :normal)
    end

    assert_receive {:DOWN, ^ref, :process, ^owner, reason}, @detection_timeout_ms
    reason
  end

  @doc "The idle socket closes on its own with `close`, with nothing before the Close, and its connection goes."
  def assert_closed!(client, {code, reason}) do
    {conn, _websocket, frames} = receive_frames_until_close!(client.conn, client.websocket, client.ref)
    Mint.HTTP.close(conn)
    assert frames == [{:close, code, reason}]
    :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
  end

  @doc "The socket saw its owner leave and stays open (the lost owner is marked), with nothing sent to its idle client."
  def await_open_without_owner!(client) do
    lost = await_socket_connection_state!(client.socket, &Map.get(&1, :websocket_owner_lost?, false))
    {settle!(client), lost}
  end

  @doc """
  The next request on the open socket is served by an owner on this node,
  under a lease the socket took over from the one it lost, an owner the socket
  now monitors; the request after it is served by that owner too, without a
  second takeover.
  """
  def assert_next_requests_served!(client, setup, lost, next_id) do
    {client, two} = turn!(client, setup, "after the owner left")
    assert terminal(two) == {"response.completed", next_id}
    refute Enum.any?(two, &(&1["type"] == "error"))

    session = Repo.get!(CodexSession, lost.codex_session.id)
    assert session.owner_instance_id == Atom.to_string(node())
    after_two = socket_connection_state!(client.socket)
    assert session.owner_lease_token != lost.websocket_owner_lease_token
    assert after_two.websocket_owner_lease_token == session.owner_lease_token
    assert {:ok, owner} = WebsocketOwnerSession.lookup(session.id)
    assert after_two.websocket_owner_pid == owner
    refute Map.has_key?(after_two, :websocket_owner_lost?)

    {client, three} = turn!(client, setup, "the request after it")
    assert terminal(three) == {"response.completed", next_id}
    assert socket_connection_state!(client.socket).websocket_owner_downstream == after_two.websocket_owner_downstream
    client
  end

  @doc "The client's next request on a new socket is served by an owner on this node that took the session over."
  def assert_new_socket_served!(port, setup, route, window, session_id, next_id) do
    before = Repo.get!(CodexSession, session_id)
    retry = connect!(port, setup, route, window)
    {retry, next} = turn!(retry, setup, "on the client's new socket")
    assert terminal(next) == {"response.completed", next_id}
    session = Repo.get!(CodexSession, session_id)
    assert session.owner_instance_id == Atom.to_string(node())
    assert session.owner_lease_token != before.owner_lease_token
    close!(retry)
  end

  @doc "The owner-exit lines of `log`, from their message on."
  def owner_exit_lines(log) do
    log
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ "after owner exit"))
    |> Enum.map(&Regex.replace(~r/\A.*?(websocket downstream)/, &1, "\\1"))
  end

  def terminal(frames) do
    %{"type" => type} = last = List.last(frames)
    {type, get_in(last, ["response", "id"]) || get_in(last, ["error", "code"])}
  end

  def close!(client) do
    Mint.HTTP.close(client.conn)
    :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
  end

  @doc "The Pool's request rows once `count` of them settled, oldest first."
  def settled_statuses!(setup, count, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @detection_timeout_ms
    statuses = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: [asc: r.admitted_at], select: r.status))

    cond do
      length(statuses) == count and "in_progress" not in statuses ->
        statuses

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          10 -> settled_statuses!(setup, count, deadline)
        end

      true ->
        flunk("request rows did not settle: #{inspect(statuses)}")
    end
  end

  defp frame(setup, %{route: @native_route, thread: thread}, text),
    do: released_client_frame(setup, thread).(native_text_input(text), Ecto.UUID.generate(), %{})

  defp frame(setup, %{route: @public_route}, text),
    do: CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => native_text_input(text), "stream" => true})

  defp receive_turn_frames!(conn, websocket, ref, frames) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    frames = frames ++ [CodexPooler.JSON.decode!(text)]

    if List.last(frames)["type"] in @terminal_types,
      do: {conn, websocket, frames},
      else: receive_turn_frames!(conn, websocket, ref, frames)
  end
end
