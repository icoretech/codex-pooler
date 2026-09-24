defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.PeerOwnerCompactionDeliveryTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [set_model_serving_mode!: 3]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_peer_window_owner!: 2]

  alias CodexPooler.Accounting.{LedgerEntry, Request}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.AccountsFixtures
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Repo
  alias CodexPooler.TestAppEnv

  # A native compaction the owner collects is returned whole in the owner's
  # reply, and the owner sends no `:complete` after it: only a relayed turn
  # gets one. The socket waited for that `:complete` before releasing the
  # compaction's response task whenever the owner was not on its own node, so
  # with the session's owner on the other web pod the compaction reached the
  # client and then every later frame of the connection (the turn that
  # continues on the compacted history) queued behind the parked task until the
  # client gave up. One node never showed it: a socket whose owner is local
  # releases on its own accepted terminal (findings#206 row 206-334, found by
  # the two-node arm of the pre-turn admission test).
  #
  # Topology: owner forwarding on, the public socket on this node, the owner
  # and its provider connection on a peer VM sharing the committed database.
  # Both collected deliveries: the admitted anchored pre-turn compaction
  # (`collect_compaction`, released-client shape, P61 probe) and a full-history
  # compaction, which needs no admission (`collect_full_history`, the shape of
  # the released client's retry on a new connection, `compact_remote_v2.rs`).
  # Serving modes Full and Lite (Lite: no top-level `instructions`/`tools`, the
  # Lite marker in `client_metadata`, P63 wire probe). Identifiers, prompt text
  # and reply frames are synthetic.
  @thread_id "019a0000-0000-7000-8000-00000000d001"
  @window_id "#{@thread_id}:0"
  @resumed_window_id "#{@thread_id}:1"
  @turn_id "019a0000-0000-7000-8000-00000000d002"
  @next_turn_id "019a0000-0000-7000-8000-00000000d006"
  @installation_id "00000000-0000-4000-8000-00000000d003"
  @context_window_id "00000000-0000-4000-8000-00000000d004"
  @resumed_context_window_id "00000000-0000-4000-8000-00000000d005"
  @anchor "resp_peer_delivery_anchor0000001"
  @compact_response "resp_peer_delivery_compact00001"
  @final_response "resp_peer_delivery_final0000001"
  @lite_marker "ws_request_header_x_openai_internal_codex_responses_lite"
  @compact_endpoint "/backend-api/codex/responses/compact"
  @turn_endpoint "/backend-api/codex/responses"
  @detection_timeout_ms 15_000

  for delivery <- [:collect_compaction, :collect_full_history], mode <- ["full", "lite"] do
    @tag delivery: delivery, mode: mode
    test "#{mode} #{delivery} served by a peer owner reaches the client and the turn continues on the same connection",
         %{delivery: delivery, mode: mode} do
      TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
      enter_peer_owner_topology!()
      ctx = %{mode: mode, delivery: delivery}
      item = compaction_item()

      upstream = start_upstream(FakeUpstream.strict_sequence(upstream_sequence(ctx, item)))
      setup = gateway_setup(upstream, compact?: true)
      peer = start_peer_window_owner!(setup, @window_id)
      if mode == "lite", do: set_model_serving_mode!(committed_owner_scope(), setup, "lite")
      ctx = Map.put(ctx, :setup, setup)
      port = start_public_endpoint!()
      client = connect!(port, setup)

      try do
        client = compaction_exchange!(client, ctx, peer)
        {client, frames} = receive_until_terminal(client, [])
        assert frames == ["response.output_item.done", "response.completed"]

        # The continuing turn is answered on the same connection, so the
        # compaction's response task was released.
        {client, frames} = client |> send_frame!(resume_frame(ctx, item)) |> receive_until_terminal([])
        assert frames == ["response.created", "response.completed"]

        rows = await_settled!(setup.pool.id, expected_rows(delivery))
        assert Enum.map(rows, &{&1.endpoint, &1.status}) == expected_rows(delivery)

        for row <- rows do
          assert Repo.aggregate(from(entry in LedgerEntry, where: entry.request_id == ^row.id and entry.entry_kind == "settlement"), :count) == 1
        end

        assert FakeUpstream.http_request_count(upstream) == 0
        assert :ok = FakeUpstream.verify!(upstream)
        _client = client
      after
        Mint.HTTP.close(client.conn)
      end
    end
  end

  defp expected_rows(:collect_compaction), do: [{@turn_endpoint, "succeeded"}, {@compact_endpoint, "succeeded"}, {@turn_endpoint, "succeeded"}]
  defp expected_rows(:collect_full_history), do: [{@compact_endpoint, "succeeded"}, {@turn_endpoint, "succeeded"}]

  # The admitted compaction follows a first turn whose success armed the
  # admission on the peer owner; the full-history compaction opens the
  # connection, as the released client's retry does.
  defp compaction_exchange!(client, %{delivery: :collect_compaction} = ctx, peer) do
    {client, frames} = client |> send_frame!(turn_frame(ctx)) |> receive_until_terminal([])
    assert frames == ["response.created", "response.output_item.done", "response.completed"]
    await_owner_armed!(peer.owner_pid)
    send_frame!(client, anchored_compaction_frame(ctx))
  end

  defp compaction_exchange!(client, %{delivery: :collect_full_history} = ctx, _peer), do: send_frame!(client, full_history_compaction_frame(ctx))

  defp upstream_sequence(%{delivery: :collect_compaction} = ctx, item) do
    [
      FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true, equals: lite(%{"type" => "response.create"}, ctx.mode), forbidden: ["previous_response_id"]], respond: completed_frames(@anchor, [answer()])),
      FakeUpstream.expect_request(
        method: "WEBSOCKET",
        websocket_connection_ordinal: 1,
        json: [valid: true, equals: lite(%{"type" => "response.create", "previous_response_id" => @anchor, "input.0.type" => "compaction_trigger"}, ctx.mode), forbidden: ["input.1"]],
        respond: compaction_frames(item)
      ),
      resume_expectation(ctx)
    ]
  end

  defp upstream_sequence(%{delivery: :collect_full_history} = ctx, item) do
    [
      FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: [valid: true, equals: lite(%{"type" => "response.create"}, ctx.mode), forbidden: ["previous_response_id"]], respond: compaction_frames(item)),
      resume_expectation(ctx)
    ]
  end

  defp resume_expectation(ctx),
    do:
      FakeUpstream.expect_request(
        method: "WEBSOCKET",
        websocket_connection_ordinal: 1,
        json: [valid: true, equals: lite(%{"type" => "response.create"}, ctx.mode), forbidden: ["previous_response_id"]],
        respond: completed_frames(@final_response, [])
      )

  defp lite(expected, "lite"), do: Map.put(expected, "client_metadata.#{@lite_marker}", "true")
  defp lite(expected, "full"), do: expected

  # The peer owner arms the admission after the first turn's terminal left it,
  # with no signal to this node; poll its state for the attached socket.
  defp await_owner_armed!(owner) do
    await!(
      fn ->
        match?(
          %{native_compaction_admission: %NativeCompactionAdmission{phase: :pending_compact}, native_compaction_admission_downstream: %{pid: pid}, downstream: %{pid: pid}},
          :sys.get_state(owner)
        )
      end,
      "the peer owner never armed the native compaction admission for the attached socket"
    )
  end

  # The Pool's serving mode is written through the committed database the
  # peer shares, so the scope's owner is committed too.
  defp committed_owner_scope do
    %{user: owner} = AccountsFixtures.committed_bootstrap_owner_fixture!()
    Scope.for_user(owner, ["instance_owner"])
  end

  defp pool_requests(pool_id), do: Repo.all(from(request in Request, where: request.pool_id == ^pool_id, order_by: [asc: request.admitted_at, asc: request.id]))

  # Each response task settles its request after its terminal reached the
  # client; no completion signal reaches the test, so poll the rows.
  defp await_settled!(pool_id, expected) do
    await!(fn -> length(pool_requests(pool_id)) == length(expected) and Enum.all?(pool_requests(pool_id), &(&1.status not in ["accepted", "in_progress"])) end, "requests did not settle")
    pool_requests(pool_id)
  end

  defp await!(condition, message) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms

    Stream.repeatedly(condition)
    |> Enum.reduce_while(nil, fn
      true, _acc ->
        {:halt, :ok}

      false, _acc ->
        if System.monotonic_time(:millisecond) >= deadline, do: flunk(message)
        Process.sleep(10)
        {:cont, nil}
    end)
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

  defp receive_until_terminal(client, seen) do
    {client, frame} = receive_frame!(client)
    seen = [frame["type"] | seen]

    if frame["type"] in ["response.completed", "error", "response.failed"],
      do: {client, Enum.reverse(seen)},
      else: receive_until_terminal(client, seen)
  end

  defp send_frame!(client, text) do
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, text)
    %{client | conn: conn, websocket: websocket}
  end

  defp receive_frame!(client) do
    {conn, websocket, text} = public_websocket_receive_text!(client.conn, client.websocket, client.ref)
    {%{client | conn: conn, websocket: websocket}, CodexPooler.JSON.decode!(text)}
  end

  defp compaction_item, do: %{"type" => "compaction", "encrypted_content" => "synthetic-peer-delivery-compaction"}

  defp prompt(label), do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic #{label} prompt"}]}

  defp answer, do: %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}

  # The released Lite client opens a provider context with its tool manifest.
  defp context_prefix("lite"), do: [%{"type" => "additional_tools", "role" => "developer", "tools" => []}]
  defp context_prefix("full"), do: []

  defp turn_frame(ctx) do
    ctx
    |> frame(context_prefix(ctx.mode) ++ [prompt("first")], @turn_id, @window_id)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(%{"request_kind" => "turn"}))
    |> CodexPooler.JSON.encode!()
  end

  # As on the wire: the next turn's id, the previous turn's window and context
  # window, the admitted response as the anchor, and only the trigger.
  defp anchored_compaction_frame(ctx) do
    ctx
    |> frame([%{"type" => "compaction_trigger"}], @next_turn_id, @window_id)
    |> Map.put("previous_response_id", @anchor)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], compaction_metadata())
    |> CodexPooler.JSON.encode!()
  end

  defp full_history_compaction_frame(ctx) do
    ctx
    |> frame(context_prefix(ctx.mode) ++ [prompt("first"), answer(), %{"type" => "compaction_trigger"}], @next_turn_id, @window_id)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], compaction_metadata())
    |> CodexPooler.JSON.encode!()
  end

  # The same turn's request on the advanced window with the compacted history
  # and no anchor.
  defp resume_frame(ctx, item) do
    metadata = %{"request_kind" => "turn", "turn_id" => @next_turn_id, "root_turn_id" => @next_turn_id, "window_id" => @resumed_window_id, "window_number" => 1, "context_window_id" => @resumed_context_window_id}

    ctx
    |> frame(context_prefix(ctx.mode) ++ [item, prompt("next")], @next_turn_id, @resumed_window_id)
    |> put_in(["client_metadata", "x-codex-turn-metadata"], turn_metadata(metadata))
    |> CodexPooler.JSON.encode!()
  end

  defp compaction_metadata do
    compaction = %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses_compaction_v2", "phase" => "pre_turn", "strategy" => "memento"}
    turn_metadata(%{"request_kind" => "compaction", "compaction" => compaction, "turn_id" => @next_turn_id, "root_turn_id" => @next_turn_id})
  end

  defp frame(ctx, input, turn_id, window_id) do
    client_metadata = %{
      "session_id" => @thread_id,
      "thread_id" => @thread_id,
      "turn_id" => turn_id,
      "root_turn_id" => turn_id,
      "x-codex-installation-id" => @installation_id,
      "x-codex-window-id" => window_id,
      "x-codex-ws-stream-request-start-ms" => Integer.to_string(System.system_time(:millisecond))
    }

    base = %{
      "type" => "response.create",
      "model" => ctx.setup.model.exposed_model_id,
      "input" => input,
      "tool_choice" => "auto",
      "reasoning" => %{"effort" => "low"},
      "store" => false,
      "stream" => true,
      "include" => ["reasoning.encrypted_content"],
      "text" => %{"verbosity" => "low"},
      "prompt_cache_key" => @thread_id
    }

    case ctx.mode do
      "full" -> Map.merge(base, %{"instructions" => "synthetic instructions", "tools" => [], "parallel_tool_calls" => true, "client_metadata" => client_metadata})
      "lite" -> Map.merge(base, %{"parallel_tool_calls" => false, "client_metadata" => Map.put(client_metadata, @lite_marker, "true")})
    end
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

  defp usage, do: %{"input_tokens" => 20_000, "output_tokens" => 10, "total_tokens" => 20_010}

  defp completed_frames(response_id, output) do
    FakeUpstream.websocket_text_frames(
      [CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress"}})] ++
        Enum.map(output, &CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => &1})) ++
        [CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => output, "usage" => usage()}})]
    )
  end

  defp compaction_frames(item) do
    FakeUpstream.websocket_text_frames([
      CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => item}),
      CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => @compact_response, "status" => "completed", "output" => [item], "usage" => usage()}})
    ])
  end
end
