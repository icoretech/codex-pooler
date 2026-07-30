defmodule CodexPooler.Alerts.StatusVocabulary.Rule do
  @moduledoc false

  @scope_types ~w(pool upstream_identity)
  @rule_kinds ~w(pool_no_usable_assignments pool_low_usable_assignments pool_all_assignments_in_state upstream_quota_threshold upstream_auth_state upstream_saved_reset_banked_first_seen)
  @route_class_rule_kinds ~w(pool_no_usable_assignments pool_low_usable_assignments)
  @severities ~w(info warning critical)
  @states ~w(active disabled)
  @target_states ~w(missing_evidence stale weekly_only exhausted reauth_required refresh_failed)
  @window_selectors ~w(account_primary account_secondary model_primary model_secondary any)
  @cooldown_minimum_minutes 5
  @cooldown_maximum_minutes 1440
  @default_cooldown_minutes 30
  @saved_reset_first_seen_rule_kind "upstream_saved_reset_banked_first_seen"
  @saved_reset_first_seen_baseline_key "saved_reset_first_seen_baseline_at"

  @type scope_type :: String.t()
  @type rule_kind :: String.t()
  @type severity :: String.t()
  @type state :: String.t()
  @type target_state :: String.t()
  @type window_selector :: String.t()

  @spec scope_types() :: [scope_type()]
  def scope_types, do: @scope_types

  @spec rule_kinds() :: [rule_kind()]
  def rule_kinds, do: @rule_kinds

  @spec route_class_rule_kinds() :: [rule_kind()]
  def route_class_rule_kinds, do: @route_class_rule_kinds

  @spec severities() :: [severity()]
  def severities, do: @severities

  @spec states() :: [state()]
  def states, do: @states

  @spec target_states() :: [target_state()]
  def target_states, do: @target_states

  @spec window_selectors() :: [window_selector()]
  def window_selectors, do: @window_selectors

  @spec default_cooldown_minutes() :: pos_integer()
  def default_cooldown_minutes, do: @default_cooldown_minutes

  @spec cooldown_minimum_minutes() :: pos_integer()
  def cooldown_minimum_minutes, do: @cooldown_minimum_minutes

  @spec cooldown_maximum_minutes() :: pos_integer()
  def cooldown_maximum_minutes, do: @cooldown_maximum_minutes

  @spec active_state() :: state()
  def active_state, do: "active"

  @spec disabled_state() :: state()
  def disabled_state, do: "disabled"

  @spec saved_reset_first_seen_rule_kind() :: rule_kind()
  def saved_reset_first_seen_rule_kind, do: @saved_reset_first_seen_rule_kind

  @spec saved_reset_first_seen_baseline_key() :: String.t()
  def saved_reset_first_seen_baseline_key, do: @saved_reset_first_seen_baseline_key
end
