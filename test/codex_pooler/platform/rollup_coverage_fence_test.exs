defmodule CodexPooler.RollupCoverageFenceTest do
  @moduledoc """
  Pins `CodexPooler.RollupCoverageFence`, the case-lifecycle fence for `daily_rollup_coverages`.

  The database writes a coverage row whenever a committed request, recorded settlement or Pool
  daily rollup dated before its current UTC day is inserted, moved or deleted. Drone 1507 started
  at 23:55Z and four tests that commit accounting rows left such a row behind at 00:00:00 UTC: one
  had committed a request admitted three minutes earlier, on the previous day, and one deleted
  after midnight a Pool graph it had written before it. Each test here drives one of those two
  shapes through the real accounting path and PostgreSQL's own triggers, proves in its body that
  the row is really written, and relies on the guard to fail it if the fence leaves it behind.
  """
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport, only: [accounting_setup: 0]
  import CodexPooler.UnboxedFixture, only: [register_unboxed_cleanup!: 1, run_unboxed: 1]
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [cleanup_unboxed_pool!: 1]

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.DailyRollupCoverage

  test "a request committed with the previous UTC day's admission time leaves no coverage row" do
    graph = committed_graph!()
    admitted_at = DateTime.add(database_midnight(), -60, :second)
    previous_day = DateTime.to_date(admitted_at)
    assert committed_coverage(previous_day) == nil

    run_unboxed(fn -> settle!(graph, admitted_at) end)

    # The insert trigger compared the admission date with the database clock at commit.
    assert %DailyRollupCoverage{completed_at: nil, mutation_version: 1} =
             committed_coverage(previous_day)
  end

  test "a Pool graph written before 00:00 UTC and deleted after it leaves no coverage row" do
    graph = committed_graph!()
    run_unboxed(fn -> settle!(graph, nil) end)
    previous_day = pass_midnight!(graph)
    assert committed_coverage(previous_day) == nil

    # What the registered cleanup is about to do, inside a transaction that is rolled back: the
    # Pool delete cascades to the rows now dated the previous day and marks it once per row.
    assert {:error, %DailyRollupCoverage{completed_at: nil, mutation_version: marks}} =
             run_unboxed(fn ->
               Repo.transaction(fn ->
                 Repo.query!("DELETE FROM pools WHERE id = $1", [Ecto.UUID.dump!(graph.pool.id)])
                 Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
                 Repo.rollback(Repo.get(DailyRollupCoverage, previous_day))
               end)
             end)

    assert marks >= 3
  end

  test "an unchanged table is read and left alone" do
    conn = :persistent_term.get({CodexPooler.RollupCoverageFence, :conn})
    found = CodexPooler.RollupCoverageFence.snapshot!(conn)

    assert CodexPooler.RollupCoverageFence.restore!(conn, found) == %{deleted: [], restored: []}
  end

  # `accounting_setup/0` derives its unique keys while it commits, so the cleanup is registered
  # straight after the commit, as the other committed accounting tests do.
  defp committed_graph! do
    graph = run_unboxed(fn -> accounting_setup() end)
    register_unboxed_cleanup!(fn -> cleanup_unboxed_pool!(graph) end)
    graph
  end

  # One request through reservation, attempt and a known-usage settlement, so the Pool has a
  # request, a recorded settlement and its daily rollups.
  defp settle!(graph, admitted_at) do
    opts = %{endpoint: "/v1/responses", transport: "http_json", correlation_id: Ecto.UUID.generate()}
    opts = if admitted_at, do: Map.put(opts, :now, admitted_at), else: opts

    {:ok, reserved} =
      Accounting.reserve(graph.auth, graph.model, %{"model" => graph.model.exposed_model_id, "input" => []}, opts)

    {:ok, attempt} = Accounting.create_attempt(reserved.request, graph.assignment)

    {:ok, _finalized} =
      Accounting.finalize_request(reserved.request, attempt, %{
        response_status_code: 200,
        usage: %{status: "usage_known", source: "upstream", input_tokens: 10, output_tokens: 5, total_tokens: 15}
      })

    :ok
  end

  # Midnight passes for this Pool's committed rows: they move to the previous UTC day with
  # triggers off, as if they had been written at 23:59, so nothing is marked until they change.
  defp pass_midnight!(graph) do
    run_unboxed(fn ->
      {:ok, previous_day} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL session_replication_role = replica")
          pool_id = Ecto.UUID.dump!(graph.pool.id)

          %{rows: [[_request_date]]} =
            Repo.query!(
              "UPDATE requests SET admitted_at = admitted_at - interval '1 day' WHERE pool_id = $1 " <>
                "RETURNING (admitted_at AT TIME ZONE 'UTC')::date",
              [pool_id]
            )

          %{num_rows: settlements} =
            Repo.query!("UPDATE ledger_entries SET occurred_at = occurred_at - interval '1 day' WHERE pool_id = $1", [pool_id])

          %{rows: [[rollup_date]]} =
            Repo.query!(
              "UPDATE daily_rollups SET rollup_date = rollup_date - 1 WHERE pool_id = $1 AND dimension_kind = 'pool' " <>
                "RETURNING rollup_date",
              [pool_id]
            )

          Repo.query!("UPDATE daily_rollups SET rollup_date = rollup_date - 1 WHERE pool_id = $1 AND dimension_kind <> 'pool'", [pool_id])
          assert settlements >= 2
          rollup_date
        end)

      previous_day
    end)
  end

  defp database_midnight do
    %{rows: [[midnight]]} =
      run_unboxed(fn -> Repo.query!("SELECT date_trunc('day', clock_timestamp() AT TIME ZONE 'UTC')") end)

    DateTime.from_naive!(midnight, "Etc/UTC")
  end

  defp committed_coverage(date), do: run_unboxed(fn -> Repo.get(DailyRollupCoverage, date) end)
