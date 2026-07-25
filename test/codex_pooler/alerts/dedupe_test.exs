defmodule CodexPooler.Alerts.DedupeTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Evaluation.EvaluationCandidate

  alias CodexPooler.Alerts.Schemas.{
    AlertIncident,
    AlertIncidentTarget,
    AlertRule
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

  test "usability dedupe keys separate route classes while pool-all stays byte-identical" do
    pool_id = Ecto.UUID.generate()

    for rule_kind <- ["pool_no_usable_assignments", "pool_low_usable_assignments"] do
      base_rule = %AlertRule{
        id: Ecto.UUID.generate(),
        pool_id: pool_id,
        scope_type: "pool",
        rule_kind: rule_kind,
        model: "gpt-5.5",
        min_usable_assignments: if(rule_kind == "pool_low_usable_assignments", do: 2),
        target_state: nil
      }

      stream_key =
        base_rule
        |> Map.put(:route_class, "proxy_stream")
        |> EvaluationCandidate.dedupe_key_for_rule(nil)

      compact_key =
        base_rule
        |> Map.put(:route_class, "proxy_compact")
        |> EvaluationCandidate.dedupe_key_for_rule(nil)

      assert stream_key != compact_key
      assert String.ends_with?(stream_key, ":route_class:proxy_stream")
      assert String.ends_with?(compact_key, ":route_class:proxy_compact")
    end

    pool_all_rule = %AlertRule{
      id: Ecto.UUID.generate(),
      pool_id: pool_id,
      scope_type: "pool",
      rule_kind: "pool_all_assignments_in_state",
      model: "gpt-5.5",
      min_usable_assignments: nil,
      target_state: "exhausted"
    }

    assert EvaluationCandidate.dedupe_key_for_rule(
             Map.put(pool_all_rule, :route_class, "proxy_stream"),
             nil
           ) ==
             "alerts:v1:pool_all_assignments_in_state:pool:#{pool_id}:model:gpt-5.5:min:none:state:exhausted"
  end

  test "pool evidence records the selected route class scope" do
    rule =
      %AlertRule{
        id: Ecto.UUID.generate(),
        pool_id: Ecto.UUID.generate(),
        scope_type: "pool",
        rule_kind: "pool_no_usable_assignments",
        severity: "critical"
      }
      |> Map.put(:route_class, "proxy_stream")

    projection = %{
      assignment_count: 2,
      enabled_assignment_count: 2,
      usable_assignment_count: 0,
      state_counts: %{}
    }

    candidate =
      EvaluationCandidate.pool_match(
        rule,
        projection,
        "no_usable_assignments",
        ~U[2026-07-25 12:00:00Z]
      )

    assert candidate.match_attrs.safe_evidence_snapshot["route_class_scope"] == "proxy_stream"
  end

  test "route-class scoped usability candidates open separate unresolved incidents" do
    pool = pool_fixture()

    projection = %{
      assignment_count: 2,
      enabled_assignment_count: 2,
      usable_assignment_count: 0,
      state_counts: %{}
    }

    incidents =
      for route_class <- ["proxy_stream", "proxy_compact"] do
        rule = alert_rule_fixture(pool, route_class: route_class)

        candidate =
          EvaluationCandidate.pool_match(
            rule,
            projection,
            "no_usable_assignments",
            ~U[2026-07-25 12:00:00Z]
          )

        assert {:ok, incident} = Alerts.record_incident_match(candidate.match_attrs)
        incident
      end

    assert Enum.uniq_by(incidents, & &1.id) == incidents

    assert Repo.aggregate(
             from(incident in AlertIncident, where: incident.state != "resolved"),
             :count
           ) ==
             2
  end

  defp timestamp(value), do: %{value | microsecond: {0, 6}}
  defp unique_suffix, do: System.unique_integer([:positive])
end
