defmodule CodexPooler.Alerts.IncidentVisibilityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertIncidentTarget

  @saved_reset_rule_kind "upstream_saved_reset_banked_first_seen"

  @tag :saved_reset_banked_first_seen
  test "saved reset first-seen incidents preserve owner and admin impacted pool visibility" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    %{user: assigned_admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    assigned_admin_scope = Scope.for_user(assigned_admin)
    %{user: unassigned_admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    unassigned_admin_scope = Scope.for_user(unassigned_admin)

    visible_pool =
      pool_fixture(%{slug: unique_slug("visible"), name: "Saved Reset Visible Pool"})

    hidden_pool =
      pool_fixture(%{slug: unique_slug("hidden"), name: "Saved Reset Hidden Pool"})

    operator_pool_assignment_fixture(assigned_admin, visible_pool, created_by_user_id: owner.id)

    %{identity: identity} = upstream_assignment_fixture(visible_pool)
    visible_rule = saved_reset_rule_fixture(visible_pool)
    hidden_rule = saved_reset_rule_fixture(hidden_pool)
    dedupe_key = unique_saved_reset_dedupe(identity)
    matched_at = now()

    assert {:ok, %{incident: incident, inserted?: true, target_inserted?: true}} =
             Alerts.record_incident_once(
               saved_reset_match_attrs(
                 visible_rule,
                 visible_pool,
                 identity,
                 dedupe_key,
                 matched_at
               )
             )

    assert {:ok, %{incident: same_incident, inserted?: false, target_inserted?: true}} =
             Alerts.record_incident_once(
               saved_reset_match_attrs(hidden_rule, hidden_pool, identity, dedupe_key, matched_at)
             )

    assert same_incident.id == incident.id

    assert {:ok, [admin_projection]} = Alerts.list_incidents(assigned_admin_scope)
    assert admin_projection.id == incident.id
    assert admin_projection.rule_kind == @saved_reset_rule_kind
    assert admin_projection.scope_type == "upstream_identity"
    assert admin_projection.pool_id == nil
    assert admin_projection.visible_impacted_pool_count == 1
    assert admin_projection.hidden_impacted_pool_count == 1
    assert admin_projection.total_impacted_pool_count == 2
    assert admin_projection.impacted_pools == [pool_projection(visible_pool)]

    inspected_admin_projection = inspect(admin_projection)
    refute inspected_admin_projection =~ hidden_pool.id
    refute inspected_admin_projection =~ hidden_pool.name
    refute inspected_admin_projection =~ hidden_pool.slug

    assert {:ok, [owner_projection]} = Alerts.list_incidents(owner_scope)
    assert owner_projection.id == incident.id
    assert owner_projection.visible_impacted_pool_count == 2
    assert owner_projection.hidden_impacted_pool_count == 0
    assert owner_projection.total_impacted_pool_count == 2

    assert owner_projection.impacted_pools |> Enum.map(& &1.id) |> MapSet.new() ==
             MapSet.new([visible_pool.id, hidden_pool.id])

    assert {:ok, []} = Alerts.list_incidents(unassigned_admin_scope)
  end

  @tag :saved_reset_banked_first_seen
  test "saved reset first-seen incidents count duplicate same-pool targets once" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)

    pool =
      pool_fixture(%{slug: unique_slug("duplicate-same-pool"), name: "Saved Reset Same Pool"})

    %{identity: identity} = upstream_assignment_fixture(pool)
    first_rule = saved_reset_rule_fixture(pool)
    second_rule = saved_reset_rule_fixture(pool)
    dedupe_key = unique_saved_reset_dedupe(identity)
    matched_at = now()

    assert {:ok, %{incident: incident, inserted?: true, target_inserted?: true}} =
             Alerts.record_incident_once(
               saved_reset_match_attrs(first_rule, pool, identity, dedupe_key, matched_at)
             )

    assert {:ok, %{incident: same_incident, inserted?: false, target_inserted?: true}} =
             Alerts.record_incident_once(
               saved_reset_match_attrs(second_rule, pool, identity, dedupe_key, matched_at)
             )

    assert same_incident.id == incident.id
    assert alert_incident_target_count(incident.id) == 2

    assert {:ok, [projection]} = Alerts.list_incidents(owner_scope)
    assert projection.id == incident.id
    assert projection.visible_impacted_pool_count == 1
    assert projection.hidden_impacted_pool_count == 0
    assert projection.total_impacted_pool_count == 1
    assert projection.impacted_pools == [pool_projection(pool)]
    assert length(projection.impacted_pools) == 1
    assert projection.impacted_pools |> Enum.map(& &1.id) |> MapSet.new() == MapSet.new([pool.id])
  end

  test "assigned admins see only manageable impacted pools for upstream incidents" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin)
    visible_pool = pool_fixture(%{slug: "alerts-visible-impact", name: "Alerts Visible Impact"})
    hidden_pool = pool_fixture(%{slug: "alerts-hidden-impact", name: "Alerts Hidden Impact"})

    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: owner.id)

    %{identity: identity} = upstream_assignment_fixture(visible_pool)
    visible_rule = alert_rule_fixture(visible_pool, rule_kind: "upstream_quota_threshold")
    hidden_rule = alert_rule_fixture(hidden_pool, rule_kind: "upstream_quota_threshold")

    incident =
      alert_incident_fixture(
        scope_type: "upstream_identity",
        rule_kind: "upstream_quota_threshold",
        upstream_identity_id: identity.id,
        dedupe_key: "alert:upstream:#{System.unique_integer([:positive])}",
        safe_evidence_snapshot: %{"quota_window" => "account_primary"}
      )

    alert_incident_target_fixture(incident, visible_rule, visible_pool)
    alert_incident_target_fixture(incident, hidden_rule, hidden_pool)

    assert {:ok, [admin_projection]} = Alerts.list_incidents(admin_scope)

    assert admin_projection.id == incident.id
    assert admin_projection.scope_type == "upstream_identity"
    assert admin_projection.visible_impacted_pool_count == 1
    assert admin_projection.hidden_impacted_pool_count == 1
    assert admin_projection.total_impacted_pool_count == 2
    assert admin_projection.impacted_pools == [pool_projection(visible_pool)]

    inspected_projection = inspect(admin_projection)
    refute inspected_projection =~ hidden_pool.id
    refute inspected_projection =~ hidden_pool.name
    refute inspected_projection =~ hidden_pool.slug

    assert {:ok, [owner_projection]} = Alerts.list_incidents(owner_scope)
    assert owner_projection.visible_impacted_pool_count == 2
    assert owner_projection.hidden_impacted_pool_count == 0

    assert owner_projection.impacted_pools |> Enum.map(& &1.id) |> MapSet.new() ==
             MapSet.new([visible_pool.id, hidden_pool.id])
  end

  test "pool filters and incident actions do not leak hidden impacted pool labels" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin)
    visible_pool = pool_fixture(%{slug: "alerts-filter-visible", name: "Alerts Filter Visible"})
    hidden_pool = pool_fixture(%{slug: "alerts-filter-hidden", name: "Alerts Filter Hidden"})

    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: owner.id)

    %{identity: identity} = upstream_assignment_fixture(visible_pool)
    visible_rule = alert_rule_fixture(visible_pool, rule_kind: "upstream_auth_state")
    hidden_rule = alert_rule_fixture(hidden_pool, rule_kind: "upstream_auth_state")

    incident =
      alert_incident_fixture(
        scope_type: "upstream_identity",
        rule_kind: "upstream_auth_state",
        upstream_identity_id: identity.id,
        dedupe_key: "alert:upstream-auth:#{System.unique_integer([:positive])}",
        safe_evidence_snapshot: %{"auth_state" => "reauth_required"}
      )

    alert_incident_target_fixture(incident, visible_rule, visible_pool)
    alert_incident_target_fixture(incident, hidden_rule, hidden_pool)

    assert {:ok, [visible_projection]} =
             Alerts.list_incidents(admin_scope, pool_id: visible_pool.id)

    assert visible_projection.impacted_pools == [pool_projection(visible_pool)]
    assert visible_projection.hidden_impacted_pool_count == 1

    assert {:error, hidden_filter_error} =
             Alerts.list_incidents(admin_scope, pool_id: hidden_pool.id)

    assert hidden_filter_error.code == :capability_denied
    refute hidden_filter_error.message =~ hidden_pool.id
    refute hidden_filter_error.message =~ hidden_pool.name
    refute hidden_filter_error.message =~ hidden_pool.slug

    hidden_pool_incident =
      alert_incident_fixture(
        pool: hidden_pool,
        dedupe_key: "alert:hidden-pool:#{System.unique_integer([:positive])}"
      )

    assert {:error, hidden_action_error} =
             Alerts.resolve_incident(admin_scope, hidden_pool_incident.id)

    assert hidden_action_error.code == :incident_not_found
    refute hidden_action_error.message =~ hidden_pool.id
    refute hidden_action_error.message =~ hidden_pool.name
    refute hidden_action_error.message =~ hidden_pool.slug
  end

  test "unassigned admins receive an empty incident list without hidden pool evidence" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    admin_scope = Scope.for_user(admin)

    hidden_pool =
      pool_fixture(%{slug: "alerts-unassigned-hidden", name: "Alerts Unassigned Hidden"})

    alert_incident_fixture(
      pool: hidden_pool,
      dedupe_key: "alert:unassigned-hidden:#{System.unique_integer([:positive])}"
    )

    assert {:ok, []} = Alerts.list_incidents(admin_scope)
  end

  defp pool_projection(pool), do: %{id: pool.id, slug: pool.slug, name: pool.name}

  defp alert_incident_target_count(incident_id) do
    Repo.aggregate(
      from(target in AlertIncidentTarget, where: target.incident_id == ^incident_id),
      :count
    )
  end

  defp saved_reset_rule_fixture(pool) do
    alert_rule_fixture(pool, %{
      scope_type: "upstream_identity",
      rule_kind: @saved_reset_rule_kind,
      display_name: "Saved reset first seen #{unique_suffix()}",
      severity: "info"
    })
  end

  defp saved_reset_match_attrs(rule, pool, identity, dedupe_key, matched_at) do
    evidence = %{
      "reason_code" => "saved_reset_banked_first_seen",
      "reset_expires_at" => "2026-07-03T00:00:00Z",
      "reset_first_seen_at" => "2026-07-02T00:00:00Z",
      "available_count" => 1,
      "source" => "snapshot",
      "path_style" => "available_expirations",
      "pool_id" => pool.id,
      "upstream_identity_id" => identity.id
    }

    %{
      dedupe_key: dedupe_key,
      scope_type: "upstream_identity",
      rule_kind: @saved_reset_rule_kind,
      severity: "info",
      upstream_identity_id: identity.id,
      matched_at: matched_at,
      safe_evidence_snapshot: evidence,
      targets: [%{rule_id: rule.id, pool_id: pool.id, metadata: evidence}]
    }
  end

  defp unique_saved_reset_dedupe(identity) do
    "alerts:v1:#{@saved_reset_rule_kind}:upstream_identity:#{identity.id}:reset_expires_at:#{unique_suffix()}"
  end

  defp unique_slug(prefix),
    do: "saved-reset-visibility-#{prefix}-#{unique_suffix()}"

  defp unique_suffix, do: System.unique_integer([:positive])
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
