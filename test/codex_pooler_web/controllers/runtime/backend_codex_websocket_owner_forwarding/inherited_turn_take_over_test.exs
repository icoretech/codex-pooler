defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.InheritedTurnTakeOverTest do
  # The released Codex client drops a socket in the middle of a streaming tool
  # continuation and at once opens a new one, which sends the same turn again as
  # an unanchored full-history request. The new socket attaches while the owner
  # still runs the dropped turn, and the attach hands that running, already
  # visible turn to it. Its request was refused `409 duplicate_turn` (same turn,
  # `runtime_replay_preflight lifecycle_conflict`) or `409 owner_busy` (another
  # turn) until the client closed that socket in reaction, which is what finally
  # cancelled the inherited turn; the retry on the next socket was served about
  # 0.7 s later (findings#206 rows 206-359 and 206-362: 22 production cases in
  # 6.5 days from one Desktop user, every predecessor post-visible). The socket
  # now takes the inherited turn over: the owner cancels it as that close would,
  # the predecessor settles once, and the request is judged against the settled
  # state and served on its first send. An owner node from an earlier release
  # has no take-over and keeps the refusal.
  #
  # Topology: the real public listener, owner forwarding on, the session's owner
  # on this node or on a second VM sharing the committed database; Full (and
  # Lite for the local owner). The provider holds the predecessor at a frame
  # barrier after its first visible delta.
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, with_info_log: 1]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_peer_window_owner!: 2, request_logs: 1]

  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo

  @detection_timeout_ms 15_000
  @thread_id "019a0000-0000-7000-8000-00000000e362"
  @window_id "#{@thread_id}:0"
  @call_id "call_inherited_take_over"

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    :ok
  end

  for {topology, mode} <- [{:local, "full"}, {:local, "lite"}, {:peer, "full"}] do
    @tag topology: topology, serving_mode: mode
    test "the full-history resend of an inherited post-visible tool continuation is served on its first send (#{topology} owner, #{mode})",
         %{topology: topology, serving_mode: mode} do
      {outcome, logs} = with_info_log(fn -> run_scenario(topology, mode, :same_turn) end)

      assert outcome.first_answer == {"response.completed", "resp_take_over_successor"}
      assert_one_charge_each!(outcome)
      assert logs =~ "websocket reconnect disposition"
      assert logs =~ "reconnect_disposition=inherited_turn_taken_over"
      refute logs =~ "reason_code=lifecycle_conflict"
    end
  end

  test "another turn from the socket that inherited a post-visible turn is served on its first send (local owner, full)" do
    {outcome, logs} = with_info_log(fn -> run_scenario(:local, "full", :next_turn) end)

    assert outcome.first_answer == {"response.completed", "resp_take_over_successor"}
    assert_one_charge_each!(outcome)
    assert logs =~ "websocket owner inherited turn taken over"
    assert logs =~ "reconnect_disposition=inherited_turn_taken_over"
  end

  # An owner node from an earlier release has no take-over entrypoint: the
  # socket keeps today's refusal and the client's own close still cancels the
  # inherited turn.
  test "an owner node without the take-over keeps the refusal (peer owner of an earlier release, full)" do
    {outcome, logs} = with_info_log(fn -> run_scenario(:peer_previous, "full", :same_turn) end)

    assert logs =~ "boundary=inherited_turn_take_over protocol=v1"
    refute logs =~ "inherited_turn_taken_over"
    assert logs =~ "reason_code=lifecycle_conflict"
    assert outcome.first_answer == {"error", 409, "duplicate_turn"}
    assert outcome.predecessor_in_progress_at_answer?
    assert outcome.upstream_count == 2
  end

  # The socket that inherited the running turn closes before it sends
  # anything. It has no response task of its own, so it exits right after
  # `terminate/2`'s 100 ms wait on its session cleanup, and a slower cleanup
  # (held here at its first query) reaches the owner only after the owner
  # handled the socket's exit. The owner's monitor keeps a post-visible turn
  # running for a socket that died without detaching; the socket's own detach
  # then came back `stale_downstream`, nothing cancelled the turn, and it ran
  # until the provider ended it while every resend met the live predecessor
  # (findings#206). The late detach of that exact socket is now applied.
  # When another socket attached in between, the turn is that socket's: the
  # late detach leaves it running and the new socket takes it over as before.
  for topology <- [:local, :peer], successor <- [:none, :reattach] do
    @tag topology: topology, successor: successor
    test "a late detach of the socket that inherited a post-visible turn #{if successor == :none, do: "cancels it", else: "leaves it to the socket that re-attached"} (#{topology} owner, full)",
         %{topology: topology, successor: successor} do
      {outcome, _logs} = with_info_log(fn -> run_late_detach_scenario(topology, successor) end)

      case successor do
        :none ->
          assert outcome.predecessor_status_after_late_detach == "failed"
          assert [opening, predecessor] = outcome.requests
          assert {opening.status, predecessor.status, predecessor.response_status_code, predecessor.last_error_code} == {"succeeded", "failed", 499, "client_disconnected"}
          assert outcome.upstream_count == 2

        :reattach ->
          assert outcome.turn_after_late_detach == :running_on_reattached_socket
          assert outcome.first_answer == {"response.completed", "resp_take_over_successor"}
          assert_one_charge_each!(outcome)
      end
    end
  end

  defp assert_one_charge_each!(outcome) do
    assert [opening, predecessor, successor] = outcome.requests
    assert {opening.status, predecessor.status, successor.status} == {"succeeded", "failed", "succeeded"}
    assert {predecessor.response_status_code, predecessor.last_error_code} == {499, "client_disconnected"}
    assert Repo.get_by!(CodexTurn, request_id: predecessor.id).status in ["failed", "interrupted"]

    for request <- outcome.requests do
      assert ledger_kinds(request.id) == %{"reservation" => 1, "settlement" => 1, "release" => 1}
    end

    # The provider generated the opening, the cancelled predecessor and the
    # successor once each; nothing was dispatched twice.
    assert outcome.upstream_count == 3
  end

  defp run_scenario(topology, mode, successor_kind) do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # provenance: observed findings#206 row 206-359 (kain Desktop: a post-visible anchored tool continuation, then the same turn's unanchored full-history request on a new socket)
        FakeUpstream.strict_sequence(
          [
            native_request(FakeUpstream.websocket_text_frames(opening_frames())),
            native_request(FakeUpstream.barrier_websocket_frames(held_continuation_frames(), notify: self(), release_ref: release_ref))
          ] ++ if(topology == :peer_previous, do: [], else: [native_request(FakeUpstream.websocket_text_frames([completed_frame("resp_take_over_successor", [])]))])
        )
      )

    setup = topology_setup!(topology, upstream)
    if mode == "lite", do: set_model_serving_mode!(model_serving_scope(), setup, "lite")
    model = setup.model.exposed_model_id
    user = synthetic_user_item("take over question")
    port = start_public_endpoint!()

    # Socket A: the opening request, then the anchored tool continuation, held
    # by the provider after its first visible delta.
    {conn_a, ws_a, ref_a} = connect!(port, setup)
    {conn_a, ws_a} = public_websocket_send_text!(conn_a, ws_a, ref_a, encode(turn_payload(model, "turn-take-over", [user])))
    {conn_a, ws_a, opening} = receive_until_terminal!(conn_a, ws_a, ref_a)
    assert List.last(opening)["type"] == "response.completed"

    continuation =
      model
      |> turn_payload("turn-take-over", [tool_output_item()])
      |> Map.put("previous_response_id", "resp_take_over_opening")

    {conn_a, ws_a} = public_websocket_send_text!(conn_a, ws_a, ref_a, encode(continuation))

    for ordinal <- [0, 1, 2] do
      assert_receive {:fake_upstream_frame_barrier, ^ordinal, _handler, ^release_ref}, @detection_timeout_ms
      assert :ok = FakeUpstream.release_frame(upstream, release_ref)
    end

    assert_receive {:fake_upstream_frame_barrier, 3, _handler, ^release_ref}, @detection_timeout_ms
    {conn_a, ws_a, visible} = receive_types!(conn_a, ws_a, ref_a, 3)
    assert visible == ["response.created", "response.output_item.added", "response.output_text.delta"]
    assert [_opening, %Request{id: predecessor_id, status: "in_progress"}] = request_logs(setup.pool.id)
    refute is_nil(Repo.get_by!(CodexTurn, request_id: predecessor_id).first_visible_output_at)

    # The client drops A and opens B at once; B's attach inherits the running
    # visible turn before the owner learns that A went away.
    _closed = Mint.HTTP.close(conn_a)
    _ws_a = ws_a
    {conn_b, ws_b, ref_b} = connect!(port, setup)
    owner = owner_pid(topology, setup)
    await_inherited_visible_turn!(owner)

    successor =
      case successor_kind do
        :same_turn -> turn_payload(model, "turn-take-over", [user, function_call_item(), tool_output_item()])
        :next_turn -> turn_payload(model, "turn-after-take-over", [user, function_call_item(), tool_output_item(), synthetic_user_item("next question")])
      end

    {conn_b, ws_b} = public_websocket_send_text!(conn_b, ws_b, ref_b, encode(successor))
    {conn_b, _ws_b, answer} = receive_until_terminal!(conn_b, ws_b, ref_b)
    predecessor_in_progress? = Repo.get!(Request, predecessor_id).status == "in_progress"
    last = List.last(answer)

    first_answer =
      case last do
        %{"type" => "error"} -> {"error", last["status"], get_in(last, ["error", "code"])}
        %{"type" => type} -> {type, get_in(last, ["response", "id"])}
      end

    _closed = Mint.HTTP.close(conn_b)
    assert await_request_settled(predecessor_id, System.monotonic_time(:millisecond) + @detection_timeout_ms) == "failed"
    _released = FakeUpstream.release_remaining_frames(upstream, release_ref)
    requests = request_logs(setup.pool.id)

    for request <- requests,
        do: assert(await_request_settled(request.id, System.monotonic_time(:millisecond) + @detection_timeout_ms) != "in_progress")

    %{
      first_answer: first_answer,
      predecessor_in_progress_at_answer?: predecessor_in_progress?,
      requests: Enum.map(requests, &Repo.get!(Request, &1.id)),
      upstream_count: FakeUpstream.count(upstream)
    }
  end

  defp run_late_detach_scenario(topology, successor) do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence(
          [
            native_request(FakeUpstream.websocket_text_frames(opening_frames())),
            native_request(FakeUpstream.barrier_websocket_frames(held_continuation_frames(), notify: self(), release_ref: release_ref))
          ] ++ if(successor == :reattach, do: [native_request(FakeUpstream.websocket_text_frames([completed_frame("resp_take_over_successor", [])]))], else: [])
        )
      )

    setup = topology_setup!(topology, upstream)
    model = setup.model.exposed_model_id
    user = synthetic_user_item("take over question")
    port = start_public_endpoint!()
    {conn_a, ws_a, ref_a, predecessor_id} = visible_held_continuation!(port, setup, model, user, upstream, release_ref)

    # A drops; B attaches at once and inherits the running visible turn.
    _closed = Mint.HTTP.close(conn_a)
    _dropped = {ws_a, ref_a}
    {conn_b, _ws_b, _ref_b} = connect!(port, setup)
    owner = owner_pid(topology, setup)
    await_inherited_visible_turn!(owner)
    %{downstream: %{pid: socket_b}} = :sys.get_state(owner)

    # B closes; its session cleanup is held at its first query until the owner
    # has handled B's exit.
    hold = hold_session_cleanup!(socket_b)
    socket_monitor = Process.monitor(socket_b)
    _closed = Mint.HTTP.close(conn_b)
    assert_receive {^hold, :held, cleanup}, @detection_timeout_ms
    assert_receive {:DOWN, ^socket_monitor, :process, ^socket_b, _reason}, @detection_timeout_ms
    await_owner_state!(owner, &match?(%{downstream: nil, active_turn: %{downstream: %{pid: ^socket_b}, visible_output?: true}}, &1), "the owner never handled the exit of the inheriting socket")

    reattached = if successor == :reattach, do: reattach!(port, setup, owner)
    release_session_cleanup!(hold, cleanup)

    case successor do
      :none ->
        status = await_request_settled(predecessor_id, System.monotonic_time(:millisecond) + @detection_timeout_ms)
        _released = FakeUpstream.release_remaining_frames(upstream, release_ref)
        requests = settled_requests!(setup)
        %{predecessor_status_after_late_detach: status, requests: requests, upstream_count: FakeUpstream.count(upstream)}

      :reattach ->
        {conn_c, ws_c, ref_c, socket_c} = reattached
        turn = late_detach_turn_state(owner, socket_c, predecessor_id)
        successor_payload = turn_payload(model, "turn-take-over", [user, function_call_item(), tool_output_item()])
        {conn_c, ws_c} = public_websocket_send_text!(conn_c, ws_c, ref_c, encode(successor_payload))
        {conn_c, _ws_c, answer} = receive_until_terminal!(conn_c, ws_c, ref_c)
        last = List.last(answer)
        _closed = Mint.HTTP.close(conn_c)
        _released = FakeUpstream.release_remaining_frames(upstream, release_ref)
        requests = settled_requests!(setup)

        %{
          turn_after_late_detach: turn,
          first_answer: {last["type"], get_in(last, ["response", "id"])},
          requests: requests,
          upstream_count: FakeUpstream.count(upstream)
        }
    end
  end

  # Socket A: the opening request, then the anchored tool continuation, held
  # by the provider after its first visible delta.
  defp visible_held_continuation!(port, setup, model, user, upstream, release_ref) do
    {conn_a, ws_a, ref_a} = connect!(port, setup)
    {conn_a, ws_a} = public_websocket_send_text!(conn_a, ws_a, ref_a, encode(turn_payload(model, "turn-take-over", [user])))
    {conn_a, ws_a, opening} = receive_until_terminal!(conn_a, ws_a, ref_a)
    assert List.last(opening)["type"] == "response.completed"

    continuation =
      model
      |> turn_payload("turn-take-over", [tool_output_item()])
      |> Map.put("previous_response_id", "resp_take_over_opening")

    {conn_a, ws_a} = public_websocket_send_text!(conn_a, ws_a, ref_a, encode(continuation))

    for ordinal <- [0, 1, 2] do
      assert_receive {:fake_upstream_frame_barrier, ^ordinal, _handler, ^release_ref}, @detection_timeout_ms
      assert :ok = FakeUpstream.release_frame(upstream, release_ref)
    end

    assert_receive {:fake_upstream_frame_barrier, 3, _handler, ^release_ref}, @detection_timeout_ms
    {conn_a, ws_a, visible} = receive_types!(conn_a, ws_a, ref_a, 3)
    assert visible == ["response.created", "response.output_item.added", "response.output_text.delta"]
    assert [_opening, %Request{id: predecessor_id, status: "in_progress"}] = request_logs(setup.pool.id)
    {conn_a, ws_a, ref_a, predecessor_id}
  end

  # C attaches after B's exit and before B's late detach, and inherits the turn.
  defp reattach!(port, setup, owner) do
    {conn_c, ws_c, ref_c} = connect!(port, setup)
    await_inherited_visible_turn!(owner)
    %{downstream: %{pid: socket_c}} = :sys.get_state(owner)
    {conn_c, ws_c, ref_c, socket_c}
  end

  defp late_detach_turn_state(owner, socket_c, predecessor_id) do
    case {:sys.get_state(owner), Repo.get!(Request, predecessor_id).status} do
      {%{downstream: %{pid: ^socket_c}, active_turn: %{downstream: %{pid: ^socket_c}} = active_turn}, "in_progress"} ->
        if Map.has_key?(active_turn, :canceled_result), do: :cancelled_by_late_detach, else: :running_on_reattached_socket

      {state, status} ->
        {:unexpected, Map.take(state, [:downstream]), status}
    end
  end

  defp settled_requests!(setup) do
    requests = request_logs(setup.pool.id)

    for request <- requests,
        do: assert(await_request_settled(request.id, System.monotonic_time(:millisecond) + @detection_timeout_ms) != "in_progress")

    Enum.map(requests, &Repo.get!(Request, &1.id))
  end

  defp await_owner_state!(owner, condition, message) do
    deadline_ms = System.monotonic_time(:millisecond) + @detection_timeout_ms

    Stream.repeatedly(fn -> :sys.get_state(owner) end)
    |> Enum.find(fn state -> condition.(state) or System.monotonic_time(:millisecond) >= deadline_ms or (Process.sleep(5) && false) end)
    |> then(&assert(condition.(&1), message))
  end

  # Holds the session cleanup task of `socket` right after its first query (the
  # owner lease read in front of its detach). The query has returned and its
  # connection is back in the pool, so nothing else waits on the hold.
  defp hold_session_cleanup!(socket) do
    hold = make_ref()
    handler_id = {__MODULE__, :session_cleanup_hold, hold}
    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok = :telemetry.attach(handler_id, [:codex_pooler, :repo, :query], &__MODULE__.hold_session_cleanup_query/4, %{hold: hold, test: self(), socket: socket})
    hold
  end

  @doc false
  def hold_session_cleanup_query(_event, _measurements, _metadata, %{hold: hold, test: test, socket: socket}) do
    if socket in Process.get(:"$callers", []) and match?({CodexPoolerWeb.WebsocketControlPath, _function, _arity}, Process.get(:"$initial_call")) and is_nil(Process.get({__MODULE__, hold})) do
      Process.put({__MODULE__, hold}, :held)
      send(test, {hold, :held, self()})

      receive do
        {^hold, :release} -> :ok
      after
        @detection_timeout_ms -> :ok
      end
    end

    :ok
  end

  defp release_session_cleanup!(hold, cleanup) do
    monitor = Process.monitor(cleanup)
    send(cleanup, {hold, :release})
    assert_receive {:DOWN, ^monitor, :process, ^cleanup, _reason}, @detection_timeout_ms
    :telemetry.detach({__MODULE__, :session_cleanup_hold, hold})
  end

  # The peer shares the committed database, so its fixture is committed: the
  # sandbox switches to auto mode before anything is written.
  defp topology_setup!(topology, upstream) when topology in [:peer, :peer_previous] do
    enter_peer_owner_topology!()
    setup = gateway_setup(upstream)
    peer_owner = start_peer_window_owner!(setup, @window_id)
    if topology == :peer_previous, do: load_forwarder_without_take_over!(peer_owner.node)
    Map.put(setup, :peer_owner, peer_owner)
  end

  defp topology_setup!(:local, upstream), do: gateway_setup(upstream)

  # An owner node of an earlier release: this release's forwarder compiled
  # without the take-over functions, so the socket's call meets the real erpc
  # `undef`.
  @take_over_functions [:remote_take_over_inherited_turn_v1, :take_over_inherited_turn, :call_remote_take_over]

  defp load_forwarder_without_take_over!(node) do
    {:ok, {WebsocketOwnerForwarder, [abstract_code: {:raw_abstract_v1, forms}]}} =
      WebsocketOwnerForwarder |> :code.which() |> :beam_lib.chunks([:abstract_code])

    stripped =
      forms
      |> Enum.reject(fn
        {:function, _line, name, _arity, _clauses} -> name in @take_over_functions
        {:attribute, _line, :spec, {{name, _arity}, _types}} -> name in @take_over_functions
        _form -> false
      end)
      |> Enum.map(fn
        {:attribute, line, :export, exports} -> {:attribute, line, :export, Enum.reject(exports, fn {name, _arity} -> name in @take_over_functions end)}
        form -> form
      end)

    {:ok, WebsocketOwnerForwarder, binary} = :compile.forms(stripped, [:binary, :return_errors])
    assert {:module, WebsocketOwnerForwarder} = :erpc.call(node, :code, :load_binary, [WebsocketOwnerForwarder, ~c"previous_release_forwarder", binary])
    refute :erpc.call(node, :erlang, :function_exported, [WebsocketOwnerForwarder, :remote_take_over_inherited_turn_v1, 2])
  end

  defp owner_pid(:local, setup) do
    [session_id] = Repo.all(from(session in CodexSession, where: session.pool_id == ^setup.pool.id, select: session.id))
    assert {:ok, owner} = WebsocketOwnerSession.lookup(session_id)
    owner
  end

  defp owner_pid(_peer, setup), do: setup.peer_owner.owner_pid

  # No signal marks the attach of B inside the owner, so this polls the owner's
  # state until the running turn's downstream is the socket that attached while
  # the turn was active, with visible output.
  defp await_inherited_visible_turn!(owner) do
    deadline_ms = System.monotonic_time(:millisecond) + @detection_timeout_ms

    Stream.repeatedly(fn -> :sys.get_state(owner) end)
    |> Enum.find(fn state ->
      inherited?(state) or System.monotonic_time(:millisecond) >= deadline_ms or (Process.sleep(5) && false)
    end)
    |> then(&assert(inherited?(&1), "the new socket never inherited the running visible turn"))
  end

  defp inherited?(%{downstream: %{pid: pid, active_turn_reconnect?: true}, active_turn: %{downstream: %{pid: pid}, visible_output?: true}}), do: true
  defp inherited?(_state), do: false

  defp connect!(port, setup) do
    {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, Ecto.UUID.generate(), "/backend-api/codex/responses", [{"x-codex-window-id", @window_id}])
    {conn, websocket, ref}
  end

  defp native_request(respond) do
    FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", json: [valid: true, equals: %{"type" => "response.create"}], respond: respond)
  end

  defp turn_payload(model, turn_id, input) do
    %{
      "type" => "response.create",
      "model" => model,
      "instructions" => "synthetic base instructions",
      "stream" => true,
      "store" => false,
      "tools" => [%{"type" => "function", "name" => "shell", "parameters" => %{"type" => "object", "properties" => %{}}}],
      "client_metadata" => %{
        "session_id" => @thread_id,
        "thread_id" => @thread_id,
        "turn_id" => turn_id,
        "x-codex-window-id" => @window_id,
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => @thread_id, "thread_id" => @thread_id, "turn_id" => turn_id, "request_kind" => "turn"})
      },
      "input" => input
    }
  end

  defp synthetic_user_item(text),
    do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic " <> text}]}

  defp function_call_item,
    do: %{"type" => "function_call", "id" => "fc_inherited_take_over", "call_id" => @call_id, "name" => "shell", "arguments" => "{}", "status" => "completed"}

  defp tool_output_item, do: %{"type" => "function_call_output", "call_id" => @call_id, "output" => "synthetic tool output"}

  defp opening_frames do
    [
      encode(%{"type" => "response.created", "response" => %{"id" => "resp_take_over_opening", "status" => "in_progress", "output" => []}}),
      encode(%{"type" => "response.output_item.added", "output_index" => 0, "item" => function_call_item()}),
      encode(%{"type" => "response.output_item.done", "output_index" => 0, "item" => function_call_item()}),
      completed_frame("resp_take_over_opening", [function_call_item()])
    ]
  end

  defp held_continuation_frames do
    message = %{"type" => "message", "id" => "msg_inherited_take_over", "role" => "assistant", "status" => "in_progress", "content" => []}

    [
      encode(%{"type" => "response.created", "response" => %{"id" => "resp_take_over_predecessor", "status" => "in_progress", "output" => []}}),
      encode(%{"type" => "response.output_item.added", "output_index" => 0, "item" => message}),
      encode(%{"type" => "response.output_text.delta", "output_index" => 0, "content_index" => 0, "item_id" => "msg_inherited_take_over", "delta" => "synthetic visible"}),
      completed_frame("resp_take_over_predecessor", [])
    ]
  end

  defp completed_frame(response_id, output) do
    encode(%{
      "type" => "response.completed",
      "response" => %{"id" => response_id, "status" => "completed", "output" => output, "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}
    })
  end

  defp encode(map), do: CodexPooler.JSON.encode!(map)

  defp receive_types!(conn, websocket, ref, count) do
    Enum.reduce(1..count, {conn, websocket, []}, fn _index, {conn, websocket, types} ->
      {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
      {conn, websocket, types ++ [CodexPooler.JSON.decode!(text)["type"]]}
    end)
  end

  defp receive_until_terminal!(conn, websocket, ref, frames \\ []) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    frames = frames ++ [CodexPooler.JSON.decode!(text)]

    if List.last(frames)["type"] in ["response.completed", "response.failed", "response.incomplete", "error"],
      do: {conn, websocket, frames},
      else: receive_until_terminal!(conn, websocket, ref, frames)
  end

  defp await_request_settled(request_id, deadline_ms) do
    case Repo.get!(Request, request_id) do
      %Request{status: status} when status in ["accepted", "in_progress"] ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          status
        else
          Process.sleep(10)
          await_request_settled(request_id, deadline_ms)
        end

      %Request{status: status} ->
        status
    end
  end

  defp ledger_kinds(request_id) do
    Repo.all(from(entry in LedgerEntry, where: entry.request_id == ^request_id, select: entry.entry_kind))
    |> Enum.frequencies()
  end
end
