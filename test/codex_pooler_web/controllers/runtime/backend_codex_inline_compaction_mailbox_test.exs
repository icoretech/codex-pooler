defmodule CodexPoolerWeb.Runtime.BackendCodexInlineCompactionMailboxTest do
  # The real sequences of 2026-09-28, replayed end to end once the inline
  # compaction pivot (`NativeTurnContinuation`) and the ordinary-turn mailbox
  # continuation (`NativeMailboxContinuation`) meet.
  #
  # Codex 0.158 compacts a turn locally and inline, under the turn's own
  # `turn_id`: a summarisation request (`request_kind: "compaction"`, ordinary
  # Responses route), then the turn's continuation, whose history is the earlier
  # user messages plus the summary as a user message behind `SUMMARY_PREFIX`.
  # That continuation is a `{:post_compaction_resume, anchor}` under a
  # `codex-resume:` claim, so a mailbox cut of it (a commentary item delivered,
  # sub-agent mail arriving, the client resending the continuation with both
  # appended) is chained through the post-compaction mailbox path, not the
  # ordinary opener's.
  #
  # Every scenario keeps the duplicate fence for a resend the cut does not
  # explain (a delivered item missing or changed): it is refused
  # `409 duplicate_turn` with no second dispatch and no second settlement. A
  # true identical resend inside its retry window is chained as the successor
  # of the request it repeats.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [released_client_connect!: 4]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @endpoint_path "/backend-api/codex/responses"
  @timeout_ms 15_000
  @poll_ms 50

  # provenance: codex-rs/prompts/templates/compact/{prompt,summary_prefix}.md at rust-v0.158.0-alpha.2.
  @summarization_prompt "You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task."
  @summary_prefix "Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:"

  defmodule ClosingAdapter do
    @moduledoc false

    def chunk(%{closed?: true}, _data), do: {:error, :closed}

    def chunk(%{adapter: adapter, payload: payload} = state, data) do
      {:ok, body, payload} = adapter.chunk(payload, data)
      closed? = body == state.close_after
      {:ok, body, %{state | payload: payload, closed?: closed?}}
    end
  end

  # S1: production incident 2026-09-28 06:38 (HTTP SSE, thread 01a0e4de-4e03).
  @tag slow: "drives an opener, its inline summarisation, a cut continuation and its mailbox resend through the HTTP route"
  test "S1 HTTP: a continuation cut after commentary by sub-agent mail after an inline compaction is served as one successor" do
    thread = unique("thread-s1")
    turn = unique("turn-s1")
    call = function_call("call_s1")
    delivered = commentary_item("msg_s1_commentary", status: true)
    done = %{"type" => "response.output_item.done", "output_index" => 0, "item" => delivered}

    upstream =
      start_upstream(
        # provenance: synthetic, shaped after the Codex 0.158 rollout of thread 01a0e4de-4e03 (06:38 UTC).
        FakeUpstream.strict_sequence([
          completed_sse("resp_s1_open", [call]),
          completed_sse("resp_s1_summary", [final_answer("the summary")]),
          FakeUpstream.sse_stream([{"response.output_item.done", done}, {"response.output_text.delta", %{"type" => "response.output_text.delta", "delta" => "not delivered"}}], done: false),
          completed_sse("resp_s1_successor", [final_answer("done")]),
          # Serves the identical resend of the successor.
          completed_sse("resp_s1_wrong", [])
        ])
      )

    setup = gateway_setup(upstream)
    session = unique("codex-session-s1")
    users = Enum.map(1..8, &user_message("request #{&1} of this thread"))

    opener = http_body(setup, users, metadata(thread, turn, 1, :turn))
    assert response(post_http(setup, session, opener), 200) =~ "response.completed"

    summarisation = http_body(setup, users ++ [call, function_output("call_s1"), user_message(@summarization_prompt)], metadata(thread, turn, 1, {:compaction, "mid_turn"}))
    assert response(post_http(setup, session, summarisation), 200) =~ "response.completed"

    continuation = http_body(setup, users ++ [summary_message("half of the work is done")], metadata(thread, turn, 2, :turn))
    cut_http_turn!(setup, session, continuation, [{"response.output_item.done", done}])

    mail = [mailbox_item("/root/alpha", 1), mailbox_item("/root/beta", 2), mailbox_item("/root/alpha", 3), mailbox_item("/root/beta", 4)]
    resend = append(continuation, [commentary_item("msg_s1_commentary") | mail])

    # A resend without the delivered item stays a duplicate.
    assert_http_duplicate!(setup, upstream, session, append(continuation, mail))

    assert response(post_http(setup, session, resend), 200) =~ "response.completed"

    assert [open_row, summary_row, cut_row, successor] = settled_pool_requests!(setup, 4)
    assert claim_prefix(open_row) == "codex-turn:"
    refute claim_prefix(summary_row) in ["codex-turn:", "codex-resume:"]
    assert {claim_prefix(cut_row), cut_row.request_metadata["native_http_claim_arm"]} == {"codex-resume:", "post_compaction_resume"}
    assert {cut_row.status, cut_row.last_error_code} == {"failed", "client_disconnected"}
    assert {successor.status, claim_prefix(successor)} == {"succeeded", "codex-request-retry:"}
    assert_edge!(cut_row, successor)
    assert %Attempt{response_metadata: %{"native_http_resume_progress" => %{"output_item_done_count" => 1}}} = Repo.get_by!(Attempt, request_id: cut_row.id)
    assert_one_settlement_each!([open_row, summary_row, cut_row, successor])
    assert FakeUpstream.count(upstream) == 4

    assert_http_chained!(setup, upstream, session, resend, successor)
  end

  # S1 over websocket: the same cut of the continuation after an inline
  # compaction, with owner forwarding on and off.
  for forwarding <- [true, false] do
    @tag forwarding: forwarding
    @tag slow: "drives an opener, its inline summarisation, a held continuation cut and its mailbox resend through the real listener"
    test "S1 websocket (owner forwarding #{forwarding}): a continuation cut after commentary by sub-agent mail after an inline compaction is served as one successor",
         %{forwarding: forwarding} do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding)
      thread = unique("thread-s1ws")
      turn = unique("turn-s1ws")
      release_ref = make_ref()
      frames = commentary_frames("resp_s1ws_continue")
      hold_at = length(frames) - 1

      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            ws_expectation(completed_frames("resp_s1ws_open")),
            ws_expectation(completed_frames("resp_s1ws_summary")),
            ws_expectation(FakeUpstream.barrier_websocket_frames(frames, notify: self(), release_ref: release_ref)),
            ws_expectation(completed_frames("resp_s1ws_successor")),
            # Serves the identical resend of the successor.
            ws_expectation(completed_frames("resp_s1ws_wrong"))
          ])
        )

      setup = gateway_setup(upstream)
      port = start_public_endpoint!()
      users = Enum.map(1..3, &user_message("request #{&1} of this thread"))
      call = function_call("call_s1ws")

      client = released_client_connect!(port, setup.authorization, thread, window_id(thread, 1))
      assert {client, {:admitted, "response.completed"}} = send_frame(client, frame(setup, users, nil, metadata(thread, turn, 1, :turn)))
      summarisation = frame(setup, users ++ [call, function_output("call_s1ws"), user_message(@summarization_prompt)], nil, metadata(thread, turn, 1, {:compaction, "mid_turn"}))
      assert {client, {:admitted, "response.completed"}} = send_frame(client, summarisation)
      Mint.HTTP.close(client.conn)

      continuation_input = users ++ [summary_message("half of the work is done")]
      continuation_metadata = metadata(thread, turn, 2, :turn)
      second = released_client_connect!(port, setup.authorization, thread, window_id(thread, 2))
      {conn, websocket} = public_websocket_send_text!(second.conn, second.websocket, second.ref, frame(setup, continuation_input, nil, continuation_metadata))

      for ordinal <- 0..(hold_at - 1) do
        assert_receive {:fake_upstream_frame_barrier, ^ordinal, _handler, ^release_ref}, @timeout_ms
        :ok = FakeUpstream.release_frame(upstream, release_ref)
      end

      # The barrier notification is read before any socket frame: the socket
      # helpers consume every message they do not recognise.
      assert_receive {:fake_upstream_frame_barrier, ^hold_at, _handler, ^release_ref}, @timeout_ms
      conn = receive_until!(conn, websocket, second.ref, "response.output_item.done")
      assert [_open, _summary, %Request{id: cut_id}] = pool_requests(setup)
      Mint.HTTP.close(conn)
      assert %{"completed_items" => 1, "terminal_class" => "none"} = await_receipt!(cut_id)
      _settled = await_settled!(cut_id)
      :ok = FakeUpstream.release_remaining_frames(upstream, release_ref)

      mail = [mailbox_item("/root/alpha", 1), mailbox_item("/root/beta", 2), mailbox_item("/root/alpha", 3), mailbox_item("/root/beta", 4)]
      resend = frame(setup, continuation_input ++ [commentary_item("msg_s1ws_commentary") | mail], nil, continuation_metadata)
      assert ws_once(port, setup, thread, resend) == {:admitted, "response.completed"}
      assert [open_row, summary_row, cut_row, successor] = settled_pool_requests!(setup, 4)

      assert claim_prefix(open_row) == "codex-turn:"
      assert claim_prefix(summary_row) == "codex-request:"
      assert {cut_row.id, claim_prefix(cut_row), cut_row.status, cut_row.last_error_code} == {cut_id, "codex-resume:", "failed", "client_disconnected"}
      assert successor.status == "succeeded"
      assert_edge!(cut_row, successor)
      assert_one_settlement_each!([open_row, summary_row, cut_row, successor])
      assert FakeUpstream.count(upstream) == 4

      # An identical resend of the served successor is chained to it.
      assert ws_once(port, setup, thread, resend) == {:admitted, "response.completed"}
      assert [_open, _summary, _cut, _successor, replay] = settled_pool_requests!(setup, 5)
      assert replay.status == "succeeded"
      assert_edge!(successor, replay)
      assert FakeUpstream.count(upstream) == 5
    end
  end

  # S2: production 03:38 (websocket, thread 01a0e4df turn 01a0e617).
  @tag slow: "drives an opener, two tool continuations, a mid-turn inline compaction and its continuation through the real listener"
  test "S2 websocket: a mid-turn inline compaction after two tool continuations and its continuation are admitted" do
    thread = unique("thread-s2")
    turn = unique("turn-s2")
    user = user_message("fix the flaky test")
    older = user_message("an older request of this thread")
    call_a = function_call("call_s2_a")
    call_b = function_call("call_s2_b")

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          ws_expectation(completed_frames("resp_s2_open"), forbidden: ["previous_response_id"]),
          ws_expectation(completed_frames("resp_s2_tool_a"), equals: %{"previous_response_id" => "resp_s2_open"}),
          ws_expectation(completed_frames("resp_s2_tool_b"), equals: %{"previous_response_id" => "resp_s2_tool_a"}),
          ws_expectation(completed_frames("resp_s2_summary"), forbidden: ["previous_response_id"]),
          ws_expectation(completed_frames("resp_s2_continue"), forbidden: ["previous_response_id"]),
          # Serve the identical resends of the continuation and the summarisation request.
          ws_expectation(completed_frames("resp_s2_continue_resend")),
          ws_expectation(completed_frames("resp_s2_summary_resend"))
        ])
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()
    client = released_client_connect!(port, setup.authorization, thread, window_id(thread, 1))
    opening = [older, user]

    try do
      assert {client, {:admitted, "response.completed"}} = send_frame(client, frame(setup, opening, nil, metadata(thread, turn, 1, :turn)))
      assert {client, {:admitted, "response.completed"}} = send_frame(client, frame(setup, [call_a, function_output("call_s2_a")], "resp_s2_open", metadata(thread, turn, 1, :turn)))
      assert {client, {:admitted, "response.completed"}} = send_frame(client, frame(setup, [call_b, function_output("call_s2_b")], "resp_s2_tool_a", metadata(thread, turn, 1, :turn)))

      history = opening ++ [call_a, function_output("call_s2_a"), call_b, function_output("call_s2_b")]
      summarisation = frame(setup, history ++ [user_message(@summarization_prompt)], nil, metadata(thread, turn, 1, {:compaction, "mid_turn"}))
      assert {client, {:admitted, "response.completed"}} = send_frame(client, summarisation)
      Mint.HTTP.close(client.conn)

      continuation = frame(setup, [user, summary_message("both tools ran")], nil, metadata(thread, turn, 2, :turn))
      assert ws_once(port, setup, thread, continuation) == {:admitted, "response.completed"}

      rows = settled_pool_requests!(setup, 5)
      assert Enum.map(rows, &claim_prefix/1) == ["codex-turn:", "codex-request:", "codex-request:", "codex-request:", "codex-resume:"]
      assert Enum.all?(rows, &(&1.status == "succeeded"))

      assert_one_settlement_each!(rows)
      assert FakeUpstream.count(upstream) == 5

      # Identical resends of the continuation and of the summarisation request are chained to them.
      assert ws_once(port, setup, thread, continuation) == {:admitted, "response.completed"}
      assert ws_once(port, setup, thread, summarisation, 1) == {:admitted, "response.completed"}
      assert [_open, _tool_a, _tool_b, summary_row, continuation_row, continuation_resend, summary_resend] = settled_pool_requests!(setup, 7)
      assert_edge!(continuation_row, continuation_resend)
      assert_edge!(summary_row, summary_resend)
      assert FakeUpstream.count(upstream) == 7
    after
      Mint.HTTP.close(client.conn)
    end
  end

  # S3: production 03:42 (websocket, then the HTTPS fallback; thread 01a0e4df turn 01a0e619).
  @tag slow: "drives a pre-turn inline compaction and a mailbox continuation through the real listener"
  test "S3 websocket: the continuation of a pre-turn inline compaction carrying new mail is admitted" do
    %{setup: setup, upstream: upstream, port: port, thread: thread, continuation: continuation} = pre_turn_compaction!(ws_expectation(completed_frames("resp_s3_continue")))

    assert ws_once(port, setup, thread, frame(setup, continuation.input, nil, continuation.metadata)) == {:admitted, "response.completed"}
    rows = settled_pool_requests!(setup, 2)
    assert Enum.map(rows, &claim_prefix/1) == ["codex-request:", "codex-resume:"]

    assert_one_settlement_each!(rows)
    assert FakeUpstream.count(upstream) == 2

    # An HTTPS resend never redeems the websocket continuation; an identical
    # websocket resend is chained to it.
    assert http_fallback(setup, thread, continuation) == {409, "duplicate_turn"}
    assert ws_once(port, setup, thread, frame(setup, continuation.input, nil, continuation.metadata)) == {:admitted, "response.completed"}
    assert [_summary, continuation_row, resend] = settled_pool_requests!(setup, 3)
    assert_edge!(continuation_row, resend)
    assert FakeUpstream.count(upstream) == 3
  end

  @tag slow: "drives a pre-turn inline compaction, a failed websocket continuation and its HTTPS fallback through the real listener"
  test "S3 fallback: a continuation whose websocket failed before any output is admitted over HTTPS" do
    %{setup: setup, upstream: upstream, port: port, thread: thread, continuation: continuation} =
      pre_turn_compaction!(ws_expectation(FakeUpstream.websocket_terminal_failure("server_error")), [
        FakeUpstream.expect_request(method: "POST", respond: FakeUpstream.json_response(%{"id" => "resp_s3_fallback", "status" => "completed", "output" => []})),
        FakeUpstream.expect_request(method: "POST", respond: FakeUpstream.json_response(%{"id" => "resp_s3_fallback_resend", "status" => "completed", "output" => []}))
      ])

    assert {status, _code} = ws_once(port, setup, thread, frame(setup, continuation.input, nil, continuation.metadata))
    refute status == :admitted
    assert [_summary, %Request{status: "failed"} = failed] = settled_pool_requests!(setup, 2)
    assert claim_prefix(failed) == "codex-resume:"

    assert http_fallback(setup, thread, continuation) == {:admitted, "response.completed"}
    assert [_summary, _failed, %Request{status: "succeeded"} = fallback] = settled_pool_requests!(setup, 3)
    assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^fallback.id and l.entry_kind == "settlement"), :count) == 1
    assert FakeUpstream.count(upstream) == 3

    # A websocket resend never redeems the HTTPS fallback; an identical HTTPS
    # resend is chained to it.
    assert ws_once(port, setup, thread, frame(setup, continuation.input, nil, continuation.metadata)) == {409, "duplicate_turn"}
    assert http_fallback(setup, thread, continuation) == {:admitted, "response.completed"}
    assert [_summary, _failed, _fallback, resend] = settled_pool_requests!(setup, 4)
    assert_edge!(fallback, resend)
    assert FakeUpstream.count(upstream) == 4
  end

  # S5: two consecutive mailbox cuts of the continuation after an inline compaction.
  @tag slow: "drives an inline compaction, two cut mailbox resends and the final one through the HTTP route"
  test "S5 HTTP: two consecutive mailbox cuts after an inline compaction chain as successive successors" do
    thread = unique("thread-s5")
    turn = unique("turn-s5")
    first_delivered = commentary_item("msg_s5_commentary", status: true)
    first_done = %{"type" => "response.output_item.done", "output_index" => 0, "item" => first_delivered}
    second_delivered = reasoning_item("rs_s5_reasoning")
    second_done = %{"type" => "response.output_item.done", "output_index" => 0, "item" => second_delivered}
    undelivered = {"response.output_text.delta", %{"type" => "response.output_text.delta", "delta" => "not delivered"}}

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          completed_sse("resp_s5_open", [function_call("call_s5")]),
          completed_sse("resp_s5_summary", [final_answer("the summary")]),
          FakeUpstream.sse_stream([{"response.output_item.done", first_done}, undelivered], done: false),
          FakeUpstream.sse_stream([{"response.output_item.done", second_done}, undelivered], done: false),
          completed_sse("resp_s5_final", [final_answer("done")]),
          # Serves the identical resend of the successor.
          completed_sse("resp_s5_wrong", [])
        ])
      )

    setup = gateway_setup(upstream)
    session = unique("codex-session-s5")
    users = Enum.map(1..4, &user_message("request #{&1} of this thread"))

    assert response(post_http(setup, session, http_body(setup, users, metadata(thread, turn, 1, :turn))), 200) =~ "response.completed"
    summarisation = http_body(setup, users ++ [function_call("call_s5"), function_output("call_s5"), user_message(@summarization_prompt)], metadata(thread, turn, 1, {:compaction, "mid_turn"}))
    assert response(post_http(setup, session, summarisation), 200) =~ "response.completed"

    continuation = http_body(setup, users ++ [summary_message("half of the work is done")], metadata(thread, turn, 2, :turn))
    cut_http_turn!(setup, session, continuation, [{"response.output_item.done", first_done}])

    first_resend = append(continuation, [commentary_item("msg_s5_commentary"), mailbox_item("/root/alpha", 1), mailbox_item("/root/beta", 2)])
    cut_http_turn!(setup, session, first_resend, [{"response.output_item.done", second_done}])

    second_resend = append(first_resend, [second_delivered, mailbox_item("/root/alpha", 3)])
    assert response(post_http(setup, session, second_resend), 200) =~ "response.completed"

    assert [_open, _summary, cut, first, second] = rows = settled_pool_requests!(setup, 5)
    assert {claim_prefix(cut), cut.request_metadata["native_http_claim_arm"]} == {"codex-resume:", "post_compaction_resume"}
    assert {first.status, first.last_error_code, second.status} == {"failed", "client_disconnected", "succeeded"}
    assert Enum.map([first, second], &claim_prefix/1) == ["codex-request-retry:", "codex-request-retry:"]
    assert_edge!(cut, first)
    assert_edge!(first, second)
    assert_one_settlement_each!(rows)
    assert FakeUpstream.count(upstream) == 5

    # The first cut row already has its successor; the served one chains an identical resend.
    assert_http_duplicate!(setup, upstream, session, continuation)
    assert_http_chained!(setup, upstream, session, second_resend, second)
  end

  defp pre_turn_compaction!(continuation_expectation, fallback \\ []) do
    thread = unique("thread-s3")
    turn = unique("turn-s3")
    earlier = user_message("earlier task")
    mail = mailbox_item("/root/worker", 1)

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence(
          # The last expectation serves an identical websocket resend.
          [ws_expectation(completed_frames("resp_s3_summary"), forbidden: ["previous_response_id"]), continuation_expectation] ++
            fallback ++
            [ws_expectation(completed_frames("resp_s3_resend"))]
        )
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()
    summarisation = frame(setup, [earlier, final_answer("done"), mail, user_message(@summarization_prompt)], nil, metadata(thread, turn, 1, {:compaction, "pre_turn"}))
    assert ws_once(port, setup, thread, summarisation, 1) == {:admitted, "response.completed"}

    continuation = %{input: [earlier, summary_message("the worker was asked to finish"), mailbox_item("/root/worker", 2)], metadata: metadata(thread, turn, 2, :turn)}
    %{setup: setup, upstream: upstream, port: port, thread: thread, continuation: continuation}
  end

  defp http_fallback(setup, thread, %{input: input, metadata: metadata}) do
    response =
      build_conn()
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("session-id", thread)
      |> put_req_header("x-codex-window-id", window_id(thread, 2))
      |> put_req_header("x-codex-turn-metadata", metadata)
      |> put_req_header("content-type", "application/json")
      |> post(@endpoint_path, CodexPooler.JSON.encode!(%{"model" => setup.model.exposed_model_id, "input" => input, "client_metadata" => %{"x-codex-turn-metadata" => metadata}}))

    case CodexPooler.JSON.decode(response.resp_body) do
      {:ok, %{"error" => %{"code" => code}}} -> {response.status, code}
      {:ok, %{"id" => _id}} when response.status == 200 -> {:admitted, "response.completed"}
      other -> {response.status, other}
    end
  end

  # S6: a sub-agent's turn compacted remotely (`/compact`), then its resume cut
  # right after a reasoning item by mail from a peer sub-agent. The provider's
  # reasoning item carries fields the client's closed reasoning model drops, so
  # the client resends the item without them (production incident 2026-09-28
  # 14:35, HTTP SSE after a restart cut the websockets).
  @tag slow: "drives a remote compaction, a cut resume and a peer mailbox resend through the HTTP route"
  test "S6 HTTP: a resume cut after reasoning by a peer's mail after a remote compaction is served as one successor" do
    thread = unique("thread-s6")
    turn = unique("turn-s6")
    users = Enum.map(1..4, &user_message("request #{&1} of this thread"))
    history = users ++ [%{"type" => "compaction", "encrypted_content" => "synthetic-pivot"}]
    done = %{"type" => "response.output_item.done", "output_index" => 0, "item" => provider_reasoning_item("rs_s6_reasoning")}
    call = %{"type" => "custom_tool_call", "id" => "ctc_s6", "status" => "in_progress", "call_id" => "call_s6", "name" => "apply_patch", "input" => ""}

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_s6_compact", "object" => "response.compaction", "output" => history, "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}}),
          FakeUpstream.sse_stream([{"response.output_item.done", done}, {"response.output_item.added", %{"type" => "response.output_item.added", "output_index" => 1, "item" => call}}], done: false),
          completed_sse("resp_s6_successor", [final_answer("done")]),
          # Serves the identical resend of the successor.
          completed_sse("resp_s6_wrong", [])
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    session = unique("codex-session-s6")

    compaction = setup |> http_body(users ++ [%{"type" => "compaction_trigger"}], metadata(thread, turn, 1, {:remote_compaction, "mid_turn"}, "/root/worker_a")) |> Map.delete("stream")
    assert json_response(post_http(setup, session, compaction, @endpoint_path <> "/compact"), 200)["object"] == "response.compaction"

    resume = http_body(setup, history, metadata(thread, turn, 2, :turn, "/root/worker_a"))
    cut_http_turn!(setup, session, resume, [{"response.output_item.done", done}])

    mail = mailbox_item("/root/worker_b", 1, "/root/worker_a")
    resend = append(resume, [reasoning_item("rs_s6_reasoning"), mail])

    # A resend without the delivered item stays a duplicate.
    assert_http_duplicate!(setup, upstream, session, append(resume, [mail]))

    assert response(post_http(setup, session, resend), 200) =~ "response.completed"

    assert [compaction_row, cut_row, successor] = settled_pool_requests!(setup, 3)
    assert {claim_prefix(cut_row), cut_row.request_metadata["native_http_claim_arm"]} == {"codex-resume:", "post_compaction_resume"}
    assert {cut_row.status, cut_row.last_error_code} == {"failed", "client_disconnected"}
    assert {successor.status, claim_prefix(successor)} == {"succeeded", "codex-request-retry:"}
    assert_edge!(cut_row, successor)
    assert %Attempt{response_metadata: %{"native_http_resume_progress" => %{"output_item_done_count" => 1}}} = Repo.get_by!(Attempt, request_id: cut_row.id)
    assert_one_settlement_each!([compaction_row, cut_row, successor])
    assert FakeUpstream.count(upstream) == 3

    assert_http_chained!(setup, upstream, session, resend, successor)
  end

  # -- native HTTP -----------------------------------------------------------

  defp post_http(setup, session, body, path \\ @endpoint_path) do
    build_conn()
    |> put_req_header("authorization", setup.authorization)
    |> put_req_header("session-id", session)
    |> put_req_header("content-type", "application/json")
    |> post(path, CodexPooler.JSON.encode!(body))
  end

  defp assert_http_duplicate!(setup, upstream, session, body) do
    before = {length(pool_requests(setup)), settlements(setup), FakeUpstream.count(upstream)}
    assert %{"error" => %{"code" => "duplicate_turn"}} = json_response(post_http(setup, session, body), 409)
    assert {length(pool_requests(setup)), settlements(setup), FakeUpstream.count(upstream)} == before
  end

  # An identical resend inside its retry window is served as the successor of
  # the request it repeats.
  defp assert_http_chained!(setup, upstream, session, body, predecessor) do
    count = length(pool_requests(setup))
    dispatched = FakeUpstream.count(upstream)
    assert response(post_http(setup, session, body), 200) =~ "response.completed"
    resend = setup |> settled_pool_requests!(count + 1) |> List.last()
    assert resend.status == "succeeded"
    assert_edge!(predecessor, resend)
    assert_one_settlement_each!([resend])
    assert FakeUpstream.count(upstream) == dispatched + 1
  end

  # Streams `payload` through the gateway and drops the client right after the
  # SSE frames of `events` were written (the test adapter returns the whole
  # body written so far).
  defp cut_http_turn!(setup, session, payload, events) do
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    options = RequestOptions.build(%{codex_session: pool_session!(setup, session), upstream_endpoint: @endpoint_path, transport: "http_sse"}, @endpoint_path, payload) |> RequestOptions.capture_api_key_runtime_epoch(auth)
    assert {:ok, %{stream: stream}} = Gateway.execute(auth, @endpoint_path, payload, options)
    stream_conn = build_conn() |> put_resp_content_type("text/event-stream") |> send_chunked(200)
    {adapter, adapter_payload} = stream_conn.adapter
    closing = %{adapter: adapter, payload: adapter_payload, close_after: Enum.map_join(events, &sse_frame/1), closed?: false}
    assert {:ok, _closed} = stream.(%{stream_conn | adapter: {ClosingAdapter, closing}})
  end

  defp sse_frame({name, event}), do: "event: #{name}\ndata: " <> CodexPooler.JSON.encode!(event) <> "\n\n"

  defp pool_session!(setup, session_key),
    do: Repo.one!(from(s in CodexSession, where: s.pool_id == ^setup.pool.id and s.session_key == ^session_key))

  defp http_body(setup, input, metadata),
    do: %{"model" => setup.model.exposed_model_id, "stream" => true, "input" => input, "client_metadata" => %{"x-codex-turn-metadata" => metadata}}

  defp append(body, items), do: Map.update!(body, "input", &(&1 ++ items))

  defp completed_sse(response_id, output) do
    FakeUpstream.sse_stream(
      Enum.map(Enum.with_index(output), fn {item, index} -> {"response.output_item.done", %{"type" => "response.output_item.done", "output_index" => index, "item" => item}} end) ++
        [
          {"response.completed", %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => output, "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}}}}
        ]
    )
  end

  # -- websocket ---------------------------------------------------------------

  defp ws_expectation(respond, json \\ []),
    do: FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true] ++ json, respond: respond)

  # One frame on a fresh socket of the thread's window `window_number`.
  defp ws_once(port, setup, thread, payload, window_number \\ 2) do
    client = released_client_connect!(port, setup.authorization, thread, window_id(thread, window_number))

    try do
      {_client, outcome} = send_frame(client, payload)
      outcome
    after
      Mint.HTTP.close(client.conn)
    end
  end

  # Sends one frame and reads until its terminal frame.
  defp send_frame(client, payload) do
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, payload)
    {conn, websocket, outcome} = receive_outcome(conn, websocket, client.ref)
    {%{client | conn: conn, websocket: websocket}, outcome}
  end

  defp receive_outcome(conn, websocket, ref) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => "error", "status" => status, "error" => %{"code" => code}} -> {conn, websocket, {status, code}}
      %{"type" => "error"} = error -> {conn, websocket, {:error, error}}
      %{"type" => "response.completed" = type} -> {conn, websocket, {:admitted, type}}
      %{"type" => "response.failed" = type} = failed -> {conn, websocket, {type, get_in(failed, ["response", "error", "code"])}}
      %{"type" => _other} -> receive_outcome(conn, websocket, ref)
    end
  end

  defp receive_until!(conn, websocket, ref, type) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    if CodexPooler.JSON.decode!(text)["type"] == type, do: conn, else: receive_until!(conn, websocket, ref, type)
  end

  defp frame(setup, input, previous_response_id, metadata) do
    %{"type" => "response.create", "model" => setup.model.exposed_model_id, "stream" => true, "input" => input, "client_metadata" => %{"x-codex-turn-metadata" => metadata}}
    |> then(&if previous_response_id, do: Map.put(&1, "previous_response_id", previous_response_id), else: &1)
    |> CodexPooler.JSON.encode!()
  end

  defp completed_frames(response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => response_id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}}
      })
    ])
  end

  defp commentary_frames(response_id) do
    item = commentary_item("msg_s1ws_commentary", status: true)

    Enum.map(
      [
        %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.output_item.added", "output_index" => 0, "item" => Map.merge(item, %{"status" => "in_progress", "content" => []})},
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
        %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}
      ],
      &CodexPooler.JSON.encode!/1
    )
  end

  defp await_receipt!(request_id, deadline \\ System.monotonic_time(:millisecond) + @timeout_ms) do
    case Repo.all(from(a in Attempt, where: a.request_id == ^request_id)) do
      [%Attempt{response_metadata: %{"downstream_delivery" => %{} = receipt}}] ->
        receipt

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("no delivery receipt for #{request_id} within the budget"),
          else: Process.sleep(@poll_ms) && await_receipt!(request_id, deadline)
    end
  end

  defp await_settled!(request_id, deadline \\ System.monotonic_time(:millisecond) + @timeout_ms) do
    case Repo.all(from(r in Request, where: r.id == ^request_id and r.status not in ["accepted", "in_progress"])) do
      [%Request{} = request] ->
        request

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("request never settled"),
          else: Process.sleep(@poll_ms) && await_settled!(request_id, deadline)
    end
  end

  # -- shared ------------------------------------------------------------------

  defp settled_pool_requests!(setup, count, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @timeout_ms
    rows = pool_requests(setup)

    cond do
      length(rows) == count and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) ->
        rows

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected #{count} settled requests, got #{inspect(Enum.map(rows, & &1.status))}")

      true ->
        Process.sleep(@poll_ms)
        settled_pool_requests!(setup, count, deadline)
    end
  end

  defp pool_requests(setup),
    do: Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: [asc: r.admitted_at, asc: r.id]))

  defp settlements(setup) do
    Repo.aggregate(from(l in LedgerEntry, join: r in Request, on: r.id == l.request_id, where: r.pool_id == ^setup.pool.id and l.entry_kind == "settlement"), :count)
  end

  defp assert_one_settlement_each!(requests) do
    for %Request{id: id} <- requests do
      assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^id and l.entry_kind == "settlement"), :count) == 1
    end
  end

  defp assert_edge!(predecessor, successor) do
    assert successor.request_metadata["client_resend"]["predecessor_request_id"] == predecessor.id
    assert Repo.exists?(from(l in RequestClientRetryLink, where: l.predecessor_request_id == ^predecessor.id and l.successor_request_id == ^successor.id))
  end

  defp claim_prefix(%Request{correlation_id: correlation_id}) do
    Enum.find(["codex-turn:", "codex-request-retry:", "codex-request:", "codex-resume:", "codex-kind:", "client-retry-v1:"], :other, &String.starts_with?(correlation_id, &1))
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp window_id(thread, number), do: "#{thread}:#{number}"

  defp metadata(thread, turn, window_number, kind, agent_name \\ "/root") do
    document = %{
      "turn_id" => turn,
      "thread_id" => thread,
      "agent_name" => agent_name,
      "window_id" => window_id(thread, window_number),
      "context_window_id" => "00000000-0000-4000-8000-00000000#{window_number}b02",
      "window_number" => window_number
    }

    case kind do
      :turn ->
        Map.put(document, "request_kind", "turn")

      # `CompactionTurnMetadata` of a local inline compaction: implementation
      # `responses`, never a compaction trigger item in the input.
      {:compaction, phase} ->
        document
        |> Map.put("request_kind", "compaction")
        |> Map.put("compaction", %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses", "phase" => phase, "strategy" => "memento"})

      {:remote_compaction, phase} ->
        document
        |> Map.put("request_kind", "compaction")
        |> Map.put("compaction", %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses_compact", "phase" => phase})
    end
    |> CodexPooler.JSON.encode!()
  end

  defp user_message(text), do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}
  defp summary_message(summary), do: user_message(@summary_prefix <> "\n" <> summary)
  defp final_answer(text), do: %{"type" => "message", "role" => "assistant", "phase" => "final_answer", "content" => [%{"type" => "output_text", "text" => text}]}
  defp function_call(call_id), do: %{"type" => "function_call", "call_id" => call_id, "name" => "shell", "arguments" => "{}"}
  defp function_output(call_id), do: %{"type" => "function_call_output", "call_id" => call_id, "output" => "ok"}
  defp reasoning_item(id), do: %{"type" => "reasoning", "id" => id, "summary" => [], "encrypted_content" => "synthetic-reasoning"}

  # A reasoning item as the provider may push it: fields the client's closed
  # reasoning model drops, so it resends `reasoning_item/1`.
  defp provider_reasoning_item(id), do: Map.merge(reasoning_item(id), %{"status" => "completed", "content" => [], "provider_field" => "synthetic"})

  # As the provider streams it (`status: true`), or as the client resends it:
  # without the item's `status` and the part's `annotations` and `logprobs`.
  defp commentary_item(id, opts \\ []) do
    part = %{"type" => "output_text", "text" => "checking the workers"}
    part = if Keyword.get(opts, :status), do: Map.merge(part, %{"annotations" => [], "logprobs" => []}), else: part
    item = %{"type" => "message", "id" => id, "role" => "assistant", "phase" => "commentary", "content" => [part]}
    if Keyword.get(opts, :status), do: Map.put(item, "status", "completed"), else: item
  end

  defp mailbox_item(author, n, recipient \\ "/root"),
    do: %{"type" => "agent_message", "author" => author, "recipient" => recipient, "content" => [%{"type" => "input_text", "text" => "synthetic update #{n} from #{author}"}]}
end
