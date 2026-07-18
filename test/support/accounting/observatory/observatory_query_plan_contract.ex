defmodule CodexPooler.Accounting.ObservatoryQueryPlanContract do
  @moduledoc false

  alias CodexPooler.Accounting.ObservatoryQueryPlanSupport, as: Support

  @request_index "requests_api_key_pool_admitted_idx"
  # Tokens and cost read from the 1:1 request_log_facts projection. The request is
  # already scoped, so binding the fact by its request_id primary key keeps it a
  # bounded per-request lookup instead of a full scan the planner would then
  # nested-loop by request_id.
  @fact_indexes ["request_log_facts_pkey"]
  @request_predicates ["api_key_id", "pool_id", "admitted_at"]
  @fact_predicates ["request_id"]
  @fact_index_predicates ["request_id"]
  @maximum_scoped_rows 240
  @maximum_relation_work 241
  @minimum_fixture_rows 7_241

  def maximum_relation_work, do: @maximum_relation_work

  def verify!(plans, options) do
    checks = checks(plans, options)

    case Enum.find(checks, fn {_name, passed?} -> not passed? end) do
      nil -> checks
      {name, false} -> raise ArgumentError, "Todo 9 query-plan contract failed: #{name}"
    end
  end

  def checks(plans, options) do
    projection = Keyword.fetch!(options, :projection)
    query_count = Keyword.fetch!(options, :query_count)
    fixture_row_count = Keyword.fetch!(options, :fixture_row_count)
    aggregate_plans = Enum.filter(plans, &(&1.projection in Support.aggregate_projections()))
    outcome_plan = Enum.find(plans, &(&1.projection == :observatory_outcomes))

    %{
      "aggregate_fact_per_request_indexed_join" =>
        Enum.all?(aggregate_plans, fn plan ->
          Support.uses_any_index?(plan.root, @fact_indexes) and
            Support.index_condition_contains?(
              plan.root,
              "request_log_facts",
              @fact_index_predicates
            )
        end),
      "aggregate_request_composite_index_condition" =>
        Enum.all?(aggregate_plans, fn plan ->
          Support.uses_index?(plan.root, @request_index) and
            Support.index_condition_contains?(plan.root, "requests", @request_predicates)
        end),
      "bounded_relation_work" => relation_work_bounded?(plans),
      "bounded_sorts" => sorts_bounded?(plans),
      "bucket_count" => length(projection.buckets) == 12,
      "fact_table_indexed_access" => Support.no_fact_sequential_scans?(plans),
      "fact_scope_predicates_present" =>
        predicates_present_for_all?(plans, "request_log_facts", @fact_predicates),
      "fixture_volume" => fixture_row_count >= @minimum_fixture_rows,
      "outcome_count" => length(projection.outcomes) <= 12,
      "outcome_fact_bounded_indexed_access" =>
        outcome_plan && Support.indexed_access?(outcome_plan.root, "request_log_facts"),
      "outcome_request_bounded_indexed_access" =>
        outcome_plan && Support.indexed_access?(outcome_plan.root, "requests"),
      "projection_set" => Enum.map(plans, & &1.projection) == Support.projections(),
      "query_count" => query_count <= 8,
      "request_scope_predicates_present" =>
        predicates_present_for_all?(plans, "requests", @request_predicates),
      "result_limits" =>
        plans
        |> Enum.filter(&(&1.projection == :observatory_outcomes))
        |> Enum.all?(&Support.has_node_type?(&1.root, "Limit"))
    }
  end

  defp predicates_present_for_all?(plans, relation, predicates) do
    Enum.all?(plans, &Support.predicates_present?(&1.root, relation, predicates))
  end

  defp relation_work_bounded?(plans) do
    Enum.all?(plans, fn plan ->
      Enum.all?(Support.fact_relations(), fn relation ->
        Support.relation_work(plan.root, relation)["total_relation_work"] <=
          @maximum_relation_work
      end)
    end)
  end

  defp sorts_bounded?(plans) do
    Enum.all?(plans, fn plan ->
      plan.root
      |> Support.plan_nodes()
      |> Enum.filter(&(&1["Node Type"] == "Sort"))
      |> Enum.all?(fn node ->
        (node["Actual Rows"] || 0) * (node["Actual Loops"] || 0) <= @maximum_scoped_rows
      end)
    end)
  end
end
