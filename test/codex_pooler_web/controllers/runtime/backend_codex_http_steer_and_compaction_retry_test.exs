defmodule CodexPoolerWeb.Runtime.BackendCodexHttpSteerAndCompactionRetryTest do
  # Two requests the released Codex client (0.156.1, and Desktop 0.155.0-alpha.16.3)
  # sends over native HTTP once a session has fallen back from websockets to
  # HTTPS, which it does for the rest of the session:
  #
  #   * user input steered into a running turn is drained into the SAME turn,
  #     under the same `turn_id`, before the next model request
  #     (`session/turn_input.rs` `steer_input` returns the active turn's id,
  #     `session/turn.rs` drains pending input at the top of the sampling loop,
  #     and right after a mid-turn compaction when the model needed no follow-up:
  #     `can_drain_pending_input = !model_needs_follow_up`). That request ends
  #     with a user message and derived the turn's own `codex-turn:` claim, so it
  #     was refused `409 duplicate_turn` (findings#206 row 206-403);
  #   * a remote compaction whose `response.completed` the client never read is
  #     retried with the same prompt, up to twice (`compact_remote_v2.rs`
  #     `MAX_REMOTE_COMPACTION_V2_STREAM_RETRIES`); the retry met its own claim
  #     and was refused, and three refusals fail the turn and lose the compaction
  #     (findings#206 row 206-404).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @moduletag capture_log: true

  @session_header "session-id"
  @metadata_key "x-codex-turn-metadata"
  @lite_header "x-openai-internal-codex-responses-lite"

  for mode <- ["full", "lite"] do
    @mode mode

    test "a steer drained right after a mid-turn compaction is served as a later request of its turn, and its resend is refused (#{mode})",
         %{conn: conn} do
      upstream = start_upstream(FakeUpstream.strict_sequence([turn_sse("resp_open"), compaction_sse("resp_compaction"), turn_sse("resp_steer")]))
      setup = setup!(upstream, @mode)
      ids = ids()

      open = native_text_input("open the turn")
      assert response(post(conn, setup, ids, "turn", open), 200)
      assert response(post(conn, setup, ids, "compaction", open ++ [assistant("working"), %{"type" => "compaction_trigger"}]), 200)

      steered = open ++ [compaction_item("mid-turn"), user("steer the running turn")]
      assert response(post(conn, setup, ids, "turn", steered, 1), 200)

      # The steered request rebuilt for a retry: model output appended, the
      # user's progress unchanged. It is the same request and stays fenced.
      assert %{"error" => %{"code" => "duplicate_turn"}} =
               json_response(post(conn, setup, ids, "turn", steered ++ [assistant("partial answer")], 1), 409)

      assert FakeUpstream.count(upstream) == 3

      assert [
               {"codex-turn", "opening", "succeeded"},
               {"codex-request", "compaction", "succeeded"},
               {"codex-resume", "steered_continuation", "succeeded"}
             ] = rows(setup)
    end

    test "an HTTP compaction whose reply the client never read is chained on each of its retries (#{mode})", %{conn: conn} do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            turn_sse("resp_open"),
            compaction_sse("resp_compaction_one"),
            compaction_sse("resp_compaction_two"),
            compaction_sse("resp_compaction_three")
          ])
        )

      setup = setup!(upstream, @mode)
      ids = ids()
      open = native_text_input("open the turn")
      compaction = open ++ [assistant("working"), %{"type" => "compaction_trigger"}]

      assert response(post(conn, setup, ids, "turn", open), 200)

      # The client's first attempt and its two retries with the same prompt.
      for _attempt <- 1..3, do: assert(response(post(conn, setup, ids, "compaction", compaction), 200))

      assert FakeUpstream.count(upstream) == 4
      assert [_open, first, second, third] = pool_requests(setup)
      assert Enum.map([first, second, third], & &1.request_metadata["native_http_claim_arm"]) == ["compaction", "compaction", "compaction"]
      assert String.starts_with?(first.correlation_id, "codex-request:")

      # Each retry is one successor of the attempt before it, with its own
      # single settlement.
      assert second.request_metadata["client_resend"] == %{"predecessor_request_id" => first.id, "reason" => "failed_predecessor"}
      assert third.request_metadata["client_resend"] == %{"predecessor_request_id" => second.id, "reason" => "failed_predecessor"}

      for request <- [first, second, third] do
        assert Repo.aggregate(from(e in LedgerEntry, where: e.request_id == ^request.id and e.entry_kind == "settlement"), :count) == 1
      end
    end
  end

  test "a steer into an uncompacted turn is served, while a rebuilt retry of the opener stays refused", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.strict_sequence([turn_sse("resp_open"), turn_sse("resp_steer")]))
    setup = setup!(upstream, "full")
    ids = ids()
    open = native_text_input("open the turn")

    assert response(post(conn, setup, ids, "turn", open), 200)

    # Control: the opener rebuilt with its delivered answer is not a steer.
    assert %{"error" => %{"code" => "duplicate_turn"}} =
             json_response(post(conn, setup, ids, "turn", open ++ [assistant("delivered answer")]), 409)

    steered = open ++ [assistant("delivered answer"), user("steer the running turn")]
    assert response(post(conn, setup, ids, "turn", steered), 200)

    assert %{"error" => %{"code" => "duplicate_turn"}} = json_response(post(conn, setup, ids, "turn", steered), 409)
    assert FakeUpstream.count(upstream) == 2
    assert [{"codex-turn", "opening", "succeeded"}, {"codex-resume", "steered_continuation", "succeeded"}] = rows(setup)
  end

  defp setup!(upstream, mode) do
    setup = gateway_setup(upstream, compact?: true)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
    Map.put(setup, :serving_mode, mode)
  end

  defp ids, do: %{turn: "turn-" <> unique_suffix(), thread: Ecto.UUID.generate()}

  # The released client's HTTP request (P69 wire capture of 0.156.1): a JSON
  # body carrying the canonical document, `stream: true`, the document echoed
  # as `x-codex-turn-metadata`, the thread as `session-id`, the current window
  # as `x-codex-window-id`, and in Lite the marker moved to a header. The window
  # advances after every compaction the client completes.
  defp post(conn, setup, ids, kind, input, window \\ 0) do
    document =
      CodexPooler.JSON.encode!(%{
        "session_id" => ids.thread,
        "thread_id" => ids.thread,
        "turn_id" => ids.turn,
        "window_id" => "#{ids.thread}:#{window}",
        "request_kind" => kind
      })

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => input,
      "stream" => true,
      "client_metadata" => %{@metadata_key => document}
    }

    conn
    |> recycle()
    |> auth(setup)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "text/event-stream")
    |> put_req_header(@session_header, ids.thread)
    |> put_req_header("thread-id", ids.thread)
    |> put_req_header("x-codex-window-id", "#{ids.thread}:#{window}")
    |> put_req_header(@metadata_key, document)
    |> put_req_header("originator", "codex_cli_rs")
    |> then(&if setup.serving_mode == "lite", do: put_req_header(&1, @lite_header, "true"), else: &1)
    |> post("/backend-api/codex/responses", CodexPooler.JSON.encode!(payload))
  end

  defp turn_sse(id) do
    FakeUpstream.sse_stream([
      {"response.completed", %{"type" => "response.completed", "response" => %{"id" => id, "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}}}}
    ])
  end

  defp compaction_sse(id) do
    FakeUpstream.compaction_stream(%{
      "id" => id,
      "output" => [compaction_item(id)],
      "usage" => %{"input_tokens" => 5, "output_tokens" => 2, "total_tokens" => 7}
    })
  end

  defp user(text), do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}
  defp assistant(text), do: %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => text}]}
  defp compaction_item(label), do: %{"type" => "compaction", "encrypted_content" => "synthetic-compaction-" <> label}

  defp pool_requests(setup), do: Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id, order_by: r.admitted_at))

  defp rows(setup) do
    for request <- pool_requests(setup) do
      {request.correlation_id |> String.split(":") |> hd(), request.request_metadata["native_http_claim_arm"], request.status}
    end
  end
end
