defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketCompactionBookkeepingRefusalTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [cleanup_local_owner_sessions: 0]

  alias CodexPooler.Accounting.{LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  # Production request `ab3c4d98` (findings#206 rows 206-273 and 206-284):
  # a second socket of one window attached to the owner while the first was
  # still attached, and opened the next turn with an anchored, incremental
  # websocket compaction on the owner's live upstream connection. Nothing had
  # armed a native compaction admission for that socket, so the compact took
  # the new turn's ordinary claim and ran without owner provenance; the
  # provider served it and the attempt settled `succeeded`, and only the
  # Pooler's confirmation of it (the owner's `pending_final`) could not be
  # recorded: `missing_confirmation_provenance`. The same shape answers the
  # same way with and without the replacement-attach admission clear of
  # `c367a8b5a`.
  #
  # The refusal is kept although the compact was billed. Delivering the item
  # instead would not spare the second compaction: without `pending_final` the
  # turn that carries the item meets the compaction's own turn claim and is
  # refused `409 duplicate_turn`, which the released client does not retry,
  # exactly as it is here right after the refusal. On the generic 502 the
  # client in production redid the compaction over HTTP and finished the turn
  # there (findings#206 row 206-284). Frames keep the released client's
  # upgrade headers and key sets; identifiers, prompt text and reply frames
  # are synthetic.
  @thread_id "019a0000-0000-7000-8000-00000000d001"
  @window_id "#{@thread_id}:0"
  @resumed_window_id "#{@thread_id}:1"
  @turn_id "019a0000-0000-7000-8000-00000000d002"
  @next_turn_id "019a0000-0000-7000-8000-00000000d006"
  @installation_id "00000000-0000-4000-8000-00000000d003"
  @context_window_id "00000000-0000-4000-8000-00000000d004"
  @resumed_context_window_id "00000000-0000-4000-8000-00000000d005"
  @anchor "resp_bookkeeping_refusal_anchor1"
  @compact_response "resp_bookkeeping_refusal_compact"

  test "owner_forwarded incremental compaction without owner provenance is refused and its item could not carry the turn" do
    put_owner_forwarding!()
    item = %{"type" => "compaction", "encrypted_content" => "synthetic-bookkeeping-refusal"}

    upstream =
      start_upstream(
        # Strict finite scenario: the first socket's turn, the replacement
        # socket's anchored compact on the owner's live upstream connection,
        # nothing else reaches the provider.
        # provenance: released-client header and frame shapes; reply frames synthetic
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]], respond: completed_frames(@anchor)),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.create", "previous_response_id" => @anchor, "input.0.type" => "message", "input.1.type" => "compaction_trigger"}],
            respond: compaction_frames(item, @compact_response)
          )
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    port = start_public_endpoint!()
    first = connect!(port, setup)

    try do
      first = send_frame!(first, turn_frame(setup))
      {first, created} = receive_frame!(first)
      {first, completed} = receive_frame!(first)
      assert %{"type" => "response.created"} = created
      assert %{"type" => "response.completed", "response" => %{"id" => @anchor}} = completed
      _first = first

      second = connect!(port, setup)

      try do
        {second, log} =
          with_log([level: :warning], fn ->
            second = send_frame!(second, compaction_frame(setup))
            {second, refusal} = receive_frame!(second)
            assert %{"type" => "error", "status" => 502, "error" => %{"code" => "invalid_compaction_response"}} = refusal
            second
          end)

        assert log =~ "native compact confirmation refused reason=missing_confirmation_provenance"
        assert log =~ "compaction_input_mode=incremental"

        # What the client would meet had the refused item been delivered.
        second = send_frame!(second, resume_frame(setup, item))
        {_second, duplicate} = receive_frame!(second)
        assert %{"type" => "error", "status" => 409, "error" => %{"code" => "duplicate_turn"}} = duplicate

        rows = settled_pool_requests!(setup.pool.id, 2)
        assert Enum.map(rows, &{&1.endpoint, &1.transport, &1.status}) == [{"/backend-api/codex/responses", "websocket", "succeeded"}, {"/backend-api/codex/responses/compact", "websocket", "succeeded"}]

        for row <- rows do
          assert Repo.aggregate(from(entry in LedgerEntry, where: entry.request_id == ^row.id and entry.entry_kind == "settlement"), :count) == 1
        end

        assert FakeUpstream.http_request_count(upstream) == 0
        assert :ok = FakeUpstream.verify!(upstream)
      after
        Mint.HTTP.close(second.conn)
      end
    after
      Mint.HTTP.close(first.conn)
    end
  end

  defp connect!(port, setup) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", setup.authorization},
      {"session-id", @thread_id},
      {"thread-id", @thread_id},
      {"x-client-request-id", @thread_id},
      {"x-codex-window-id", @window_id}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/backend-api/codex/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    %{conn: conn, websocket: websocket, ref: ref}
  end

  defp send_frame!(client, text) do
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, text)
    %{client | conn: conn, websocket: websocket}
  end

  defp receive_frame!(client) do
    {conn, websocket, text} = public_websocket_receive_text!(client.conn, client.websocket, client.ref)
    {%{client | conn: conn, websocket: websocket}, CodexPooler.JSON.decode!(text)}
  end

  # Every response task settles its request after the terminal frame reached
  # the client; no completion signal reaches the test, so wait for the rows
  # within a bounded detection budget.
  defp settled_pool_requests!(pool_id, count) do
    deadline = System.monotonic_time(:millisecond) + 15_000

    Stream.repeatedly(fn -> Repo.all(from(request in Request, where: request.pool_id == ^pool_id, order_by: [asc: request.admitted_at, asc: request.id])) end)
    |> Enum.reduce_while(nil, fn rows, _acc ->
      cond do
        length(rows) == count and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) -> {:halt, rows}
        System.monotonic_time(:millisecond) >= deadline -> flunk("expected #{count} settled requests, got #{inspect(Enum.map(rows, & &1.status))}")
        true -> Process.sleep(10) && {:cont, nil}
      end
    end)
  end

  defp put_owner_forwarding! do
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      cleanup_local_owner_sessions()

      case previous do
        :error -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        {:ok, value} -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  defp turn_frame(setup) do
    setup
    |> frame([%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic bookkeeping prompt"}]}], @turn_id, @window_id)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(%{"request_kind" => "turn"}))
    |> CodexPooler.JSON.encode!()
  end

  # The released client's pre-turn remote compaction: the next turn's prompt
  # and the trigger, anchored on the previous turn's last response.
  defp compaction_frame(setup) do
    compaction = %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses_compaction_v2", "phase" => "pre_turn", "strategy" => "memento"}

    setup
    |> frame([next_prompt(), %{"type" => "compaction_trigger"}], @next_turn_id, @window_id)
    |> Map.put("previous_response_id", @anchor)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(%{"request_kind" => "compaction", "compaction" => compaction, "turn_id" => @next_turn_id, "root_turn_id" => @next_turn_id}))
    |> CodexPooler.JSON.encode!()
  end

  # The next turn on the advanced window with the compacted history.
  defp resume_frame(setup, item) do
    setup
    |> frame([item, next_prompt()], @next_turn_id, @resumed_window_id)
    |> put_in(
      ["client_metadata", "x-codex-turn-metadata"],
      turn_metadata(%{
        "request_kind" => "turn",
        "turn_id" => @next_turn_id,
        "root_turn_id" => @next_turn_id,
        "window_id" => @resumed_window_id,
        "window_number" => 1,
        "context_window_id" => @resumed_context_window_id
      })
    )
    |> CodexPooler.JSON.encode!()
  end

  defp next_prompt, do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic next prompt"}]}

  defp frame(setup, input, turn_id, window_id) do
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
        "session_id" => @thread_id,
        "thread_id" => @thread_id,
        "turn_id" => turn_id,
        "root_turn_id" => turn_id,
        "x-codex-installation-id" => @installation_id,
        "x-codex-window-id" => window_id,
        "x-codex-ws-stream-request-start-ms" => "1790000000000"
      }
    }
  end

  defp turn_metadata(extra) do
    %{
      "agent_name" => "/root",
      "analytics_enabled" => true,
      "auto_review_enabled" => false,
      "context_window_id" => @context_window_id,
      "installation_id" => @installation_id,
      "root_turn_id" => @turn_id,
      "sandbox" => "seccomp",
      "sandbox_mode" => "read-only",
      "session_id" => @thread_id,
      "thread_id" => @thread_id,
      "thread_source" => "user",
      "turn_id" => @turn_id,
      "turn_started_at_unix_ms" => 1_790_000_000_000,
      "turn_trigger" => "exec",
      "window_id" => @window_id,
      "window_number" => 0,
      "model" => "gpt-test-model",
      "reasoning_effort" => "low"
    }
    |> Map.merge(extra)
    |> CodexPooler.JSON.encode!()
  end

  defp completed_frames(response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}}),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => response_id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 20_000, "output_tokens" => 1, "total_tokens" => 20_001}}
      })
    ])
  end

  defp compaction_frames(item, response_id) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => item}),
      CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item]}})
    ])
  end
end
