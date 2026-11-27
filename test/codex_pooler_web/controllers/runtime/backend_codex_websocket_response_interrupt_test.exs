defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketResponseInterruptTest do
  # The released Codex client (0.159.0) stops a running turn served under Lite
  # by sending `{"type": "response.interrupt", "response_id": ..., "mode":
  # "discard_partial_items"}` on the websocket that carries the turn
  # (findings#270 row 270-272). The provider answers on that connection only:
  # `response.interrupt.accepted`, `response.output_item.interrupted` for an
  # item it had open, then the terminal `response.incomplete` with reason
  # `interrupted` and the usage generated so far; the client reads that terminal
  # as a turn ended without end-of-turn and sends its follow-up anchored on the
  # interrupted response. The Pooler refused the frame `400 invalid_request`
  # ("websocket message type is not supported"), which the client does not
  # retry, and refused the anchored follow-up `409 duplicate_turn`.
  #
  # Frames: the shape of the released client's frames and of the provider's
  # answers to a live interrupt (probe against the provider's websocket: an
  # early interrupt, right after `response.created`, is answered with no
  # `output_item.interrupted`; a late one, after the terminal, with a
  # non-terminal `response.interrupt.failed`), with synthetic text and ids.
  #
  # Topology: the real public listener, native websocket, one node with owner
  # forwarding off (the socket's own upstream session) and on (the session's
  # owner on this node), the Pool's serving mode forced to Full and to Lite
  # (the provider accepts the interrupt in both); FakeUpstream answers an
  # interrupt the way the provider does.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport,
    only: [enter_peer_owner_topology!: 0, start_peer_window_owner!: 2]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  @moduletag capture_log: true

  # Detection budget for a frame, a settlement or a row the test only observes.
  @detection_timeout_ms 15_000
  # How long a dropped interrupt is watched for an answer that must not come.
  @silence_ms 300

  @turn_path "/backend-api/codex/responses"
  @native_terminal_types ["response.completed", "response.failed", "response.incomplete", "error"]
  @installation_id "00000000-0000-4000-8000-000000000272"
  @interrupt_mode "discard_partial_items"

  @tag :interrupted_mailbox
  test "a mailbox increment colliding with an old steer requests full history, and a websocket rebuild dispatches once" do
    put_owner_forwarding!(false)
    final_id = "resp_mailbox_completed"
    gate = make_ref()
    frames = completed_events(final_id)
    reply = FakeUpstream.barrier_websocket_frames(frames, notify: self(), release_ref: gate)
    ctx = interrupted_mailbox_setup!([FakeUpstream.expect_request(method: "WEBSOCKET", path: @turn_path, respond: reply)])
    assert_mailbox_rebuild_requested!(ctx)

    # Codex opens a new socket and resends the full history, including the
    # earlier tool call. Its HTTP fallback must still meet this active claim.
    rebuilt = frame(ctx.turn, "turn", ctx.rebuilt, %{})
    client = ctx.port |> connect!(ctx.setup, ctx.turn) |> send_frame!(rebuilt)
    assert_receive {:fake_upstream_frame_barrier, 0, handler, ^gate}, @detection_timeout_ms

    try do
      assert %{"error" => %{"code" => "duplicate_turn"}} = json_response(mailbox_http_rebuild(ctx), 409)
      assert length(pool_requests(ctx.setup)) == 4
    after
      assert :ok = FakeUpstream.release_remaining_frames(ctx.upstream, gate)
    end

    {client, events} = receive_turn!(client)
    assert %{"type" => "response.completed", "response" => %{"id" => ^final_id}} = List.last(events)
    last_barrier = length(frames)
    assert_receive {:fake_upstream_frame_barrier, ^last_barrier, ^handler, ^gate}, @detection_timeout_ms
    await_no_response_task!(client)
    assert_mailbox_rebuild_settled!(ctx)
    drop!(client)
  end

  @tag :interrupted_mailbox
  test "a Lite mailbox increment through its session owner requests full history and accepts the HTTP rebuild" do
    put_owner_forwarding!(true)
    final_id = "resp_mailbox_http_completed"
    terminal = completed_events(final_id) |> List.last() |> CodexPooler.JSON.decode!()
    reply = FakeUpstream.sse_stream([{"response.completed", terminal}])
    ctx = interrupted_mailbox_setup!([FakeUpstream.expect_request(method: "POST", path: @turn_path, respond: reply)], "lite")
    assert_mailbox_rebuild_requested!(ctx)
    response = mailbox_http_rebuild(ctx)
    assert response.status == 200
    assert response.resp_body =~ final_id
    assert_mailbox_rebuild_settled!(ctx)
  end

  @tag :interrupted_mailbox
  test "mail directed to a different agent cannot change a duplicate turn into a full-history retry" do
    put_owner_forwarding!(false)
    ctx = interrupted_mailbox_setup!([])
    mail = Map.put(ctx.mail, "recipient", "/root/other")
    anchored = frame(ctx.turn, "turn", [mail], %{"previous_response_id" => ctx.interrupted_id})
    {client, events} = send_turn!(ctx.client, anchored)
    assert %{"type" => "error", "status" => 409, "error" => %{"code" => "duplicate_turn"}} = List.last(events)

    # Replaying the actual previously served steer on its old anchor stays
    # a duplicate even though the last request on this socket was interrupted.
    {client, replay} = send_turn!(client, follow_up_frame(ctx.turn, "resp_before_steer"))
    assert %{"type" => "error", "status" => 409, "error" => %{"code" => "duplicate_turn"}} = List.last(replay)
    assert [opening, steer, interrupted] = pool_requests(ctx.setup)
    turn = Repo.get_by!(CodexTurn, request_id: interrupted.id)

    # The durable collision check must reject both the producer itself and
    # an old pair after a later request of this semantic turn was recorded.
    refute CodexPooler.Accounting.older_settled_steer?(turn.codex_session_id, turn.semantic_turn_digest, interrupted.correlation_id, interrupted.correlation_id)
    refute CodexPooler.Accounting.older_settled_steer?(turn.codex_session_id, turn.semantic_turn_digest, opening.correlation_id, steer.correlation_id)
    assert :ok = FakeUpstream.verify!(ctx.upstream)
    drop!(client)
  end

  for forwarding <- [:off, :on], mode <- ["full", "lite"], moment <- [:mid, :early] do
    @tag forwarding: forwarding, serving_mode: mode, moment: moment
    test "a #{mode} turn interrupted #{moment} with owner forwarding #{forwarding} ends interrupted, and its anchored follow-up is served", ctx do
      put_owner_forwarding!(ctx.forwarding == :on)
      hold = make_ref()
      response_id = "resp_interrupt_#{ctx.moment}_#{System.unique_integer([:positive])}"

      upstream =
        start_upstream(
          # provenance: observed provider websocket answers to a live `response.interrupt` (probe, gpt-6-luna, Full and Lite, early and mid); ids and text synthetic
          FakeUpstream.strict_sequence([
            turn_request(interruptible(response_id, ctx.moment, hold)),
            turn_request(FakeUpstream.websocket_text_frames(completed_events("resp_after_interrupt")))
          ])
        )

      setup = gateway_setup(upstream)
      set_model_serving_mode!(model_serving_scope(), setup, ctx.serving_mode)
      assert :ok = CodexPooler.Events.subscribe_pool(setup.pool)
      {_server, port} = start_public_endpoint_with_server!()
      turn = new_turn(setup, ctx.serving_mode)

      client = port |> connect!(setup, turn) |> prewarm!(turn) |> send_frame!(opener_frame(turn))
      assert_receive {:fake_upstream_interruptible_open, _handler, ^hold}, @detection_timeout_ms
      {client, opening} = receive_n!(client, length(opening_events(response_id, ctx.moment)))
      assert Enum.map(opening, & &1["type"]) == Enum.map(opening_events(response_id, ctx.moment), &CodexPooler.JSON.decode!(&1)["type"])

      # The interrupt reaches the provider on the turn's connection, exactly as
      # the client sent it, and the provider's answer reaches the client.
      {{client, interrupted}, log} = with_info_log(fn -> client |> send_frame!(interrupt_frame(response_id)) |> receive_turn!() end)
      assert_receive {:fake_upstream_interrupted, _handler, ^hold}, @detection_timeout_ms
      assert Enum.map(interrupted, &CodexPooler.JSON.encode!/1) == interrupted_events(response_id, ctx.moment)
      assert %{"type" => "response.incomplete", "response" => %{"id" => ^response_id, "incomplete_details" => %{"reason" => "interrupted"}}} = List.last(interrupted)
      assert [%{websocket_connection_id: 1, json: %{"type" => "response.interrupt", "response_id" => ^response_id, "mode" => @interrupt_mode} = sent}] = FakeUpstream.websocket_interrupts(upstream)
      assert map_size(sent) == 3
      assert log =~ "native websocket response interrupt outcome=written topology=#{topology(ctx.forwarding)}"
      assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms

      # The follow-up anchored on the interrupted response is a later request
      # of the turn, served on the same connection.
      {client, follow_up} = send_turn!(client, follow_up_frame(turn, response_id))
      assert %{"type" => "response.completed", "response" => %{"id" => "resp_after_interrupt"}} = List.last(follow_up)
      assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms

      assert [_interrupted_request, follow_up_request] = FakeUpstream.requests(upstream)
      assert follow_up_request.websocket_connection_id == 1
      assert follow_up_request.json["previous_response_id"] == response_id

      # The interrupted request is a served request billed for what it
      # generated; the follow-up took the claim of a later request of its turn.
      assert [interrupted_row, follow_up_row] = pool_requests(setup)
      assert {interrupted_row.status, interrupted_row.usage_status, follow_up_row.status} == {"succeeded", "usage_known", "succeeded"}
      assert "codex-turn:" <> _turn_claim = interrupted_row.correlation_id
      assert "codex-resume:" <> _later_request_claim = follow_up_row.correlation_id
      assert %{"terminal_class" => "response.incomplete", "incomplete_reason" => "interrupted"} = await_downstream_delivery!(interrupted_row)
      assert :ok = FakeUpstream.verify!(upstream)

      drop!(client)
    end
  end

  # The session's owner and the turn's upstream connection live on a second
  # VM: the interrupt reaches them through the owner's versioned remote entry
  # point (`remote_interrupt_turn_v1`), and the answer comes back through the
  # turn's relay.
  @tag slow: "boots a second VM that owns the session and shares the committed database"
  test "with the session's owner on another node, the interrupt reaches the provider through it and the follow-up is served" do
    put_owner_forwarding!(true)
    enter_peer_owner_topology!()
    hold = make_ref()
    response_id = "resp_interrupt_peer_#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        # provenance: observed provider websocket answers to a live `response.interrupt` (probe, gpt-6-luna, mid); ids and text synthetic
        FakeUpstream.strict_sequence([
          turn_request(interruptible(response_id, :mid, hold)),
          turn_request(FakeUpstream.websocket_text_frames(completed_events("resp_after_peer_interrupt")))
        ])
      )

    setup = gateway_setup(upstream)
    assert :ok = CodexPooler.Events.subscribe_pool(setup.pool)
    turn = new_turn(setup, "full")
    peer_owner = start_peer_window_owner!(setup, "#{turn.thread}:0")
    assert node(peer_owner.owner_pid) != node()
    {_server, port} = start_public_endpoint_with_server!()

    client = port |> connect!(setup, turn) |> prewarm!(turn) |> send_frame!(opener_frame(turn))
    assert_receive {:fake_upstream_interruptible_open, _handler, ^hold}, @detection_timeout_ms
    {client, _opening} = receive_n!(client, length(opening_events(response_id, :mid)))

    {{client, interrupted}, log} = with_info_log(fn -> client |> send_frame!(interrupt_frame(response_id)) |> receive_turn!() end)
    assert Enum.map(interrupted, &CodexPooler.JSON.encode!/1) == interrupted_events(response_id, :mid)
    assert [%{websocket_connection_id: 1, json: %{"response_id" => ^response_id, "mode" => @interrupt_mode}}] = FakeUpstream.websocket_interrupts(upstream)
    # The owner's upstream session on the peer wrote it; the peer's log
    # reaches this node's capture.
    assert log =~ "native websocket response interrupt outcome=written topology=owner"
    assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms

    {client, follow_up} = send_turn!(client, follow_up_frame(turn, response_id))
    assert %{"type" => "response.completed", "response" => %{"id" => "resp_after_peer_interrupt"}} = List.last(follow_up)
    assert [_interrupted_request, %{websocket_connection_id: 1, json: %{"previous_response_id" => ^response_id}}] = FakeUpstream.requests(upstream)
    assert :ok = FakeUpstream.verify!(upstream)

    drop!(client)
  end

  # The provider built the interrupted response's context under the mode that
  # request was served in, and keeps it for the follow-up. A Lite turn
  # interrupted on a connection whose last completed response was Full leaves a
  # Lite context there: the Lite follow-up anchored on it rides the connection
  # instead of meeting the guard for a Lite anchor on a Full context
  # (`previous_response_not_found`, findings#232 row 232-210).
  test "a lite turn interrupted after a full turn on the same connection keeps its follow-up on that connection" do
    put_owner_forwarding!(false)
    hold = make_ref()
    response_id = "resp_interrupt_after_full_#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        # provenance: observed provider websocket answers to a live `response.interrupt` (probe, gpt-6-luna, Lite, mid); the Pool's serving mode switched between the two turns; ids and text synthetic
        FakeUpstream.strict_sequence([
          turn_request(FakeUpstream.websocket_text_frames(completed_events("resp_full_before_interrupt"))),
          turn_request(interruptible(response_id, :mid, hold)),
          turn_request(FakeUpstream.websocket_text_frames(completed_events("resp_lite_after_interrupt")))
        ])
      )

    setup = gateway_setup(upstream)
    set_model_serving_mode!(model_serving_scope(), setup, "full")
    assert :ok = CodexPooler.Events.subscribe_pool(setup.pool)
    {_server, port} = start_public_endpoint_with_server!()
    full_turn = new_turn(setup, "full")

    client = port |> connect!(setup, full_turn) |> prewarm!(full_turn)
    {client, first} = send_turn!(client, opener_frame(full_turn))
    assert %{"type" => "response.completed"} = List.last(first)
    assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms

    set_model_serving_mode!(model_serving_scope(), setup, "lite")
    lite_turn = %{new_turn(setup, "lite") | thread: full_turn.thread}
    client = send_frame!(client, opener_frame(lite_turn))
    assert_receive {:fake_upstream_interruptible_open, _handler, ^hold}, @detection_timeout_ms
    {client, _opening} = receive_n!(client, length(opening_events(response_id, :mid)))
    {client, interrupted} = client |> send_frame!(interrupt_frame(response_id)) |> receive_turn!()
    assert %{"type" => "response.incomplete", "response" => %{"incomplete_details" => %{"reason" => "interrupted"}}} = List.last(interrupted)
    assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms

    {client, follow_up} = send_turn!(client, follow_up_frame(lite_turn, response_id))
    assert %{"type" => "response.completed", "response" => %{"id" => "resp_lite_after_interrupt"}} = List.last(follow_up)
    assert [_full, _interrupted, %{websocket_connection_id: 1, json: %{"previous_response_id" => ^response_id}}] = FakeUpstream.requests(upstream)
    assert :ok = FakeUpstream.verify!(upstream)

    drop!(client)
  end

  # An interrupt the provider cannot apply is dropped without an answer: one
  # naming another response than the running one, a malformed one, one sent
  # after the response ended. An error frame would end the client's turn; the
  # provider itself answers an interrupt it cannot apply with a non-terminal
  # `response.interrupt.failed` the client ignores. Each leaves one line.
  for forwarding <- [:off, :on], shape <- [:other_response, :malformed] do
    @tag forwarding: forwarding, shape: shape
    test "an interrupt (#{shape}) with owner forwarding #{forwarding} is dropped with its line, and the turn runs to its end", ctx do
      put_owner_forwarding!(ctx.forwarding == :on)
      hold = make_ref()
      response_id = "resp_uninterrupted_#{System.unique_integer([:positive])}"
      # provenance: synthetic_adversarial (an interrupt naming another response, or missing its mode, which the released client never sends)
      upstream = start_upstream(FakeUpstream.strict_sequence([turn_request(interruptible(response_id, :mid, hold))]))
      setup = gateway_setup(upstream)
      assert :ok = CodexPooler.Events.subscribe_pool(setup.pool)
      {_server, port} = start_public_endpoint_with_server!()
      turn = new_turn(setup, "full")

      client = port |> connect!(setup, turn) |> prewarm!(turn) |> send_frame!(opener_frame(turn))
      assert_receive {:fake_upstream_interruptible_open, _handler, ^hold}, @detection_timeout_ms
      {client, _opening} = receive_n!(client, length(opening_events(response_id, :mid)))

      {client, log} = with_info_log(fn -> client |> send_frame!(dropped_interrupt_frame(ctx.shape, response_id)) |> assert_silent!() end)
      assert log =~ "native websocket response interrupt outcome=#{dropped_outcome(ctx.shape)} topology=#{topology(ctx.forwarding)}"
      assert FakeUpstream.websocket_interrupts(upstream) == []

      :ok = FakeUpstream.release_interruptible(upstream, hold)
      {client, rest} = receive_turn!(client)
      assert %{"type" => "response.completed", "response" => %{"id" => ^response_id}} = List.last(rest)
      assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms

      assert [row] = pool_requests(setup)
      assert %{"terminal_class" => "response.completed"} = delivery = await_downstream_delivery!(row)
      refute Map.has_key?(delivery, "incomplete_reason")
      assert :ok = FakeUpstream.verify!(upstream)

      drop!(client)
    end
  end

  # The client interrupts a response the provider completed a moment before
  # (the race the provider answers `response.interrupt.failed`). Nothing of it
  # reaches the provider or the client, and the next request is served.
  for forwarding <- [:off, :on] do
    @tag forwarding: forwarding
    test "an interrupt of a response that already completed with owner forwarding #{forwarding} is dropped, and the next request is served", ctx do
      put_owner_forwarding!(ctx.forwarding == :on)
      hold = make_ref()
      response_id = "resp_completed_first_#{System.unique_integer([:positive])}"

      upstream =
        start_upstream(
          # provenance: observed provider answer to a late interrupt (probe: `response.interrupt.failed`, not a terminal); the Pooler never sends it; ids and text synthetic
          FakeUpstream.strict_sequence([
            turn_request(interruptible(response_id, :mid, hold)),
            turn_request(FakeUpstream.websocket_text_frames(completed_events("resp_after_late_interrupt")))
          ])
        )

      setup = gateway_setup(upstream)
      assert :ok = CodexPooler.Events.subscribe_pool(setup.pool)
      {_server, port} = start_public_endpoint_with_server!()
      turn = new_turn(setup, "full")

      client = port |> connect!(setup, turn) |> prewarm!(turn) |> send_frame!(opener_frame(turn))
      assert_receive {:fake_upstream_interruptible_open, _handler, ^hold}, @detection_timeout_ms
      :ok = FakeUpstream.release_interruptible(upstream, hold)
      {client, completed} = receive_turn!(client)
      assert %{"type" => "response.completed", "response" => %{"id" => ^response_id}} = List.last(completed)
      assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
      :ok = await_no_response_task!(client)

      {client, log} = with_info_log(fn -> client |> send_frame!(interrupt_frame(response_id)) |> assert_silent!() end)
      assert log =~ "native websocket response interrupt outcome=no_running_turn topology=#{topology(ctx.forwarding)}"
      assert FakeUpstream.websocket_interrupts(upstream) == []

      {client, next} = send_turn!(client, follow_up_frame(turn, response_id))
      assert %{"type" => "response.completed", "response" => %{"id" => "resp_after_late_interrupt"}} = List.last(next)
      assert_receive {CodexPooler.Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}}, @detection_timeout_ms
      assert :ok = FakeUpstream.verify!(upstream)

      drop!(client)
    end
  end

  defp dropped_interrupt_frame(:other_response, _response_id), do: interrupt_frame("resp_not_the_running_one")
  defp dropped_interrupt_frame(:malformed, response_id), do: CodexPooler.JSON.encode!(%{"type" => "response.interrupt", "response_id" => response_id})

  defp dropped_outcome(:other_response), do: "response_mismatch"
  defp dropped_outcome(:malformed), do: "malformed"

  # Nothing reaches the client for a while: no error frame, no event.
  defp assert_silent!(client) do
    socket = Mint.HTTP.get_socket(client.conn)

    receive do
      {tag, ^socket, data} when tag in [:tcp, :ssl] -> flunk("the client received #{byte_size(data)} bytes after a dropped interrupt")
    after
      @silence_ms -> client
    end
  end

  # The socket's response task for the settled turn has gone, so an interrupt
  # now finds no running turn on either path.
  defp await_no_response_task!(client, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @detection_timeout_ms

    cond do
      MapSet.size(Map.get(socket_connection_state!(client.socket), :tasks, MapSet.new())) == 0 -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("the socket kept a response task after its turn settled")
      true -> Process.sleep(10) && await_no_response_task!(client, deadline)
    end
  end

  defp topology(:off), do: "direct"
  defp topology(:on), do: "owner"

  defp assert_mailbox_rebuild_requested!(ctx) do
    anchored = frame(ctx.turn, "turn", [ctx.mail], %{"previous_response_id" => ctx.interrupted_id})
    {client, events} = send_turn!(ctx.client, anchored)
    assert %{"type" => "error", "status" => 400, "error" => %{"code" => "previous_response_not_found", "message" => advice}} = List.last(events)
    assert advice =~ "full input"
    assert length(FakeUpstream.requests(ctx.upstream)) == 3
    assert length(pool_requests(ctx.setup)) == 3
    drop!(client)
  end

  defp mailbox_http_rebuild(ctx) do
    body = ctx.turn |> frame("turn", ctx.rebuilt, %{}) |> CodexPooler.JSON.decode!() |> Map.delete("type")

    build_conn()
    |> auth(ctx.setup)
    |> put_req_header("accept", "text/event-stream")
    |> put_req_header("session-id", ctx.turn.thread)
    |> put_req_header("thread-id", ctx.turn.thread)
    |> put_req_header("originator", "codex_exec")
    |> put_req_header("x-codex-window-id", "#{ctx.turn.thread}:0")
    |> put_req_header("x-codex-turn-metadata", body["client_metadata"]["x-codex-turn-metadata"])
    |> then(&if(ctx.turn.mode == "lite", do: put_req_header(&1, "x-openai-internal-codex-responses-lite", "true"), else: &1))
    |> post(@turn_path, body)
  end

  defp assert_mailbox_rebuild_settled!(ctx) do
    assert [_, _, _, recovery] = pool_requests(ctx.setup)
    assert recovery.status == "succeeded"
    assert Repo.get_by!(Attempt, request_id: recovery.id).status == "succeeded"
    assert "codex-request:" <> _ = recovery.correlation_id
    assert [_, _, _, sent] = FakeUpstream.requests(ctx.upstream)
    refute Map.has_key?(sent.json, "previous_response_id")
    assert List.last(sent.json["input"]) == ctx.mail
    assert :ok = FakeUpstream.verify!(ctx.upstream)
  end

  # A user steer already owns the claim for this user-message count. Its
  # result is a tool call, so the interrupted request and the full history
  # reconstructed after it both contain a tool result.
  defp interrupted_mailbox_setup!(recoveries, mode \\ "full") do
    hold = make_ref()
    first_id = "resp_before_steer"
    steered_id = "resp_steered_tool_call"
    interrupted_id = "resp_interrupted_after_tool"
    call = %{"type" => "function_call", "id" => "fc_mailbox", "call_id" => "call_mailbox", "name" => "exec_command", "arguments" => "{}", "status" => "completed"}
    result = %{"type" => "function_call_output", "call_id" => call["call_id"], "output" => "synthetic result"}
    reasoning = %{"type" => "reasoning", "id" => "rs_mailbox", "summary" => []}
    mail = %{"type" => "agent_message", "author" => "/root/worker", "recipient" => "/root", "content" => [%{"type" => "input_text", "text" => "synthetic update"}]}

    call_frames =
      encode([
        created(steered_id),
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => call},
        %{"type" => "response.completed", "response" => %{"id" => steered_id, "output" => [call], "status" => "completed", "usage" => %{"input_tokens" => 15, "output_tokens" => 5, "total_tokens" => 20}}}
      ])

    opening = encode([created(interrupted_id), %{"type" => "response.output_item.done", "output_index" => 0, "item" => reasoning}])
    on_interrupt = FakeUpstream.interruptible_websocket_frames(opening, response_id: interrupted_id, interrupted: interrupted_events(interrupted_id, :early), completion: completion_events(interrupted_id), notify: self(), release_ref: hold)

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence(
          [
            turn_request(FakeUpstream.websocket_text_frames(completed_events(first_id))),
            turn_request(FakeUpstream.websocket_text_frames(call_frames)),
            turn_request(on_interrupt)
          ] ++ recoveries
        )
      )

    setup = gateway_setup(upstream)
    set_model_serving_mode!(model_serving_scope(), setup, mode)
    {_server, port} = start_public_endpoint_with_server!()
    turn = setup |> new_turn(mode) |> Map.put(:agent_name, "/root")

    client = port |> connect!(setup, turn) |> prewarm!(turn)
    {client, opening} = send_turn!(client, opener_frame(turn))
    assert %{"type" => "response.completed", "response" => %{"id" => ^first_id, "output" => [answer]}} = List.last(opening)
    steer = user_message("synthetic steered input")
    {client, steered} = send_turn!(client, frame(turn, "turn", [steer], %{"previous_response_id" => first_id}))
    assert %{"type" => "response.completed", "response" => %{"id" => ^steered_id, "output" => [^call]}} = List.last(steered)
    client = send_frame!(client, frame(turn, "turn", [result], %{"previous_response_id" => steered_id}))
    assert_receive {:fake_upstream_interruptible_open, _handler, ^hold}, @detection_timeout_ms
    {client, _opening} = receive_n!(client, 2)
    {client, interrupted} = client |> send_frame!(interrupt_frame(interrupted_id)) |> receive_turn!()
    assert %{"type" => "response.incomplete", "response" => %{"id" => ^interrupted_id, "incomplete_details" => %{"reason" => "interrupted"}}} = List.last(interrupted)
    await_no_response_task!(client)
    assert [opener, steer_request, tool_request] = pool_requests(setup)
    assert "codex-turn:" <> _ = opener.correlation_id
    assert "codex-resume:" <> _ = steer_request.correlation_id
    assert "codex-request:" <> _ = tool_request.correlation_id
    assert %{"terminal_class" => "response.incomplete", "incomplete_reason" => "interrupted"} = await_downstream_delivery!(tool_request)

    %{client: client, port: port, setup: setup, upstream: upstream, turn: turn, mail: mail, interrupted_id: interrupted_id, rebuilt: history(turn) ++ [answer, steer, call, result, reasoning, mail]}
  end

  # The provider's interruptible response: what it sends before the client
  # interrupts, its answer to the interrupt, and the rest had nobody
  # interrupted it.
  defp interruptible(response_id, moment, hold) do
    FakeUpstream.interruptible_websocket_frames(opening_events(response_id, moment),
      response_id: response_id,
      interrupted: interrupted_events(response_id, moment),
      completion: completion_events(response_id),
      notify: self(),
      release_ref: hold
    )
  end

  defp opening_events(response_id, :early), do: encode([created(response_id)])

  defp opening_events(response_id, :mid) do
    encode([
      created(response_id),
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => %{"type" => "message", "id" => "msg_#{response_id}", "role" => "assistant", "status" => "in_progress", "content" => []}},
      %{"type" => "response.output_text.delta", "item_id" => "msg_#{response_id}", "output_index" => 0, "content_index" => 0, "delta" => "synthetic partial answer"}
    ])
  end

  defp interrupted_events(response_id, moment) do
    item_interrupted = %{"type" => "response.output_item.interrupted", "item_id" => "msg_#{response_id}", "output_index" => 0, "response_id" => response_id, "sequence_number" => 16}

    encode(
      [%{"type" => "response.interrupt.accepted", "response_id" => response_id, "sequence_number" => 15}] ++
        if(moment == :mid, do: [item_interrupted], else: []) ++
        [
          %{
            "type" => "response.incomplete",
            "response" => %{
              "id" => response_id,
              "status" => "incomplete",
              "incomplete_details" => %{"reason" => "interrupted"},
              "output" => [],
              "usage" => %{"input_tokens" => 41, "output_tokens" => 51, "total_tokens" => 92, "output_tokens_details" => %{"reasoning_tokens" => 37}}
            }
          }
        ]
    )
  end

  defp completion_events(response_id) do
    item = %{"type" => "message", "id" => "msg_#{response_id}", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}

    encode([
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 41, "output_tokens" => 60, "total_tokens" => 101}}}
    ])
  end

  defp completed_events(response_id) do
    item = %{"type" => "message", "id" => "msg_#{response_id}", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "synthetic follow-up answer"}]}

    encode([
      created(response_id),
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 91, "output_tokens" => 5, "total_tokens" => 96}}}
    ])
  end

  defp created(response_id), do: %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}}

  defp encode(events), do: Enum.map(events, &CodexPooler.JSON.encode!/1)

  defp turn_request(respond) do
    FakeUpstream.expect_request(method: "WEBSOCKET", path: @turn_path, websocket_connection_ordinal: 1, json: [valid: true, equals: %{"type" => "response.create"}], respond: respond)
  end

  defp interrupt_frame(response_id), do: CodexPooler.JSON.encode!(%{"type" => "response.interrupt", "response_id" => response_id, "mode" => @interrupt_mode})

  # The released client's identity of one turn: its thread, the turn id, and
  # the serving mode the Pool's catalog told it (Lite marks every frame).
  defp new_turn(setup, mode) do
    %{
      model: setup.model.exposed_model_id,
      thread: Ecto.UUID.generate(),
      turn_id: Ecto.UUID.generate(),
      context: Ecto.UUID.generate(),
      mode: mode,
      started_at: System.system_time(:millisecond)
    }
  end

  defp connect!(port, setup, turn) do
    before = WebsocketCleanupFence.listener_sockets()

    headers = [
      {"session-id", turn.thread},
      {"thread-id", turn.thread},
      {"x-client-request-id", turn.thread},
      {"x-codex-window-id", "#{turn.thread}:0"},
      {"x-codex-turn-metadata", CodexPooler.JSON.encode!(turn_metadata(turn, "prewarm", ""))},
      {"openai-beta", "responses_websockets=2026-02-06"},
      {"originator", "codex_exec"}
    ]

    {conn, websocket, ref, _response_headers} = public_websocket_connect_with_request_headers!(port, setup, turn.thread, @turn_path, headers)
    socket = WebsocketCleanupFence.await_new_listener_socket!(before)
    %{conn: conn, websocket: websocket, ref: ref, socket: socket}
  end

  defp drop!(client) do
    Mint.HTTP.close(client.conn)
    :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
  end

  # The Pooler answers the prewarm itself with an empty response id, after
  # which the released client sends the turn's opener whole (`client.rs`
  # `prepare_websocket_request`).
  defp prewarm!(client, turn) do
    {client, events} = send_turn!(client, frame(turn, "prewarm", [developer_message("synthetic developer instructions"), user_message("synthetic environment context")], %{"generate" => false}))
    assert %{"type" => "response.completed", "response" => %{"id" => ""}} = List.last(events)
    client
  end

  defp opener_frame(turn), do: frame(turn, "turn", history(turn), %{})

  # The released client's next request after an interrupted response: the
  # user input it interrupted the response for, anchored on that response.
  defp follow_up_frame(turn, response_id), do: frame(turn, "turn", [user_message("synthetic steered input")], %{"previous_response_id" => response_id})

  defp history(turn) do
    [developer_message("synthetic developer instructions"), user_message("synthetic environment context"), user_message("interrupt sample: answer at length")]
    |> then(&if(turn.mode == "lite", do: [additional_tools() | &1], else: &1))
  end

  defp frame(turn, request_kind, input, extra) do
    base = %{
      "type" => "response.create",
      "model" => turn.model,
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "reasoning" => %{"effort" => "low"},
      "store" => false,
      "stream" => true,
      "include" => ["reasoning.encrypted_content"],
      "prompt_cache_key" => turn.thread,
      "input" => input,
      "client_metadata" => client_metadata(turn, request_kind)
    }

    base =
      case turn.mode do
        "full" -> Map.merge(base, %{"instructions" => "synthetic base instructions", "tools" => [tool()]})
        "lite" -> base |> Map.put("parallel_tool_calls", false) |> put_in(["client_metadata", "ws_request_header_x_openai_internal_codex_responses_lite"], "true")
      end

    base |> Map.merge(extra) |> CodexPooler.JSON.encode!()
  end

  defp client_metadata(turn, request_kind) do
    turn_id = if request_kind == "prewarm", do: "", else: turn.turn_id

    metadata = %{
      "session_id" => turn.thread,
      "thread_id" => turn.thread,
      "turn_id" => turn_id,
      "x-codex-installation-id" => @installation_id,
      "x-codex-window-id" => "#{turn.thread}:0",
      "x-codex-turn-metadata" => CodexPooler.JSON.encode!(turn_metadata(turn, request_kind, turn_id))
    }

    if request_kind == "prewarm", do: metadata, else: Map.put(metadata, "root_turn_id", turn.turn_id)
  end

  defp turn_metadata(turn, request_kind, turn_id) do
    base = %{
      "installation_id" => @installation_id,
      "session_id" => turn.thread,
      "thread_id" => turn.thread,
      "turn_id" => turn_id,
      "window_id" => "#{turn.thread}:0",
      "window_number" => 0,
      "context_window_id" => turn.context,
      "request_kind" => request_kind,
      "thread_source" => "user"
    }

    base = if turn[:agent_name], do: Map.put(base, "agent_name", turn.agent_name), else: base

    case request_kind do
      "prewarm" -> Map.merge(base, %{"model" => turn.model, "reasoning_effort" => "low"})
      "turn" -> Map.merge(base, %{"root_turn_id" => turn.turn_id, "turn_trigger" => "exec", "turn_started_at_unix_ms" => turn.started_at, "model" => turn.model, "reasoning_effort" => "low"})
    end
  end

  defp tool, do: %{"type" => "function", "name" => "exec_command", "description" => "synthetic tool", "strict" => false, "parameters" => %{"type" => "object", "properties" => %{"cmd" => %{"type" => "string"}}, "required" => ["cmd"]}}

  defp additional_tools, do: %{"type" => "additional_tools", "id" => "at_interrupt_sample", "role" => "developer", "tools" => []}

  defp developer_message(text), do: %{"type" => "message", "role" => "developer", "content" => [%{"type" => "input_text", "text" => text}]}
  defp user_message(text), do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}

  defp send_turn!(client, frame), do: client |> send_frame!(frame) |> receive_turn!()

  defp send_frame!(client, frame) do
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame)
    %{client | conn: conn, websocket: websocket}
  end

  defp receive_turn!(client) do
    {client, events} = receive_events!(client, [], &Enum.any?(&1, fn event -> event["type"] in @native_terminal_types end))
    {client, events}
  end

  defp receive_n!(client, count), do: receive_events!(client, [], &(length(&1) >= count))

  # Every JSON event the Pooler sends until `done?` holds, controls excepted.
  defp receive_events!(client, events, done?) do
    if done?.(events) do
      {client, events}
    else
      message = receive_mint_socket_message!(client.conn, @detection_timeout_ms, "timed out waiting for native events")

      case Mint.WebSocket.stream(client.conn, message) do
        {:ok, conn, responses} ->
          {websocket, events} = Enum.reduce(responses, {client.websocket, events}, &decode_response(&1, &2, client.ref))
          receive_events!(%{client | conn: conn, websocket: websocket}, events, done?)

        {:error, _conn, reason, _responses} ->
          flunk("websocket receive failed: #{inspect(reason)}")

        :unknown ->
          receive_events!(client, events, done?)
      end
    end
  end

  defp decode_response({:data, ref, data}, {websocket, events}, ref) do
    assert {:ok, websocket, frames} = Mint.WebSocket.decode(websocket, data)
    {websocket, events ++ for({:text, text} <- frames, event = CodexPooler.JSON.decode!(text), not String.starts_with?(event["type"] || "", "codex."), do: event)}
  end

  defp decode_response(_response, acc, _ref), do: acc

  defp put_owner_forwarding!(enabled?) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled?)
  end

  defp pool_requests(setup),
    do: Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id, order_by: [asc: request.admitted_at]))

  # The socket records its delivery receipt once the turn's task has ended,
  # which can be after the request's finalization event.
  defp await_downstream_delivery!(%Request{id: request_id} = request, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @detection_timeout_ms
    [metadata] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request_id, select: attempt.response_metadata))

    case Map.get(metadata || %{}, "downstream_delivery") do
      %{} = receipt ->
        receipt

      nil ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("no delivery receipt for the request")
        Process.sleep(10)
        await_downstream_delivery!(request, deadline)
    end
  end
end
