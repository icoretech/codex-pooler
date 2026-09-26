defmodule CodexPooler.Accounting.ModelHistoryQueryPlanTest do
  use CodexPooler.DataCase, async: false
  import CodexPooler.PoolerFixtures
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.RequestLogs.ModelHistory
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL

  test "the bounded history read can start at the attempt time index instead of scanning retained history" do
    setup = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(setup.pool)
    request = request_fixture(setup)
    now = DateTime.utc_now()
    old = DateTime.add(now, -30, :day)

    rows =
      for number <- 1..5000 do
        %{id: Ecto.UUID.generate(), request_id: request.id, attempt_number: number, pool_upstream_assignment_id: assignment.id, upstream_identity_id: assignment.upstream_identity_id, started_at: if(number >= 4999, do: DateTime.add(now, -1, :second), else: old), status: if(number == 4999, do: "in_progress", else: "succeeded"), transport: "http_json", upstream_model_id: "model-a"}
      end

    Repo.insert_all(Attempt, rows)
    Repo.query!("ANALYZE attempts")
    query = ModelHistory.query([setup.pool.id], DateTime.add(now, -3600, :second), now, ModelHistory.normalize_filters(%{}))
    {sql, params} = SQL.to_sql(:all, Repo, query)
    %{rows: [[plan]]} = Repo.query!("EXPLAIN (ANALYZE, FORMAT JSON) " <> sql, params)
    assert inspect(plan) =~ "attempts_model_history_started_idx"
    assert Repo.all(query) |> Enum.map(&{&1.attempt_number, &1.status}) |> Enum.sort() == [{4999, "in_progress"}, {5000, "succeeded"}]
  end
end
