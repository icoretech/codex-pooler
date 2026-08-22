defmodule CodexPooler.MCP.ToolDispatchTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [primary_quota_window_attrs: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP

  alias CodexPooler.MCP.{
    OperatorMCPKey,
    OperatorMCPSettings,
    ProtocolVersions,
    Redaction,
    ToolDispatch
  }

  alias CodexPooler.MCP.Tools.{LogMetadata, OperatorMetadata, PoolMetadata, QuotaMetadata}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @row_text_tool_names [
    "codex_pooler_list_pools",
    "codex_pooler_get_pool",
    "codex_pooler_list_upstreams",
    "codex_pooler_get_upstream",
    "codex_pooler_list_pool_api_keys",
    "codex_pooler_get_pool_api_key",
    "codex_pooler_list_upstream_quotas",
    "codex_pooler_get_upstream_quota",
    "codex_pooler_list_operators",
    "codex_pooler_get_operator",
    "codex_pooler_list_invites",
    "codex_pooler_get_invite",
    "codex_pooler_list_request_logs",
    "codex_pooler_get_request_log",
    "codex_pooler_list_audit_logs",
    "codex_pooler_get_audit_log"
  ]

  setup do
    reset_bootstrap_state_fixture!()
    Repo.delete_all(OperatorMCPKey)
    Repo.delete_all(OperatorMCPSettings)
    Repo.delete_all(CodexPooler.InstanceSettings.Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn -> InstanceSettings.reset_cache_for_test() end)

    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})

    user =
      user
      |> Ecto.Changeset.change(
        display_name: "MCP Operator",
        password_change_required: false,
        email: "operator.status@example.com"
      )
      |> Repo.update!()

    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _updated} =
             InstanceSettings.update_system_settings(settings, %{"mcp" => %{"enabled" => true}})

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(user, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(user, %{label: "Dispatch MCP"})

    assert {:ok, auth} = MCP.authenticate_token(raw_token)

    %{auth: auth, raw_token: raw_token, user: user}
  end

  test "dispatches service status with MCP content and structuredContent", %{
    auth: auth,
    raw_token: raw_token,
    user: user
  } do
    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_mcp_service_status", %{}, %{auth: auth})

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "MCP service enabled"
    refute String.contains?(text, "\n- ")
    refute text =~ user.email

    structured = result["structuredContent"]
    assert structured["globalGate"] == %{"enabled" => true}
    assert structured["accountGate"] == %{"enabled" => true}
    assert structured["actor"]["id"] == user.id
    assert structured["actor"]["display_name"] == "MCP Operator"
    assert structured["actor"]["email"] == "op***@example.com"
    assert structured["protocolVersion"] == ProtocolVersions.current()
    assert structured["supportedProtocolVersions"] == ProtocolVersions.supported()
    assert structured["supportedToolCount"] == 17

    refute inspect(result) =~ raw_token
    refute inspect(result) =~ auth.key.key_prefix
    refute inspect(result) =~ Base.encode16(auth.key.key_hash)
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "get metadata handlers report malformed direct arguments separately from auth failures", %{
    auth: auth
  } do
    selector_handlers = [
      &PoolMetadata.get_pool/2,
      &PoolMetadata.get_upstream/2,
      &PoolMetadata.get_pool_api_key/2,
      &OperatorMetadata.get_operator/2,
      &OperatorMetadata.get_invite/2,
      &QuotaMetadata.get_upstream_quota/2
    ]

    for handler <- selector_handlers do
      assert {:error, %{code: :invalid_arguments, message: "selector is required"}} =
               handler.(%{}, %{auth: auth})

      assert {:error, %{code: :invalid_arguments, message: "selector is required"}} =
               handler.(%{"selector" => 123}, %{auth: auth})
    end

    id_handlers = [&LogMetadata.get_request_log/2, &LogMetadata.get_audit_log/2]

    for handler <- id_handlers do
      assert {:error, %{code: :invalid_arguments, message: "id is required"}} =
               handler.(%{}, %{auth: auth})

      assert {:error, %{code: :invalid_arguments, message: "id is required"}} =
               handler.(%{"id" => 123}, %{auth: auth})
    end

    assert {:error,
            %{code: :tool_execution_failed, message: "MCP authenticated actor is unavailable"}} =
             PoolMetadata.get_pool(%{"selector" => "missing"}, %{})

    assert {:error,
            %{code: :tool_execution_failed, message: "MCP authenticated actor is unavailable"}} =
             LogMetadata.get_request_log(%{"id" => Ecto.UUID.generate()}, %{})
  end

  test "all metadata list/get tools return one readable text item and safe structured content", %{
    auth: auth,
    user: user
  } do
    pool = pool_fixture(%{name: "MCP dispatch pool", slug: "mcp-dispatch-pool"})

    %{api_key: api_key, raw_key: raw_key} =
      active_api_key_fixture(pool, %{display_name: "MCP dispatch API key"})

    %{assignment: assignment, identity: upstream_identity} =
      active_upstream_assignment_fixture(pool, %{account_label: "MCP dispatch upstream"})

    %{user: operator} =
      operator_fixture(auth.operator, %{
        "display_name" => "MCP dispatch operator",
        "email" => "mcp-dispatch-operator@example.com"
      })

    scope = Scope.for_user(user, Accounts.roles_for_user(user))

    assert {:ok, %{invite: invite}} =
             Access.create_invite(scope, pool, %{invited_email: "mcp-dispatch-invite@example.com"})

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-mcp-dispatch",
        endpoint: "/backend-api/codex/responses",
        transport: "http_sse",
        status: "succeeded",
        usage_status: "usage_known",
        correlation_id: "mcp-dispatch-request",
        response_status_code: 202,
        retry_count: 2,
        upstream_account_label: upstream_identity.account_label,
        upstream_account_email: "upstream.mcp-dispatch@example.com"
      })

    _attempt = attempt_fixture(request, assignment, %{latency_ms: 321})

    assert {:ok, [_quota_window]} =
             QuotaWindows.upsert_quota_windows(upstream_identity, [
               primary_quota_window_attrs(%{
                 active_limit: 100,
                 credits: 42,
                 reset_at: DateTime.add(DateTime.utc_now(), 900, :second),
                 used_percent: Decimal.new("58.0")
               })
             ])

    event =
      %AuditEvent{
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        actor_type: "user",
        actor_user_id: user.id,
        pool_id: pool.id,
        request_id: request.id,
        action: "operator.update",
        target_type: "user",
        target_id: user.id,
        outcome: "success",
        correlation_id: "mcp-dispatch-audit-correlation",
        details: %{"status" => "changed"}
      }
      |> Repo.insert!()

    cases = [
      {
        "codex_pooler_list_pools",
        %{"query" => pool.slug, "limit" => 10},
        [
          "name=MCP dispatch pool",
          "slug=#{pool.slug}",
          "status=active",
          "upstreams=1",
          "api_keys=1"
        ]
      },
      {
        "codex_pooler_get_pool",
        %{"selector" => pool.slug},
        ["id=#{pool.id}", "name=MCP dispatch pool", "slug=#{pool.slug}", "status=active"]
      },
      {
        "codex_pooler_list_upstreams",
        %{"pool_selector" => pool.slug, "limit" => 10},
        ["label=MCP dispatch upstream", "status=active", "account=", "assignments="]
      },
      {
        "codex_pooler_get_upstream",
        %{"selector" => upstream_identity.id},
        ["id=#{upstream_identity.id}", "status=active", "account=", "assignments="]
      },
      {
        "codex_pooler_list_pool_api_keys",
        %{"pool_selector" => pool.slug, "limit" => 10},
        [
          "name=MCP dispatch API key",
          "status=active",
          "prefix=#{api_key.key_prefix}",
          "pool=#{pool.slug}"
        ]
      },
      {
        "codex_pooler_get_pool_api_key",
        %{"selector" => api_key.key_prefix},
        [
          "id=#{api_key.id}",
          "name=MCP dispatch API key",
          "status=active",
          "prefix=#{api_key.key_prefix}"
        ]
      },
      {
        "codex_pooler_list_upstream_quotas",
        %{"pool_id" => pool.id, "limit" => 10},
        [
          "account MCP dispatch upstream",
          "status active",
          "account_primary",
          "42/100 remaining",
          "routing usable"
        ]
      },
      {
        "codex_pooler_get_upstream_quota",
        %{"selector" => upstream_identity.id},
        [
          "1 upstream quota metadata record returned",
          "account MCP dispatch upstream",
          "account_primary",
          "42/100 remaining"
        ]
      },
      {
        "codex_pooler_list_operators",
        %{"query" => "MCP dispatch operator", "limit" => 10},
        ["name=MCP dispatch operator", "status=active", "email=mc***@example.com", "mcp="]
      },
      {
        "codex_pooler_get_operator",
        %{"selector" => operator.id},
        ["name=MCP dispatch operator", "status=active", "email=mc***@example.com", "mcp="]
      },
      {
        "codex_pooler_list_invites",
        %{"email" => "mcp-dispatch-invite@example.com", "limit" => 10},
        ["status=active", "recipient=mc***@example.com", "pool=#{pool.slug}"]
      },
      {
        "codex_pooler_get_invite",
        %{"selector" => invite.id},
        ["status=active", "recipient=mc***@example.com", "pool=#{pool.slug}"]
      },
      {
        "codex_pooler_list_request_logs",
        %{
          "pool_id" => pool.id,
          "status" => "succeeded",
          "model" => "gpt-mcp-dispatch",
          "limit" => 10
        },
        ["pool=mcp-dispatch-pool", "status=succeeded", "model=gpt-mcp-dispatch", "retries=2"]
      },
      {
        "codex_pooler_get_request_log",
        %{"id" => request.id},
        [
          "pool=mcp-dispatch-pool",
          "status=succeeded",
          "model=gpt-mcp-dispatch",
          "retries=2",
          "response=202"
        ]
      },
      {
        "codex_pooler_list_audit_logs",
        %{"pool_id" => pool.id, "action" => "operator.update", "limit" => 10},
        [
          "action=operator.update",
          "outcome=success",
          "actor=user",
          "target=user",
          "pool=mcp-dispatch-pool"
        ]
      },
      {
        "codex_pooler_get_audit_log",
        %{"id" => event.id},
        [
          "action=operator.update",
          "outcome=success",
          "actor=user",
          "target=user",
          "pool=mcp-dispatch-pool"
        ]
      }
    ]

    assert Enum.map(cases, &elem(&1, 0)) == @row_text_tool_names

    for {tool_name, arguments, expectations} <- cases do
      assert {:ok, result} = ToolDispatch.call(tool_name, arguments, %{auth: auth})

      assert result["isError"] == false
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert String.trim(text) != ""
      assert String.contains?(text, "\n- ")
      refute text == Jason.encode!(result["structuredContent"])
      refute String.contains?(text, Jason.encode!(result["structuredContent"]))
      refute inspect(result) =~ raw_key

      for expectation <- expectations do
        assert text =~ expectation
      end

      assert :ok = Redaction.assert_mcp_output_safe!(result)
    end
  end

  test "input validation failures are CallToolResult-style errors, not JSON-RPC errors", %{
    auth: auth
  } do
    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_get_mcp_service_status", %{"unexpected" => true}, %{
               auth: auth
             })

    assert result["isError"] == true
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text == "invalid_arguments: Invalid tool arguments"
    refute Map.has_key?(result, "structuredContent")

    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "Pool API-key list tool returns metadata-only CallToolResult", %{auth: auth} do
    assert {:ok, result} =
             ToolDispatch.call("codex_pooler_list_pool_api_keys", %{}, %{auth: auth})

    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "Pool API key metadata records"
    assert result["structuredContent"]["status"] == "ok"
    refute inspect(result) =~ "raw_pool_api_key"
    refute inspect(result) =~ "key_hash"
    assert :ok = Redaction.assert_mcp_output_safe!(result)
  end

  test "unknown tools remain dispatch errors for the JSON-RPC layer", %{auth: auth} do
    assert {:error, %{code: :tool_not_found, message: "MCP tool was not found"}} =
             ToolDispatch.call("codex_pooler_missing_tool", %{}, %{auth: auth})
  end

  test "handler exceptions return a safe error and log sanitized operator context", %{
    auth: auth
  } do
    crashing_tool = %{
      name: "codex_pooler_crashing_status",
      title: "Crashing status",
      description:
        "Use when testing. Raises while dispatching. Never returns secrets. Filters/limits: none.",
      input_schema: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      output_schema: %{
        "type" => "object",
        "required" => ["ok"],
        "properties" => %{"ok" => %{"type" => "boolean"}},
        "additionalProperties" => false
      },
      annotations: %{
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false
      },
      handler: {__MODULE__, :crashing_handler}
    }

    log =
      capture_log([level: :warning], fn ->
        assert {:ok, result} = ToolDispatch.call(crashing_tool, %{}, %{auth: auth})
        assert result["isError"] == true

        assert [%{"type" => "text", "text" => text}] = result["content"]
        assert text == "tool_execution_failed: MCP tool execution failed"
        refute Map.has_key?(result, "structuredContent")
      end)

    assert log =~ "mcp tool handler failed"
    assert log =~ "tool=codex_pooler_crashing_status"
    assert log =~ "handler=#{inspect(__MODULE__)}.crashing_handler"
    assert log =~ "exception=RuntimeError"
    assert log =~ "reason=handler_exception"
    refute log =~ "PRIVATE_CONTEXT"
  end

  test "output schema validation protects handler regressions", %{auth: auth} do
    bad_tool = %{
      name: "codex_pooler_bad_status",
      title: "Bad status",
      description:
        "Use when testing. Returns invalid output. Never returns secrets. Filters/limits: none.",
      input_schema: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      output_schema: %{
        "type" => "object",
        "required" => ["ok"],
        "properties" => %{"ok" => %{"type" => "boolean"}},
        "additionalProperties" => false
      },
      annotations: %{
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false
      },
      handler: {__MODULE__, :bad_handler}
    }

    assert {:ok, result} = ToolDispatch.call(bad_tool, %{}, %{auth: auth})
    assert result["isError"] == true
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text == "invalid_tool_output: MCP tool output failed schema validation"
    refute Map.has_key?(result, "structuredContent")
  end

  test "output schema validation rejects present null values unless explicitly nullable", %{
    auth: auth
  } do
    bad_tool = %{
      name: "codex_pooler_bad_nullable_status",
      title: "Bad nullable status",
      description:
        "Use when testing. Returns invalid null output. Never returns secrets. Filters/limits: none.",
      input_schema: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      },
      output_schema: %{
        "type" => "object",
        "required" => ["item"],
        "properties" => %{"item" => %{"type" => "object"}},
        "additionalProperties" => false
      },
      annotations: %{
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => false
      },
      handler: {__MODULE__, :null_item_handler}
    }

    assert {:ok, result} = ToolDispatch.call(bad_tool, %{}, %{auth: auth})
    assert result["isError"] == true
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text == "invalid_tool_output: MCP tool output failed schema validation"
    refute Map.has_key?(result, "structuredContent")

    nullable_tool =
      put_in(bad_tool.output_schema["properties"]["item"]["type"], ["object", "null"])

    assert {:ok, nullable_result} = ToolDispatch.call(nullable_tool, %{}, %{auth: auth})
    assert nullable_result["isError"] == false
    assert nullable_result["structuredContent"] == %{"item" => nil}
  end

  @tag :mcp_schema_edges
  test "schema validation covers MCP catalog null edge shapes", %{auth: auth} do
    cases = [
      {"codex_pooler_list_request_logs", %{"limit" => 10}, "nextOffset"},
      {"codex_pooler_list_audit_logs", %{"limit" => 10}, "nextOffset"},
      {"codex_pooler_get_request_log", %{"id" => Ecto.UUID.generate()}, "item"},
      {"codex_pooler_get_operator", %{"selector" => "missing-operator-selector"}, "item"},
      {"codex_pooler_get_invite", %{"selector" => "missing-invite-selector"}, "item"},
      {"codex_pooler_get_upstream_quota", %{"selector" => "missing-quota-selector"}, "item"}
    ]

    for {tool_name, arguments, null_field} <- cases do
      assert {:ok, result} = ToolDispatch.call(tool_name, arguments, %{auth: auth})
      assert result["isError"] == false
      assert Map.has_key?(result["structuredContent"], null_field)
      assert is_nil(result["structuredContent"][null_field])
      assert :ok = Redaction.assert_mcp_output_safe!(result)
    end
  end

  def bad_handler(_arguments, _context), do: {:ok, %{"missing" => true}, "bad output"}
  def null_item_handler(_arguments, _context), do: {:ok, %{"item" => nil}, "nullable output"}
  def crashing_handler(_arguments, _context), do: raise("PRIVATE_CONTEXT")
end
