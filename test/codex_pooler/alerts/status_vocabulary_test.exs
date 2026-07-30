defmodule CodexPooler.Alerts.StatusVocabularyTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Alerts.Schemas.{AlertChannel, AlertIncident, AlertRule}
  alias CodexPooler.Alerts.StatusVocabulary.{Channel, Incident, Rule}

  test "alert schemas delegate to dependency-free vocabularies" do
    assert Rule.scope_types() == AlertRule.scope_types()
    assert Rule.rule_kinds() == AlertRule.rule_kinds()
    assert Rule.route_class_rule_kinds() == AlertRule.route_class_rule_kinds()
    assert Rule.severities() == AlertRule.severities()
    assert Rule.states() == AlertRule.states()
    assert Rule.target_states() == AlertRule.target_states()
    assert Rule.window_selectors() == AlertRule.window_selectors()
    assert Rule.default_cooldown_minutes() == AlertRule.default_cooldown_minutes()
    assert Rule.cooldown_minimum_minutes() == AlertRule.cooldown_minimum_minutes()
    assert Rule.cooldown_maximum_minutes() == AlertRule.cooldown_maximum_minutes()

    assert helper_values(Rule, [:active_state, :disabled_state]) == AlertRule.states()

    assert Channel.channel_types() == AlertChannel.channel_types()
    assert Channel.states() == AlertChannel.states()
    assert Channel.endpoint_schemes() == AlertChannel.endpoint_schemes()
    assert helper_values(Channel, [:active_state, :disabled_state]) == AlertChannel.states()

    assert Incident.scope_types() == AlertIncident.scope_types()
    assert Incident.rule_kinds() == AlertIncident.rule_kinds()
    assert Incident.severities() == AlertIncident.severities()
    assert Incident.states() == AlertIncident.states()

    assert helper_values(Incident, [
             :open_state,
             :acknowledged_state,
             :resolved_state
           ]) == AlertIncident.states()
  end

  defp helper_values(module, helpers) do
    Enum.map(helpers, &apply(module, &1, []))
  end
end