end

defmodule CodexPooler.RollupCoverageFenceRestoreTest do
  @moduledoc """
  The fence writes back a coverage row that existed before the test, content and version
  included, when a commit across 00:00 UTC invalidated it: the production shape of a day the
  00:17 UTC rebuild had already published.
  """
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport, only: [accounting_setup: 0]
  import CodexPooler.UnboxedFixture, only: [register_unboxed_cleanup!: 1, run_unboxed: 1]
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [cleanup_unboxed_pool!: 1]

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.DailyRollupCoverage

  setup_all do
    %{rows: [[midnight]]} =
      run_unboxed(fn -> Repo.query!("SELECT date_trunc('day', clock_timestamp() AT TIME ZONE 'UTC')") end)

    previous_day = midnight |> NaiveDateTime.to_date() |> Date.add(-1)
    register_unboxed_cleanup!(fn -> Repo.delete_all(from c in DailyRollupCoverage, where: c.rollup_date == ^previous_day) end)
    completed_at = NaiveDateTime.add(midnight, 17 * 60, :second)

    run_unboxed(fn ->
      Repo.insert!(%DailyRollupCoverage{
        rollup_date: previous_day,
        contract_version: DailyRollupCoverage.contract_version(),
        completed_at: DateTime.from_naive!(completed_at, "Etc/UTC"),
        mutation_version: 0,
        created_at: DateTime.from_naive!(completed_at, "Etc/UTC"),
        updated_at: DateTime.from_naive!(completed_at, "Etc/UTC")
      })
    end)

    %{previous_day: previous_day, midnight: DateTime.from_naive!(midnight, "Etc/UTC")}
  end

  test "an invalidated published day is written back as it was", %{previous_day: previous_day, midnight: midnight} do
    graph = run_unboxed(fn -> accounting_setup() end)
    register_unboxed_cleanup!(fn -> cleanup_unboxed_pool!(graph) end)
    admitted_at = DateTime.add(midnight, -60, :second)

    run_unboxed(fn ->
      {:ok, _reserved} =
        Accounting.reserve(
          graph.auth,
          graph.model,
          %{"model" => graph.model.exposed_model_id, "input" => []},
          %{endpoint: "/v1/responses", transport: "http_json", correlation_id: Ecto.UUID.generate(), now: admitted_at}
        )
    end)

    assert %DailyRollupCoverage{completed_at: nil, mutation_version: 1} =
             run_unboxed(fn -> Repo.get(DailyRollupCoverage, previous_day) end)
  end
end
