defmodule CodexPooler.Alerts.AlertAuditTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Repo

  test "records rule lifecycle audit rows at the alert context boundary" do
    {scope, pool} = owner_scope_and_pool()

    assert {:ok, rule} =
             Alerts.create_rule(scope, rule_attrs(pool, %{display_name: "Audited rule"}))

    assert create_audit = audit_event("alert_rule.create", rule.id)
    assert create_audit.actor_user_id == scope.user.id
    assert create_audit.pool_id == pool.id
    assert create_audit.target_type == "alert_rule"
    assert create_audit.details["alert_rule_id"] == rule.id
    assert create_audit.details["pool_id"] == pool.id
    assert create_audit.details["display_name"] == "Audited rule"
    assert create_audit.details["rule_kind"] == "pool_no_usable_assignments"
    assert create_audit.details["severity"] == "critical"

    assert {:ok, updated_rule} =
             Alerts.update_rule(scope, rule.id, %{
               display_name: "Audited rule updated",
               cooldown_minutes: 60,
               metadata: %{"prompt" => "must not persist in audit"}
             })

    assert update_audit = audit_event("alert_rule.update", rule.id)
    assert update_audit.details["display_name"] == "Audited rule updated"
    assert "cooldown_minutes" in update_audit.details["changed_fields"]
    assert "display_name" in update_audit.details["changed_fields"]
    assert "metadata" in update_audit.details["changed_fields"]
    refute inspect(update_audit.details) =~ "must not persist in audit"

    assert {:ok, disabled_rule} = Alerts.update_rule(scope, updated_rule.id, %{state: "disabled"})
    assert disable_audit = audit_event("alert_rule.disable", rule.id)
    assert disable_audit.details["previous_state"] == "active"
    assert disable_audit.details["state"] == "disabled"

    assert {:ok, enabled_rule} = Alerts.update_rule(scope, disabled_rule.id, %{state: "active"})
    assert enable_audit = audit_event("alert_rule.enable", rule.id)
    assert enable_audit.details["previous_state"] == "disabled"
    assert enable_audit.details["state"] == "active"

    assert {:ok, deleted_rule} = Alerts.delete_rule(scope, enabled_rule.id)
    assert deleted_rule.id == rule.id
    assert delete_audit = audit_event("alert_rule.delete", rule.id)
    assert delete_audit.pool_id == pool.id
    assert delete_audit.details["state"] == "active"
  end

  test "records channel lifecycle audit rows without endpoint or signing-secret leakage" do
    {scope, _pool} = owner_scope_and_pool()
    raw_endpoint = "https://hooks.example.com/alerts/team-secret?token=query-secret"
    signing_secret = "whsec_audit_hidden_value"

    assert {:ok, channel} =
             Alerts.create_channel(scope, %{
               channel_type: "webhook",
               display_name: "Audited webhook",
               state: "active",
               endpoint_url: raw_endpoint,
               webhook_signing_secret: signing_secret,
               metadata: %{"authorization" => "Bearer channel-token"}
             })

    assert create_audit = audit_event("alert_channel.create", channel.id)
    assert create_audit.actor_user_id == scope.user.id
    assert create_audit.pool_id == nil
    assert create_audit.target_type == "alert_channel"
    assert create_audit.details["alert_channel_id"] == channel.id
    assert create_audit.details["channel_type"] == "webhook"
    assert create_audit.details["endpoint_host"] == "hooks.example.com"
    assert create_audit.details["webhook_signing_secret_configured"] == true
    refute Map.has_key?(create_audit.details, "webhook_signing_secret_key_version")

    assert {:ok, updated_channel} =
             Alerts.update_channel(scope, channel.id, %{
               display_name: "Audited webhook updated",
               metadata: %{"token" => "metadata-secret"}
             })

    assert update_audit = audit_event("alert_channel.update", channel.id)
    assert update_audit.details["display_name"] == "Audited webhook updated"
    assert "display_name" in update_audit.details["changed_fields"]
    assert "metadata" in update_audit.details["changed_fields"]

    assert {:ok, disabled_channel} =
             Alerts.update_channel(scope, updated_channel.id, %{state: "disabled"})

    assert disable_audit = audit_event("alert_channel.disable", channel.id)
    assert disable_audit.details["previous_state"] == "active"
    assert disable_audit.details["state"] == "disabled"

    assert {:ok, active_channel} =
             Alerts.update_channel(scope, disabled_channel.id, %{state: "active"})

    assert enable_audit = audit_event("alert_channel.enable", channel.id)
    assert enable_audit.details["previous_state"] == "disabled"
    assert enable_audit.details["state"] == "active"

    assert {:ok, deleted_channel} = Alerts.delete_channel(scope, active_channel.id)
    assert deleted_channel.id == channel.id
    assert delete_audit = audit_event("alert_channel.delete", channel.id)
    assert delete_audit.details["state"] == "active"

    channel_audits = audit_events_for_target(channel.id)
    refute inspect(channel_audits) =~ raw_endpoint
    refute inspect(channel_audits) =~ "team-secret"
    refute inspect(channel_audits) =~ "query-secret"
    refute inspect(channel_audits) =~ signing_secret
    refute inspect(channel_audits) =~ "Bearer channel-token"
    refute inspect(channel_audits) =~ "metadata-secret"
  end

  test "records incident acknowledge and resolve audit rows with metadata-only identifiers" do
    {scope, pool} = owner_scope_and_pool()
    dedupe_key = "alert:audit:#{System.unique_integer([:positive])}"

    incident =
      alert_incident_fixture(
        pool: pool,
        dedupe_key: dedupe_key,
        safe_evidence_snapshot: %{"prompt" => "already redacted upstream"}
      )

    assert {:ok, acknowledged} = Alerts.acknowledge_incident(scope, incident.id)
    assert acknowledge_audit = audit_event("alert_incident.acknowledge", incident.id)
    assert acknowledge_audit.actor_user_id == scope.user.id
    assert acknowledge_audit.pool_id == pool.id
    assert acknowledge_audit.target_type == "alert_incident"
    assert acknowledge_audit.details["alert_incident_id"] == incident.id
    assert acknowledge_audit.details["previous_state"] == "open"
    assert acknowledge_audit.details["state"] == "acknowledged"
    assert acknowledge_audit.details["dedupe_key_fingerprint"]
    refute inspect(acknowledge_audit.details) =~ dedupe_key
    refute inspect(acknowledge_audit.details) =~ "already redacted upstream"

    assert {:ok, resolved} = Alerts.resolve_incident(scope, acknowledged.id)
    assert resolved.state == "resolved"
    assert resolve_audit = audit_event("alert_incident.resolve", incident.id)
    assert resolve_audit.details["previous_state"] == "acknowledged"
    assert resolve_audit.details["state"] == "resolved"
    assert resolve_audit.details["pool_id"] == pool.id
  end

  defp owner_scope_and_pool do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner)

    pool =
      pool_fixture(%{
        slug: "alert-audit-#{System.unique_integer([:positive])}",
        name: "Alert Audit"
      })

    {scope, pool}
  end

  defp rule_attrs(pool, overrides) do
    %{
      pool_id: pool.id,
      scope_type: "pool",
      rule_kind: "pool_no_usable_assignments",
      display_name: "Pool usable assignment coverage",
      severity: "critical",
      cooldown_minutes: 30,
      state: "active",
      metadata: %{}
    }
    |> Map.merge(Map.new(overrides))
  end

  defp audit_event(action, target_id) do
    Repo.one!(
      from event in AuditEvent,
        where: event.action == ^action and event.target_id == ^target_id,
        order_by: [desc: event.occurred_at, desc: event.id],
        limit: 1
    )
  end

  defp audit_events_for_target(target_id) do
    Repo.all(
      from event in AuditEvent,
        where: event.target_id == ^target_id,
        order_by: [asc: event.occurred_at, asc: event.id]
    )
  end
end
