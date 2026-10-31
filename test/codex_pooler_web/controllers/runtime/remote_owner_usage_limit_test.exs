defmodule CodexPoolerWeb.Runtime.RemoteOwnerUsageLimitTest do
  # The usage-limit answers of findings#206 rows 206-592, 206-593, 206-596,
  # 206-598 and 206-599, and the held-back partition hop of row 206-586, with
  # the session's owner and its provider connection on a second VM sharing the
  # committed database and the socket on this node, as when a production turn
  # lands on the other web pod (row 206-600, row 206-601 for the hop). The
  # one-node arms live with each row's own test; these re-run them over a
  # remote owner, which serves every account of the Pool the turn fails over
  # to.
  #
  # Two BEAM nodes (the module boots the peer once), owner forwarding on,
  # FakeUpstream; Full and Lite.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_shared_bridge_peer!: 0, start_shared_peer_session_owner!: 3]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn, RoutingCircuitState}
  alias CodexPooler.Gateway.Runtime.Dispatch.WebsocketAttempt
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.EncryptedCollaborationHistory

  @moduletag capture_log: true

  @turn_endpoint "/backend-api/codex/responses"
  @lite_header "x-openai-internal-codex-responses-lite"
  @provider_message "synthetic provider usage limit text"
  @reset_seconds 3_600
  # The terminal goes out right after the last refusal; the 206-598 defect
  # held it for a fixed five seconds.
  @terminal_budget_ms 2_500

  setup_all do
    %{peer_node: start_shared_bridge_peer!()}
  end

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    enter_peer_owner_topology!()
    :ok = Logger.put_module_level(WebsocketAttempt, :info)
    on_exit(fn -> Logger.delete_module_level(WebsocketAttempt) end)
    :ok
  end

  for mode <- ["full", "lite"] do
    @mode mode

    for kind <- [:agent_handoff, :send_message, :spawn_agent, :followup_task] do
      @tag history_kind: kind
      test "native websocket #{mode}: #{kind} history leaves an exhausted remote owner account", context do
        exhausted_history!(context, @mode)
      end
    end

    test "native websocket #{mode}: encrypted collaboration history survives a pre-output provider quota refusal", %{peer_node: peer_node} do
      pre_output_collaboration_failover!(peer_node, @mode)
    end

    # Rows 206-598 and 206-599 over a remote owner.
    test "public /v1 websocket #{mode}: a failover the sibling serves reaches the client", %{peer_node: peer_node} do
      pool = failover_pool!(@mode, served_frames())
      turn_state = "remote-owner-served-#{System.unique_integer([:positive])}"
      peer = start_shared_peer_session_owner!(pool, %{accepted_turn_state: turn_state}, peer_node)

      {event, elapsed_ms} = public_turn!(pool, turn_state)

      diagnostics("206-600 served #{@mode}", elapsed_ms, event)
      assert %{"type" => "response.completed", "response" => %{"id" => "resp_remote_owner_served"}} = event
      assert elapsed_ms < @terminal_budget_ms
      assert {FakeUpstream.websocket_connection_count(pool.upstream), FakeUpstream.websocket_connection_count(pool.sibling_upstream)} == {1, 1}
      assert %{"outcome" => "delivered", "terminal_class" => "response.completed"} = final_receipt!(pool)
      assert_peer_owner_served!(peer)
    end

    test "public /v1 websocket #{mode}: the last candidate's usage limit goes out at once", %{peer_node: peer_node} do
      pool = failover_pool!(@mode, [provider_frame(reset_at())])
      turn_state = "remote-owner-refused-#{System.unique_integer([:positive])}"
      peer = start_shared_peer_session_owner!(pool, %{accepted_turn_state: turn_state}, peer_node)

      {event, elapsed_ms} = public_turn!(pool, turn_state)

      diagnostics("206-600 refused #{@mode}", elapsed_ms, event)
      assert %{"type" => "error", "status" => 429} = event
      refute CodexPooler.JSON.encode!(event) =~ @provider_message
      assert elapsed_ms < @terminal_budget_ms
      assert {FakeUpstream.websocket_connection_count(pool.upstream), FakeUpstream.websocket_connection_count(pool.sibling_upstream)} == {1, 1}
      assert %{"outcome" => "delivered", "terminal_class" => "error"} = final_receipt!(pool)
      assert [%Request{status: "failed", response_status_code: 429}] = settled_rows!(pool)
      assert_peer_owner_served!(peer)
    end

    # Rows 206-592 and 206-596 over a remote owner: the Pool's advice is
    # withheld (the sibling is behind an open circuit).
    test "native websocket #{mode}: a withheld-advice usage limit is the classified wrapped 429, recorded and logged", %{peer_node: peer_node} do
      resets_at = reset_at()
      pool = withheld_pool!(@mode, FakeUpstream.websocket_text_frames([provider_frame(resets_at)]))
      thread_id = Ecto.UUID.generate()
      peer = start_shared_peer_session_owner!(pool, window_session(thread_id), peer_node)

      # The line is logged after the frame went out: the capture waits for the
      # settled row.
      {{event, rows}, log} = with_log([level: :info], fn -> {native_turn!(pool, thread_id), settled_rows!(pool)} end)

      diagnostics("206-600 native withheld #{@mode}", 0, event)
      assert %{"type" => "error", "status" => 429, "error" => error} = event
      assert %{"type" => "usage_limit_reached", "message" => "upstream usage limit reached", "resets_at" => ^resets_at} = error
      refute CodexPooler.JSON.encode!(event) =~ @provider_message
      assert [%Request{status: "failed", response_status_code: 429}] = rows
      assert log =~ ~r/websocket usage limit answered .*status=429.*advice=withheld/
      assert FakeUpstream.count(pool.sibling_upstream) == 0
      assert_peer_owner_served!(peer)
    end

    # Row 206-596 over a remote owner: the terminal answer's advised reset.
    test "native websocket #{mode}: the terminal usage limit records its 429 and advised reset, and logs them", %{peer_node: peer_node} do
      resets_at = reset_at()
      upstream = start_upstream(FakeUpstream.websocket_text_frames([provider_frame(resets_at)]))
      pool = upstream |> gateway_setup(quota?: false) |> Map.put(:upstream, upstream)
      prime_routing_quota!(pool.identity)
      put_serving_mode!(pool, @mode)
      thread_id = Ecto.UUID.generate()
      peer = start_shared_peer_session_owner!(pool, window_session(thread_id), peer_node)

      {{event, rows}, log} = with_log([level: :info], fn -> {native_turn!(Map.put(pool, :mode, @mode), thread_id), settled_rows!(pool)} end)

      diagnostics("206-600 native terminal #{@mode}", 0, event)
      assert %{"type" => "error", "status" => 429, "error" => %{"type" => "usage_limit_reached", "resets_at" => ^resets_at, "resets_in_seconds" => seconds}} = event
      assert [%Request{response_status_code: 429} = request] = rows
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.response_metadata["usage_limit"] == %{"resets_at" => resets_at, "resets_in_seconds" => seconds}
      assert log =~ ~r/websocket usage limit answered .*status=429.*resets_at=#{resets_at} resets_in_seconds=#{seconds}/
      assert_peer_owner_served!(peer)
    end

    # Row 206-593 over a remote owner: a streaming /v1 turn bridged onto the
    # peer owner's provider connection answers the /v1 relayed contract.
    test "bridged /v1 #{mode}: a withheld-advice usage limit answers the /v1 relayed 429 with the circuit wait", %{conn: conn, peer_node: peer_node} do
      pool = withheld_pool!(@mode, FakeUpstream.websocket_text_frames([provider_frame(reset_at())]))
      session_id = "remote-owner-bridge-#{System.unique_integer([:positive])}"
      peer = start_shared_peer_session_owner!(pool, %{session_header: session_id, session_header_source: "x-session-id"}, peer_node)

      bridged =
        conn
        |> auth(pool)
        |> maybe_lite(pool)
        |> put_req_header("x-session-id", session_id)
        |> post("/v1/responses", %{"model" => pool.model.exposed_model_id, "input" => "synthetic remote owner prompt", "stream" => true})

      CodexPooler.TestDiagnostics.puts(fn -> "206-600 bridged #{@mode}: #{bridged.status} #{inspect(get_resp_header(bridged, "retry-after"))} #{bridged.resp_body}" end)
      assert bridged.status == 429
      assert %{"error" => %{"type" => "rate_limit_error", "code" => "upstream_rate_limited"}} = CodexPooler.JSON.decode!(bridged.resp_body)
      assert [seconds] = get_resp_header(bridged, "retry-after")
      assert String.to_integer(seconds) in 55..60
      assert get_resp_header(bridged, "x-should-retry") == []
      refute bridged.resp_body =~ @provider_message
      assert {FakeUpstream.websocket_connection_count(pool.upstream), FakeUpstream.http_request_count(pool.upstream)} == {1, 0}
      assert [%Request{status: "failed", response_status_code: 429}] = settled_rows!(pool)
      assert_peer_owner_served!(peer)
    end

    # Row 206-601: the held-back partition hop of row 206-586 over a remote
    # owner. Partition T (older anchor): the refusing account and an exhausted
    # sibling; partition P: one account with a behavioral source drift.
    test "native websocket #{mode}: the refused first frame moves the turn to the held-back partition", %{peer_node: peer_node} do
      pool = split_pool!(@mode)
      thread_id = Ecto.UUID.generate()
      peer = start_shared_peer_session_owner!(pool, window_session(thread_id), peer_node)

      event = native_turn!(pool, thread_id)

      diagnostics("206-601 partition #{@mode}", 0, event)
      assert %{"type" => "response.completed"} = event
      assert [row] = settled_rows!(pool)

      assert Repo.all(from(a in Attempt, where: a.request_id == ^row.id, order_by: [asc: a.attempt_number], select: {a.status, a.pool_upstream_assignment_id})) ==
               [{"retryable_failed", pool.assignment.id}, {"succeeded", pool.other.assignment.id}]

      assert %{"partition_count" => 2, "routable_selection" => false} = row.request_metadata["canonical_partition"]
      assert FakeUpstream.websocket_connection_count(pool.exhausted_upstream) == 0
      assert_peer_owner_served!(peer)
    end
  end

  defp pre_output_collaboration_failover!(peer_node, mode) do
    pool = failover_pool!(mode, served_frames())
    turn_state = "remote-quota-collaboration-#{System.unique_integer([:positive])}"
    peer = start_shared_peer_session_owner!(pool, %{accepted_turn_state: turn_state}, peer_node)
    port = start_public_endpoint!()
    {conn, websocket, ref} = public_websocket_connect!(port, pool, turn_state)
    history = native_text_input("synthetic completed collaboration") ++ EncryptedCollaborationHistory.items(:send_message)
    payload = %{"type" => "response.create", "model" => pool.model.exposed_model_id, "input" => history, "stream" => true}

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(payload))
      {_conn, _websocket, terminal} = native_terminal_state!(conn, websocket, ref)
      assert %{"type" => "response.completed"} = terminal
      assert [%Request{status: "succeeded", transport: "websocket"} = row] = settled_rows!(pool)

      assert Repo.all(from(a in Attempt, where: a.request_id == ^row.id, order_by: [asc: a.attempt_number], select: {a.status, a.pool_upstream_assignment_id})) ==
               [{"retryable_failed", pool.assignment.id}, {"succeeded", pool.sibling.assignment.id}]

      assert [refused, _served] = Repo.all(from(a in Attempt, where: a.request_id == ^row.id, order_by: [asc: a.attempt_number]))
      assert refused.upstream_status_code == 200
      assert refused.response_metadata["stream_error_code"] == "usage_limit_reached"
      assert refused.response_metadata["stream_terminal_type"] == "error"
      assert refused.response_metadata["quota_rejection_before_output"] == true
      assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^row.id and l.entry_kind == "settlement"), :count) == 1
      assert {FakeUpstream.count(pool.upstream), FakeUpstream.count(pool.sibling_upstream)} == {1, 1}
      assert FakeUpstream.http_request_count(pool.upstream) == 0
      assert FakeUpstream.http_request_count(pool.sibling_upstream) == 0
      assert [%{json: moved}] = FakeUpstream.requests(pool.sibling_upstream)
      assert_preserved_collaboration!(moved, :send_message)
      assert_peer_owner_served!(peer)
    after
      Mint.HTTP.close(conn)
    end
  end

  defp exhausted_history!(%{peer_node: peer_node, history_kind: kind}, mode) do
    upstream = start_upstream(FakeUpstream.websocket_text_frames(served_frames()))
    sibling_upstream = start_upstream(FakeUpstream.websocket_text_frames(served_frames()))
    setup = gateway_setup(upstream, quota?: false)
    sibling = gateway_upstream(setup.pool, sibling_upstream, "upstream-token-handoff-sibling", compact?: false)
    use_routing_strategy!(setup.pool, "quota_first", 2)
    prime_routing_quota!(setup.identity, %{used_percent: Decimal.new("10")})
    prime_routing_quota!(sibling.identity, %{used_percent: Decimal.new("90")})
    pool = pool_with_sibling!(setup, mode, upstream, sibling, sibling_upstream)
    turn_state = "remote-handoff-#{System.unique_integer([:positive])}"
    peer = start_shared_peer_session_owner!(pool, %{accepted_turn_state: turn_state}, peer_node)
    port = start_public_endpoint!()
    {conn, websocket, ref} = public_websocket_connect!(port, pool, turn_state)

    try do
      opening = %{"type" => "response.create", "model" => pool.model.exposed_model_id, "input" => native_text_input("synthetic opening"), "stream" => true}
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(opening))
      {conn, websocket, terminal} = native_terminal_state!(conn, websocket, ref)
      assert %{"type" => "response.completed"} = terminal
      assert [%Request{status: "succeeded"} = first] = settled_rows!(pool)
      await_session_assignment!(peer.session.id, setup.assignment.id)
      prime_exhausted_routing_quota!(setup.identity)

      anchored = opening |> Map.put("previous_response_id", "resp_remote_owner_served") |> Map.put("input", [%{"type" => "function_call_output", "call_id" => "call_synthetic_anchor", "output" => "synthetic result"}])
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(anchored))
      {conn, websocket, terminal} = native_terminal_state!(conn, websocket, ref)
      assert %{"type" => "error", "status" => 503, "error" => %{"code" => "pinned_continuation_unavailable"}} = terminal
      assert [_, %Request{status: "rejected"} = denied] = settled_rows!(pool)
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^denied.id), :count) == 0
      assert Repo.aggregate(from(t in CodexTurn, where: t.request_id == ^denied.id), :count) == 0
      assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^denied.id), :count) == 0

      history = Map.put(opening, "input", opening["input"] ++ portable_history(kind))
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(history))
      {_conn, _websocket, terminal} = native_terminal_state!(conn, websocket, ref)
      assert %{"type" => "response.completed"} = terminal
      assert [_, _, %Request{status: "succeeded", transport: "websocket"} = moved_row] = settled_rows!(pool)
      assert moved_row.request_metadata["codex_session_id"] == first.request_metadata["codex_session_id"]
      assert get_in(moved_row.request_metadata, ["routing", "model_serving_mode"]) == mode
      assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^moved_row.id and l.entry_kind == "settlement"), :count) == 1
      await_session_assignment!(peer.session.id, sibling.assignment.id)
      assert {FakeUpstream.count(upstream), FakeUpstream.count(sibling_upstream)} == {1, 1}
      assert FakeUpstream.http_request_count(upstream) == 0
      assert FakeUpstream.http_request_count(sibling_upstream) == 0
      assert [%{json: moved}] = FakeUpstream.requests(sibling_upstream)
      refute Map.has_key?(moved, "previous_response_id")
      for item <- portable_history(kind), do: assert(Enum.count(moved["input"], &(&1 == item)) == 1)
      assert_peer_owner_served!(peer)
    after
      Mint.HTTP.close(conn)
    end
  end

  defp portable_history(:agent_handoff) do
    [%{"type" => "agent_message", "author" => "/root/sample", "recipient" => "/root", "content" => [%{"type" => "input_text", "text" => "Message Type: MESSAGE\nTask name: /root\nSender: /root/sample\nPayload:\n"}, %{"type" => "encrypted_content", "encrypted_content" => "synthetic-peer-handoff"}]}]
  end

  defp portable_history(kind), do: EncryptedCollaborationHistory.items(kind)

  defp assert_preserved_collaboration!(payload, kind) do
    refute Map.has_key?(payload, "previous_response_id")
    for item <- EncryptedCollaborationHistory.items(kind), do: assert(Enum.count(payload["input"], &(&1 == item)) == 1)
  end

  defp await_session_assignment!(session_id, assignment_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000
    actual = Repo.get!(CodexSession, session_id).pool_upstream_assignment_id

    if actual == assignment_id do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "session assignment did not finish updating"

      receive do
      after
        5 -> await_session_assignment!(session_id, assignment_id, deadline)
      end
    end
  end

  defp reset_at, do: DateTime.to_unix(DateTime.utc_now()) + @reset_seconds

  defp provider_frame(resets_at) do
    CodexPooler.JSON.encode!(%{
      "type" => "error",
      "status" => 429,
      "error" => %{"type" => "usage_limit_reached", "message" => @provider_message, "plan_type" => "team", "resets_at" => resets_at, "resets_in_seconds" => @reset_seconds}
    })
  end

  defp served_frames do
    [
      CodexPooler.JSON.encode!(%{"type" => "response.output_text.delta", "delta" => "synthetic", "item_id" => "msg_remote_owner_served", "output_index" => 0, "content_index" => 0}),
      CodexPooler.JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_remote_owner_served", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}}
      })
    ]
  end

  # The first account refuses with a usage limit and routes first (quota-first
  # routing, more quota left); the sibling answers `sibling_frames`.
  defp failover_pool!(mode, sibling_frames) do
    upstream = start_upstream(FakeUpstream.websocket_text_frames([provider_frame(reset_at())]))
    sibling_upstream = start_upstream(FakeUpstream.websocket_text_frames(sibling_frames))
    setup = gateway_setup(upstream, quota?: false)
    sibling = gateway_upstream(setup.pool, sibling_upstream, "upstream-token-remote-owner-sibling", compact?: false)
    use_routing_strategy!(setup.pool, "quota_first", 2)
    prime_routing_quota!(setup.identity, %{used_percent: Decimal.new("10")})
    prime_routing_quota!(sibling.identity, %{used_percent: Decimal.new("90")})
    pool_with_sibling!(setup, mode, upstream, sibling, sibling_upstream)
  end

  # The refusing account and a sibling behind an open circuit, so the Pool's
  # return is not known.
  defp withheld_pool!(mode, refusing_mode) do
    upstream = start_upstream(refusing_mode)
    sibling_upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(upstream, quota?: false)
    sibling = gateway_upstream(setup.pool, sibling_upstream, "upstream-token-remote-owner-withheld", compact?: false)
    prime_routing_quota!(setup.identity)
    prime_routing_quota!(sibling.identity)
    pool = pool_with_sibling!(setup, mode, upstream, sibling, sibling_upstream)
    open_circuit!(pool, sibling.assignment)
    pool
  end

  defp pool_with_sibling!(setup, mode, upstream, sibling, sibling_upstream) do
    model = put_model_source_assignments!(setup.model, [setup.assignment, sibling.assignment])
    setup = %{setup | model: model}
    put_serving_mode!(setup, mode)
    Map.merge(setup, %{mode: mode, upstream: upstream, sibling: sibling, sibling_upstream: sibling_upstream})
  end

  defp split_pool!(mode) do
    resets_at = DateTime.to_unix(DateTime.utc_now()) + 3 * 86_400

    refusing_frame =
      CodexPooler.JSON.encode!(%{
        "type" => "error",
        "status" => 429,
        "error" => %{"type" => "usage_limit_reached", "message" => @provider_message, "resets_at" => resets_at},
        "headers" => %{"x-codex-secondary-used-percent" => "100", "x-codex-secondary-window-minutes" => "10080", "x-codex-secondary-reset-at" => Integer.to_string(resets_at)}
      })

    completed = CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_remote_owner_partition", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}}})
    refusing_upstream = start_upstream(FakeUpstream.websocket_text_frames([refusing_frame]))
    exhausted_upstream = start_upstream(FakeUpstream.websocket_text_frames([completed]))
    other_upstream = start_upstream(FakeUpstream.websocket_text_frames([completed]))

    setup = gateway_setup(refusing_upstream, quota?: false)
    anchor = setup.assignment.created_at
    exhausted = setup.pool |> gateway_upstream(exhausted_upstream, "upstream-token-remote-owner-exhausted", compact?: false) |> shift_created_at!(anchor, 1)
    other = setup.pool |> gateway_upstream(other_upstream, "upstream-token-remote-owner-other", compact?: false) |> shift_created_at!(anchor, 2)
    prime_routing_quota!(setup.identity)
    prime_exhausted_routing_quota!(exhausted.identity, %{reset_at: DateTime.utc_now() |> DateTime.add(7_200, :second) |> DateTime.truncate(:second)})
    prime_routing_quota!(other.identity)

    model =
      setup.model
      |> put_model_source_assignments!([setup.assignment, exhausted.assignment, other.assignment])
      |> put_behavioral_drift!(other.assignment)

    setup = %{setup | model: model}
    put_serving_mode!(setup, mode)
    Map.merge(setup, %{mode: mode, exhausted: exhausted, other: other, exhausted_upstream: exhausted_upstream})
  end

  # The serving mode is written as the override row itself: the admin write
  # would commit an operator and its audit event beside the Pool (the peer
  # shares the committed database), which the Pool's cleanup does not remove.
  defp put_serving_mode!(setup, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: mode, created_at: timestamp, updated_at: timestamp})
  end

  defp shift_created_at!(upstream, anchor, seconds) do
    assignment = upstream.assignment |> Ecto.Changeset.change(created_at: DateTime.add(anchor, seconds, :second)) |> Repo.update!()
    %{upstream | assignment: assignment}
  end

  defp put_behavioral_drift!(model, assignment) do
    sources = Map.fetch!(model.metadata, "source_assignment_models")
    sources = Map.update!(sources, assignment.id, &Map.put(&1, "context_window", 111_111))
    model |> Ecto.Changeset.change(metadata: Map.put(model.metadata, "source_assignment_models", sources)) |> Repo.update!()
  end

  defp open_circuit!(pool, assignment) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for route_class <- ["proxy_http", "proxy_stream", "proxy_websocket"] do
      Repo.insert!(%RoutingCircuitState{
        pool_id: pool.pool.id,
        pool_upstream_assignment_id: assignment.id,
        upstream_identity_id: assignment.upstream_identity_id,
        model_identifier: pool.model.exposed_model_id,
        route_class: route_class,
        status: "open",
        reason_code: "upstream_5xx",
        failure_count: 3,
        success_count: 0,
        opened_at: now,
        last_failure_at: now,
        next_probe_at: DateTime.add(now, 60, :second),
        metadata: %{"probe_in_flight_count" => 0},
        created_at: now,
        updated_at: now
      })
    end
  end

  defp window_session(thread_id), do: %{session_header: "#{thread_id}:0", session_header_source: "x-codex-window-id"}

  defp maybe_lite(conn, %{mode: "lite"}), do: put_req_header(conn, @lite_header, "true")
  defp maybe_lite(conn, _pool), do: conn

  defp native_turn!(pool, thread_id) do
    {_server, port} = start_public_endpoint_with_server!()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers =
      [
        {"authorization", pool.authorization},
        {"session-id", thread_id},
        {"thread-id", thread_id},
        {"x-client-request-id", thread_id},
        {"x-codex-window-id", "#{thread_id}:0"}
      ] ++ if(pool.mode == "lite", do: [{@lite_header, "true"}], else: [])

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, @turn_endpoint, headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    frame =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => pool.model.exposed_model_id,
        "instructions" => "synthetic instructions",
        "input" => native_text_input("synthetic remote owner prompt"),
        "tools" => [],
        "tool_choice" => "auto",
        "parallel_tool_calls" => true,
        "store" => false,
        "stream" => true,
        "client_metadata" => %{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "#{thread_id}-turn"}
      })

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, frame)
      native_terminal!(conn, websocket, ref)
    after
      Mint.HTTP.close(conn)
    end
  end

  defp native_terminal!(conn, websocket, ref) do
    {_conn, _websocket, terminal} = native_terminal_state!(conn, websocket, ref)
    terminal
  end

  defp native_terminal_state!(conn, websocket, ref) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)

    case CodexPooler.JSON.decode!(text) do
      %{"type" => type} = terminal when type in ["response.completed", "response.failed", "error"] -> {conn, websocket, terminal}
      _progress -> native_terminal_state!(conn, websocket, ref)
    end
  end

  defp public_turn!(pool, turn_state) do
    port = start_public_endpoint!()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
    headers = [{"authorization", pool.authorization}, {"x-codex-turn-state", turn_state}, {"openai-beta", "responses_websockets=2026-02-06"}]
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/v1/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)

    try do
      payload = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => pool.model.exposed_model_id, "input" => "synthetic remote owner prompt", "stream" => true})
      started = System.monotonic_time(:millisecond)
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
      event = native_terminal!(conn, websocket, ref)
      {event, System.monotonic_time(:millisecond) - started}
    after
      Mint.HTTP.close(conn)
    end
  end

  # The socket forwarded to the peer's owner: the peer owner still holds the
  # session's lease, and no owner of the session runs here.
  defp assert_peer_owner_served!(peer) do
    assert Repo.get!(CodexSession, peer.session.id).owner_instance_id == Atom.to_string(peer.node)
    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(peer.session.id)
  end

  defp settled_rows!(pool) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn -> Repo.all(from(r in Request, where: r.pool_id == ^pool.pool.id, order_by: [asc: r.admitted_at])) end)
    |> Enum.reduce_while(nil, fn rows, _acc ->
      cond do
        rows != [] and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) -> {:halt, rows}
        System.monotonic_time(:millisecond) >= deadline -> {:halt, rows}
        true -> Process.sleep(10) && {:cont, nil}
      end
    end)
  end

  # The socket writes the turn's delivery receipt onto its last attempt after
  # it pushed the terminal and the gateway settled the turn.
  defp final_receipt!(pool) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn ->
      Repo.all(
        from(a in Attempt,
          join: r in Request,
          on: r.id == a.request_id,
          where: r.pool_id == ^pool.pool.id and r.status not in ["accepted", "in_progress"],
          order_by: [desc: a.attempt_number],
          limit: 1,
          select: a.response_metadata
        )
      )
    end)
    |> Enum.reduce_while(nil, fn
      [%{"downstream_delivery" => receipt}], _acc -> {:halt, receipt}
      _rows, _acc -> if System.monotonic_time(:millisecond) >= deadline, do: {:halt, nil}, else: Process.sleep(10) && {:cont, nil}
    end)
  end

  defp diagnostics(label, elapsed_ms, event), do: CodexPooler.TestDiagnostics.puts(fn -> "#{label}: #{elapsed_ms} ms #{CodexPooler.JSON.encode!(event)}" end)
end
