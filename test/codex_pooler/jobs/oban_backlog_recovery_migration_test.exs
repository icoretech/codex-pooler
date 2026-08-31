defmodule CodexPooler.Jobs.ObanBacklogRecoveryMigrationTest do
  use CodexPooler.DataCase, async: false

  alias Ecto.Migration.Runner

  import CodexPooler.PoolerFixtures

  alias CodexPooler.{Jobs, Repo}
  alias CodexPooler.Jobs.CatalogSyncEnqueueWorker

  @migration_version 20_260_831_084_633
  @recovery_marker "catalog_sync_backlog_recovery_v1"
  @jobs_queue "jobs"
  @catalog_sync_worker "CodexPooler.Jobs.CatalogSyncWorker"
  @catalog_sync_enqueue_worker "CodexPooler.Jobs.CatalogSyncEnqueueWorker"
  @unrelated_worker "CodexPooler.Jobs.TokenRefreshWorker"

  test "supersedes only overdue catalog retries and preserves a future enqueuer" do
    now = migration_now()
    active_pool = pool_fixture()
    inactive_pool = pool_fixture(%{status: "disabled", disabled_at: DateTime.add(now, -1, :hour)})
    future_pool = pool_fixture()
    exhausted_pool = pool_fixture()
    non_object_meta_pool = pool_fixture()

    active_catalog =
      insert_job!(
        worker: @catalog_sync_worker,
        args: %{"pool_id" => active_pool.id, "trigger_kind" => "scheduled"},
        attempt: 1,
        scheduled_at: overdue_at(now),
        errors: [%{"attempt" => 1, "error" => "catalog failure"}],
        meta: %{"preserved" => "catalog"}
      )

    inactive_catalog =
      insert_job!(
        worker: @catalog_sync_worker,
        args: %{"pool_id" => inactive_pool.id, "trigger_kind" => "scheduled"},
        attempt: 2,
        scheduled_at: overdue_at(now),
        errors: [%{"attempt" => 2, "error" => "catalog failure"}]
      )

    future_catalog =
      insert_job!(
        worker: @catalog_sync_worker,
        args: %{"pool_id" => future_pool.id, "trigger_kind" => "scheduled"},
        scheduled_at: future_at(now)
      )

    exhausted_catalog =
      insert_job!(
        worker: @catalog_sync_worker,
        args: %{"pool_id" => exhausted_pool.id, "trigger_kind" => "scheduled"},
        attempt: 3,
        max_attempts: 3,
        scheduled_at: overdue_at(now)
      )

    malformed_catalog =
      insert_job!(
        worker: @catalog_sync_worker,
        args: %{"pool_id" => "not-a-uuid"},
        scheduled_at: overdue_at(now)
      )

    missing_pool_catalog =
      insert_job!(
        worker: @catalog_sync_worker,
        args: %{"pool_id" => Ecto.UUID.generate()},
        scheduled_at: overdue_at(now)
      )

    overdue_catalog_enqueue =
      insert_job!(
        worker: @catalog_sync_enqueue_worker,
        args: %{},
        scheduled_at: overdue_at(now),
        errors: [%{"attempt" => 1, "error" => "catalog enqueue failure"}],
        meta: %{"preserved" => "catalog_enqueue"}
      )

    future_catalog_enqueue =
      insert_job!(
        worker: @catalog_sync_enqueue_worker,
        args: %{},
        scheduled_at: future_at(now)
      )

    exhausted_catalog_enqueue =
      insert_job!(
        worker: @catalog_sync_enqueue_worker,
        args: %{},
        attempt: 3,
        max_attempts: 3,
        scheduled_at: overdue_at(now)
      )

    unrelated_retryable =
      insert_job!(
        worker: @unrelated_worker,
        args: %{"upstream_identity_id" => Ecto.UUID.generate()},
        scheduled_at: overdue_at(now)
      )

    terminal_catalog =
      insert_job!(
        state: "completed",
        worker: @catalog_sync_worker,
        args: %{"pool_id" => active_pool.id, "trigger_kind" => "scheduled"},
        attempt: 1,
        scheduled_at: overdue_at(now),
        completed_at: overdue_at(now)
      )

    non_object_meta =
      insert_job!(
        worker: @catalog_sync_worker,
        args: %{"pool_id" => non_object_meta_pool.id, "trigger_kind" => "scheduled"},
        scheduled_at: overdue_at(now),
        meta: %{}
      )

    replace_meta_with_json_array!(non_object_meta)

    assert {:ok, blocked_catalog} = Jobs.enqueue_catalog_sync(active_pool)
    assert blocked_catalog.conflict?
    assert blocked_catalog.id == active_catalog.id

    run_migration!()

    assert_recovered!(active_catalog, "superseded")
    assert_recovered!(inactive_catalog, "superseded")
    assert preserved!(future_catalog)
    assert preserved!(exhausted_catalog)
    assert preserved!(malformed_catalog)
    assert preserved!(missing_pool_catalog)
    assert preserved_non_object_meta!(non_object_meta)

    assert_recovered!(overdue_catalog_enqueue, "superseded")
    assert preserved!(future_catalog_enqueue)
    assert preserved!(exhausted_catalog_enqueue)

    assert catalog_enqueue_replacements() == []

    assert preserved!(unrelated_retryable)
    assert preserved!(terminal_catalog)

    assert {:ok, fresh_catalog} = Jobs.enqueue_catalog_sync(active_pool)
    refute fresh_catalog.conflict?
    assert fresh_catalog.id != active_catalog.id

    snapshot = backlog_snapshot()

    run_migration!()

    assert backlog_snapshot() == snapshot
  end

  test "creates one current catalog enqueuer when recovery leaves no incomplete enqueuer" do
    now = migration_now()
    pool = pool_fixture()

    overdue_catalog =
      insert_job!(
        worker: @catalog_sync_worker,
        args: %{"pool_id" => pool.id, "trigger_kind" => "scheduled"},
        scheduled_at: overdue_at(now)
      )

    overdue_catalog_enqueue =
      insert_job!(
        worker: @catalog_sync_enqueue_worker,
        args: %{},
        scheduled_at: overdue_at(now)
      )

    run_migration!()

    assert_recovered!(overdue_catalog, "superseded")
    assert_recovered!(overdue_catalog_enqueue, "superseded")

    assert [catalog_enqueue_replacement] = catalog_enqueue_replacements()
    assert catalog_enqueue_replacement.state == "available"
    assert catalog_enqueue_replacement.args == %{}
    assert catalog_enqueue_replacement.attempt == 0
    assert catalog_enqueue_replacement.max_attempts == 3
    assert catalog_enqueue_replacement.tags == ["catalog_sync_enqueue"]
    assert recovery_action(catalog_enqueue_replacement) == "replacement"

    assert {:ok, conflicting_enqueue} =
             CatalogSyncEnqueueWorker.new(%{}) |> Oban.insert()

    assert conflicting_enqueue.conflict?
    assert conflicting_enqueue.id == catalog_enqueue_replacement.id

    assert {:ok, fresh_catalog} = Jobs.enqueue_catalog_sync(pool)
    refute fresh_catalog.conflict?
    assert fresh_catalog.id != overdue_catalog.id

    snapshot = backlog_snapshot()
    run_migration!()
    assert backlog_snapshot() == snapshot
    assert Enum.map(catalog_enqueue_replacements(), & &1.id) == [catalog_enqueue_replacement.id]
  end

  defp run_migration! do
    Runner.run(
      Repo,
      Repo.config(),
      @migration_version,
      migration_module(),
      :forward,
      :up,
      :up,
      log: false
    )
  end

  defp migration_module do
    module = CodexPooler.Repo.Migrations.RecoverOverdueObanBacklog

    unless Code.ensure_loaded?(module) do
      Code.require_file(
        "../../../priv/repo/migrations/20260831084633_recover_overdue_oban_backlog.exs",
        __DIR__
      )
    end

    module
  end

  defp insert_job!(attrs) do
    now = migration_now()

    state = Keyword.get(attrs, :state, "retryable")
    scheduled_at = Keyword.fetch!(attrs, :scheduled_at)

    {1, [job]} =
      Repo.insert_all(
        Oban.Job,
        [
          %{
            state: state,
            queue: Keyword.get(attrs, :queue, @jobs_queue),
            worker: Keyword.fetch!(attrs, :worker),
            args: Keyword.fetch!(attrs, :args),
            errors: Keyword.get(attrs, :errors, []),
            attempt: Keyword.get(attrs, :attempt, 1),
            max_attempts: Keyword.get(attrs, :max_attempts, 3),
            inserted_at: Keyword.get(attrs, :inserted_at, now),
            scheduled_at: scheduled_at,
            attempted_at: Keyword.get(attrs, :attempted_at, overdue_at(now)),
            completed_at: Keyword.get(attrs, :completed_at),
            discarded_at: Keyword.get(attrs, :discarded_at),
            cancelled_at: Keyword.get(attrs, :cancelled_at),
            priority: Keyword.get(attrs, :priority, 0),
            tags: Keyword.get(attrs, :tags, []),
            meta: Keyword.get(attrs, :meta, %{})
          }
        ],
        returning: true
      )

    job
  end

  defp assert_recovered!(job, action) do
    recovered = Repo.get!(Oban.Job, job.id)

    assert recovered.state == "cancelled"
    assert %DateTime{} = recovered.cancelled_at
    assert recovered.attempt == job.attempt
    assert recovered.errors == job.errors
    assert recovery_action(recovered) == action
    assert recovery_metadata(recovered)["version"] == 1
    assert recovery_metadata(recovered)["reason"] == "overdue_retryable"

    assert {:ok, _recovered_at, _offset} =
             recovery_metadata(recovered)["recovered_at"] |> DateTime.from_iso8601()
  end

  defp preserved!(job) do
    current = Repo.get!(Oban.Job, job.id)

    assert current.state == job.state
    assert current.cancelled_at == job.cancelled_at
    assert current.meta == job.meta
  end

  defp preserved_non_object_meta!(job) do
    assert %Postgrex.Result{rows: [["retryable", nil, []]]} =
             Repo.query!("SELECT state::text, cancelled_at, meta FROM oban_jobs WHERE id = $1", [
               job.id
             ])

    true
  end

  defp catalog_enqueue_replacements do
    Repo.all(
      from job in Oban.Job,
        where: job.queue == ^@jobs_queue and job.worker == ^@catalog_sync_enqueue_worker,
        where: fragment("? #>> ? = ?", job.meta, ^[@recovery_marker, "action"], "replacement"),
        order_by: [asc: job.id]
    )
  end

  defp backlog_snapshot do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT
          id,
          state::text,
          cancelled_at::text,
          meta::text,
          attempt,
          scheduled_at::text
        FROM oban_jobs
        WHERE worker = ANY($1::text[])
        ORDER BY id ASC
        """,
        [
          [
            @catalog_sync_worker,
            @catalog_sync_enqueue_worker,
            @unrelated_worker
          ]
        ]
      )

    rows
  end

  defp recovery_action(job), do: recovery_metadata(job)["action"]
  defp recovery_metadata(job), do: get_in(job.meta, [@recovery_marker])

  defp replace_meta_with_json_array!(job) do
    assert %{num_rows: 1} =
             Repo.query!("UPDATE oban_jobs SET meta = '[]'::jsonb WHERE id = $1", [job.id])

    :ok
  end

  defp migration_now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end

  defp overdue_at(now), do: DateTime.add(now, -1, :hour)
  defp future_at(now), do: DateTime.add(now, 1, :hour)
end
