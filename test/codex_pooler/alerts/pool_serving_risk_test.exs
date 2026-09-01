defmodule CodexPooler.Alerts.PoolServingRiskTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [primary_quota_window_attrs: 1]

  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Evaluation.EvaluationProjection
  alias CodexPooler.Alerts.Schemas.AlertRule
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountAvailabilityStore
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  test "pool_no_usable_assignments matches when no assignment can route" do
    timestamp = now()
    pool = pool_fixture()
    upstream_assignment_fixture(pool)

    rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    assert [%{action: :match, match_attrs: match}] = Alerts.evaluate_rule(rule, at: timestamp)
    assert match.scope_type == "pool"
    assert match.pool_id == pool.id
    assert match.safe_evidence_snapshot["reason_code"] == "no_usable_assignments"
    assert match.safe_evidence_snapshot["assignment_count"] == 1
    assert match.safe_evidence_snapshot["enabled_assignment_count"] == 1
    assert match.safe_evidence_snapshot["usable_assignment_count"] == 0
  end

  test "fresh provider availability without windows clears pool serving risk" do
    timestamp = now()
    pool = pool_fixture()

    upstream_assignment_fixture(pool, %{
      identity_metadata: %{
        "credential_epoch" => 1,
        AccountAvailabilityStore.metadata_key() =>
          AccountAvailabilityStore.encode!(:available, timestamp, 1)
      }
    })

    no_usable_rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    all_missing_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: "missing_evidence"
      )

    assert [%{action: :clear}] = Alerts.evaluate_rule(no_usable_rule, at: timestamp)
    assert [%{action: :clear}] = Alerts.evaluate_rule(all_missing_rule, at: timestamp)
  end

  test "superseded raw evidence blocks fallback but alert display counts only effective rows" do
    timestamp = now()
    frozen_at = DateTime.add(timestamp, -3_600, :second)
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)
    put_available_identity!(identity, timestamp)

    assert {:ok, [_primary, _secondary]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("100"),
                 reset_at: DateTime.add(timestamp, -1, :second),
                 observed_at: frozen_at,
                 last_sync_at: frozen_at
               }),
               %{
                 quota_key: "account",
                 quota_scope: "account",
                 quota_family: "account",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new("100"),
                 reset_at: DateTime.add(timestamp, 6, :day),
                 observed_at: timestamp,
                 last_sync_at: timestamp,
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh"
               }
             ])

    rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    assert [%{action: :match, match_attrs: match}] = Alerts.evaluate_rule(rule, at: timestamp)
    assert match.safe_evidence_snapshot["usable_assignment_count"] == 0

    assert {[assignment], _cache} =
             EvaluationProjection.assigned_identities_from_cache(
               pool.id,
               nil,
               %{at: timestamp, route_class: nil, circuit_observed_at: timestamp},
               false,
               %{}
             )

    assert assignment.quota.window_count == 1
    assert [window] = assignment.quota_windows
    assert window.window_kind == "secondary"
  end

  test "concrete model alerts resolve exposed and upstream aliases while model nil stays aggregate" do
    timestamp = now()
    pool = pool_fixture()
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)

    alpha =
      model_fixture(pool, %{
        exposed_model_id: "gpt-example-alpha",
        upstream_model_id: "provider-example-alpha",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

    model_fixture(pool, %{
      exposed_model_id: "gpt-example-beta",
      upstream_model_id: "provider-example-beta",
      metadata: %{"source_assignment_ids" => [assignment.id]}
    })

    identity
    |> Ecto.Changeset.change(%{
      metadata: %{
        "credential_epoch" => 1,
        AccountAvailabilityStore.metadata_key() =>
          AccountAvailabilityStore.encode!(:available, timestamp, 1)
      }
    })
    |> Repo.update!()

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "provider-example-beta",
                 quota_scope: "upstream_model",
                 quota_family: "codex_model",
                 upstream_model: "provider-example-beta",
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("100"),
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp,
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh"
               }
             ])

    alpha_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_no_usable_assignments",
        model: String.upcase(alpha.exposed_model_id)
      )

    beta_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_no_usable_assignments",
        model: "gpt-example-beta"
      )

    aggregate_rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    assert [%{action: :clear}] = Alerts.evaluate_rule(alpha_rule, at: timestamp)
    assert [%{action: :match}] = Alerts.evaluate_rule(beta_rule, at: timestamp)
    assert [%{action: :match}] = Alerts.evaluate_rule(aggregate_rule, at: timestamp)
  end

  test "concrete model alert fails closed when its persisted upstream alias is blank" do
    timestamp = now()
    pool = pool_fixture()
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-example-malformed-upstream",
        upstream_model_id: "provider-example-malformed-upstream",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

    model
    |> Ecto.Changeset.change(%{upstream_model_id: "   "})
    |> Repo.update!()

    put_available_identity!(identity, timestamp)
    put_exhausted_upstream_model!(identity, "provider-example-unrelated", timestamp)

    rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        model: "gpt-example-malformed-upstream",
        target_state: "exhausted"
      )

    assert [%{action: :clear}] = Alerts.evaluate_rule(rule, at: timestamp)
  end

  test "blank persisted concrete model and aliases fail closed instead of becoming aggregate scope" do
    timestamp = now()
    pool = pool_fixture()
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-example-malformed-blank",
        upstream_model_id: "provider-example-malformed-blank",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

    model
    |> Ecto.Changeset.change(%{exposed_model_id: "   ", upstream_model_id: "\t"})
    |> Repo.update!()

    put_available_identity!(identity, timestamp)
    put_exhausted_upstream_model!(identity, "provider-example-unrelated", timestamp)

    rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        model: "gpt-example-persisted-rule-placeholder",
        target_state: "exhausted"
      )

    rule
    |> Ecto.Changeset.change(%{model: "   "})
    |> Repo.update!()

    persisted_rule = Repo.get!(AlertRule, rule.id)
    assert [%{action: :clear}] = Alerts.evaluate_rule(persisted_rule, at: timestamp)
  end

  test "pool_low_usable_assignments matches below configured minimum and clears at or above it" do
    timestamp = now()
    pool = pool_fixture()
    %{identity: usable_identity} = upstream_assignment_fixture(pool)
    upstream_assignment_fixture(pool)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(usable_identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("25"),
                 credits: 75,
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])

    warning_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_low_usable_assignments",
        severity: "warning",
        min_usable_assignments: 2
      )

    assert [%{action: :match, match_attrs: match}] =
             Alerts.evaluate_rule(warning_rule, at: timestamp)

    assert match.severity == "warning"
    assert match.safe_evidence_snapshot["reason_code"] == "low_usable_assignments"
    assert match.safe_evidence_snapshot["usable_assignment_count"] == 1
    assert match.safe_evidence_snapshot["min_usable_assignments"] == 2

    clear_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_low_usable_assignments",
        min_usable_assignments: 1
      )

    assert [%{action: :clear}] = Alerts.evaluate_rule(clear_rule, at: timestamp)
  end

  test "pool_all_assignments_in_state matches all enabled assignments and ignores disabled ones" do
    timestamp = now()
    pool = pool_fixture()
    %{identity: exhausted_identity} = upstream_assignment_fixture(pool)

    upstream_assignment_fixture(pool, %{
      assignment_status: "disabled",
      health_status: "disabled",
      eligibility_status: "ineligible"
    })

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(exhausted_identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("100"),
                 credits: 0,
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])

    rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: "exhausted",
        severity: "critical"
      )

    assert [%{action: :match, match_attrs: match}] = Alerts.evaluate_rule(rule, at: timestamp)
    assert match.safe_evidence_snapshot["reason_code"] == "exhausted"
    assert match.safe_evidence_snapshot["enabled_assignment_count"] == 1
    assert match.safe_evidence_snapshot["state_counts"] == %{"exhausted" => 1}
  end

  test "pool serving-risk predicates clear when usable assignments are healthy" do
    timestamp = now()
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("10"),
                 credits: 90,
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])

    no_usable_rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    all_missing_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: "missing_evidence"
      )

    assert [%{action: :clear}] = Alerts.evaluate_rule(no_usable_rule, at: timestamp)
    assert [%{action: :clear}] = Alerts.evaluate_rule(all_missing_rule, at: timestamp)
  end

  test "reauth-required takes priority over fresh usable quota in pool serving risk" do
    timestamp = now()
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{identity_status: "reauth_required"})

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("10"),
                 credits: 90,
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])

    reauth_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: "reauth_required"
      )

    no_usable_rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    assert [%{action: :match, match_attrs: reauth_match}] =
             Alerts.evaluate_rule(reauth_rule, at: timestamp)

    assert reauth_match.safe_evidence_snapshot["state_counts"] == %{"reauth_required" => 1}

    assert [%{action: :match, match_attrs: no_usable_match}] =
             Alerts.evaluate_rule(no_usable_rule, at: timestamp)

    assert no_usable_match.safe_evidence_snapshot["usable_assignment_count"] == 0
  end

  test "reauth-required takes priority over stale quota in pool serving risk" do
    timestamp = now()
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{identity_status: "reauth_required"})

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 freshness_state: "stale",
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])

    reauth_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: "reauth_required"
      )

    stale_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: "stale"
      )

    assert [%{action: :match, match_attrs: reauth_match}] =
             Alerts.evaluate_rule(reauth_rule, at: timestamp)

    assert reauth_match.safe_evidence_snapshot["reason_code"] == "reauth_required"
    assert [%{action: :clear}] = Alerts.evaluate_rule(stale_rule, at: timestamp)
  end

  test "fresh recovered quota clears reauth serving-risk predicates" do
    timestamp = now()
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{identity_status: "reauth_required"})

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("20"),
                 credits: 80,
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])

    reauth_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: "reauth_required"
      )

    no_usable_rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    assert [%{action: :match}] = Alerts.evaluate_rule(reauth_rule, at: timestamp)
    assert [%{action: :match}] = Alerts.evaluate_rule(no_usable_rule, at: timestamp)

    identity
    |> UpstreamIdentity.changeset(%{status: "active", disabled_at: nil})
    |> Repo.update!()

    assert [%{action: :clear}] = Alerts.evaluate_rule(reauth_rule, at: timestamp)
    assert [%{action: :clear}] = Alerts.evaluate_rule(no_usable_rule, at: timestamp)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp put_available_identity!(identity, timestamp) do
    identity
    |> Ecto.Changeset.change(%{
      metadata: %{
        "credential_epoch" => 1,
        AccountAvailabilityStore.metadata_key() =>
          AccountAvailabilityStore.encode!(:available, timestamp, 1)
      }
    })
    |> Repo.update!()
  end

  defp put_exhausted_upstream_model!(identity, upstream_model, timestamp) do
    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: upstream_model,
                 quota_scope: "upstream_model",
                 quota_family: "codex_model",
                 upstream_model: upstream_model,
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("100"),
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp,
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh"
               }
             ])
  end
end
