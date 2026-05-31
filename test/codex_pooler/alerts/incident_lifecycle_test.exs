defmodule CodexPooler.Alerts.IncidentLifecycleTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.{AlertIncident, AlertIncidentTarget}
  alias CodexPooler.Repo

  test "records first match and open duplicates against the same unresolved incident" do
    %{pool: pool, rule: rule} = lifecycle_rule_fixture()
    first_seen = timestamp(~U[2026-05-30 10:00:00Z])
    second_seen = timestamp(~U[2026-05-30 10:05:00Z])
    dedupe_key = dedupe_key("open-duplicate")

    assert {:ok, first_incident} =
             Alerts.record_incident_match(
               match_attrs(rule, pool, dedupe_key,
                 matched_at: first_seen,
                 evidence: %{
                   "condition" => "no_usable_assignments",
                   "access_token" => "not-persisted"
                 }
               )
             )

    assert first_incident.state == "open"
    assert first_incident.occurrence_count == 1
    assert first_incident.first_seen_at == first_seen
    assert first_incident.last_seen_at == first_seen
    assert first_incident.safe_evidence_snapshot["access_token"] == "[REDACTED]"

    assert [target] = targets_for(first_incident)
    assert target.rule_id == rule.id
    assert target.pool_id == pool.id
    assert target.first_matched_at == first_seen
    assert target.last_matched_at == first_seen
    refute target.resolved_at

    assert {:ok, duplicate_incident} =
             Alerts.record_incident_match(
               match_attrs(rule, pool, dedupe_key,
                 matched_at: second_seen,
                 evidence: %{
                   "condition" => "still_no_usable_assignments",
                   "prompt" => "not-persisted"
                 },
                 target_metadata: %{"sample_count" => 2}
               )
             )

    assert duplicate_incident.id == first_incident.id
    assert duplicate_incident.state == "open"
    assert duplicate_incident.occurrence_count == 2
    assert duplicate_incident.first_seen_at == first_seen
    assert duplicate_incident.last_seen_at == second_seen
    assert duplicate_incident.safe_evidence_snapshot["condition"] == "still_no_usable_assignments"
    assert duplicate_incident.safe_evidence_snapshot["prompt"] == "[REDACTED]"

    assert [updated_target] = targets_for(duplicate_incident)
    assert updated_target.id == target.id
    assert updated_target.first_matched_at == first_seen
    assert updated_target.last_matched_at == second_seen
    assert updated_target.metadata == %{"sample_count" => 2}
  end

  test "duplicate match while acknowledged preserves acknowledged state and lifecycle fields" do
    %{owner_scope: owner_scope, pool: pool, rule: rule} = lifecycle_rule_fixture()
    first_seen = timestamp(~U[2026-05-30 11:00:00Z])
    duplicate_seen = timestamp(~U[2026-05-30 11:05:00Z])
    dedupe_key = dedupe_key("acknowledged-duplicate")

    assert {:ok, incident} =
             Alerts.record_incident_match(
               match_attrs(rule, pool, dedupe_key, matched_at: first_seen)
             )

    assert {:ok, acknowledged} = Alerts.acknowledge_incident(owner_scope, incident.id)
    acknowledged_at = acknowledged.acknowledged_at

    assert {:ok, duplicate_incident} =
             Alerts.record_incident_match(
               match_attrs(rule, pool, dedupe_key,
                 matched_at: duplicate_seen,
                 evidence: %{"condition" => "acknowledged_still_active"}
               )
             )

    assert duplicate_incident.id == incident.id
    assert duplicate_incident.state == "acknowledged"
    assert duplicate_incident.acknowledged_at == acknowledged_at
    assert duplicate_incident.occurrence_count == 2
    assert duplicate_incident.first_seen_at == first_seen
    assert duplicate_incident.last_seen_at == duplicate_seen
    refute duplicate_incident.resolved_at
  end

  test "clear resolves unresolved incidents and returned condition creates a new row" do
    %{owner_scope: owner_scope, pool: pool, rule: rule} = lifecycle_rule_fixture()
    first_seen = timestamp(~U[2026-05-30 12:00:00Z])
    duplicate_seen = timestamp(~U[2026-05-30 12:05:00Z])
    cleared_at = timestamp(~U[2026-05-30 12:10:00Z])
    returned_at = timestamp(~U[2026-05-30 12:15:00Z])
    dedupe_key = dedupe_key("clear-return")

    assert {:ok, incident} =
             Alerts.record_incident_match(
               match_attrs(rule, pool, dedupe_key, matched_at: first_seen)
             )

    assert {:ok, acknowledged} = Alerts.acknowledge_incident(owner_scope, incident.id)

    assert {:ok, active_incident} =
             Alerts.record_incident_match(
               match_attrs(rule, pool, dedupe_key, matched_at: duplicate_seen)
             )

    assert active_incident.id == acknowledged.id
    assert active_incident.state == "acknowledged"

    assert {:ok, resolved_incident} =
             Alerts.clear_incident_condition(%{dedupe_key: dedupe_key, cleared_at: cleared_at})

    assert resolved_incident.id == incident.id
    assert resolved_incident.state == "resolved"
    assert resolved_incident.resolved_at == cleared_at
    assert resolved_incident.last_seen_at == duplicate_seen

    assert [resolved_target] = targets_for(resolved_incident)
    assert resolved_target.resolved_at == cleared_at

    assert {:ok, returned_incident} =
             Alerts.record_incident_match(
               match_attrs(rule, pool, dedupe_key, matched_at: returned_at)
             )

    assert returned_incident.id != incident.id
    assert returned_incident.state == "open"
    assert returned_incident.occurrence_count == 1
    assert returned_incident.first_seen_at == returned_at
    assert returned_incident.last_seen_at == returned_at

    assert %AlertIncident{state: "resolved", resolved_at: ^cleared_at} =
             Repo.get!(AlertIncident, incident.id)
  end

  test "clearing a condition with no unresolved incident is idempotent" do
    assert {:ok, nil} = Alerts.clear_incident_condition(dedupe_key("already-clear"))
  end

  defp lifecycle_rule_fixture do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    pool = pool_fixture(%{slug: "alerts-lifecycle-#{unique_suffix()}", name: "Alerts Lifecycle"})
    rule = alert_rule_fixture(pool, created_by_user_id: owner.id)
    %{owner_scope: owner_scope, pool: pool, rule: rule}
  end

  defp match_attrs(rule, pool, dedupe_key, opts) do
    %{
      dedupe_key: dedupe_key,
      scope_type: "pool",
      rule_kind: rule.rule_kind,
      severity: rule.severity,
      pool_id: pool.id,
      matched_at: Keyword.fetch!(opts, :matched_at),
      safe_evidence_snapshot: Keyword.get(opts, :evidence, %{"condition" => "active"}),
      suppression_metadata: Keyword.get(opts, :suppression_metadata, %{}),
      targets: [
        %{
          rule_id: rule.id,
          pool_id: pool.id,
          metadata: Keyword.get(opts, :target_metadata, %{})
        }
      ]
    }
  end

  defp targets_for(%AlertIncident{} = incident) do
    Repo.all(
      from target in AlertIncidentTarget,
        where: target.incident_id == ^incident.id,
        order_by: [asc: target.first_matched_at, asc: target.id]
    )
  end

  defp dedupe_key(label), do: "alert:test:#{label}:#{unique_suffix()}"
  defp timestamp(value), do: %{value | microsecond: {0, 6}}
  defp unique_suffix, do: System.unique_integer([:positive])
end
