defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.AuthRefreshExhaustedFailoverTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [seed_preferring_assignment: 2, start_upstream: 1, start_public_endpoint_with_server!: 0, public_websocket_connect_with_request_headers!: 5, public_websocket_send_text!: 4, public_websocket_receive_text!: 3, capture_public_endpoint_identity!: 1, assert_public_endpoint_identity_released!: 1]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [execute_websocket_response: 4, strict_native_response: 4, websocket_auth_refresh_payload: 2, websocket_failover_candidates!: 3, route_circuit_failures: 1, account_reconciliation_jobs: 1, held_websocket_handshake_401: 2]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [start_shared_peer_session_owner!: 3]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{CodexSession, RoutingCircuitState}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams

  for mode <- ["full", "lite"] do
    @mode mode
    test "#{mode} exhausted refreshed handshake fails over exactly once" do
      first =
        start_upstream(
          FakeUpstream.strict_sequence([
            handshake_401(),
            FakeUpstream.expect_request(method: "POST", path: "/oauth/token", respond: FakeUpstream.json_response(%{"access_token" => "synthetic-refreshed-access"}, 200)),
            handshake_401()
          ])
        )

      second_server = start_upstream(FakeUpstream.strict_sequence([strict_native_response("resp_exhausted_auth_success", 1, 4, 3)]))
      {setup, second} = websocket_failover_candidates!(first, second_server, @mode)
      assert :ok = Events.subscribe_pool(setup.pool)
      assert {:ok, _secret} = Upstreams.store_encrypted_secret(setup.identity, %{secret_kind: "refresh_token", plaintext: "synthetic-refresh"})
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      request_id = seed_preferring_assignment([setup.assignment.id, second.assignment.id], setup.assignment.id)
      parent = self()
      result = execute_observed_response(auth, websocket_auth_refresh_payload(setup, "exhausted-auth"), %{request_id: request_id}, fn frame -> send(parent, {:result_frame, CodexPooler.JSON.decode!(frame) |> Map.take(["id", "type"])}) end)

      result_status =
        case result do
          :ok -> :ok
          {:error, error} -> {:error, Map.get(error, :code)}
          _other -> :unexpected
        end

      assert result_status == :ok
      assert_received {:result_frame, %{"id" => "resp_exhausted_auth_success"}}
      refute_received {:result_frame, _other}
      attempts = Repo.all(from a in Attempt, order_by: a.attempt_number)
      assert Enum.map(attempts, &{&1.pool_upstream_assignment_id, &1.status}) == [{setup.assignment.id, "retryable_failed"}, {setup.assignment.id, "retryable_failed"}, {second.assignment.id, "succeeded"}]
      request = await_settled_request!(setup.pool.id)
      assert request.status == "succeeded"
      assert request.retry_count == 2
      assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "settlement"), :count) == 1
      assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "release"), :count) == 1
      assert route_circuit_failures(setup.assignment.id) == [{"upstream_unauthorized", 1}]
      assert :ok = FakeUpstream.verify!(first)
      assert :ok = FakeUpstream.verify!(second_server)
    end
  end

  for topology <- [:direct, :local_owner], mode <- ["full", "lite"], route <- ["/backend-api/codex/responses", "/v1/responses"] do
    @tag topology: topology, mode: mode, route: route
    @tag :exhausted_auth_socket
    @tag slow: "drives released HTTP websocket framing across an auth refresh and failover"
    test "#{topology} #{mode} #{route} exhausted refresh reaches B without an intermediate terminal", ctx do
      assert_exhausted_socket_failover!(ctx)
    end
  end

  def assert_exhausted_socket_failover!(ctx) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, ctx.topology != :direct)
    first = start_upstream(FakeUpstream.strict_sequence([handshake_401(), refresh_success(), handshake_401()]))
    second_server = start_upstream(FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, respond: FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(completed_event())]))]))
    {setup, second} = websocket_failover_candidates!(first, second_server, ctx.mode)
    assert :ok = Events.subscribe_pool(setup.pool)
    assert {:ok, _secret} = Upstreams.store_encrypted_secret(setup.identity, %{secret_kind: "refresh_token", plaintext: "synthetic-refresh"})
    turn_state = Ecto.UUID.generate()
    session_attrs = if ctx.route == "/v1/responses", do: %{session_header: turn_state, session_header_source: "x-session-id"}, else: %{accepted_turn_state: turn_state}
    peer = if ctx.topology == :remote_owner, do: start_shared_peer_session_owner!(setup, session_attrs, ctx.peer_node)
    port = start_owned_endpoint!()
    headers = if ctx.route == "/v1/responses", do: [{"x-session-id", turn_state}], else: []
    {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, turn_state, ctx.route, headers)

    try do
      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, websocket_auth_refresh_payload(setup, "wire-auth-failover"))
      {_conn, _websocket, types, terminal} = receive_terminal(conn, websocket, ref, [])
      assert terminal["type"] == "response.completed"
      refute "error" in types
      refute "response.failed" in types
      request = await_settled_request!(setup.pool.id)
      assert_failover_rows!(setup, second, request)
      assert :ok = FakeUpstream.verify!(first)
      assert :ok = FakeUpstream.verify!(second_server)

      if ctx.topology != :direct do
        owner_metadata = request.request_metadata["websocket_owner_forwarding"]
        assert owner_metadata["enabled"] == true
        expected_node = if peer, do: peer.node, else: node()
        assert owner_metadata["owner_instance_id"] == Atom.to_string(expected_node)

        if peer do
          assert node(peer.owner_pid) != node()
          assert Repo.get!(CodexSession, peer.session.id).owner_instance_id == Atom.to_string(peer.node)
        end
      end
    after
      Mint.HTTP.close(conn)
    end
  end

  for mode <- ["full", "lite"], route <- ["/backend-api/codex/responses", "/v1/responses"] do
    @tag mode: mode, route: route
    test "#{mode} #{route} HTTP twin exhausts one refresh then succeeds on B", ctx do
      CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
      unauthorized = FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: FakeUpstream.json_response(%{"error" => %{"code" => "invalid_api_key"}}, 401))
      first = start_upstream(FakeUpstream.strict_sequence([unauthorized, refresh_success(), unauthorized]))
      second_server = start_upstream(FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: FakeUpstream.json_response(completed_event()["response"]))]))
      {setup, second} = websocket_failover_candidates!(first, second_server, ctx.mode)
      assert :ok = Events.subscribe_pool(setup.pool)
      assert {:ok, _secret} = Upstreams.store_encrypted_secret(setup.identity, %{secret_kind: "refresh_token", plaintext: "synthetic-refresh"})
      request_id = seed_preferring_assignment([setup.assignment.id, second.assignment.id], setup.assignment.id)
      port = start_owned_endpoint!()
      payload = websocket_auth_refresh_payload(setup, "http-twin") |> CodexPooler.JSON.decode!() |> Map.take(["model", "input"]) |> Map.put("stream", false)
      response = Req.post!("http://127.0.0.1:#{port}" <> ctx.route, headers: [{"authorization", setup.authorization}, {"x-request-id", request_id}], json: payload, retry: false)
      assert response.status == 200
      request = await_settled_request!(setup.pool.id)
      assert_failover_rows!(setup, second, request)
      assert :ok = FakeUpstream.verify!(first)
      assert :ok = FakeUpstream.verify!(second_server)
    end
  end

  test "exhausted refresh consumes the held circuit probe receipt exactly once before failing over" do
    release_ref = make_ref()
    first = start_upstream(FakeUpstream.strict_sequence([held_websocket_handshake_401(self(), release_ref), refresh_success(), handshake_401()]))
    second_server = start_upstream(FakeUpstream.strict_sequence([strict_native_response("resp_probe_failover", 1, 4, 3)]))
    {setup, second} = websocket_failover_candidates!(first, second_server, "full")
    assert :ok = Events.subscribe_pool(setup.pool)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    circuit = Repo.insert!(%RoutingCircuitState{pool_id: setup.pool.id, pool_upstream_assignment_id: setup.assignment.id, upstream_identity_id: setup.identity.id, model_identifier: setup.model.exposed_model_id, route_class: "proxy_websocket", status: "half_open", reason_code: "upstream_5xx", failure_count: 0, success_count: 0, opened_at: DateTime.add(now, -60, :second), half_opened_at: now, probe_generation: Ecto.UUID.generate(), probe_admission_ids: [], metadata: %{"probe_in_flight_count" => 0}, created_at: now, updated_at: now})
    assert {:ok, _secret} = Upstreams.store_encrypted_secret(setup.identity, %{secret_kind: "refresh_token", plaintext: "synthetic-refresh"})
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    request_id = seed_preferring_assignment([setup.assignment.id, second.assignment.id], setup.assignment.id)
    client = Task.async(fn -> execute_websocket_response(auth, websocket_auth_refresh_payload(setup, "probe"), %{request_id: request_id}, fn _frame -> :ok end) end)
    assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid, ^release_ref}, 15_000
    held = Repo.reload!(circuit)
    assert length(held.probe_admission_ids) == 1
    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
    assert :ok = Task.await(client, 15_000)
    request = await_settled_request!(setup.pool.id)
    assert_failover_rows!(setup, second, request)
    finished = Repo.reload!(circuit)
    assert finished.probe_admission_ids == []
    assert finished.metadata["probe_in_flight_count"] == 0
    assert finished.failure_count == 1
    assert :ok = FakeUpstream.verify!(first)
    assert :ok = FakeUpstream.verify!(second_server)
  end

  for mode <- ["full", "lite"] do
    @tag mode: mode
    test "#{mode} refreshed handshake on the last eligible candidate retains sanitized 503", ctx do
      first = start_upstream(FakeUpstream.strict_sequence([handshake_401(), refresh_success(), handshake_401()]))
      second_server = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
      {setup, second} = websocket_failover_candidates!(first, second_server, ctx.mode)
      assert :ok = Events.subscribe_pool(setup.pool)
      second.assignment |> Ecto.Changeset.change(status: "paused") |> Repo.update!()
      assert {:ok, _secret} = Upstreams.store_encrypted_secret(setup.identity, %{secret_kind: "refresh_token", plaintext: "synthetic-refresh"})
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      parent = self()
      result = execute_observed_response(auth, websocket_auth_refresh_payload(setup, "last-candidate"), %{}, fn _frame -> send(parent, :unexpected_auth_frame) end)
      assert {:error, %{status: 503, code: "upstream_unauthorized", message: "upstream authentication failed; retry the request"}} = result
      refute_received :unexpected_auth_frame
      request = await_settled_request!(setup.pool.id)
      assert request.status == "failed"
      attempts = Repo.all(from a in Attempt, where: a.request_id == ^request.id, order_by: a.attempt_number)
      assert Enum.map(attempts, & &1.status) == ["retryable_failed", "failed"]
      assert length(account_reconciliation_jobs(setup.identity.id)) == 1
      assert :ok = FakeUpstream.verify!(first)
      assert FakeUpstream.requests(second_server) == []
    end
  end

  for mode <- ["full", "lite"] do
    @tag mode: mode
    test "#{mode} first-event retry suppression remains after successful token refresh", ctx do
      refusal = %{"type" => "response.failed", "response" => %{"id" => "resp_retry_suppressed", "status" => "failed", "error" => %{"code" => "server_error", "message" => "synthetic refusal"}}}
      first = start_upstream(FakeUpstream.strict_sequence([handshake_401(), refresh_success(), FakeUpstream.expect_request(method: "WEBSOCKET", respond: FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(refusal)]))]))
      second_server = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
      {setup, second} = websocket_failover_candidates!(first, second_server, ctx.mode)
      assert :ok = Events.subscribe_pool(setup.pool)
      assert {:ok, _secret} = Upstreams.store_encrypted_secret(setup.identity, %{secret_kind: "refresh_token", plaintext: "synthetic-refresh"})
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      request_id = seed_preferring_assignment([setup.assignment.id, second.assignment.id], setup.assignment.id)
      parent = self()
      _result = execute_observed_response(auth, websocket_auth_refresh_payload(setup, "first-event-after-refresh"), %{request_id: request_id}, fn frame -> send(parent, {:suppressed_frame_type, CodexPooler.JSON.decode!(frame)["type"]}) end)
      request = await_settled_request!(setup.pool.id)
      assert request.status == "failed"
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 2
      assert_received {:suppressed_frame_type, "response.failed"}
      assert FakeUpstream.requests(second_server) == []
      assert :ok = FakeUpstream.verify!(first)
    end
  end

  defp execute_observed_response(auth, payload, options, push_frame) do
    Task.async(fn -> execute_websocket_response(auth, payload, options, push_frame) end)
    |> Task.await(15_000)
  end

  defp start_owned_endpoint! do
    {server, port} = start_public_endpoint_with_server!()
    ownership = capture_public_endpoint_identity!(server)

    on_exit(fn ->
      monitor = Process.monitor(server)

      try do
        ThousandIsland.stop(server)
      catch
        :exit, _already_stopped -> :ok
      end

      assert_receive {:DOWN, ^monitor, :process, ^server, _reason}, 15_000
      assert_public_endpoint_identity_released!(ownership)
    end)

    port
  end

  defp assert_failover_rows!(setup, second, request) do
    assert request.status == "succeeded"
    assert request.retry_count == 2
    attempts = Repo.all(from a in Attempt, where: a.request_id == ^request.id, order_by: a.attempt_number)
    assert Enum.map(attempts, &{&1.pool_upstream_assignment_id, &1.status}) == [{setup.assignment.id, "retryable_failed"}, {setup.assignment.id, "retryable_failed"}, {second.assignment.id, "succeeded"}]
    assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "settlement"), :count) == 1
    assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "release"), :count) == 1
    assert route_circuit_failures(setup.assignment.id) == [{"upstream_unauthorized", 1}]
    assert length(account_reconciliation_jobs(setup.identity.id)) == 1
    circuits = Repo.all(from c in RoutingCircuitState, where: c.pool_upstream_assignment_id == ^setup.assignment.id)
    assert Enum.all?(circuits, &(&1.probe_admission_ids == []))
  end

  defp receive_terminal(conn, websocket, ref, types) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)
    decoded = CodexPooler.JSON.decode!(frame)
    type = decoded["type"]
    types = if type == "codex.response.metadata", do: types, else: types ++ [type]
    if type in ["response.completed", "response.failed", "error"], do: {conn, websocket, types, decoded}, else: receive_terminal(conn, websocket, ref, types)
  end

  defp await_settled_request!(pool_id) do
    assert_receive {Events, %{pool_id: ^pool_id, reason: "request_finalized", payload: %{"request_id" => request_id, "status" => status}}}
                   when status in ["succeeded", "failed"],
                   15_000

    request = Repo.get!(Request, request_id)
    assert request.pool_id == pool_id
    assert request.status == status
    refute is_nil(request.completed_at)
    request
  end

  defp completed_event do
    %{"type" => "response.completed", "response" => %{"id" => "resp_exhausted_wire_success", "object" => "response", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}}}
  end

  defp refresh_success do
    FakeUpstream.expect_request(method: "POST", path: "/oauth/token", respond: FakeUpstream.json_response(%{"access_token" => "synthetic-refreshed-access"}, 200))
  end

  defp handshake_401 do
    FakeUpstream.expect_request(method: "GET", respond: FakeUpstream.websocket_upgrade_error(%{"error" => %{"code" => "invalid_api_key"}}, status: 401, headers: [{"x-openai-authorization-error", "invalid_api_key"}]))
  end
end

defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.AuthRefreshExhaustedFailoverPeerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexWebsocket.AuthRefreshExhaustedFailoverTest, only: [assert_exhausted_socket_failover!: 1]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_shared_bridge_peer!: 0]

  @moduletag topology: :remote_owner
  @moduletag :exhausted_auth_socket
  @moduletag slow: "drives released HTTP websocket framing through a remote owner across an auth refresh and failover"

  setup_all do
    %{peer_node: start_shared_bridge_peer!()}
  end

  setup do
    enter_peer_owner_topology!()
    :ok
  end

  for mode <- ["full", "lite"], route <- ["/backend-api/codex/responses", "/v1/responses"] do
    @tag mode: mode, route: route
    test "remote_owner #{mode} #{route} exhausted refresh reaches B without an intermediate terminal", ctx do
      assert_exhausted_socket_failover!(ctx)
    end
  end
end
