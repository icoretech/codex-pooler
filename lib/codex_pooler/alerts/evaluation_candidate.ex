defmodule CodexPooler.Alerts.EvaluationCandidate do
  @moduledoc """
  Builds generic alert evaluation match/clear candidates and stable dedupe keys.
  """

  alias CodexPooler.Alerts.IncidentLifecycle
  alias CodexPooler.Alerts.Schemas.AlertRule
  alias CodexPooler.Upstreams.Quota

  @type action :: :match | :clear
  @type candidate :: %{
          required(:action) => action(),
          required(:dedupe_key) => String.t(),
          required(:rule_id) => Ecto.UUID.t(),
          required(:rule_kind) => AlertRule.rule_kind(),
          optional(:match_attrs) => IncidentLifecycle.match_attrs(),
          optional(:clear_attrs) => IncidentLifecycle.clear_attrs()
        }

  @spec pool_match(AlertRule.t(), map(), String.t(), DateTime.t()) :: candidate()
  def pool_match(%AlertRule{} = rule, projection, reason_code, %DateTime{} = timestamp) do
    dedupe_key = dedupe_key_for_rule(rule, nil)

    match(rule, dedupe_key, timestamp, %{
      pool_id: rule.pool_id,
      safe_evidence_snapshot: %{
        "reason_code" => reason_code,
        "pool_id" => rule.pool_id,
        "model" => rule.model,
        "assignment_count" => projection.assignment_count,
        "enabled_assignment_count" => projection.enabled_assignment_count,
        "usable_assignment_count" => projection.usable_assignment_count,
        "state_counts" => stringify_count_keys(projection.state_counts),
        "min_usable_assignments" => rule.min_usable_assignments,
        "target_state" => rule.target_state
      },
      targets: [target(rule, rule.pool_id, %{reason_code: reason_code})]
    })
  end

  @spec threshold(AlertRule.t(), map(), DateTime.t()) :: candidate()
  def threshold(%AlertRule{} = rule, assignment, %DateTime{} = timestamp) do
    dedupe_key = dedupe_key_for_rule(rule, assignment.upstream_identity_id)
    threshold = rule.threshold_used_percent || Decimal.new(100)
    selector = rule.window_selector || "any"
    windows = selected_windows(assignment.quota_windows, selector, rule.model, timestamp)
    match = Enum.find(windows, &threshold_match?(&1, threshold, timestamp))

    if match do
      upstream_match(rule, dedupe_key, assignment, "quota_threshold", timestamp, %{
        window_selector: selector,
        threshold_used_percent: decimal_string(threshold),
        used_percent: decimal_float(match.used_percent),
        reset_at: iso8601_or_nil(match.reset_at),
        quota_key: match.quota_key,
        window_kind: match.window_kind,
        quota_scope: match.quota_scope,
        model: match.model,
        upstream_model: match.upstream_model
      })
    else
      clear(rule, dedupe_key, timestamp)
    end
  end

  @spec auth_state(AlertRule.t(), map(), DateTime.t()) :: candidate()
  def auth_state(%AlertRule{} = rule, assignment, %DateTime{} = timestamp) do
    dedupe_key = dedupe_key_for_rule(rule, assignment.upstream_identity_id)
    target_state = rule.target_state

    if assignment.identity_status == target_state do
      upstream_match(rule, dedupe_key, assignment, target_state, timestamp, %{
        target_state: target_state,
        identity_status: assignment.identity_status
      })
    else
      clear(rule, dedupe_key, timestamp)
    end
  end

  @spec clear(AlertRule.t(), String.t(), DateTime.t()) :: candidate()
  def clear(%AlertRule{} = rule, dedupe_key, %DateTime{} = timestamp) do
    %{
      action: :clear,
      dedupe_key: dedupe_key,
      rule_id: rule.id,
      rule_kind: rule.rule_kind,
      clear_attrs: %{dedupe_key: dedupe_key, cleared_at: timestamp}
    }
  end

  @spec dedupe_key_for_rule(AlertRule.t(), Ecto.UUID.t() | nil) :: String.t()
  def dedupe_key_for_rule(
        %AlertRule{rule_kind: "upstream_quota_threshold"} = rule,
        upstream_identity_id
      ) do
    Enum.join(
      [
        "alerts",
        "v1",
        rule.rule_kind,
        "upstream_identity",
        upstream_identity_id || "none",
        "window",
        rule.window_selector || "any",
        "threshold",
        decimal_string(rule.threshold_used_percent || Decimal.new(100)),
        "model",
        rule.model || "any"
      ],
      ":"
    )
  end

  def dedupe_key_for_rule(
        %AlertRule{rule_kind: "upstream_auth_state"} = rule,
        upstream_identity_id
      ) do
    Enum.join(
      [
        "alerts",
        "v1",
        rule.rule_kind,
        "upstream_identity",
        upstream_identity_id || "none",
        "state",
        rule.target_state || "unknown"
      ],
      ":"
    )
  end

  def dedupe_key_for_rule(%AlertRule{} = rule, _upstream_identity_id) do
    Enum.join(
      [
        "alerts",
        "v1",
        rule.rule_kind,
        "pool",
        rule.pool_id,
        "model",
        rule.model || "any",
        "min",
        rule.min_usable_assignments || "none",
        "state",
        rule.target_state || "none"
      ],
      ":"
    )
  end

  defp upstream_match(rule, dedupe_key, assignment, reason_code, timestamp, metadata) do
    match(rule, dedupe_key, timestamp, %{
      upstream_identity_id: assignment.upstream_identity_id,
      safe_evidence_snapshot:
        Map.merge(metadata, %{
          reason_code: reason_code,
          pool_id: rule.pool_id,
          upstream_identity_id: assignment.upstream_identity_id,
          pool_upstream_assignment_id: assignment.assignment_id,
          model: rule.model
        }),
      targets: [target(rule, rule.pool_id, metadata)]
    })
  end

  defp match(rule, dedupe_key, timestamp, attrs) do
    match_attrs = %{
      dedupe_key: dedupe_key,
      scope_type: rule.scope_type,
      rule_kind: rule.rule_kind,
      severity: severity_for(rule),
      pool_id: Map.get(attrs, :pool_id),
      upstream_identity_id: Map.get(attrs, :upstream_identity_id),
      safe_evidence_snapshot: Map.fetch!(attrs, :safe_evidence_snapshot),
      targets: Map.fetch!(attrs, :targets),
      matched_at: timestamp
    }

    %{
      action: :match,
      dedupe_key: dedupe_key,
      rule_id: rule.id,
      rule_kind: rule.rule_kind,
      match_attrs: match_attrs
    }
  end

  defp threshold_match?(%Quota.AccountQuotaWindow{} = window, threshold, timestamp) do
    Quota.Windows.fresh_window?(window, timestamp) and not is_nil(window.used_percent) and
      Decimal.compare(window.used_percent, threshold) != :lt
  end

  defp selected_windows(windows, "any", model, timestamp) do
    opts = model_opts(model) ++ [at: timestamp]

    windows
    |> Quota.Windows.quota_window_selection_data_from_windows(opts)
    |> Map.fetch!(:routing_windows)
  end

  defp selected_windows(windows, selector, model, timestamp) do
    windows
    |> selected_windows("any", model, timestamp)
    |> Enum.filter(&(window_selector(&1) == selector))
  end

  defp window_selector(%Quota.AccountQuotaWindow{} = window) do
    cond do
      model_window?(window) and window.window_kind == "secondary" -> "model_secondary"
      model_window?(window) -> "model_primary"
      window.window_kind == "secondary" -> "account_secondary"
      true -> "account_primary"
    end
  end

  defp model_window?(%Quota.AccountQuotaWindow{} = window) do
    window.quota_scope in ["model", "upstream_model"] or present_string?(window.model) or
      present_string?(window.upstream_model)
  end

  defp target(rule, pool_id, metadata) do
    %{rule_id: rule.id, pool_id: pool_id, metadata: stringify_metadata(metadata)}
  end

  defp severity_for(%AlertRule{
         rule_kind: "upstream_auth_state",
         target_state: "reauth_required"
       }),
       do: "critical"

  defp severity_for(%AlertRule{severity: severity}), do: severity

  defp model_opts(nil), do: []
  defp model_opts(model), do: [model: model]

  defp stringify_count_keys(counts),
    do: Map.new(counts, fn {key, value} -> {to_string(key), value} end)

  defp stringify_metadata(metadata),
    do: Map.new(metadata, fn {key, value} -> {to_string(key), value} end)

  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_string(value) when is_integer(value), do: Integer.to_string(value)

  defp decimal_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp decimal_float(_value), do: nil

  defp iso8601_or_nil(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601_or_nil(_value), do: nil

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
