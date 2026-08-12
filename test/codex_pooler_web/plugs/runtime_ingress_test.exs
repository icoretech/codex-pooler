defmodule CodexPoolerWeb.Plugs.RuntimeIngressTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog, only: [capture_log: 2]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.OperationalSettings.IPRules
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Cache
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Pools
  alias CodexPooler.Pools.RoutingSettings
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPoolerWeb.Plugs.{RuntimeIngress, TrustedProxyRemoteIp}
  alias CodexPoolerWeb.GatewayControllerHelpers

  alias CodexPoolerWeb.Plugs.RuntimeIngress.{
    CompressedBody,
    Firewall,
    ForwardedClientIP,
    Path
  }

  alias CodexPoolerWeb.Plugs.RuntimeIngress.Firewall.Decision
  alias CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIP.Resolution

  @firewall_denied_event [:codex_pooler, :ingress, :firewall, :denied]

  defp append_req_header(conn, name, value) do
    %{conn | req_headers: conn.req_headers ++ [{name, value}]}
  end

  setup do
    previous_operational_settings = Application.get_env(:codex_pooler, OperationalSettings, [])

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
      Application.put_env(:codex_pooler, OperationalSettings, previous_operational_settings)
      Repo.delete_all(Settings)
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  describe "unencoded ingress characterization" do
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

      mcp =
        build_conn()
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
      assert json_response(pruned, 401)["error"]["code"] == "api_key_missing"

      health = get(build_conn(), "/healthz")
      assert json_response(health, 200)["status"] == "ok"
    end
  end

  describe "canonical path classification" do
    test "classifies every facade protocol from decoded path segments" do
      for {request_path, protocol} <- [
            {"/api/tags", :ollama},
            {"/api/chat", :ollama},
            {"/api/codex/usage", :runtime_metadata},
            {"/wham/usage", :runtime_metadata},
            {"/backend-api/wham/usage", :runtime_metadata},
            {"/v1/messages", :anthropic},
            {"/v1/messages/count_tokens", :anthropic},
            {"/v1/responses", :openai},
            {"/backend-api/codex/responses", :codex},
            {"/backend-api/files", :codex},
            {"/backend-api/transcribe", :codex}
          ] do
        path = :get |> Plug.Test.conn(request_path) |> Path.fetch()

        assert path.scope == :runtime
        assert Path.protocol(path) == protocol
      end
    end

    test "classifies encoded unsafe facade candidates before returning an error" do
      for {request_path, protocol} <- [
            {"/api%2Fchat", :ollama},
            {"/v1%2Fmessages", :anthropic},
            {"/v1%2Fresponses", :openai},
            {"/backend-api%2Fcodex/responses", :codex},
            {"/api/codex%00/usage", :runtime_metadata}
          ] do
        path = :get |> Plug.Test.conn(request_path) |> Path.fetch()

        assert path.scope == :runtime
        assert path.unsafe_segment?
        assert Path.protocol(path) == protocol
      end
    end

    test "attaches the exact fixed persona for each facade endpoint kind" do
      for {request_path, persona_protocol} <- [
            {"/api/chat", :ollama_chat},
            {"/api/generate", :ollama_generate},
            {"/api/tags", :metadata},
            {"/v1/messages", :anthropic_messages},
            {"/v1/responses", :openai_responses},
            {"/v1/chat/completions", :openai_chat},
            {"/v1/completions", :openai_completions},
            {"/v1/images/generations", :media},
            {"/v1/models", :metadata},
            {"/backend-api/codex/responses", :codex},
            {"/backend-api/files", :media},
            {"/backend-api/transcribe", :media},
            {"/api/codex/usage", :metadata}
          ] do
        conn = Plug.Test.conn(:get, request_path)

        assert GatewayControllerHelpers.request_opts(conn).persona ==
                 Persona.fixed(persona_protocol)
      end
    end

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
            {"/backend-api/%74ranscribe", "multipart/form-data; boundary=example",
             "invalid multipart fixture"}
          ] do
        conn =
          conn
          |> recycle()
          |> put_req_header("content-type", content_type)
          |> post(path, body)

        assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
      end
    end

    test "unsafe runtime candidates authenticate before returning the fixed invalid-path envelope",
         %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})
      setup = active_api_key_fixture()

      for path <- [
            "/v1%2Fresponses",
            "/backend-api%5Cfiles",
            "/api/codex%00/usage"
          ] do
        unauthenticated = conn |> recycle() |> remote_ip({203, 0, 113, 10}) |> get(path)
        assert json_response(unauthenticated, 401)["error"]["code"] == "api_key_missing"

        conn =
          conn
          |> recycle()
          |> auth(setup)
          |> remote_ip({203, 0, 113, 10})
          |> get(path)

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
      refute conn.halted

      Plug.Conn.send_resp(conn, 204, "")
    end

    test "stores settings and passthrough classification for ordinary JSON requests" do
      setup_runtime_ingress(%OperationalSettings{})
      settings = OperationalSettings.current()

      conn =
        Plug.Test.conn(:post, "/login", "{}")
        |> put_req_header("content-type", "application/vnd.api+json")
        |> RuntimeIngress.call([])

      assert conn.private[:codex_pooler_runtime_ingress_settings] == settings
      assert conn.private[:codex_pooler_json_parse_error_scope] == :passthrough
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
                 "code" => "service_unavailable",
                 "message" => "gemma3 is temporarily unavailable",
                 "param" => nil,
                 "type" => "server_error"
               }
             }

      assert_received {@firewall_denied_event, %{count: 1},
                       %{scope: "runtime", reason: "settings_unavailable"}}

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

      assert_received {@firewall_denied_event, %{count: 1},
                       %{scope: "runtime", reason: "invalid_allowlist_rules"}}

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

      assert_received {@firewall_denied_event, %{count: 1},
                       %{scope: "runtime", reason: "not_allowed"}}

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
                 "code" => "service_unavailable",
                 "message" => "gemma3 is temporarily unavailable",
                 "param" => nil,
                 "type" => "server_error"
               }
             }

      assert_pruned_helper_side_effects_absent(conn, upstream)

      assert_received {@firewall_denied_event, %{count: 1},
                       %{scope: "runtime", reason: "settings_unavailable"}}

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

    test "pruned backend helper routes authenticate before the fixed absent response",
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
            {"POST", "/backend-api/codex/realtime/calls", "application/sdp",
             "v=0\r\ns=codex-pooler-test\r\n"},
            {"POST", "/backend-api/codex/safety/arc", "application/json", "{}"}
          ] do
        unauthenticated =
          conn
          |> recycle()
          |> dispatch_absent_backend_helper(method, path, content_type, body)

        assert json_response(unauthenticated, 401)["error"]["code"] == "api_key_missing"
        assert %Plug.Conn.Unfetched{aspect: :body_params} = unauthenticated.body_params

        setup = active_api_key_fixture()

        conn =
          conn
          |> recycle()
          |> auth(setup)
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

      assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
      assert %Plug.Conn.Unfetched{aspect: :body_params} = conn.body_params
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

      assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
      assert %Plug.Conn.Unfetched{aspect: :body_params} = conn.body_params
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

  describe "compressed runtime API requests" do
    test "decode returns the unchanged connection when content-encoding is absent", %{conn: conn} do
      assert {:ok, ^conn} = CompressedBody.decode(conn, OperationalSettings.current())
    end

    test "decodes gzip JSON bodies within configured limits", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})
      upstream = start_upstream(FakeUpstream.json_response(gateway_response("gzip_ok")))
      setup = gateway_setup(upstream)

      body = gateway_body(setup)

      conn =
        conn
        |> auth(setup)
        |> compressed_post(
          "/backend-api/codex/responses",
          "gzip",
          :zlib.gzip(Jason.encode!(body))
        )

      assert %{"id" => "gzip_ok"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["model"] == setup.model.upstream_model_id
    end

    test "accepts uncompressed JSON when compressed encodings are disabled", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{decompression_algorithms: []})
      upstream = start_upstream(FakeUpstream.json_response(gateway_response("plain_json_ok")))
      setup = gateway_setup(upstream)

      conn =
        conn
        |> auth(setup)
        |> put_req_header("content-type", "application/json")
        |> post("/backend-api/codex/responses", Jason.encode!(gateway_body(setup)))

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
      upstream = start_upstream(FakeUpstream.json_response(gateway_response("deflate_ok")))
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
      upstream = start_upstream(FakeUpstream.json_response(gateway_response("zstd_ok")))
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

      upstream =
        start_upstream(FakeUpstream.json_response(gateway_response("zstd_multi_output_ok")))

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

      upstream = start_upstream(FakeUpstream.json_response(gateway_response("zstd_chunked_ok")))
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

      upstream = start_upstream(FakeUpstream.json_response(gateway_response("zstd_one_mib_ok")))
      setup = gateway_setup(upstream)
      body = fixed_size_gateway_body(setup, 1_048_576)
      encoded = Jason.encode!(body)

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

      upstream =
        start_upstream(FakeUpstream.json_response(gateway_response("should_not_dispatch")))

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

      assert json_response(conn, 413)["error"]["code"] == "compressed_request_too_large"
    end

    test "plain JSON readers pick up updated body limits for new requests" do
      small_payload = String.duplicate("a", 32)

      setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 8})

      assert {:more, _partial, _conn} =
               Plug.Test.conn(:post, "/plain-json-reader", small_payload)
               |> put_req_header("content-type", "application/json")
               |> RuntimeIngress.call([])
               |> CompressedBody.read_plain_json_body([])

      setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 128})

      assert {:ok, ^small_payload, _conn} =
               Plug.Test.conn(:post, "/plain-json-reader", small_payload)
               |> put_req_header("content-type", "application/json")
               |> RuntimeIngress.call([])
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
          :zlib.gzip(Jason.encode!(payload))
        )

      assert json_response(conn, 413)["error"]["code"] == "decompressed_request_too_large"
    end

    test "updated decompressed limits affect subsequent compressed requests", %{conn: conn} do
      payload = %{"model" => "x", "input" => native_text_input(String.duplicate("a", 200))}
      compressed = :zlib.gzip(Jason.encode!(payload))

      setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 16})
      setup = active_api_key_fixture()

      rejected_conn =
        conn
        |> auth(setup)
        |> compressed_post("/backend-api/codex/responses", "gzip", compressed)

      assert json_response(rejected_conn, 413)["error"]["code"] ==
               "decompressed_request_too_large"

      setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 4_096})

      upstream =
        start_upstream(FakeUpstream.json_response(gateway_response("gzip_updated_limit_ok")))

      gateway_setup = gateway_setup(upstream)

      accepted_conn =
        conn
        |> recycle()
        |> auth(gateway_setup)
        |> compressed_post(
          "/backend-api/codex/responses",
          "gzip",
          :zlib.gzip(
            Jason.encode!(gateway_body(gateway_setup) |> Map.put("input", payload["input"]))
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

      upstream = start_upstream(FakeUpstream.json_response(gateway_response("gzip_chunked_ok")))
      setup = gateway_setup(upstream)
      large_input = :crypto.strong_rand_bytes(1_200_000) |> Base.encode16(case: :lower)
      body = gateway_body(setup) |> Map.put("input", native_text_input(large_input))
      compressed = :zlib.gzip(Jason.encode!(body))

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
          :zlib.gzip(Jason.encode!(payload))
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
          :zlib.gzip(Jason.encode!(payload))
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
    previous = Application.get_env(:codex_pooler, OperationalSettings, [])

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous
      |> Keyword.put(:settings, settings)
      |> Keyword.put(:use_instance_settings?, false)
    )

    on_exit(fn -> Application.put_env(:codex_pooler, OperationalSettings, previous) end)
  end

  defp with_cache_unregistered(fun) when is_function(fun, 0) do
    cache = Process.whereis(Cache)
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
          1_000 -> flunk("traced callback did not complete")
        end

      delivered_ref = :erlang.trace_delivered(task.pid)
      assert_receive {:trace_delivered, pid, ^delivered_ref} when pid == task.pid, 1_000

      calls = collect_traced_calls(task.pid, module, function, arity, 0)
      send(task.pid, {:release_trace, release_ref})
      assert Task.await(task, 1_000) == result
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

  defp deflate(body) when is_map(body), do: body |> Jason.encode!() |> :zlib.compress()

  defp zstd(body) when is_map(body) do
    body |> Jason.encode!() |> zstd_encoded()
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

  defp gateway_response(id) do
    %{"id" => id, "object" => "response", "model" => "private-fixture", "output" => []}
  end

  defp fixed_size_gateway_body(setup, target_bytes) do
    body = gateway_body(setup) |> Map.put("input", native_text_input(""))
    padding_bytes = target_bytes - byte_size(Jason.encode!(body))
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

    reasoning_levels =
      Enum.map(~w(low medium high xhigh max ultra), &%{"effort" => &1, "description" => &1})

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-5.6-sol",
        upstream_model_id: "gpt-5.6-sol",
        pricing_ref: "gpt-5.6-sol",
        metadata: %{
          "source_assignment_ids" => [upstream.assignment.id],
          "source_assignment_models" => %{
            upstream.assignment.id => %{
              "slug" => "gpt-5.6-sol",
              "supported_reasoning_levels" => reasoning_levels,
              "default_reasoning_level" => "max"
            }
          },
          "supported_reasoning_levels" => reasoning_levels,
          "default_reasoning_level" => "max"
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
    assert %Plug.Conn.Unfetched{aspect: :body_params} = conn.body_params
    assert FakeUpstream.requests(upstream) == []
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end
end
