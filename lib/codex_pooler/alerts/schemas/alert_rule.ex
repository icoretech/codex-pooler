defmodule CodexPooler.Alerts.Schemas.AlertRule do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  alias CodexPooler.Alerts.StatusVocabulary.Rule, as: RuleStatus
  alias CodexPooler.RouteClass

  @scope_types RuleStatus.scope_types()
  @rule_kinds RuleStatus.rule_kinds()
  @route_class_rule_kinds RuleStatus.route_class_rule_kinds()
  @severities RuleStatus.severities()
  @states RuleStatus.states()
  @target_states RuleStatus.target_states()
  @window_selectors RuleStatus.window_selectors()
  @cooldown_minimum_minutes RuleStatus.cooldown_minimum_minutes()
  @cooldown_maximum_minutes RuleStatus.cooldown_maximum_minutes()
  @default_cooldown_minutes RuleStatus.default_cooldown_minutes()
  @saved_reset_first_seen_rule_kind RuleStatus.saved_reset_first_seen_rule_kind()
  @saved_reset_first_seen_baseline_key RuleStatus.saved_reset_first_seen_baseline_key()

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
    field :route_class, :string
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
      :route_class,
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
    |> update_change(:route_class, &trim_optional_string/1)
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
    |> validate_inclusion(:route_class, RouteClass.all())
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
    |> validate_route_class_rule_kind()
    |> check_constraint(:scope_type, name: :alert_rules_scope_type_check)
    |> check_constraint(:rule_kind, name: :alert_rules_rule_kind_check)
    |> check_constraint(:severity, name: :alert_rules_severity_check)
    |> check_constraint(:cooldown_minutes, name: :alert_rules_cooldown_minutes_check)
    |> check_constraint(:state, name: :alert_rules_state_check)
    |> check_constraint(:route_class, name: :alert_rules_route_class_check)
    |> check_constraint(:min_usable_assignments, name: :alert_rules_min_usable_assignments_check)
    |> check_constraint(:target_state, name: :alert_rules_target_state_check)
    |> check_constraint(:window_selector, name: :alert_rules_window_selector_check)
    |> check_constraint(:threshold_used_percent, name: :alert_rules_threshold_used_percent_check)
    |> check_constraint(:metadata, name: :alert_rules_metadata_shape_check)
  end

  @spec scope_types() :: [scope_type()]
  defdelegate scope_types(), to: RuleStatus

  @spec rule_kinds() :: [rule_kind()]
  defdelegate rule_kinds(), to: RuleStatus

  @spec route_classes() :: [RouteClass.t()]
  def route_classes, do: RouteClass.all()

  @spec route_class_rule_kinds() :: [rule_kind()]
  defdelegate route_class_rule_kinds(), to: RuleStatus

  @spec severities() :: [severity()]
  defdelegate severities(), to: RuleStatus

  @spec states() :: [state()]
  defdelegate states(), to: RuleStatus

  @spec target_states() :: [target_state()]
  defdelegate target_states(), to: RuleStatus

  @spec window_selectors() :: [window_selector()]
  defdelegate window_selectors(), to: RuleStatus

  @spec default_cooldown_minutes() :: pos_integer()
  defdelegate default_cooldown_minutes(), to: RuleStatus

  @spec cooldown_minimum_minutes() :: pos_integer()
  defdelegate cooldown_minimum_minutes(), to: RuleStatus

  @spec cooldown_maximum_minutes() :: pos_integer()
  defdelegate cooldown_maximum_minutes(), to: RuleStatus

  @spec active_state() :: state()
  defdelegate active_state(), to: RuleStatus

  @spec disabled_state() :: state()
  defdelegate disabled_state(), to: RuleStatus

  @spec saved_reset_first_seen_baseline_at(t()) :: DateTime.t() | nil
  def saved_reset_first_seen_baseline_at(%__MODULE__{} = rule) do
    if rule.rule_kind == @saved_reset_first_seen_rule_kind do
      metadata_baseline_at(rule.metadata) || rule.created_at
    end
  end

  @spec saved_reset_first_seen_baseline_key() :: String.t()
  defdelegate saved_reset_first_seen_baseline_key(), to: RuleStatus

  defp trim_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_optional_string(value), do: value

  defp validate_route_class_rule_kind(changeset) do
    case {get_field(changeset, :route_class), get_field(changeset, :rule_kind)} do
      {route_class, rule_kind}
      when is_binary(route_class) and rule_kind not in @route_class_rule_kinds ->
        add_error(changeset, :route_class, "is not supported for this rule kind")

      _route_class_and_rule_kind ->
        changeset
    end
  end

  defp metadata_baseline_at(metadata) when is_map(metadata) do
    case Map.get(metadata, @saved_reset_first_seen_baseline_key) ||
           Map.get(metadata, :saved_reset_first_seen_baseline_at) do
      value when is_binary(value) -> parse_datetime(value)
      %DateTime{} = value -> value
      _value -> nil
    end
  end

  defp metadata_baseline_at(_metadata), do: nil

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end
end
