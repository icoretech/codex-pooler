defmodule CodexPoolerWeb.Plugs.RuntimeIngressTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPoolerWeb.Plugs.RuntimeIngress.CompressedBody

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

  describe "runtime API firewall" do
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

    test "denies a direct client IP outside the allowlist", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      conn = conn |> remote_ip({198, 51, 100, 20}) |> get("/api/codex/usage")

      assert %{"error" => error} = json_response(conn, 403)
      assert error["code"] == "access_denied"
      assert error["type"] == "invalid_request_error"
      refute inspect(error) =~ "198.51.100.20"
    end

    test "applies firewall to every runtime API route family", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      for {method, path} <- [
            {:get, "/backend-api/codex/models"},
            {:get, "/backend-api/codex/agent-identities/jwks"},
            {:post, "/backend-api/codex/responses"},
            {:get, "/backend-api/codex/v1/responses"},
            {:post, "/backend-api/codex/v1/responses"},
            {:post, "/backend-api/codex/responses/compact"},
            {:post, "/backend-api/codex/v1/responses/compact"},
            {:post, "/backend-api/files"},
            {:post, "/backend-api/files/file_123/uploaded"},
            {:post, "/backend-api/transcribe"},
            {:get, "/wham/usage"},
            {:get, "/backend-api/wham/agent-identities/jwks"},
            {:get, "/backend-api/wham/usage"}
          ] do
        conn = conn |> recycle() |> remote_ip({198, 51, 100, 20}) |> dispatch(method, path)

        assert json_response(conn, 403)["error"]["code"] == "access_denied"
      end
    end

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

    test "applies the same firewall semantics to the MCP route", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      conn = conn |> remote_ip({198, 51, 100, 20}) |> get("/mcp")

      assert json_response(conn, 403)["error"]["message"] == "client IP is not allowed"
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
            "/backend-api/codex/alpha/search",
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

    @tag :feature_control_plane_alpha_search
    test "authenticates alpha search before malformed, compressed, or large bodies", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{max_compressed_body_bytes: 1})
      upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
      _setup = gateway_setup(upstream)

      malformed_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> post("/backend-api/codex/alpha/search", ~s({"id":))

      assert json_response(malformed_conn, 401)["error"]["code"] == "api_key_missing"

      compressed_conn =
        conn
        |> recycle()
        |> compressed_post(
          "/backend-api/codex/alpha/search",
          "gzip",
          :zlib.gzip(~s({"id":"search_alpha_fixture"}))
        )

      assert json_response(compressed_conn, 401)["error"]["code"] == "api_key_missing"

      large_conn =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> post(
          "/backend-api/codex/alpha/search",
          ~s({"id":"search_alpha_fixture","input":") <>
            String.duplicate("a", 10_000) <> ~s("})
        )

      assert json_response(large_conn, 401)["error"]["code"] == "api_key_missing"
      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(Request, :count, :id) == 0
      assert Repo.aggregate(Attempt, :count, :id) == 0
    end

    test "authenticates realtime SDP before controller raw body handling", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})

      conn =
        conn
        |> put_req_header("content-type", "application/sdp")
        |> post("/backend-api/codex/realtime/calls", "v=0\r\ns=codex-pooler-test\r\n")

      assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
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
          :zlib.gzip(Jason.encode!(body))
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
               Plug.Test.conn(:post, "/backend-api/codex/responses", small_payload)
               |> put_req_header("content-type", "application/json")
               |> CompressedBody.read_plain_json_body([])

      setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 128})

      assert {:ok, ^small_payload, _conn} =
               Plug.Test.conn(:post, "/backend-api/codex/responses", small_payload)
               |> put_req_header("content-type", "application/json")
               |> CompressedBody.read_plain_json_body([])
    end

    test "rejects decompressed bodies above the decompressed-size limit", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 16})
      setup = active_api_key_fixture()

      payload = %{"model" => "x", "input" => String.duplicate("a", 200)}

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
      payload = %{"model" => "x", "input" => String.duplicate("a", 200)}
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

      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "gzip_chunked_ok"}))
      setup = gateway_setup(upstream)
      large_input = :crypto.strong_rand_bytes(1_200_000) |> Base.encode16(case: :lower)
      body = gateway_body(setup) |> Map.put("input", large_input)
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
             InstanceSettings.update(instance_settings, %{
               "ingress" => %{
                 "firewall_allowlist" => settings.firewall_allowlist,
                 "trusted_proxies" => settings.trusted_proxies,
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

  defp remote_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp compressed_post(conn, path, encoding, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("content-encoding", encoding)
    |> post(path, body)
  end

  defp dispatch(conn, :get, path), do: get(conn, path)
  defp dispatch(conn, :post, path), do: post(conn, path, %{})

  defp deflate(body) when is_map(body), do: body |> Jason.encode!() |> :zlib.compress()

  defp zstd(body) when is_map(body) do
    body |> Jason.encode!() |> :zstd.compress() |> IO.iodata_to_binary()
  end

  defp gateway_body(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => "hello"
    }
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
        metadata: %{"source_assignment_ids" => [upstream.assignment.id]},
        supports_responses: true,
        supports_streaming: true
      })

    pricing_snapshot!(model)
    Map.merge(key, %{identity: upstream.identity, assignment: upstream.assignment, model: model})
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
end
