defmodule CodexPooler.Accounting.DailyRollupCoverageRepairTest do
  @moduledoc """
  Pins the scheduled repair of daily rollup coverage.

  The coverage triggers mark a completed UTC day incomplete whenever a request, recorded
  settlement or Pool daily rollup dated on it changes, and the scheduled rebuild used to rebuild
  only the previous day. Production kept two shapes that nothing ever repaired: a day whose
  rebuild never published (no coverage row, rollups maintained only incrementally, so the
  rebuild-only admission counts stay zero) and a day changed after its rebuild (coverage
  incomplete). While either sits inside the seven-day Pool usage window, every render of that
  window falls back to raw rows. These tests drive both shapes through the real accounting path
  and PostgreSQL's own triggers, then run the scheduled worker and the rebuild jobs it enqueues.
  """
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport, only: [accounting_setup: 0]

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{DailyRollup, DailyRollupCoverage}
  alias CodexPooler.Admin.Stats
  alias CodexPooler.Jobs.{DailyRollupRebuildEnqueueWorker, DailyRollupRebuildWorker}

  test "the scheduled pass rebuilds a day whose rebuild never ran and a day changed after its rebuild" do
    setup = accounting_setup()
    today = database_today()
    missed_day = Date.add(today, -3)
    mutated_day = Date.add(today, -2)

    # The day the rebuild never ran for: its rows were written while it was the current day, so
    # nothing marked it, and only the incremental rollups exist.
    without_coverage_triggers(fn -> settle!(setup, missed_day, 1) end)

    # Every other day of the window was rebuilt on schedule, then one of them changed.
    for offset <- 1..6, Date.add(today, -offset) != missed_day do
      assert :ok = perform_job(DailyRollupRebuildWorker, %{"rollup_date" => Date.to_iso8601(Date.add(today, -offset))})
    end

    settle!(setup, mutated_day, 2)
    flush_coverage_triggers!()

    assert Accounting.daily_rollup_coverage_statuses([missed_day, mutated_day]) == %{
             missed_day => :missing,
             mutated_day => :incomplete
           }

    assert pool_admitted(setup.pool.id, missed_day) == 0
    assert seven_day_usage(setup.pool.id).source == :raw_fallback

    assert :ok = perform_job(DailyRollupRebuildEnqueueWorker, %{})

    enqueued = enqueued_rollup_dates()

    for date <- enqueued do
      assert :ok = perform_job(DailyRollupRebuildWorker, %{"rollup_date" => Date.to_iso8601(date)})
    end

    assert Accounting.daily_rollup_coverage_statuses([missed_day, mutated_day]) == %{
             missed_day => :complete,
             mutated_day => :complete
           }

    assert pool_admitted(setup.pool.id, missed_day) == 1
    assert pool_admitted(setup.pool.id, mutated_day) == 1

    covered = seven_day_usage(setup.pool.id)
    raw = seven_day_usage(setup.pool.id, force_raw: true)
    assert covered.source == :daily_rollups_with_raw_tail
    assert covered.summary_by_pool_id == raw.summary_by_pool_id
    assert covered.histogram_by_pool_id == raw.histogram_by_pool_id

    # Newest first, so the days the seven-day window reads go before the 22 lookback days that
    # never had coverage in this database, and one pass takes at most four of them.
    assert Enum.take(enqueued, 2) == [mutated_day, missed_day]
    assert length(enqueued) == 4
  end

  test "a pass selects newest days first, bounded by the lookback and the batch limit" do
    today = database_today()
    complete_through!(today, 28)
    beyond_lookback = Date.add(today, -29)
    incomplete = Date.add(today, -5)
    incompatible = Date.add(today, -9)
    premature = Date.add(today, -1)
    missing = Date.add(today, -20)

    put_coverage!(beyond_lookback, completed_at: nil)
    put_coverage!(incomplete, completed_at: nil)
    put_coverage!(incompatible, contract_version: DailyRollupCoverage.contract_version() + 1)
    # Published while the day was still current: later writes to that day never marked it.
    put_coverage!(premature, completed_at: DateTime.new!(premature, ~T[12:00:00.000000], "Etc/UTC"))
    Repo.delete_all(from coverage in DailyRollupCoverage, where: coverage.rollup_date == ^missing)

    assert Accounting.daily_rollup_dates_needing_rebuild(limit: 10) == [premature, incomplete, incompatible, missing]
    assert Accounting.daily_rollup_dates_needing_rebuild() == [premature, incomplete, incompatible, missing]
    assert Accounting.daily_rollup_dates_needing_rebuild(limit: 2) == [premature, incomplete]
    assert Accounting.daily_rollup_dates_needing_rebuild(lookback_days: 29, limit: 10) == [premature, incomplete, incompatible, missing, beyond_lookback]
  end

  test "a pass over complete coverage enqueues nothing, and a day already queued is not queued twice" do
    today = database_today()
    complete_through!(today, 28)

    assert :ok = perform_job(DailyRollupRebuildEnqueueWorker, %{})
    assert enqueued_rollup_dates() == []

    missing = Date.add(today, -4)
    Repo.delete_all(from coverage in DailyRollupCoverage, where: coverage.rollup_date == ^missing)

    assert :ok = perform_job(DailyRollupRebuildEnqueueWorker, %{})
    assert :ok = perform_job(DailyRollupRebuildEnqueueWorker, %{})
    assert enqueued_rollup_dates() == [missing]
  end

  defp settle!(setup, date, second) do
    admitted_at = DateTime.new!(date, Time.new!(12, 0, second, {0, 6}), "Etc/UTC")
    opts = %{endpoint: "/v1/responses", transport: "http_json", correlation_id: Ecto.UUID.generate(), now: admitted_at}

    {:ok, reserved} =
      Accounting.reserve(setup.auth, setup.model, %{"model" => setup.model.exposed_model_id, "input" => []}, opts)

    {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    {:ok, _finalized} =
      Accounting.finalize_request(reserved.request, attempt, %{
        response_status_code: 200,
        usage: %{
          status: "usage_known",
          source: "upstream",
          input_tokens: 10,
          output_tokens: 5,
          total_tokens: 15,
          recorded_at: DateTime.add(admitted_at, 5, :second)
        }
      })

    :ok
  end

  # Writes made while the triggers are off are never queued, like writes to a day that was
  # still the current UTC day when they committed.
  defp without_coverage_triggers(fun) do
    Repo.query!("SET session_replication_role = replica")

    try do
      fun.()
    after
      Repo.query!("SET session_replication_role = origin")
    end
  end

  defp flush_coverage_triggers! do
    Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
    Repo.query!("SET CONSTRAINTS ALL DEFERRED")
  end

  defp database_today do
    %{rows: [[today]]} = Repo.query!("SELECT (clock_timestamp() AT TIME ZONE 'UTC')::date")
    today
  end

  defp complete_through!(today, days) do
    Enum.each(1..days, fn offset ->
      date = Date.add(today, -offset)
      put_coverage!(date, completed_at: DateTime.new!(Date.add(date, 1), ~T[00:17:00.000000], "Etc/UTC"))
    end)
  end

  defp put_coverage!(date, attrs) do
    completed_at = Keyword.get(attrs, :completed_at, DateTime.new!(Date.add(date, 1), ~T[00:17:00.000000], "Etc/UTC"))
    stamped_at = completed_at || DateTime.new!(Date.add(date, 1), ~T[00:17:00.000000], "Etc/UTC")

    Repo.insert!(
      %DailyRollupCoverage{
        rollup_date: date,
        contract_version: Keyword.get(attrs, :contract_version, DailyRollupCoverage.contract_version()),
        completed_at: completed_at,
        mutation_version: if(completed_at, do: 0, else: 1),
        created_at: stamped_at,
        updated_at: stamped_at
      },
      on_conflict: {:replace, [:contract_version, :completed_at, :mutation_version, :updated_at]},
      conflict_target: :rollup_date
    )
  end

  defp enqueued_rollup_dates do
    [worker: DailyRollupRebuildWorker]
    |> all_enqueued()
    |> Enum.map(&Date.from_iso8601!(&1.args["rollup_date"]))
    |> Enum.sort({:desc, Date})
  end

  defp pool_admitted(pool_id, date) do
    DailyRollup
    |> where([rollup], rollup.pool_id == ^pool_id and rollup.rollup_date == ^date and rollup.dimension_kind == "pool")
    |> select([rollup], rollup.admitted_request_count)
    |> Repo.one()
  end

  defp seven_day_usage(pool_id, opts \\ []) do
    Stats.pool_usage_by_pool_ids([pool_id], [traffic_window: "7d", histogram_pool_ids: [pool_id]] ++ opts)
  end
end
