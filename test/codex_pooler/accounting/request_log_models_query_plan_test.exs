defmodule CodexPooler.Accounting.RequestLogModelsQueryPlanTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting
  alias CodexPooler.Repo

  @listed_model_index "requests_pool_listed_model_idx"
  @bulk_rows 2_000

  # The request-log model filter steps through a partial index whose predicate is
  # the filter's own row condition (findings#206 rows 206-373 and 206-389). Every
  # step must state that condition, or PostgreSQL cannot use the index and reads
  # the Pool's history instead; nothing else in the result would change, so the
  # plan is what this test pins.
  test "every model filter step reads the partial listed-model index" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{pool: other_pool, api_key: other_api_key} = active_api_key_fixture()

    for {model, index} <- Enum.with_index(["gpt-plan-alpha", "gpt-plan-beta", "/backend-api/codex/models", "gpt-plan-alpha"]) do
      request_fixture(%{pool: pool, api_key: api_key}, %{requested_model: model, correlation_id: "model-plan-#{index}"})
    end

    request_fixture(%{pool: other_pool, api_key: other_api_key}, %{requested_model: "gpt-plan-other", correlation_id: "model-plan-other"})

    # A Pool's history is long and holds few models. With a handful of rows the listed-model index
    # and `requests_pool_admitted_idx` (read the Pool's rows, then sort them) cost almost the same,
    # and a partition database's earlier rows tipped the planner to the latter (findings#206 row
    # 206-608, Drone 1580). A production-shaped history makes the sort cost what it costs.
    bulk_history!(pool, api_key, @bulk_rows)
    bulk_history!(other_pool, other_api_key, @bulk_rows)

    Repo.query!("ANALYZE requests")

    assert [[reltuples]] = Repo.query!("SELECT reltuples FROM pg_class WHERE oid = 'public.requests'::regclass").rows
    assert reltuples >= 2 * @bulk_rows, "requests statistics are empty (#{reltuples} rows); the plan would be a coin toss"

    {models, [{sql, params}]} = collect_model_list_queries(fn -> Accounting.list_request_log_models(nil, visible_pool_ids: [pool.id, other_pool.id]) end)

    assert models == ["gpt-plan-alpha", "gpt-plan-beta", "gpt-plan-other"]

    # A handful of fixture rows would otherwise be read sequentially; production
    # has a million. Forbid the sequential scan so the planner has to pick an index.
    Repo.query!("SET LOCAL enable_seqscan = off")
    # Plain EXPLAIN on PostgreSQL 18 does not list the recursive step's subplan; EXPLAIN ANALYZE does.
    %{rows: [[[%{"Plan" => plan}]]]} = Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> sql, params)

    request_scans = plan |> plan_nodes() |> Enum.filter(&(&1["Relation Name"] == "requests"))

    # One scan for the first model of each Pool, one for every next model; an
    # index scan names the index itself, a bitmap heap scan through its child.
    assert length(request_scans) == 2

    assert Enum.map(request_scans, fn scan -> scan |> plan_nodes() |> Enum.map(& &1["Index Name"]) |> Enum.reject(&is_nil/1) end) ==
             [[@listed_model_index], [@listed_model_index]]
  end

  # Repeats the models the test already recorded, so the model list stays the same.
  defp bulk_history!(pool, api_key, rows) do
    Repo.query!(
      """
      INSERT INTO requests (pool_id, api_key_id, requested_model, endpoint, transport, correlation_id)
      SELECT $1, $2, (SELECT requested_model FROM requests WHERE pool_id = $1 ORDER BY correlation_id LIMIT 1),
             '/backend-api/codex/responses', 'http_json', 'model-plan-bulk-' || $3 || '-' || g
      FROM generate_series(1, $4) AS g
      """,
      [Ecto.UUID.dump!(pool.id), Ecto.UUID.dump!(api_key.id), pool.id, rows]
    )
  end

  defp collect_model_list_queries(fun) do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok = :telemetry.attach(handler_id, [:codex_pooler, :repo, :query], &__MODULE__.handle_query_event/4, {handler_id, self()})

    try do
      {fun.(), receive_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  def handle_query_event(_event, _measurements, metadata, {handler_id, test_pid}) do
    if self() == test_pid and metadata.query =~ "WITH RECURSIVE models", do: send(test_pid, {handler_id, metadata.query, metadata.params})
  end

  defp receive_queries(handler_id, queries) do
    receive do
      {^handler_id, query, params} -> receive_queries(handler_id, [{query, params} | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp plan_nodes(node), do: [node | Enum.flat_map(Map.get(node, "Plans", []), &plan_nodes/1)]
end
