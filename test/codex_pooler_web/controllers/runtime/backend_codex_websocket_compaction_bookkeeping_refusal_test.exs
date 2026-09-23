defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketCompactionBookkeepingRefusalTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [cleanup_local_owner_sessions: 0]

  alias CodexPooler.Accounting.{LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.{NativeCompactionAdmission, WebsocketOwnerSession}
  alias CodexPooler.Repo

  # A pre-turn remote compaction of the released client (`rust-v0.156.1`
  # `run_pre_sampling_compact`) is an anchored, incremental `response.create`
  # on the connection that produced the anchor. It is served only under the
  # owner's native compaction admission, which the previous turn's ordinary
  # success armed as `pending_compact` for that socket for 60 s. Without one
  # the compaction can never be confirmed (`missing_confirmation_provenance`,
  # findings#206 rows 206-273/206-284). It used to be dispatched anyway: the
  # provider served and billed it, the client got `502 invalid_compaction_response`,
  # and because the compaction held the turn's claim every websocket retry of
  # the client (a full-history compaction on a new connection: the client drops
  # a connection after any stream error and resets its continuation) met
  # `409 duplicate_turn`, so the client paid again over HTTPS (production
  # request `ab3c4d98`, findings#206 row 206-288). It is now refused before
  # dispatch with the retryable `503 owner_unavailable` and nothing is claimed,
  # billed or sent upstream; the retry needs no admission (first-compact
  # collection) and carries the turn. Frames keep the released client's upgrade
  # headers and key sets; identifiers, prompt text and reply frames are
  # synthetic. Serving mode Full (the fake catalog model), one node, owner
  # forwarding on.
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
  @final_response "resp_bookkeeping_refusal_final01"

  # Production `ab3c4d98` (icoretech, 2026-09-22 14:27Z, findings#206 row
  # 206-288): the released client's pre-turn compaction on the socket that had
  # served the previous turn 34 s earlier (turn completed 14:26:52.583,
  # compaction admitted 14:27:26.892, both on one socket per the owner log).
  # The compaction carries the NEW turn's id, so its binding never matches the
  # admission the previous turn's success armed (`binding_mismatch`), and the
  # rows show two different turn claims. Row 206-289: after a pause longer
  # than the admission's 60 s (`@compact_reservation_ttl_ms`) the owner refuses
  # the reservation `expired` before it compares bindings, so the same frame
  # ends the same way; the test moves the armed deadline into the past instead
  # of waiting, since the owner compares it with the wall clock at reservation.
  for {arm, cause} <- [{:pre_turn, "binding_mismatch"}, {:expired, "expired"}] do
    @tag arm: arm, cause: cause
    test "owner_forwarded #{arm} anchored compaction without a usable admission is refused before dispatch and the client's full-history retry carries the turn",
         %{arm: arm, cause: cause} do
      put_owner_forwarding!()
      item = compaction_item(Atom.to_string(arm))

      upstream =
        start_upstream(
          # Strict finite scenario: the turn, then the retried full-history
          # compaction and the compacted turn. The refused anchored compaction
          # never reaches the provider.
          # provenance: released-client header and frame shapes; reply frames synthetic
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]], respond: completed_frames(@anchor)),
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              json: [valid: true, equals: %{"type" => "response.create", "input.0.type" => "message", "input.1.type" => "message", "input.2.type" => "compaction_trigger"}, forbidden: ["previous_response_id"]],
              respond: compaction_frames(item, @compact_response)
            ),
            FakeUpstream.expect_request(method: "WEBSOCKET", json: [valid: true, equals: %{"type" => "response.create", "input.0.type" => "compaction"}, forbidden: ["previous_response_id"]], respond: completed_frames(@final_response))
          ])
        )

      setup = gateway_setup(upstream, compact?: true)
      port = start_public_endpoint!()
      first = connect!(port, setup, @window_id)

      first = ordinary_turn!(first, turn_frame(setup, @turn_id, [prompt("first")]), @anchor)
      owner = owner!(setup)
      admission = await_pending_compact!(owner)
      if arm == :expired, do: expire_admission!(owner, admission)

      {first, log} =
        with_log([level: :warning], fn ->
          first = send_frame!(first, anchored_compaction_frame(setup, @anchor, [prompt("next")], @next_turn_id))
          {first, refusal} = receive_frame!(first)
          assert %{"type" => "error", "status" => 503, "error" => %{"code" => "owner_unavailable"}} = refusal
          first
        end)

      assert log =~ "native compaction refused before dispatch reason=admission_unavailable cause=#{cause} code=owner_unavailable status=503 compaction_phase=pre_turn topology=forwarded"
      refute log =~ "native compact confirmation refused"
      # Nothing was claimed, recorded or sent for the refused compaction.
      assert [%Request{endpoint: "/backend-api/codex/responses"}] = settled_pool_requests!(setup.pool.id, 1)
      assert length(FakeUpstream.requests(upstream)) == 1

      # The released client drops a connection after any stream error, so it
      # retries on a new connection with the full history.
      Mint.HTTP.close(first.conn)
      retry = connect!(port, setup, @window_id)

      try do
        retry = send_frame!(retry, full_history_compaction_frame(setup, [prompt("first"), prompt("next")], @next_turn_id))
        {retry, done} = receive_frame!(retry)
        assert done == %{"type" => "response.output_item.done", "item" => item}
        {retry, completed} = receive_frame!(retry)
        assert %{"type" => "response.completed", "response" => %{"status" => "completed", "output" => [^item]}} = completed

        # The turn continues on the same connection with the compacted history.
        retry = send_frame!(retry, resume_frame(setup, item, @next_turn_id))
        {retry, created} = receive_frame!(retry)
        assert %{"type" => "response.created"} = created
        {_retry, final} = receive_frame!(retry)
        assert %{"type" => "response.completed", "response" => %{"id" => @final_response}} = final

        rows = settled_pool_requests!(setup.pool.id, 3)

        assert Enum.map(rows, &{&1.endpoint, &1.transport, &1.status}) == [
                 {"/backend-api/codex/responses", "websocket", "succeeded"},
                 {"/backend-api/codex/responses/compact", "websocket", "succeeded"},
                 {"/backend-api/codex/responses", "websocket", "succeeded"}
               ]

        for row <- rows do
          assert Repo.aggregate(from(entry in LedgerEntry, where: entry.request_id == ^row.id and entry.entry_kind == "settlement"), :count) == 1
        end

        assert FakeUpstream.http_request_count(upstream) == 0
        assert :ok = FakeUpstream.verify!(upstream)
      after
        Mint.HTTP.close(retry.conn)
      end
    end
  end

  # An anchored compaction on a socket that attached after the turn it anchors
  # on, with no ordinary success of its own (the shape findings#206 row 206-284
  # first reproduced; the released client cannot send it, because a new
  # connection resets its continuation, but a frame of any client that does
  # must not be billed and then refused). Refused before dispatch.
  test "owner_forwarded anchored compaction on a socket without its own admission is refused before dispatch" do
    put_owner_forwarding!()

    upstream =
      start_upstream(
        # provenance: released-client header and frame shapes; reply frames synthetic
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]], respond: completed_frames(@anchor))
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    port = start_public_endpoint!()
    first = connect!(port, setup, @window_id)

    try do
      _first = ordinary_turn!(first, turn_frame(setup, @turn_id, [prompt("first")]), @anchor)
      second = connect!(port, setup, @window_id)

      try do
        {_second, log} =
          with_log([level: :warning], fn ->
            second = send_frame!(second, anchored_compaction_frame(setup, @anchor, [prompt("next")], @next_turn_id))
            {second, refusal} = receive_frame!(second)
            assert %{"type" => "error", "status" => 503, "error" => %{"code" => "owner_unavailable"}} = refusal
            second
          end)

        assert log =~ "native compaction refused before dispatch reason=admission_unavailable cause=no_admission"
        refute log =~ "native compact confirmation refused"
        assert [%Request{endpoint: "/backend-api/codex/responses", status: "succeeded"}] = settled_pool_requests!(setup.pool.id, 1)
        assert :ok = FakeUpstream.verify!(upstream)
      after
        Mint.HTTP.close(second.conn)
      end
    after
      Mint.HTTP.close(first.conn)
    end
  end

  defp connect!(port, setup, window_id) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", setup.authorization},
      {"session-id", @thread_id},
      {"thread-id", @thread_id},
      {"x-client-request-id", @thread_id},
      {"x-codex-window-id", window_id}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/backend-api/codex/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    %{conn: conn, websocket: websocket, ref: ref}
  end

  defp ordinary_turn!(client, frame, response_id) do
    client = send_frame!(client, frame)
    {client, created} = receive_frame!(client)
    {client, completed} = receive_frame!(client)
    assert %{"type" => "response.created"} = created
    assert %{"type" => "response.completed", "response" => %{"id" => ^response_id}} = completed
    client
  end

  defp send_frame!(client, text) do
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, text)
    %{client | conn: conn, websocket: websocket}
  end

  defp receive_frame!(client) do
    {conn, websocket, text} = public_websocket_receive_text!(client.conn, client.websocket, client.ref)
    {%{client | conn: conn, websocket: websocket}, CodexPooler.JSON.decode!(text)}
  end

  defp owner!(setup) do
    [session_id] = Repo.all(from(session in CodexSession, where: session.pool_id == ^setup.pool.id, select: session.id))
    assert {:ok, owner} = WebsocketOwnerSession.lookup(session_id)
    owner
  end

  # The ordinary success arms the admission after the terminal frame left the
  # owner; poll the owner's authoritative state until it is armed for this
  # client's downstream (no completion signal reaches the test process).
  defp await_pending_compact!(owner) do
    deadline = System.monotonic_time(:millisecond) + 15_000

    Stream.repeatedly(fn -> :sys.get_state(owner) end)
    |> Enum.reduce_while(nil, fn
      %{native_compaction_admission: %NativeCompactionAdmission{phase: :pending_compact} = admission, native_compaction_admission_downstream: armed, downstream: %{pid: pid}}, _acc
      when is_map(armed) and armed.pid == pid ->
        {:halt, admission}

      _other, _acc ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("owner never armed the native compaction admission for the attached socket")
        Process.sleep(10)
        {:cont, nil}
    end)
  end

  # Stands for the wall clock passing the armed admission's deadline: the
  # reservation compares `expires_at_ms` with the system time it is made at.
  defp expire_admission!(owner, %NativeCompactionAdmission{expires_at_ms: expires_at_ms}) when is_integer(expires_at_ms) do
    expired_at = System.system_time(:millisecond) - 1
    assert expired_at < expires_at_ms

    :sys.replace_state(owner, fn state ->
      %{state | native_compaction_admission: %{state.native_compaction_admission | expires_at_ms: expired_at}}
    end)

    :ok
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
        System.monotonic_time(:millisecond) >= deadline -> flunk("expected #{count} settled requests, got #{inspect(Enum.map(rows, &{&1.endpoint, &1.status}))}")
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

  defp compaction_item(label), do: %{"type" => "compaction", "encrypted_content" => "synthetic-bookkeeping-refusal-#{label}"}

  defp prompt(label), do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic #{label} prompt"}]}

  defp turn_frame(setup, turn_id, input) do
    setup
    |> frame(input, turn_id, @window_id)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(%{"request_kind" => "turn", "turn_id" => turn_id, "root_turn_id" => turn_id}))
    |> CodexPooler.JSON.encode!()
  end

  # The released client's pre-turn remote compaction on the connection that
  # produced the anchor: the next turn's prompt and the trigger.
  defp anchored_compaction_frame(setup, anchor, input, turn_id) do
    setup
    |> frame(input ++ [%{"type" => "compaction_trigger"}], turn_id, @window_id)
    |> Map.put("previous_response_id", anchor)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], compaction_metadata(turn_id))
    |> CodexPooler.JSON.encode!()
  end

  # The same compaction after the client reset its continuation: the whole
  # history, no anchor.
  defp full_history_compaction_frame(setup, history, turn_id) do
    setup
    |> frame(history ++ [%{"type" => "compaction_trigger"}], turn_id, @window_id)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], compaction_metadata(turn_id))
    |> CodexPooler.JSON.encode!()
  end

  defp compaction_metadata(turn_id) do
    compaction = %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses_compaction_v2", "phase" => "pre_turn", "strategy" => "memento"}
    turn_metadata(%{"request_kind" => "compaction", "compaction" => compaction, "turn_id" => turn_id, "root_turn_id" => turn_id})
  end

  # The next turn on the advanced window with the compacted history.
  defp resume_frame(setup, item, turn_id) do
    setup
    |> frame([item, prompt("next")], turn_id, @resumed_window_id)
    |> put_in(
      ["client_metadata", "x-codex-turn-metadata"],
      turn_metadata(%{
        "request_kind" => "turn",
        "turn_id" => turn_id,
        "root_turn_id" => turn_id,
        "window_id" => @resumed_window_id,
        "window_number" => 1,
        "context_window_id" => @resumed_context_window_id
      })
    )
    |> CodexPooler.JSON.encode!()
  end

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
