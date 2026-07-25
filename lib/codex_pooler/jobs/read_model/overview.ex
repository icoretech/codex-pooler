defmodule CodexPooler.Jobs.ReadModel.Overview do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Jobs.{HealthPolicy, ReadModel.FailurePresentation, ReadModel.Query}
  alias CodexPooler.Repo

  @overview_action_buckets [:active_failure, :retry_pressure, :stuck_executing, :backlog_pressure]

  def load(filters, opts \\ []) do
    filters = Query.normalize_explorer_filters(filters)
    now = Query.attention_now(opts)

    {:ok, overview} =
      Repo.transaction(fn ->
        Oban.Job
        |> apply_filters(filters)
        |> Query.job_metadata_query()
        |> order_by([job], desc: job.inserted_at, desc: job.id)
        |> Repo.stream()
        |> Enum.reduce(empty(), &collect_job(&1, &2, now))
        |> finalize()
      end)

    overview
  end

  def empty do
    %{
      status: :empty,
      empty?: true,
      healthy?: false,
      total: 0,
      actionable_count: 0,
      completed_context_count: 0,
      buckets: Map.new(@overview_action_buckets, &{&1, empty_bucket()}),
      completed_context: empty_bucket()
    }
  end

  defp empty_bucket, do: %{count: 0, newest: nil}

  defp apply_filters(queryable, filters) do
    queryable
    |> Query.maybe_filter_explorer_worker(filters.worker)
    |> Query.maybe_filter_explorer_target(filters.target_kind, filters.target_id)
    |> Query.exclude_resolved_failure_jobs_query()
  end

  defp collect_job(job, overview, now) do
    job = job |> FailurePresentation.sanitize_job() |> HealthPolicy.put_attention(now: now)
    overview = %{overview | total: overview.total + 1}

    case job.attention_state do
      attention_state when attention_state in @overview_action_buckets ->
        collect_actionable_job(overview, attention_state, job)

      :healthy_context ->
        collect_completed_context_job(overview, job)

      _other_state ->
        overview
    end
  end

  defp collect_actionable_job(overview, attention_state, job) do
    bucket = Map.fetch!(overview.buckets, attention_state)

    bucket = %{bucket | count: bucket.count + 1, newest: bucket.newest || job}

    %{
      overview
      | actionable_count: overview.actionable_count + 1,
        buckets: Map.put(overview.buckets, attention_state, bucket)
    }
  end

  defp collect_completed_context_job(overview, job) do
    bucket = overview.completed_context

    %{
      overview
      | completed_context_count: overview.completed_context_count + 1,
        completed_context: %{bucket | count: bucket.count + 1, newest: bucket.newest || job}
    }
  end

  defp finalize(%{total: 0} = overview), do: overview

  defp finalize(%{actionable_count: actionable_count} = overview) when actionable_count > 0 do
    %{overview | status: :attention_required, empty?: false, healthy?: false}
  end

  defp finalize(overview), do: %{overview | status: :healthy, empty?: false, healthy?: true}
end
