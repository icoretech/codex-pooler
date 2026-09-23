defmodule CodexPooler.Alerts.OrphanedIncidentResolutionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.{AlertIncident, AlertIncidentTarget}
  alias CodexPooler.Jobs.{AlertEvaluationEnqueueWorker, AlertEvaluationWorker}
  alias CodexPooler.Repo

  # Deleting a rule cascades its incident targets away. An open incident left
  # with no unresolved target has no rule that can ever clear it, so it stayed
  # open forever (findings#260 row 260-31: four production incidents open since
  # the rule that raised them was deleted seconds after its first evaluation).
  # The scheduled evaluation pass resolves such incidents.
  test "the scheduled evaluation pass resolves an incident whose only rule was deleted" do
    {scope, pool} = owner_scope_and_pool()
    at = ~U[2026-05-30 10:05:00.000000Z]

    assert {:ok, rule} = Alerts.create_rule(scope, pool_rule_attrs(pool))
    evaluate!(rule, at)
    assert %AlertIncident{state: "open"} = incident = incident_for_pool(pool)
    assert target_count(incident) == 1

    assert {:ok, _deleted} = Alerts.delete_rule(scope, rule)
    assert %AlertIncident{state: "open"} = Repo.reload!(incident)
    assert target_count(incident) == 0

    assert :ok = perform_job(AlertEvaluationEnqueueWorker, %{}, scheduled_at: ~U[2026-05-30 10:10:00Z])

    assert %AlertIncident{state: "resolved"} = resolved = Repo.reload!(incident)
    assert resolved.resolved_at == ~U[2026-05-30 10:10:00.000000Z]
    assert resolved.suppression_metadata["resolved_reason"] == "no_rule_target"
  end

  test "the pass resolves a legacy incident that never had a target and keeps incidents a rule still owns" do
    {scope, pool} = owner_scope_and_pool()
    %{identity: identity} = upstream_assignment_fixture(pool)

    legacy =
      alert_incident_fixture(%{
        upstream_identity: identity,
        rule_kind: "upstream_saved_reset_banked_first_seen",
        severity: "info",
        dedupe_key: "alerts:v1:upstream_saved_reset_banked_first_seen:upstream_identity:#{identity.id}:reset_expires_at:2026-07-12T01:38:31.531963Z",
        first_seen_at: ~U[2026-05-30 08:50:00.000000Z],
        last_seen_at: ~U[2026-05-30 08:50:00.000000Z]
      })

    assert {:ok, kept_rule} = Alerts.create_rule(scope, pool_rule_attrs(pool, %{display_name: "Kept rule"}))
    kept = alert_incident_fixture(%{pool: pool, dedupe_key: "alert:kept:#{System.unique_integer([:positive])}"})
    alert_incident_target_fixture(kept, kept_rule, pool)

    assert {:ok, deleted_rule} = Alerts.create_rule(scope, pool_rule_attrs(pool, %{display_name: "Deleted rule"}))

    shared =
      alert_incident_fixture(%{
        upstream_identity: identity,
        rule_kind: "upstream_auth_state",
        dedupe_key: "alert:shared:#{System.unique_integer([:positive])}",
        state: "acknowledged",
        acknowledged_at: ~U[2026-05-30 09:00:00.000000Z]
      })

    alert_incident_target_fixture(shared, kept_rule, pool)
    alert_incident_target_fixture(shared, deleted_rule, pool)
    assert {:ok, _deleted} = Alerts.delete_rule(scope, deleted_rule)

    assert :ok = perform_job(AlertEvaluationEnqueueWorker, %{}, scheduled_at: ~U[2026-05-30 10:10:00Z])

    assert %AlertIncident{state: "resolved"} = Repo.reload!(legacy)
    assert %AlertIncident{state: "open"} = Repo.reload!(kept)
    assert %AlertIncident{state: "acknowledged"} = Repo.reload!(shared)
  end

  defp owner_scope_and_pool do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    pool = pool_fixture(%{slug: "orphan-incident-#{System.unique_integer([:positive])}", name: "Orphan Incident"})
    {Scope.for_user(owner), pool}
  end

  defp pool_rule_attrs(pool, overrides \\ %{}) do
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
    |> Map.merge(overrides)
  end

  defp evaluate!(rule, at) do
    args = %{"alert_rule_id" => rule.id, "evaluation_window_started_at" => DateTime.to_iso8601(at), "trigger_kind" => "test"}
    assert :ok = perform_job(AlertEvaluationWorker, args, attempted_at: at)
  end

  defp incident_for_pool(pool) do
    Repo.one!(from incident in AlertIncident, where: incident.pool_id == ^pool.id)
  end

  defp target_count(incident) do
    Repo.aggregate(from(target in AlertIncidentTarget, where: target.incident_id == ^incident.id), :count)
  end
end
