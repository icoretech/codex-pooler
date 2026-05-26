defmodule CodexPoolerWeb.McpControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [primary_quota_window_attrs: 1]

  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings, Redaction, ToolRegistry}
  alias CodexPooler.Postgres.INET
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @mcp_version "2025-11-25"

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

    %{user: user}
  end

  describe "authenticated MCP lifecycle" do
    test "initialize returns protocol server info and tools capability without a session id", %{
      conn: conn,
      user: user
    } do
      raw_token = enabled_mcp_token!(user)

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
      assert get_resp_header(conn, "mcp-session-id") == []
      refute inspect(response) =~ raw_token
    end

    test "notifications initialized returns accepted with an empty body", %{
      conn: conn,
      user: user
    } do
      raw_token = enabled_mcp_token!(user)

      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post(
          "/mcp",
          Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
        )

      assert response(conn, 202) == ""
    end

    test "ping returns an empty JSON-RPC result", %{conn: conn, user: user} do
      raw_token = enabled_mcp_token!(user)

      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post(
          "/mcp",
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => "ping-1", "method" => "ping"})
        )

      assert json_response(conn, 200) == %{
               "jsonrpc" => "2.0",
               "id" => "ping-1",
               "result" => %{}
             }
    end

    test "tools list returns the service status tool page", %{conn: conn, user: user} do
      raw_token = enabled_mcp_token!(user)

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

      assert [%{"name" => "codex_pooler_get_mcp_service_status"} = tool | _rest] =
               response["result"]["tools"]

      assert tool["annotations"]["readOnlyHint"] == true
      assert tool["inputSchema"]["additionalProperties"] == false
    end

    test "tools call dispatches service status without leaking token material", %{
      conn: conn,
      user: user
    } do
      raw_token = enabled_mcp_token!(user)

      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post(
          "/mcp",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => "call-1",
            "method" => "tools/call",
            "params" => %{"name" => "codex_pooler_get_mcp_service_status", "arguments" => %{}}
          })
        )

      response = json_response(conn, 200)
      result = response["result"]

      assert result["isError"] == false
      assert get_in(result, ["structuredContent", "globalGate", "enabled"]) == true
      assert get_in(result, ["structuredContent", "accountGate", "enabled"]) == true
      assert get_in(result, ["structuredContent", "protocolVersion"]) == @mcp_version
      assert get_in(result, ["structuredContent", "supportedToolCount"]) == 17
      refute inspect(response) =~ raw_token
      refute inspect(response) =~ raw_token_prefix(raw_token)
    end

    test "every advertised tool dispatches through tools/call with MCP-safe output", %{
      conn: conn,
      user: user
    } do
      raw_token = enabled_mcp_token!(user)

      listed_conn =
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

      listed_tools = json_response(listed_conn, 200)["result"]["tools"]
      assert Enum.map(listed_tools, & &1["name"]) == Enum.map(ToolRegistry.all_tools(), & &1.name)

      for tool <- listed_tools do
        checked_conn =
          conn
          |> recycle()
          |> authenticated_json_rpc_conn(raw_token)
          |> post(
            "/mcp",
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => "call-#{tool["name"]}",
              "method" => "tools/call",
              "params" => %{
                "name" => tool["name"],
                "arguments" => smoke_arguments(tool)
              }
            })
          )

        response = json_response(checked_conn, 200)
        result = response["result"]

        assert response["id"] == "call-#{tool["name"]}"
        assert is_boolean(result["isError"])
        assert :ok = Redaction.assert_mcp_output_safe!(result)
        refute inspect(response) =~ raw_token
        refute inspect(response) =~ raw_token_prefix(raw_token)
      end
    end

    test "tools call returns wire-level Pool list text and structured counts", %{
      conn: conn,
      user: user
    } do
      raw_token = enabled_mcp_token!(user)
      pool = pool_fixture(%{name: "Wire Pool"})
      %{raw_key: raw_pool_api_key, api_key: api_key} = active_api_key_fixture(pool)
      active_upstream_assignment_fixture(pool, %{account_label: "Wire upstream"})

      response =
        call_tool(conn, raw_token, "wire-list-pools", "codex_pooler_list_pools", %{
          "query" => pool.slug,
          "limit" => 10
        })

      {result, text, structured} = assert_successful_tool_response(response, "wire-list-pools")
      assert text =~ "1 Pool metadata records returned"
      assert text =~ "name=Wire Pool"
      assert text =~ "slug=#{pool.slug}"
      assert text =~ "upstreams=1"
      assert text =~ "api_keys=1"
      assert text =~ "routing=routing settings unavailable"

      assert [item] = structured["items"]
      assert item["id"] == pool.id
      assert item["slug"] == pool.slug
      assert item["api_key_count"] == 1
      assert item["upstream_count"] == 1
      assert item["routing_summary"]["summary"] =~ "routing"

      assert_no_wire_leaks(response, raw_token, [
        raw_pool_api_key,
        Base.encode16(api_key.key_hash)
      ])

      assert :ok = Redaction.assert_mcp_output_safe!(result)
    end

    test "quota list tool returns readable text and structured content over json-rpc", %{
      conn: conn,
      user: user
    } do
      raw_token = enabled_mcp_token!(user)
      pool = pool_fixture(%{name: "Wire Quota Pool"})

      %{identity: identity} =
        upstream_assignment_fixture(pool, %{
          account_label: "Wire quota upstream",
          chatgpt_account_id: "acct-wire-quota",
          plan_family: "team"
        })

      reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 primary_quota_window_attrs(%{
                   active_limit: 100,
                   credits: 42,
                   reset_at: reset_at,
                   used_percent: Decimal.new("58.0")
                 })
               ])

      list_response =
        call_tool(conn, raw_token, "wire-list-quotas", "codex_pooler_list_upstream_quotas", %{
          "pool_id" => pool.id,
          "limit" => 10
        })

      {list_result, list_text, list_structured} =
        assert_successful_tool_response(list_response, "wire-list-quotas")

      assert list_text =~ "1 upstream quota metadata records returned; total 1; offset 0"

      assert list_text =~
               "account Wire quota upstream status active account acct-wire-quota plan team"

      assert list_text =~ "account_primary: 42/100 remaining, 58.0% used"
      assert [list_item] = list_structured["items"]
      assert list_item["id"] == identity.id
      assert list_item["quota_summary"]["freshness_status"] == "fresh"
      assert [list_window] = list_item["quota_windows"]
      assert {:ok, list_reset_at, 0} = DateTime.from_iso8601(list_window["reset_at"])
      assert DateTime.compare(list_reset_at, reset_at) == :eq
      assert :ok = Redaction.assert_mcp_output_safe!(list_result)

      get_response =
        conn
        |> recycle()
        |> call_tool(raw_token, "wire-get-quota", "codex_pooler_get_upstream_quota", %{
          "selector" => identity.id
        })

      {get_result, get_text, get_structured} =
        assert_successful_tool_response(get_response, "wire-get-quota")

      assert get_text =~ "1 upstream quota metadata record returned"

      assert get_text =~
               "account Wire quota upstream status active account acct-wire-quota plan team"

      assert get_structured["status"] == "ok"
      assert get_structured["item"]["id"] == identity.id
      assert [get_window] = get_structured["item"]["quota_windows"]
      assert get_window["remaining_value"] == 42
      assert :ok = Redaction.assert_mcp_output_safe!(get_result)

      assert_no_wire_leaks(list_response, raw_token, [])
      assert_no_wire_leaks(get_response, raw_token, [])
    end

    test "tools call gets Pool by slug and not-found selectors stay absent", %{
      conn: conn,
      user: user
    } do
      raw_token = enabled_mcp_token!(user)
      pool = pool_fixture(%{name: "Wire Lookup Pool"})

      response =
        call_tool(conn, raw_token, "wire-get-pool", "codex_pooler_get_pool", %{
          "selector" => pool.slug
        })

      {result, text, structured} = assert_successful_tool_response(response, "wire-get-pool")
      assert text =~ "1 Pool metadata record returned"
      assert text =~ "id=#{pool.id}"
      assert text =~ "name=Wire Lookup Pool"
      assert text =~ "slug=#{pool.slug}"
      assert text =~ "status=active"

      assert structured["status"] == "ok"
      assert structured["item"]["id"] == pool.id
      assert structured["item"]["slug"] == pool.slug
      assert structured["item"]["name"] == "Wire Lookup Pool"
      assert :ok = Redaction.assert_mcp_output_safe!(result)

      missing_selector = "WIRE_NOT_FOUND_SELECTOR_SENTINEL"

      missing_response =
        conn
        |> recycle()
        |> call_tool(raw_token, "wire-get-pool-missing", "codex_pooler_get_pool", %{
          "selector" => missing_selector
        })

      {missing_result, missing_text, missing_structured} =
        assert_successful_tool_response(missing_response, "wire-get-pool-missing")

      assert missing_text == "No visible Pool metadata record matched the selector"

      assert missing_structured == %{
               "status" => "not_found",
               "kind" => "pool",
               "item" => nil,
               "candidates" => [],
               "message" => "Pool selector did not match"
             }

      assert_no_wire_leaks(missing_response, raw_token, [missing_selector])
      assert :ok = Redaction.assert_mcp_output_safe!(missing_result)
    end

    test "tools call lists request logs with succeeded and failed wire rows", %{
      conn: conn,
      user: user
    } do
      raw_token = enabled_mcp_token!(user)
      pool = pool_fixture(%{slug: "wire-request-logs", name: "Wire Request Logs"})
      %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "Wire runtime key"})

      %{assignment: assignment} =
        upstream_assignment_fixture(pool, %{account_label: "Wire upstream"})

      succeeded =
        request_fixture(%{pool: pool, api_key: api_key}, %{
          requested_model: "gpt-wire-logs",
          endpoint: "/backend-api/codex/responses",
          transport: "http_sse",
          status: "succeeded",
          usage_status: "usage_known",
          correlation_id: "wire-request-log-succeeded",
          response_status_code: 202,
          retry_count: 2,
          upstream_account_email: "wire.upstream@example.com",
          upstream_account_label: "wire-account-label",
          request_metadata: unsafe_log_metadata(%{"safe" => "visible metadata"})
        })

      attempt_with_latency(succeeded, assignment, 345)

      failed =
        request_fixture(%{pool: pool, api_key: api_key}, %{
          requested_model: "gpt-wire-logs",
          endpoint: "/backend-api/codex/responses",
          transport: "websocket",
          status: "failed",
          usage_status: "usage_unknown",
          correlation_id: "wire-request-log-failed",
          response_status_code: 499,
          retry_count: 1,
          request_metadata: unsafe_log_metadata(%{"safe" => "failed metadata"})
        })

      attempt_with_latency(failed, assignment, 678)

      response =
        call_tool(conn, raw_token, "wire-list-request-logs", "codex_pooler_list_request_logs", %{
          "pool_id" => pool.id,
          "model" => "gpt-wire-logs",
          "limit" => 10
        })

      {result, text, structured} =
        assert_successful_tool_response(response, "wire-list-request-logs")

      assert text =~ "2 request logs returned; total 2; offset 0; statuses failed:1, succeeded:1"
      assert text =~ "pool=wire-request-logs"
      assert text =~ "status=succeeded"
      assert text =~ "status=failed"
      assert text =~ "model=gpt-wire-logs"
      assert text =~ "transport=http_sse"
      assert text =~ "transport=websocket"
      assert text =~ "retries=2"
      assert text =~ "retries=1"
      refute text =~ "pool_slug="
      refute text =~ "metadata="

      assert structured["total"] == 2
      assert Enum.map(structured["items"], & &1["id"]) == [failed.id, succeeded.id]
      assert Enum.map(structured["items"], & &1["status"]) == ["failed", "succeeded"]
      assert Enum.all?(structured["items"], &(&1["pool_slug"] == "wire-request-logs"))
      assert Enum.any?(structured["items"], &(&1["latency_ms"] == 345))
      assert Enum.any?(structured["items"], &(&1["latency_ms"] == 678))

      assert_no_wire_leaks(response, raw_token, unsafe_wire_sentinels())
      assert :ok = Redaction.assert_mcp_output_safe!(result)
    end

    test "tools call omits adversarial request-log debug metadata over json-rpc", %{
      conn: conn,
      user: user
    } do
      raw_token = enabled_mcp_token!(user)
      pool = pool_fixture(%{slug: "wire-request-log-debug-privacy", name: "Wire Debug Privacy"})
      %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: "Wire privacy key"})

      %{assignment: assignment} =
        upstream_assignment_fixture(pool, %{
          account_label: "Wire privacy upstream",
          assignment_label: "Wire privacy assignment"
        })

      %{request: request, attempt: attempt} =
        failed_debug_request_fixture(pool, api_key, assignment, %{
          correlation_id: "wire-debug-privacy",
          codex_session_id: "wire-session-example-privacy",
          codex_session_key: "wire-session-key-example-privacy",
          request_error: "client_disconnected",
          attempt_error: "owner_drained",
          request_metadata: adversarial_debug_metadata(),
          response_metadata: adversarial_debug_metadata(),
          error_message: "raw prompt: explain private data"
        })

      _turn =
        debug_turn_fixture(request, %{
          session:
            debug_session_fixture(pool, api_key, assignment, "wire-session-key-example-privacy"),
          status: "failed",
          error_code: "turn_owner_drained",
          final_attempt_id: attempt.id,
          turn_sequence: 1
        })

      list_body =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post(
          "/mcp",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => "wire-list-request-log-debug-privacy",
            "method" => "tools/call",
            "params" => %{
              "name" => "codex_pooler_list_request_logs",
              "arguments" => %{
                "pool_id" => pool.id,
                "model" => "gpt-log-debug-contract",
                "limit" => 10
              }
            }
          })
        )
        |> response(200)

      {list_result, _list_text, list_structured} =
        assert_successful_tool_body_response(list_body, "wire-list-request-log-debug-privacy")

      assert [list_item] = list_structured["items"]
      assert list_item["id"] == request.id
      assert_debug_fields_present(list_item["debug"], :list)
      assert_response_body_omits_adversarial_debug_values(list_body)
      assert_no_wire_leaks(Jason.decode!(list_body), raw_token, adversarial_forbidden_strings())
      assert :ok = Redaction.assert_mcp_output_safe!(list_result)

      get_body =
        conn
        |> recycle()
        |> authenticated_json_rpc_conn(raw_token)
        |> post(
          "/mcp",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => "wire-get-request-log-debug-privacy",
            "method" => "tools/call",
            "params" => %{
              "name" => "codex_pooler_get_request_log",
              "arguments" => %{"id" => request.id}
            }
          })
        )
        |> response(200)

      {get_result, _get_text, get_structured} =
        assert_successful_tool_body_response(get_body, "wire-get-request-log-debug-privacy")

      assert get_structured["status"] == "ok"
      assert get_structured["item"]["id"] == request.id
      assert_debug_fields_present(get_structured["item"]["debug"], :get)
      assert_response_body_omits_adversarial_debug_values(get_body)
      assert_no_wire_leaks(Jason.decode!(get_body), raw_token, adversarial_forbidden_strings())
      assert :ok = Redaction.assert_mcp_output_safe!(get_result)
    end

    test "tools call lists audit logs with pool and system wire rows", %{
      conn: conn,
      user: user
    } do
      raw_token = enabled_mcp_token!(user)
      pool = pool_fixture(%{slug: "wire-audit-pool", name: "Wire Audit Pool"})

      base_time =
        DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:microsecond)

      {:ok, ip_address} = INET.cast("198.51.100.88")

      pool_event =
        %AuditEvent{
          occurred_at: base_time,
          actor_type: "user",
          actor_user_id: user.id,
          pool_id: pool.id,
          action: "pool.wire_update",
          target_type: "pool",
          target_id: pool.id,
          outcome: "success",
          ip_address: ip_address,
          details: unsafe_audit_details(%{"status" => "pool event"})
        }
        |> Repo.insert!()

      system_event =
        %AuditEvent{
          occurred_at: DateTime.add(base_time, 1, :second),
          actor_type: "system",
          action: "system.wire_rotate",
          target_type: "instance_settings",
          outcome: "success",
          details: %{}
        }
        |> Repo.insert!()

      response =
        call_tool(conn, raw_token, "wire-list-audit-logs", "codex_pooler_list_audit_logs", %{
          "limit" => 2
        })

      {result, text, structured} =
        assert_successful_tool_response(response, "wire-list-audit-logs")

      assert text =~ "2 audit events returned"
      assert text =~ "action=system.wire_rotate"
      assert text =~ "actor=system"
      assert text =~ "target=instance_settings"
      assert text =~ "pool=system"
      assert text =~ "action=pool.wire_update"
      assert text =~ "pool=wire-audit-pool"
      assert text =~ "details=0 safe detail keys"
      assert text =~ "details=4 safe detail keys"

      assert [first_item, second_item] = structured["items"]
      assert first_item["id"] == system_event.id
      assert second_item["id"] == pool_event.id
      assert first_item["pool_slug"] == nil
      assert second_item["pool_slug"] == "wire-audit-pool"
      assert second_item["ip_address"] == "198.51.100.xxx"
      assert second_item["details"]["safe_sentinel"] == "[REDACTED]"

      assert_no_wire_leaks(response, raw_token, unsafe_wire_sentinels())
      assert :ok = Redaction.assert_mcp_output_safe!(result)
    end

    test "tools call lists operators with masked identities and sentinel-safe filters", %{
      conn: conn,
      user: user
    } do
      raw_token = enabled_mcp_token!(user)

      %{user: operator} =
        operator_fixture(user, %{
          "display_name" => "Wire Operator",
          "email" => Redaction.forbidden_sentinel!(:disallowed_email)
        })

      assert {:ok, _settings} = MCP.set_operator_mcp_enabled(operator, true)

      assert {:ok, %{raw_token: operator_raw_token}} =
               MCP.create_operator_token(operator, %{label: "Wire Operator MCP"})

      response =
        call_tool(conn, raw_token, "wire-list-operators", "codex_pooler_list_operators", %{
          "query" => "Wire Operator",
          "limit" => 10
        })

      {result, text, structured} =
        assert_successful_tool_response(response, "wire-list-operators")

      assert text =~ "1 operator metadata records returned; total 1"
      assert text =~ "name=Wire Operator"
      assert text =~ "email=ta***@example.com"
      assert text =~ "mcp=enabled"
      assert text =~ "keys=1"

      assert [presented] = structured["operators"]
      assert presented["id"] == operator.id
      assert presented["display_name"] == "Wire Operator"
      assert presented["email"] == "ta***@example.com"
      assert presented["mcp_enabled"] == true
      assert presented["mcp_key_count"] == 1

      assert_no_wire_leaks(response, raw_token, [operator.email, operator_raw_token])
      assert :ok = Redaction.assert_mcp_output_safe!(result)

      sentinel = Redaction.forbidden_sentinel!(:prompt)

      sentinel_response =
        conn
        |> recycle()
        |> call_tool(raw_token, "wire-list-operators-sentinel", "codex_pooler_list_operators", %{
          "query" => sentinel,
          "status" => sentinel
        })

      {sentinel_result, sentinel_text, sentinel_structured} =
        assert_successful_tool_response(sentinel_response, "wire-list-operators-sentinel")

      assert sentinel_text == "No operator metadata records matched the visible scope"

      assert sentinel_structured["filters"] == %{
               "applied" => %{"query" => %{"applied" => true}, "status" => %{"applied" => true}},
               "count" => 2
             }

      assert_no_wire_leaks(sentinel_response, raw_token, [sentinel])
      assert :ok = Redaction.assert_mcp_output_safe!(sentinel_result)
    end

    test "tools call validates nullable edge shapes over json-rpc", %{conn: conn, user: user} do
      raw_token = enabled_mcp_token!(user)

      cases = [
        {"wire-empty-request-logs", "codex_pooler_list_request_logs",
         %{"limit" => 10, "offset" => 10_000}, "nextOffset"},
        {"wire-empty-audit-logs", "codex_pooler_list_audit_logs",
         %{"limit" => 10, "offset" => 10_000}, "nextOffset"},
        {"wire-missing-operator", "codex_pooler_get_operator",
         %{"selector" => "missing-operator-selector"}, "item"},
        {"wire-missing-invite", "codex_pooler_get_invite",
         %{"selector" => "missing-invite-selector"}, "item"},
        {"wire-missing-quota", "codex_pooler_get_upstream_quota",
         %{"selector" => "missing-quota-selector"}, "item"}
      ]

      for {id, tool_name, arguments, null_field} <- cases do
        response =
          conn
          |> recycle()
          |> call_tool(raw_token, id, tool_name, arguments)

        {result, _text, structured} = assert_successful_tool_response(response, id)
        assert Map.has_key?(structured, null_field)
        assert is_nil(structured[null_field])
        assert :ok = Redaction.assert_mcp_output_safe!(result)
      end
    end
  end

  describe "MCP bearer authentication" do
    test "missing bearer token is rejected after valid protocol negotiation", %{conn: conn} do
      conn =
        conn
        |> json_rpc_conn()
        |> post("/mcp", Jason.encode!(initialize_request()))

      response = json_rpc_error(conn, 401)

      assert response["error"]["code"] == -32_000
      assert response["error"]["message"] == "MCP bearer token is required"
    end

    test "invalid bearer token and Pool API keys do not authenticate MCP", %{conn: conn} do
      enable_global_mcp!()

      for header <- ["Bearer not-an-mcp-token", "Basic dXNlcjpwYXNz", "Token custom-token"] do
        checked_conn =
          conn
          |> recycle()
          |> json_rpc_conn()
          |> put_req_header("authorization", header)
          |> post("/mcp?token=query-token", Jason.encode!(initialize_request()))

        response = json_rpc_error(checked_conn, 401)
        assert response["error"]["message"] == "MCP bearer token is required"
        refute inspect(response) =~ "not-an-mcp-token"
        refute inspect(response) =~ "query-token"
        refute inspect(response) =~ "custom-token"
      end
    end

    test "bearer token value is trimmed while empty bearer stays rejected", %{
      conn: conn,
      user: user
    } do
      raw_token = enabled_mcp_token!(user)

      padded_conn =
        conn
        |> json_rpc_conn()
        |> put_req_header("authorization", "Bearer   #{raw_token}  ")
        |> post("/mcp", Jason.encode!(initialize_request()))

      assert json_response(padded_conn, 200)["result"]["protocolVersion"] == @mcp_version

      empty_conn =
        conn
        |> recycle()
        |> json_rpc_conn()
        |> put_req_header("authorization", "Bearer    ")
        |> post("/mcp", Jason.encode!(initialize_request()))

      response = json_rpc_error(empty_conn, 401)

      assert response["error"]["message"] == "MCP bearer token is required"
      refute inspect(response) =~ raw_token
      refute inspect(response) =~ raw_token_prefix(raw_token)
    end

    test "query cookies custom headers and browser sessions do not authenticate MCP", %{
      user: user
    } do
      raw_token = enabled_mcp_token!(user)

      conn =
        build_conn()
        |> init_test_session(%{})
        |> put_session(:mcp_token, raw_token)
        |> put_req_header("x-mcp-token", raw_token)
        |> json_rpc_conn()
        |> post("/mcp?token=#{URI.encode(raw_token)}", Jason.encode!(initialize_request()))

      response = json_rpc_error(conn, 401)

      assert response["error"]["message"] == "MCP bearer token is required"
      refute inspect(response) =~ raw_token
      refute inspect(response) =~ raw_token_prefix(raw_token)
    end

    test "global MCP gate disables otherwise valid tokens immediately", %{conn: conn, user: user} do
      raw_token = mcp_token!(user)
      assert {:ok, _settings} = MCP.set_operator_mcp_enabled(user, true)

      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post("/mcp", Jason.encode!(initialize_request()))

      response = json_rpc_error(conn, 403)

      assert response["error"]["message"] == "MCP service is disabled"
      refute inspect(response) =~ raw_token
      refute inspect(response) =~ raw_token_prefix(raw_token)
    end

    test "per-operator MCP gate disables otherwise valid tokens immediately", %{
      conn: conn,
      user: user
    } do
      raw_token = mcp_token!(user)
      enable_global_mcp!()

      conn =
        conn
        |> authenticated_json_rpc_conn(raw_token)
        |> post("/mcp", Jason.encode!(initialize_request()))

      response = json_rpc_error(conn, 403)

      assert response["error"]["message"] == "MCP is disabled for this operator"
      refute inspect(response) =~ raw_token
      refute inspect(response) =~ raw_token_prefix(raw_token)
    end

    test "disabled deleted and password-change-required operators are denied", %{
      conn: conn,
      user: user
    } do
      raw_token = enabled_mcp_token!(user)

      for {changes, message} <- [
            {%{password_change_required: true}, "MCP operator must complete password change"},
            {%{password_change_required: false, status: "disabled"}, "MCP operator is disabled"},
            {%{status: "active", deleted_at: DateTime.utc_now()}, "MCP operator is deleted"}
          ] do
        user |> Ecto.Changeset.change(changes) |> Repo.update!()

        checked_conn =
          conn
          |> recycle()
          |> authenticated_json_rpc_conn(raw_token)
          |> post("/mcp", Jason.encode!(initialize_request()))

        response = json_rpc_error(checked_conn, 403)

        assert response["error"]["message"] == message
        refute inspect(response) =~ raw_token
        refute inspect(response) =~ raw_token_prefix(raw_token)
      end
    end
  end

  defp assert_successful_tool_body_response(body, id) do
    response = Jason.decode!(body)
    {result, text, structured} = assert_successful_tool_response(response, id)
    assert String.contains?(body, "structuredContent")
    {result, text, structured}
  end

  defp failed_debug_request_fixture(pool, api_key, assignment, attrs) do
    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-log-debug-contract",
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        status: "failed",
        usage_status: "usage_unknown",
        correlation_id: Map.fetch!(attrs, :correlation_id),
        response_status_code: 499,
        retry_count: 1,
        request_metadata:
          Map.merge(
            %{
              "codex_session_id" => Map.fetch!(attrs, :codex_session_id),
              "codex_session_key" => Map.fetch!(attrs, :codex_session_key),
              "body" => %{"input" => "raw debug prompt"}
            },
            Map.get(attrs, :request_metadata, %{})
          )
      })
      |> Ecto.Changeset.change(last_error_code: Map.fetch!(attrs, :request_error))
      |> Repo.update!()

    attempt =
      request
      |> attempt_fixture(assignment, %{
        status: "failed",
        retryable: true,
        upstream_status_code: 499,
        usage_status: "usage_unknown"
      })
      |> Ecto.Changeset.change(%{
        latency_ms: 321,
        network_error_code: Map.fetch!(attrs, :attempt_error),
        error_message: Map.fetch!(attrs, :error_message),
        response_metadata:
          Map.merge(
            %{"websocket_frame" => "raw debug websocket frame"},
            Map.get(attrs, :response_metadata, %{})
          )
      })
      |> Repo.update!()

    %{request: request, attempt: attempt}
  end

  defp debug_session_fixture(pool, api_key, assignment, session_key) do
    now = debug_timestamp()

    %CodexSession{
      pool_id: pool.id,
      api_key_id: api_key.id,
      session_key: session_key,
      conversation_key: "conversation-#{session_key}",
      pool_upstream_assignment_id: assignment.id,
      status: "active",
      owner_instance_id: "test-instance",
      owner_lease_token: Ecto.UUID.generate(),
      owner_lease_expires_at: DateTime.add(now, 60, :second),
      last_heartbeat_at: now,
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp debug_turn_fixture(request, attrs) do
    now = debug_timestamp()

    %CodexTurn{
      codex_session_id: Map.fetch!(attrs, :session).id,
      request_id: request.id,
      turn_sequence: Map.fetch!(attrs, :turn_sequence),
      transport_kind: request.transport,
      status: Map.fetch!(attrs, :status),
      error_code: Map.get(attrs, :error_code),
      first_visible_output_at: now,
      final_attempt_id: Map.get(attrs, :final_attempt_id),
      started_at: now,
      completed_at: now,
      created_at: now,
      updated_at: DateTime.add(now, 1, :second)
    }
    |> Repo.insert!()
  end

  defp debug_timestamp, do: ~U[2026-05-26 00:00:00.000000Z]

  defp adversarial_debug_metadata do
    %{
      "raw_headers" => %{
        "authorization" => "Authorization: Bearer sk-example-secret",
        "cookie" => "Cookie: session=secret-cookie"
      },
      "request_body" => "raw prompt: explain private data",
      "raw_idempotency_key" => "idempotency_key=idem-secret-123",
      "websocket_frame" => ~s({"type":"response.output_text.delta","delta":"secret frame"}),
      "safe_debug_marker" => "debug metadata present"
    }
  end

  defp assert_debug_fields_present(debug, :list) do
    assert is_map(debug)
    assert is_map(debug["continuity"])
    assert is_map(debug["failure"])
    assert is_map(debug["attempt"])
    assert debug["failure"]["error_code"] == "turn_owner_drained"
    assert debug["attempt"]["attempt_count"] == 1
  end

  defp assert_debug_fields_present(debug, :get) do
    assert is_map(debug)
    assert is_map(debug["continuity"])
    assert is_map(debug["terminal_state"])
    assert is_map(debug["turn"])
    assert [_attempt] = debug["attempts"]
    assert debug["terminal_state"]["state"] == "terminal"
  end

  defp assert_response_body_omits_adversarial_debug_values(body) do
    response = Jason.decode!(body)
    result = response["result"]
    assert [%{"type" => "text", "text" => text}] = result["content"]
    structured = result["structuredContent"]

    refute text =~ Jason.encode!(structured)

    for forbidden <- adversarial_forbidden_strings() do
      refute text =~ forbidden
      refute Jason.encode!(structured) =~ forbidden
      refute body =~ forbidden
      refute inspect(response) =~ forbidden
    end
  end

  defp adversarial_forbidden_strings do
    [
      "Authorization: Bearer sk-example-secret",
      "Cookie: session=secret-cookie",
      "raw prompt: explain private data",
      "idempotency_key=idem-secret-123",
      ~s({"type":"response.output_text.delta","delta":"secret frame"})
    ]
  end

  defp call_tool(conn, raw_token, id, name, arguments) do
    conn
    |> authenticated_json_rpc_conn(raw_token)
    |> post(
      "/mcp",
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      })
    )
    |> json_response(200)
  end

  defp assert_successful_tool_response(response, id) do
    assert response["jsonrpc"] == "2.0"
    assert response["id"] == id
    result = response["result"]
    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert is_binary(text)
    assert is_map(result["structuredContent"])
    {result, text, result["structuredContent"]}
  end

  defp assert_no_wire_leaks(response, raw_token, extra_values) do
    inspected = inspect(response)

    refute inspected =~ raw_token
    refute inspected =~ raw_token_prefix(raw_token)

    for value <- List.wrap(extra_values), is_binary(value), value != "" do
      refute inspected =~ value
    end
  end

  defp attempt_with_latency(request, assignment, latency_ms) do
    request
    |> attempt_fixture(assignment)
    |> Ecto.Changeset.change(latency_ms: latency_ms)
    |> Repo.update!()
  end

  defp unsafe_log_metadata(extra) do
    Map.merge(
      %{
        "prompt" => Redaction.forbidden_sentinel!(:prompt),
        "raw_headers" => %{"authorization" => Redaction.forbidden_sentinel!(:raw_headers)},
        "request_body" => Redaction.forbidden_sentinel!(:request_body),
        "response_body" => Redaction.forbidden_sentinel!(:response_body),
        "raw_email_value" => "wire.request@example.com",
        "raw_ip_value" => "192.0.2.88",
        "nested" => %{
          "count" => 2,
          "safe_sentinel" => Redaction.forbidden_sentinel!(:response_body)
        }
      },
      extra
    )
  end

  defp unsafe_audit_details(extra) do
    Map.merge(
      %{
        "before" => %{"email" => Redaction.forbidden_sentinel!(:audit_before_blob)},
        "after" => %{"email" => Redaction.forbidden_sentinel!(:audit_after_blob)},
        "safe_sentinel" => Redaction.forbidden_sentinel!(:prompt),
        "request_body" => Redaction.forbidden_sentinel!(:request_body),
        "response_body" => Redaction.forbidden_sentinel!(:response_body),
        "contact" => "wire.audit@example.com",
        "client_ip" => "192.0.2.99",
        "raw_headers" => %{"cookie" => Redaction.forbidden_sentinel!(:cookies)}
      },
      extra
    )
  end

  defp unsafe_wire_sentinels do
    [
      Redaction.forbidden_sentinel!(:prompt),
      Redaction.forbidden_sentinel!(:raw_headers),
      Redaction.forbidden_sentinel!(:request_body),
      Redaction.forbidden_sentinel!(:response_body),
      Redaction.forbidden_sentinel!(:audit_before_blob),
      Redaction.forbidden_sentinel!(:audit_after_blob),
      Redaction.forbidden_sentinel!(:cookies),
      "wire.request@example.com",
      "wire.upstream@example.com",
      "wire.audit@example.com",
      "192.0.2.88",
      "192.0.2.99"
    ]
  end

  defp authenticated_json_rpc_conn(conn, raw_token) do
    conn
    |> json_rpc_conn()
    |> put_req_header("authorization", "Bearer #{raw_token}")
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

  defp enabled_mcp_token!(user) do
    enable_global_mcp!()
    assert {:ok, _settings} = MCP.set_operator_mcp_enabled(user, true)
    mcp_token!(user)
  end

  defp mcp_token!(user) do
    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(user, %{label: "Controller MCP"})

    raw_token
  end

  defp enable_global_mcp! do
    settings = InstanceSettings.ensure_singleton!()
    assert {:ok, updated} = InstanceSettings.update(settings, %{"mcp" => %{"enabled" => true}})
    updated
  end

  defp raw_token_prefix(raw_token) do
    raw_token |> String.split("-") |> Enum.take(3) |> Enum.join("-")
  end

  defp smoke_arguments(%{"inputSchema" => %{"required" => required}}) do
    cond do
      "selector" in required -> %{"selector" => "no-such-mcp-smoke-selector"}
      "id" in required -> %{"id" => "00000000-0000-0000-0000-000000000000"}
      true -> %{}
    end
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
end
