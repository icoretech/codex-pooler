defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketPreTurnCompactionAdmissionTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{LedgerEntry, Request}
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.{NativeCompactionAdmission, WebsocketOwnerSession}
  alias CodexPooler.Repo

  # The released client's pre-turn remote compaction (findings#206 row
  # 206-304). Observed on the wire with Codex 0.156.1 (`codex app-server`,
  # websocket, `model_auto_compact_token_limit` below the reported usage, P61
  # probe): after turn T1 completed with response R1 on connection 1, turn T2
  # starts with a `response.create` on the SAME connection whose turn metadata
  # names T2 (`turn_id` and `root_turn_id`), `request_kind: compaction`,
  # `compaction.phase: pre_turn`, T1's window and context window, whose
  # `previous_response_id` is R1 and whose `input` is only the
  # `compaction_trigger`; T2's final request follows on the same connection
  # with no anchor, the compaction item, and the advanced window (`:1`) and
  # context window. The admission T1's success armed is bound to T1, so the
  # compaction's binding never matched it (`binding_mismatch`) and since
  # `6e4481b07` it was refused `503 owner_unavailable` before dispatch: the
  # client then paid a reconnect and a full-history resend for every such
  # compaction. The owner now admits it on its first send, once, because it
  # declares the pre-turn phase and is anchored on exactly the response the
  # admission was armed for, on the same window, context, connection
  # generation and downstream, inside the admission deadline; the reservation
  # adopts T2's turn key, so the final request's admission matches. Frames keep
  # the released client's key sets; identifiers, prompt text and reply frames
  # are synthetic. Serving mode Full (the fake catalog model), one node.
  @thread_id "019a0000-0000-7000-8000-00000000e001"
  @window_id "#{@thread_id}:0"
  @resumed_window_id "#{@thread_id}:1"
  @turn_id "019a0000-0000-7000-8000-00000000e002"
  @next_turn_id "019a0000-0000-7000-8000-00000000e006"
  @installation_id "00000000-0000-4000-8000-00000000e003"
  @context_window_id "00000000-0000-4000-8000-00000000e004"
  @resumed_context_window_id "00000000-0000-4000-8000-00000000e005"
  @anchor "resp_preturn_admission_anchor001"
  @compact_response "resp_preturn_admission_compact01"
  @final_response "resp_preturn_admission_final0001"
  @lifecycle_event [:codex_pooler, :gateway, :native_compaction, :lifecycle]

  for topology <- [:forwarded, :direct] do
    @tag topology: topology
    test "#{topology} released pre-turn compaction anchored on the admitted response is served on its first send, billed once, and its turn continues on the same connection",
         %{topology: topology} do
      put_owner_forwarding!(topology == :forwarded)
      attach_lifecycle_events!(topology)
      item = compaction_item("served")

      upstream =
        start_upstream(
          # Strict finite scenario, every request on the first provider
          # connection: the turn, the anchored pre-turn compaction, the
          # compacted turn. A refusal, a reconnect or a full-history resend
          # would not match.
          # provenance: released-client frame shapes (P61 probe); reply frames synthetic
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]], respond: completed_frames(@anchor)),
            FakeUpstream.expect_request(
              method: "WEBSOCKET",
              websocket_connection_ordinal: 1,
              json: [valid: true, equals: %{"type" => "response.create", "previous_response_id" => @anchor, "input.0.type" => "compaction_trigger"}, forbidden: ["input.1"]],
              respond: compaction_frames(item, @compact_response)
            ),
            FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true, equals: %{"type" => "response.create", "input.0.type" => "compaction"}, forbidden: ["previous_response_id"]], respond: completed_frames(@final_response))
          ])
        )

      setup = gateway_setup(upstream, compact?: true)
      port = start_public_endpoint!()
      client = connect!(port, setup, @window_id)

      try do
        client = ordinary_turn!(client, turn_frame(setup, @turn_id, [prompt("first")]), @anchor)
        await_armed!(topology, setup)

        {client, log} =
          with_log([level: :warning], fn ->
            client = send_frame!(client, pre_turn_compaction_frame(setup, @anchor, @next_turn_id))
            {client, done} = receive_frame!(client)
            assert done == %{"type" => "response.output_item.done", "item" => item}
            {client, completed} = receive_frame!(client)
            assert %{"type" => "response.completed", "response" => %{"id" => @compact_response, "status" => "completed", "output" => [^item]}} = completed

            client = send_frame!(client, resume_frame(setup, item, @next_turn_id))
            {client, created} = receive_frame!(client)
            assert %{"type" => "response.created"} = created
            {client, final} = receive_frame!(client)
            assert %{"type" => "response.completed", "response" => %{"id" => @final_response}} = final
            client
          end)

        # The compaction was reserved under the armed admission on its first
        # send and confirmed into the final admission, which the final turn
        # reserved.
        await_lifecycle!(topology, :pending_compact, :reserved_compact)
        await_lifecycle!(topology, :collected_unconfirmed, :pending_final)
        await_lifecycle!(topology, :pending_final, :reserved_final)

        refute log =~ "native compaction refused before dispatch"
        refute log =~ "native compact confirmation refused"
        refute log =~ "duplicate_turn"

        rows = settled_pool_requests!(setup.pool.id, 3)

        assert Enum.map(rows, &{&1.endpoint, &1.transport, &1.status}) == [
                 {"/backend-api/codex/responses", "websocket", "succeeded"},
                 {"/backend-api/codex/responses/compact", "websocket", "succeeded"},
                 {"/backend-api/codex/responses", "websocket", "succeeded"}
               ]

        for row <- rows do
          assert Repo.aggregate(from(entry in LedgerEntry, where: entry.request_id == ^row.id and entry.entry_kind == "settlement"), :count) == 1
        end

        assert length(FakeUpstream.requests(upstream)) == 3
        assert FakeUpstream.http_request_count(upstream) == 0
        assert :ok = FakeUpstream.verify!(upstream)
        _client = client
      after
        Mint.HTTP.close(client.conn)
      end
    end

    @tag topology: topology
    test "#{topology} a resend of a served pre-turn compaction finds the admission spent and is refused before dispatch",
         %{topology: topology} do
      put_owner_forwarding!(topology == :forwarded)
      attach_lifecycle_events!(topology)
      item = compaction_item("spent")

      upstream =
        start_upstream(
          # provenance: released-client frame shapes (P61 probe); reply frames synthetic
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true, equals: %{"type" => "response.create"}, forbidden: ["previous_response_id"]], respond: completed_frames(@anchor)),
            FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true, equals: %{"previous_response_id" => @anchor, "input.0.type" => "compaction_trigger"}], respond: compaction_frames(item, @compact_response))
          ])
        )

      setup = gateway_setup(upstream, compact?: true)
      port = start_public_endpoint!()
      client = connect!(port, setup, @window_id)

      try do
        client = ordinary_turn!(client, turn_frame(setup, @turn_id, [prompt("first")]), @anchor)
        await_armed!(topology, setup)
        frame = pre_turn_compaction_frame(setup, @anchor, @next_turn_id)

        client = send_frame!(client, frame)
        {client, _done} = receive_frame!(client)
        {client, completed} = receive_frame!(client)
        assert %{"type" => "response.completed", "response" => %{"id" => @compact_response}} = completed
        await_lifecycle!(topology, :collected_unconfirmed, :pending_final)
        await_socket_response_tasks_released!(setup)

        {_client, log} =
          with_log([level: :warning], fn ->
            client = send_frame!(client, frame)
            {client, refusal} = receive_frame!(client)
            assert %{"type" => "error", "status" => 503, "error" => %{"code" => "owner_unavailable"}} = refusal
            client
          end)

        assert log =~ "native compaction refused before dispatch reason=admission_unavailable cause=invalid_transition code=owner_unavailable status=503 compaction_phase=pre_turn topology=#{topology}"
        assert [%Request{status: "succeeded"}, %Request{endpoint: "/backend-api/codex/responses/compact", status: "succeeded"}] = settled_pool_requests!(setup.pool.id, 2)
        assert length(FakeUpstream.requests(upstream)) == 2
        assert :ok = FakeUpstream.verify!(upstream)
      after
        Mint.HTTP.close(client.conn)
      end
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

  # Every admission transition of the owner (forwarded) or of the socket's own
  # upstream session (direct) is reported on this event; the test waits on the
  # transitions instead of on time.
  defp attach_lifecycle_events!(topology) do
    handler_id = {__MODULE__, self(), make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @lifecycle_event,
        fn
          _event, _measurements, %{topology: ^topology, phase_from: from, phase_to: to}, _config -> send(test_pid, {:admission_lifecycle, from, to})
          _event, _measurements, _metadata, _config -> :ok
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # The direct upstream session reports the arm; the owner arms a forwarded
  # admission without an event, so poll its authoritative state until it is
  # armed for the attached socket (no completion signal reaches the test).
  defp await_armed!(:direct, _setup) do
    receive do
      {:admission_lifecycle, _from, :pending_compact} -> :ok
    after
      15_000 -> flunk("direct admission never armed")
    end
  end

  defp await_armed!(:forwarded, setup) do
    [session_id] = Repo.all(from(session in CodexSession, where: session.pool_id == ^setup.pool.id, select: session.id))
    assert {:ok, owner} = WebsocketOwnerSession.lookup(session_id)
    deadline = System.monotonic_time(:millisecond) + 15_000

    Stream.repeatedly(fn -> :sys.get_state(owner) end)
    |> Enum.reduce_while(nil, fn
      %{native_compaction_admission: %NativeCompactionAdmission{phase: :pending_compact}, native_compaction_admission_downstream: armed, downstream: %{pid: pid}}, _acc
      when is_map(armed) and armed.pid == pid ->
        {:halt, :ok}

      _other, _acc ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("owner never armed the native compaction admission for the attached socket")
        Process.sleep(10)
        {:cont, nil}
    end)
  end

  # The compaction's response task streams the terminal to the client, settles,
  # and only then hands its result to the socket, which stops tracking it once
  # it has acknowledged the delivery. A resend that reaches the socket while it
  # still tracks a task is deferred behind it and refused at dequeue, which
  # answers the same 503 but logs only the generic failed-turn line (Drone
  # 1538, findings#206 row 206-392). Wait, within the detection budget, until
  # the socket's own state (the set its deferral decision reads) tracks no
  # task, so the resend meets the spent admission directly. `:sys.get_state/1`
  # answers after every message the socket already holds, and nothing starts
  # another task before the resend.
  defp await_socket_response_tasks_released!(setup) do
    assert [{socket, _value}] = Registry.lookup(CodexPooler.PubSub, Events.pubsub_topic(setup.pool.id, "pools"))
    await_socket_response_tasks_released!(socket, System.monotonic_time(:millisecond) + 15_000)
  end

  defp await_socket_response_tasks_released!(socket, deadline) do
    {_transport, handler_state} = :sys.get_state(socket)
    tasks = Map.get(handler_state.connection.websock_state, :tasks, MapSet.new())

    cond do
      MapSet.size(tasks) == 0 ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          10 -> await_socket_response_tasks_released!(socket, deadline)
        end

      true ->
        flunk("the socket still tracks response tasks #{inspect(MapSet.to_list(tasks))}")
    end
  end

  defp await_lifecycle!(topology, from, to) do
    receive do
      {:admission_lifecycle, ^from, ^to} -> :ok
    after
      15_000 -> flunk("#{topology} admission never moved #{from} -> #{to}")
    end
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

  defp put_owner_forwarding!(enabled?) do
    previous = Application.fetch_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled?)

    on_exit(fn ->
      case previous do
        :error -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        {:ok, value} -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  defp compaction_item(label), do: %{"type" => "compaction", "encrypted_content" => "synthetic-preturn-admission-#{label}"}

  defp prompt(label), do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic #{label} prompt"}]}

  defp turn_frame(setup, turn_id, input) do
    setup
    |> frame(input, turn_id, @window_id)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(%{"request_kind" => "turn", "turn_id" => turn_id, "root_turn_id" => turn_id}))
    |> CodexPooler.JSON.encode!()
  end

  # As on the wire: the next turn's id, the previous turn's window and context
  # window, the admitted response as the anchor, and only the trigger.
  defp pre_turn_compaction_frame(setup, anchor, turn_id) do
    compaction = %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses_compaction_v2", "phase" => "pre_turn", "strategy" => "memento"}

    setup
    |> frame([%{"type" => "compaction_trigger"}], turn_id, @window_id)
    |> Map.put("previous_response_id", anchor)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(%{"request_kind" => "compaction", "compaction" => compaction, "turn_id" => turn_id, "root_turn_id" => turn_id}))
    |> CodexPooler.JSON.encode!()
  end

  # The same turn's final request on the advanced window with the compacted
  # history and no anchor.
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
      "sandbox" => "seatbelt",
      "sandbox_mode" => "read-only",
      "session_id" => @thread_id,
      "thread_id" => @thread_id,
      "turn_id" => @turn_id,
      "turn_started_at_unix_ms" => 1_790_000_000_000,
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
