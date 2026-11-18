defmodule CodexPoolerWeb.Plugs.RuntimeIngressTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [capture_public_endpoint_identity!: 1, assert_public_endpoint_identity_released!: 1]
  import ExUnit.CaptureLog, only: [capture_log: 2]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.OperationalSettings.IPRules
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Cache
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.MCP
  alias CodexPooler.Pools
  alias CodexPooler.Pools.RoutingSettings
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPoolerWeb.Plugs.{RuntimeIngress, TrustedProxyRemoteIp}

  alias CodexPoolerWeb.Plugs.RuntimeIngress.{
    CompressedBody,
    Firewall,
    ForwardedClientIP
  }

  alias CodexPoolerWeb.Plugs.RuntimeIngress.Firewall.Decision
  alias CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIP.Resolution

  @detection_timeout_ms 15_000
  @firewall_denied_event [:codex_pooler, :ingress, :firewall, :denied]

  defp append_req_header(conn, name, value) do
    %{conn | req_headers: conn.req_headers ++ [{name, value}]}
  end

  setup do
    previous_operational_settings = CodexPooler.TestAppEnv.restore_on_exit(OperationalSettings)

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous_operational_settings
      |> Keyword.delete(:settings)
      |> Keyword.put(:use_instance_settings?, true)
    )

    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      Repo.delete_all(Settings)
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  @tag :parser_error_envelopes
  test "live parser exceptions use runtime and MCP envelopes before Phoenix renders generic errors" do
    setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 16})
    setup = active_api_key_fixture()
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    active_upstream_assignment_fixture(setup.pool, %{metadata: %{"base_url" => FakeUpstream.url(upstream)}})
    user = Repo.get!(CodexPooler.Accounts.User, setup.api_key.created_by_user_id)
    assert {:ok, _settings} = InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{"mcp" => %{"enabled" => true}})
    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(user, true)
    assert {:ok, %{raw_token: raw_token}} = MCP.create_operator_token(user, %{label: "Parser error contract"})
    port = start_parser_error_endpoint!()
    counts = parser_error_side_effect_counts()
    body = CodexPooler.JSON.encode!(%{"model" => "sample-model", "input" => "synthetic input"})
    query = "a" <> String.duplicate("[b]", 40) <> "=1"

    multipart = parser_error_request(port, "/backend-api/transcribe", "multipart/form-data; boundary=example", "invalid multipart fixture", setup.authorization)
    oversized = parser_error_request(port, "/backend-api/codex/responses", "application/json", body, setup.authorization)
    setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 1_024})
    mcp = parser_error_request(port, "/mcp?" <> query, "application/json", ~s({"jsonrpc":"2.0","id":1,"method":"tools/list"}), "Bearer #{raw_token}")

    observed = Enum.map([multipart, oversized, mcp], &Map.take(&1, [:status, :code, :jsonrpc, :id, :phoenix_renders, :plug_error_catches, :endpoint_error_handlers, :wrapper_order]))

    assert Enum.map(observed, &Map.take(&1, [:status, :code, :jsonrpc, :id])) == [
             %{status: 400, code: "invalid_request", jsonrpc: nil, id: nil},
             %{status: 413, code: "decompressed_request_too_large", jsonrpc: nil, id: nil},
             %{status: 400, code: -32_600, jsonrpc: "2.0", id: nil}
           ],
           inspect(observed)

    assert multipart.part_reads > 0
    assert oversized.body_reads > 0
    assert mcp.body_reads > 0
    assert Enum.all?([multipart, oversized, mcp], &(&1.uploads == 0 and &1.phoenix_renders == 0))
    assert multipart.message == "request body could not be parsed"
    assert mcp.message == "request query is invalid"

    for path <- ["/backend-api/transcribe", "/v1/audio/transcriptions"] do
      for authorization <- [nil, "Bearer invalid-key"] do
        refused = parser_error_request(port, path, "multipart/form-data; boundary=example", "invalid multipart fixture", authorization)
        assert refused.status == 401
        assert {refused.body_reads, refused.part_reads, refused.json_decodes, refused.compressed_decodes, refused.uploads} == {0, 0, 0, 0, 0}
      end
    end

    for path <- ["/backend-api/codex/responses", "/v1/responses"], encoding <- [nil, "gzip"] do
      encoded = if encoding, do: :zlib.gzip(body), else: body
      headers = if encoding, do: [{"content-encoding", encoding}], else: []
      queried = parser_error_request(port, path <> "?" <> query, "application/json", encoded, setup.authorization, headers)
      assert {queried.status, queried.code, queried.message} == {400, "invalid_request", "request query is invalid"}
      assert queried.phoenix_renders == 0
      assert queried.uploads == 0

      for authorization <- [nil, "Bearer invalid-key"] do
        refused = parser_error_request(port, path <> "?" <> query, "application/json", encoded, authorization, headers)
        assert refused.status == 401
        assert {refused.body_reads, refused.part_reads, refused.json_decodes, refused.compressed_decodes, refused.uploads} == {0, 0, 0, 0, 0}
      end
    end

    for authorization <- [nil, "Bearer invalid-key"] do
      refused = parser_error_request(port, "/mcp?" <> query, "application/json", "{", authorization)
      assert {refused.status, refused.code, refused.jsonrpc} == {401, -32_000, "2.0"}
      assert {refused.body_reads, refused.part_reads, refused.json_decodes, refused.compressed_decodes, refused.uploads} == {0, 0, 0, 0, 0}
    end

    ping = parser_error_request(port, "/mcp?ordinary=1", "application/json", ~s({"jsonrpc":"2.0","id":1,"method":"ping"}), "Bearer #{raw_token}")
    assert {ping.status, ping.jsonrpc, ping.id, ping.code} == {200, "2.0", 1, nil}
    assert ping.body_reads > 0
    assert ping.json_decodes > 0
    malformed_mcp = parser_error_request(port, "/mcp", "application/json", "{", "Bearer #{raw_token}")
    assert {malformed_mcp.status, malformed_mcp.code, malformed_mcp.jsonrpc, malformed_mcp.message} == {400, -32_700, "2.0", "parse error"}

    setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 16})
    compressed = parser_error_request(port, "/backend-api/codex/responses", "application/json", :zlib.gzip(body), setup.authorization, [{"content-encoding", "gzip"}])
    assert {compressed.status, compressed.code} == {oversized.status, oversized.code}
    assert compressed.compressed_decodes == 1
    assert compressed.phoenix_renders == 0
    multipart_oversized = parser_error_request(port, "/backend-api/codex/responses", "multipart/form-data; boundary=scope-boundary", parser_multipart_body(8_000_001), setup.authorization)
    assert {multipart_oversized.status, multipart_oversized.code, multipart_oversized.message} == {413, "request_too_large", "request body is too large"}
    assert multipart_oversized.phoenix_renders == 0
    assert parser_error_side_effect_counts() == counts
    assert FakeUpstream.requests(upstream) == []
  end

  @tag :parser_error_envelopes
  test "ordinary parser errors remain generic Phoenix responses and browser CSRF stays enforced" do
    setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 16})
    port = start_parser_error_endpoint!()
    query = "a" <> String.duplicate("[b]", 40) <> "=1"

    for path <- ["/login", "/admin/unknown-parser-route", "/unknown-parser-route"] do
      malformed = parser_error_request(port, path, "application/json", "{", nil)
      assert {malformed.status, malformed.code, malformed.jsonrpc, malformed.phoenix_renders} == {400, nil, nil, 1}
      queried = parser_error_request(port, path <> "?" <> query, "application/json", "{}", nil)
      assert {queried.status, queried.code, queried.jsonrpc, queried.phoenix_renders} == {400, nil, nil, 1}
    end

    oversized = parser_error_request(port, "/unknown-parser-route", "application/json", String.duplicate("a", 8_000_001), nil)
    assert {oversized.status, oversized.code, oversized.jsonrpc, oversized.phoenix_renders} == {413, nil, nil, 1}
    csrf = parser_error_request(port, "/login", "application/json", "{}", nil, [{"accept", "text/html"}])
    assert {csrf.status, csrf.code, csrf.jsonrpc, csrf.phoenix_renders} == {403, nil, nil, 1}
  end

  @tag :parser_budget_scope
  test "ordinary JSON login and unknown routes do not inherit runtime JSON limits" do
    setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 16})
    CodexPooler.AccountsFixtures.bootstrap_owner_fixture()
    body = CodexPooler.JSON.encode!(%{"user" => %{"email" => "nobody@example.com", "password" => "synthetic-invalid-password"}})

    for {path, expected} <- [{"/login", 302}, {"/%6cogin", 302}, {"/unknown-parser-route", 404}, {"/admin/unknown-parser-route", 404}] do
      outcome = parser_endpoint_outcome(:post, path, "application/json", body)
      assert outcome == %{status: expected, parsed: true}
    end
  end

  @tag :parser_budget_scope
  test "ordinary multipart has an eight megabyte budget instead of the media ceiling" do
    setup_runtime_ingress(%OperationalSettings{})

    for path <- ["/unknown-parser-route", "/login", "/admin/unknown-parser-route"] do
      body = parser_multipart_body(8_000_001)
      outcome = parser_endpoint_outcome(:post, path, "multipart/form-data; boundary=scope-boundary", body)
      assert outcome.status == 413
    end
  end

  @tag :parser_budget_scope
  test "live browser parsing retains CSRF and login semantics independently of runtime limits" do
    setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 16})
    CodexPooler.AccountsFixtures.bootstrap_owner_fixture()
    port = start_parser_scope_endpoint!()
    login = Req.get!("http://127.0.0.1:#{port}/login", decode_body: false, redirect: false)
    assert login.status == 200
    _login_observation = parser_scope_observation!()
    [_, csrf] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, login.body)
    cookie = login.headers |> Map.fetch!("set-cookie") |> Enum.map_join("; ", &(&1 |> String.split(";", parts: 2) |> hd()))
    body = CodexPooler.JSON.encode!(%{"user" => %{"email" => "nobody@example.com", "password" => "synthetic-invalid-password"}})

    for path <- ["/login", "/%6cogin"] do
      refused = parser_scope_request(port, :post, path, "application/json", body)
      assert refused.status == 403
      assert refused.parsed
      assert refused.json_decodes > 0
      assert refused.compressed_decodes == 0

      allowed = parser_scope_request(port, :post, path, "application/json", body, [{"x-csrf-token", csrf}, {"cookie", cookie}])
      assert allowed.status == 302
      assert allowed.parsed
      assert allowed.json_decodes > 0

      malformed = parser_scope_request(port, :post, path, "application/json", "{")
      assert malformed.status == 400
      assert malformed.json_decodes > 0

      compressed = parser_scope_request(port, :post, path, "application/json", :zlib.gzip(body), [{"content-encoding", "gzip"}])
      assert compressed.status == 400
      assert compressed.compressed_decodes == 0
    end
  end

  @tag :parser_budget_scope
  test "live ordinary JSON and multipart enforce independent byte boundaries on unknown and admin paths" do
    setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 16})
    port = start_parser_scope_endpoint!()
    # Plug charges 36 bytes per part and 56 per header in addition to its name and value.
    multipart_overhead = 36 + 56 + byte_size("content-disposition") + byte_size(~s(form-data; name="note"))

    for path <- ["/unknown-parser-route", "/admin/unknown-parser-route"] do
      for size <- [7_999_999, 8_000_000, 8_000_001] do
        expected = if size > 8_000_000, do: 413, else: 404
        json = parser_scope_request(port, :post, path, "application/json", ~s({"x":") <> String.duplicate("a", size - 8) <> ~s("}))
        assert json.status == expected
        assert json.body_reads > 0
        assert json.json_decodes > 0 == (expected == 404)
        assert json.compressed_decodes == 0

        multipart = parser_scope_request(port, :post, path, "multipart/form-data; boundary=scope-boundary", parser_multipart_body(size - multipart_overhead))
        assert multipart.status == expected
        assert multipart.part_reads > 0
        assert multipart.compressed_decodes == 0
      end
    end
  end

  @tag :parser_budget_scope
  test "live media allowance requires exact authenticated POST routes and does not expand runtime JSON" do
    setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 16})
    setup = active_api_key_fixture()
    port = start_parser_scope_endpoint!()
    multipart_type = "multipart/form-data; boundary=scope-boundary"
    body = parser_multipart_body(8_000_001)

    paths = ["/backend-api/transcribe", "/backend-api/%74ranscribe", "/v1/files", "/%761/files", "/v1/audio/transcriptions", "/v1/audio/%74ranscriptions", "/v1/images/edits", "/v1/images/%65dits"]

    for path <- paths do
      for authorization <- [nil, "Bearer invalid-key"], encoding <- [nil, "gzip"] do
        headers = if authorization, do: [{"authorization", authorization}], else: []
        headers = if encoding, do: [{"content-encoding", encoding} | headers], else: headers
        refused = parser_scope_request(port, :post, path, multipart_type, "unread synthetic input", headers)
        assert refused.status == 401
        refute refused.parsed
        assert {refused.body_reads, refused.part_reads, refused.json_decodes, refused.compressed_decodes, refused.uploads} == {0, 0, 0, 0, 0}
      end

      accepted = parser_scope_request(port, :post, path, multipart_type, body, [{"authorization", setup.authorization}])
      assert accepted.status == 400
      assert accepted.parsed
      assert accepted.part_reads > 0

      for method <- [:put, :patch, :delete] do
        wrong_method = parser_scope_request(port, method, path, multipart_type, body, [{"authorization", setup.authorization}])
        assert wrong_method.status == 413
      end
    end

    for path <- ["/v1/files/extra", "/v1/images/generations", "/backend-api/codex/images/edits", "/backend-api/codex/responses"] do
      refused = parser_scope_request(port, :post, path, multipart_type, body, [{"authorization", setup.authorization}])
      assert refused.status == 413
    end

    for encoding <- [nil, "gzip"] do
      json = CodexPooler.JSON.encode!(%{"model" => "sample-model", "input" => "synthetic request"})
      encoded = if encoding, do: :zlib.gzip(json), else: json
      headers = [{"authorization", setup.authorization}]
      headers = if encoding, do: [{"content-encoding", encoding} | headers], else: headers
      refused = parser_scope_request(port, :post, "/backend-api/codex/responses", "application/json", encoded, headers)
      assert refused.status == 413
      assert refused.body_reads > 0
      assert refused.compressed_decodes == if(encoding, do: 1, else: 0)
    end

    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0

    with_parser_upload_directory(fn ->
      upload_body = "--scope-boundary\r\ncontent-disposition: form-data; name=\"file\"; filename=\"sample.txt\"\r\ncontent-type: text/plain\r\n\r\nsynthetic upload\r\n--scope-boundary--\r\n"
      upload = parser_scope_request(port, :post, "/v1/files", multipart_type, upload_body, [{"authorization", setup.authorization}])
      assert upload.status == 400
      assert upload.parsed
      assert upload.part_reads > 0
      assert upload.uploads == 1
    end)
  end

  describe "unencoded ingress characterization" do
    test "all body-parsed methods authenticate backend routes before multipart parsing" do
      setup_runtime_ingress(%OperationalSettings{})

      for method <- [:post, :put, :patch, :delete],
          path <- ["/backend-api/transcribe", "/backend-api/files", "/backend-api/codex/responses"],
          content_type <- ["application/json", "multipart/form-data; boundary=example"] do
        conn =
          build_conn()
          |> put_req_header("content-type", content_type)
          |> dispatch(@endpoint, method, path, "invalid body")

        assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
        assert %Plug.Conn.Unfetched{} = conn.body_params
      end

      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    end

    test "authenticated transcription reports malformed JSON before file validation" do
      setup_runtime_ingress(%OperationalSettings{})
      setup = active_api_key_fixture()

      conn =
        build_conn()
        |> auth(setup)
        |> put_req_header("content-type", "application/json")
        |> post("/backend-api/transcribe", ~s({"model":))

      assert json_response(conn, 400)["error"]["message"] == "request body must be valid JSON"
      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    end

    test "transcription authenticates JSON requests before parsing for canonical and encoded paths" do
      setup_runtime_ingress(%OperationalSettings{})

      for path <- ["/backend-api/transcribe", "/backend-api/%74ranscribe"],
          body <- [~s({"model":), "{}"] do
        conn = build_conn() |> put_req_header("content-type", "application/json") |> post(path, body)
        assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
      end

      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    end

    test "preserves runtime, MCP, multipart, usage, pruned-helper, and passthrough order", %{
      conn: conn
    } do
      setup_runtime_ingress(%OperationalSettings{})
      setup = active_api_key_fixture()

      protected_runtime =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/backend-api/codex/responses", ~s({"model":))

      assert json_response(protected_runtime, 401)["error"]["code"] == "api_key_missing"

      missing_mcp =
        build_conn()
        |> put_req_header("content-type", "multipart/form-data; boundary=example")
        |> post("/mcp", "invalid multipart fixture")

      assert json_response(missing_mcp, 401)["error"]["code"] == -32_000
      assert %Plug.Conn.Unfetched{} = missing_mcp.body_params

      user = Repo.get!(CodexPooler.Accounts.User, setup.api_key.created_by_user_id)
      assert {:ok, _settings} = InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{"mcp" => %{"enabled" => true}})
      assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(user, true)
      assert {:ok, %{raw_token: raw_token}} = MCP.create_operator_token(user, %{label: "Ingress contract"})

      mcp =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("content-type", "multipart/form-data; boundary=example")
        |> post("/mcp", "invalid multipart fixture")

      assert json_response(mcp, 415)["error"]["code"] == -32_600

      multipart =
        build_conn()
        |> auth(setup)
        |> put_req_header("content-type", "multipart/form-data; boundary=example")
        |> post("/backend-api/files", "invalid multipart fixture")

      assert json_response(multipart, 400)["error"]["code"] ==
               "unsupported_multipart_file_create"

      usage = build_conn() |> auth(setup) |> get("/api/codex/usage")
      assert json_response(usage, 200)["plan_type"] == "api_key"

      pruned = post(build_conn(), "/backend-api/codex/thread/goal/get", %{})
      assert response(pruned, 404) =~ "Not Found"

      health = get(build_conn(), "/healthz")
      assert json_response(health, 200)["status"] == "ok"
    end
  end

  describe "canonical path classification" do
    @tag :capture_log
    test "encoded runtime route families reach the same pre-parser firewall", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      for {method, path, headers} <- [
            {:post, "/%62ackend-api/codex/responses", []},
            {:post, "/backend-api/%66iles", []},
            {:post, "/backend-api/%74ranscribe", []},
            {:get, "/api/%63odex/usage", []},
            {:get, "/%77ham/usage", []},
            {:get, "/backend-api/wham/%75sage", []},
            {:get, "/%76%31/models", []},
            {:get, "/v1/%72esponses",
             [
               {"connection", "upgrade"},
               {"upgrade", "websocket"},
               {"sec-websocket-version", "13"},
               {"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="}
             ]}
          ] do
        conn =
          headers
          |> Enum.reduce(recycle(conn), fn {name, value}, conn ->
            put_req_header(conn, name, value)
          end)
          |> remote_ip({198, 51, 100, 20})
          |> dispatch(method, path)

        assert json_response(conn, 403)["error"]["code"] == "access_denied"
      end
    end

    @tag :capture_log
    test "encoded pruned helpers reach the same runtime firewall", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      conn =
        conn
        |> remote_ip({198, 51, 100, 20})
        |> post("/backend-api/codex/thread/%67oal/get", %{})

      assert json_response(conn, 403)["error"]["code"] == "access_denied"
    end

    test "encoded protected JSON and transcription routes authenticate before parsing", %{
      conn: conn
    } do
      setup_runtime_ingress(%OperationalSettings{})

      for {path, content_type, body} <- [
            {"/%62ackend-api/codex/responses", "application/json", ~s({"model":)},
            {"/backend-api/%66iles", "application/json", ~s({"file_name":)},
            {"/backend-api/%74ranscribe", "multipart/form-data; boundary=example", "invalid multipart fixture"}
          ] do
        conn =
          conn
          |> recycle()
          |> put_req_header("content-type", content_type)
          |> post(path, body)

        assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
      end
    end

    test "the beta Agents and vault families are classified on the decoded path and stop at the segment boundary", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})
      setup = active_api_key_fixture()

      for {method, path} <- [
            {:post, "/v1/%61gents/sessions"},
            {:get, "/v1/agents/sessions/session_fixture/events"},
            {:post, "/v1/%76aults/vault_fixture/credentials"},
            {:get, "/v1/agents/"}
          ] do
        conn = conn |> recycle() |> auth(setup) |> dispatch(method, path)

        assert json_response(conn, 404) == %{
                 "error" => %{
                   "message" => "Unsupported OpenAI /v1 endpoint: the beta Agents API is not supported",
                   "type" => "invalid_request_error",
                   "code" => "unsupported_endpoint",
                   "param" => nil
                 }
               }
      end

      for path <- ["/v1/agent/sessions", "/v1/agentsx", "/v1/vault", "/v1/sessions/agents"] do
        conn = conn |> recycle() |> auth(setup) |> get(path)

        assert html_response(conn, 404) =~ "Not Found"
      end
    end

    test "unsafe runtime candidates return only the fixed invalid-path envelope", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      for path <- [
            "/v1%2Fresponses",
            "/backend-api%5Cfiles",
            "/api/codex%00/usage"
          ] do
        conn = conn |> recycle() |> remote_ip({198, 51, 100, 20}) |> get(path)

        assert json_response(conn, 400) == %{
                 "error" => %{
                   "message" => "request path is invalid",
                   "type" => "invalid_request_error",
                   "code" => "invalid_request",
                   "param" => nil
                 }
               }
      end

      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    end

    test "single decoding does not reject double-encoded or invalid percent text", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})

      for path <- ["/v1/value%252Ftail", "/v1/value%ZZtail"] do
        conn = get(recycle(conn), path)
        assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
      end
    end

    test "unsafe passthrough candidates retain normal router behavior", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      for path <- ["/admin%2Fusers", "/login%00suffix", "/healthz%2Fextra"] do
        conn = conn |> recycle() |> remote_ip({198, 51, 100, 20}) |> get(path)

        assert html_response(conn, 404) =~ "Not Found"
      end
    end
  end

  describe "JSON parser context" do
    test "endpoint ingress reads one operational settings snapshot and resolves the client once" do
      setup_runtime_ingress_override(%OperationalSettings{
        firewall_allowlist: ["203.0.113.10"],
        trusted_proxies: ["10.0.0.1"]
      })

      conn =
        Plug.Test.conn(:post, "/login", "{}")
        |> remote_ip({10, 0, 0, 1})
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-forwarded-for", "203.0.113.10")

      {conn, settings_calls} =
        trace_call_count({OperationalSettings, :current, 0}, fn ->
          conn
          |> TrustedProxyRemoteIp.call([])
          |> RuntimeIngress.call([])
        end)

      assert settings_calls == 1

      assert %OperationalSettings{} =
               conn.private[:codex_pooler_runtime_ingress_settings]

      assert %Resolution{
               status: :ok,
               client_ip: {203, 0, 113, 10},
               source: :x_forwarded_for
             } = conn.private[:codex_pooler_client_ip_resolution]

      assert conn.private[:codex_pooler_peer_ip] == {10, 0, 0, 1}
      assert conn.remote_ip == {203, 0, 113, 10}
    end

    test "endpoint ingress invokes the bounded forwarded client resolver exactly once" do
      setup_runtime_ingress_override(%OperationalSettings{trusted_proxies: ["10.0.0.1"]})

      conn =
        Plug.Test.conn(:get, "/metrics")
        |> remote_ip({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.10")

      {conn, resolver_calls} =
        trace_call_count({ForwardedClientIP, :resolve, 2}, fn ->
          conn
          |> TrustedProxyRemoteIp.call([])
          |> RuntimeIngress.call([])
        end)

      assert resolver_calls == 1
      assert %Resolution{status: :ok} = conn.private[:codex_pooler_client_ip_resolution]
    end

    test "trusted proxy resolution bypasses exactly health and readiness paths" do
      setup_runtime_ingress_override(%OperationalSettings{trusted_proxies: ["10.0.0.1"]})

      for path <- ["/healthz", "/readyz"] do
        conn =
          Plug.Test.conn(:get, path)
          |> remote_ip({10, 0, 0, 1})
          |> put_req_header("x-forwarded-for", "203.0.113.10")
          |> TrustedProxyRemoteIp.call([])

        assert conn.remote_ip == {10, 0, 0, 1}
        refute Map.has_key?(conn.private, :codex_pooler_runtime_ingress_settings)
        refute Map.has_key?(conn.private, :codex_pooler_client_ip_resolution)
      end

      conn =
        Plug.Test.conn(:get, "/healthz/extra")
        |> remote_ip({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.10")
        |> TrustedProxyRemoteIp.call([])

      assert conn.remote_ip == {203, 0, 113, 10}
      assert %Resolution{status: :ok} = conn.private[:codex_pooler_client_ip_resolution]
    end

    test "stores settings and protected-backend classification before parsing" do
      setup_runtime_ingress(%OperationalSettings{})
      setup = active_api_key_fixture()
      settings = OperationalSettings.current()

      conn =
        Plug.Test.conn(:post, "/backend-api/codex/responses", "{}")
        |> auth(setup)
        |> put_req_header("content-type", "application/json")
        |> RuntimeIngress.call([])

      assert conn.private[:codex_pooler_runtime_ingress_settings] == settings
      assert conn.private[:codex_pooler_json_parse_error_scope] == :protected_backend
      assert conn.private[:runtime_api_auth]
      refute conn.halted
    end

    test "stores settings and MCP classification before parsing" do
      setup_runtime_ingress(%OperationalSettings{})
      settings = OperationalSettings.current()

      conn =
        Plug.Test.conn(:get, "/mcp")
        |> RuntimeIngress.call([])

      assert conn.private[:codex_pooler_runtime_ingress_settings] == settings
      assert conn.private[:codex_pooler_json_parse_error_scope] == :mcp
      assert conn.halted
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST, OPTIONS"]
      assert match?(%Plug.Conn.Unfetched{}, conn.body_params)
    end

    test "ordinary JSON ingress does not attach parser settings or classification" do
      setup_runtime_ingress(%OperationalSettings{})

      conn =
        Plug.Test.conn(:post, "/login", "{}")
        |> put_req_header("content-type", "application/vnd.api+json")
        |> RuntimeIngress.call([])

      refute conn.private[:codex_pooler_runtime_ingress_settings]
      refute conn.private[:codex_pooler_json_parse_error_scope]
      refute conn.private[:runtime_api_auth]
      refute conn.halted
    end
  end

  describe "runtime API firewall" do
    test "allowed runtime requests emit no firewall denial event", %{conn: conn} do
      attach_firewall_denial_handler()
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})
      setup = active_api_key_fixture()

      conn =
        conn
        |> remote_ip({203, 0, 113, 10})
        |> put_req_header("authorization", setup.authorization)
        |> get("/api/codex/usage")

      assert %{"plan_type" => "api_key"} = json_response(conn, 200)
      refute_received {@firewall_denied_event, _measurements, _metadata}
    end

    test "denied runtime requests emit one bounded event and sanitized log", %{conn: conn} do
      attach_firewall_denial_handler()
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      log =
        capture_log([metadata: [:scope, :reason, :request_id]], fn ->
          denied_conn = conn |> remote_ip({198, 51, 100, 20}) |> get("/api/codex/usage")

          assert json_response(denied_conn, 403) == %{
                   "error" => %{
                     "code" => "access_denied",
                     "message" => "client IP is not allowed",
                     "param" => nil,
                     "type" => "invalid_request_error"
                   }
                 }
        end)

      assert_received {@firewall_denied_event, %{count: 1}, metadata}
      assert metadata == %{scope: "runtime", reason: "not_allowed"}
      refute_received {@firewall_denied_event, _measurements, _metadata}
      assert log =~ "ingress firewall denied"
      assert log =~ "scope=runtime"
      assert log =~ "reason=not_allowed"

      for forbidden <- [
            "198.51.100.20",
            "x-forwarded-for",
            "/api/codex/usage",
            "request_id="
          ] do
        refute log =~ forbidden
      end
    end

    @tag :capture_log
    test "cold settings return the fixed unavailable runtime envelope and telemetry", %{
      conn: conn
    } do
      attach_firewall_denial_handler()

      conn =
        with_cache_unregistered(fn ->
          conn
          |> remote_ip({198, 51, 100, 20})
          |> get("/api/codex/usage")
        end)

      assert json_response(conn, 503) == %{
               "error" => %{
                 "code" => "settings_unavailable",
                 "message" => "runtime settings are temporarily unavailable",
                 "param" => nil,
                 "type" => "server_error"
               }
             }

      assert_received {@firewall_denied_event, %{count: 1}, %{scope: "runtime", reason: "settings_unavailable"}}

      refute_received {@firewall_denied_event, _measurements, _metadata}
    end

    @tag :capture_log
    test "warm database snapshots remain enforceable for allow and ordinary deny", %{conn: conn} do
      setup_runtime_ingress_override(%OperationalSettings{
        source: :database,
        db_available?: false,
        secrets_available?: false,
        firewall_allowlist: ["203.0.113.10"]
      })

      setup = active_api_key_fixture()

      allowed =
        conn
        |> remote_ip({203, 0, 113, 10})
        |> put_req_header("authorization", setup.authorization)
        |> get("/api/codex/usage")

      assert %{"plan_type" => "api_key"} = json_response(allowed, 200)

      denied =
        conn
        |> recycle()
        |> remote_ip({198, 51, 100, 20})
        |> get("/api/codex/usage")

      assert json_response(denied, 403)["error"]["code"] == "access_denied"
    end

    test "reuses the stored resolution without reparsing changed forwarded headers" do
      setup_runtime_ingress_override(%OperationalSettings{
        firewall_allowlist: ["203.0.113.10"],
        trusted_proxies: ["10.0.0.1"]
      })

      conn =
        Plug.Test.conn(:get, "/api/codex/usage")
        |> remote_ip({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.10")
        |> TrustedProxyRemoteIp.call([])
        |> put_req_header("x-forwarded-for", "198.51.100.20")

      settings = conn.private[:codex_pooler_runtime_ingress_settings]

      assert {allowed_conn, %Decision{outcome: :allow}} = Firewall.evaluate(conn, settings)
      assert allowed_conn.remote_ip == {203, 0, 113, 10}
    end

    test "fails closed when the compiled firewall snapshot is invalid" do
      {:ok, trusted_rules} = IPRules.compile([])

      settings = %OperationalSettings{
        firewall_allowlist: ["203.0.113.10"],
        firewall_allowlist_compiled: {:error, :invalid_rule},
        trusted_proxies_compiled: {:ok, trusted_rules}
      }

      conn =
        Plug.Test.conn(:get, "/api/codex/usage")
        |> remote_ip({203, 0, 113, 10})
        |> Plug.Conn.put_private(
          :codex_pooler_client_ip_resolution,
          %Resolution{
            status: :ok,
            peer_ip: {203, 0, 113, 10},
            client_ip: {203, 0, 113, 10},
            source: :peer,
            reason: nil,
            inspected_hops: 0
          }
        )

      assert {_conn, %Decision{outcome: :deny, reason: :invalid_allowlist_rules}} =
               Firewall.evaluate(conn, settings)
    end

    @tag :capture_log
    test "invalid firewall rules loaded from a legacy row fail closed at the HTTP boundary", %{
      conn: conn
    } do
      _settings = InstanceSettings.ensure_singleton!()

      Repo.query!(~S"""
      UPDATE instance_settings
      SET ingress = jsonb_set(ingress, '{firewall_allowlist}', '["not-an-ip"]'::jsonb, true)
      """)

      InstanceSettings.reset_cache_for_test()
      attach_firewall_denial_handler()
      setup = active_api_key_fixture()

      denied =
        conn
        |> remote_ip({198, 51, 100, 20})
        |> put_req_header("authorization", setup.authorization)
        |> get("/api/codex/usage")

      assert json_response(denied, 403)["error"]["code"] == "access_denied"

      assert_received {@firewall_denied_event, %{count: 1}, %{scope: "runtime", reason: "invalid_allowlist_rules"}}

      refute_received {@firewall_denied_event, _measurements, _metadata}
    end

    test "empty raw allowlist remains disabled when client resolution failed" do
      settings = %OperationalSettings{
        firewall_allowlist: [],
        firewall_allowlist_compiled: {:error, :invalid_rule}
      }

      conn =
        Plug.Test.conn(:get, "/api/codex/usage")
        |> Plug.Conn.put_private(
          :codex_pooler_client_ip_resolution,
          %Resolution{
            status: :error,
            peer_ip: {10, 0, 0, 1},
            client_ip: {10, 0, 0, 1},
            source: :peer,
            reason: :invalid_forwarded_entry,
            inspected_hops: 1
          }
        )

      assert {^conn, %Decision{outcome: :allow}} = Firewall.evaluate(conn, settings)
    end

    @tag :capture_log
    test "malformed trusted forwarding input fails closed only on runtime routes", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{
        firewall_allowlist: ["203.0.113.10"],
        trusted_proxies: ["10.0.0.1"]
      })

      malformed_headers = [
        "203.0.113.10, unknown",
        "203.0.113.10:0",
        "203.0.113.10:65536",
        <<255>>,
        :binary.copy("1", 65),
        Enum.join(List.duplicate("10.0.0.1", 33), ",")
      ]

      for value <- malformed_headers do
        denied =
          conn
          |> recycle()
          |> remote_ip({10, 0, 0, 1})
          |> put_req_header("x-forwarded-for", value)
          |> get("/api/codex/usage")

        assert json_response(denied, 403)["error"]["code"] == "access_denied"

        health =
          conn
          |> recycle()
          |> remote_ip({10, 0, 0, 1})
          |> put_req_header("x-forwarded-for", value)
          |> get("/healthz")

        assert json_response(health, 200) == %{"status" => "ok"}
        assert health.remote_ip == {10, 0, 0, 1}
        refute Map.has_key?(health.private, :codex_pooler_client_ip_resolution)
      end
    end

    test "preserves current runtime API behavior when no allowlist is configured", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: []})
      setup = active_api_key_fixture()

      conn =
        conn
        |> remote_ip({198, 51, 100, 20})
        |> put_req_header("authorization", setup.authorization)
        |> get("/api/codex/usage")

      assert %{"plan_type" => "api_key"} = json_response(conn, 200)
    end

    test "allows a direct allowlisted client IP", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})
      setup = active_api_key_fixture()

      conn =
        conn
        |> remote_ip({203, 0, 113, 10})
        |> put_req_header("authorization", setup.authorization)
        |> get("/api/codex/usage")

      assert %{"plan_type" => "api_key"} = json_response(conn, 200)
    end

    test "allows an exact IPv6 client IP", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["2001:db8::10"]})
      setup = active_api_key_fixture()

      conn =
        conn
        |> remote_ip({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x0010})
        |> put_req_header("authorization", setup.authorization)
        |> get("/api/codex/usage")

      assert %{"plan_type" => "api_key"} = json_response(conn, 200)
    end

    @tag :capture_log
    test "allows and denies IPv6 CIDR clients by 128-bit network prefix", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["2001:db8:abcd:12::/64"]})
      setup = active_api_key_fixture()

      allowed_conn =
        conn
        |> remote_ip({0x2001, 0x0DB8, 0xABCD, 0x0012, 0, 0, 0, 0xBEEF})
        |> put_req_header("authorization", setup.authorization)
        |> get("/api/codex/usage")

      assert %{"plan_type" => "api_key"} = json_response(allowed_conn, 200)

      denied_conn =
        conn
        |> recycle()
        |> remote_ip({0x2001, 0x0DB8, 0xABCD, 0x0013, 0, 0, 0, 0xBEEF})
        |> put_req_header("authorization", setup.authorization)
        |> get("/api/codex/usage")

      assert json_response(denied_conn, 403)["error"]["code"] == "access_denied"
    end

    @tag :capture_log
    test "denies a direct client IP outside the allowlist", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      conn = conn |> remote_ip({198, 51, 100, 20}) |> get("/api/codex/usage")

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "access_denied"
      assert error["type"] == "invalid_request_error"
      refute inspect(error) =~ "198.51.100.20"
    end

    @tag :capture_log
    test "denies content provenance checks before authentication", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      conn =
        conn
        |> remote_ip({198, 51, 100, 20})
        |> compressed_post("/v1/content_provenance_checks", "gzip", "not a gzip body")

      assert %{
               "error" => %{
                 "code" => "access_denied",
                 "message" => "client IP is not allowed",
                 "param" => nil,
                 "type" => "invalid_request_error"
               }
             } = json_response(conn, 403)
    end

    @tag :capture_log
    test "denies the beta Agents and vault families before authentication", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      for path <- ["/v1/agents/sessions", "/v1/agents/sessions/session_fixture/events", "/v1/vaults/vault_fixture/credentials"] do
        conn =
          conn
          |> recycle()
          |> remote_ip({198, 51, 100, 20})
          |> compressed_post(path, "gzip", "not a gzip body")

        assert %{
                 "error" => %{
                   "code" => "access_denied",
                   "message" => "client IP is not allowed",
                   "param" => nil,
                   "type" => "invalid_request_error"
                 }
               } = json_response(conn, 403)
      end
    end

    @tag :capture_log
    test "applies firewall to every runtime API route family", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      for {method, path} <- [
            {:get, "/backend-api/codex/models"},
            {:post, "/backend-api/codex/responses"},
            {:get, "/backend-api/codex/v1/responses"},
            {:post, "/backend-api/codex/v1/responses"},
            {:post, "/backend-api/codex/responses/compact"},
            {:post, "/backend-api/codex/v1/responses/compact"},
            {:post, "/backend-api/files"},
            {:post, "/backend-api/files/file_123/uploaded"},
            {:post, "/backend-api/transcribe"},
            {:get, "/wham/usage"},
            {:get, "/backend-api/wham/usage"}
          ] do
        conn = conn |> recycle() |> remote_ip({198, 51, 100, 20}) |> dispatch(method, path)

        assert json_response(conn, 403)["error"]["code"] == "access_denied"
      end
    end

    @tag :capture_log
    test "ignores spoofed forwarded headers from untrusted peers", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      conn =
        conn
        |> remote_ip({198, 51, 100, 20})
        |> put_req_header("x-forwarded-for", "203.0.113.10")
        |> get("/api/codex/usage")

      assert json_response(conn, 403)["error"]["code"] == "access_denied"
    end

    test "honors forwarded client IPs from trusted proxies", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{
        firewall_allowlist: ["203.0.113.10"],
        trusted_proxies: ["10.0.0.1"]
      })

      setup = active_api_key_fixture()

      conn =
        conn
        |> remote_ip({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.10, 10.0.0.1")
        |> put_req_header("authorization", setup.authorization)
        |> get("/api/codex/usage")

      assert %{"plan_type" => "api_key"} = json_response(conn, 200)
    end

    test "honors configured positional x-forwarded-for depth", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{
        firewall_allowlist: ["203.0.113.10"],
        trusted_proxies: ["10.0.0.1"],
        forwarded_client_ip_source: :x_forwarded_for,
        forwarded_proxy_depth: 2
      })

      setup = active_api_key_fixture()

      conn =
        conn
        |> remote_ip({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.10, 10.0.0.1")
        |> put_req_header("authorization", setup.authorization)
        |> get("/api/codex/usage")

      assert %{"plan_type" => "api_key"} = json_response(conn, 200)
      assert conn.remote_ip == {203, 0, 113, 10}

      assert %Resolution{
               status: :ok,
               source: :x_forwarded_for,
               inspected_hops: 2
             } = conn.private[:codex_pooler_client_ip_resolution]
    end

    @tag :capture_log
    test "ignores spoof-prepended forwarded hops from trusted proxies", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{
        firewall_allowlist: ["198.51.100.77"],
        trusted_proxies: ["10.0.0.1"]
      })

      setup = active_api_key_fixture()

      conn =
        conn
        |> remote_ip({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "198.51.100.77, 203.0.113.10, 10.0.0.1")
        |> put_req_header("authorization", setup.authorization)
        |> get("/api/codex/usage")

      assert json_response(conn, 403)["error"]["code"] == "access_denied"
    end

    @tag :capture_log
    test "combines duplicate forwarded headers before trusted proxy resolution", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{
        firewall_allowlist: ["198.51.100.77"],
        trusted_proxies: ["10.0.0.1"]
      })

      setup = active_api_key_fixture()

      conn =
        conn
        |> remote_ip({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "198.51.100.77")
        |> append_req_header("x-forwarded-for", "203.0.113.10, 10.0.0.1")
        |> put_req_header("authorization", setup.authorization)
        |> get("/api/codex/usage")

      assert json_response(conn, 403)["error"]["code"] == "access_denied"
    end

    @tag :capture_log
    test "applies trusted proxy updates to subsequent requests only", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})
      setup = active_api_key_fixture()

      denied_conn =
        conn
        |> remote_ip({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.10, 10.0.0.1")
        |> put_req_header("authorization", setup.authorization)
        |> get("/api/codex/usage")

      assert json_response(denied_conn, 403)["error"]["code"] == "access_denied"

      setup_runtime_ingress(%OperationalSettings{
        firewall_allowlist: ["203.0.113.10"],
        trusted_proxies: ["10.0.0.1"]
      })

      allowed_conn =
        conn
        |> recycle()
        |> remote_ip({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.10, 10.0.0.1")
        |> put_req_header("authorization", setup.authorization)
        |> get("/api/codex/usage")

      assert %{"plan_type" => "api_key"} = json_response(allowed_conn, 200)
    end

    test "does not apply runtime firewall settings to non-runtime API route families", %{
      conn: conn
    } do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      conn = conn |> remote_ip({198, 51, 100, 20}) |> get("/healthz")

      assert %{"status" => "ok"} = json_response(conn, 200)
    end

    @tag :capture_log
    test "applies the same firewall semantics to the MCP route", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      conn = conn |> remote_ip({198, 51, 100, 20}) |> get("/mcp")

      assert json_response(conn, 403)["error"]["message"] == "client IP is not allowed"
    end
  end

  describe "pruned runtime helper firewall matrix" do
    test "disabled malformed firewall settings preserve the fixed absent response", %{conn: conn} do
      attach_firewall_denial_handler()

      setup_runtime_ingress_override(%OperationalSettings{
        firewall_allowlist: [],
        firewall_allowlist_compiled: {:error, :invalid_rule}
      })

      {upstream, setup} = pruned_runtime_helper_setup()

      conn =
        conn
        |> auth(setup)
        |> remote_ip({198, 51, 100, 20})
        |> put_req_header("content-type", "application/json")
        |> post("/backend-api/codex/analytics-events/events", ~s({"event":))

      assert_pruned_helper_absent(conn)
      assert_pruned_helper_side_effects_absent(conn, upstream)
      refute_received {@firewall_denied_event, _measurements, _metadata}
    end

    test "stale admitted firewall settings preserve the fixed absent response", %{conn: conn} do
      attach_firewall_denial_handler()

      setup_runtime_ingress_override(%OperationalSettings{
        source: :database,
        db_available?: false,
        secrets_available?: false,
        firewall_allowlist: ["203.0.113.10"]
      })

      {upstream, setup} = pruned_runtime_helper_setup()

      conn =
        conn
        |> auth(setup)
        |> remote_ip({203, 0, 113, 10})
        |> put_req_header("content-type", "application/json")
        |> post("/backend-api/codex/analytics-events/events", ~s({"event":))

      assert_pruned_helper_absent(conn)
      assert_pruned_helper_side_effects_absent(conn, upstream)
      refute_received {@firewall_denied_event, _measurements, _metadata}
    end

    @tag :capture_log
    test "denied clients receive the normal runtime firewall envelope", %{conn: conn} do
      attach_firewall_denial_handler()
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})
      {upstream, setup} = pruned_runtime_helper_setup()

      conn =
        conn
        |> auth(setup)
        |> remote_ip({198, 51, 100, 20})
        |> put_req_header("content-type", "application/json")
        |> post("/backend-api/codex/analytics-events/events", ~s({"event":))

      assert json_response(conn, 403) == %{
               "error" => %{
                 "code" => "access_denied",
                 "message" => "client IP is not allowed",
                 "param" => nil,
                 "type" => "invalid_request_error"
               }
             }

      assert_pruned_helper_side_effects_absent(conn, upstream)

      assert_received {@firewall_denied_event, %{count: 1}, %{scope: "runtime", reason: "not_allowed"}}

      refute_received {@firewall_denied_event, _measurements, _metadata}
    end

    @tag :capture_log
    test "cold settings receive the normal runtime unavailable envelope", %{conn: conn} do
      attach_firewall_denial_handler()
      {upstream, setup} = pruned_runtime_helper_setup()

      conn =
        with_cache_unregistered(fn ->
          conn
          |> auth(setup)
          |> remote_ip({198, 51, 100, 20})
          |> put_req_header("content-type", "application/json")
          |> post("/backend-api/codex/analytics-events/events", ~s({"event":))
        end)

      assert json_response(conn, 503) == %{
               "error" => %{
                 "code" => "settings_unavailable",
                 "message" => "runtime settings are temporarily unavailable",
                 "param" => nil,
                 "type" => "server_error"
               }
             }

      assert_pruned_helper_side_effects_absent(conn, upstream)

      assert_received {@firewall_denied_event, %{count: 1}, %{scope: "runtime", reason: "settings_unavailable"}}

      refute_received {@firewall_denied_event, _measurements, _metadata}
    end
  end

  describe "protected backend JSON authentication order" do
    test "authenticates backend JSON runtime routes before Plug.Parsers reads malformed bodies",
         %{
           conn: conn
         } do
      setup_runtime_ingress(%OperationalSettings{})

      for path <- [
            "/backend-api/codex/responses",
            "/backend-api/codex/v1/responses",
            "/backend-api/codex/responses/compact",
            "/backend-api/codex/v1/responses/compact",
            "/backend-api/codex/v1/chat/completions",
            "/backend-api/codex/images/generations",
            "/backend-api/codex/images/edits",
            "/backend-api/files",
            "/backend-api/files/file_123/uploaded"
          ] do
        conn =
          conn
          |> recycle()
          |> put_req_header("content-type", "application/json")
          |> post(path, ~s({"model":))

        assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
      end
    end

    test "pruned backend helper routes preserve the fixed absent response without ingress auth",
         %{
           conn: conn
         } do
      setup_runtime_ingress(%OperationalSettings{})

      for {method, path, content_type, body} <- [
            {"GET", "/backend-api/codex/agent-identities/jwks?kid=absent", nil, nil},
            {"GET", "/backend-api/wham/agent-identities/jwks?kid=absent", nil, nil},
            {"POST", "/backend-api/codex/thread/goal/get", "application/json", "{}"},
            {"POST", "/backend-api/codex/thread/goal/set", "application/json", "{}"},
            {"POST", "/backend-api/codex/thread/goal/clear", "application/json", "{}"},
            {"POST", "/backend-api/codex/analytics-events/events", "application/json", "{}"},
            {"POST", "/backend-api/codex/memories/trace_summarize", "application/json", "{}"},
            {"POST", "/backend-api/codex/alpha/search", "application/json", "{}"},
            {"POST", "/backend-api/codex/realtime/calls", "application/sdp", "v=0\r\ns=codex-pooler-test\r\n"},
            {"POST", "/backend-api/codex/safety/arc", "application/json", "{}"}
          ] do
        conn =
          conn
          |> recycle()
          |> dispatch_absent_backend_helper(method, path, content_type, body)

        assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
        assert response(conn, 404) == "Not Found"
      end
    end

    test "malformed pruned thread goal set returns absent before parsing or side effects", %{
      conn: conn
    } do
      setup_runtime_ingress(%OperationalSettings{})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/backend-api/codex/thread/goal/set", ~s({"goal":))

      assert response(conn, 404) =~ "Not Found"
      assert Repo.aggregate(Request, :count) == 0
    end

    test "malformed pruned reset-credit consume returns absent before parsing or side effects", %{
      conn: conn
    } do
      setup_runtime_ingress(%OperationalSettings{})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/codex/rate-limit-reset-credits/consume", ~s({"redeem_request_id":))

      assert response(conn, 404) =~ "Not Found"
      assert Repo.aggregate(Request, :count) == 0
    end
  end

  describe "image generation permission order" do
    test "denies the four exact image routes before body parsing", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})
      setup = disabled_image_generation_setup()

      for path <- [
            "/backend-api/codex/images/generations",
            "/backend-api/codex/images/edits",
            "/v1/images/generations",
            "/v1/images/edits"
          ] do
        conn =
          conn
          |> recycle()
          |> auth(setup)
          |> put_req_header("content-type", "application/json")
          |> post(path, ~s({"model":))

        assert %{
                 "error" => %{
                   "code" => "image_generation_disabled",
                   "message" => "Image generation is disabled for this pool",
                   "param" => nil,
                   "type" => "invalid_request_error"
                 }
               } = json_response(conn, 403)
      end
    end

    test "keeps authentication ahead of the image permission", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})

      for path <- [
            "/backend-api/codex/images/generations",
            "/backend-api/codex/images/edits",
            "/v1/images/generations",
            "/v1/images/edits"
          ] do
        conn =
          conn
          |> recycle()
          |> put_req_header("content-type", "application/json")
          |> post(path, ~s({"model":))

        assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
      end
    end

    test "denies disabled compressed image requests before decompression", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{max_compressed_body_bytes: 1})
      setup = disabled_image_generation_setup()

      conn =
        conn
        |> auth(setup)
        |> compressed_post(
          "/backend-api/codex/images/generations",
          "gzip",
          :zlib.gzip(~s({"model":"x"}))
        )

      assert json_response(conn, 403)["error"]["code"] == "image_generation_disabled"
    end

    test "does not gate unsupported image variations", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})
      setup = disabled_image_generation_setup()

      conn =
        conn
        |> auth(setup)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/images/variations", "{}")

      assert json_response(conn, 404)["error"]["code"] == "unsupported_endpoint"
    end
  end

  describe "audio transcription permission order" do
    for path <- ["/backend-api/transcribe", "/v1/audio/transcriptions", "/v1/audio/%74ranscriptions"],
        {content_type, body, encoding} <- [
          {"application/json", ~s({"model":), nil},
          {"multipart/form-data; boundary=synthetic", "malformed multipart", nil},
          {"application/json", "invalid gzip bytes", "gzip"}
        ] do
      @audio_path path
      @audio_content_type content_type
      @audio_body body
      @audio_encoding encoding
      test "#{path} denies disabled #{content_type} #{encoding} before reading the body", %{conn: conn} do
        setup_runtime_ingress(%OperationalSettings{})
        setup = active_api_key_fixture()
        setup.pool |> Pools.ensure_routing_settings() |> Ecto.Changeset.change(allow_audio_transcription: false) |> Repo.update!()

        conn = conn |> auth(setup) |> put_req_header("content-type", @audio_content_type)
        conn = if @audio_encoding, do: put_req_header(conn, "content-encoding", @audio_encoding), else: conn
        response = post(conn, @audio_path, @audio_body)

        assert %{"error" => %{"code" => "audio_transcription_disabled", "type" => "invalid_request_error"}} = json_response(response, 403)
        assert Repo.aggregate(Request, :count) == 0
        assert Repo.aggregate(Attempt, :count) == 0
        assert Repo.aggregate(LedgerEntry, :count) == 0
      end
    end

    test "authentication remains first and unsupported audio routes keep their own contract", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})
      setup = active_api_key_fixture()
      setup.pool |> Pools.ensure_routing_settings() |> Ecto.Changeset.change(allow_audio_transcription: false) |> Repo.update!()

      for path <- ["/backend-api/transcribe", "/v1/audio/transcriptions"] do
        response = conn |> recycle() |> put_req_header("content-type", "multipart/form-data; boundary=synthetic") |> post(path, "malformed multipart")
        assert json_response(response, 401)["error"]["code"] == "api_key_missing"
      end

      for path <- ["/v1/audio/speech", "/v1/audio/translations"] do
        response = conn |> recycle() |> auth(setup) |> post(path, %{})
        assert response.status == 404
        refute response.resp_body =~ "audio_transcription_disabled"
      end

      settings = Pools.get_routing_settings(setup.pool)
      settings |> Ecto.Changeset.change(allow_audio_transcription: true) |> Repo.update!()
      response = conn |> recycle() |> auth(setup) |> post("/v1/audio/transcriptions", %{"model" => "gpt-transcribe"})
      assert json_response(response, 400)["error"]["param"] == "file"
    end
  end

  describe "compressed runtime API requests" do
    test "decode returns the unchanged connection when content-encoding is absent", %{conn: conn} do
      assert {:ok, ^conn} = CompressedBody.decode(conn, OperationalSettings.current())
    end

    test "decodes gzip JSON bodies within configured limits", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "gzip_ok"}))
      setup = gateway_setup(upstream)

      body = gateway_body(setup)

      conn =
        conn
        |> auth(setup)
        |> compressed_post(
          "/backend-api/codex/responses",
          "gzip",
          :zlib.gzip(CodexPooler.JSON.encode!(body))
        )

      assert %{"id" => "gzip_ok"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["model"] == setup.model.upstream_model_id
    end

    test "accepts uncompressed JSON when compressed encodings are disabled", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{decompression_algorithms: []})
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "plain_json_ok"}))
      setup = gateway_setup(upstream)

      conn =
        conn
        |> auth(setup)
        |> put_req_header("content-type", "application/json")
        |> post("/backend-api/codex/responses", CodexPooler.JSON.encode!(gateway_body(setup)))

      assert %{"id" => "plain_json_ok"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["model"] == setup.model.upstream_model_id
    end

    test "rejects compressed JSON when no encodings are selected", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{decompression_algorithms: []})
      setup = active_api_key_fixture()

      conn =
        conn
        |> auth(setup)
        |> compressed_post(
          "/backend-api/codex/responses",
          "gzip",
          :zlib.gzip(~s({"model":"x"}))
        )

      assert json_response(conn, 415)["error"]["code"] == "unsupported_content_encoding"
    end

    test "rejects unknown compressed JSON encodings", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})
      setup = active_api_key_fixture()

      conn =
        conn
        |> auth(setup)
        |> compressed_post("/backend-api/codex/responses", "br", "compressed-json-placeholder")

      assert json_response(conn, 415)["error"]["code"] == "unsupported_content_encoding"
    end

    test "decodes deflate JSON bodies within configured limits", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "deflate_ok"}))
      setup = gateway_setup(upstream)

      body = gateway_body(setup)

      conn =
        conn
        |> auth(setup)
        |> compressed_post("/backend-api/codex/responses", "deflate", deflate(body))

      assert %{"id" => "deflate_ok"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["input"] == body["input"]
    end

    test "decodes zstd JSON bodies within configured limits", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "zstd_ok"}))
      setup = gateway_setup(upstream)

      body = gateway_body(setup)

      conn =
        conn
        |> auth(setup)
        |> compressed_post("/backend-api/codex/responses", "zstd", zstd(body))

      assert %{"id" => "zstd_ok"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["input"] == body["input"]
    end

    test "decodes zstd JSON bodies that require multiple decoder outputs", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{
        max_decompressed_body_bytes: 1_048_576,
        max_decompression_ratio: 1_000_000
      })

      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "zstd_multi_output_ok"}))
      setup = gateway_setup(upstream)
      input = String.duplicate("a", 500_000)
      body = gateway_body(setup) |> Map.put("input", native_text_input(input))
      compressed = zstd(body)

      assert zstd_first_output_shape(compressed) == {:remainder, 131_072}

      conn =
        conn
        |> auth(setup)
        |> compressed_post("/backend-api/codex/responses", "zstd", compressed)

      assert %{"id" => "zstd_multi_output_ok"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["input"] == native_text_input(input)
    end

    test "decodes zstd JSON bodies across multiple decoder input chunks", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{
        max_decompressed_body_bytes: 1_048_576,
        max_decompression_ratio: 100
      })

      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "zstd_chunked_ok"}))
      setup = gateway_setup(upstream)
      input = deterministic_input(450_000)
      body = gateway_body(setup) |> Map.put("input", native_text_input(input))
      compressed = zstd(body)

      assert byte_size(compressed) > 16_384

      conn =
        conn
        |> auth(setup)
        |> compressed_post("/backend-api/codex/responses", "zstd", compressed)

      assert %{"id" => "zstd_chunked_ok"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["input"] == native_text_input(input)
    end

    test "accepts a zstd JSON body at the exact one MiB decompressed limit", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{
        max_decompressed_body_bytes: 1_048_576,
        max_decompression_ratio: 1_000_000
      })

      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "zstd_one_mib_ok"}))
      setup = gateway_setup(upstream)
      body = fixed_size_gateway_body(setup, 1_048_576)
      encoded = CodexPooler.JSON.encode!(body)

      assert byte_size(encoded) == 1_048_576

      conn =
        conn
        |> auth(setup)
        |> compressed_post("/backend-api/codex/responses", "zstd", zstd_encoded(encoded))

      assert %{"id" => "zstd_one_mib_ok"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["input"] |> native_input_text() |> byte_size() > 1_000_000
    end

    test "rejects zstd when runtime support is unavailable", %{conn: conn} do
      setup_runtime_ingress_override(%OperationalSettings{
        decompression_algorithms: ["zstd"],
        zstd_supported?: false
      })

      setup = active_api_key_fixture()

      conn =
        conn
        |> auth(setup)
        |> compressed_post("/backend-api/codex/responses", "zstd", zstd(%{"model" => "x"}))

      assert json_response(conn, 415)["error"]["code"] == "unsupported_content_encoding"
    end

    test "authenticates compressed requests before reading the body", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{max_compressed_body_bytes: 1})

      conn =
        compressed_post(
          conn,
          "/backend-api/codex/responses",
          "gzip",
          :zlib.gzip(~s({"model":"x"}))
        )

      assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
    end

    test "rejects unsupported content provenance checks before gzip decompression", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
      setup = upstream |> gateway_setup() |> disabled_image_generation_setup()

      conn =
        conn
        |> auth(setup)
        |> compressed_post("/v1/content_provenance_checks", "gzip", "not a gzip body")

      assert %{
               "error" => %{
                 "code" => "unsupported_endpoint",
                 "message" => "Unsupported OpenAI /v1 endpoint",
                 "param" => nil,
                 "type" => "invalid_request_error"
               }
             } = json_response(conn, 404)

      assert FakeUpstream.requests(upstream) == []
      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    end

    test "rejects the beta Agents family before gzip decompression, body parsing and dispatch", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{max_compressed_body_bytes: 1})
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
      setup = gateway_setup(upstream)

      for path <- ["/v1/agents/sessions", "/v1/agents/sessions/session_fixture/events", "/v1/vaults"] do
        conn = conn |> recycle() |> auth(setup) |> compressed_post(path, "gzip", "not a gzip body")

        assert %{
                 "error" => %{
                   "code" => "unsupported_endpoint",
                   "message" => "Unsupported OpenAI /v1 endpoint: the beta Agents API is not supported",
                   "param" => nil,
                   "type" => "invalid_request_error"
                 }
               } = json_response(conn, 404)
      end

      assert FakeUpstream.requests(upstream) == []
      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    end

    test "rejects compressed bodies above the compressed-size limit", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{max_compressed_body_bytes: 1})
      setup = active_api_key_fixture()

      conn =
        conn
        |> auth(setup)
        |> compressed_post(
          "/backend-api/codex/responses",
          "gzip",
          :zlib.gzip(~s({"model":"x"}))
        )

      error = json_response(conn, 413)["error"]
      assert error["code"] == "compressed_request_too_large"
      assert error["message"] =~ "1-byte limit"
      assert error["message"] =~ "ingress.max_compressed_body_bytes in System > Firewall before retrying"
      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
      assert Repo.aggregate(LedgerEntry, :count) == 0
    end

    test "plain JSON readers pick up updated body limits for new requests" do
      setup = active_api_key_fixture()
      small_payload = String.duplicate("a", 32)

      setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 8})

      assert {:more, _partial, _conn} =
               Plug.Test.conn(:post, "/backend-api/codex/responses", small_payload)
               |> auth(setup)
               |> put_req_header("content-type", "application/json")
               |> RuntimeIngress.call([])
               |> CompressedBody.read_plain_json_body([])

      setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 128})

      assert {:ok, ^small_payload, _conn} =
               Plug.Test.conn(:post, "/backend-api/codex/responses", small_payload)
               |> auth(setup)
               |> put_req_header("content-type", "application/json")
               |> RuntimeIngress.call([])
               |> CompressedBody.read_plain_json_body([])
    end

    @tag slow: "decodes a synthetic 48-image history larger than the former 32 MiB compressed budget"
    test "default ingress budgets accept image-heavy zstd history while explicit smaller limits still reject" do
      settings = %OperationalSettings{}
      previous_settings = %{settings | max_compressed_body_bytes: 32 * 1024 * 1024, max_decompressed_body_bytes: 64 * 1024 * 1024}

      images =
        Enum.map(1..48, fn _index ->
          %{"type" => "input_image", "image_url" => "data:image/png;base64," <> Base.encode64(:crypto.strong_rand_bytes(1_500_000))}
        end)

      encoded = CodexPooler.JSON.encode!(%{"input" => [%{"type" => "message", "role" => "user", "content" => images}]})
      compressed = zstd_encoded(encoded)
      assert byte_size(compressed) > previous_settings.max_compressed_body_bytes
      assert byte_size(compressed) < settings.max_compressed_body_bytes
      assert byte_size(encoded) > previous_settings.max_decompressed_body_bytes
      assert byte_size(encoded) < settings.max_decompressed_body_bytes

      new_conn = fn ->
        Plug.Test.conn(:post, "/backend-api/codex/responses", compressed)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("content-encoding", "zstd")
      end

      assert {:error, %{status: 413, code: "compressed_request_too_large", message: message}, _conn} = CompressedBody.decode(new_conn.(), previous_settings)
      assert message =~ "#{previous_settings.max_compressed_body_bytes}-byte limit"
      assert message =~ "ingress.max_compressed_body_bytes"

      assert {:error, %{status: 413, code: "decompressed_request_too_large"}} = CompressedBody.decode(new_conn.(), %{settings | max_decompressed_body_bytes: previous_settings.max_decompressed_body_bytes})

      assert {:ok, accepted} = CompressedBody.decode(new_conn.(), settings)
      assert length(hd(accepted.body_params["input"])["content"]) == 48
      assert :crypto.hash(:sha256, CodexPooler.JSON.encode!(accepted.body_params)) == :crypto.hash(:sha256, encoded)

      assert {:ok, ^encoded, _conn} =
               Plug.Test.conn(:post, "/plain-json-reader", encoded)
               |> put_private(:codex_pooler_runtime_ingress_settings, settings)
               |> CompressedBody.read_plain_json_body([])
    end

    test "rejects decompressed bodies above the decompressed-size limit", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 16})
      setup = active_api_key_fixture()

      payload = %{"model" => "x", "input" => native_text_input(String.duplicate("a", 200))}

      conn =
        conn
        |> auth(setup)
        |> compressed_post(
          "/backend-api/codex/responses",
          "gzip",
          :zlib.gzip(CodexPooler.JSON.encode!(payload))
        )

      error = json_response(conn, 413)["error"]
      assert error["code"] == "decompressed_request_too_large"
      assert error["message"] =~ "16-byte limit"
      assert error["message"] =~ "ingress.max_decompressed_body_bytes in System > Firewall before retrying"
      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
      assert Repo.aggregate(LedgerEntry, :count) == 0
    end

    test "updated decompressed limits affect subsequent compressed requests", %{conn: conn} do
      payload = %{"model" => "x", "input" => native_text_input(String.duplicate("a", 200))}
      compressed = :zlib.gzip(CodexPooler.JSON.encode!(payload))

      setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 16})
      setup = active_api_key_fixture()

      rejected_conn =
        conn
        |> auth(setup)
        |> compressed_post("/backend-api/codex/responses", "gzip", compressed)

      assert json_response(rejected_conn, 413)["error"]["code"] ==
               "decompressed_request_too_large"

      setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 4_096})
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "gzip_updated_limit_ok"}))
      gateway_setup = gateway_setup(upstream)

      accepted_conn =
        conn
        |> recycle()
        |> auth(gateway_setup)
        |> compressed_post(
          "/backend-api/codex/responses",
          "gzip",
          :zlib.gzip(
            CodexPooler.JSON.encode!(
              gateway_body(gateway_setup)
              |> Map.put("input", payload["input"])
            )
          )
        )

      assert %{"id" => "gzip_updated_limit_ok"} = json_response(accepted_conn, 200)
    end

    test "reads compressed request bodies across multiple read chunks", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{
        max_compressed_body_bytes: 3 * 1024 * 1024,
        max_decompressed_body_bytes: 5 * 1024 * 1024,
        max_decompression_ratio: 100
      })

      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "gzip_chunked_ok"}))
      setup = gateway_setup(upstream)
      large_input = :crypto.strong_rand_bytes(1_200_000) |> Base.encode16(case: :lower)
      body = gateway_body(setup) |> Map.put("input", native_text_input(large_input))
      compressed = :zlib.gzip(CodexPooler.JSON.encode!(body))

      assert byte_size(compressed) > 1_000_000

      conn =
        conn
        |> auth(setup)
        |> compressed_post("/backend-api/codex/responses", "gzip", compressed)

      assert %{"id" => "gzip_chunked_ok"} = json_response(conn, 200)
    end

    test "rejects zstd bodies above the decompressed-size limit during streaming inflate", %{
      conn: conn
    } do
      setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 16})
      setup = active_api_key_fixture()

      payload = %{"model" => "x", "input" => String.duplicate("a", 200)}

      conn =
        conn
        |> auth(setup)
        |> compressed_post("/backend-api/codex/responses", "zstd", zstd(payload))

      assert json_response(conn, 413)["error"]["code"] == "decompressed_request_too_large"
    end

    test "rejects a highly compressed gzip body during bounded inflate", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{
        max_decompressed_body_bytes: 4_096,
        max_decompression_ratio: 1_000_000
      })

      setup = active_api_key_fixture()

      payload = %{"model" => "x", "input" => String.duplicate("a", 200_000)}

      conn =
        conn
        |> auth(setup)
        |> compressed_post(
          "/backend-api/codex/responses",
          "gzip",
          :zlib.gzip(CodexPooler.JSON.encode!(payload))
        )

      assert json_response(conn, 413)["error"]["code"] == "decompressed_request_too_large"
    end

    test "rejects bodies that exceed the decompression ratio limit", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{
        max_decompressed_body_bytes: 1_000_000,
        max_decompression_ratio: 2
      })

      setup = active_api_key_fixture()

      payload = %{"model" => "x", "input" => String.duplicate("a", 20_000)}

      conn =
        conn
        |> auth(setup)
        |> compressed_post(
          "/backend-api/codex/responses",
          "gzip",
          :zlib.gzip(CodexPooler.JSON.encode!(payload))
        )

      assert json_response(conn, 413)["error"]["code"] == "decompression_ratio_exceeded"
    end

    test "rejects zstd bodies that exceed the decompression ratio limit", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{
        max_decompressed_body_bytes: 1_000_000,
        max_decompression_ratio: 2
      })

      setup = active_api_key_fixture()
      payload = %{"model" => "x", "input" => String.duplicate("a", 20_000)}

      conn =
        conn
        |> auth(setup)
        |> compressed_post("/backend-api/codex/responses", "zstd", zstd(payload))

      assert json_response(conn, 413)["error"]["code"] == "decompression_ratio_exceeded"
    end

    test "rejects decompression when the timeout budget is exhausted", %{conn: conn} do
      setup_runtime_ingress_override(%OperationalSettings{decompression_timeout_ms: 0})
      setup = active_api_key_fixture()

      conn =
        conn
        |> auth(setup)
        |> compressed_post(
          "/backend-api/codex/responses",
          "gzip",
          :zlib.gzip(~s({"model":"x"}))
        )

      assert json_response(conn, 408)["error"]["code"] == "request_decompression_timeout"
    end

    test "normalizes decompression task exits into the invalid compressed request envelope", %{
      conn: conn
    } do
      setup_runtime_ingress(%OperationalSettings{})
      setup = active_api_key_fixture()

      conn =
        conn
        |> auth(setup)
        |> compressed_post("/backend-api/codex/responses", "gzip", "not a gzip body")

      assert %{"error" => error} = json_response(conn, 400)
      assert error["code"] == "invalid_request"
      assert error["message"] == "compressed request body is invalid"
    end

    test "normalizes exited decompression tasks without escaping the runtime envelope" do
      assert {:error, error} =
               CompressedBody.normalize_decompression_task_result({:exit, {:data_error, []}})

      assert error.status == 400
      assert error.code == "invalid_request"
      assert error.message == "compressed request body is invalid"
    end
  end

  defp parser_error_side_effect_counts do
    for schema <- [Request, Attempt, LedgerEntry, CodexPooler.Files.FileRecord, CodexPooler.Audit.AuditEvent], into: %{}, do: {schema, Repo.aggregate(schema, :count)}
  end

  defp start_parser_error_endpoint! do
    observer = self()
    functions = [{Plug.Conn, :read_body, 2}, {Plug.Conn, :read_part_headers, 2}, {CodexPooler.JSON, :decode, 2}, {CompressedBody, :decode, 2}, {Plug.Upload, :random_file, 1}, {Phoenix.Endpoint.RenderErrors, :__catch__, 5}, {Plug.ErrorHandler, :__catch__, 6}]
    functions = if function_exported?(@endpoint, :handle_errors, 2), do: [{@endpoint, :handle_errors, 2} | functions], else: functions
    on_exit(fn -> for mfa <- functions, do: :erlang.trace_pattern(mfa, false, [:local]) end)

    for {module, _function, _arity} = mfa <- functions do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(mfa, true, [:local]) == 1
    end

    probe = fn conn, _opts ->
      Process.delete(:parser_error_sent_conn)
      :erlang.trace(self(), true, [:call, :arity, {:tracer, observer}])

      conn =
        register_before_send(conn, fn result ->
          Process.put(:parser_error_sent_conn, result)
          result
        end)

      result =
        try do
          @endpoint.call(conn, @endpoint.init([]))
        rescue
          _error ->
            case Process.get(:parser_error_sent_conn) do
              %Plug.Conn{} = sent -> %{sent | state: :sent}
              _none -> reraise "parser probe failed before sending a response", __STACKTRACE__
            end
        end

      :erlang.trace(self(), false, [:call])
      delivered = :erlang.trace_delivered(self())

      receive do
        {:trace_delivered, _pid, ^delivered} -> :ok
      after
        5_000 -> raise "parser exception trace barrier timed out"
      end

      send(observer, {:parser_error_finished, self(), not match?(%Plug.Conn.Unfetched{}, result.body_params)})
      Process.delete(:parser_error_sent_conn)
      result
    end

    refute @endpoint.config(:debug_errors, false)
    listener = start_supervised!({Bandit, plug: probe, port: 0, ip: {127, 0, 0, 1}, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    ownership = capture_public_endpoint_identity!(listener)

    on_exit(fn ->
      assert_public_endpoint_identity_released!(ownership)
    end)

    port
  end

  defp parser_error_request(port, path, content_type, body, authorization, extra_headers \\ []) do
    headers = [{"connection", "close"}, {"content-type", content_type}, {"accept", "application/json, text/event-stream"}]
    headers = Enum.reduce(extra_headers, headers, fn {key, value}, headers -> List.keystore(headers, key, 0, {key, value}) end)
    headers = if authorization, do: [{"authorization", authorization} | headers], else: headers
    response = Req.post!("http://127.0.0.1:#{port}" <> path, headers: headers, body: body, decode_body: false, redirect: false, retry: false)
    assert_receive {:parser_error_finished, pid, parsed}, 10_000
    {calls, wrapper_order} = drain_parser_error_calls(pid, %{}, [])

    envelope =
      case CodexPooler.JSON.decode(response.body) do
        {:ok, value} when is_map(value) -> value
        _other -> %{}
      end

    %{
      wrapper_order: wrapper_order,
      status: response.status,
      code: get_in(envelope, ["error", "code"]),
      message: get_in(envelope, ["error", "message"]),
      jsonrpc: envelope["jsonrpc"],
      id: envelope["id"],
      parsed: parsed,
      body_reads: Map.get(calls, {Plug.Conn, :read_body, 2}, 0),
      part_reads: Map.get(calls, {Plug.Conn, :read_part_headers, 2}, 0),
      json_decodes: Map.get(calls, {CodexPooler.JSON, :decode, 2}, 0),
      compressed_decodes: Map.get(calls, {CompressedBody, :decode, 2}, 0),
      uploads: Map.get(calls, {Plug.Upload, :random_file, 1}, 0),
      phoenix_renders: Map.get(calls, {Phoenix.Endpoint.RenderErrors, :__catch__, 5}, 0),
      plug_error_catches: Map.get(calls, {Plug.ErrorHandler, :__catch__, 6}, 0),
      endpoint_error_handlers: Map.get(calls, {@endpoint, :handle_errors, 2}, 0)
    }
  end

  defp drain_parser_error_calls(pid, counts, order) do
    receive do
      {:trace, ^pid, :call, {module, _function, _arity} = mfa} ->
        order = if module in [Phoenix.Endpoint.RenderErrors, Plug.ErrorHandler], do: [module | order], else: order
        drain_parser_error_calls(pid, Map.update(counts, mfa, 1, &(&1 + 1)), order)
    after
      0 -> {counts, Enum.reverse(order)}
    end
  end

  defp with_parser_upload_directory(fun) do
    root = Path.join(System.tmp_dir!(), "parser-budget-upload-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}")
    previous = :persistent_term.get(Plug.Upload)

    on_exit(fn ->
      :persistent_term.put(Plug.Upload, previous)
      File.rm_rf!(root)
      refute File.exists?(root)
    end)

    File.mkdir!(root)
    :persistent_term.put(Plug.Upload, {[root], "parser-budget"})

    try do
      fun.()
    after
      :persistent_term.put(Plug.Upload, previous)
      File.rm_rf!(root)
      refute File.exists?(root)
    end
  end

  defp start_parser_scope_endpoint! do
    observer = self()
    functions = [{Plug.Conn, :read_body, 2}, {Plug.Conn, :read_part_body, 2}, {CodexPooler.JSON, :decode, 2}, {CompressedBody, :decode, 2}, {Plug.Upload, :random_file, 1}]
    on_exit(fn -> for mfa <- functions, do: :erlang.trace_pattern(mfa, false, [:local]) end)

    for {module, _function, _arity} = mfa <- functions do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(mfa, true, [:local]) == 1
    end

    probe = fn conn, _opts ->
      :erlang.trace(self(), true, [:call, :arity, {:tracer, observer}])

      conn =
        register_before_send(conn, fn result ->
          :erlang.trace(self(), false, [:call])
          delivered = :erlang.trace_delivered(self())

          receive do
            {:trace_delivered, _pid, ^delivered} -> :ok
          after
            5_000 -> raise "parser trace barrier timed out"
          end

          send(observer, {:parser_scope_finished, self(), result.status, not match?(%Plug.Conn.Unfetched{}, result.body_params)})
          result
        end)

      try do
        @endpoint.call(conn, @endpoint.init([]))
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

    port
  end

  defp parser_scope_request(port, method, path, content_type, body, headers \\ []) do
    response = Req.request!(method: method, url: "http://127.0.0.1:#{port}" <> path, body: body, headers: [{"connection", "close"}, {"content-type", content_type} | headers], decode_body: false, redirect: false, retry: false)
    observation = parser_scope_observation!()
    assert observation.status == response.status
    observation
  end

  defp parser_scope_observation! do
    assert_receive {:parser_scope_finished, pid, status, parsed}, 10_000
    calls = drain_parser_scope_calls(pid, %{})

    %{
      status: status,
      parsed: parsed,
      body_reads: Map.get(calls, {Plug.Conn, :read_body, 2}, 0),
      part_reads: Map.get(calls, {Plug.Conn, :read_part_body, 2}, 0),
      json_decodes: Map.get(calls, {CodexPooler.JSON, :decode, 2}, 0),
      compressed_decodes: Map.get(calls, {CompressedBody, :decode, 2}, 0),
      uploads: Map.get(calls, {Plug.Upload, :random_file, 1}, 0)
    }
  end

  defp drain_parser_scope_calls(pid, counts) do
    receive do
      {:trace, ^pid, :call, mfa} -> drain_parser_scope_calls(pid, Map.update(counts, mfa, 1, &(&1 + 1)))
    after
      0 -> counts
    end
  end

  defp parser_endpoint_outcome(method, path, content_type, body) do
    observer = self()

    conn =
      Plug.Test.conn(method, path, body)
      |> put_private(:plug_skip_csrf_protection, true)
      |> put_req_header("content-type", content_type)
      |> register_before_send(fn result ->
        send(observer, {:parser_outcome, %{status: result.status, parsed: not match?(%Plug.Conn.Unfetched{}, result.body_params)}})
        result
      end)

    try do
      @endpoint.call(conn, @endpoint.init([]))
    rescue
      _error in [Plug.Parsers.RequestTooLargeError, Phoenix.Router.NoRouteError, Plug.Conn.WrapperError] -> :handled
    end

    assert_receive {:parser_outcome, outcome}
    outcome
  end

  defp parser_multipart_body(size) do
    "--scope-boundary\r\ncontent-disposition: form-data; name=\"note\"\r\n\r\n" <> String.duplicate("a", size) <> "\r\n--scope-boundary--\r\n"
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
                 "decompression_timeout_ms" => settings.decompression_timeout_ms
               }
             })
  end

  defp setup_runtime_ingress_override(%OperationalSettings{} = settings) do
    previous = CodexPooler.TestAppEnv.restore_on_exit(OperationalSettings)

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous
      |> Keyword.put(:settings, settings)
      |> Keyword.put(:use_instance_settings?, false)
    )
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

  defp trace_call_count({module, function, arity} = traced_mfa, callback) do
    parent = self()
    start_ref = make_ref()
    release_ref = make_ref()
    {:module, ^module} = Code.ensure_loaded(module)
    :erlang.trace_pattern(traced_mfa, true, [:local])

    task =
      Task.async(fn ->
        receive do
          {:start_trace, ^start_ref} -> :ok
        end

        result = callback.()
        send(parent, {:trace_result, self(), result})

        receive do
          {:release_trace, ^release_ref} -> result
        end
      end)

    try do
      :erlang.trace(task.pid, true, [:call, {:tracer, parent}])
      send(task.pid, {:start_trace, start_ref})

      result =
        receive do
          {:trace_result, pid, result} when pid == task.pid -> result
        after
          @detection_timeout_ms -> flunk("traced callback did not complete")
        end

      delivered_ref = :erlang.trace_delivered(task.pid)
      assert_receive {:trace_delivered, pid, ^delivered_ref} when pid == task.pid, @detection_timeout_ms

      calls = collect_traced_calls(task.pid, module, function, arity, 0)
      send(task.pid, {:release_trace, release_ref})
      assert Task.await(task, @detection_timeout_ms) == result
      {result, calls}
    after
      :erlang.trace_pattern(traced_mfa, false, [:local])

      if Process.alive?(task.pid) do
        :erlang.trace(task.pid, false, [:call])
        send(task.pid, {:release_trace, release_ref})
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  defp collect_traced_calls(traced_pid, module, function, arity, count) do
    receive do
      {:trace, ^traced_pid, :call, {^module, ^function, arguments}}
      when length(arguments) == arity ->
        collect_traced_calls(traced_pid, module, function, arity, count + 1)
    after
      0 -> count
    end
  end

  defp remote_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp compressed_post(conn, path, encoding, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("content-encoding", encoding)
    |> post(path, body)
  end

  defp dispatch(conn, :get, path), do: get(conn, path)
  defp dispatch(conn, :post, path), do: post(conn, path, %{})

  defp dispatch_absent_backend_helper(conn, "GET", path, _content_type, _body),
    do: get(conn, path)

  defp dispatch_absent_backend_helper(conn, "POST", path, content_type, body) do
    conn
    |> put_req_header("content-type", content_type)
    |> post(path, body)
  end

  defp deflate(body) when is_map(body), do: body |> CodexPooler.JSON.encode!() |> :zlib.compress()

  defp zstd(body) when is_map(body) do
    body |> CodexPooler.JSON.encode!() |> zstd_encoded()
  end

  defp zstd_encoded(body), do: body |> :zstd.compress() |> IO.iodata_to_binary()

  defp zstd_first_output_shape(compressed) do
    {:ok, context} = :zstd.context(:decompress)

    try do
      case :zstd.stream(context, compressed) do
        {:continue, remainder, output} when byte_size(remainder) > 0 ->
          {:remainder, IO.iodata_length(output)}

        {:continue, output} ->
          {:consumed, IO.iodata_length(output)}
      end
    after
      :zstd.close(context)
    end
  end

  defp gateway_body(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("hello")
    }
  end

  defp fixed_size_gateway_body(setup, target_bytes) do
    body = gateway_body(setup) |> Map.put("input", native_text_input(""))
    padding_bytes = target_bytes - byte_size(CodexPooler.JSON.encode!(body))
    Map.put(body, "input", native_text_input(String.duplicate("a", padding_bytes)))
  end

  defp native_text_input(text) do
    [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => text}]
      }
    ]
  end

  defp native_input_text([%{"content" => [%{"text" => text}]}]), do: text

  defp deterministic_input(target_bytes) do
    1..ceil(target_bytes / 64)
    |> Enum.map(fn index ->
      index
      |> Integer.to_string()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end)
    |> IO.iodata_to_binary()
    |> binary_part(0, target_bytes)
  end

  defp gateway_setup(upstream) do
    key = active_api_key_fixture()
    pool = key.pool
    upstream = gateway_upstream(pool, upstream, "upstream-token")
    prime_routing_quota!(upstream.identity)

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-test-model",
        upstream_model_id: "provider-gpt-test-model",
        pricing_ref: "provider-gpt-test-model",
        metadata: %{
          "source_assignment_ids" => [upstream.assignment.id],
          "source_assignment_models" => %{
            upstream.assignment.id => %{"slug" => "gpt-test-model"}
          }
        },
        supports_responses: true,
        supports_streaming: true
      })

    pricing_snapshot!(model)
    Map.merge(key, %{identity: upstream.identity, assignment: upstream.assignment, model: model})
  end

  defp disabled_image_generation_setup(setup \\ active_api_key_fixture()) do
    setup.pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(allow_image_generation: false)
    |> Repo.update!()

    assert %RoutingSettings{allow_image_generation: false} =
             Pools.get_routing_settings(setup.pool)

    setup
  end

  defp gateway_upstream(pool, upstream, token) do
    metadata = %{"base_url" => FakeUpstream.url(upstream)}

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        identity_metadata: metadata,
        assignment_metadata: metadata
      })

    assert {:ok, identity} =
             IdentityLifecycle.activate_upstream_identity(identity)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: token
             })

    assert {:ok, assignment} =
             PoolAssignments.activate_pool_assignment(assignment)

    %{identity: identity, assignment: assignment}
  end

  defp prime_routing_quota!(identity) do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             Windows.upsert_quota_windows(identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("1"),
                 reset_at: reset_at,
                 source: "codex_response_headers",
                 source_precision: "observed",
                 freshness_state: "fresh"
               }
             ])
  end

  defp pricing_snapshot!(model) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %PricingSnapshot{
      model_identifier: model.upstream_model_id,
      price_version: "runtime-ingress-test-v1",
      currency_code: "USD",
      billing_unit: "token",
      input_token_micros: Decimal.new(10),
      cached_input_token_micros: Decimal.new(1),
      output_token_micros: Decimal.new(20),
      reasoning_token_micros: Decimal.new(30),
      request_base_micros: Decimal.new(0),
      effective_at: DateTime.add(now, -60, :second),
      captured_at: now,
      config: %{}
    }
    |> Repo.insert!()
  end

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp auth(conn, setup), do: put_req_header(conn, "authorization", setup.authorization)

  defp pruned_runtime_helper_setup do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    {upstream, gateway_setup(upstream)}
  end

  defp assert_pruned_helper_absent(conn) do
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert response(conn, 404) == "Not Found"
  end

  defp assert_pruned_helper_side_effects_absent(conn, upstream) do
    refute conn.private[:runtime_api_auth]
    assert %Plug.Conn.Unfetched{aspect: :body_params} = conn.body_params
    assert FakeUpstream.requests(upstream) == []
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end
end
