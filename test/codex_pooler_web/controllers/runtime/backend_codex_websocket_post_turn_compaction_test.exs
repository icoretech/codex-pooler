defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketPostTurnCompactionTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [cleanup_local_owner_sessions: 0]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo

  # Codex rust-v0.156.0 (openai/codex#46541) runs an opt-in compaction right
  # after the final answer when `model_post_turn_compact_threshold_percent` is
  # reached: on the same socket and under the same turn id as the turn it
  # follows, a `response.create` anchored on that turn's response with
  # `[compaction_trigger]` as its only input and turn metadata
  # `request_kind: compaction`, `phase: post_turn`. The frames below keep the
  # key sets and enum values the released binary sent to a loopback capture
  # server (both samples identical); identifiers and prompt text are synthetic.
  @session_id "019a0000-0000-7000-8000-00000000a001"
  @thread_id "019a0000-0000-7000-8000-00000000a002"
  @installation_id "00000000-0000-4000-8000-00000000a003"
  @context_window_id "00000000-0000-4000-8000-00000000a004"
  @turn_id "019a0000-0000-7000-8000-00000000a005"
  @window_id "#{@thread_id}:0"
  @anchor_response_id "resp_post_turn_anchor_000001"
  @compact_response_id "resp_post_turn_compact_000001"
  @resumed_turn_id "019a0000-0000-7000-8000-00000000a006"
  @resumed_window_id "#{@thread_id}:1"
  @resumed_response_id "resp_post_turn_resumed_00001"

  for topology <- [:direct, :owner_forwarded] do
    @tag topology: topology
    test "#{topology} socket admits the released client's post_turn compaction on the completed turn's connection",
         %{topology: topology} do
      put_owner_forwarding!(topology == :owner_forwarded)
      compact_item = %{"type" => "compaction", "encrypted_content" => "synthetic-post-turn-#{topology}"}

      upstream =
        start_upstream(
          # Strict finite scenario: the ordinary turn and its post-turn compact
          # are the only sends, both on the first physical connection; the
          # compact keeps the turn's response as its anchor.
          # provenance: observed rust-v0.156.0 released-binary frame shape; reply frames synthetic
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              websocket_connection_ordinal: 1,
              json: [
                valid: true,
                equals: %{"type" => "response.create"},
                forbidden: ["previous_response_id"]
              ],
              respond: completed_frames(@anchor_response_id)
            ),
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              websocket_connection_ordinal: 1,
              json: [
                valid: true,
                equals: %{
                  "type" => "response.create",
                  "previous_response_id" => @anchor_response_id,
                  "input.0.type" => "compaction_trigger"
                }
              ],
              respond: compaction_frames(compact_item)
            )
          ])
        )

      setup = gateway_setup(upstream, compact?: true)
      port = start_public_endpoint!()

      {conn, websocket, ref, _headers} =
        public_websocket_connect_with_request_headers!(
          port,
          setup,
          "post-turn-#{topology}",
          "/backend-api/codex/responses",
          [{"session-id", @session_id}, {"thread-id", @thread_id}, {"x-client-request-id", @thread_id}]
        )

      try do
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, turn_frame(setup))
        {conn, websocket, created} = public_websocket_receive_text!(conn, websocket, ref)
        {conn, websocket, completed} = public_websocket_receive_text!(conn, websocket, ref)

        assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(created)

        assert %{"type" => "response.completed", "response" => %{"id" => @anchor_response_id}} =
                 CodexPooler.JSON.decode!(completed)

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, post_turn_frame(setup))
        {conn, websocket, done} = public_websocket_receive_text!(conn, websocket, ref)
        assert CodexPooler.JSON.decode!(done) == %{"type" => "response.output_item.done", "item" => compact_item}
        {_conn, _websocket, terminal} = public_websocket_receive_text!(conn, websocket, ref)

        assert %{"type" => "response.completed", "response" => %{"status" => "completed", "output" => [^compact_item]}} =
                 CodexPooler.JSON.decode!(terminal)

        assert [turn_request, compact_request] = FakeUpstream.requests(upstream)
        assert compact_request.websocket_connection_id == turn_request.websocket_connection_id
        assert compact_request.json["input"] == [%{"type" => "compaction_trigger"}]

        compact_row =
          Repo.one!(
            from(request in Request,
              where: request.pool_id == ^setup.pool.id and request.endpoint == "/backend-api/codex/responses/compact"
            )
          )

        assert compact_row.status == "succeeded"
        assert compact_row.transport == "websocket"
        assert [compact_attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^compact_row.id))
        assert compact_attempt.status == "succeeded"
        assert compact_attempt.pool_upstream_assignment_id == setup.assignment.id

        assert Repo.aggregate(
                 from(entry in LedgerEntry, where: entry.request_id == ^compact_row.id and entry.entry_kind == "settlement"),
                 :count
               ) == 1

        assert [%CodexTurn{status: "succeeded"}] = Repo.all(from(turn in CodexTurn, where: turn.request_id == ^compact_row.id))
        assert :ok = FakeUpstream.verify!(upstream)
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  # `codex exec resume --last` after a post-turn compaction: the first socket is
  # gone (the client exited after the compaction), a new socket on the same
  # thread with the rotated window prewarms, then sends the next turn carrying
  # the compaction item. The owner left `pending_final` behind on detach; the
  # resumed turn must be admitted on a new upstream connection with the
  # compaction item and without the old anchor (findings#258 row 258-26; the
  # released-client run on one node with owner forwarding was the only
  # evidence). The resumed frames keep the key sets the released 0.156.0
  # binary sent; through the Pooler its upstream frame carried no
  # previous_response_id, as here.
  for topology <- [:direct, :owner_forwarded] do
    @tag topology: topology
    test "#{topology} post-turn compaction, client exit and resume on a new socket admits the compacted turn", %{topology: topology} do
      put_owner_forwarding!(topology == :owner_forwarded)
      compact_item = %{"type" => "compaction", "encrypted_content" => "synthetic-post-turn-resume-#{topology}"}

      upstream =
        start_upstream(
          # provenance: observed rust-v0.156.0 released-binary exec + resume frame shapes; reply frames synthetic
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true, equals: %{"type" => "response.create"}], respond: completed_frames(@anchor_response_id)),
            FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true, equals: %{"type" => "response.create", "input.0.type" => "compaction_trigger"}], respond: compaction_frames(compact_item)),
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              websocket_connection_ordinal: 2,
              json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]],
              respond: completed_frames(@resumed_response_id)
            )
          ])
        )

      setup = gateway_setup(upstream, compact?: true)
      port = start_public_endpoint!()
      {first_conn, _websocket, _ref} = post_turn_compacted_socket!(port, setup, "post-turn-resume-#{topology}")
      Mint.HTTP.close(first_conn)

      {conn, websocket, ref, _headers} =
        public_websocket_connect_with_request_headers!(
          port,
          setup,
          "post-turn-resume-second-#{topology}",
          "/backend-api/codex/responses",
          [{"session-id", @session_id}, {"thread-id", @thread_id}, {"x-client-request-id", @thread_id}, {"x-codex-window-id", @resumed_window_id}]
        )

      try do
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, resume_prewarm_frame(setup))
        {conn, websocket, prewarm_created} = public_websocket_receive_text!(conn, websocket, ref)
        {conn, websocket, prewarm_completed} = public_websocket_receive_text!(conn, websocket, ref)
        assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(prewarm_created)
        assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(prewarm_completed)

        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, resumed_turn_frame(setup, compact_item))
        {conn, websocket, created} = public_websocket_receive_text!(conn, websocket, ref)
        {_conn, _websocket, completed} = public_websocket_receive_text!(conn, websocket, ref)
        assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(created)
        assert %{"type" => "response.completed", "response" => %{"id" => @resumed_response_id}} = CodexPooler.JSON.decode!(completed)

        assert [first_turn, compact, resumed] = FakeUpstream.requests(upstream)
        assert compact.websocket_connection_id == first_turn.websocket_connection_id
        assert resumed.websocket_connection_id != first_turn.websocket_connection_id
        assert compact_item in resumed.json["input"]

        assert await_settled_rows!(setup) == [
                 {"/backend-api/codex/responses", "websocket", "succeeded"},
                 {"/backend-api/codex/responses/compact", "websocket", "succeeded"},
                 {"/backend-api/codex/responses", "websocket", "succeeded"}
               ]

        assert :ok = FakeUpstream.verify!(upstream)
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  # After a post-turn compaction the owner keeps the native compaction
  # admission in `pending_final` for the next turn. The released client then
  # exits, and the detach clears that admission; its lifecycle observation must
  # name the detach, not `request_rejected` (findings#258 row 258-23, seen in
  # every real-client arm of the 0.156.0 post-turn run).
  test "owner_forwarded socket close after a post-turn compaction clears the admission as a downstream detach" do
    put_owner_forwarding!(true)
    compact_item = %{"type" => "compaction", "encrypted_content" => "synthetic-post-turn-detach"}

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true, equals: %{"type" => "response.create"}], respond: completed_frames(@anchor_response_id)),
          FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true, equals: %{"type" => "response.create", "input.0.type" => "compaction_trigger"}], respond: compaction_frames(compact_item))
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    port = start_public_endpoint!()
    {conn, websocket, ref} = post_turn_compacted_socket!(port, setup, "post-turn-detach")

    [session] = Repo.all(from(session in CodexSession, where: session.pool_id == ^setup.pool.id))
    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(session.id)
    # The lifecycle observation is a debug line of the owner module; raise
    # only that module's level, restored before the next test.
    on_exit(fn -> Logger.delete_module_level(WebsocketOwnerSession) end)
    :ok = Logger.put_module_level(WebsocketOwnerSession, :debug)

    log =
      capture_log([level: :debug], fn ->
        _websocket = websocket
        _ref = ref
        Mint.HTTP.close(conn)
        await_owner_detached!(owner_pid)
      end)

    Logger.delete_module_level(WebsocketOwnerSession)

    clears = log |> String.split("\n") |> Enum.filter(&(&1 =~ "native compaction lifecycle" and &1 =~ "operation: :clear"))
    assert Enum.any?(clears, &(&1 =~ "reason: :downstream_detached" and &1 =~ "phase_from: :pending_final")), inspect(clears)
    refute Enum.any?(clears, &(&1 =~ "reason: :request_rejected"))
  end

  defp post_turn_compacted_socket!(port, setup, turn_state) do
    {conn, websocket, ref, _headers} =
      public_websocket_connect_with_request_headers!(
        port,
        setup,
        turn_state,
        "/backend-api/codex/responses",
        [{"session-id", @session_id}, {"thread-id", @thread_id}, {"x-client-request-id", @thread_id}, {"x-codex-window-id", @window_id}]
      )

    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, turn_frame(setup))
    {conn, websocket, _created} = public_websocket_receive_text!(conn, websocket, ref)
    {conn, websocket, _completed} = public_websocket_receive_text!(conn, websocket, ref)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, post_turn_frame(setup))
    {conn, websocket, _done} = public_websocket_receive_text!(conn, websocket, ref)
    {conn, websocket, terminal} = public_websocket_receive_text!(conn, websocket, ref)
    assert %{"type" => "response.completed", "response" => %{"status" => "completed"}} = CodexPooler.JSON.decode!(terminal)
    {conn, websocket, ref}
  end

  # The socket detaches from the owner in its terminate callback; the owner's
  # downstream becomes nil once the detach call ran (authoritative state, no
  # completion signal to wait on).
  defp await_owner_detached!(owner_pid) do
    deadline = System.monotonic_time(:millisecond) + 15_000

    Stream.repeatedly(fn -> :sys.get_state(owner_pid).downstream end)
    |> Enum.reduce_while(nil, fn
      nil, _acc ->
        {:halt, :ok}

      _attached, _acc ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("owner never saw the downstream detach")
        Process.sleep(10)
        {:cont, nil}
    end)
  end

  defp put_owner_forwarding!(enabled?) do
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled?)

    on_exit(fn ->
      if enabled?, do: cleanup_local_owner_sessions()

      case previous do
        :error -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        {:ok, value} -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  defp turn_frame(setup) do
    setup
    |> frame([%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic post-turn prompt"}]}])
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(:turn))
    |> CodexPooler.JSON.encode!()
  end

  # The shared websocket receive helper drops every non-socket message, so the
  # request events cannot be awaited; the rows are the authority (bounded poll,
  # no completion signal survives the receive loop).
  defp await_settled_rows!(setup) do
    await_settled_rows!(setup, System.monotonic_time(:millisecond) + 15_000)
  end

  defp await_settled_rows!(setup, deadline) do
    rows =
      Repo.all(
        from(request in Request,
          where: request.pool_id == ^setup.pool.id,
          order_by: request.admitted_at,
          select: {request.endpoint, request.transport, request.status}
        )
      )

    if Enum.any?(rows, &match?({_endpoint, _transport, "in_progress"}, &1)) and
         System.monotonic_time(:millisecond) <= deadline do
      Process.sleep(10)
      await_settled_rows!(setup, deadline)
    else
      rows
    end
  end

  # The resumed process's prewarm on the rotated window: no input, no
  # generation, prewarm turn metadata.
  defp resume_prewarm_frame(setup) do
    setup
    |> frame([])
    |> Map.put("generate", false)
    |> put_in(["client_metadata", "turn_id"], @resumed_turn_id)
    |> put_in(["client_metadata", "root_turn_id"], @resumed_turn_id)
    |> put_in(["client_metadata", "x-codex-window-id"], @resumed_window_id)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(:resume_prewarm))
    |> CodexPooler.JSON.encode!()
  end

  # The resumed turn replays the history with the compaction item in place of
  # what it compacted, under a new turn id on the rotated window.
  defp resumed_turn_frame(setup, compact_item) do
    history = [
      %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic post-turn prompt"}]},
      compact_item,
      %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic resumed prompt"}]}
    ]

    setup
    |> frame(history)
    |> put_in(["client_metadata", "turn_id"], @resumed_turn_id)
    |> put_in(["client_metadata", "root_turn_id"], @resumed_turn_id)
    |> put_in(["client_metadata", "x-codex-window-id"], @resumed_window_id)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(:resumed_turn))
    |> CodexPooler.JSON.encode!()
  end

  defp post_turn_frame(setup) do
    setup
    |> frame([%{"type" => "compaction_trigger"}])
    |> Map.put("previous_response_id", @anchor_response_id)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(:post_turn_compaction))
    |> CodexPooler.JSON.encode!()
  end

  # Top-level keys of the released client's websocket `response.create`
  # (prewarm aside, it sends no `generate`).
  defp frame(setup, input) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "input" => input,
      "tools" => [],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "reasoning" => %{"effort" => "low"},
      "store" => false,
      "stream" => true,
      "include" => ["reasoning.encrypted_content"],
      "text" => %{"verbosity" => "low"},
      "prompt_cache_key" => @thread_id,
      "client_metadata" => %{
        "session_id" => @session_id,
        "thread_id" => @thread_id,
        "turn_id" => @turn_id,
        "root_turn_id" => @turn_id,
        "x-codex-installation-id" => @installation_id,
        "x-codex-window-id" => @window_id,
        "x-codex-ws-stream-request-start-ms" => "1790000000000"
      }
    }
  end

  defp turn_metadata(:turn) do
    common_turn_metadata()
    |> Map.merge(%{"request_kind" => "turn", "model" => "gpt-test-model", "reasoning_effort" => "low"})
    |> CodexPooler.JSON.encode!()
  end

  defp turn_metadata(:post_turn_compaction) do
    common_turn_metadata()
    |> Map.merge(%{
      "request_kind" => "compaction",
      "compaction" => %{
        "trigger" => "auto",
        "reason" => "context_limit",
        "implementation" => "responses_compaction_v2",
        "phase" => "post_turn",
        "strategy" => "memento"
      }
    })
    |> CodexPooler.JSON.encode!()
  end

  defp turn_metadata(:resume_prewarm) do
    common_turn_metadata()
    |> Map.drop(["root_turn_id", "turn_started_at_unix_ms", "turn_trigger"])
    |> Map.merge(resumed_window_metadata())
    |> Map.merge(%{"request_kind" => "prewarm", "model" => "gpt-test-model", "reasoning_effort" => "low"})
    |> CodexPooler.JSON.encode!()
  end

  defp turn_metadata(:resumed_turn) do
    common_turn_metadata()
    |> Map.merge(resumed_window_metadata())
    |> Map.merge(%{"request_kind" => "turn", "root_turn_id" => @resumed_turn_id, "model" => "gpt-test-model", "reasoning_effort" => "low"})
    |> CodexPooler.JSON.encode!()
  end

  defp resumed_window_metadata, do: %{"turn_id" => @resumed_turn_id, "window_id" => @resumed_window_id, "window_number" => 1}

  defp common_turn_metadata do
    %{
      "agent_name" => "/root",
      "analytics_enabled" => true,
      "auto_review_enabled" => false,
      "context_window_id" => @context_window_id,
      "installation_id" => @installation_id,
      "node_repl_auto_review_required" => false,
      "node_repl_disabled" => false,
      "root_turn_id" => @turn_id,
      "sandbox" => "seccomp",
      "sandbox_mode" => "read-only",
      "session_id" => @session_id,
      "thread_id" => @thread_id,
      "thread_source" => "user",
      "turn_id" => @turn_id,
      "turn_started_at_unix_ms" => 1_790_000_000_000,
      "turn_trigger" => "exec",
      "window_id" => @window_id,
      "window_number" => 0
    }
  end

  defp completed_frames(response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "id" => response_id,
          "status" => "completed",
          "output" => [],
          "usage" => %{"input_tokens" => 20_000, "output_tokens" => 1, "total_tokens" => 20_001}
        }
      })
    ])
  end

  defp compaction_frames(item) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => item}),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => @compact_response_id, "status" => "completed", "output" => [item]}
      })
    ])
  end
end
