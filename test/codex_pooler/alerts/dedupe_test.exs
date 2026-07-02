defmodule CodexPooler.Alerts.DedupeTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts

  alias CodexPooler.Alerts.Schemas.{
    AlertIncident,
    AlertIncidentTarget
  }

  alias CodexPooler.Repo

  test "upstream-global issue affecting multiple pools dedupes to one root incident" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)

    pool_alpha = pool_fixture(%{slug: "pool-alpha-#{unique_suffix()}", name: "Pool Alpha"})
    pool_beta = pool_fixture(%{slug: "pool-beta-#{unique_suffix()}", name: "Pool Beta"})

    %{identity: identity} = upstream_assignment_fixture(pool_alpha)

    rule_alpha =
      alert_rule_fixture(pool_alpha,
        scope_type: "upstream_identity",
        rule_kind: "upstream_quota_threshold",
        severity: "warning",
        window_selector: "account_primary",
        threshold_used_percent: Decimal.new("90")
      )

    rule_beta =
      alert_rule_fixture(pool_beta,
        scope_type: "upstream_identity",
        rule_kind: "upstream_quota_threshold",
        severity: "warning",
        window_selector: "account_primary",
        threshold_used_percent: Decimal.new("90")
      )

    dedupe_key = "alert:upstream-quota:#{identity.id}:account_primary:90:#{unique_suffix()}"
    first_seen = timestamp(~U[2026-05-30 13:00:00Z])
    second_seen = timestamp(~U[2026-05-30 13:05:00Z])

    assert {:ok, incident} =
             Alerts.record_incident_match(%{
               dedupe_key: dedupe_key,
               scope_type: "upstream_identity",
               rule_kind: "upstream_quota_threshold",
               severity: "warning",
               upstream_identity_id: identity.id,
               matched_at: first_seen,
               safe_evidence_snapshot: %{
                 "window_selector" => "account_primary",
                 "used_percent" => 91,
                 "raw_response_body" => "not-persisted"
               },
               targets: [
                 %{
                   rule_id: rule_alpha.id,
                   pool_id: pool_alpha.id,
                   metadata: %{"pool" => "alpha"}
                 },
                 %{rule_id: rule_beta.id, pool_id: pool_beta.id, metadata: %{"pool" => "beta"}}
               ]
             })

    assert incident.scope_type == "upstream_identity"
    assert incident.upstream_identity_id == identity.id
    refute incident.pool_id
    assert incident.occurrence_count == 1
    assert incident.safe_evidence_snapshot["raw_response_body"] == "[REDACTED]"

    assert {:ok, duplicate_incident} =
             Alerts.record_incident_match(%{
               dedupe_key: dedupe_key,
               scope_type: "upstream_identity",
               rule_kind: "upstream_quota_threshold",
               severity: "warning",
               upstream_identity_id: identity.id,
               matched_at: second_seen,
               safe_evidence_snapshot: %{
                 "window_selector" => "account_primary",
                 "used_percent" => 94
               },
               targets: [
                 %{rule_id: rule_alpha.id, pool_id: pool_alpha.id},
                 %{rule_id: rule_beta.id, pool_id: pool_beta.id}
               ]
             })

    assert duplicate_incident.id == incident.id
    assert duplicate_incident.occurrence_count == 2
    assert duplicate_incident.last_seen_at == second_seen

    incident_rows = Repo.all(from row in AlertIncident, where: row.dedupe_key == ^dedupe_key)
    assert Enum.map(incident_rows, & &1.id) == [incident.id]

    target_rows =
      Repo.all(
        from target in AlertIncidentTarget,
          where: target.incident_id == ^incident.id,
          order_by: [asc: target.pool_id]
      )

    assert length(target_rows) == 2

    assert target_rows |> Enum.map(& &1.pool_id) |> MapSet.new() ==
             MapSet.new([pool_alpha.id, pool_beta.id])

    assert Enum.all?(target_rows, &(&1.last_matched_at == second_seen))

    assert {:ok, [projection]} = Alerts.list_incidents(owner_scope, state: "open")
    assert projection.id == incident.id
    assert projection.total_impacted_pool_count == 2
    assert projection.hidden_impacted_pool_count == 0

    assert projection.impacted_pools |> Enum.map(& &1.id) |> MapSet.new() ==
             MapSet.new([pool_alpha.id, pool_beta.id])
  end

  defp timestamp(value), do: %{value | microsecond: {0, 6}}
  defp unique_suffix, do: System.unique_integer([:positive])
end
