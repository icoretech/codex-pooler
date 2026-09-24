defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.SteerProgressMonotonicTest do
  # A later `:opening` request of a turn is re-keyed to the steered
  # `codex-resume:` claim when it is further along the turn than the request
  # holding the bare `codex-turn:` claim (findings#206 rows 206-403/206-412).
  # "Further along" must be monotonic, not merely different (row 206-423):
  #
  #   * the same compaction point (or none) and strictly MORE user messages
  #     after it: the released client drained steered input into the turn
  #     (`session/turn.rs` `can_drain_pending_input`); or
  #   * a compaction point the holder did not end on: a remote compaction
  #     replaced the history (`compact_remote_v2.rs` `build_v2_compacted_history`
  #     keeps only messages and appends the new compaction item last).
  #
  # Anything else -- fewer user messages at the same point, or the compaction
  # point gone -- is not a later request of the turn. The released client never
  # sends that (a sampling retry re-reads the history, which only gains model
  # output: `run_sampling_request` rebuilds the prompt from `clone_history()`;
  # `remove_first_item` runs only in local compaction and
  # `drop_last_n_user_turns` only in rollout reconstruction), so such a request
  # is a trimmed resend of the holder and keeps the bare claim and its refusal
  # instead of being generated a second time.
  #
  # The last describe emulates a rolling deploy (row 206-424): rows as a node of
  # the previous release writes them, then the full-history resend reaching a
  # node of this one.
  #
  # Topology: the real public listener; native websocket with owner forwarding
  # on (owner on this node) and off; native HTTP SSE through the router with
  # the released client's headers; Full and Lite; one node. FakeUpstream only.
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [request_logs: 1]

  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @detection_timeout_ms 15_000
  @thread_id "019a0000-0000-7000-8000-00000000e423"
  @metadata_key "x-codex-turn-metadata"
  @lite_header "x-openai-internal-codex-responses-lite"

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    :ok
  end

  describe "a native HTTP resend of the turn's opener that is not further along" do
    for mode <- ["full", "lite"] do
      @tag serving_mode: mode
      test "with fewer user messages is refused, not generated again (#{mode})", %{conn: conn, serving_mode: mode} do
        upstream = start_upstream(FakeUpstream.strict_sequence([turn_sse("resp_mono_open")]))
        setup = http_setup!(upstream, mode)
        ids = ids()
        opener = [user("earlier turn"), assistant("earlier answer"), user("open the turn")]

        assert response(post_http(conn, setup, ids, "turn", opener), 200)

        trimmed = [user("open the turn")]
        assert %{"error" => %{"code" => "duplicate_turn"}} = json_response(post_http(conn, setup, ids, "turn", trimmed), 409)

        assert FakeUpstream.count(upstream) == 1
        assert [{"codex-turn", "opening", "succeeded"}] = http_rows(setup)
      end
    end

    test "with its compaction point gone is refused, not generated again (full)", %{conn: conn} do
      upstream = start_upstream(FakeUpstream.strict_sequence([turn_sse("resp_mono_open")]))
      setup = http_setup!(upstream, "full")
      ids = ids()
      opener = [user("earlier turn"), compaction_item("earlier"), user("open the turn")]

      assert response(post_http(conn, setup, ids, "turn", opener), 200)

      pruned = [user("earlier turn"), user("open the turn")]
      assert %{"error" => %{"code" => "duplicate_turn"}} = json_response(post_http(conn, setup, ids, "turn", pruned), 409)

      assert FakeUpstream.count(upstream) == 1
      assert [{"codex-turn", "opening", "succeeded"}] = http_rows(setup)
    end
  end

  describe "a native HTTP steer that is further along" do
    # Control for the tightened rule: in an already compacted session a
    # mid-turn compaction replaces the history (its retained user messages,
    # then the new compaction item), so the steer drained after it carries a
    # different compaction point and no more user messages after it than the
    # opener had. It is still a later request of the turn.
    test "after a mid-turn compaction of a compacted session is served once (full)", %{conn: conn} do
      upstream = start_upstream(FakeUpstream.strict_sequence([turn_sse("resp_mono_open"), compaction_sse("resp_mono_compaction"), turn_sse("resp_mono_steer")]))
      setup = http_setup!(upstream, "full")
      ids = ids()
      opener = [user("earlier turn"), compaction_item("earlier"), user("open the turn")]

      assert response(post_http(conn, setup, ids, "turn", opener), 200)
      assert response(post_http(conn, setup, ids, "compaction", opener ++ [assistant("working"), %{"type" => "compaction_trigger"}]), 200)

      steered = [user("earlier turn"), user("open the turn"), compaction_item("mid-turn"), user("steer the running turn")]
      assert response(post_http(conn, setup, ids, "turn", steered, 1), 200)
      assert %{"error" => %{"code" => "duplicate_turn"}} = json_response(post_http(conn, setup, ids, "turn", steered, 1), 409)

      assert FakeUpstream.count(upstream) == 3

      assert [
               {"codex-turn", "opening", "succeeded"},
               {"codex-request", "compaction", "succeeded"},
               {"codex-resume", "steered_continuation", "succeeded"}
             ] = http_rows(setup)
    end
  end

  describe "a full-history resend on a new socket of the turn's opener that is not further along" do
    for {topology, mode} <- [{:local, "full"}, {:local, "lite"}, {:direct, "full"}] do
      @tag topology: topology, serving_mode: mode
      test "with fewer user messages is refused, not generated again (#{topology} owner, #{mode})", %{topology: topology, serving_mode: mode} do
        upstream = start_upstream(FakeUpstream.strict_sequence([native_request(response_frames("resp_mono_open", "msg_mono_open"))]))
        setup = websocket_setup!(topology, upstream, mode)
        port = start_public_endpoint!()
        model = setup.model.exposed_model_id
        opener = [user("earlier turn"), assistant("earlier answer"), user("open the turn")]

        {:ok, opening} = send_on_new_socket(port, setup, turn_payload(model, opener))
        {:ok, trimmed} = send_on_new_socket(port, setup, turn_payload(model, [user("open the turn")]))

        outcome = finish(setup, upstream)
        assert answer_of(opening) == {"response.completed", "resp_mono_open"}
        assert answer_of(trimmed) == {"error", 409, "duplicate_turn"}
        assert_served_once_each!(outcome, 1)
      end
    end

    test "with its compaction point gone is refused, not generated again (local owner, full)" do
      upstream = start_upstream(FakeUpstream.strict_sequence([native_request(response_frames("resp_mono_open", "msg_mono_open"))]))
      setup = websocket_setup!(:local, upstream, "full")
      port = start_public_endpoint!()
      model = setup.model.exposed_model_id
      opener = [user("earlier turn"), compaction_item("earlier"), user("open the turn")]

      {:ok, opening} = send_on_new_socket(port, setup, turn_payload(model, opener))
      {:ok, pruned} = send_on_new_socket(port, setup, turn_payload(model, [user("earlier turn"), user("open the turn")]))

      outcome = finish(setup, upstream)
      assert answer_of(opening) == {"response.completed", "resp_mono_open"}
      assert answer_of(pruned) == {"error", 409, "duplicate_turn"}
      assert_served_once_each!(outcome, 1)
    end
  end

  describe "a rolling deploy (a node of the previous release served the steer on its own socket)" do
    # The previous release records no websocket progress, and its codec claims
    # a steer anchored on its own socket per payload (`codex-request:`). The
    # emulation writes those rows exactly so: the opener without
    # `native_turn_progress`, the steer under a `codex-request:` claim without
    # it. The steer's client never read its answer and resends it as full
    # history on a new socket, which reaches a node of this release: with no
    # progress on the holder of the bare claim it keeps that claim, and the
    # opener's resend policy refuses it. It is not generated a second time.
    for topology <- [:local, :direct] do
      @tag topology: topology
      test "the steer's full-history resend is refused, not generated again (#{topology} owner, full)", %{topology: topology} do
        upstream =
          start_upstream(
            FakeUpstream.strict_sequence([
              native_request(response_frames("resp_mono_open", "msg_mono_open")),
              native_request(response_frames("resp_mono_steer", "msg_mono_steer"))
            ])
          )

        setup = websocket_setup!(topology, upstream, "full")
        port = start_public_endpoint!()
        model = setup.model.exposed_model_id
        opener = [user("open the turn")]
        steer_user = user("steer the running turn")

        {conn, ws, ref} = connect!(port, setup)
        {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(turn_payload(model, opener)))
        {conn, ws, opening} = receive_until_terminal!(conn, ws, ref)
        assert answer_of(opening) == {"response.completed", "resp_mono_open"}

        anchored = model |> turn_payload([steer_user]) |> Map.put("previous_response_id", "resp_mono_open")
        {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(anchored))
        {conn, _ws, steered} = receive_until_terminal!(conn, ws, ref)
        assert answer_of(steered) == {"response.completed", "resp_mono_steer"}
        _closed = Mint.HTTP.close(conn)

        settle_all!(setup)
        rewrite_as_previous_release!(setup)

        {:ok, resend} = send_on_new_socket(port, setup, turn_payload(model, opener ++ [assistant("msg_mono_open"), steer_user]))

        outcome = finish(setup, upstream)
        assert answer_of(resend) == {"error", 409, "duplicate_turn"}
        assert_served_once_each!(outcome, 2)
        assert [opener_row, steer_row] = outcome.requests
        assert String.starts_with?(opener_row.correlation_id, "codex-turn:")
        assert String.starts_with?(steer_row.correlation_id, "codex-request:")
      end
    end
  end

  # The rows a node of the previous release writes for the same two requests.
  defp rewrite_as_previous_release!(setup) do
    [opener, steer] = pool_requests(setup)

    for request <- [opener, steer] do
      metadata = Map.delete(request.request_metadata, "native_turn_progress")
      request |> Ecto.Changeset.change(request_metadata: metadata) |> Repo.update!()
    end

    # This release claims the steer `codex-resume:`; the previous one already
    # claimed it `codex-request:`, which no form of the resend derives.
    case steer.correlation_id do
      "codex-resume:" <> suffix -> steer |> Ecto.Changeset.change(correlation_id: "codex-request:previous-release-" <> suffix) |> Repo.update!()
      "codex-request:" <> _previous_release -> steer
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

  defp finish(setup, upstream) do
    settle_all!(setup)
    %{requests: Enum.map(request_logs(setup.pool.id), &Repo.get!(Request, &1.id)), upstream_count: FakeUpstream.count(upstream)}
  end

  defp settle_all!(setup) do
    for request <- request_logs(setup.pool.id),
        do: assert(await_request_settled(request.id, System.monotonic_time(:millisecond) + @detection_timeout_ms) != "in_progress")
  end

  defp http_setup!(upstream, mode) do
    setup = gateway_setup(upstream, compact?: true)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
    Map.put(setup, :serving_mode, mode)
  end

  defp websocket_setup!(:direct, upstream, mode) do
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
    websocket_setup!(:local, upstream, mode)
  end

  defp websocket_setup!(:local, upstream, mode) do
    setup = gateway_setup(upstream)
    if mode == "lite", do: set_model_serving_mode!(model_serving_scope(), setup, "lite")
    setup
  end

  defp ids, do: %{turn: "turn-" <> unique_suffix(), thread: Ecto.UUID.generate()}

  # The released client's HTTP request (P69 wire capture of 0.156.1): the
  # canonical document in the body and echoed as `x-codex-turn-metadata`, the
  # thread as `session-id`, the window as `x-codex-window-id` (advanced after
  # every completed compaction), and in Lite the marker as a header.
  defp post_http(conn, setup, ids, kind, input, window \\ 0) do
    document =
      CodexPooler.JSON.encode!(%{
        "session_id" => ids.thread,
        "thread_id" => ids.thread,
        "turn_id" => ids.turn,
        "window_id" => "#{ids.thread}:#{window}",
        "request_kind" => kind
      })

    payload = %{"model" => setup.model.exposed_model_id, "input" => input, "stream" => true, "client_metadata" => %{@metadata_key => document}}

    conn
    |> recycle()
    |> auth(setup)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "text/event-stream")
    |> put_req_header("session-id", ids.thread)
    |> put_req_header("thread-id", ids.thread)
    |> put_req_header("x-codex-window-id", "#{ids.thread}:#{window}")
    |> put_req_header(@metadata_key, document)
    |> put_req_header("originator", "codex_cli_rs")
    |> then(&if setup.serving_mode == "lite", do: put_req_header(&1, @lite_header, "true"), else: &1)
    |> post("/backend-api/codex/responses", CodexPooler.JSON.encode!(payload))
  end

  defp http_rows(setup) do
    for request <- pool_requests(setup) do
      {request.correlation_id |> String.split(":") |> hd(), request.request_metadata["native_http_claim_arm"], request.status}
    end
  end

  defp turn_sse(id) do
    FakeUpstream.sse_stream([
      {"response.completed", %{"type" => "response.completed", "response" => %{"id" => id, "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}}}}
    ])
  end

  defp compaction_sse(id) do
    FakeUpstream.compaction_stream(%{"id" => id, "output" => [compaction_item(id)], "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}})
  end

  defp send_on_new_socket(port, setup, payload) do
    {conn, ws, ref} = connect!(port, setup)
    {conn, ws} = public_websocket_send_text!(conn, ws, ref, encode(payload))
    {conn, _ws, frames} = receive_until_terminal!(conn, ws, ref)
    _closed = Mint.HTTP.close(conn)
    {:ok, frames}
  end

  defp connect!(port, setup) do
    {conn, websocket, ref, _headers} =
      public_websocket_connect_with_request_headers!(port, setup, Ecto.UUID.generate(), "/backend-api/codex/responses", [{"x-codex-window-id", "#{@thread_id}:0"}])

    {conn, websocket, ref}
  end

  defp native_request(frames) do
    # provenance: source-derived findings#206 rows 206-423/206-424 (rust-v0.156.1 client.rs: a request resent after its connection closed goes out as full history on a new socket)
    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      path: "/backend-api/codex/responses",
      json: [valid: true, equals: %{"type" => "response.create"}],
      respond: FakeUpstream.websocket_text_frames(frames)
    )
  end

  defp turn_payload(model, input) do
    document = CodexPooler.JSON.encode!(%{"session_id" => @thread_id, "thread_id" => @thread_id, "turn_id" => "turn-steer-monotonic", "window_id" => "#{@thread_id}:0", "request_kind" => "turn"})

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
        "turn_id" => "turn-steer-monotonic",
        "x-codex-window-id" => "#{@thread_id}:0",
        @metadata_key => document
      },
      "input" => input
    }
  end

  defp answer_of(frames) do
    last = List.last(frames)

    case last do
      %{"type" => "error"} -> {"error", last["status"], get_in(last, ["error", "code"])}
      %{"type" => type} -> {type, get_in(last, ["response", "id"])}
    end
  end

  defp user(text), do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic " <> text}]}

  defp assistant(message_id),
    do: %{"type" => "message", "id" => message_id, "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}

  defp compaction_item(label), do: %{"type" => "compaction", "encrypted_content" => "synthetic-compaction-" <> label}

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
