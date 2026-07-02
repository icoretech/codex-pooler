defmodule CodexPooler.Alerts.Evaluator do
  @moduledoc """
  Metadata-only alert rule evaluator built from persisted pool, upstream, and quota evidence.
  """

  import Ecto.Query

  alias CodexPooler.Alerts.{
    EvaluationCandidate,
    EvaluationProjection,
    IncidentLifecycle,
    SavedResetFirstSeenEvaluator
  }

  alias CodexPooler.Alerts.Schemas.AlertRule
  alias CodexPooler.Repo

  @upstream_rule_kinds ~w(
    upstream_quota_threshold
    upstream_auth_state
    upstream_saved_reset_banked_first_seen
  )

  @type action :: :match | :clear
  @type candidate :: %{
          required(:action) => action(),
          required(:dedupe_key) => String.t(),
          required(:rule_id) => Ecto.UUID.t(),
          required(:rule_kind) => AlertRule.rule_kind(),
          optional(:match_attrs) => IncidentLifecycle.match_attrs(),
          optional(:clear_attrs) => IncidentLifecycle.clear_attrs()
        }

  @type evaluation_opts :: keyword() | map()
  @type projection_cache :: EvaluationProjection.projection_cache()

  @spec evaluate_rule(AlertRule.t(), evaluation_opts()) :: [candidate()]
  def evaluate_rule(%AlertRule{} = rule, opts \\ []) do
    timestamp = evaluation_timestamp(opts)
    {candidates, _projection_cache} = evaluate_rule_with_projection_cache(rule, timestamp, %{})

    candidates
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
    candidate =
      rule
      |> EvaluationCandidate.dedupe_key_for_rule(nil)
      |> then(&EvaluationCandidate.clear(rule, &1, timestamp))

    {[candidate], projection_cache}
  end

  defp evaluate_rule_with_projection_cache(
         %AlertRule{rule_kind: "pool_no_usable_assignments"} = rule,
         timestamp,
         projection_cache
       ) do
    {projection, projection_cache} =
      EvaluationProjection.pool_from_cache(rule.pool_id, rule.model, timestamp, projection_cache)

    candidates =
      if projection.usable_assignment_count == 0 do
        [EvaluationCandidate.pool_match(rule, projection, "no_usable_assignments", timestamp)]
      else
        [clear_rule(rule, timestamp)]
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
      EvaluationProjection.pool_from_cache(rule.pool_id, rule.model, timestamp, projection_cache)

    candidates =
      if projection.usable_assignment_count > 0 and
           projection.usable_assignment_count < min_usable do
        [EvaluationCandidate.pool_match(rule, projection, "low_usable_assignments", timestamp)]
      else
        [clear_rule(rule, timestamp)]
      end

    {candidates, projection_cache}
  end

  defp evaluate_rule_with_projection_cache(
         %AlertRule{rule_kind: "pool_all_assignments_in_state"} = rule,
         timestamp,
         projection_cache
       ) do
    {projection, projection_cache} =
      EvaluationProjection.pool_from_cache(rule.pool_id, rule.model, timestamp, projection_cache)

    candidates =
      if (rule.target_state && projection.enabled_assignment_count > 0) and
           EvaluationProjection.all_in_state?(projection, rule.target_state) do
        [EvaluationCandidate.pool_match(rule, projection, rule.target_state, timestamp)]
      else
        [clear_rule(rule, timestamp)]
      end

    {candidates, projection_cache}
  end

  defp evaluate_rule_with_projection_cache(
         %AlertRule{rule_kind: rule_kind} = rule,
         timestamp,
         projection_cache
       )
       when rule_kind in @upstream_rule_kinds do
    {assignments, projection_cache} =
      EvaluationProjection.assigned_identities_from_cache(
        rule.pool_id,
        rule.model,
        timestamp,
        projection_cache
      )

    candidates =
      assignments
      |> Enum.filter(&EvaluationProjection.enabled_assignment?/1)
      |> Enum.flat_map(&upstream_candidates(rule, &1, timestamp))

    {candidates, projection_cache}
  end

  defp upstream_candidates(
         %AlertRule{rule_kind: "upstream_quota_threshold"} = rule,
         assignment,
         timestamp
       ) do
    [EvaluationCandidate.threshold(rule, assignment, timestamp)]
  end

  defp upstream_candidates(
         %AlertRule{rule_kind: "upstream_auth_state"} = rule,
         assignment,
         timestamp
       ) do
    [EvaluationCandidate.auth_state(rule, assignment, timestamp)]
  end

  defp upstream_candidates(
         %AlertRule{rule_kind: "upstream_saved_reset_banked_first_seen"} = rule,
         assignment,
         timestamp
       ) do
    SavedResetFirstSeenEvaluator.candidates(rule, assignment, timestamp)
  end

  defp clear_rule(rule, timestamp) do
    dedupe_key = EvaluationCandidate.dedupe_key_for_rule(rule, nil)
    EvaluationCandidate.clear(rule, dedupe_key, timestamp)
  end

  defp evaluation_timestamp(opts) do
    opts = Map.new(opts)
    Map.get(opts, :at) || Map.get(opts, "at") || now()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
