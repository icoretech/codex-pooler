defmodule CodexPooler.Alerts.Schemas.AlertRule do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @scope_types ~w(pool upstream_identity)
  @rule_kinds ~w(pool_no_usable_assignments pool_low_usable_assignments pool_all_assignments_in_state upstream_quota_threshold upstream_auth_state)
  @severities ~w(info warning critical)
  @states ~w(active disabled)
  @target_states ~w(missing_evidence stale weekly_only exhausted reauth_required refresh_failed)
  @window_selectors ~w(account_primary account_secondary model_primary model_secondary any)
  @cooldown_minimum_minutes 5
  @cooldown_maximum_minutes 1440
  @default_cooldown_minutes 30

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type scope_type :: String.t()
  @type rule_kind :: String.t()
  @type severity :: String.t()
  @type state :: String.t()
  @type target_state :: String.t()
  @type window_selector :: String.t()

  schema "alert_rules" do
    field :pool_id, :binary_id
    field :scope_type, :string
    field :rule_kind, :string
    field :display_name, :string
    field :severity, :string
    field :cooldown_minutes, :integer, default: @default_cooldown_minutes
    field :state, :string, default: "active"
    field :model, :string
    field :min_usable_assignments, :integer
    field :target_state, :string
    field :window_selector, :string
    field :threshold_used_percent, :decimal
    field :created_by_user_id, :binary_id
    field :disabled_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :pool_id,
      :scope_type,
      :rule_kind,
      :display_name,
      :severity,
      :cooldown_minutes,
      :state,
      :model,
      :min_usable_assignments,
      :target_state,
      :window_selector,
      :threshold_used_percent,
      :created_by_user_id,
      :disabled_at,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> update_change(:display_name, &String.trim/1)
    |> update_change(:model, &trim_optional_string/1)
    |> validate_required([
      :pool_id,
      :scope_type,
      :rule_kind,
      :display_name,
      :severity,
      :cooldown_minutes,
      :state,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> validate_length(:display_name, min: 1)
    |> validate_inclusion(:scope_type, @scope_types)
    |> validate_inclusion(:rule_kind, @rule_kinds)
    |> validate_inclusion(:severity, @severities)
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:target_state, @target_states)
    |> validate_inclusion(:window_selector, @window_selectors)
    |> validate_number(:cooldown_minutes,
      greater_than_or_equal_to: @cooldown_minimum_minutes,
      less_than_or_equal_to: @cooldown_maximum_minutes
    )
    |> validate_number(:min_usable_assignments, greater_than: 0)
    |> validate_number(:threshold_used_percent,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> check_constraint(:scope_type, name: :alert_rules_scope_type_check)
    |> check_constraint(:rule_kind, name: :alert_rules_rule_kind_check)
    |> check_constraint(:severity, name: :alert_rules_severity_check)
    |> check_constraint(:cooldown_minutes, name: :alert_rules_cooldown_minutes_check)
    |> check_constraint(:state, name: :alert_rules_state_check)
    |> check_constraint(:min_usable_assignments, name: :alert_rules_min_usable_assignments_check)
    |> check_constraint(:target_state, name: :alert_rules_target_state_check)
    |> check_constraint(:window_selector, name: :alert_rules_window_selector_check)
    |> check_constraint(:threshold_used_percent, name: :alert_rules_threshold_used_percent_check)
    |> check_constraint(:metadata, name: :alert_rules_metadata_shape_check)
  end

  @spec scope_types() :: [scope_type()]
  def scope_types, do: @scope_types

  @spec rule_kinds() :: [rule_kind()]
  def rule_kinds, do: @rule_kinds

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

  defp trim_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_optional_string(value), do: value
end
