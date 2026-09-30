defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketInlineCompactionTest do
  # Codex 0.158 compacts a turn LOCALLY and inline, under the turn's own
  # `turn_id` (`compact.rs` `run_inline_auto_compact_task`): it sends a
  # summarisation request that declares `request_kind: "compaction"` on the
  # ordinary Responses route, with the history plus the summarisation prompt
  # and no compaction trigger item, then replaces the history with the earlier
  # user messages plus the summary as a USER message (`SUMMARY_PREFIX`,
  # `build_compacted_history`), advances the window and sends the turn's
  # continuation as full history with no anchor and no compaction item.
  #
  # Both requests are new requests of the turn. Before this suite both took the
  # turn's bare `codex-turn:` claim over websocket, so each met the turn's
  # earlier request and was refused `409 duplicate_turn` as a terminal
  # predecessor resend: the summarisation request of a mid-turn compaction
  # (production case A) and the continuation after a pre-turn compaction
  # (production case B), first over websocket and then over the HTTPS
  # fallback. A true resend of either is chained to it as its successor, like
  # any identical resend inside its retry window.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [released_client_connect!: 4]

  alias CodexPooler.Accounting.{Request, RequestClientRetryLink}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @moduletag capture_log: true

  # provenance: codex-rs/prompts/templates/compact/{prompt,summary_prefix}.md at rust-v0.158.0-alpha.2.
  @summarization_prompt "You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task."
  @summary_prefix "Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:"

  # `:complete` keeps every earlier user message in the replacement history.
  # `:truncated` is a long thread: `build_compacted_history` keeps only the most
  # recent user messages within its token budget, so the continuation carries no
  # more user messages than the opener did and cannot pass for a steered
  # request of the turn (findings#206 row 206-423).
  for history <- [:complete, :truncated] do
    @tag slow: "drives a turn, its mid-turn inline compaction, the continuation and two resends through the real public listener"
    test "a mid-turn inline compaction and its continuation are admitted, and resends of either are chained (case A, #{history})" do
      assert_mid_turn_compaction(unquote(history))
    end
  end

  defp assert_mid_turn_compaction(history) do
    thread = "thread-inline-a-#{System.unique_integer([:positive])}"
    turn = "turn-inline-a-#{System.unique_integer([:positive])}"
    user = user_message("fix the flaky test")
    older = user_message("an older request of this thread")
    {opening_input, retained} = if history == :complete, do: {[user], [user]}, else: {[older, user], [user]}
    call = %{"type" => "function_call", "call_id" => "call_a", "name" => "shell", "arguments" => "{}"}
    output = %{"type" => "function_call_output", "call_id" => "call_a", "output" => "ok"}

    upstream =
      start_upstream(
        # provenance: synthetic, shaped after Codex 0.158 rollout files of thread 01a0e4df turn 01a0e617.
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, forbidden: ["previous_response_id"]], respond: completed_frames("resp_a_open")),
          FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, equals: %{"previous_response_id" => "resp_a_open"}], respond: completed_frames("resp_a_tool")),
          FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, forbidden: ["previous_response_id"]], respond: completed_frames("resp_a_summary")),
          FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, forbidden: ["previous_response_id"]], respond: completed_frames("resp_a_continue")),
          FakeUpstream.expect_request(method: "WEBSOCKET", respond: completed_frames("resp_a_continue_resend")),
          FakeUpstream.expect_request(method: "WEBSOCKET", respond: completed_frames("resp_a_summary_resend"))
        ])
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()
    client = released_client_connect!(port, setup.authorization, thread, window_id(thread, 1))

    try do
      opener = frame(setup, opening_input, nil, metadata(thread, turn, 1, :turn))
      assert {client, {:admitted, "response.completed"}} = send_frame(client, opener)

      tool = frame(setup, [call, output], "resp_a_open", metadata(thread, turn, 1, :turn))
      assert {client, {:admitted, "response.completed"}} = send_frame(client, tool)

      summarisation = frame(setup, opening_input ++ [call, output, user_message(@summarization_prompt)], nil, metadata(thread, turn, 1, {:compaction, "mid_turn"}))
      assert {client, {:admitted, "response.completed"}} = send_frame(client, summarisation)
      Mint.HTTP.close(client.conn)

      # The window advanced with the compaction: a new socket and a new Pooler session.
      second = released_client_connect!(port, setup.authorization, thread, window_id(thread, 2))
      continuation = frame(setup, retained ++ [summary_message("fixed half of it")], nil, metadata(thread, turn, 2, :turn))
      assert {second, {:admitted, "response.completed"}} = send_frame(second, continuation)

      rows = settled_pool_requests!(setup.pool.id, 4)
      assert FakeUpstream.count(upstream) == 4

      assert [open_claim, tool_claim, summary_claim, continuation_claim] = Enum.map(rows, &claim_prefix/1)
      assert {open_claim, tool_claim, summary_claim, continuation_claim} == {"codex-turn:", "codex-request:", "codex-request:", "codex-resume:"}

      # A true resend of the continuation, and of the summarisation request on
      # its own window, is chained to the request it repeats.
      assert {second, {:admitted, "response.completed"}} = send_frame(second, continuation)
      Mint.HTTP.close(second.conn)

      third = released_client_connect!(port, setup.authorization, thread, window_id(thread, 1))
      assert {third, {:admitted, "response.completed"}} = send_frame(third, summarisation)
      Mint.HTTP.close(third.conn)

      assert [_open, _tool, summary_row, continuation_row, continuation_resend, summary_resend] = settled_pool_requests!(setup.pool.id, 6)
      assert_linked!(continuation_row, continuation_resend)
      assert_linked!(summary_row, summary_resend)
      assert FakeUpstream.count(upstream) == 6
    after
      Mint.HTTP.close(client.conn)
    end
  end

  for carrier <- [:websocket, :http] do
    @tag slow: "drives a pre-turn inline compaction, its continuation and a resend through the real public listener"
    test "the continuation of a turn opened by a pre-turn inline compaction is admitted and a resend is chained (case B, #{carrier})",
         %{conn: conn} do
      assert_pre_turn_continuation(conn, unquote(carrier))
    end
  end

  defp assert_pre_turn_continuation(conn, carrier) do
    thread = "thread-inline-b-#{System.unique_integer([:positive])}"
    turn = "turn-inline-b-#{System.unique_integer([:positive])}"
    earlier = user_message("earlier task")
    answer = %{"type" => "message", "role" => "assistant", "phase" => "final_answer", "content" => [%{"type" => "output_text", "text" => "done"}]}
    mailbox = %{"type" => "agent_message", "author" => "/root/worker", "recipient" => "/root", "content" => [%{"type" => "input_text", "text" => "worker finished"}]}

    upstream =
      start_upstream(
        # provenance: synthetic, shaped after Codex 0.158 rollout files of thread 01a0e4df turn 01a0e619.
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, forbidden: ["previous_response_id"]], respond: completed_frames("resp_b_summary")),
          continuation_expectation(carrier, "resp_b_continue"),
          continuation_expectation(carrier, "resp_b_resend")
        ])
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()
    client = released_client_connect!(port, setup.authorization, thread, window_id(thread, 1))

    try do
      summarisation =
        frame(setup, [earlier, answer, mailbox, user_message(@summarization_prompt)], nil, metadata(thread, turn, 1, {:compaction, "pre_turn"}))

      assert {client, {:admitted, "response.completed"}} = send_frame(client, summarisation)
      Mint.HTTP.close(client.conn)

      input = [earlier, summary_message("the worker was asked to finish"), mailbox]
      continuation_metadata = metadata(thread, turn, 2, :turn)

      assert send_continuation(conn, port, setup, thread, carrier, input, continuation_metadata) == {:admitted, "response.completed"}

      rows = settled_pool_requests!(setup.pool.id, 2)
      assert FakeUpstream.count(upstream) == 2
      assert Enum.map(rows, &claim_prefix/1) == ["codex-request:", "codex-resume:"]

      assert send_continuation(conn, port, setup, thread, carrier, input, continuation_metadata) == {:admitted, "response.completed"}
      assert [_summary, continuation_row, resend] = settled_pool_requests!(setup.pool.id, 3)
      assert_linked!(continuation_row, resend)
      assert FakeUpstream.count(upstream) == 3
    after
      Mint.HTTP.close(client.conn)
    end
  end

  defp send_continuation(_conn, port, setup, thread, :websocket, input, metadata) do
    client = released_client_connect!(port, setup.authorization, thread, window_id(thread, 2))

    try do
      {_client, outcome} = send_frame(client, frame(setup, input, nil, metadata))
      outcome
    after
      Mint.HTTP.close(client.conn)
    end
  end

  defp send_continuation(conn, _port, setup, thread, :http, input, metadata) do
    response =
      conn
      |> recycle()
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("session-id", thread)
      |> put_req_header("x-codex-window-id", window_id(thread, 2))
      |> put_req_header("x-codex-turn-metadata", metadata)
      |> post("/backend-api/codex/responses", %{"model" => setup.model.exposed_model_id, "input" => input, "client_metadata" => %{"x-codex-turn-metadata" => metadata}})

    case CodexPooler.JSON.decode(response.resp_body) do
      {:ok, %{"error" => %{"code" => code}}} -> {response.status, code}
      {:ok, %{"id" => _id}} when response.status == 200 -> {:admitted, "response.completed"}
      other -> {response.status, other}
    end
  end

  defp continuation_expectation(:websocket, response_id),
    do: FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, forbidden: ["previous_response_id"]], respond: completed_frames(response_id))

  defp continuation_expectation(:http, response_id),
    do: FakeUpstream.expect_request(method: "POST", respond: FakeUpstream.json_response(%{"id" => response_id, "status" => "completed", "output" => []}))

  defp user_message(text), do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}

  defp summary_message(summary), do: user_message(@summary_prefix <> "\n" <> summary)

  defp claim_prefix(%Request{correlation_id: correlation_id}) do
    Enum.find(["codex-turn:", "codex-request:", "codex-resume:", "codex-kind:"], :other, &String.starts_with?(correlation_id, &1))
  end

  # Sends one frame and reads until its terminal frame: a completed turn yields
  # `response.created` then `response.completed`, a refusal one error frame.
  defp send_frame(client, payload) do
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, payload)
    {conn, websocket, outcome} = receive_outcome(conn, websocket, client.ref)
    {%{client | conn: conn, websocket: websocket}, outcome}
  end

  defp receive_outcome(conn, websocket, ref) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(frame) do
      %{"type" => "error", "status" => status, "error" => %{"code" => code}} -> {conn, websocket, {status, code}}
      %{"type" => "response.completed" = type} -> {conn, websocket, {:admitted, type}}
      %{"type" => _other} -> receive_outcome(conn, websocket, ref)
    end
  end

  @settlement_budget_ms 15_000

  defp settled_pool_requests!(pool_id, count) do
    deadline = System.monotonic_time(:millisecond) + @settlement_budget_ms
    await_settled_pool_requests(pool_id, count, deadline)
  end

  defp await_settled_pool_requests(pool_id, count, deadline) do
    rows = Repo.all(from(r in Request, where: r.pool_id == ^pool_id, order_by: [asc: r.admitted_at, asc: r.id]))

    cond do
      length(rows) == count and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) ->
        rows

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected #{count} settled requests, got #{inspect(Enum.map(rows, & &1.status))}")

      true ->
        Process.sleep(10)
        await_settled_pool_requests(pool_id, count, deadline)
    end
  end

  defp assert_linked!(predecessor, successor) do
    assert successor.request_metadata["client_resend"]["predecessor_request_id"] == predecessor.id
    assert Repo.exists?(from(l in RequestClientRetryLink, where: l.predecessor_request_id == ^predecessor.id and l.successor_request_id == ^successor.id))
  end

  defp frame(setup, input, previous_response_id, metadata) do
    %{"type" => "response.create", "model" => setup.model.exposed_model_id, "stream" => true, "input" => input, "client_metadata" => %{"x-codex-turn-metadata" => metadata}}
    |> then(&if previous_response_id, do: Map.put(&1, "previous_response_id", previous_response_id), else: &1)
    |> CodexPooler.JSON.encode!()
  end

  defp window_id(thread, number), do: "#{thread}:#{number}"

  defp metadata(thread, turn, window_number, kind) do
    document = %{
      "turn_id" => turn,
      "thread_id" => thread,
      "agent_name" => "/root",
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
    end
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
end
