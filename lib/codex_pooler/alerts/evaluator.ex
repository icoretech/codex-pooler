defmodule CodexPooler.Alerts.Evaluator do
  @moduledoc """
  Metadata-only alert rule evaluator built from persisted pool, upstream, and quota evidence.
  """

  import Ecto.Query

  alias CodexPooler.Alerts.IncidentLifecycle
  alias CodexPooler.Alerts.Schemas.AlertRule
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @active "active"
  @disabled_assignment_states ~w(deleted disabled)
  @auth_target_states ~w(reauth_required refresh_failed)

  @type action :: :match | :clear
  @type assignment_state :: String.t()
  @type quota_window_selector :: String.t()
  @type candidate :: %{
          required(:action) => action(),
          required(:dedupe_key) => String.t(),
          required(:rule_id) => Ecto.UUID.t(),
          required(:rule_kind) => AlertRule.rule_kind(),
          optional(:match_attrs) => IncidentLifecycle.match_attrs(),
          optional(:clear_attrs) => IncidentLifecycle.clear_attrs()
        }

  @type evaluation_opts :: keyword() | map()
  @type projection_cache :: %{
          optional({Ecto.UUID.t() | nil, String.t() | nil}) => [map()]
        }

  @spec evaluate_rule(AlertRule.t(), evaluation_opts()) :: [candidate()]
  def evaluate_rule(rule, opts \\ [])

  def evaluate_rule(%AlertRule{state: "disabled"} = rule, opts) do
    timestamp = evaluation_timestamp(opts)

    [clear_candidate(rule, dedupe_key_for_rule(rule, nil), timestamp)]
  end

  def evaluate_rule(%AlertRule{rule_kind: "pool_no_usable_assignments"} = rule, opts) do
    timestamp = evaluation_timestamp(opts)
    projection = pool_projection(rule.pool_id, rule.model, timestamp)
    dedupe_key = dedupe_key_for_rule(rule, nil)

    if projection.usable_assignment_count == 0 do
      [pool_match_candidate(rule, dedupe_key, projection, "no_usable_assignments", timestamp)]
    else
      [clear_candidate(rule, dedupe_key, timestamp)]
    end
  end

  def evaluate_rule(%AlertRule{rule_kind: "pool_low_usable_assignments"} = rule, opts) do
    timestamp = evaluation_timestamp(opts)
    min_usable = rule.min_usable_assignments || 1
    projection = pool_projection(rule.pool_id, rule.model, timestamp)
    dedupe_key = dedupe_key_for_rule(rule, nil)

    if projection.usable_assignment_count > 0 and projection.usable_assignment_count < min_usable do
      [pool_match_candidate(rule, dedupe_key, projection, "low_usable_assignments", timestamp)]
    else
      [clear_candidate(rule, dedupe_key, timestamp)]
    end
  end

  def evaluate_rule(%AlertRule{rule_kind: "pool_all_assignments_in_state"} = rule, opts) do
    timestamp = evaluation_timestamp(opts)
    projection = pool_projection(rule.pool_id, rule.model, timestamp)
    dedupe_key = dedupe_key_for_rule(rule, nil)
    target_state = rule.target_state

    if (target_state && projection.enabled_assignment_count > 0) and
         all_in_state?(projection, target_state) do
      [pool_match_candidate(rule, dedupe_key, projection, target_state, timestamp)]
    else
      [clear_candidate(rule, dedupe_key, timestamp)]
    end
  end

  def evaluate_rule(%AlertRule{rule_kind: "upstream_quota_threshold"} = rule, opts) do
    timestamp = evaluation_timestamp(opts)

    rule.pool_id
    |> enabled_assigned_identity_projections(rule.model, timestamp)
    |> Enum.map(&threshold_candidate(rule, &1, timestamp))
  end

  def evaluate_rule(%AlertRule{rule_kind: "upstream_auth_state"} = rule, opts) do
    timestamp = evaluation_timestamp(opts)

    rule.pool_id
    |> enabled_assigned_identity_projections(rule.model, timestamp)
    |> Enum.map(&auth_state_candidate(rule, &1, timestamp))
  end

  @spec evaluate_active_rules(evaluation_opts()) :: [candidate()]
  def evaluate_active_rules(opts \\ []) do
    timestamp = evaluation_timestamp(opts)

    {candidate_groups, _projection_cache} =
      AlertRule
      |> where([rule], rule.state == "active")
      |> order_by([rule], asc: rule.created_at, asc: rule.id)
      |> Repo.all()
      |> Enum.map_reduce(%{}, fn rule, projection_cache ->
        evaluate_rule_with_projection_cache(rule, timestamp, projection_cache)
      end)

    List.flatten(candidate_groups)
  end

  defp evaluate_rule_with_projection_cache(
         %AlertRule{state: "disabled"} = rule,
         timestamp,
         projection_cache
       ) do
    {[clear_candidate(rule, dedupe_key_for_rule(rule, nil), timestamp)], projection_cache}
  end

  defp evaluate_rule_with_projection_cache(
         %AlertRule{rule_kind: "pool_no_usable_assignments"} = rule,
         timestamp,
         projection_cache
       ) do
    {projection, projection_cache} =
      pool_projection_from_cache(rule.pool_id, rule.model, timestamp, projection_cache)

    dedupe_key = dedupe_key_for_rule(rule, nil)

    candidates =
      if projection.usable_assignment_count == 0 do
        [pool_match_candidate(rule, dedupe_key, projection, "no_usable_assignments", timestamp)]
      else
        [clear_candidate(rule, dedupe_key, timestamp)]
      end

    {candidates, projection_cache}
  end

  defp evaluate_rule_with_projection_cache(
         %AlertRule{rule_kind: "pool_low_usable_assignments"} = rule,
         timestamp,
         projection_cache
       ) do
    min_usable = rule.min_usable_assignments || 1

    {projection, projection_cache} =
      pool_projection_from_cache(rule.pool_id, rule.model, timestamp, projection_cache)

    dedupe_key = dedupe_key_for_rule(rule, nil)

    candidates =
      if projection.usable_assignment_count > 0 and
           projection.usable_assignment_count < min_usable do
        [pool_match_candidate(rule, dedupe_key, projection, "low_usable_assignments", timestamp)]
      else
        [clear_candidate(rule, dedupe_key, timestamp)]
      end

    {candidates, projection_cache}
  end

  defp evaluate_rule_with_projection_cache(
         %AlertRule{rule_kind: "pool_all_assignments_in_state"} = rule,
         timestamp,
         projection_cache
       ) do
    {projection, projection_cache} =
      pool_projection_from_cache(rule.pool_id, rule.model, timestamp, projection_cache)

    dedupe_key = dedupe_key_for_rule(rule, nil)
    target_state = rule.target_state

    candidates =
      if (target_state && projection.enabled_assignment_count > 0) and
           all_in_state?(projection, target_state) do
        [pool_match_candidate(rule, dedupe_key, projection, target_state, timestamp)]
      else
        [clear_candidate(rule, dedupe_key, timestamp)]
      end

    {candidates, projection_cache}
  end

  defp evaluate_rule_with_projection_cache(
         %AlertRule{rule_kind: rule_kind} = rule,
         timestamp,
         projection_cache
       )
       when rule_kind in ["upstream_quota_threshold", "upstream_auth_state"] do
    {assignments, projection_cache} =
      assigned_identity_projections_from_cache(
        rule.pool_id,
        rule.model,
        timestamp,
        projection_cache
      )

    candidates =
      assignments
      |> Enum.reject(&(&1.assignment_status in @disabled_assignment_states))
      |> Enum.map(fn assignment ->
        case rule.rule_kind do
          "upstream_quota_threshold" -> threshold_candidate(rule, assignment, timestamp)
          "upstream_auth_state" -> auth_state_candidate(rule, assignment, timestamp)
        end
      end)

    {candidates, projection_cache}
  end

  defp pool_projection(pool_id, model, timestamp) do
    pool_projection_from_assignments(
      pool_id,
      model,
      assigned_identity_projections(pool_id, model, timestamp)
    )
  end

  defp pool_projection_from_cache(pool_id, model, timestamp, projection_cache) do
    {assignments, projection_cache} =
      assigned_identity_projections_from_cache(pool_id, model, timestamp, projection_cache)

    {pool_projection_from_assignments(pool_id, model, assignments), projection_cache}
  end

  defp pool_projection_from_assignments(pool_id, model, assignments) do
    enabled = Enum.reject(assignments, &(&1.assignment_status in @disabled_assignment_states))
    usable = Enum.filter(enabled, & &1.usable_assignment?)

    %{
      pool_id: pool_id,
      model: model,
      assignment_count: length(assignments),
      enabled_assignment_count: length(enabled),
      usable_assignment_count: length(usable),
      state_counts: Enum.frequencies_by(enabled, & &1.state),
      assignments: assignments
    }
  end

  @spec assigned_identity_projections_from_cache(
          Ecto.UUID.t() | nil,
          String.t() | nil,
          DateTime.t(),
          projection_cache()
        ) :: {[map()], projection_cache()}
  defp assigned_identity_projections_from_cache(pool_id, model, timestamp, projection_cache) do
    cache_key = {pool_id, model}

    case Map.fetch(projection_cache, cache_key) do
      {:ok, assignments} ->
        {assignments, projection_cache}

      :error ->
        assignments = assigned_identity_projections(pool_id, model, timestamp)
        {assignments, Map.put(projection_cache, cache_key, assignments)}
    end
  end

  defp assigned_identity_projections(pool_id, model, timestamp) do
    assignments = assignment_rows(pool_id)

    windows_by_identity_id =
      windows_by_identity_id(Enum.map(assignments, & &1.upstream_identity_id))

    Enum.map(assignments, fn row ->
      windows = Map.get(windows_by_identity_id, row.upstream_identity_id, [])
      quota_projection = quota_projection(windows, model, timestamp)

      Map.merge(row, %{
        model: model,
        quota_windows: windows,
        quota: quota_projection,
        state: assignment_state(row, quota_projection),
        usable_assignment?: usable_assignment?(row, quota_projection)
      })
    end)
  end

  defp enabled_assigned_identity_projections(pool_id, model, timestamp) do
    pool_id
    |> assigned_identity_projections(model, timestamp)
    |> Enum.reject(&(&1.assignment_status in @disabled_assignment_states))
  end

  defp assignment_rows(pool_id) do
    Repo.all(
      from assignment in PoolUpstreamAssignment,
        join: identity in UpstreamIdentity,
        on: identity.id == assignment.upstream_identity_id,
        where: assignment.pool_id == ^pool_id,
        order_by: [asc: assignment.created_at, asc: assignment.id],
        select: %{
          pool_id: assignment.pool_id,
          assignment_id: assignment.id,
          upstream_identity_id: identity.id,
          assignment_status: assignment.status,
          health_status: assignment.health_status,
          eligibility_status: assignment.eligibility_status,
          identity_status: identity.status
        }
    )
  end

  defp windows_by_identity_id([]), do: %{}

  defp windows_by_identity_id(identity_ids) do
    Quota.AccountQuotaWindow
    |> where([window], window.upstream_identity_id in ^identity_ids)
    |> order_by([window],
      asc: window.quota_key,
      asc: window.window_kind,
      asc: window.window_minutes
    )
    |> Repo.all()
    |> Enum.group_by(& &1.upstream_identity_id)
  end

  defp quota_projection(windows, model, timestamp) do
    opts = model_opts(model) ++ [at: timestamp]
    selection = Quota.Windows.quota_window_selection_data_from_windows(windows, opts)
    eligibility = Quota.Windows.routing_quota_eligibility_from_windows(windows, opts)
    state = quota_state(windows, selection, eligibility, timestamp)

    %{
      state: state,
      routing_usable?: eligibility.eligible?,
      window_count: length(windows),
      selector_windows: selection.routing_windows,
      reason_codes: quota_reason_codes(state, selection, eligibility, timestamp)
    }
  end

  defp quota_state([], _selection, _eligibility, _timestamp), do: "missing_evidence"

  defp quota_state(
         _windows,
         _selection,
         %{eligible?: true, routing_state: :credit_backed_probe},
         _timestamp
       ),
       do: "credit_backed_probe"

  defp quota_state(
         _windows,
         _selection,
         %{eligible?: true, routing_state: :weekly_only_probe},
         _timestamp
       ),
       do: "weekly_only"

  defp quota_state(_windows, _selection, %{eligible?: true}, _timestamp), do: "usable"

  defp quota_state(_windows, selection, _eligibility, timestamp) do
    cond do
      exhausted_selection?(selection, timestamp) -> "exhausted"
      stale_selection?(selection, timestamp) -> "stale"
      true -> "missing_evidence"
    end
  end

  defp exhausted_selection?(selection, timestamp) do
    selection.routing_windows
    |> Enum.flat_map(&Quota.Windows.routing_window_reason_codes(&1, timestamp))
    |> Enum.member?("exhausted")
  end

  defp stale_selection?(selection, timestamp) do
    selection.routing_windows
    |> Enum.flat_map(&Quota.Windows.routing_window_reason_codes(&1, timestamp))
    |> Enum.any?(&(&1 in ["expired", "not_fresh"]))
  end

  defp quota_reason_codes("usable", _selection, _eligibility, _timestamp), do: ["quota_usable"]

  defp quota_reason_codes("credit_backed_probe", _selection, _eligibility, _timestamp),
    do: ["credit_backed_probe"]

  defp quota_reason_codes("weekly_only", _selection, _eligibility, _timestamp),
    do: ["weekly_only"]

  defp quota_reason_codes("missing_evidence", %{routing_windows: []}, _eligibility, _timestamp),
    do: ["missing_evidence"]

  defp quota_reason_codes(state, selection, _eligibility, timestamp) do
    reason_codes =
      selection.routing_windows
      |> Enum.flat_map(&Quota.Windows.routing_window_reason_codes(&1, timestamp))
      |> Enum.uniq()

    if reason_codes == [], do: [state], else: [state | reason_codes]
  end

  defp assignment_state(row, _quota) when row.identity_status in @auth_target_states,
    do: row.identity_status

  defp assignment_state(_row, %{state: state}), do: state

  defp usable_assignment?(row, quota) do
    row.assignment_status == @active and row.health_status == @active and
      row.eligibility_status == "eligible" and row.identity_status == @active and
      quota.routing_usable?
  end

  defp all_in_state?(projection, target_state) do
    projection.assignments
    |> Enum.reject(&(&1.assignment_status in @disabled_assignment_states))
    |> Enum.all?(&(&1.state == target_state))
  end

  defp threshold_candidate(rule, assignment, timestamp) do
    dedupe_key = dedupe_key_for_rule(rule, assignment.upstream_identity_id)
    threshold = rule.threshold_used_percent || Decimal.new(100)
    selector = rule.window_selector || "any"
    windows = selected_windows(assignment.quota_windows, selector, rule.model, timestamp)
    match = Enum.find(windows, &threshold_match?(&1, threshold, timestamp))

    if match do
      upstream_match_candidate(rule, dedupe_key, assignment, "quota_threshold", timestamp, %{
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
      clear_candidate(rule, dedupe_key, timestamp)
    end
  end

  defp auth_state_candidate(rule, assignment, timestamp) do
    dedupe_key = dedupe_key_for_rule(rule, assignment.upstream_identity_id)
    target_state = rule.target_state

    if assignment.identity_status == target_state do
      upstream_match_candidate(rule, dedupe_key, assignment, target_state, timestamp, %{
        target_state: target_state,
        identity_status: assignment.identity_status
      })
    else
      clear_candidate(rule, dedupe_key, timestamp)
    end
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

  defp pool_match_candidate(rule, dedupe_key, projection, reason_code, timestamp) do
    match_candidate(rule, dedupe_key, timestamp, %{
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

  defp upstream_match_candidate(rule, dedupe_key, assignment, reason_code, timestamp, metadata) do
    match_candidate(rule, dedupe_key, timestamp, %{
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

  defp match_candidate(rule, dedupe_key, timestamp, attrs) do
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

  defp clear_candidate(rule, dedupe_key, timestamp) do
    %{
      action: :clear,
      dedupe_key: dedupe_key,
      rule_id: rule.id,
      rule_kind: rule.rule_kind,
      clear_attrs: %{dedupe_key: dedupe_key, cleared_at: timestamp}
    }
  end

  defp target(rule, pool_id, metadata) do
    %{rule_id: rule.id, pool_id: pool_id, metadata: stringify_metadata(metadata)}
  end

  defp dedupe_key_for_rule(
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

  defp dedupe_key_for_rule(
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

  defp dedupe_key_for_rule(%AlertRule{} = rule, _upstream_identity_id) do
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

  defp severity_for(%AlertRule{
         rule_kind: "upstream_auth_state",
         target_state: "reauth_required"
       }),
       do: "critical"

  defp severity_for(%AlertRule{severity: severity}), do: severity

  defp model_opts(nil), do: []
  defp model_opts(model), do: [model: model]

  defp evaluation_timestamp(opts) do
    opts = Map.new(opts)
    Map.get(opts, :at) || Map.get(opts, "at") || now()
  end

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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
