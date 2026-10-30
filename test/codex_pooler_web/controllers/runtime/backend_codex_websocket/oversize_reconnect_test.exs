defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.OversizeReconnectTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, as: OwnerSupport
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport
  alias CodexPoolerWeb.Runtime.MailboxPrefixRaceSupport, as: PeerSupport
  alias Ecto.Adapters.SQL.Sandbox

  @native "/backend-api/codex/responses"
  @window [{"x-codex-window-id", "synthetic-size-window"}]

  setup_all do
    remote = PeerSupport.start_http_peer!()
    %{remote: remote, remote_port: PeerSupport.start_peer_listener!(remote)}
  end

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    fixture = gateway_setup(upstream, model_metadata: %{"supported_input_modalities" => ["text", "image"]})
    register_unboxed_pool_cleanup!(fixture)
    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)
    %{fixture: fixture, auth: auth, upstream: upstream, port: start_public_endpoint!()}
  end

  @tag :encrypted_tools
  test "an unassigned peer owner rejects encrypted tool history before dispatch and another node serves unchanged HTTP history", ctx do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    OwnerSupport.enter_peer_owner_topology!()
    window = Ecto.UUID.generate()
    headers = [{"x-codex-window-id", window}]
    {session, owner} = OwnerSupport.start_remote_session_owner!(ctx.auth, %{session_header: window, session_header_source: "x-codex-window-id"}, ctx.remote, :real)
    assert node(owner) == ctx.remote
    assert %CodexSession{pool_upstream_assignment_id: nil, recreated_from_assignment_id: nil, previous_window_assignment_id: nil} = session
    FakeUpstream.set_mode(ctx.upstream, FakeUpstream.sse_stream([{"response.completed", %{"type" => "response.completed", "response" => %{"status" => "completed", "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}}]))
    payload = %{"type" => "response.create", "model" => ctx.fixture.model.exposed_model_id, "input" => encrypted_tool_history(), "stream" => true}
    refute RequestOptions.build(%{}, @native, payload).payload_context.portable_full_history?
    {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(ctx.port, ctx.fixture, Ecto.UUID.generate(), @native, headers)
    on_exit(fn -> Mint.HTTP.close(conn) end)

    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(payload))
    {_conn, _websocket, frames} = BackendCodexWebsocketSupport.receive_frames_until_close!(conn, websocket, ref)
    assert [{:text, refusal}, {:close, 1011, _}] = frames
    assert %{"type" => "error", "status" => 502, "error" => %{"code" => "upstream_request_failed"}} = CodexPooler.JSON.decode!(refusal)
    assert FakeUpstream.count(ctx.upstream) == 0
    assert [%Request{status: "rejected", usage_status: "not_applicable", response_status_code: 413}] = Repo.all(from r in Request, where: r.pool_id == ^ctx.fixture.pool.id)
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(CodexTurn, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0
    assert handshake(ctx.remote_port, ctx.fixture.authorization, @native, headers).status == 426

    response = Req.post!("http://127.0.0.1:#{ctx.remote_port}" <> @native, headers: [{"authorization", ctx.fixture.authorization} | headers], json: Map.delete(payload, "type"), receive_timeout: 15_000, retry: false)
    assert response.status == 200
    assert response.body =~ "response.completed"
    [captured] = FakeUpstream.requests(ctx.upstream)
    assert captured.method == "POST"
    assert :crypto.hash(:sha256, :erlang.term_to_binary(captured.json["input"])) == :crypto.hash(:sha256, :erlang.term_to_binary(payload["input"]))
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^ctx.fixture.pool.id and r.status == "succeeded"), :count) == 1
    assert Repo.aggregate(Attempt, :count) == 1
    assert Repo.aggregate(from(l in LedgerEntry, where: l.entry_kind == "settlement"), :count) == 1
    assert :ok = FakeUpstream.verify!(ctx.upstream)
  end

  defp encrypted_tool_history do
    image = %{"type" => "input_image", "image_url" => "data:image/png;base64," <> String.duplicate("A", 512 * 1024)}

    [
      %{"type" => "message", "role" => "user", "content" => List.duplicate(image, 35)},
      %{"type" => "function_call", "status" => "completed", "call_id" => "call_function", "name" => "example", "arguments" => "{}", "encrypted_content" => "synthetic-function-cipher"},
      %{"type" => "function_call_output", "call_id" => "call_function", "output" => "synthetic function result"},
      %{"type" => "custom_tool_call", "status" => "completed", "call_id" => "call_custom", "name" => "example_custom", "input" => "synthetic input", "encrypted_content" => "synthetic-custom-cipher"},
      %{"type" => "custom_tool_call_output", "call_id" => "call_custom", "output" => "synthetic custom result"},
      %{"type" => "web_search_call", "status" => "completed", "action" => %{"type" => "search", "query" => "synthetic"}, "encrypted_content" => "synthetic-search-cipher"}
    ]
  end

  test "committed marker returns actual HTTP 426 before upgrade without changing persistence", ctx do
    mark!(ctx.auth)
    before = snapshot(ctx)

    for endpoint <- [@native, "/backend-api/codex/v1/responses"] do
      response = handshake(ctx.port, ctx.fixture.authorization, endpoint, @window)
      assert response.status == 426
      assert response.body == ""
      assert response.headers["connection"] == "close"
      refute response.headers["x-models-etag"]
      refute response.headers["x-codex-turn-state"]
    end

    assert snapshot(ctx) == before
    assert FakeUpstream.count(ctx.upstream) == 0
  end

  test "node A marker directs node B reconnect while an existing socket and another window remain live", ctx do
    {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(ctx.port, ctx.fixture, Ecto.UUID.generate(), @native, @window)
    on_exit(fn -> Mint.HTTP.close(conn) end)
    {conn, websocket} = BackendCodexWebsocketSupport.socket_transport_barrier!(conn, websocket, ref)
    mark!(ctx.auth)
    before = snapshot(ctx)
    response = handshake(ctx.remote_port, ctx.fixture.authorization, @native, @window)
    assert response.status == 426
    refute response.headers["x-models-etag"]
    assert snapshot(ctx) == before
    assert :erpc.call(ctx.remote, Repo, :aggregate, [CodexSession, :count]) == length(before.sessions)
    {conn, websocket} = BackendCodexWebsocketSupport.socket_transport_barrier!(conn, websocket, ref)
    FakeUpstream.set_mode(ctx.upstream, FakeUpstream.sse_stream([{"response.completed", %{"type" => "response.completed", "response" => %{"usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}}]))
    payload = CodexPooler.JSON.encode!(%{"type" => "response.create", "model" => ctx.fixture.model.exposed_model_id, "input" => native_text_input("synthetic live socket control"), "stream" => true, "generate" => true})
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, payload)
    {conn, _websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)
    assert CodexPooler.JSON.decode!(frame)["type"] == "response.completed"
    Mint.HTTP.close(conn)
    assert handshake(ctx.remote_port, ctx.fixture.authorization, @native, [{"x-codex-window-id", "unrelated-window"}]).status == 101
    assert FakeUpstream.count(ctx.upstream) == 1
  end

  @tag :negative
  test "missing blank duplicate or different windows and public v1 retain ordinary upgrades", ctx do
    mark!(ctx.auth)

    for headers <- [[], [{"session-id", "synthetic-size-window"}], [{"x-codex-window-id", " "}], @window ++ @window, [{"x-codex-window-id", "other-window"}]] do
      assert handshake(ctx.port, ctx.fixture.authorization, @native, headers).status == 101
    end

    assert handshake(ctx.port, ctx.fixture.authorization, "/v1/responses", @window).status == 101
    assert FakeUpstream.count(ctx.upstream) == 0
  end

  @tag :negative
  test "other key and other pool do not inherit the marker", ctx do
    mark!(ctx.auth)
    other_key = CodexPooler.PoolerFixtures.api_key_fixture(ctx.fixture.pool)
    assert handshake(ctx.port, other_key.authorization, @native, @window).status == 101
    other = gateway_setup(ctx.upstream)
    register_unboxed_pool_cleanup!(other)
    assert handshake(ctx.port, other.authorization, @native, @window).status == 101
  end

  @tag :negative
  test "expired marker does not redirect and handshake never refreshes its database timestamp", ctx do
    mark!(ctx.auth)
    Repo.query!("UPDATE requests SET admitted_at = now() - interval '60 seconds' WHERE pool_id = $1", [Ecto.UUID.dump!(ctx.auth.pool.id)])
    [before] = snapshot(ctx).requests
    assert handshake(ctx.port, ctx.fixture.authorization, @native, @window).status == 101
    assert Repo.get!(Request, before.id) == before
  end

  @tag :negative
  test "revoked and invalid credentials fail authentication before marker lookup", ctx do
    mark!(ctx.auth)
    Repo.update_all(from(k in Access.APIKey, where: k.id == ^ctx.auth.api_key.id), set: [status: "revoked"])
    assert handshake(ctx.port, ctx.fixture.authorization, @native, @window).status == 401
    assert handshake(ctx.port, "Bearer invalid-synthetic", @native, @window).status == 401
  end

  @tag :negative
  test "a real blocked marker read returns sanitized 503 while invalid auth bypasses that read", ctx do
    mark!(ctx.auth)
    # Only the peer's connections have the bounded statement timeout. Auth tables
    # remain readable while the marker table is held on a separate backend.
    original = :erpc.call(ctx.remote, Repo, :config, [])
    config = Keyword.update(original, :parameters, [statement_timeout: "100ms"], &Keyword.put(&1, :statement_timeout, "100ms"))
    on_exit(fn -> replace_peer_repo!(ctx.remote, original) end)
    replace_peer_repo!(ctx.remote, config)
    parent = self()

    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("LOCK TABLE requests IN ACCESS EXCLUSIVE MODE")
            send(parent, :requests_locked)
            receive do: (:release -> :ok)
          end)
        end)
      end)

    assert_receive :requests_locked, 15_000

    try do
      assert handshake(ctx.remote_port, "Bearer invalid-synthetic", @native, @window).status == 401
      response = handshake(ctx.remote_port, ctx.fixture.authorization, @native, @window)
      assert response.status == 503
      assert CodexPooler.JSON.decode!(response.body)["error"]["code"] == "service_unavailable"
      refute response.headers["x-models-etag"]
    after
      send(holder.pid, :release)
      Task.await(holder, 15_000)
    end
  end

  defp replace_peer_repo!(remote, config) do
    :ok = :erpc.call(remote, Supervisor, :terminate_child, [CodexPooler.Supervisor, Repo])
    :ok = :erpc.call(remote, Application, :put_env, [:codex_pooler, Repo, config])
    assert {:ok, _} = :erpc.call(remote, Supervisor, :restart_child, [CodexPooler.Supervisor, Repo])
  end

  defp mark!(auth) do
    opts = RequestOptions.build(%{transport: "websocket", forwarded_headers: @window}, @native, %{})
    context = %Denials.Context{auth: auth, model: nil, endpoint: @native, payload: %{}, opts: opts}
    assert {:ok, :native_websocket_size_recovery} = Denials.record_native_websocket_size_recovery(context, 16_777_217)
  end

  defp snapshot(ctx) do
    pool_id = ctx.auth.pool.id
    %{requests: Repo.all(from r in Request, where: r.pool_id == ^pool_id), sessions: Repo.all(from s in CodexSession, where: s.pool_id == ^pool_id), leases: Repo.all(BridgeOwnerLease)}
  end

  defp handshake(port, authorization, endpoint, headers) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 15_000)

    try do
      headers = [{"host", "localhost"}, {"authorization", authorization}, {"connection", "Upgrade"}, {"upgrade", "websocket"}, {"sec-websocket-version", "13"}, {"sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16))} | headers]
      :ok = :gen_tcp.send(socket, ["GET ", endpoint, " HTTP/1.1\r\n", Enum.map(headers, fn {k, v} -> [k, ": ", v, "\r\n"] end), "\r\n"])
      read_response(socket, "")
    after
      :gen_tcp.close(socket)
    end
  end

  defp read_response(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      [head, body] = String.split(acc, "\r\n\r\n", parts: 2)
      [status | headers] = String.split(head, "\r\n")
      [_, status | _] = String.split(status, " ")

      headers =
        Map.new(headers, fn line ->
          [k, v] = String.split(line, ":", parts: 2)
          {String.downcase(k), String.trim(v)}
        end)

      length = String.to_integer(Map.get(headers, "content-length", "0"))
      %{status: String.to_integer(status), headers: headers, body: read_body(socket, body, length)}
    else
      {:ok, bytes} = :gen_tcp.recv(socket, 0, 15_000)
      read_response(socket, acc <> bytes)
    end
  end

  defp read_body(socket, body, length) when byte_size(body) < length do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 15_000)
    read_body(socket, body <> bytes, length)
  end

  defp read_body(_socket, body, _length), do: body
end
