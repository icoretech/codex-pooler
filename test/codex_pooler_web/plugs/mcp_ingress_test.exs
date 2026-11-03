defmodule CodexPoolerWeb.Plugs.McpIngressTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [capture_public_endpoint_identity!: 1, assert_public_endpoint_identity_released!: 1]

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Cache
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.MCP
  alias CodexPooler.Repo
  alias CodexPooler.RouteClass

  @firewall_denied_event [:codex_pooler, :ingress, :firewall, :denied]

  setup :register_and_log_in_user

  @mcp_version "2025-11-25"

  setup do
    previous_operational_settings = CodexPooler.TestAppEnv.restore_on_exit(OperationalSettings)

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous_operational_settings
      |> Keyword.delete(:settings)
      |> Keyword.put(:use_instance_settings?, true)
    )

    Admission.reset_for_test()
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      Admission.reset_for_test()
      Repo.delete_all(Settings)
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  describe "MCP firewall and trusted proxy ingress" do
    test "allowed MCP requests emit no firewall denial event", %{conn: conn, user: user} do
      attach_firewall_denial_handler()
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["198.51.100.20"]})
      raw_token = enabled_mcp_token!(user)

      conn =
        conn
        |> remote_ip({198, 51, 100, 20})
        |> authenticated_json_rpc_conn(raw_token)
        |> post("/mcp", CodexPooler.JSON.encode!(initialize_request()))

      assert json_response(conn, 200)["result"]["protocolVersion"] == @mcp_version
      refute_received {@firewall_denied_event, _measurements, _metadata}
    end

    @tag :capture_log
    test "denied MCP requests emit one bounded denial event", %{conn: conn} do
      attach_firewall_denial_handler()
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      conn =
        conn
        |> remote_ip({198, 51, 100, 20})
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", CodexPooler.JSON.encode!(initialize_request()))

      assert json_rpc_error(conn, 403) == %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{"code" => -32_600, "message" => "client IP is not allowed"}
             }

      assert_received {@firewall_denied_event, %{count: 1}, metadata}
      assert metadata == %{scope: "mcp", reason: "not_allowed"}
      refute_received {@firewall_denied_event, _measurements, _metadata}
    end

    @tag :capture_log
    test "cold settings return the fixed unavailable MCP envelope and telemetry", %{conn: conn} do
      attach_firewall_denial_handler()

      conn =
        with_cache_unregistered(fn ->
          conn
          |> remote_ip({198, 51, 100, 20})
          |> put_req_header("content-type", "application/json")
          |> post("/mcp", CodexPooler.JSON.encode!(initialize_request()))
        end)

      assert json_rpc_error(conn, 503) == %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{
                 "code" => -32_000,
                 "message" => "runtime settings are temporarily unavailable"
               }
             }

      assert_received {@firewall_denied_event, %{count: 1}, %{scope: "mcp", reason: "settings_unavailable"}}

      refute_received {@firewall_denied_event, _measurements, _metadata}
    end

    test "empty allowlist leaves MCP reachable", %{conn: conn, user: user} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: []})
      raw_token = enabled_mcp_token!(user)

      conn =
        conn
        |> remote_ip({198, 51, 100, 20})
        |> authenticated_json_rpc_conn(raw_token)
        |> post("/mcp", CodexPooler.JSON.encode!(initialize_request()))

      assert json_response(conn, 200)["result"]["protocolVersion"] == @mcp_version
    end

    @tag :capture_log
    test "configured allowlist denies MCP before protocol dispatch", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      conn =
        conn
        |> remote_ip({198, 51, 100, 20})
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", CodexPooler.JSON.encode!(initialize_request()))

      error = json_rpc_error(conn, 403)["error"]
      assert error["message"] == "client IP is not allowed"
      refute inspect(error) =~ "198.51.100.20"
    end

    @tag :capture_log
    test "trusted proxy headers are honored only from trusted immediate peers", %{
      conn: conn,
      user: user
    } do
      raw_token = enabled_mcp_token!(user)

      setup_runtime_ingress(%OperationalSettings{
        firewall_allowlist: ["203.0.113.10"],
        trusted_proxies: ["10.0.0.1"]
      })

      allowed_conn =
        conn
        |> remote_ip({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.10, 10.0.0.1")
        |> authenticated_json_rpc_conn(raw_token)
        |> post("/mcp", CodexPooler.JSON.encode!(initialize_request()))

      assert json_response(allowed_conn, 200)["result"]["protocolVersion"] == @mcp_version

      denied_conn =
        conn
        |> recycle()
        |> remote_ip({198, 51, 100, 20})
        |> put_req_header("x-forwarded-for", "203.0.113.10")
        |> json_rpc_conn()
        |> post("/mcp", CodexPooler.JSON.encode!(initialize_request()))

      assert json_rpc_error(denied_conn, 403)["error"]["message"] == "client IP is not allowed"
    end

    @tag :capture_log
    test "x-real-ip policy ignores x-forwarded-for and rejects duplicate selected fields", %{
      conn: conn,
      user: user
    } do
      attach_firewall_denial_handler()
      raw_token = enabled_mcp_token!(user)

      setup_runtime_ingress(%OperationalSettings{
        firewall_allowlist: ["203.0.113.10"],
        trusted_proxies: ["10.0.0.1"],
        forwarded_client_ip_source: :x_real_ip
      })

      allowed_conn =
        conn
        |> remote_ip({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", <<255, 0, 44>>)
        |> put_req_header("x-real-ip", "203.0.113.10")
        |> authenticated_json_rpc_conn(raw_token)
        |> post("/mcp", CodexPooler.JSON.encode!(initialize_request()))

      assert json_response(allowed_conn, 200)["result"]["protocolVersion"] == @mcp_version
      refute_received {@firewall_denied_event, _measurements, _metadata}

      denied_conn =
        conn
        |> recycle()
        |> remote_ip({10, 0, 0, 1})
        |> put_req_header("x-real-ip", "203.0.113.10")
        |> then(&%{&1 | req_headers: &1.req_headers ++ [{"x-real-ip", "198.51.100.20"}]})
        |> json_rpc_conn()
        |> post("/mcp", CodexPooler.JSON.encode!(initialize_request()))

      assert json_rpc_error(denied_conn, 403)["error"]["message"] == "client IP is not allowed"

      assert_received {@firewall_denied_event, %{count: 1}, %{scope: "mcp", reason: "duplicate_x_real_ip"}}

      refute_received {@firewall_denied_event, _measurements, _metadata}
    end

    test "x-forwarded-for policy ignores malformed x-real-ip", %{conn: conn, user: user} do
      raw_token = enabled_mcp_token!(user)

      setup_runtime_ingress(%OperationalSettings{
        firewall_allowlist: ["203.0.113.10"],
        trusted_proxies: ["10.0.0.1"],
        forwarded_client_ip_source: :x_forwarded_for,
        forwarded_proxy_depth: 1
      })

      allowed_conn =
        conn
        |> remote_ip({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.10")
        |> put_req_header("x-real-ip", <<255>>)
        |> authenticated_json_rpc_conn(raw_token)
        |> post("/mcp", CodexPooler.JSON.encode!(initialize_request()))

      assert json_response(allowed_conn, 200)["result"]["protocolVersion"] == @mcp_version
    end
  end

  describe "MCP authentication before body parsing" do
    @tag :auth_before_body
    test "missing invalid and Pool credentials leave nested JSON unread", %{conn: conn, user: user} do
      setup_runtime_ingress(%OperationalSettings{})
      enabled_mcp_token!(user)
      pool_key = CodexPooler.PoolerFixtures.active_api_key_fixture()
      body = ~s({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"x":) <> String.duplicate("[", 300) <> String.duplicate("]", 300) <> "}}"

      for authorization <- [nil, "Bearer invalid-mcp-token", pool_key.authorization] do
        request = conn |> recycle() |> json_rpc_conn()
        request = if authorization, do: put_req_header(request, "authorization", authorization), else: request
        response = post(request, "/mcp", body)
        assert json_rpc_error(response, 401)["error"]["message"] == "MCP bearer token is required"
        body_unfetched? = match?(%Plug.Conn.Unfetched{}, response.body_params)
        assert body_unfetched?
        {Plug.Adapters.Test.Conn, adapter} = response.adapter
        assert byte_size(adapter.req_body) == byte_size(body)
      end
    end
  end

  @tag :auth_before_body
  test "missing credentials take precedence over malformed and oversized bodies", %{conn: conn} do
    setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 8})

    for body <- ["{", String.duplicate("a", 64)] do
      response = conn |> recycle() |> json_rpc_conn() |> post("/mcp", body)
      assert json_rpc_error(response, 401)["error"]["message"] == "MCP bearer token is required"
      body_unfetched? = match?(%Plug.Conn.Unfetched{}, response.body_params)
      assert body_unfetched?
      {Plug.Adapters.Test.Conn, adapter} = response.adapter
      assert byte_size(adapter.req_body) == byte_size(body)
    end
  end

  @tag :auth_before_body
  test "live HTTP refuses invalid credentials with zero body reads and decodes", %{user: user} do
    setup_runtime_ingress(%OperationalSettings{})
    raw_token = enabled_mcp_token!(user)
    pool_key = CodexPooler.PoolerFixtures.active_api_key_fixture()
    observer = self()
    traced_calls = [{Plug.Conn, :read_body, 2}, {CodexPooler.JSON, :decode, 2}]

    on_exit(fn ->
      for mfa <- traced_calls, do: :erlang.trace_pattern(mfa, false, [:local])
    end)

    for mfa <- traced_calls, do: :erlang.trace_pattern(mfa, true, [:local])

    probe = fn conn, _opts ->
      :erlang.trace(self(), true, [:call, :arity, {:tracer, observer}])

      try do
        result = @endpoint.call(conn, @endpoint.init([]))
        :erlang.trace(self(), false, [:call])
        delivered = :erlang.trace_delivered(self())

        receive do
          {:trace_delivered, _tracee, ^delivered} -> :ok
        after
          5_000 -> raise "MCP ingress trace barrier timed out"
        end

        send(observer, {:mcp_body_observed, self(), match?(%Plug.Conn.Unfetched{}, result.body_params)})
        result
      after
        :erlang.trace(self(), false, [:call])
      end
    end

    refute @endpoint.config(:debug_errors, false)
    listener = start_supervised!({Bandit, plug: probe, port: 0, ip: {127, 0, 0, 1}, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    ownership = capture_public_endpoint_identity!(listener)

    on_exit(fn ->
      assert_public_endpoint_identity_released!(ownership)
    end)

    for {authorization, expected_status, expected_reads} <- [
          {nil, 401, 0},
          {"Bearer invalid-mcp-token", 401, 0},
          {pool_key.authorization, 401, 0},
          {"Bearer #{raw_token}", 200, 1}
        ] do
      headers = [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}, {"mcp-protocol-version", @mcp_version}]
      headers = if authorization, do: [{"authorization", authorization} | headers], else: headers

      response = Req.post!("http://127.0.0.1:#{port}/mcp", headers: headers, body: CodexPooler.JSON.encode!(initialize_request()), decode_body: false, retry: false)
      assert response.status == expected_status
      assert_receive {:mcp_body_observed, request_pid, body_unfetched?}, 5_000
      calls = drain_mcp_calls(request_pid, %{})
      assert Map.get(calls, {Plug.Conn, :read_body, 2}, 0) == expected_reads
      assert Map.get(calls, {CodexPooler.JSON, :decode, 2}, 0) == expected_reads
      assert body_unfetched? == (expected_reads == 0)
    end
  end

  @tag :mcp_methods
  test "live non-POST methods reject incomplete bodies without authentication, admission or parsing", %{user: user} do
    setup_runtime_ingress(%OperationalSettings{})
    _token = enabled_mcp_token!(user)
    port = start_mcp_method_probe!()

    for enabled <- [true, false] do
      assert {:ok, _settings} = InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{"mcp" => %{"enabled" => enabled}})

      for method <- ~w(GET HEAD DELETE OPTIONS PUT PATCH), encoding <- [nil, "gzip"] do
        expected_status = if method == "OPTIONS", do: 204, else: 405
        headers = if encoding, do: [{"content-encoding", encoding}], else: []
        response = incomplete_mcp_request!(port, method, "/mcp", headers)
        assert response.status == expected_status
        assert response.allow == ["POST, OPTIONS"]
        assert_method_calls!(expected_status, 0, 0, 0)
        assert {:ok, saturation} = Admission.saturation()
        assert saturation[RouteClass.mcp()] == %{running: 0, queued: 0}
      end
    end
  end

  @tag :mcp_methods
  test "non-POST methods bypass a saturated lane while authenticated POST retains admission", %{user: user} do
    setup_runtime_ingress(%OperationalSettings{
      bulkheads: Map.put(OperationalSettings.current().bulkheads, RouteClass.mcp(), %{max_concurrency: 1, queue_limit: 0, queue_timeout_ms: 25})
    })

    raw_token = enabled_mcp_token!(user)
    port = start_mcp_method_probe!()
    assert {:ok, held} = Admission.acquire(RouteClass.mcp())
    on_exit(fn -> Admission.release(held) end)

    for method <- ~w(GET HEAD DELETE OPTIONS PUT PATCH) do
      expected_status = if method == "OPTIONS", do: 204, else: 405
      response = incomplete_mcp_request!(port, method, "/mcp", [])
      assert response.status == expected_status
      assert response.allow == ["POST, OPTIONS"]
      assert_method_calls!(expected_status, 0, 0, 0)
    end

    response = incomplete_mcp_request!(port, "POST", "/mcp", [{"authorization", "Bearer #{raw_token}"}])
    assert response.status == 503
    assert_method_calls!(503, 1, 1, 0)
    Admission.release(held)

    response = Req.post!("http://127.0.0.1:#{port}/mcp", headers: [{"authorization", "Bearer #{raw_token}"}, {"accept", "application/json, text/event-stream"}, {"mcp-protocol-version", @mcp_version}], json: initialize_request(), retry: false)
    assert response.status == 200
    assert response.body["result"]["protocolVersion"] == @mcp_version
    assert_method_calls!(200, 2, 1, 1)

    response = incomplete_mcp_request!(port, "POST", "/mcp", [])
    assert response.status == 401
    assert_method_calls!(401, 1, 0, 0)

    assert {:ok, _settings} = InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{"mcp" => %{"enabled" => false}})
    response = incomplete_mcp_request!(port, "POST", "/mcp", [{"authorization", "Bearer #{raw_token}"}])
    assert response.status == 403
    assert_method_calls!(403, 1, 0, 0)
  end

  @tag :mcp_methods
  @tag :capture_log
  test "firewall and unsafe paths precede non-POST method responses" do
    setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["198.51.100.20"]})
    port = start_mcp_method_probe!()

    for method <- ~w(GET HEAD DELETE OPTIONS PUT PATCH) do
      response = incomplete_mcp_request!(port, method, "/mcp", [])
      assert response.status == 403
      assert response.allow == []
      assert_method_calls!(403, 0, 0, 0)
    end

    response = incomplete_mcp_request!(port, "DELETE", "/mcp%00suffix", [])
    assert response.status == 400
    assert response.allow == []
    assert_method_calls!(400, 0, 0, 0)
  end

  describe "MCP body parser ingress" do
    test "encoded MCP spelling reaches the same pre-parser content-type guard", %{conn: conn, user: user} do
      setup_runtime_ingress(%OperationalSettings{})
      raw_token = enabled_mcp_token!(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("content-type", "multipart/form-data; boundary=example")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", @mcp_version)
        |> post("/%6dcp", "invalid multipart fixture")

      assert json_rpc_error(conn, 415)["error"] == %{
               "code" => -32_600,
               "message" => "content-type must be application/json"
             }
    end

    test "unsafe MCP candidate returns only the fixed invalid-request envelope", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      conn = conn |> remote_ip({198, 51, 100, 20}) |> get("/mcp%00suffix")

      assert json_rpc_error(conn, 400) == %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{"code" => -32_600, "message" => "invalid request"}
             }
    end

    test "oversized bodies are rejected before controller dispatch", %{conn: conn, user: user} do
      setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 8})
      raw_token = enabled_mcp_token!(user)

      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post("/mcp", String.duplicate("a", 64))

      assert json_rpc_error(conn, 413)["error"]["message"] == "request body is too large"
    end

    test "multipart bodies are rejected before multipart parsing", %{conn: conn, user: user} do
      setup_runtime_ingress(%OperationalSettings{})
      raw_token = enabled_mcp_token!(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("content-type", "multipart/form-data; boundary=example")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", @mcp_version)
        |> post("/mcp", "not a valid multipart body")

      assert json_rpc_error(conn, 415)["error"]["message"] ==
               "content-type must be application/json"
    end

    test "compressed bodies are rejected before decompression", %{conn: conn, user: user} do
      setup_runtime_ingress(%OperationalSettings{})
      raw_token = enabled_mcp_token!(user)

      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> put_req_header("content-encoding", "gzip")
        |> post("/mcp", :zlib.gzip(CodexPooler.JSON.encode!(initialize_request())))

      assert json_rpc_error(conn, 415)["error"]["message"] ==
               "compressed MCP request bodies are not supported"
    end

    test "unsupported content types are rejected before controller dispatch", %{conn: conn, user: user} do
      setup_runtime_ingress(%OperationalSettings{})
      raw_token = enabled_mcp_token!(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("content-type", "text/plain")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", @mcp_version)
        |> post("/mcp", CodexPooler.JSON.encode!(initialize_request()))

      assert json_rpc_error(conn, 415)["error"]["message"] ==
               "content-type must be application/json"
    end

    test "malformed JSON is rejected with sanitized parse error before controller dispatch", %{
      conn: conn,
      user: user
    } do
      setup_runtime_ingress(%OperationalSettings{})
      raw_token = enabled_mcp_token!(user)

      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post("/mcp", ~s({"jsonrpc":"2.0","id":"bad","method":"initialize"))

      error = json_rpc_error(conn, 400)["error"]
      assert error["code"] == -32_700
      assert error["message"] == "parse error"
      refute inspect(error) =~ "initialize"
    end
  end

  describe "MCP admission" do
    @tag :capture_log
    test "a real body-read timeout returns JSON-RPC, closes keepalive and releases admission", %{conn: conn, user: user} do
      setup_runtime_ingress(%OperationalSettings{
        body_read_timeout_ms: 100,
        decompression_timeout_ms: 5_000,
        bulkheads: Map.put(OperationalSettings.current().bulkheads, RouteClass.mcp(), %{max_concurrency: 1, queue_limit: 0, queue_timeout_ms: 25})
      })

      raw_token = enabled_mcp_token!(user)
      port = start_mcp_method_probe!()
      response = stalled_mcp_body!(port, raw_token)

      assert response.status == 408
      assert response.connection == "close"
      assert response.body == %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32_600, "message" => "request body read timed out"}}
      assert_receive {:mcp_method_observed, _request, 408}, 5_000

      completed = conn |> authenticated_json_rpc_conn(raw_token) |> post("/mcp", CodexPooler.JSON.encode!(initialize_request()))
      assert json_response(completed, 200)["result"]["protocolVersion"] == @mcp_version
      assert Repo.aggregate(CodexPooler.Accounting.Request, :count) == 0
      assert Repo.aggregate(CodexPooler.Accounting.Attempt, :count) == 0
    end

    test "MCP uses a dedicated local admission lane before controller dispatch", %{conn: conn, user: user} do
      setup_runtime_ingress(%OperationalSettings{
        bulkheads:
          OperationalSettings.current().bulkheads
          |> Map.put(RouteClass.mcp(), %{max_concurrency: 1, queue_limit: 0, queue_timeout_ms: 25})
      })

      raw_token = enabled_mcp_token!(user)

      assert {:ok, held} = Admission.acquire(RouteClass.mcp(), %{request_id: "held-mcp"})

      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post("/mcp", CodexPooler.JSON.encode!(initialize_request()))

      error = json_rpc_error(conn, 503)["error"]
      assert error["message"] == "MCP route class is temporarily overloaded"
      refute inspect(error) =~ "initialize"

      Admission.release(held)
    end
  end

  defp start_mcp_method_probe! do
    observer = self()
    traced_calls = [{Plug.Conn, :read_body, 2}, {CodexPooler.Gateway.Admission, :admit_mcp, 1}, {CodexPoolerWeb.Mcp.Authentication, :authenticate, 1}]
    on_exit(fn -> for mfa <- traced_calls, do: :erlang.trace_pattern(mfa, false, [:local]) end)

    for {module, _function, _arity} = mfa <- traced_calls do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(mfa, true, [:local]) == 1
    end

    probe = fn conn, _opts ->
      :erlang.trace(self(), true, [:call, :arity, {:tracer, observer}])

      try do
        result = @endpoint.call(conn, @endpoint.init([]))
        :erlang.trace(self(), false, [:call])
        delivered = :erlang.trace_delivered(self())

        receive do
          {:trace_delivered, _tracee, ^delivered} -> :ok
        after
          5_000 -> raise "MCP method trace barrier timed out"
        end

        send(observer, {:mcp_method_observed, self(), result.status})
        result
      after
        :erlang.trace(self(), false, [:call])
      end
    end

    listener = start_supervised!({Bandit, plug: probe, port: 0, ip: {127, 0, 0, 1}, startup_log: false})
    ownership = capture_public_endpoint_identity!(listener)
    on_exit(fn -> assert_public_endpoint_identity_released!(ownership) end)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    port
  end

  defp incomplete_mcp_request!(port, method, target, headers) do
    assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    on_exit(fn -> :gen_tcp.close(socket) end)

    try do
      fields = [{"host", "localhost"}, {"content-type", "application/json"}, {"content-length", "100000000"}, {"connection", "close"}] ++ headers
      request = [method, " ", target, " HTTP/1.1\r\n", Enum.map(fields, fn {name, value} -> [name, ": ", value, "\r\n"] end), "\r\n"]
      assert :ok = :gen_tcp.send(socket, request)
      response = receive_mcp_headers!(socket, "")
      [status_line | fields] = String.split(response, "\r\n", trim: true)
      [_version, status | _reason] = String.split(status_line, " ")
      allow = for field <- fields, String.starts_with?(String.downcase(field), "allow:"), do: field |> String.split(":", parts: 2) |> List.last() |> String.trim()
      %{status: String.to_integer(status), allow: allow}
    after
      :gen_tcp.close(socket)
    end
  end

  defp stalled_mcp_body!(port, raw_token) do
    assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    on_exit(fn -> :gen_tcp.close(socket) end)

    try do
      fields = [{"host", "example.com"}, {"content-type", "application/json"}, {"content-length", "100"}, {"connection", "keep-alive"}, {"authorization", "Bearer " <> raw_token}]
      request = ["POST /mcp HTTP/1.1\r\n", Enum.map(fields, fn {name, value} -> [name, ": ", value, "\r\n"] end), "\r\n{"]
      assert :ok = :gen_tcp.send(socket, request)
      response = receive_closed_mcp_response!(socket, "")
      [head, body] = String.split(response, "\r\n\r\n", parts: 2)
      [status_line | headers] = String.split(head, "\r\n", trim: true)
      [_version, status | _reason] = String.split(status_line, " ")
      connection = Enum.find_value(headers, fn field -> if String.starts_with?(String.downcase(field), "connection:"), do: field |> String.split(":", parts: 2) |> List.last() |> String.trim() end)
      %{status: String.to_integer(status), connection: connection, body: CodexPooler.JSON.decode!(body)}
    after
      :gen_tcp.close(socket)
    end
  end

  defp receive_closed_mcp_response!(socket, acc) do
    assert byte_size(acc) <= 32_768

    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, bytes} -> receive_closed_mcp_response!(socket, acc <> bytes)
      {:error, :closed} -> acc
      {:error, reason} -> flunk("MCP response did not close: #{inspect(reason)}")
    end
  end

  defp receive_mcp_headers!(socket, buffer) do
    assert byte_size(buffer) < 32_768

    if String.contains?(buffer, "\r\n\r\n") do
      buffer |> String.split("\r\n\r\n", parts: 2) |> hd()
    else
      assert {:ok, bytes} = :gen_tcp.recv(socket, 0, 2_000)
      receive_mcp_headers!(socket, buffer <> bytes)
    end
  end

  defp assert_method_calls!(status, authentications, admissions, reads) do
    assert_receive {:mcp_method_observed, request_pid, ^status}, 5_000
    calls = drain_mcp_calls(request_pid, %{})
    assert Map.get(calls, {CodexPoolerWeb.Mcp.Authentication, :authenticate, 1}, 0) == authentications
    assert Map.get(calls, {CodexPooler.Gateway.Admission, :admit_mcp, 1}, 0) == admissions
    assert Map.get(calls, {Plug.Conn, :read_body, 2}, 0) == reads
  end

  defp drain_mcp_calls(request_pid, counts) do
    receive do
      {:trace, ^request_pid, :call, mfa} ->
        drain_mcp_calls(request_pid, Map.update(counts, mfa, 1, &(&1 + 1)))
    after
      0 -> counts
    end
  end

  defp setup_runtime_ingress(settings) do
    instance_settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _updated} =
             InstanceSettings.update_system_settings(instance_settings, %{
               "ingress" => %{
                 "firewall_allowlist" => settings.firewall_allowlist,
                 "trusted_proxies" => settings.trusted_proxies,
                 "forwarded_client_ip_source" => settings.forwarded_client_ip_source,
                 "forwarded_proxy_depth" => settings.forwarded_proxy_depth,
                 "decompression_algorithms" => settings.decompression_algorithms,
                 "max_compressed_body_bytes" => settings.max_compressed_body_bytes,
                 "max_decompressed_body_bytes" => settings.max_decompressed_body_bytes,
                 "max_decompression_ratio" => settings.max_decompression_ratio,
                 "body_read_timeout_ms" => settings.body_read_timeout_ms,
                 "decompression_timeout_ms" => settings.decompression_timeout_ms
               },
               "gateway" => %{"bulkheads" => string_keyed_map(settings.bulkheads)}
             })
  end

  defp attach_firewall_denial_handler do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @firewall_denied_event,
        fn event, measurements, metadata, _config ->
          send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp with_cache_unregistered(fun) when is_function(fun, 0) do
    cache = Process.whereis(Cache)

    # Also on_exit: the ExUnit timeout or a linked crash kills the test before `after` runs, and
    # every later test in the run would find the cache process without its name.
    on_exit(fn ->
      if is_pid(cache) and Process.alive?(cache) and is_nil(Process.whereis(Cache)),
        do: Process.register(cache, Cache)
    end)

    Process.unregister(Cache)

    try do
      fun.()
    after
      if is_pid(cache), do: Process.register(cache, Cache)
    end
  end

  defp authenticated_json_rpc_conn(conn, raw_token) do
    conn
    |> json_rpc_conn()
    |> put_req_header("authorization", "Bearer #{raw_token}")
  end

  defp enabled_mcp_token!(user) do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _updated} =
             InstanceSettings.update_system_settings(settings, %{"mcp" => %{"enabled" => true}})

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(user, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(user, %{label: "Ingress MCP"})

    raw_token
  end

  defp json_rpc_conn(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @mcp_version)
  end

  defp json_rpc_error(conn, status) do
    response = json_response(conn, status)
    assert response["jsonrpc"] == "2.0"
    assert is_map(response["error"])
    response
  end

  defp initialize_request do
    %{
      "jsonrpc" => "2.0",
      "id" => "init-1",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @mcp_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "example-client", "version" => "0.0.1"}
      }
    }
  end

  defp remote_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp string_keyed_map(map), do: map |> CodexPooler.JSON.encode!() |> CodexPooler.JSON.decode!()
end
