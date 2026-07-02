defmodule CodexPooler.Repo.Migrations.AddUpstreamSavedResetBankedFirstSeenAlertRule do
  use Ecto.Migration

  @existing_rule_kind_check "rule_kind IN ('pool_no_usable_assignments', 'pool_low_usable_assignments', 'pool_all_assignments_in_state', 'upstream_quota_threshold', 'upstream_auth_state')"
  @saved_reset_rule_kind_check "rule_kind IN ('pool_no_usable_assignments', 'pool_low_usable_assignments', 'pool_all_assignments_in_state', 'upstream_quota_threshold', 'upstream_auth_state', 'upstream_saved_reset_banked_first_seen')"

  def up do
    replace_rule_kind_constraints(@saved_reset_rule_kind_check)
  end

  def down do
    replace_rule_kind_constraints(@existing_rule_kind_check)
  end

  defp replace_rule_kind_constraints(rule_kind_check) do
    drop constraint(:alert_rules, :alert_rules_rule_kind_check)
    drop constraint(:alert_incidents, :alert_incidents_rule_kind_check)

    create constraint(:alert_rules, :alert_rules_rule_kind_check, check: rule_kind_check)
    create constraint(:alert_incidents, :alert_incidents_rule_kind_check, check: rule_kind_check)
  end
end
