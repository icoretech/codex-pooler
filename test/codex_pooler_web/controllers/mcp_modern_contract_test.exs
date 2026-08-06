defmodule CodexPoolerWeb.McpModernContractTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures

  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings}
  alias CodexPooler.MCP.Redaction
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Mcp.Protocol

  @modern_version "2026-07-28"
  @instructions "Read-only operator metadata for a codex-pooler instance: Pools, upstream accounts, API keys, operators, invites, quota evidence, and request/audit log metadata. All tools are non-mutating. Output is sanitized and never contains secrets, tokens, prompts, or request/response bodies."

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

    %{raw_token: enabled_mcp_token!(user)}
  end

  describe "server/discover" do
    test "Given matched modern metadata and headers with authentication When discovering Then the exact private discovery envelope is returned",
         %{conn: conn, raw_token: raw_token} do
      conn =
        conn
        |> modern_discovery_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> post("/mcp", Jason.encode!(discovery_request()))

      response = json_response(conn, 200)
      server_version = app_version()

      assert response == %{
               "jsonrpc" => "2.0",
               "id" => "discover-1",
               "result" => %{
                 "resultType" => "complete",
                 "supportedVersions" => Protocol.supported_protocol_versions(),
                 "capabilities" => %{"tools" => %{"listChanged" => false}},
                 "instructions" => @instructions,
                 "ttlMs" => 3_600_000,
                 "cacheScope" => "private",
                 "_meta" => %{
                   "io.modelcontextprotocol/serverInfo" => %{
                     "name" => "codex-pooler",
                     "version" => server_version
                   }
                 }
               }
             }

      refute Map.has_key?(response["result"], "serverInfo")
      assert :ok = Redaction.assert_mcp_output_safe!(response["result"])
    end

    test "Given a valid supported discovery request without authentication When posted Then authentication returns 401 rather than legacy fallback",
         %{conn: conn} do
      conn =
        conn
        |> modern_discovery_conn()
        |> post("/mcp", Jason.encode!(discovery_request()))

      response = json_response(conn, 401)
      assert response["error"]["code"] == -32_000
      assert response["error"]["message"] == "MCP bearer token is required"
    end

    test "Given modern metadata without client capabilities and no authentication When posted Then invalid params precedes authentication",
         %{conn: conn} do
      request =
        discovery_request(%{
          "io.modelcontextprotocol/protocolVersion" => @modern_version
        })

      conn =
        conn
        |> modern_discovery_conn()
        |> post("/mcp", Jason.encode!(request))

      response = json_response(conn, 400)
      assert response["error"]["code"] == -32_602
    end

    test "Given a modern protocol header without modern metadata When posted Then header mismatch precedes authentication",
         %{conn: conn} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "discover-1",
        "method" => "server/discover",
        "params" => %{}
      }

      conn =
        conn
        |> modern_discovery_conn()
        |> post("/mcp", Jason.encode!(request))

      response = json_response(conn, 400)
      assert response["error"]["code"] == -32_020
    end

    test "Given neither modern metadata nor a modern protocol header When posted with authentication Then legacy unknown-method behavior is preserved",
         %{conn: conn, raw_token: raw_token} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "discover-legacy",
        "method" => "server/discover",
        "params" => %{}
      }

      conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> post("/mcp", Jason.encode!(request))

      response = json_response(conn, 200)
      assert response["error"]["code"] == -32_601
    end

    test "Given an unsupported metadata version When posted Then only the supported versions are returned",
         %{conn: conn} do
      caller_version = "caller-supplied-version-marker"

      request =
        discovery_request(%{
          "io.modelcontextprotocol/protocolVersion" => caller_version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        })

      conn =
        conn
        |> modern_discovery_conn()
        |> post("/mcp", Jason.encode!(request))

      response = json_response(conn, 400)
      assert response["error"]["code"] == -32_022
      assert response["error"]["data"] == %{"supported" => Protocol.supported_protocol_versions()}
      refute Map.has_key?(response["error"]["data"], "requested")
      refute response |> Jason.encode!() |> String.contains?(caller_version)
    end

    test "Given an unsupported protocol header without metadata When posted Then only the supported versions are returned",
         %{conn: conn} do
      caller_version = "caller-header-version-marker"
      request_id = "header-only-version"

      request = %{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "method" => "tools/list",
        "params" => %{}
      }

      conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("mcp-protocol-version", caller_version)
        |> post("/mcp", Jason.encode!(request))

      response = json_response(conn, 400)

      assert response["error"] == %{
               "code" => -32_022,
               "message" => "unsupported MCP protocol version",
               "data" => %{"supported" => Protocol.supported_protocol_versions()}
             }

      assert response["id"] == request_id
      refute response |> Jason.encode!() |> String.contains?(caller_version)
    end

    test "Given a matched modern version without Mcp-Method When posted Then header mismatch precedes authentication",
         %{conn: conn} do
      conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("mcp-protocol-version", @modern_version)
        |> post("/mcp", Jason.encode!(discovery_request()))

      response = json_response(conn, 400)
      assert response["error"]["code"] == -32_020
    end

    test "Given an untrusted origin without authentication When posted Then origin rejection remains first",
         %{conn: conn} do
      conn =
        conn
        |> modern_discovery_conn()
        |> put_req_header("origin", "https://untrusted.example")
        |> post("/mcp", Jason.encode!(discovery_request()))

      response = json_response(conn, 403)
      assert response["error"]["code"] == -32_600
      assert response["error"]["message"] == "origin is not allowed"
    end
  end

  describe "advertise-equals-serve" do
    test "Given discovery advertises protocol versions When each partition is exercised Then every advertised version is accepted by its era contract",
         %{conn: conn, raw_token: raw_token} do
      discovery =
        conn
        |> modern_discovery_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> post("/mcp", Jason.encode!(discovery_request()))
        |> json_response(200)

      advertised_versions = discovery["result"]["supportedVersions"]
      modern_versions = Protocol.modern_protocol_versions()
      legacy_versions = Protocol.legacy_protocol_versions()

      assert advertised_versions == modern_versions ++ legacy_versions
      assert length(advertised_versions) == MapSet.size(MapSet.new(advertised_versions))
      assert MapSet.disjoint?(MapSet.new(modern_versions), MapSet.new(legacy_versions))

      assert MapSet.new(advertised_versions) ==
               MapSet.union(MapSet.new(modern_versions), MapSet.new(legacy_versions))

      for version <- modern_versions do
        request = %{
          "jsonrpc" => "2.0",
          "id" => "advertised-modern-#{version}",
          "method" => "tools/list",
          "params" => %{
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => version,
              "io.modelcontextprotocol/clientCapabilities" => %{}
            }
          }
        }

        response =
          conn
          |> recycle()
          |> json_rpc_conn()
          |> put_req_header("authorization", "Bearer #{raw_token}")
          |> put_req_header("mcp-protocol-version", version)
          |> put_req_header("mcp-method", "tools/list")
          |> post("/mcp", Jason.encode!(request))
          |> json_response(200)

        assert response["result"]["resultType"] == "complete"
        refute get_in(response, ["error", "code"]) == -32_022
      end

      for version <- legacy_versions do
        request = %{
          "jsonrpc" => "2.0",
          "id" => "advertised-legacy-#{version}",
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => version,
            "capabilities" => %{},
            "clientInfo" => %{"name" => "contract-client", "version" => "1.0.0"}
          }
        }

        response =
          conn
          |> recycle()
          |> json_rpc_conn()
          |> put_req_header("authorization", "Bearer #{raw_token}")
          |> put_req_header("mcp-protocol-version", version)
          |> post("/mcp", Jason.encode!(request))
          |> json_response(200)

        assert response["result"]["protocolVersion"] == version
        refute get_in(response, ["error", "code"]) == -32_022
      end
    end
  end

  describe "dual-era tool and HTTP surface" do
    test "Given an authenticated modern tools/list request When posted twice Then both complete private envelopes preserve deterministic tool order",
         %{conn: conn, raw_token: raw_token} do
      first =
        conn
        |> modern_request_conn(raw_token, "tools/list")
        |> post("/mcp", Jason.encode!(modern_request("list-1", "tools/list", %{})))
        |> json_response(200)

      second =
        conn
        |> recycle()
        |> modern_request_conn(raw_token, "tools/list")
        |> post("/mcp", Jason.encode!(modern_request("list-2", "tools/list", %{})))
        |> json_response(200)

      assert first["result"]["resultType"] == "complete"
      assert first["result"]["ttlMs"] == 3_600_000
      assert first["result"]["cacheScope"] == "private"
      assert nested_server_info?(first["result"])
      assert first["result"]["tools"] == second["result"]["tools"]
      assert first["result"]["tools"] != []
      assert :ok = Redaction.assert_mcp_output_safe!(first["result"])
    end

    test "Given an authenticated modern tools/call request When the tool succeeds Then the complete result has no cache hints",
         %{conn: conn, raw_token: raw_token} do
      tool_name = "codex_pooler_get_mcp_service_status"

      conn =
        conn
        |> modern_request_conn(raw_token, "tools/call", tool_name)
        |> post(
          "/mcp",
          Jason.encode!(
            modern_request("call-success", "tools/call", %{
              "name" => tool_name,
              "arguments" => %{}
            })
          )
        )

      result = json_response(conn, 200)["result"]
      assert result["isError"] == false
      assert result["resultType"] == "complete"
      assert nested_server_info?(result)
      refute Map.has_key?(result, "ttlMs")
      refute Map.has_key?(result, "cacheScope")
      assert :ok = Redaction.assert_mcp_output_safe!(result)
    end

    test "Given an authenticated modern tools/call request When real argument validation fails Then the CallToolResult error remains complete and non-cacheable",
         %{conn: conn, raw_token: raw_token} do
      tool_name = "codex_pooler_get_mcp_service_status"

      conn =
        conn
        |> modern_request_conn(raw_token, "tools/call", tool_name)
        |> post(
          "/mcp",
          Jason.encode!(
            modern_request("call-error", "tools/call", %{
              "name" => tool_name,
              "arguments" => %{"unexpected" => true}
            })
          )
        )

      result = json_response(conn, 200)["result"]
      assert result["isError"] == true
      assert result["resultType"] == "complete"
      assert nested_server_info?(result)
      refute Map.has_key?(result, "ttlMs")
      refute Map.has_key?(result, "cacheScope")
    end

    test "Given an exact base64 sentinel Mcp-Name When calling a plain-ASCII tool Then the encoded header is accepted",
         %{conn: conn, raw_token: raw_token} do
      tool_name = "codex_pooler_get_mcp_service_status"
      encoded_name = "=?base64?#{Base.encode64(tool_name)}?="

      conn =
        conn
        |> modern_request_conn(raw_token, "tools/call", encoded_name)
        |> post(
          "/mcp",
          Jason.encode!(
            modern_request("call-base64", "tools/call", %{
              "name" => tool_name,
              "arguments" => %{}
            })
          )
        )

      result = json_response(conn, 200)["result"]
      assert result["isError"] == false
      assert result["resultType"] == "complete"
    end

    test "Given missing mismatched malformed or unsafe mirrored headers When posting modern requests Then fixed header mismatch errors do not echo input",
         %{conn: conn, raw_token: raw_token} do
      tool_name = "codex_pooler_get_mcp_service_status"

      missing_protocol_conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("mcp-method", "tools/list")

      mismatched_protocol_conn =
        conn
        |> modern_request_conn(raw_token, "tools/list")
        |> put_req_header("mcp-protocol-version", "2025-11-25")

      cases = [
        {nil, missing_protocol_conn, modern_request("header-case-1", "tools/list", %{})},
        {"2025-11-25", mismatched_protocol_conn,
         modern_request("header-case-2", "tools/list", %{})},
        {nil, modern_request_conn(conn, raw_token, nil),
         modern_request("header-case-1", "tools/list", %{})},
        {"caller-method-marker", modern_request_conn(conn, raw_token, "caller-method-marker"),
         modern_request("header-case-3", "tools/list", %{})},
        {nil, modern_request_conn(conn, raw_token, "tools/call"),
         modern_request("header-case-3", "tools/call", %{
           "name" => tool_name,
           "arguments" => %{}
         })},
        {"other-tool", modern_request_conn(conn, raw_token, "tools/call", "other-tool"),
         modern_request("header-case-5", "tools/call", %{
           "name" => tool_name,
           "arguments" => %{}
         })},
        {"not-base64",
         modern_request_conn(conn, raw_token, "tools/call", "=?base64?not-base64?="),
         modern_request("header-case-6", "tools/call", %{
           "name" => tool_name,
           "arguments" => %{}
         })},
        {" tool-name", modern_request_conn(conn, raw_token, "tools/call", " tool-name"),
         modern_request("header-case-7", "tools/call", %{
           "name" => tool_name,
           "arguments" => %{}
         })}
      ]

      for {marker, request_conn, request} <- cases do
        response =
          request_conn
          |> post("/mcp", Jason.encode!(request))
          |> json_response(400)

        assert response["error"] == %{"code" => -32_020, "message" => "header mismatch"}

        if marker do
          refute response |> Jason.encode!() |> String.contains?(marker)
        end
      end
    end

    test "Given genuinely modern methods outside the supported set When posted Then each returns method-not-found over HTTP 404",
         %{conn: conn, raw_token: raw_token} do
      for method <- ["ping", "subscriptions/listen"] do
        conn =
          conn
          |> recycle()
          |> modern_request_conn(raw_token, method)
          |> post("/mcp", Jason.encode!(modern_request("unknown-modern", method, %{})))

        response = json_response(conn, 404)
        assert response["error"] == %{"code" => -32_601, "message" => "method not found"}
      end
    end

    test "Given initialize carries modern metadata When posted Then metadata cannot promote it out of legacy semantics",
         %{conn: conn, raw_token: raw_token} do
      request =
        modern_request("initialize-modern-looking", "initialize", %{
          "protocolVersion" => @modern_version
        })

      conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("mcp-method", "initialize")
        |> post("/mcp", Jason.encode!(request))

      response = json_response(conn, 400)
      assert response["error"]["code"] == -32_600
      assert response["error"]["message"] == "unsupported initialize protocol version"
    end

    test "Given initialize carries a modern header and a legacy body version When posted Then the header remains a legacy initialize guard",
         %{conn: conn, raw_token: raw_token} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "initialize-modern-header",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "contract-client", "version" => "1.0.0"}
        }
      }

      conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("mcp-protocol-version", @modern_version)
        |> post("/mcp", Jason.encode!(request))

      response = json_response(conn, 400)

      assert response["error"] == %{
               "code" => -32_600,
               "message" => "unsupported MCP protocol version"
             }
    end

    test "Given a legacy ping When posted Then its existing successful result remains unchanged",
         %{conn: conn, raw_token: raw_token} do
      conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> post(
          "/mcp",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => "legacy-ping",
            "method" => "ping"
          })
        )

      assert json_response(conn, 200) == %{
               "jsonrpc" => "2.0",
               "id" => "legacy-ping",
               "result" => %{}
             }
    end

    test "Given a legacy initialize list and call sequence When each response is returned Then modern envelope keys stay absent",
         %{conn: conn, raw_token: raw_token} do
      initialize = %{
        "jsonrpc" => "2.0",
        "id" => "legacy-sequence-initialize",
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "contract-client", "version" => "1.0.0"}
        }
      }

      list = %{
        "jsonrpc" => "2.0",
        "id" => "legacy-sequence-list",
        "method" => "tools/list",
        "params" => %{}
      }

      call = %{
        "jsonrpc" => "2.0",
        "id" => "legacy-sequence-call",
        "method" => "tools/call",
        "params" => %{
          "name" => "codex_pooler_get_mcp_service_status",
          "arguments" => %{}
        }
      }

      responses =
        for request <- [initialize, list, call] do
          conn
          |> recycle()
          |> json_rpc_conn()
          |> put_req_header("authorization", "Bearer #{raw_token}")
          |> post("/mcp", Jason.encode!(request))
          |> json_response(200)
          |> Map.fetch!("result")
        end

      for result <- responses do
        refute Map.has_key?(result, "resultType")
        refute Map.has_key?(result, "_meta")
        refute Map.has_key?(result, "ttlMs")
        refute Map.has_key?(result, "cacheScope")
      end
    end

    test "Given a notification carrying modern protocol and ignored headers When posted without an id Then it remains accepted without modern validation",
         %{conn: conn, raw_token: raw_token} do
      conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("authorization", "Bearer #{raw_token}")
        |> put_req_header("mcp-protocol-version", @modern_version)
        |> put_req_header("mcp-session-id", "ignored-session")
        |> put_req_header("last-event-id", "ignored-event")
        |> post(
          "/mcp",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "method" => "notifications/initialized",
            "params" => %{}
          })
        )

      assert response(conn, 202) == ""
      assert get_resp_header(conn, "mcp-session-id") == []
      assert get_resp_header(conn, "last-event-id") == []
    end

    test "Given session and resume headers on a modern list When posted Then they are ignored and never echoed",
         %{conn: conn, raw_token: raw_token} do
      conn =
        conn
        |> modern_request_conn(raw_token, "tools/list")
        |> put_req_header("mcp-session-id", "ignored-session")
        |> put_req_header("last-event-id", "ignored-event")
        |> post("/mcp", Jason.encode!(modern_request("ignored-headers", "tools/list", %{})))

      assert json_response(conn, 200)["result"]["resultType"] == "complete"
      assert get_resp_header(conn, "mcp-session-id") == []
      assert get_resp_header(conn, "last-event-id") == []
    end

    test "Given unsupported HTTP methods When routed Then GET DELETE and OPTIONS advertise only POST and OPTIONS" do
      get_conn = get(build_conn(), "/mcp")
      delete_conn = delete(build_conn(), "/mcp")
      options_conn = :options |> build_conn("/mcp") |> CodexPoolerWeb.Router.call([])

      assert response(get_conn, 405) == ""
      assert response(delete_conn, 405) == ""
      assert response(options_conn, 204) == ""

      for checked_conn <- [get_conn, delete_conn, options_conn] do
        assert get_resp_header(checked_conn, "allow") == ["POST, OPTIONS"]
      end
    end
  end

  defp discovery_request(meta \\ modern_meta()) do
    %{
      "jsonrpc" => "2.0",
      "id" => "discover-1",
      "method" => "server/discover",
      "params" => %{"_meta" => meta}
    }
  end

  defp modern_meta do
    %{
      "io.modelcontextprotocol/protocolVersion" => @modern_version,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }
  end

  defp modern_discovery_conn(conn) do
    conn
    |> json_rpc_conn()
    |> put_req_header("mcp-protocol-version", @modern_version)
    |> put_req_header("mcp-method", "server/discover")
  end

  defp modern_request(id, method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put(params, "_meta", modern_meta())
    }
  end

  defp modern_request_conn(conn, raw_token, method, name \\ nil) do
    conn =
      conn
      |> json_rpc_conn()
      |> put_req_header("authorization", "Bearer #{raw_token}")
      |> put_req_header("mcp-protocol-version", @modern_version)

    conn = if method, do: put_req_header(conn, "mcp-method", method), else: conn
    if name, do: put_req_header(conn, "mcp-name", name), else: conn
  end

  defp nested_server_info?(result) do
    match?(
      %{
        "io.modelcontextprotocol/serverInfo" => %{
          "name" => "codex-pooler",
          "version" => version
        }
      }
      when is_binary(version),
      result["_meta"]
    )
  end

  defp json_rpc_conn(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
  end

  defp enabled_mcp_token!(user) do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _updated} =
             InstanceSettings.update_system_settings(settings, %{"mcp" => %{"enabled" => true}})

    assert {:ok, _settings} = MCP.set_operator_mcp_enabled(user, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(user, %{label: "Modern contract MCP"})

    raw_token
  end

  defp app_version do
    case Application.spec(:codex_pooler, :vsn) do
      nil -> "0.0.0"
      version -> List.to_string(version)
    end
  end
end
