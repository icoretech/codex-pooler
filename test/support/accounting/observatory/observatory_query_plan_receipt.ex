defmodule CodexPooler.Accounting.ObservatoryQueryPlanReceipt do
  @moduledoc false

  alias CodexPooler.Accounting.ObservatoryQueryPlanContract, as: Contract
  alias CodexPooler.Accounting.ObservatoryQueryPlanSupport, as: Support

  @request_fields ["api_key_id", "pool_id", "admitted_at"]
  @ledger_fields ["api_key_id", "pool_id", "occurred_at"]

  def build(plans, projection, query_count, fixture_row_count, checks, probes) do
    %{
      "checks" => Map.put(checks, "contract", "pass"),
      "fixture_volume" => %{"fact_pairs" => fixture_row_count},
      "invocation" => %{
        "explain" => ["ANALYZE", "BUFFERS", "FORMAT JSON"],
        "local_test_index_normalization" => "fixed_scope_indexes_rebuilt_before_analyze",
        "maximum_relation_work" => Contract.maximum_relation_work(),
        "statement_timeout_seconds" => 30
      },
      "plans" => Enum.map(plans, &summarize_plan/1),
      "projection" => %{
        "bucket_count" => length(projection.buckets),
        "outcome_count" => length(projection.outcomes),
        "query_count" => query_count
      },
      "regression_probes" => probes,
      "result" => "pass"
    }
  end

  def write_if_requested!(receipt) do
    case System.get_env("TODO9_QUERY_PLAN_RECEIPT") do
      path when is_binary(path) and path != "" ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, [Jason.encode_to_iodata!(receipt, pretty: true), "\n"])

      _unset ->
        :ok
    end
  end

  defp summarize_plan(plan) do
    nodes = Support.plan_nodes(plan.root)

    %{
      "buffer_blocks" => %{
        "shared_hit" => plan.root["Shared Hit Blocks"] || 0,
        "shared_read" => plan.root["Shared Read Blocks"] || 0,
        "temporary_read" => plan.root["Temp Read Blocks"] || 0,
        "temporary_written" => plan.root["Temp Written Blocks"] || 0
      },
      "execution_time_ms" => plan.execution_time_ms,
      "fact_access" => %{
        "ledger_entries" => relation_summary(plan.root, "ledger_entries", @ledger_fields),
        "requests" => relation_summary(plan.root, "requests", @request_fields)
      },
      "indexes" =>
        nodes
        |> Enum.map(& &1["Index Name"])
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.sort(),
      "limit_present" => Support.has_node_type?(plan.root, "Limit"),
      "node_types" => nodes |> Enum.map(& &1["Node Type"]) |> Enum.uniq() |> Enum.sort(),
      "planning_time_ms" => plan.planning_time_ms,
      "projection" => Atom.to_string(plan.projection),
      "sort_actual_rows" =>
        nodes
        |> Enum.filter(&(&1["Node Type"] == "Sort"))
        |> Enum.map(&(&1["Actual Rows"] || 0))
    }
  end

  defp relation_summary(root, relation, candidates) do
    %{
      "filter_fields" => Support.condition_fields(root, relation, "Filter", candidates),
      "index_condition_fields" =>
        Support.condition_fields(root, relation, "Index Cond", candidates),
      "indexed_access" => Support.indexed_access?(root, relation),
      "maximum_actual_rows_per_loop" => Support.maximum_actual_rows(root, relation),
      "recheck_condition_fields" =>
        Support.condition_fields(root, relation, "Recheck Cond", candidates),
      "relation_work" => Support.relation_work(root, relation),
      "scope_predicates_present" => Support.predicates_present?(root, relation, candidates)
    }
  end
end
