defmodule CodexPooler.Alerts.SavedResetAlertRuleBaselineTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertRule

  @tag :saved_reset_banked_first_seen
  test "saved reset first-seen rules created active persist a baseline timestamp" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    pool = pool_fixture(%{slug: "saved-reset-baseline-create", name: "Saved Reset Baseline"})

    assert {:ok, rule} =
             Alerts.create_rule(
               owner_scope,
               saved_reset_rule_attrs(pool, %{
                 display_name: "Saved reset active baseline",
                 metadata: %{"safe_label" => "saved reset lifecycle"}
               })
             )

    assert rule.metadata["safe_label"] == "saved reset lifecycle"
    assert {:ok, baseline, 0} = DateTime.from_iso8601(saved_reset_baseline!(rule))
    assert DateTime.compare(baseline, rule.created_at) == :eq
  end

  @tag :saved_reset_banked_first_seen
  test "saved reset first-seen rules created without state persist an active baseline timestamp" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    pool = pool_fixture(%{slug: "saved-reset-baseline-default", name: "Saved Reset Baseline"})

    attrs =
      saved_reset_rule_attrs(pool, %{
        display_name: "Saved reset default active baseline",
        metadata: %{"safe_label" => "saved reset lifecycle"}
      })
      |> Map.delete(:state)

    assert {:ok, rule} = Alerts.create_rule(owner_scope, attrs)

    assert rule.state == AlertRule.active_state()
    assert rule.metadata["safe_label"] == "saved reset lifecycle"
    assert {:ok, baseline, 0} = DateTime.from_iso8601(saved_reset_baseline!(rule))
    assert DateTime.compare(baseline, rule.created_at) == :eq
  end

  @tag :saved_reset_banked_first_seen
  test "saved reset first-seen rules derive created_at when baseline metadata is missing or malformed" do
    created_at = ~U[2026-01-02 03:04:05Z]
    pool = pool_fixture(%{slug: "saved-reset-baseline-fallback", name: "Saved Reset Fallback"})

    missing_baseline =
      alert_rule_fixture(pool,
        scope_type: "upstream_identity",
        rule_kind: "upstream_saved_reset_banked_first_seen",
        severity: "info",
        metadata: %{},
        created_at: created_at
      )

    malformed_baseline =
      alert_rule_fixture(pool,
        scope_type: "upstream_identity",
        rule_kind: "upstream_saved_reset_banked_first_seen",
        severity: "info",
        metadata: %{"saved_reset_first_seen_baseline_at" => "not-a-timestamp"},
        created_at: created_at
      )

    assert DateTime.compare(
             AlertRule.saved_reset_first_seen_baseline_at(missing_baseline),
             created_at
           ) ==
             :eq

    assert DateTime.compare(
             AlertRule.saved_reset_first_seen_baseline_at(malformed_baseline),
             created_at
           ) == :eq
  end

  @tag :saved_reset_banked_first_seen
  test "saved reset first-seen rules created disabled defer baseline metadata until enabled" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    pool = pool_fixture(%{slug: "saved-reset-baseline-deferred", name: "Saved Reset Deferred"})

    assert {:ok, rule} =
             Alerts.create_rule(
               owner_scope,
               saved_reset_rule_attrs(pool, %{
                 display_name: "Saved reset disabled deferred baseline",
                 state: "disabled",
                 metadata: %{"safe_label" => "saved reset lifecycle"}
               })
             )

    refute Map.has_key?(rule.metadata, "saved_reset_first_seen_baseline_at")

    assert {:ok, enabled_rule} = Alerts.update_rule(owner_scope, rule, %{state: "active"})

    assert {:ok, enabled_baseline, 0} = DateTime.from_iso8601(saved_reset_baseline!(enabled_rule))
    assert DateTime.compare(enabled_baseline, enabled_rule.updated_at) == :eq
  end

  @tag :saved_reset_banked_first_seen
  test "saved reset first-seen disabled-to-active transitions move the baseline forward" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    pool = pool_fixture(%{slug: "saved-reset-baseline-enable", name: "Saved Reset Enable"})
    old_baseline = ~U[2026-01-02 03:04:05Z]

    assert {:ok, rule} =
             Alerts.create_rule(
               owner_scope,
               saved_reset_rule_attrs(pool, %{
                 display_name: "Saved reset disabled baseline",
                 state: "disabled",
                 metadata: %{
                   "safe_label" => "saved reset lifecycle",
                   "saved_reset_first_seen_baseline_at" => DateTime.to_iso8601(old_baseline)
                 }
               })
             )

    assert {:ok, enabled_rule} = Alerts.update_rule(owner_scope, rule, %{state: "active"})

    assert enabled_rule.metadata["safe_label"] == "saved reset lifecycle"
    assert {:ok, enabled_baseline, 0} = DateTime.from_iso8601(saved_reset_baseline!(enabled_rule))
    assert DateTime.compare(enabled_baseline, old_baseline) == :gt
    assert DateTime.compare(enabled_baseline, enabled_rule.updated_at) == :eq
  end

  @tag :saved_reset_banked_first_seen
  test "non saved reset rules do not receive saved reset baseline metadata" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)
    pool = pool_fixture(%{slug: "alerts-no-baseline-churn", name: "Alerts No Baseline Churn"})

    assert {:ok, rule} =
             Alerts.create_rule(
               owner_scope,
               rule_attrs(pool, %{
                 display_name: "Pool rule without saved reset baseline",
                 state: "disabled",
                 metadata: %{"safe_label" => "pool lifecycle"}
               })
             )

    refute Map.has_key?(rule.metadata, "saved_reset_first_seen_baseline_at")

    assert {:ok, enabled_rule} = Alerts.update_rule(owner_scope, rule, %{state: "active"})

    assert enabled_rule.metadata == %{"safe_label" => "pool lifecycle"}
  end

  defp rule_attrs(pool, overrides) do
    overrides = Map.new(overrides)

    %{
      pool_id: pool.id,
      scope_type: "pool",
      rule_kind: "pool_no_usable_assignments",
      display_name: Map.get(overrides, :display_name, "Pool usable assignment coverage"),
      severity: "critical",
      cooldown_minutes: 30,
      state: "active",
      metadata: %{}
    }
    |> Map.merge(overrides)
  end

  defp saved_reset_rule_attrs(pool, overrides) do
    rule_attrs(
      pool,
      Map.merge(
        %{
          scope_type: "upstream_identity",
          rule_kind: "upstream_saved_reset_banked_first_seen",
          severity: "info",
          cooldown_minutes: 30
        },
        Map.new(overrides)
      )
    )
  end

  defp saved_reset_baseline!(%AlertRule{} = rule),
    do: Map.fetch!(rule.metadata, "saved_reset_first_seen_baseline_at")
end
