defmodule CodexPoolerWeb.Admin.AlertRuleForm do
  @moduledoc false

  import Phoenix.Component, only: [to_form: 2]

  alias CodexPooler.Alerts.Schemas.AlertRule
  alias CodexPooler.Pools.Pool

  @type option :: {String.t(), String.t()}
  @type attrs :: %{String.t() => term()}

  @default_rule_kind "pool_no_usable_assignments"
  @default_severity "critical"
  @saved_reset_rule_kind "upstream_saved_reset_banked_first_seen"
  @default_state AlertRule.active_state()
  @default_scope_type "pool"

  @rule_kind_options [
    {"No usable assignments", "pool_no_usable_assignments"},
    {"Low usable assignments", "pool_low_usable_assignments"},
    {"All assignments in a state", "pool_all_assignments_in_state"},
    {"Quota threshold on assigned upstreams", "upstream_quota_threshold"},
    {"Upstream auth state", "upstream_auth_state"},
    {"First-seen banked saved reset", @saved_reset_rule_kind}
  ]

  @severity_options [
    {"Info", "info"},
    {"Warning", "warning"},
    {"Critical", "critical"}
  ]

  @state_options [
    {"Enabled", "active"},
    {"Disabled", "disabled"}
  ]

  @assignment_state_options [
    {"Missing quota evidence", "missing_evidence"},
    {"Stale quota evidence", "stale"},
    {"Weekly-only quota evidence", "weekly_only"},
    {"Quota exhausted", "exhausted"},
    {"Reauthorization required", "reauth_required"},
    {"Refresh failed", "refresh_failed"}
  ]

  @auth_state_options [
    {"Reauthorization required", "reauth_required"},
    {"Refresh failed", "refresh_failed"}
  ]

  @window_selector_options [
    {"Any quota window", "any"},
    {"Account primary window", "account_primary"},
    {"Account secondary window", "account_secondary"},
    {"Model primary window", "model_primary"},
    {"Model secondary window", "model_secondary"}
  ]

  @spec create_form([Pool.t()], attrs() | map(), keyword()) :: Phoenix.HTML.Form.t()
  def create_form(pools, attrs \\ %{}, opts \\ []) do
    attrs
    |> default_saved_reset_create_severity()
    |> default_attrs(default_pool_id(pools))
    |> normalize_attrs()
    |> to_form(as: :alert_rule, errors: Keyword.get(opts, :errors, []))
  end

  @spec edit_form(AlertRule.t(), attrs() | map(), keyword()) :: Phoenix.HTML.Form.t()
  def edit_form(%AlertRule{} = rule, attrs \\ %{}, opts \\ []) do
    rule
    |> attrs_from_rule()
    |> Map.merge(Map.new(attrs))
    |> normalize_attrs(default_severity: rule.severity)
    |> to_form(as: :alert_rule, errors: Keyword.get(opts, :errors, []))
  end

  @spec delete_form(AlertRule.t() | nil) :: Phoenix.HTML.Form.t()
  def delete_form(nil), do: to_form(%{"id" => ""}, as: :alert_rule_delete)
  def delete_form(%AlertRule{} = rule), do: to_form(%{"id" => rule.id}, as: :alert_rule_delete)

  @spec normalize_submit(attrs() | map()) :: map()
  def normalize_submit(attrs, opts \\ []) do
    attrs
    |> normalize_attrs(opts)
    |> Map.take([
      "pool_id",
      "scope_type",
      "rule_kind",
      "display_name",
      "severity",
      "cooldown_minutes",
      "state",
      "model",
      "min_usable_assignments",
      "target_state",
      "window_selector",
      "threshold_used_percent"
    ])
    |> drop_blank_optional_values()
  end

  @spec changeset_errors(Ecto.Changeset.t()) :: keyword(String.t())
  def changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset.errors
  end

  @spec pool_options([Pool.t()]) :: [option()]
  def pool_options(pools), do: Enum.map(pools, &{&1.name, &1.id})

  @spec rule_kind_options() :: [option()]
  def rule_kind_options, do: @rule_kind_options

  @spec severity_options() :: [option()]
  def severity_options, do: @severity_options

  @spec state_options() :: [option()]
  def state_options, do: @state_options

  @spec target_state_options(String.t()) :: [option()]
  def target_state_options("upstream_auth_state"), do: @auth_state_options
  def target_state_options(_rule_kind), do: @assignment_state_options

  @spec window_selector_options() :: [option()]
  def window_selector_options, do: @window_selector_options

  @spec rule_kind_label(String.t()) :: String.t()
  def rule_kind_label(value), do: label_for(@rule_kind_options, value, "Alert rule")

  @spec severity_label(String.t()) :: String.t()
  def severity_label(value), do: label_for(@severity_options, value, "Unknown severity")

  @spec state_label(String.t()) :: String.t()
  def state_label(value), do: label_for(@state_options, value, "Unknown state")

  @spec target_state_label(String.t() | nil) :: String.t()
  def target_state_label(nil), do: "Not set"
  def target_state_label(value), do: label_for(@assignment_state_options, value, "Unknown state")

  @spec window_selector_label(String.t() | nil) :: String.t()
  def window_selector_label(nil), do: "Not set"

  def window_selector_label(value),
    do: label_for(@window_selector_options, value, "Unknown window")

  @spec threshold_label(Decimal.t() | nil) :: String.t()
  def threshold_label(nil), do: "Not set"
  def threshold_label(value), do: "#{Decimal.to_string(value, :normal)}%"

  @spec value(Phoenix.HTML.FormField.t()) :: term()
  def value(field), do: field.value

  defp default_pool_id([%Pool{id: pool_id} | _pools]), do: pool_id
  defp default_pool_id(_pools), do: ""

  defp default_attrs(attrs, pool_id) do
    %{
      "pool_id" => pool_id,
      "scope_type" => @default_scope_type,
      "rule_kind" => @default_rule_kind,
      "display_name" => "",
      "severity" =>
        default_severity_for_rule_kind(string_value(attrs, "rule_kind", @default_rule_kind)),
      "cooldown_minutes" => AlertRule.default_cooldown_minutes(),
      "state" => @default_state,
      "model" => "",
      "min_usable_assignments" => "2",
      "target_state" => "missing_evidence",
      "window_selector" => "any",
      "threshold_used_percent" => "80"
    }
    |> Map.merge(Map.new(attrs))
  end

  defp attrs_from_rule(%AlertRule{} = rule) do
    %{
      "id" => rule.id,
      "pool_id" => rule.pool_id,
      "scope_type" => rule.scope_type,
      "rule_kind" => rule.rule_kind,
      "display_name" => rule.display_name,
      "severity" => rule.severity,
      "cooldown_minutes" => rule.cooldown_minutes,
      "state" => rule.state,
      "model" => rule.model || "",
      "min_usable_assignments" => rule.min_usable_assignments || "2",
      "target_state" => rule.target_state || "missing_evidence",
      "window_selector" => rule.window_selector || "any",
      "threshold_used_percent" => threshold_input(rule.threshold_used_percent)
    }
  end

  defp normalize_attrs(attrs, opts \\ []) do
    attrs = Map.new(attrs)
    rule_kind = string_value(attrs, "rule_kind", @default_rule_kind)

    attrs
    |> stringify_keys()
    |> Map.put(
      "rule_kind",
      normalize_option(rule_kind, AlertRule.rule_kinds(), @default_rule_kind)
    )
    |> normalize_rule_kind_fields(opts)
    |> prune_rule_kind_fields()
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_rule_kind_fields(%{"rule_kind" => rule_kind} = attrs, opts) do
    default_severity =
      Keyword.get(opts, :default_severity) || default_severity_for_rule_kind(rule_kind)

    attrs
    |> Map.put("scope_type", scope_type_for(rule_kind))
    |> Map.put(
      "severity",
      normalize_option(
        attrs["severity"],
        AlertRule.severities(),
        default_severity
      )
    )
    |> Map.put("state", normalize_option(attrs["state"], AlertRule.states(), @default_state))
    |> Map.put("target_state", normalize_target_state(rule_kind, attrs["target_state"]))
    |> Map.put("window_selector", normalize_window_selector(attrs["window_selector"]))
  end

  defp normalize_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_value(value), do: value

  defp string_value(attrs, key, default) do
    case Map.get(attrs, key) || Map.get(attrs, known_atom_key(key)) do
      value when is_binary(value) -> String.trim(value)
      nil -> default
      value -> to_string(value)
    end
  end

  defp known_atom_key("rule_kind"), do: :rule_kind
  defp known_atom_key(_key), do: :unknown

  defp normalize_option(value, options, default) when is_binary(value) do
    if value in options, do: value, else: default
  end

  defp normalize_option(_value, _options, default), do: default

  defp scope_type_for(rule_kind)
       when rule_kind in [
              "upstream_quota_threshold",
              "upstream_auth_state",
              @saved_reset_rule_kind
            ],
       do: "upstream_identity"

  defp scope_type_for(_rule_kind), do: "pool"

  defp normalize_target_state("upstream_auth_state", value) do
    normalize_option(value, Enum.map(@auth_state_options, &elem(&1, 1)), "reauth_required")
  end

  defp normalize_target_state(_rule_kind, value) do
    normalize_option(value, AlertRule.target_states(), "missing_evidence")
  end

  defp normalize_window_selector(value),
    do: normalize_option(value, AlertRule.window_selectors(), "any")

  defp prune_rule_kind_fields(%{"rule_kind" => "pool_low_usable_assignments"} = attrs) do
    Map.drop(attrs, ["target_state", "window_selector", "threshold_used_percent"])
  end

  defp prune_rule_kind_fields(%{"rule_kind" => "pool_all_assignments_in_state"} = attrs) do
    Map.drop(attrs, ["min_usable_assignments", "window_selector", "threshold_used_percent"])
  end

  defp prune_rule_kind_fields(%{"rule_kind" => "upstream_quota_threshold"} = attrs) do
    Map.drop(attrs, ["min_usable_assignments", "target_state"])
  end

  defp prune_rule_kind_fields(%{"rule_kind" => "upstream_auth_state"} = attrs) do
    Map.drop(attrs, ["min_usable_assignments", "window_selector", "threshold_used_percent"])
  end

  defp prune_rule_kind_fields(%{"rule_kind" => @saved_reset_rule_kind} = attrs) do
    Map.drop(attrs, [
      "min_usable_assignments",
      "target_state",
      "window_selector",
      "threshold_used_percent"
    ])
  end

  defp prune_rule_kind_fields(attrs) do
    Map.drop(attrs, [
      "min_usable_assignments",
      "target_state",
      "window_selector",
      "threshold_used_percent"
    ])
  end

  defp drop_blank_optional_values(attrs) do
    Enum.reduce(
      [
        "model",
        "min_usable_assignments",
        "target_state",
        "window_selector",
        "threshold_used_percent"
      ],
      attrs,
      fn key, acc ->
        if Map.get(acc, key) in [nil, ""], do: Map.delete(acc, key), else: acc
      end
    )
  end

  defp threshold_input(nil), do: "80"
  defp threshold_input(value), do: Decimal.to_string(value, :normal)

  defp default_saved_reset_create_severity(attrs) do
    attrs = Map.new(attrs)

    if string_value(attrs, "rule_kind", @default_rule_kind) == @saved_reset_rule_kind and
         string_value(attrs, "severity", @default_severity) == @default_severity and
         not targeted_field?(attrs, "severity") do
      Map.put(attrs, "severity", default_severity_for_rule_kind(@saved_reset_rule_kind))
    else
      attrs
    end
  end

  defp default_severity_for_rule_kind(@saved_reset_rule_kind), do: "info"
  defp default_severity_for_rule_kind(_rule_kind), do: @default_severity

  defp targeted_field?(attrs, field) do
    case Map.get(attrs, "_target") || Map.get(attrs, :_target) do
      target when is_list(target) -> to_string(List.last(target)) == field
      _target -> false
    end
  end

  defp label_for(options, value, fallback) do
    options
    |> Enum.find_value(fn {label, option_value} -> option_value == value && label end)
    |> case do
      nil -> fallback
      label -> label
    end
  end
end
