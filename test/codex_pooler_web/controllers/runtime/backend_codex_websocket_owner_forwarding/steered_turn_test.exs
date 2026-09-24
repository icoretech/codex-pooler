defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.SteeredTurnTest do
  # The released Codex client lets the user type while a turn runs and drains
  # that input into the SAME turn, under the same `turn_id`, before the turn's
  # next model request (`session/turn.rs` `can_drain_pending_input`,
  # `turn_input.rs` `steer_input` returns the active turn's id). The drain only
  # happens after a sampling request finished, so the steered request follows
  # the previous request's `response.completed`; on the websocket it rides the
  # same connection as an anchored increment (`client.rs`
  # `prepare_websocket_request`: `previous_response_id` of the response just
  # completed, `input` only the items added since, here the user message).
  # Without a tool result in that increment the frame derived the turn's bare
  # `codex-turn:` claim, which the turn's opening request already holds, and
  # was refused `409 duplicate_turn` (findings#206 row 206-409). A frame
  # anchored on a response its own turn produced on this socket is now a later
  # request of that turn, claimed per payload like a tool-result continuation;
  # its identical resend and the opener's own resend stay refused.
  #
  # Topology: the real public listener; owner forwarding on with the session's
  # owner on this node or on a second VM sharing the committed database, and
  # owner forwarding off (the socket's own upstream session); Full and Lite.
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3, with_info_log: 1]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_peer_window_owner!: 2, request_logs: 1]

  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @detection_timeout_ms 15_000
  @thread_id "019a0000-0000-7000-8000-00000000e409"
  @window_id "#{@thread_id}:0"
  @turn_id "turn-steered"

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    :ok
  end

  for {topology, mode} <- [{:local, "full"}, {:local, "lite"}, {:peer, "full"}, {:direct, "full"}, {:direct, "lite"}] do
    @tag topology: topology, serving_mode: mode
    test "a steered anchored increment of the running turn is served once (#{topology} owner, #{mode})", %{topology: topology, serving_mode: mode} do
      {outcome, logs} = with_info_log(fn -> run_scenario(topology, mode, []) end)

      assert outcome.steer_answer == {"response.completed", "resp_steered_successor"}
      assert_served_once_each!(outcome, 2)
      assert outcome.steer_upstream_anchor == "resp_steered_opening"
      refute logs =~ "reason_code=duplicate"
    end
  end

  test "the identical resend of a served steered frame is still refused (local owner, full)" do
    {outcome, _logs} = with_info_log(fn -> run_scenario(:local, "full", [:resend_steer]) end)

    assert outcome.steer_answer == {"response.completed", "resp_steered_successor"}
    assert outcome.resend_answers == [{"error", 409, "duplicate_turn"}]
    assert_served_once_each!(outcome, 2)
  end

  test "the identical resend of a served steered frame is still refused (owner forwarding off, full)" do
    {outcome, _logs} = with_info_log(fn -> run_scenario(:direct, "full", [:resend_steer]) end)

    assert outcome.steer_answer == {"response.completed", "resp_steered_successor"}
    assert outcome.resend_answers == [{"error", 409, "duplicate_turn"}]
    assert_served_once_each!(outcome, 2)
  end

  # The opener's own resend is not anchored on a response of its turn, so it
  # keeps the bare turn claim and today's refusal, even after a steer.
  test "the opener's resend on the same socket is still refused after a steer (local owner, full)" do
    {outcome, _logs} = with_info_log(fn -> run_scenario(:local, "full", [:resend_opener]) end)

    assert outcome.steer_answer == {"response.completed", "resp_steered_successor"}
    assert outcome.resend_answers == [{"error", 409, "duplicate_turn"}]
    assert_served_once_each!(outcome, 2)
  end

  # Only the anchor on a response of the frame's OWN turn marks a later request.
  # The next turn's opener is anchored on the previous turn's response and keeps
  # the bare turn claim, which is what fences its full-history resend from
  # another socket.
  test "a new turn anchored on the previous turn's response keeps the turn claim; its full-history resend on another socket is refused (local owner, full)" do
    {outcome, _logs} = with_info_log(fn -> run_next_turn_scenario() end)

    assert outcome.next_turn_answer == {"response.completed", "resp_next_turn_opening"}
    assert outcome.resend_answer == {"error", 409, "duplicate_turn"}
    assert Enum.map(outcome.requests, &String.slice(&1.correlation_id, 0, 11)) == ["codex-turn:", "codex-turn:"]
    assert_served_once_each!(outcome, 2)
  end

  defp assert_served_once_each!(outcome, count) do
    assert length(outcome.requests) == count
    assert Enum.map(outcome.requests, & &1.status) == List.duplicate("succeeded", count)

    for request <- outcome.requests do
      assert ledger_kinds(request.id) == %{"reservation" => 1, "settlement" => 1, "release" => 1}
    end

    # The provider generated each served request once; nothing was dispatched twice.
    assert outcome.upstream_count == count
  end

  defp run_scenario(topology, mode, extras) do
    upstream =
      start_upstream(
        # provenance: source-derived findings#206 row 206-409 (rust-v0.156.1 session/turn.rs drains steered input after response.completed; client.rs sends it as an anchored increment on the same connection)
        FakeUpstream.strict_sequence([
          native_request(FakeUpstream.websocket_text_frames(response_frames("resp_steered_opening", "msg_steered_opening"))),
          native_request(FakeUpstream.websocket_text_frames(response_frames("resp_steered_successor", "msg_steered_successor")))
        ])
      )

    setup = topology_setup!(topology, upstream)
    if mode == "lite", do: set_model_serving_mode!(model_serving_scope(), setup, "lite")
    model = setup.model.exposed_model_id
    port = start_public_endpoint!()

    {conn, ws, ref} = connect!(port, setup)
    opener = turn_payload(model, [synthetic_user_item("steered question")])
    {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(opener))
    {conn, ws, opening} = receive_until_terminal!(conn, ws, ref)
    assert List.last(opening)["type"] == "response.completed"

    # The user typed while the turn ran; the client drains it into the same
    # turn as the increment after the response it just completed.
    steer =
      model
      |> turn_payload([synthetic_user_item("steered follow-up")])
      |> Map.put("previous_response_id", "resp_steered_opening")

    {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(steer))
    {conn, ws, steered} = receive_until_terminal!(conn, ws, ref)

    {conn, ws, resend_answers} =
      Enum.reduce(extras, {conn, ws, []}, fn extra, {conn, ws, answers} ->
        frame = if extra == :resend_steer, do: steer, else: opener
        {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(frame))
        {conn, ws, answer} = receive_until_terminal!(conn, ws, ref)
        {conn, ws, answers ++ [answer_of(answer)]}
      end)

    _ws = ws
    _closed = Mint.HTTP.close(conn)
    requests = request_logs(setup.pool.id)

    for request <- requests,
        do: assert(await_request_settled(request.id, System.monotonic_time(:millisecond) + @detection_timeout_ms) != "in_progress")

    %{
      steer_answer: answer_of(steered),
      resend_answers: resend_answers,
      steer_upstream_anchor: upstream_anchor(upstream, 1),
      requests: Enum.map(requests, &Repo.get!(Request, &1.id)),
      upstream_count: FakeUpstream.count(upstream)
    }
  end

  defp run_next_turn_scenario do
    upstream =
      start_upstream(
        # provenance: source-derived findings#206 row 206-409 (rust-v0.156.1 client.rs carries the websocket session across turns, so a new turn's opener is an anchored increment on the previous turn's last response)
        FakeUpstream.strict_sequence([
          native_request(FakeUpstream.websocket_text_frames(response_frames("resp_previous_turn", "msg_previous_turn"))),
          native_request(FakeUpstream.websocket_text_frames(response_frames("resp_next_turn_opening", "msg_next_turn_opening")))
        ])
      )

    setup = gateway_setup(upstream)
    model = setup.model.exposed_model_id
    port = start_public_endpoint!()
    first_user = synthetic_user_item("first question")
    next_user = synthetic_user_item("next question")

    {conn, ws, ref} = connect!(port, setup)
    {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(turn_payload(model, [first_user], "turn-previous")))
    {conn, ws, first} = receive_until_terminal!(conn, ws, ref)
    assert List.last(first)["type"] == "response.completed"

    next_turn =
      model
      |> turn_payload([next_user], "turn-next")
      |> Map.put("previous_response_id", "resp_previous_turn")

    {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(next_turn))
    {conn, _ws, next_answer} = receive_until_terminal!(conn, ws, ref)
    _closed = Mint.HTTP.close(conn)

    # The client lost that socket and resends the next turn's opener as full
    # history on a new one.
    assistant = %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}
    {conn_b, ws_b, ref_b} = connect!(port, setup)
    {conn_b, ws_b} = public_websocket_send_text!(conn_b, ws_b, ref_b, encode(turn_payload(model, [first_user, assistant, next_user], "turn-next")))
    {conn_b, _ws_b, resend} = receive_until_terminal!(conn_b, ws_b, ref_b)
    _closed = Mint.HTTP.close(conn_b)
    requests = request_logs(setup.pool.id)

    for request <- requests,
        do: assert(await_request_settled(request.id, System.monotonic_time(:millisecond) + @detection_timeout_ms) != "in_progress")

    %{
      next_turn_answer: answer_of(next_answer),
      resend_answer: answer_of(resend),
      requests: Enum.map(requests, &Repo.get!(Request, &1.id)),
      upstream_count: FakeUpstream.count(upstream)
    }
  end

  defp answer_of(frames) do
    last = List.last(frames)

    case last do
      %{"type" => "error"} -> {"error", last["status"], get_in(last, ["error", "code"])}
      %{"type" => type} -> {type, get_in(last, ["response", "id"])}
    end
  end

  defp upstream_anchor(upstream, index) do
    case Enum.at(FakeUpstream.requests(upstream), index) do
      %{json: %{} = json} -> Map.get(json, "previous_response_id")
      %{body: body} when is_binary(body) -> body |> CodexPooler.JSON.decode!() |> Map.get("previous_response_id")
      _missing -> nil
    end
  end

  # The peer shares the committed database, so its fixture is committed: the
  # sandbox switches to auto mode before anything is written.
  defp topology_setup!(:peer, upstream) do
    enter_peer_owner_topology!()
    setup = gateway_setup(upstream)
    Map.put(setup, :peer_owner, start_peer_window_owner!(setup, @window_id))
  end

  defp topology_setup!(:direct, upstream) do
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
    gateway_setup(upstream)
  end

  defp topology_setup!(:local, upstream), do: gateway_setup(upstream)

  defp connect!(port, setup) do
    {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, Ecto.UUID.generate(), "/backend-api/codex/responses", [{"x-codex-window-id", @window_id}])
    {conn, websocket, ref}
  end

  defp native_request(respond) do
    FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", json: [valid: true, equals: %{"type" => "response.create"}], respond: respond)
  end

  defp turn_payload(model, input, turn_id \\ @turn_id) do
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

  defp response_frames(response_id, message_id) do
    message = %{"type" => "message", "id" => message_id, "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}

    [
      encode(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}}),
      encode(%{"type" => "response.output_item.added", "output_index" => 0, "item" => Map.put(message, "status", "in_progress")}),
      encode(%{"type" => "response.output_text.delta", "output_index" => 0, "content_index" => 0, "item_id" => message_id, "delta" => "synthetic answer"}),
      encode(%{"type" => "response.output_item.done", "output_index" => 0, "item" => message}),
      encode(%{
        "type" => "response.completed",
        "response" => %{"id" => response_id, "status" => "completed", "output" => [message], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}
      })
    ]
  end

  defp encode(map), do: CodexPooler.JSON.encode!(map)

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
