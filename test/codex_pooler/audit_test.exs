defmodule CodexPooler.AuditTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Audit
  alias CodexPooler.Repo

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  setup do
    reset_bootstrap_state_fixture!()
    Repo.delete_all(CodexPooler.Audit.AuditEvent)
    :ok
  end

  test "admin action options include pool, api key, MCP, and alert management events" do
    actions = Audit.supported_actions()

    assert "pool.create" in actions
    assert "pool.update" in actions
    assert "pool.status_update" in actions
    assert "pool.routing_update" in actions
    assert "pool.delete" in actions
    assert "invite.create" in actions
    assert "invite.revoke" in actions
    assert "upstream_account.import" in actions
    assert "upstream_account.pause" in actions
    assert "upstream_account.reactivate" in actions
    assert "upstream_account.delete" in actions
    assert "api_key.create" in actions
    assert "api_key.update" in actions
    assert "api_key.pause" in actions
    assert "api_key.resume" in actions
    assert "api_key.revoke" in actions
    assert "api_key.rotate" in actions
    assert "api_key.delete" in actions
    assert "mcp.operator_enable" in actions
    assert "mcp.operator_disable" in actions
    assert "mcp.token_create" in actions
    assert "mcp.token_update" in actions
    assert "mcp.token_delete" in actions
    assert "alert_rule.create" in actions
    assert "alert_rule.update" in actions
    assert "alert_rule.enable" in actions
    assert "alert_rule.disable" in actions
    assert "alert_rule.delete" in actions
    assert "alert_channel.create" in actions
    assert "alert_channel.update" in actions
    assert "alert_channel.enable" in actions
    assert "alert_channel.disable" in actions
    assert "alert_channel.delete" in actions
    assert "alert_incident.acknowledge" in actions
    assert "alert_incident.resolve" in actions
  end

  test "audit event details redact credentials and prompt content" do
    pool = pool_fixture()

    assert {:ok, event} =
             Audit.record_system_event(%{
               pool_id: pool.id,
               action: "access.denied",
               target_type: "api_key",
               outcome: "failure",
               correlation_id: "corr-audit-redaction",
               details: %{
                 "authorization" => "Bearer token-value",
                 "api_key" => "sk-cxp-abcdef123456-secret",
                 "upstream_token" => "upstream-token",
                 "cookie" => "a=b",
                 "prompt" => "raw prompt",
                 "safe" => "visible"
               }
             })

    stored = Repo.get!(CodexPooler.Audit.AuditEvent, event.id)
    assert stored.details["authorization"] == "[REDACTED]"
    assert stored.details["api_key"] == "[REDACTED]"
    assert stored.details["upstream_token"] == "[REDACTED]"
    assert stored.details["cookie"] == "[REDACTED]"
    assert stored.details["prompt"] == "[REDACTED]"
    assert stored.details["safe"] == "visible"

    assert %{items: [listed]} = Audit.list_events(pool)
    assert listed.details["authorization"] == "[REDACTED]"
    refute inspect(listed) =~ "raw prompt"
    refute inspect(listed) =~ "token-value"
  end

  test "lists global and pool audit events with structured filters" do
    first_pool = pool_fixture(%{slug: "audit-first", name: "Audit First"})
    second_pool = pool_fixture(%{slug: "audit-second", name: "Audit Second"})
    %{user: user} = bootstrap_owner_fixture(%{"email" => "audit.actor@example.com"})

    assert {:ok, global_event} =
             Audit.record_user_event(user, %{
               action: "operator.update",
               target_type: "user",
               target_id: user.id,
               correlation_id: "global-correlation",
               details: %{"safe" => "visible"}
             })

    assert {:ok, first_event} =
             Audit.record_system_event(%{
               pool_id: first_pool.id,
               action: "access.denied",
               target_type: "api_key",
               outcome: "failure",
               correlation_id: "first-correlation",
               details: %{"status" => "failed"}
             })

    assert {:ok, second_event} =
             Audit.record_system_event(%{
               pool_id: second_pool.id,
               action: "upstream.quota_exhausted",
               target_type: "upstream_identity",
               correlation_id: "second-correlation",
               details: %{}
             })

    assert %{items: all_items, total: total} = Audit.list_events(nil)
    assert total == 4
    assert Enum.any?(all_items, &(&1.id == global_event.id))
    assert Enum.any?(all_items, &(&1.id == first_event.id))
    assert Enum.any?(all_items, &(&1.id == second_event.id))

    assert %{items: [listed_first]} = Audit.list_events(first_pool)
    assert listed_first.id == first_event.id
    assert listed_first.pool_name == "Audit First"
    assert listed_first.pool_slug == "audit-first"

    assert %{items: global_items} = Audit.list_events(nil, filters: [actor: "audit.actor"])
    listed_global = Enum.find(global_items, &(&1.id == global_event.id))
    assert listed_global.id == global_event.id

    assert %{items: [listed_failure]} = Audit.list_events(nil, filters: [outcome: "failure"])
    assert listed_failure.id == first_event.id

    assert %{items: [listed_correlation]} =
             Audit.list_events(nil, filters: [request: "second-correlation"])

    assert listed_correlation.id == second_event.id
  end

  test "does not record runtime request or file events in audit_events" do
    pool = pool_fixture(%{slug: "request-audit", name: "Request Audit"})

    assert {:error, :runtime_events_not_recorded} =
             Audit.record_system_event(%{
               pool_id: pool.id,
               action: "request.finalized",
               target_type: "request",
               target_id: Ecto.UUID.generate(),
               outcome: "failure",
               details: %{"status" => "failed"}
             })

    assert {:error, :runtime_events_not_recorded} =
             Audit.record_system_event(%{
               pool_id: pool.id,
               action: "file.created",
               target_type: "codex_file",
               target_id: Ecto.UUID.generate(),
               details: %{"status" => "pending_upload"}
             })

    assert %{items: []} = Audit.list_events(pool)
  end
end
