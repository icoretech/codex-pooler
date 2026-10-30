defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.OversizeStartupTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [socket_transport_barrier!: 3, await_succeeded_pool_requests!: 2]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.{ContinuityPayload, NativeTurnContinuation, RequestOptions}
  alias CodexPooler.Gateway.Persistence.{CodexTurn, RoutingCircuitState}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  @moduletag capture_log: true

  for forwarding <- [false, true], shape <- [:tool_output, :images, :encrypted_tools] do
    @tag forwarding: forwarding, shape: shape
    test "oversized inherited unanchored tool history is refused before execution (#{shape}, owner forwarding #{forwarding})", %{forwarding: forwarding, shape: shape} do
      assert_oversize_preclaim!(forwarding, shape)
    end
  end

  for forwarding <- [false, true] do
    @tag :encrypted_tools
    test "small encrypted tool history remains native websocket work (owner forwarding #{forwarding})" do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, unquote(forwarding))
      upstream = start_upstream(FakeUpstream.sse_stream([{"response.completed", %{"type" => "response.completed", "response" => %{"status" => "completed", "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}}]))
      setup = gateway_setup(upstream)
      port = start_public_endpoint!()
      window = Ecto.UUID.generate()
      {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, Ecto.UUID.generate(), "/backend-api/codex/responses", [{"x-codex-window-id", window}])
      on_exit(fn -> Mint.HTTP.close(conn) end)
      payload = %{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => Enum.take(inherited_input(:encrypted_tools), 5), "stream" => true}
      refute RequestOptions.build(%{}, "/backend-api/codex/responses", payload).payload_context.portable_full_history?
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(payload))
      {conn, _websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
      assert CodexPooler.JSON.decode!(text)["type"] == "response.completed"
      [request] = await_succeeded_pool_requests!(setup.pool.id, 1)
      assert request.transport == "websocket"
      refute Map.has_key?(request.request_metadata, "native_websocket_size_recovery")
      assert Repo.aggregate(Attempt, :count) == 1
      assert Repo.aggregate(from(l in LedgerEntry, where: l.entry_kind == "settlement"), :count) == 1
      [captured] = FakeUpstream.requests(upstream)
      assert replay_digest(captured.json) == replay_digest(payload)
      assert FakeUpstream.physical_counts(upstream).websocket_generation == 1
      assert FakeUpstream.physical_counts(upstream).http_generation == 0
      Mint.HTTP.close(conn)
    end
  end

  defp assert_oversize_preclaim!(forwarding, shape) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding)
    upstream = start_upstream(FakeUpstream.sse_stream([%{"type" => "response.output_text.delta", "delta" => "synthetic visible output", "output_index" => 0, "content_index" => 0}, %{"type" => "response.completed", "response" => %{"id" => "resp_synthetic_http_rebuild", "status" => "completed", "usage" => %{"input_tokens" => 4, "output_tokens" => 1, "total_tokens" => 5}}}]))
    setup = gateway_setup(upstream, model_metadata: %{"supported_input_modalities" => ["text", "image"]})
    port = start_public_endpoint!()
    window = Ecto.UUID.generate()
    {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, Ecto.UUID.generate(), "/backend-api/codex/responses", [{"x-codex-window-id", window}])

    payload = %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => inherited_input(shape),
      "stream" => true,
      "generate" => true,
      "client_metadata" => %{"x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"thread_id" => setup.pool.id, "turn_id" => "synthetic-child-startup", "request_kind" => "turn"})}
    }

    assert NativeTurnContinuation.turn_role(payload) == :tool_continuation
    assert RequestOptions.build(%{}, "/backend-api/codex/responses", payload).payload_context.portable_full_history? == (shape != :encrypted_tools)
    expected_handoffs = Enum.filter(payload["input"], &(Map.get(&1, "type") == "agent_message"))

    if shape in [:images, :encrypted_tools] do
      assert [handoff] = expected_handoffs
      assert ContinuityPayload.v2_encrypted_handoff?(handoff)
    end

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(payload))
      {conn, _websocket, [text], 1011} = receive_recovery_close!(conn, websocket, ref, [])
      assert %{"type" => "error", "status" => 502, "error" => %{"type" => "server_error", "code" => "upstream_request_failed"}} = CodexPooler.JSON.decode!(text)
      assert FakeUpstream.count(upstream) == 0
      assert [%Request{status: "rejected", usage_status: "not_applicable", request_metadata: metadata, correlation_id: correlation_id}] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)
      assert get_in(metadata, ["native_websocket_size_recovery", "message_bytes"]) > 16_777_216
      refute String.starts_with?(correlation_id, "codex-")
      assert Repo.aggregate(Attempt, :count) == 0
      assert Repo.aggregate(LedgerEntry, :count) == 0
      assert Repo.aggregate(CodexTurn, :count) == 0
      assert Repo.aggregate(RoutingCircuitState, :count) == 0
      Mint.HTTP.close(conn)
      http = build_conn() |> put_req_header("authorization", setup.authorization) |> put_req_header("x-codex-window-id", window) |> put_req_header("content-type", "application/json") |> post("/backend-api/codex/responses", CodexPooler.JSON.encode!(Map.delete(payload, "type")))
      assert http.status == 200
      assert http.resp_body =~ "response.completed"
      assert FakeUpstream.count(upstream) == 1
      [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "POST"
      actual_handoffs = Enum.filter(captured.json["input"], &(Map.get(&1, "type") == "agent_message"))
      assert actual_handoffs == expected_handoffs
      assert replay_digest(captured.json) == replay_digest(payload)
      assert NativeTurnContinuation.turn_role(captured.json) == :tool_continuation
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id and r.status == "succeeded"), :count) == 1
      served = Repo.one!(from(r in Request, where: r.pool_id == ^setup.pool.id and r.status == "succeeded"))
      assert served.request_metadata["native_http_claim_arm"] == "tool_continuation"
      assert String.starts_with?(served.correlation_id, "codex-request:")
      {again, again_ws, again_ref, _} = public_websocket_connect_with_request_headers!(port, setup, Ecto.UUID.generate(), "/backend-api/codex/responses", [{"x-codex-window-id", Ecto.UUID.generate()}])

      try do
        {again, again_ws} = public_websocket_send_text!(again, again_ws, again_ref, CodexPooler.JSON.encode!(payload))
        {_again, _again_ws, [_error], 1011} = receive_recovery_close!(again, again_ws, again_ref, [])
        assert Repo.get!(Request, served.id) == served
        assert FakeUpstream.count(upstream) == 1
      after
        Mint.HTTP.close(again)
      end
    after
      Mint.HTTP.close(conn)
    end
  end

  for failure <- [:missing_window, :failed_marker] do
    @tag failure: failure
    test "oversized refusal has no recovery authority when #{failure}", %{failure: failure} do
      upstream = start_upstream(FakeUpstream.json_response(%{}))
      setup = gateway_setup(upstream)

      if failure == :failed_marker do
        trigger = "oversize_reject_" <> String.replace(Ecto.UUID.generate(), "-", "")
        Repo.query!("CREATE FUNCTION #{trigger}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.pool_id = '#{setup.pool.id}'::uuid THEN NEW.request_metadata = '{}'::jsonb; END IF; RETURN NEW; END $$")
        Repo.query!("CREATE TRIGGER #{trigger} BEFORE INSERT ON requests FOR EACH ROW EXECUTE FUNCTION #{trigger}()")
      end

      headers = if failure == :missing_window, do: [], else: [{"x-codex-window-id", Ecto.UUID.generate()}]
      port = start_public_endpoint!()
      {conn, websocket, ref, _} = public_websocket_connect_with_request_headers!(port, setup, Ecto.UUID.generate(), "/backend-api/codex/responses", headers)
      payload = %{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => inherited_input(:tool_output)}

      try do
        {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(payload))
        {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
        expected_status = if failure == :missing_window, do: 413, else: 503
        expected_code = if failure == :missing_window, do: "websocket_message_too_large", else: "service_unavailable"
        assert %{"type" => "error", "status" => ^expected_status, "error" => %{"code" => ^expected_code}} = CodexPooler.JSON.decode!(text)
        # A successful ping proves the refusal did not emit the recovery close.
        socket_transport_barrier!(conn, websocket, ref)
        assert FakeUpstream.count(upstream) == 0
        assert Repo.aggregate(Request, :count) == 0
        assert Repo.aggregate(Attempt, :count) == 0
        assert Repo.aggregate(LedgerEntry, :count) == 0
        assert Repo.aggregate(CodexTurn, :count) == 0
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  for forwarding <- [false, true] do
    @tag forwarding: forwarding
    test "cancellation before confirmed refusal leaves no recovery or execution authority (#{forwarding})", %{forwarding: forwarding} do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding)
      upstream = start_upstream(FakeUpstream.json_response(%{}))
      setup = gateway_setup(upstream)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      {:ok, state} = CodexResponsesSocket.init(%{auth: auth, opts: %{request_id: "synthetic-oversize-cancel", accepted_turn_state: Ecto.UUID.generate(), forwarded_headers: [{"x-codex-window-id", Ecto.UUID.generate()}]}})
      observer = self()

      state =
        Map.put(state, :response_task_start_options,
          before_direct_cleanup_ready: fn ->
            send(observer, {:oversize_ready, self()})

            receive do
              :release -> :ok
            end
          end
        )

      payload = %{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => inherited_input(:tool_output)}
      assert {:ok, state} = CodexResponsesSocket.handle_in({CodexPooler.JSON.encode!(payload), [opcode: :text]}, state)
      assert_receive {:oversize_ready, task}, 15_000
      monitor = Process.monitor(task)
      Process.exit(task, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^task, :killed}, 15_000
      assert :ok = WebsocketCleanupFence.terminate_and_await!(:closed, state)
      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
      assert Repo.aggregate(LedgerEntry, :count) == 0
      assert Repo.aggregate(CodexTurn, :count) == 0
    end
  end

  test "trusted recovery stop releases queued native work without dispatching it" do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    upstream = start_upstream(FakeUpstream.json_response(%{}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = CodexResponsesSocket.init(%{auth: auth, opts: %{request_id: "synthetic-oversize-queue", accepted_turn_state: Ecto.UUID.generate(), forwarded_headers: [{"x-codex-window-id", Ecto.UUID.generate()}]}})
    observer = self()

    state =
      Map.put(state, :response_task_start_options,
        before_direct_cleanup_ready: fn ->
          send(observer, {:oversize_queue_ready, self()})

          receive do
            :release -> :ok
          after
            15_000 -> raise "oversize queue barrier timed out"
          end
        end
      )

    payload = %{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => inherited_input(:tool_output)}
    assert {:ok, state} = CodexResponsesSocket.handle_in({CodexPooler.JSON.encode!(payload), [opcode: :text]}, state)
    assert_receive {:oversize_queue_ready, task}, 15_000
    monitor = Process.monitor(task)
    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)
    queued = Map.put(payload, "input", native_text_input("synthetic queued request"))
    assert {:ok, state} = CodexResponsesSocket.handle_in({CodexPooler.JSON.encode!(queued), [opcode: :text]}, state)
    assert :queue.len(state.queued_response_payloads) == 1
    send(task, :release)
    assert_receive {:oversize_queue_ready, ^task}, 15_000
    send(task, :release)
    assert_receive {:codex_response_done, ^task, result}, 15_000
    assert {:stop, :normal, {1011, _}, [{:text, text}], stopped} = CodexResponsesSocket.handle_info({:codex_response_done, task, result}, state)
    assert CodexPooler.JSON.decode!(text)["error"]["code"] == "upstream_request_failed"
    assert stopped.socket_stopped?
    assert :queue.is_empty(stopped.queued_response_payloads)
    assert MapSet.size(stopped.tasks) == 0
    assert :ok = WebsocketCleanupFence.terminate_and_await!(:closed, stopped)
    assert_receive {:DOWN, ^monitor, :process, ^task, _reason}, 15_000
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 1
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0
    assert Repo.aggregate(CodexTurn, :count) == 0
  end

  defp inherited_input(:tool_output), do: [%{"type" => "function_call_output", "call_id" => "call_inherited", "output" => String.duplicate("x", 28 * 1024 * 1024)}]

  defp inherited_input(:encrypted_tools) do
    [
      %{"type" => "function_call", "status" => "completed", "call_id" => "call_function", "name" => "example", "arguments" => "{}", "encrypted_content" => "synthetic-function-cipher"},
      %{"type" => "function_call_output", "call_id" => "call_function", "output" => "synthetic function result"},
      %{"type" => "custom_tool_call", "status" => "completed", "call_id" => "call_custom", "name" => "example_custom", "input" => "synthetic input", "encrypted_content" => "synthetic-custom-cipher"},
      %{"type" => "custom_tool_call_output", "call_id" => "call_custom", "output" => "synthetic custom result"},
      %{"type" => "web_search_call", "status" => "completed", "action" => %{"type" => "search", "query" => "synthetic"}, "encrypted_content" => "synthetic-search-cipher"}
      | inherited_input(:images)
    ]
  end

  defp inherited_input(:images) do
    image = %{"type" => "input_image", "image_url" => "data:image/png;base64," <> String.duplicate("A", 512 * 1024)}

    handoff = %{
      "type" => "agent_message",
      "author" => "/root",
      "recipient" => "/root/sample",
      "content" => [
        %{"type" => "input_text", "text" => "Message Type: NEW_TASK\nTask name: /root/sample\nSender: /root\nPayload:\n"},
        %{"type" => "encrypted_content", "encrypted_content" => "synthetic-handoff"}
      ]
    }

    [%{"type" => "function_call_output", "call_id" => "call_inherited", "output" => "synthetic inherited tool result"}, %{"role" => "user", "content" => List.duplicate(image, 57)}, handoff]
  end

  defp replay_digest(payload) do
    items = Enum.filter(payload["input"], &(Map.get(&1, "type") in ["function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output", "web_search_call"] or Map.get(&1, "role") == "user"))
    :crypto.hash(:sha256, :erlang.term_to_binary(items))
  end

  defp receive_recovery_close!(conn, websocket, ref, texts, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    message = receive_mint_socket_message!(conn, remaining, "recovery close did not arrive")

    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {websocket, frames} =
          Enum.reduce(responses, {websocket, []}, fn
            {:data, ^ref, data}, {ws, frames} ->
              {:ok, ws, decoded} = Mint.WebSocket.decode(ws, data)
              {ws, frames ++ decoded}

            _, acc ->
              acc
          end)

        texts = texts ++ for({:text, text} <- frames, do: text)

        case Enum.find(frames, &match?({:close, _, _}, &1)) do
          {:close, code, _} -> {conn, websocket, texts, code}
          nil -> receive_recovery_close!(conn, websocket, ref, texts, deadline)
        end

      :unknown ->
        receive_recovery_close!(conn, websocket, ref, texts, deadline)

      {:error, _conn, reason, _responses} ->
        flunk("recovery socket failed: #{inspect(reason)}")
    end
  end
end
