defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.SteeredTurnBeyondSocketTest do
  # The released Codex client (rust-v0.156.1) drains user input steered into a
  # running turn into the SAME turn, under the same `turn_id`, once a request of
  # it completed (`session/turn.rs` `can_drain_pending_input`, `turn_input.rs`
  # `steer_input`). On the connection that delivered that response the steer is
  # an anchored increment (findings#206 row 206-409), but two things put it
  # somewhere else:
  #
  #   * the connection is gone when the steer is sent. `client.rs`
  #     `websocket_connection` finds it closed (`conn.is_closed()`, or the
  #     provider headers or auth changed), resets the cached websocket session
  #     and opens a new one, and `prepare_websocket_request` then has no last
  #     response, so the steer goes out as full history on the new socket;
  #   * the session fell back to HTTPS (`try_switch_fallback_transport` sets the
  #     session-wide `disable_websockets`), so the steer is a native HTTP
  #     request carrying full history, after a turn opener that ran on the
  #     websocket.
  #
  # In a turn with no tool result anywhere in its history both derived the
  # turn's bare `codex-turn:` claim, which the websocket opener holds, and were
  # refused `409 duplicate_turn` (findings#206 row 206-412). The opener's own
  # resends, full history or rebuilt with its delivered answer, must stay
  # refused on every transport.
  #
  # Topology: the real public listener; owner forwarding on with the session's
  # owner on this node or on a second VM sharing the committed database, and
  # owner forwarding off (the socket's own upstream session); Full and Lite;
  # native HTTP SSE through the router for the HTTPS arms. FakeUpstream only.
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
  @thread_id "019a0000-0000-7000-8000-00000000e412"
  @window_id "#{@thread_id}:0"
  @turn_id "turn-steered-beyond"
  @metadata_key "x-codex-turn-metadata"
  @lite_header "x-openai-internal-codex-responses-lite"

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    :ok
  end

  describe "a steer sent as full history on a new socket" do
    for {topology, mode} <- [{:local, "full"}, {:local, "lite"}, {:peer, "full"}, {:direct, "full"}, {:direct, "lite"}] do
      @tag topology: topology, serving_mode: mode
      test "is served once, and its resend and the opener's resend stay refused (#{topology} owner, #{mode})", %{topology: topology, serving_mode: mode} do
        {outcome, logs} = with_info_log(fn -> run_new_socket_steer(topology, mode) end)

        assert outcome.steer_answer == {"response.completed", "resp_beyond_steer"}
        assert outcome.resend_answers == [{"error", 409, "duplicate_turn"}, {"error", 409, "duplicate_turn"}]
        assert_served_once_each!(outcome, 2)
        assert [_opener, steer] = outcome.requests
        assert String.starts_with?(steer.correlation_id, "codex-resume:")
        assert logs =~ "native websocket steered turn claim rebound"
      end
    end

    # The opener of a later turn on a long-lived socket is an anchored
    # increment, so its own row cannot be compared with a full-history steer
    # unless the socket knew the history that anchor stood for.
    for topology <- [:local, :direct] do
      @tag topology: topology
      test "is served when the turn's opener was an anchored increment (#{topology} owner, full)", %{topology: topology} do
        {outcome, _logs} = with_info_log(fn -> run_anchored_opener_steer(topology) end)

        assert outcome.steer_answer == {"response.completed", "resp_beyond_steer"}
        assert outcome.resend_answers == [{"error", 409, "duplicate_turn"}]
        assert_served_once_each!(outcome, 3)

        # The anchored opener recorded the progress of the history its anchor
        # stood for: a digest, never content.
        assert [_previous, opener, steer] = outcome.requests
        assert %{"version" => 1, "digest" => <<_::binary-size(43)>>} = opener.request_metadata["native_turn_progress"]
        assert String.starts_with?(opener.correlation_id, "codex-turn:")
        assert String.starts_with?(steer.correlation_id, "codex-resume:")
      end
    end

    # A steer served anchored on its own socket and then sent again as full
    # history on another socket (its client never read the answer) is the same
    # request, and must not be generated twice.
    for topology <- [:local, :direct] do
      @tag topology: topology
      test "is refused when it repeats a steer already served anchored on the old socket (#{topology} owner, full)", %{topology: topology} do
        {outcome, _logs} = with_info_log(fn -> run_anchored_steer_then_full_history(topology) end)

        assert outcome.steer_answer == {"response.completed", "resp_beyond_steer"}
        assert outcome.resend_answers == [{"error", 409, "duplicate_turn"}]
        assert_served_once_each!(outcome, 2)
        assert [_opener, steer] = outcome.requests
        assert String.starts_with?(steer.correlation_id, "codex-resume:")
      end
    end
  end

  describe "a steer sent over HTTPS after a websocket opener" do
    for mode <- ["full", "lite"] do
      @tag serving_mode: mode
      test "is served once, and its resend and the opener's HTTPS resends stay refused (#{mode})", %{conn: conn, serving_mode: mode} do
        outcome = run_https_steer(conn, mode)

        # The opener's HTTPS fallback, as sent and rebuilt with its delivered
        # answer, is the opener again.
        assert outcome.opener_resend_statuses == [{409, "duplicate_turn"}, {409, "duplicate_turn"}]
        assert outcome.steer_status == 200
        assert outcome.steer_resend_status == {409, "duplicate_turn"}
        assert_served_once_each!(outcome, 2)

        assert [opener, steer] = outcome.requests
        assert opener.transport == "websocket" and String.starts_with?(opener.correlation_id, "codex-turn:")
        assert String.starts_with?(steer.correlation_id, "codex-resume:")
        assert steer.request_metadata["native_http_claim_arm"] == "steered_continuation"
      end
    end
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

  defp run_new_socket_steer(topology, mode) do
    upstream =
      start_upstream(
        # provenance: source-derived findings#206 row 206-412 (rust-v0.156.1 client.rs websocket_connection resets the cached session when the connection closed, so the steer drained after response.completed goes out as full history on a new socket)
        FakeUpstream.strict_sequence([
          native_request(FakeUpstream.websocket_text_frames(response_frames("resp_beyond_opening", "msg_beyond_opening"))),
          native_request(FakeUpstream.websocket_text_frames(response_frames("resp_beyond_steer", "msg_beyond_steer")))
        ])
      )

    setup = topology_setup!(topology, upstream)
    if mode == "lite", do: set_model_serving_mode!(model_serving_scope(), setup, "lite")
    model = setup.model.exposed_model_id
    port = start_public_endpoint!()
    opener_input = [synthetic_user_item("steered question")]

    {:ok, _opening} = send_on_new_socket(port, setup, turn_payload(model, opener_input))

    steer_input = opener_input ++ [assistant_item("msg_beyond_opening"), synthetic_user_item("steered follow-up")]
    {:ok, steered} = send_on_new_socket(port, setup, turn_payload(model, steer_input))

    {:ok, steer_resend} = send_on_new_socket(port, setup, turn_payload(model, steer_input))
    {:ok, opener_resend} = send_on_new_socket(port, setup, turn_payload(model, opener_input))

    finish(setup, upstream, steered, [steer_resend, opener_resend])
  end

  defp run_anchored_opener_steer(topology) do
    upstream =
      start_upstream(
        # provenance: source-derived findings#206 row 206-412 (rust-v0.156.1 client.rs carries the websocket session across turns, so the next turn's opener is an anchored increment; after a reconnect its steer is full history)
        FakeUpstream.strict_sequence([
          native_request(FakeUpstream.websocket_text_frames(response_frames("resp_beyond_previous", "msg_beyond_previous"))),
          native_request(FakeUpstream.websocket_text_frames(response_frames("resp_beyond_opening", "msg_beyond_opening"))),
          native_request(FakeUpstream.websocket_text_frames(response_frames("resp_beyond_steer", "msg_beyond_steer")))
        ])
      )

    setup = topology_setup!(topology, upstream)
    model = setup.model.exposed_model_id
    port = start_public_endpoint!()
    first_user = synthetic_user_item("first question")
    next_user = synthetic_user_item("next question")

    {conn, ws, ref} = connect!(port, setup)
    {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(turn_payload(model, [first_user], "turn-beyond-previous")))
    {conn, ws, first} = receive_until_terminal!(conn, ws, ref)
    assert List.last(first)["type"] == "response.completed"

    opener =
      model
      |> turn_payload([next_user])
      |> Map.put("previous_response_id", "resp_beyond_previous")

    {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(opener))
    {conn, _ws, opening} = receive_until_terminal!(conn, ws, ref)
    assert List.last(opening)["type"] == "response.completed"
    _closed = Mint.HTTP.close(conn)

    history = [first_user, assistant_item("msg_beyond_previous"), next_user]
    steer_input = history ++ [assistant_item("msg_beyond_opening"), synthetic_user_item("steered follow-up")]
    {:ok, steered} = send_on_new_socket(port, setup, turn_payload(model, steer_input))
    {:ok, opener_resend} = send_on_new_socket(port, setup, turn_payload(model, history))

    finish(setup, upstream, steered, [opener_resend])
  end

  defp run_anchored_steer_then_full_history(topology) do
    upstream =
      start_upstream(
        # provenance: source-derived findings#206 row 206-412 (rust-v0.156.1 client.rs resends a request as full history on a new connection; the steer's anchored and full-history forms are one request)
        FakeUpstream.strict_sequence([
          native_request(FakeUpstream.websocket_text_frames(response_frames("resp_beyond_opening", "msg_beyond_opening"))),
          native_request(FakeUpstream.websocket_text_frames(response_frames("resp_beyond_steer", "msg_beyond_steer")))
        ])
      )

    setup = topology_setup!(topology, upstream)
    model = setup.model.exposed_model_id
    port = start_public_endpoint!()
    opener_input = [synthetic_user_item("steered question")]
    steer_user = synthetic_user_item("steered follow-up")

    {conn, ws, ref} = connect!(port, setup)
    {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(turn_payload(model, opener_input)))
    {conn, ws, opening} = receive_until_terminal!(conn, ws, ref)
    assert List.last(opening)["type"] == "response.completed"

    steer =
      model
      |> turn_payload([steer_user])
      |> Map.put("previous_response_id", "resp_beyond_opening")

    {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(steer))
    {conn, _ws, steered} = receive_until_terminal!(conn, ws, ref)
    _closed = Mint.HTTP.close(conn)

    full_history = opener_input ++ [assistant_item("msg_beyond_opening"), steer_user]
    {:ok, resend} = send_on_new_socket(port, setup, turn_payload(model, full_history))

    finish(setup, upstream, steered, [resend])
  end

  defp run_https_steer(conn, mode) do
    upstream =
      start_upstream(
        # provenance: source-derived findings#206 row 206-412 (rust-v0.156.1 client.rs try_switch_fallback_transport disables websockets for the rest of the session, so a steer drained after a websocket request completed goes out over HTTPS as full history)
        FakeUpstream.strict_sequence([
          native_request(FakeUpstream.websocket_text_frames(response_frames("resp_beyond_opening", "msg_beyond_opening"))),
          turn_sse("resp_beyond_steer")
        ])
      )

    setup = gateway_setup(upstream)
    if mode == "lite", do: set_model_serving_mode!(model_serving_scope(), setup, "lite")
    model = setup.model.exposed_model_id
    port = start_public_endpoint!()
    opener_input = [synthetic_user_item("steered question")]

    {:ok, _opening} = send_on_new_socket(port, setup, turn_payload(model, opener_input))

    opener_resends =
      for input <- [opener_input, opener_input ++ [assistant_item("msg_beyond_opening")]] do
        status_of(post_http(conn, setup, mode, input))
      end

    steer_input = opener_input ++ [assistant_item("msg_beyond_opening"), synthetic_user_item("steered follow-up")]
    steer_conn = post_http(conn, setup, mode, steer_input)
    steer_status = steer_conn.status
    steer_resend = status_of(post_http(conn, setup, mode, steer_input))

    requests = pool_requests(setup)

    for request <- requests,
        do: assert(await_request_settled(request.id, System.monotonic_time(:millisecond) + @detection_timeout_ms) != "in_progress")

    %{
      opener_resend_statuses: opener_resends,
      steer_status: steer_status,
      steer_resend_status: steer_resend,
      requests: Enum.map(requests, &Repo.get!(Request, &1.id)),
      upstream_count: FakeUpstream.count(upstream)
    }
  end

  defp finish(setup, upstream, steered, resends) do
    requests = request_logs(setup.pool.id)

    for request <- requests,
        do: assert(await_request_settled(request.id, System.monotonic_time(:millisecond) + @detection_timeout_ms) != "in_progress")

    %{
      steer_answer: answer_of(steered),
      resend_answers: Enum.map(resends, &answer_of/1),
      requests: Enum.map(requests, &Repo.get!(Request, &1.id)),
      upstream_count: FakeUpstream.count(upstream)
    }
  end

  defp send_on_new_socket(port, setup, payload) do
    {conn, ws, ref} = connect!(port, setup)
    {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(payload))
    {conn, _ws, frames} = receive_until_terminal!(conn, ws, ref)
    _closed = Mint.HTTP.close(conn)
    {:ok, frames}
  end

  defp answer_of(frames) do
    last = List.last(frames)

    case last do
      %{"type" => "error"} -> {"error", last["status"], get_in(last, ["error", "code"])}
      %{"type" => type} -> {type, get_in(last, ["response", "id"])}
    end
  end

  defp status_of(%Plug.Conn{status: 200}), do: 200
  defp status_of(%Plug.Conn{status: status} = conn), do: {status, get_in(CodexPooler.JSON.decode!(conn.resp_body), ["error", "code"])}

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

  defp canonical_document(turn_id),
    do: CodexPooler.JSON.encode!(%{"session_id" => @thread_id, "thread_id" => @thread_id, "turn_id" => turn_id, "window_id" => @window_id, "request_kind" => "turn"})

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
        @metadata_key => canonical_document(turn_id)
      },
      "input" => input
    }
  end

  # The released client's HTTP request after the fallback (P69 wire capture of
  # 0.156.1): the same canonical document in the body and echoed as
  # `x-codex-turn-metadata`, the thread as `session-id`, the window as
  # `x-codex-window-id`, and in Lite the marker as a header.
  defp post_http(conn, setup, mode, input) do
    document = canonical_document(@turn_id)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "instructions" => "synthetic base instructions",
      "input" => input,
      "stream" => true,
      "store" => false,
      "tools" => [%{"type" => "function", "name" => "shell", "parameters" => %{"type" => "object", "properties" => %{}}}],
      "client_metadata" => %{@metadata_key => document}
    }

    conn
    |> recycle()
    |> auth(setup)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "text/event-stream")
    |> put_req_header("session-id", @thread_id)
    |> put_req_header("thread-id", @thread_id)
    |> put_req_header("x-codex-window-id", @window_id)
    |> put_req_header(@metadata_key, document)
    |> put_req_header("originator", "codex_cli_rs")
    |> then(&if mode == "lite", do: put_req_header(&1, @lite_header, "true"), else: &1)
    |> post("/backend-api/codex/responses", CodexPooler.JSON.encode!(payload))
  end

  defp turn_sse(id) do
    FakeUpstream.sse_stream([
      {"response.completed", %{"type" => "response.completed", "response" => %{"id" => id, "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}}}}
    ])
  end

  defp synthetic_user_item(text),
    do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic " <> text}]}

  defp assistant_item(message_id),
    do: %{"type" => "message", "id" => message_id, "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}

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

  defp pool_requests(setup), do: Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: r.admitted_at))

  defp ledger_kinds(request_id) do
    Repo.all(from(entry in LedgerEntry, where: entry.request_id == ^request_id, select: entry.entry_kind))
    |> Enum.frequencies()
  end
end
