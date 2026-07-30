defmodule CodexPooler.Alerts.StatusVocabulary.Incident do
  @moduledoc false

  @scope_types ~w(pool upstream_identity)
  @rule_kinds ~w(pool_no_usable_assignments pool_low_usable_assignments pool_all_assignments_in_state upstream_quota_threshold upstream_auth_state upstream_saved_reset_banked_first_seen)
  @severities ~w(info warning critical)
  @states ~w(open acknowledged resolved)

  @type scope_type :: String.t()
  @type rule_kind :: String.t()
  @type severity :: String.t()
  @type state :: String.t()

  @spec scope_types() :: [scope_type()]
  def scope_types, do: @scope_types

  @spec rule_kinds() :: [rule_kind()]
  def rule_kinds, do: @rule_kinds

  @spec severities() :: [severity()]
  def severities, do: @severities

  @spec states() :: [state()]
  def states, do: @states

  @spec open_state() :: state()
  def open_state, do: "open"

  @spec acknowledged_state() :: state()
  def acknowledged_state, do: "acknowledged"

  @spec resolved_state() :: state()
  def resolved_state, do: "resolved"
end
