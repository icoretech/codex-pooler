defmodule CodexPooler.Accounting.ObservatoryQueryPlanSupport do
  @moduledoc false

  alias CodexPooler.Repo

  @fact_relations ["requests", "request_log_facts"]
  @projections [
    :observatory_summary,
    :observatory_buckets,
    :observatory_models,
    :observatory_outcomes
  ]
  @aggregate_projections [:observatory_summary, :observatory_buckets, :observatory_models]
  @condition_fields ["Index Cond", "Recheck Cond", "Filter"]

  def fact_relations, do: @fact_relations
  def projections, do: @projections
  def aggregate_projections, do: @aggregate_projections

  def collect_observatory_queries(fun) do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        &__MODULE__.handle_repo_query_event/4,
        {handler_id, self()}
      )

    try do
      {fun.(), receive_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  def handle_repo_query_event(_event, _measurements, metadata, {handler_id, test_pid}) do
    projection = get_in(metadata, [:options, :reporting_projection])

    if metadata[:repo] == Repo and projection in @projections do
      send(test_pid, {handler_id, projection, metadata.query, metadata.params})
    end
  end

  def explain!({projection, query, params}) do
    result = Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> query, params)
    [document] = result.rows |> hd() |> hd()

    %{
      projection: projection,
      root: document["Plan"],
      planning_time_ms: document["Planning Time"],
      execution_time_ms: document["Execution Time"]
    }
  end

  def plan_nodes(node), do: [node | Enum.flat_map(Map.get(node, "Plans", []), &plan_nodes/1)]

  def relation_nodes(root, relation) do
    root
    |> plan_nodes()
    |> Enum.filter(&(&1["Relation Name"] == relation))
  end

  def condition_fields(root, relation, condition, candidates) do
    root
    |> relation_paths(relation)
    |> Enum.flat_map(&plan_nodes/1)
    |> Enum.map(& &1[condition])
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn text -> Enum.filter(candidates, &String.contains?(text, &1)) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def predicates_present?(root, relation, required) do
    present =
      @condition_fields
      |> Enum.flat_map(&condition_fields(root, relation, &1, required))
      |> MapSet.new()

    Enum.all?(required, &MapSet.member?(present, &1))
  end

  def index_condition_contains?(root, relation, required) do
    present = condition_fields(root, relation, "Index Cond", required) |> MapSet.new()
    Enum.all?(required, &MapSet.member?(present, &1))
  end

  def indexed_access?(root, relation) do
    root
    |> relation_paths(relation)
    |> Enum.any?(fn node -> Enum.any?(plan_nodes(node), &is_binary(&1["Index Name"])) end)
  end

  def uses_index?(root, index_name),
    do: Enum.any?(plan_nodes(root), &(&1["Index Name"] == index_name))

  def uses_any_index?(root, names), do: Enum.any?(names, &uses_index?(root, &1))
  def has_node_type?(root, type), do: Enum.any?(plan_nodes(root), &(&1["Node Type"] == type))

  def maximum_actual_rows(root, relation) do
    case relation_nodes(root, relation) do
      [] -> 0
      nodes -> nodes |> Enum.map(&(&1["Actual Rows"] || 0)) |> Enum.max()
    end
  end

  def relation_work(root, relation) do
    relation_nodes(root, relation)
    |> Enum.reduce(
      %{
        "actual_loops" => [],
        "removed_row_work" => 0,
        "returned_row_work" => 0,
        "total_relation_work" => 0
      },
      fn node, work ->
        loops = node["Actual Loops"] || 0
        returned = (node["Actual Rows"] || 0) * loops
        removed = removed_rows_per_loop(node) * loops

        %{
          "actual_loops" => work["actual_loops"] ++ [loops],
          "removed_row_work" => work["removed_row_work"] + removed,
          "returned_row_work" => work["returned_row_work"] + returned,
          "total_relation_work" => work["total_relation_work"] + returned + removed
        }
      end
    )
  end

  def map_plan_nodes(plans, mutation) do
    Enum.map(plans, &%{&1 | root: map_node(&1.root, mutation)})
  end

  def no_fact_sequential_scans?(plans) do
    Enum.all?(plans, fn plan ->
      Enum.all?(plan_nodes(plan.root), fn node ->
        node["Node Type"] != "Seq Scan" or node["Relation Name"] not in @fact_relations
      end)
    end)
  end

  defp relation_paths(root, relation), do: relation_nodes(root, relation)

  defp removed_rows_per_loop(node) do
    Enum.reduce(node, 0, fn
      {"Rows Removed by " <> _reason, value}, total when is_number(value) -> total + value
      _field, total -> total
    end)
  end

  defp map_node(node, mutation) do
    node
    |> Map.update("Plans", [], &Enum.map(&1, fn child -> map_node(child, mutation) end))
    |> mutation.()
  end

  defp receive_queries(handler_id, queries) do
    receive do
      {^handler_id, projection, query, params} ->
        receive_queries(handler_id, [{projection, query, params} | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
