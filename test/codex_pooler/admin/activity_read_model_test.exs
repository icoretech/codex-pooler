defmodule CodexPooler.Admin.ActivityReadModelTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Admin.ActivityReadModel
  alias CodexPooler.Audit
  alias CodexPooler.Jobs.RuntimeStateCleanupWorker
  alias CodexPooler.Repo

  @started_at ~U[2026-06-02 10:00:00.000000Z]
  @ended_at ~U[2026-06-02 12:00:00.000000Z]

  test "activity_summary_for_pool_ids/3 returns full-window counts and strips internal fields" do
    pool = pool_fixture()

    for index <- 1..12 do
      insert_audit_event!(pool, DateTime.add(@started_at, index, :minute), "pool.update")
    end

    summary = ActivityReadModel.activity_summary_for_pool_ids([pool.id], @started_at, @ended_at)

    assert summary.source_counts == %{audit_events: 12, jobs: 0}

    assert ActivityReadModel.activity_source_counts([pool.id], @started_at, @ended_at) == %{
             audit_events: 12,
             jobs: 0
           }

    assert length(summary.recent_activity) == 10
    assert Enum.all?(summary.recent_activity, &(&1.type == :audit_event))

    refute Enum.any?(summary.recent_activity, &Map.has_key?(&1, :source_total))
    refute Enum.any?(summary.recent_activity, &Map.has_key?(&1, :source_rank))
    refute Enum.any?(summary.recent_activity, &Map.has_key?(&1, :source_order_id))
  end

  test "activity_summary_for_pool_ids/3 returns only audit events when jobs are absent" do
    pool = pool_fixture()

    audit_event = insert_audit_event!(pool, @started_at, "api_key.create")
    insert_audit_event!(pool, DateTime.add(@started_at, 1, :minute), "pool.routing_update")

    summary = ActivityReadModel.activity_summary_for_pool_ids([pool.id], @started_at, @ended_at)

    assert summary.source_counts == %{audit_events: 2, jobs: 0}
    assert Enum.map(summary.recent_activity, & &1.type) == [:audit_event, :audit_event]

    assert Enum.any?(summary.recent_activity, fn row ->
             row.id == audit_event.id and row.pool_id == pool.id and
               row.action == "api_key.create" and
               row.target_type == "pool" and row.outcome == "success"
           end)
  end

  test "activity_summary_for_pool_ids/3 returns only jobs when audit events are absent" do
    pool = pool_fixture()

    first_job = insert_job!(pool, @started_at, state: "available")
    insert_job!(pool, DateTime.add(@started_at, 1, :minute), state: "scheduled")

    summary = ActivityReadModel.activity_summary_for_pool_ids([pool.id], @started_at, @ended_at)

    assert summary.source_counts == %{audit_events: 0, jobs: 2}
    assert Enum.map(summary.recent_activity, & &1.type) == [:job, :job]

    assert Enum.any?(summary.recent_activity, fn row ->
             row.id == first_job.id and row.state == "available" and row.queue == "jobs" and
               row.worker == inspect(RuntimeStateCleanupWorker)
           end)
  end

  test "activity_summary_for_pool_ids/3 defaults counts to zero when neither source has rows" do
    pool = pool_fixture()

    assert ActivityReadModel.activity_summary_for_pool_ids([pool.id], @started_at, @ended_at) ==
             %{
               recent_activity: [],
               source_counts: %{audit_events: 0, jobs: 0}
             }

    assert ActivityReadModel.activity_summary_for_pool_ids([], @started_at, @ended_at) == %{
             recent_activity: [],
             source_counts: %{audit_events: 0, jobs: 0}
           }
  end

  test "activity_summary_for_pool_ids/3 merges mixed sources with deterministic tie ordering" do
    pool = pool_fixture()
    other_pool = pool_fixture()
    tied_at = DateTime.add(@started_at, 30, :minute)

    audit_events = [
      insert_audit_event!(pool, tied_at, "pool.update"),
      insert_audit_event!(pool, tied_at, "pool.routing_update")
    ]

    jobs = [
      insert_job!(pool, tied_at, state: "available"),
      insert_job!(pool, tied_at, state: "scheduled")
    ]

    insert_audit_event!(other_pool, DateTime.add(tied_at, 10, :minute), "pool.delete")
    insert_job!(other_pool, DateTime.add(tied_at, 10, :minute), state: "available")

    summary = ActivityReadModel.activity_summary_for_pool_ids([pool.id], @started_at, @ended_at)

    audit_ids = audit_events |> Enum.map(& &1.id) |> Enum.sort(:desc)
    job_ids = jobs |> Enum.map(& &1.id) |> Enum.sort(:desc)

    assert summary.source_counts == %{audit_events: 2, jobs: 2}

    assert Enum.map(summary.recent_activity, & &1.type) == [
             :audit_event,
             :audit_event,
             :job,
             :job
           ]

    assert summary.recent_activity |> Enum.take(2) |> Enum.map(& &1.id) == audit_ids
    assert summary.recent_activity |> Enum.drop(2) |> Enum.map(& &1.id) == job_ids
  end

  test "activity_summary_for_pool_ids/3 keeps merged top ten correct when jobs dominate newest rows" do
    pool = pool_fixture()

    for index <- 1..4 do
      insert_audit_event!(pool, DateTime.add(@started_at, index, :minute), "pool.update")
    end

    for index <- 1..8 do
      insert_job!(pool, DateTime.add(@started_at, 30 + index, :minute), state: "available")
    end

    summary = ActivityReadModel.activity_summary_for_pool_ids([pool.id], @started_at, @ended_at)

    assert summary.source_counts == %{audit_events: 4, jobs: 8}
    assert length(summary.recent_activity) == 10
    assert summary.recent_activity |> Enum.take(8) |> Enum.all?(&(&1.type == :job))
    assert summary.recent_activity |> Enum.count(&(&1.type == :job)) == 8
    assert summary.recent_activity |> Enum.count(&(&1.type == :audit_event)) == 2
  end

  defp insert_audit_event!(pool, occurred_at, action) do
    assert {:ok, audit_event} =
             Audit.record_system_event(%{
               pool_id: pool.id,
               action: action,
               target_type: "pool",
               target_id: pool.id,
               outcome: "success",
               occurred_at: occurred_at,
               details: %{"safe" => "activity-read-model-test"}
             })

    audit_event
  end

  defp insert_job!(pool, inserted_at, attrs) do
    state = Keyword.fetch!(attrs, :state)
    index = System.unique_integer([:positive])

    assert {:ok, job} =
             %{"pool_id" => pool.id, "index" => index}
             |> RuntimeStateCleanupWorker.new(
               meta: %{"source" => "activity-read-model-test"},
               unique: false
             )
             |> Oban.insert()

    updates = [
      state: state,
      inserted_at: inserted_at,
      scheduled_at: inserted_at
    ]

    {1, _rows} =
      from(job in Oban.Job, where: job.id == ^job.id)
      |> Repo.update_all(set: updates)

    Repo.get!(Oban.Job, job.id)
  end
end
