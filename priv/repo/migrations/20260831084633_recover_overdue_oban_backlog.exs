defmodule CodexPooler.Repo.Migrations.RecoverOverdueObanBacklog do
  use Ecto.Migration

  @recovery_marker "catalog_sync_backlog_recovery_v1"
  @jobs_queue "jobs"
  @catalog_sync_worker "CodexPooler.Jobs.CatalogSyncWorker"
  @catalog_sync_enqueue_worker "CodexPooler.Jobs.CatalogSyncEnqueueWorker"
  @incomplete_job_states ~w(available executing retryable scheduled suspended)
  @uuid_pattern "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"

  def up do
    # The old release can still be processing jobs while the migration release
    # starts. Serialize state changes and unique inserts against those writes.
    query!("LOCK TABLE public.oban_jobs IN SHARE ROW EXCLUSIVE MODE", [])

    recovery_timestamp = database_timestamp()
    recovered_at = DateTime.from_naive!(recovery_timestamp, "Etc/UTC")

    cancelled_count =
      supersede_overdue_catalog_syncs(recovery_timestamp, recovered_at) +
        supersede_overdue_catalog_enqueues(recovery_timestamp, recovered_at)

    if cancelled_count > 0 do
      insert_current_catalog_enqueue(recovery_timestamp, recovered_at)
    end
  end

  def down do
    # This deliberately preserves the terminal history written by the repair.
    # A corrective release, rather than a migration rollback, owns any future
    # recovery policy change.
    :ok
  end

  defp supersede_overdue_catalog_syncs(recovery_timestamp, recovered_at) do
    query!(
      """
      UPDATE public.oban_jobs AS job
      SET
        state = 'cancelled',
        cancelled_at = $1,
        meta = COALESCE(job.meta, '{}'::jsonb) || $2::jsonb
      WHERE job.queue = $3
        AND job.worker = $4
        AND job.state = 'retryable'
        AND job.scheduled_at <= $1
        AND job.attempt < job.max_attempts
        AND jsonb_typeof(job.args) = 'object'
        AND (job.meta IS NULL OR jsonb_typeof(job.meta) = 'object')
        AND NOT (COALESCE(job.meta, '{}'::jsonb) ? $5)
        AND EXISTS (
          SELECT 1
          FROM public.pools AS pool
          WHERE pool.id = CASE
              WHEN job.args ->> 'pool_id' ~* $6 THEN (job.args ->> 'pool_id')::uuid
            END
        )
      """,
      [
        recovery_timestamp,
        recovery_metadata("superseded", recovered_at),
        @jobs_queue,
        @catalog_sync_worker,
        @recovery_marker,
        @uuid_pattern
      ]
    ).num_rows
  end

  defp supersede_overdue_catalog_enqueues(recovery_timestamp, recovered_at) do
    query!(
      """
      UPDATE public.oban_jobs AS job
      SET
        state = 'cancelled',
        cancelled_at = $1,
        meta = COALESCE(job.meta, '{}'::jsonb) || $2::jsonb
      WHERE job.queue = $3
        AND job.worker = $4
        AND job.state = 'retryable'
        AND job.scheduled_at <= $1
        AND job.attempt < job.max_attempts
        AND jsonb_typeof(job.args) = 'object'
        AND (job.meta IS NULL OR jsonb_typeof(job.meta) = 'object')
        AND NOT (COALESCE(job.meta, '{}'::jsonb) ? $5)
      """,
      [
        recovery_timestamp,
        recovery_metadata("superseded", recovered_at),
        @jobs_queue,
        @catalog_sync_enqueue_worker,
        @recovery_marker
      ]
    ).num_rows
  end

  defp insert_current_catalog_enqueue(recovery_timestamp, recovered_at) do
    query!(
      """
      INSERT INTO public.oban_jobs (
        state,
        queue,
        worker,
        args,
        errors,
        attempt,
        max_attempts,
        inserted_at,
        scheduled_at,
        priority,
        tags,
        meta
      )
      SELECT
        'available',
        $2,
        $3,
        '{}'::jsonb,
        ARRAY[]::jsonb[],
        0,
        3,
        $1,
        $1,
        0,
        ARRAY['catalog_sync_enqueue']::text[],
        $4::jsonb
      WHERE NOT EXISTS (
          SELECT 1
          FROM public.oban_jobs AS current_job
          WHERE current_job.queue = $2
            AND current_job.worker = $3
            AND current_job.state::text = ANY($5::text[])
        )
      """,
      [
        recovery_timestamp,
        @jobs_queue,
        @catalog_sync_enqueue_worker,
        recovery_metadata("replacement", recovered_at),
        @incomplete_job_states
      ]
    )
  end

  defp recovery_metadata(action, recovered_at) do
    %{
      @recovery_marker => %{
        "version" => 1,
        "action" => action,
        "reason" => "overdue_retryable",
        "recovered_at" => DateTime.to_iso8601(recovered_at)
      }
    }
  end

  defp database_timestamp do
    %{rows: [[timestamp]]} =
      query!("SELECT timezone('UTC', transaction_timestamp())", [])

    timestamp
  end

  defp query!(sql, params) do
    repo().query!(sql, params, log: false)
  end
end
