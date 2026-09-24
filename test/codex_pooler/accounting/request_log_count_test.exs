defmodule CodexPooler.Accounting.RequestLogCountTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting

  # The request-log total counted every matching row on every load and live
  # refresh: for the all-Pools page that is the whole request history, about
  # 10M blocks for 600 loads on production (findings#206 row 206-385). A reader
  # may bound it with `:count_limit`: the count stops one row past the limit and
  # says whether the total is exact, so the page can print "more than" instead
  # of a wrong number, and a caller that passes no limit keeps the exact total.
  setup do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{pool: other_pool, api_key: other_key} = active_api_key_fixture()

    requests =
      for index <- 1..5 do
        request_fixture(%{pool: pool, api_key: api_key}, %{status: if(rem(index, 2) == 0, do: "failed", else: "succeeded")})
      end

    request_fixture(%{pool: other_pool, api_key: other_key})
    %{pool: pool, other_pool: other_pool, requests: requests}
  end

  test "a count limit below the matching rows reports the limit as an inexact total", %{pool: pool} do
    assert %{items: items, total: 3, total_exact?: false, limit: 2, offset: 0} = Accounting.list_request_logs(pool, limit: 2, count_limit: 3)
    assert length(items) == 2
  end

  test "a count limit at or above the matching rows reports the exact total", %{pool: pool} do
    for count_limit <- [5, 6, 10_000] do
      assert %{total: 5, total_exact?: true} = Accounting.list_request_logs(pool, count_limit: count_limit)
    end
  end

  test "without a count limit the total stays exact", %{pool: pool} do
    assert %{total: 5, total_exact?: true} = Accounting.list_request_logs(pool)
  end

  test "the bounded count applies the same filters and visible Pools as the page", %{pool: pool, other_pool: other_pool} do
    filters = [status: "failed"]
    assert %{total: 2, total_exact?: true} = Accounting.list_request_logs(pool, filters: filters, count_limit: 10)
    assert %{total: 1, total_exact?: false} = Accounting.list_request_logs(pool, filters: filters, count_limit: 1)

    assert %{total: 6, total_exact?: true} = Accounting.list_request_logs(nil, visible_pool_ids: [pool.id, other_pool.id], count_limit: 10)
    assert %{total: 1, total_exact?: true} = Accounting.list_request_logs(nil, visible_pool_ids: [other_pool.id], count_limit: 10)
    assert %{total: 0, total_exact?: true} = Accounting.list_request_logs(nil, visible_pool_ids: [], count_limit: 10)
  end

  test "the bounded count reads at most one row past the limit", %{pool: pool} do
    {sql, params} = capture_count_query(fn -> Accounting.list_request_logs(pool, count_limit: 3) end)
    assert sql =~ ~r/LIMIT \$\d+/
    assert 4 in params

    %{rows: [[[explain]]]} = Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> sql, params)

    request_rows =
      explain["Plan"]
      |> plan_nodes()
      |> Enum.filter(&(&1["Relation Name"] == "requests"))
      |> Enum.sum_by(&(&1["Actual Rows"] * &1["Actual Loops"]))

    assert request_rows == 4, "the bounded count read #{request_rows} request rows: #{inspect(explain)}"
  end

  defp capture_count_query(fun) do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, pid ->
          if self() == pid and metadata.query =~ "count(", do: send(pid, {:count_query, metadata.query, metadata.params})
        end,
        test_pid
      )

    fun.()
    :telemetry.detach(handler_id)
    assert_received {:count_query, sql, params}
    {sql, params}
  end

  defp plan_nodes(node), do: [node | Enum.flat_map(Map.get(node, "Plans", []), &plan_nodes/1)]
end
