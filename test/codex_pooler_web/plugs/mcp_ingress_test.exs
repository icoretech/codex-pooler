defmodule CodexPoolerWeb.Plugs.McpIngressTest do
  use CodexPoolerWeb.ConnCase, async: false

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
    previous_operational_settings = Application.get_env(:codex_pooler, OperationalSettings, [])

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
      Application.put_env(:codex_pooler, OperationalSettings, previous_operational_settings)
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
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_response(conn, 200)["result"]["protocolVersion"] == @mcp_version
      refute_received {@firewall_denied_event, _measurements, _metadata}
    end

    test "denied MCP requests emit one bounded denial event", %{conn: conn} do
      attach_firewall_denial_handler()
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      conn =
        conn
        |> remote_ip({198, 51, 100, 20})
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_rpc_error(conn, 403) == %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{"code" => -32_600, "message" => "client IP is not allowed"}
             }

      assert_received {@firewall_denied_event, %{count: 1}, metadata}
      assert metadata == %{scope: "mcp", reason: "not_allowed"}
      refute_received {@firewall_denied_event, _measurements, _metadata}
    end

    test "cold settings return the fixed unavailable MCP envelope and telemetry", %{conn: conn} do
      attach_firewall_denial_handler()

      conn =
        with_cache_unregistered(fn ->
          conn
          |> remote_ip({198, 51, 100, 20})
          |> put_req_header("content-type", "application/json")
          |> post("/mcp", Jason.encode!(initialize_request()))
        end)

      assert json_rpc_error(conn, 503) == %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{
                 "code" => -32_000,
                 "message" => "runtime settings are temporarily unavailable"
               }
             }

      assert_received {@firewall_denied_event, %{count: 1},
                       %{scope: "mcp", reason: "settings_unavailable"}}

      refute_received {@firewall_denied_event, _measurements, _metadata}
    end

    test "empty allowlist leaves MCP reachable", %{conn: conn, user: user} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: []})
      raw_token = enabled_mcp_token!(user)

      conn =
        conn
        |> remote_ip({198, 51, 100, 20})
        |> authenticated_json_rpc_conn(raw_token)
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_response(conn, 200)["result"]["protocolVersion"] == @mcp_version
    end

    test "configured allowlist denies MCP before protocol dispatch", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{firewall_allowlist: ["203.0.113.10"]})

      conn =
        conn
        |> remote_ip({198, 51, 100, 20})
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", Jason.encode!(initialize_request()))

      error = json_rpc_error(conn, 403)["error"]
      assert error["message"] == "client IP is not allowed"
      refute inspect(error) =~ "198.51.100.20"
    end

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
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_response(allowed_conn, 200)["result"]["protocolVersion"] == @mcp_version

      denied_conn =
        conn
        |> recycle()
        |> remote_ip({198, 51, 100, 20})
        |> put_req_header("x-forwarded-for", "203.0.113.10")
        |> json_rpc_conn()
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_rpc_error(denied_conn, 403)["error"]["message"] == "client IP is not allowed"
    end

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
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_response(allowed_conn, 200)["result"]["protocolVersion"] == @mcp_version
      refute_received {@firewall_denied_event, _measurements, _metadata}

      denied_conn =
        conn
        |> recycle()
        |> remote_ip({10, 0, 0, 1})
        |> put_req_header("x-real-ip", "203.0.113.10")
        |> then(&%{&1 | req_headers: &1.req_headers ++ [{"x-real-ip", "198.51.100.20"}]})
        |> json_rpc_conn()
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_rpc_error(denied_conn, 403)["error"]["message"] == "client IP is not allowed"

      assert_received {@firewall_denied_event, %{count: 1},
                       %{scope: "mcp", reason: "duplicate_x_real_ip"}}

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
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_response(allowed_conn, 200)["result"]["protocolVersion"] == @mcp_version
    end
  end

  describe "MCP body parser ingress" do
    test "encoded MCP spelling reaches the same pre-parser content-type guard", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})

      conn =
        conn
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

    test "oversized bodies are rejected before controller dispatch", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{max_decompressed_body_bytes: 8})

      conn =
        conn
        |> json_rpc_conn()
        |> post("/mcp", String.duplicate("a", 64))

      assert json_rpc_error(conn, 413)["error"]["message"] == "request body is too large"
    end

    test "multipart bodies are rejected before multipart parsing", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})

      conn =
        conn
        |> put_req_header("content-type", "multipart/form-data; boundary=example")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", @mcp_version)
        |> post("/mcp", "not a valid multipart body")

      assert json_rpc_error(conn, 415)["error"]["message"] ==
               "content-type must be application/json"
    end

    test "compressed bodies are rejected before decompression", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})

      conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("content-encoding", "gzip")
        |> post("/mcp", :zlib.gzip(Jason.encode!(initialize_request())))

      assert json_rpc_error(conn, 415)["error"]["message"] ==
               "compressed MCP request bodies are not supported"
    end

    test "unsupported content types are rejected before controller dispatch", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{})

      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", @mcp_version)
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_rpc_error(conn, 415)["error"]["message"] ==
               "content-type must be application/json"
    end

    test "malformed JSON is rejected with sanitized parse error before controller dispatch", %{
      conn: conn
    } do
      setup_runtime_ingress(%OperationalSettings{})

      conn =
        conn
        |> json_rpc_conn()
        |> post("/mcp", ~s({"jsonrpc":"2.0","id":"bad","method":"initialize"))

      error = json_rpc_error(conn, 400)["error"]
      assert error["code"] == -32_700
      assert error["message"] == "parse error"
      refute inspect(error) =~ "initialize"
    end
  end

  describe "MCP admission" do
    test "MCP uses a dedicated local admission lane before controller dispatch", %{conn: conn} do
      setup_runtime_ingress(%OperationalSettings{
        bulkheads:
          OperationalSettings.current().bulkheads
          |> Map.put(RouteClass.mcp(), %{max_concurrency: 1, queue_limit: 0, queue_timeout_ms: 25})
      })

      assert {:ok, held} = Admission.acquire(RouteClass.mcp(), %{request_id: "held-mcp"})

      conn =
        conn
        |> json_rpc_conn()
        |> post("/mcp", Jason.encode!(initialize_request()))

      error = json_rpc_error(conn, 503)["error"]
      assert error["message"] == "MCP route class is temporarily overloaded"
      refute inspect(error) =~ "initialize"

      Admission.release(held)
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

  defp string_keyed_map(map), do: map |> Jason.encode!() |> Jason.decode!()
end
