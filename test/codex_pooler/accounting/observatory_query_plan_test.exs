defmodule CodexPooler.Accounting.ObservatoryQueryPlanTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting.ObservatoryQueryPlanContract, as: Contract
  alias CodexPooler.Accounting.ObservatoryQueryPlanFixture, as: Fixture
  alias CodexPooler.Accounting.ObservatoryQueryPlanReceipt, as: Receipt
  alias CodexPooler.Accounting.ObservatoryQueryPlanSupport, as: Support
  alias CodexPooler.Accounting.Usage.Observatory

  @moduletag timeout: 120_000

  test "representative API-key Observatory plans avoid full fact-table scans" do
    Fixture.set_statement_timeout()

    %{principal: principal, upper_bound: upper_bound, row_count: row_count} =
      Fixture.insert_representative_rows!()

    Fixture.refresh_statistics()

    {{:ok, projection}, queries} =
      Support.collect_observatory_queries(fn ->
        Observatory.read(principal, "1h", as_of: upper_bound)
      end)

    plans = Enum.map(queries, &Support.explain!/1)

    options = [
      projection: projection,
      query_count: length(queries),
      fixture_row_count: row_count
    ]

    checks = Contract.verify!(plans, options)
    assert_raise ArgumentError, fn -> Contract.verify!(without_api_key_scope(plans), options) end

    assert_raise ArgumentError, fn ->
      Contract.verify!(without_required_scope_index(plans), options)
    end

    assert_raise ArgumentError, fn -> Contract.verify!(without_result_limits(plans), options) end

    probes = %{
      "api_key_scope" => "rejected",
      "required_scope_index" => "rejected",
      "result_limit" => "rejected"
    }

    plans
    |> Receipt.build(projection, length(queries), row_count, checks, probes)
    |> Receipt.write_if_requested!()
  end

  defp without_api_key_scope(plans) do
    Support.map_plan_nodes(plans, &remove_api_key_scope/1)
  end

  defp remove_api_key_scope(node) do
    Enum.reduce(["Index Cond", "Recheck Cond", "Filter"], node, fn condition, changed ->
      Map.update(changed, condition, nil, &remove_api_key_id/1)
    end)
  end

  defp remove_api_key_id(value) when is_binary(value),
    do: String.replace(value, "api_key_id", "removed_scope")

  defp remove_api_key_id(value), do: value

  defp without_required_scope_index(plans) do
    Support.map_plan_nodes(plans, fn
      %{"Index Name" => "requests_api_key_pool_admitted_id_idx"} = node ->
        %{node | "Index Name" => "unscoped_test_index"}

      node ->
        node
    end)
  end

  defp without_result_limits(plans) do
    Support.map_plan_nodes(plans, fn
      %{"Node Type" => "Limit"} = node -> %{node | "Node Type" => "Result"}
      node -> node
    end)
  end
end
