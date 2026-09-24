defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.InheritedTurnEdgesTest do
  # The two edges left around the take-over of an inherited running turn
  # (findings#206 rows 206-407 and 206-408).
  #
  # 206-407. The released Codex client drops a socket in the middle of a
  # streaming tool continuation and at once sends the same turn again on a new
  # socket as an unanchored full-history request. With owner forwarding off
  # (the chart default for a single app replica) the dropped socket's direct
  # task keeps the predecessor turn `in_progress` until that socket's cleanup
  # stops it, 250 ms after the close plus its settlement. A resend claimed in
  # that window carries a different request claim than the anchored
  # predecessor, so nothing fenced it before the reservation tried to start its
  # turn: the active-turn index (`codex_turns_active_semantic_turn_uq`) raised,
  # the client got `500 websocket_response_task_failed`, and the claimed request
  # stayed `accepted` with no ledger entry. The claim now waits, bounded, until
  # the database shows the live predecessor of that turn settled and is then
  # served; a predecessor still live at the bound answers the retryable
  # `409 duplicate_turn` before anything is claimed.
  #
  # 206-408. A released-client turn that has not shown output yet is
  # replay-active at the owner, so a new socket attaching while it runs gets
  # only a candidate and the turn stays with the old socket (it is never
  # inherited): when the old socket's close is seen first, the resend redeems
  # the replay that close armed and is served on its first send; when the
  # resend arrives before that close, it answers `409 duplicate_turn` and the
  # client's retry redeems the replay. That one retry is kept by decision (the
  # take-over only cancels a turn the requesting socket itself holds).
  #
  # Topology: one VM, the real public listener, the released client's frames
  # with turn metadata, FakeUpstream holding the predecessor at a frame barrier.
  # 206-407 runs with owner forwarding off (Full and Lite), 206-408 with it on
  # (Full).
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, with_info_log: 1]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [request_logs: 1]

  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo

  @detection_timeout_ms 15_000
  @thread_id "019a0000-0000-7000-8000-00000000e407"
  @window_id "#{@thread_id}:0"
  @call_id "call_inherited_edge"

  describe "owner forwarding off: a same-turn full-history resend while the dropped socket's turn is live (206-407)" do
    setup do
      put_owner_forwarding!(false)
    end

    for mode <- ["full", "lite"] do
      @tag serving_mode: mode
      test "is served once the dropped socket's turn settles, and no request is left accepted (#{mode})", %{serving_mode: mode} do
        {outcome, logs} = with_info_log(fn -> run_direct_resend(mode, :close_first_socket) end)

        assert outcome.first_answer == {"response.completed", "resp_edge_successor"}
        assert outcome.predecessor_at_answer == "failed"
        assert logs =~ "websocket turn claim met a live predecessor of the same turn"
        assert logs =~ "outcome=settled"
        refute logs =~ "websocket_response_task_failed"
        refute logs =~ "unique_violation"

        assert [opening, predecessor, successor] = outcome.requests
        assert {opening.status, predecessor.status, successor.status} == {"succeeded", "failed", "succeeded"}
        assert {predecessor.response_status_code, predecessor.last_error_code} == {499, "client_disconnected"}
        for request <- outcome.requests, do: assert(ledger_kinds(request.id) == %{"reservation" => 1, "settlement" => 1, "release" => 1})
        # The provider generated the opening, the cut predecessor and the resend once each.
        assert outcome.upstream_count == 3
      end
    end

    # The first socket stays open (the Pooler has not seen the client leave),
    # so the predecessor never settles within the wait: the resend is refused
    # with the retryable 409 before anything is claimed, never a 500.
    test "answers the retryable 409 when the turn is still live at the bound, and claims nothing (full)" do
      {outcome, logs} = with_info_log(fn -> run_direct_resend("full", :keep_first_socket) end)

      assert outcome.first_answer == {"error", 409, "duplicate_turn"}
      assert outcome.predecessor_at_answer == "in_progress"
      assert logs =~ "websocket turn claim met a live predecessor of the same turn"
      assert logs =~ "outcome=live"
      refute logs =~ "websocket_response_task_failed"
      refute logs =~ "unique_violation"
      assert [_opening, _predecessor] = outcome.requests
      refute Enum.any?(outcome.requests, &(&1.status == "accepted"))
      assert outcome.upstream_count == 2
    end
  end

  describe "owner forwarding off: a same-turn frame on the same socket while the turn's previous task still runs (206-413)" do
    setup do
      put_owner_forwarding!(false)
    end

    # An unanchored frame of the running turn is not continuity-ordered, so the
    # socket dispatches it next to the task that still holds the turn; its
    # claim now meets the live predecessor before the reservation instead of
    # the active-turn index at turn start.
    test "answers the retryable 409, never a 500, claims nothing, and the running turn completes (full)" do
      {outcome, logs} = with_info_log(fn -> run_same_socket_frame() end)

      assert outcome.second_answer == {"error", 409, "duplicate_turn"}
      assert outcome.first_answer == {"response.completed", "resp_edge_predecessor"}
      assert logs =~ "outcome=live"
      refute logs =~ "websocket_response_task_failed"
      refute logs =~ "unique_violation"
      assert [opening, predecessor] = outcome.requests
      assert {opening.status, predecessor.status} == {"succeeded", "succeeded"}
      assert outcome.upstream_count == 2
    end
  end

  describe "owner forwarding on: a pre-visible turn is never inherited by the next socket (206-408)" do
    setup do
      put_owner_forwarding!(true)
    end

    test "the resend sent before the old socket's close is refused once, and the retry redeems the replay that close armed (full)" do
      {outcome, logs} = with_info_log(fn -> run_previsible_unobserved_cut() end)

      # The new socket got only a candidate: the owner kept the old socket as
      # the downstream of the pre-visible replay-active turn.
      refute outcome.inherited_after_attach?
      assert outcome.first_answer == {"error", 409, "duplicate_turn"}
      assert logs =~ "reconnect_disposition=identity_rejected"
      refute logs =~ "inherited_turn_taken_over"
      assert outcome.suspended_replay_after_close?
      assert outcome.retry_answer == {"response.completed", "resp_edge_successor"}

      # The replay generation is billed on the predecessor's own request.
      assert [opening, predecessor] = outcome.requests
      assert {opening.status, predecessor.status} == {"succeeded", "succeeded"}
      for request <- outcome.requests, do: assert(ledger_kinds(request.id) == %{"reservation" => 1, "settlement" => 1, "release" => 1})
      assert outcome.upstream_count == 3
    end
  end

  defp put_owner_forwarding!(enabled?) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled?)
    :ok
  end

  defp run_direct_resend(mode, first_socket) do
    release_ref = make_ref()
    successor = if first_socket == :close_first_socket, do: [native_request(FakeUpstream.websocket_text_frames([completed_frame("resp_edge_successor", [])]))], else: []

    upstream =
      start_upstream(
        # provenance: observed findings#206 row 206-359 (a post-visible anchored tool continuation, then the same turn's unanchored full-history request on a new socket), with owner forwarding off
        FakeUpstream.strict_sequence(
          [
            native_request(FakeUpstream.websocket_text_frames(opening_frames())),
            native_request(FakeUpstream.barrier_websocket_frames(held_continuation_frames(), notify: self(), release_ref: release_ref))
          ] ++ successor
        )
      )

    setup = gateway_setup(upstream)
    if mode == "lite", do: set_model_serving_mode!(model_serving_scope(), setup, "lite")
    model = setup.model.exposed_model_id
    user = synthetic_user_item("edge question")
    port = start_public_endpoint!()

    {conn_a, ws_a, ref_a} = open_continuation!(port, setup, model, user)
    stream_until_visible!(upstream, release_ref, conn_a, ws_a, ref_a)
    assert [_opening, %Request{id: predecessor_id, status: "in_progress"}] = request_logs(setup.pool.id)

    # The client drops the first socket (or the Pooler has not seen it go) and
    # at once sends the same turn as full history on a new one.
    if first_socket == :close_first_socket, do: Mint.HTTP.close(conn_a)
    {conn_b, ws_b, ref_b} = connect!(port, setup)
    resend = turn_payload(model, "turn-edge", [user, function_call_item(), tool_output_item()])
    {conn_b, ws_b} = public_websocket_send_text!(conn_b, ws_b, ref_b, encode(resend))
    {conn_b, _ws_b, answer} = receive_until_terminal!(conn_b, ws_b, ref_b)
    predecessor_at_answer = Repo.get!(Request, predecessor_id).status
    _closed = Mint.HTTP.close(conn_b)
    if first_socket == :keep_first_socket, do: Mint.HTTP.close(conn_a)
    _released = FakeUpstream.release_remaining_frames(upstream, release_ref)

    %{
      first_answer: answer_summary(List.last(answer)),
      predecessor_at_answer: predecessor_at_answer,
      requests: settled_requests!(setup.pool.id),
      upstream_count: FakeUpstream.count(upstream)
    }
  end

  defp run_same_socket_frame do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # provenance: observed findings#206 row 206-413 (a same-turn frame dispatched on the socket while the turn's previous task still holds it, owner forwarding off)
        FakeUpstream.strict_sequence([
          native_request(FakeUpstream.websocket_text_frames(opening_frames())),
          native_request(FakeUpstream.barrier_websocket_frames(held_continuation_frames(), notify: self(), release_ref: release_ref))
        ])
      )

    setup = gateway_setup(upstream)
    model = setup.model.exposed_model_id
    user = synthetic_user_item("edge question")
    port = start_public_endpoint!()

    {conn, ws, ref} = open_continuation!(port, setup, model, user)
    stream_until_visible!(upstream, release_ref, conn, ws, ref)
    frame = turn_payload(model, "turn-edge", [user, function_call_item(), tool_output_item()])
    {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(frame))
    {conn, ws, second} = receive_until_terminal!(conn, ws, ref)
    :ok = FakeUpstream.release_remaining_frames(upstream, release_ref)
    {conn, _ws, first} = receive_until_terminal!(conn, ws, ref)
    _closed = Mint.HTTP.close(conn)

    %{
      second_answer: answer_summary(List.last(second)),
      first_answer: answer_summary(List.last(first)),
      requests: settled_requests!(setup.pool.id),
      upstream_count: FakeUpstream.count(upstream)
    }
  end

  defp run_previsible_unobserved_cut do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # provenance: observed findings#206 row 206-408 shape (a released-client tool continuation cut before any output, its full-history resend on a new socket before the Pooler saw the cut)
        FakeUpstream.strict_sequence([
          native_request(FakeUpstream.websocket_text_frames(opening_frames())),
          native_request(FakeUpstream.barrier_websocket_frames(held_continuation_frames(), notify: self(), release_ref: release_ref)),
          native_request(FakeUpstream.websocket_text_frames([completed_frame("resp_edge_successor", [])]))
        ])
      )

    setup = gateway_setup(upstream)
    model = setup.model.exposed_model_id
    user = synthetic_user_item("edge question")
    port = start_public_endpoint!()

    {conn_a, ws_a, ref_a} = open_continuation!(port, setup, model, user)

    # The provider accepted the continuation and sent only `response.created`
    # (lifecycle, never visible) before it holds.
    assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^release_ref}, @detection_timeout_ms
    assert :ok = FakeUpstream.release_frame(upstream, release_ref)
    assert_receive {:fake_upstream_frame_barrier, 1, _handler, ^release_ref}, @detection_timeout_ms
    {_conn_a, _ws_a, ["response.created"]} = receive_types!(conn_a, ws_a, ref_a, 1)
    assert [_opening, %Request{id: predecessor_id, status: "in_progress"}] = request_logs(setup.pool.id)
    assert is_nil(Repo.get_by!(CodexTurn, request_id: predecessor_id).first_visible_output_at)

    # The new socket's upgrade and resend beat the old socket's close.
    {conn_b, ws_b, ref_b} = connect!(port, setup)
    owner = owner_pid(setup)
    inherited_after_attach? = inherited?(:sys.get_state(owner))
    resend = turn_payload(model, "turn-edge", [user, function_call_item(), tool_output_item()])
    {conn_b, ws_b} = public_websocket_send_text!(conn_b, ws_b, ref_b, encode(resend))
    {conn_b, ws_b, first} = receive_until_terminal!(conn_b, ws_b, ref_b)
    _closed = Mint.HTTP.close(conn_b)
    _ws_b = ws_b

    # The old socket's close arms the pre-visible replay; the client's retry on
    # the next socket redeems it.
    cleanup_probe = attach_cleanup_probe!()
    _closed = Mint.HTTP.close(conn_a)
    assert_receive {^cleanup_probe, :cleanup_finished}, @detection_timeout_ms
    await_suspended_replay!(owner)
    {conn_c, ws_c, ref_c} = connect!(port, setup)
    {conn_c, ws_c} = public_websocket_send_text!(conn_c, ws_c, ref_c, encode(resend))
    {conn_c, _ws_c, retry} = receive_until_terminal!(conn_c, ws_c, ref_c)
    _closed = Mint.HTTP.close(conn_c)
    _released = FakeUpstream.release_remaining_frames(upstream, release_ref)

    %{
      inherited_after_attach?: inherited_after_attach?,
      first_answer: answer_summary(List.last(first)),
      suspended_replay_after_close?: true,
      retry_answer: answer_summary(List.last(retry)),
      requests: settled_requests!(setup.pool.id),
      upstream_count: FakeUpstream.count(upstream)
    }
  end

  # The first socket runs the opening request (a function call) and then sends
  # the anchored tool continuation.
  defp open_continuation!(port, setup, model, user) do
    {conn, ws, ref} = connect!(port, setup)
    {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(turn_payload(model, "turn-edge", [user])))
    {conn, ws, opening} = receive_until_terminal!(conn, ws, ref)
    assert List.last(opening)["type"] == "response.completed"
    continuation = model |> turn_payload("turn-edge", [tool_output_item()]) |> Map.put("previous_response_id", "resp_edge_opening")
    {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(continuation))
    {conn, ws, ref}
  end

  defp stream_until_visible!(upstream, release_ref, conn, ws, ref) do
    for ordinal <- [0, 1, 2] do
      assert_receive {:fake_upstream_frame_barrier, ^ordinal, _handler, ^release_ref}, @detection_timeout_ms
      assert :ok = FakeUpstream.release_frame(upstream, release_ref)
    end

    assert_receive {:fake_upstream_frame_barrier, 3, _handler, ^release_ref}, @detection_timeout_ms
    {_conn, _ws, visible} = receive_types!(conn, ws, ref, 3)
    assert visible == ["response.created", "response.output_item.added", "response.output_text.delta"]
  end

  defp answer_summary(%{"type" => "error"} = frame), do: {"error", frame["status"], get_in(frame, ["error", "code"])}
  defp answer_summary(%{"type" => type} = frame), do: {type, get_in(frame, ["response", "id"])}

  # Waits (bounded) for every request to leave `accepted`/`in_progress`; the
  # tests assert the statuses, so a request left behind shows up there.
  defp settled_requests!(pool_id) do
    deadline_ms = System.monotonic_time(:millisecond) + @detection_timeout_ms

    for request <- request_logs(pool_id) do
      _status = await_request_settled(request.id, deadline_ms)
      Repo.get!(Request, request.id)
    end
  end

  # Every socket of this test closes only after its turn ended, so the first
  # cleanup the probe sees after the first socket's close is that socket's.
  defp attach_cleanup_probe! do
    test_pid = self()
    probe = make_ref()
    handler = "inherited-turn-edges-cleanup-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :gateway, :websocket_control, :cleanup_finished],
        fn _event, _measurements, _metadata, _config -> send(test_pid, {probe, :cleanup_finished}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    probe
  end

  defp owner_pid(setup) do
    [session_id] = Repo.all(from(session in CodexSession, where: session.pool_id == ^setup.pool.id, select: session.id))
    assert {:ok, owner} = WebsocketOwnerSession.lookup(session_id)
    owner
  end

  defp inherited?(%{downstream: %{pid: pid, active_turn_reconnect?: true}, active_turn: %{downstream: %{pid: pid}}}), do: true
  defp inherited?(_state), do: false

  defp await_suspended_replay!(owner) do
    deadline_ms = System.monotonic_time(:millisecond) + @detection_timeout_ms

    Stream.repeatedly(fn -> :sys.get_state(owner) end)
    |> Enum.find(fn state -> suspended?(state) or System.monotonic_time(:millisecond) >= deadline_ms or (Process.sleep(5) && false) end)
    |> then(&assert(suspended?(&1), "the old socket's close never armed the pre-visible replay"))
  end

  defp suspended?(%{active_turn: nil, suspended_replay: %{provisional_status: :armed}}), do: true
  defp suspended?(_state), do: false

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
    do: %{"type" => "function_call", "id" => "fc_inherited_edge", "call_id" => @call_id, "name" => "shell", "arguments" => "{}", "status" => "completed"}

  defp tool_output_item, do: %{"type" => "function_call_output", "call_id" => @call_id, "output" => "synthetic tool output"}

  defp opening_frames do
    [
      encode(%{"type" => "response.created", "response" => %{"id" => "resp_edge_opening", "status" => "in_progress", "output" => []}}),
      encode(%{"type" => "response.output_item.added", "output_index" => 0, "item" => function_call_item()}),
      encode(%{"type" => "response.output_item.done", "output_index" => 0, "item" => function_call_item()}),
      completed_frame("resp_edge_opening", [function_call_item()])
    ]
  end

  defp held_continuation_frames do
    message = %{"type" => "message", "id" => "msg_inherited_edge", "role" => "assistant", "status" => "in_progress", "content" => []}

    [
      encode(%{"type" => "response.created", "response" => %{"id" => "resp_edge_predecessor", "status" => "in_progress", "output" => []}}),
      encode(%{"type" => "response.output_item.added", "output_index" => 0, "item" => message}),
      encode(%{"type" => "response.output_text.delta", "output_index" => 0, "content_index" => 0, "item_id" => "msg_inherited_edge", "delta" => "synthetic visible"}),
      completed_frame("resp_edge_predecessor", [])
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
