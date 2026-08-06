defmodule CodexPoolerWeb.McpContractTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings}
  alias CodexPooler.Repo

  @mcp_version "2025-11-25"
  @codex_mcp_version "2025-06-18"
  @allow "POST, OPTIONS"

  setup do
    reset_bootstrap_state_fixture!()
    Repo.delete_all(OperatorMCPKey)
    Repo.delete_all(OperatorMCPSettings)
    Repo.delete_all(CodexPooler.InstanceSettings.Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      InstanceSettings.reset_cache_for_test()
    end)

    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    user = user |> Ecto.Changeset.change(password_change_required: false) |> Repo.update!()
    raw_token = enabled_mcp_token!(user)

    %{raw_token: raw_token}
  end

  describe "method surface" do
    test "GET is routed but unavailable for stateless SSE", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "text/event-stream")
        |> get("/mcp")

      assert response(conn, 405) == ""
      assert get_resp_header(conn, "allow") == [@allow]
    end

    test "HEAD mirrors GET method denial without a response body", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "text/event-stream")
        |> head("/mcp")

      assert conn.status == 405
      assert conn.resp_body == ""
      assert get_resp_header(conn, "allow") == [@allow]
    end

    test "DELETE is routed and denied with the MCP Allow header", %{conn: conn} do
      conn = delete(conn, "/mcp")

      assert response(conn, 405) == ""
      assert get_resp_header(conn, "allow") == [@allow]
    end

    test "OPTIONS returns the MCP Allow header without JSON-RPC work" do
      conn = :options |> build_conn("/mcp") |> CodexPoolerWeb.Router.call([])

      assert response(conn, 204) == ""
      assert get_resp_header(conn, "allow") == [@allow]
    end
  end

  describe "HTTP and protocol headers" do
    test "POST requires JSON content type", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", @mcp_version)
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_rpc_error(conn, 415)["error"]["message"] ==
               "content-type must be application/json"
    end

    test "POST requires both JSON and SSE in Accept", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-protocol-version", @mcp_version)
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_rpc_error(conn, 406)["error"]["message"] ==
               "accept must include application/json and text/event-stream"
    end

    test "POST rejects unsupported protocol header versions", %{conn: conn} do
      conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("mcp-protocol-version", "2025-03-26")
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_rpc_error(conn, 400)["error"]["message"] ==
               "unsupported MCP protocol version"

      refute inspect(json_response(conn, 400)) =~ "2025-03-26"
    end

    test "POST rejects present untrusted origins", %{conn: conn} do
      conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("mcp-protocol-version", @mcp_version)
        |> put_req_header("origin", "https://untrusted.example")
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_rpc_error(conn, 403)["error"]["message"] == "origin is not allowed"
    end

    test "POST accepts absent Origin and absent protocol header for CLI clients", %{
      conn: conn,
      raw_token: raw_token
    } do
      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post("/mcp", Jason.encode!(initialize_request()))

      response = json_response(conn, 200)
      assert response["result"]["protocolVersion"] == @mcp_version
    end
  end

  describe "initialize and minimal tools contract" do
    test "initialize returns server info and empty tools capability", %{
      conn: conn,
      raw_token: raw_token
    } do
      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post("/mcp", Jason.encode!(initialize_request()))

      response = json_response(conn, 200)

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == "init-1"
      assert response["result"]["protocolVersion"] == @mcp_version
      assert response["result"]["serverInfo"]["name"] == "codex-pooler"
      assert is_binary(response["result"]["serverInfo"]["version"])
      assert response["result"]["capabilities"]["tools"] == %{"listChanged" => false}
      refute get_resp_header(conn, "mcp-session-id") != []
    end

    test "initialize accepts each supported body protocol version without a protocol header", %{
      conn: conn,
      raw_token: raw_token
    } do
      for version <- [@mcp_version, @codex_mcp_version] do
        checked_conn =
          conn
          |> recycle()
          |> authenticated_json_rpc_conn(raw_token)
          |> post("/mcp", Jason.encode!(initialize_request(version)))

        assert json_response(checked_conn, 200)["result"]["protocolVersion"] == version
      end
    end

    test "initialize accepts supported body and header conflicts with the body version", %{
      conn: conn,
      raw_token: raw_token
    } do
      for {body_version, header_version} <- [
            {@codex_mcp_version, @mcp_version},
            {@mcp_version, @codex_mcp_version}
          ] do
        checked_conn =
          conn
          |> recycle()
          |> authenticated_json_rpc_conn(raw_token)
          |> put_req_header("mcp-protocol-version", header_version)
          |> post("/mcp", Jason.encode!(initialize_request(body_version)))

        assert json_response(checked_conn, 200)["result"]["protocolVersion"] == body_version
      end
    end

    test "initialize rejects unsupported body protocol versions", %{
      conn: conn,
      raw_token: raw_token
    } do
      request = put_in(initialize_request(), ["params", "protocolVersion"], "2025-03-26")

      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post("/mcp", Jason.encode!(request))

      assert json_rpc_error(conn, 400)["error"]["message"] ==
               "unsupported initialize protocol version"

      refute inspect(json_response(conn, 400)) =~ "2025-03-26"
    end

    test "initialize rejects missing body protocol versions", %{
      conn: conn,
      raw_token: raw_token
    } do
      request = pop_in(initialize_request(), ["params", "protocolVersion"]) |> elem(1)

      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post("/mcp", Jason.encode!(request))

      assert json_rpc_error(conn, 400)["error"]["message"] ==
               "unsupported initialize protocol version"
    end

    test "non-initialize requests accept absent and supported protocol headers", %{
      conn: conn,
      raw_token: raw_token
    } do
      for version <- [nil, @mcp_version, @codex_mcp_version] do
        checked_conn =
          conn
          |> recycle()
          |> authenticated_json_rpc_conn(raw_token)
          |> maybe_put_protocol_header(version)
          |> post("/mcp", Jason.encode!(ping_request()))

        assert json_response(checked_conn, 200) == %{
                 "jsonrpc" => "2.0",
                 "id" => "ping-1",
                 "result" => %{}
               }
      end
    end

    test "non-initialize requests reject unsupported protocol headers", %{
      conn: conn,
      raw_token: raw_token
    } do
      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> put_req_header("mcp-protocol-version", "2025-03-26")
        |> post("/mcp", Jason.encode!(ping_request()))

      assert json_rpc_error(conn, 400)["error"]["message"] ==
               "unsupported MCP protocol version"

      refute inspect(json_response(conn, 400)) =~ "2025-03-26"
    end

    test "tools/list returns the service status tool after catalog foundation", %{
      conn: conn,
      raw_token: raw_token
    } do
      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post(
          "/mcp",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => "tools-1",
            "method" => "tools/list",
            "params" => %{}
          })
        )

      response = json_response(conn, 200)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == "tools-1"

      assert [%{"name" => "codex_pooler_get_mcp_service_status"} | _rest] =
               response["result"]["tools"]
    end

    test "tools/call returns JSON-RPC tool-not-found for unknown tools", %{
      conn: conn,
      raw_token: raw_token
    } do
      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post(
          "/mcp",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => "call-1",
            "method" => "tools/call",
            "params" => %{"name" => "codex_pooler_unknown", "arguments" => %{}}
          })
        )

      error = json_rpc_error(conn, 200)["error"]
      assert error["code"] == -32_602
      assert error["message"] == "MCP tool was not found"
    end
  end

  describe "JSON-RPC body shapes" do
    test "notifications are accepted with 202 and an empty body", %{
      conn: conn,
      raw_token: raw_token
    } do
      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post(
          "/mcp",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "method" => "notifications/initialized",
            "params" => %{}
          })
        )

      assert response(conn, 202) == ""
    end

    test "JSON-RPC responses from clients are accepted with 202 and an empty body", %{
      conn: conn,
      raw_token: raw_token
    } do
      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post(
          "/mcp",
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => "server-request-1", "result" => %{}})
        )

      assert response(conn, 202) == ""
    end

    test "batch arrays are rejected", %{conn: conn} do
      conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("mcp-protocol-version", @mcp_version)
        |> post("/mcp", Jason.encode!([initialize_request()]))

      assert json_rpc_error(conn, 400)["error"]["message"] == "batch JSON-RPC is not supported"
    end

    test "malformed JSON is rejected with a sanitized JSON-RPC parse error" do
      conn =
        Plug.Test.conn("POST", "/mcp", ~s({"jsonrpc":"2.0","id":"bad","method":"initialize"))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", @mcp_version)
        |> @endpoint.call(@endpoint.init([]))

      error = json_rpc_error(conn, 400)["error"]
      assert error["code"] == -32_700
      assert error["message"] == "parse error"
      refute inspect(error) =~ "initialize"
    end

    test "invalid null ids are rejected", %{conn: conn} do
      request = %{initialize_request() | "id" => nil}

      conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("mcp-protocol-version", @mcp_version)
        |> post("/mcp", Jason.encode!(request))

      assert json_rpc_error(conn, 400)["error"]["message"] ==
               "request id must be a string or number"
    end

    test "invalid params are rejected", %{conn: conn} do
      request = put_in(initialize_request(), ["params"], [])

      conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("mcp-protocol-version", @mcp_version)
        |> post("/mcp", Jason.encode!(request))

      assert json_rpc_error(conn, 400)["error"]["message"] == "params must be an object"
    end

    test "JSON-RPC response objects cannot also be requests", %{conn: conn} do
      conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("mcp-protocol-version", @mcp_version)
        |> post(
          "/mcp",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => "mixed",
            "method" => "ping",
            "result" => %{}
          })
        )

      assert json_rpc_error(conn, 400)["error"]["message"] ==
               "JSON-RPC message cannot mix request and response fields"
    end

    test "unsupported methods return sanitized JSON-RPC errors", %{
      conn: conn,
      raw_token: raw_token
    } do
      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post(
          "/mcp",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => "unsupported-1",
            "method" => "resources/list",
            "params" => %{"secret" => "metadata-only-test-value"}
          })
        )

      error_response = json_rpc_error(conn, 200)

      assert error_response["id"] == "unsupported-1"
      assert error_response["error"]["code"] == -32_601
      assert error_response["error"]["message"] == "method not found"
      refute inspect(error_response) =~ "metadata-only-test-value"
      refute inspect(error_response) =~ "resources/list"
    end
  end

  describe "wrong auth primitives do not bypass the MCP contract" do
    test "Pool API-key bearer auth does not bypass MCP content negotiation", %{conn: conn} do
      setup = active_api_key_fixture()

      conn =
        conn
        |> put_req_header("authorization", setup.authorization)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-protocol-version", @mcp_version)
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_rpc_error(conn, 406)["error"]["message"] ==
               "accept must include application/json and text/event-stream"
    end

    test "browser session cookies do not bypass MCP content negotiation" do
      %{user: user, token: token} = bootstrap_owner_fixture()

      conn =
        build_conn()
        |> log_in_user(user, token)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-protocol-version", @mcp_version)
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_rpc_error(conn, 406)["error"]["message"] ==
               "accept must include application/json and text/event-stream"
    end

    test "query, basic, custom, invite-like, and upstream-like tokens do not bypass protocol checks",
         %{
           conn: conn
         } do
      for {header_name, header_value} <- [
            {"authorization", "Basic dXNlcjpwYXNz"},
            {"x-mcp-token", "custom-token"},
            {"x-invite-token", "invite-like-token"},
            {"x-upstream-token", "upstream-like-token"}
          ] do
        checked_conn =
          conn
          |> recycle()
          |> put_req_header(header_name, header_value)
          |> put_req_header("content-type", "application/json")
          |> put_req_header("accept", "application/json, text/event-stream")
          |> post("/mcp?token=query-token", Jason.encode!(initialize_request()))

        assert json_rpc_error(checked_conn, 401)["error"]["message"] ==
                 "MCP bearer token is required"
      end
    end
  end

  defp authenticated_json_rpc_conn(conn, raw_token) do
    conn
    |> json_rpc_conn()
    |> put_req_header("authorization", "Bearer #{raw_token}")
  end

  defp maybe_put_protocol_header(conn, nil), do: conn

  defp maybe_put_protocol_header(conn, version) do
    put_req_header(conn, "mcp-protocol-version", version)
  end

  defp enabled_mcp_token!(user) do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _updated} =
             InstanceSettings.update_system_settings(settings, %{"mcp" => %{"enabled" => true}})

    assert {:ok, _settings} = MCP.set_operator_mcp_enabled(user, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(user, %{label: "Contract MCP"})

    raw_token
  end

  defp json_rpc_conn(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
  end

  defp json_rpc_error(conn, status) do
    response = json_response(conn, status)
    assert response["jsonrpc"] == "2.0"
    assert is_map(response["error"])
    response
  end

  defp ping_request do
    %{"jsonrpc" => "2.0", "id" => "ping-1", "method" => "ping"}
  end

  defp initialize_request(protocol_version \\ @mcp_version) do
    %{
      "jsonrpc" => "2.0",
      "id" => "init-1",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "example-client", "version" => "0.0.1"}
      }
    }
  end
end
