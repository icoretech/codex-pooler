defmodule CodexPooler.Jobs.ReadModel do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  alias CodexPooler.Jobs.{
    AccountReconciliationWorker,
    ReadModel.Explorer,
    ReadModel.FailurePresentation,
    ReadModel.Overview,
    ReadModel.Query,
    ReadModel.WorkerSummaries,
    TokenRefreshWorker
  }

  @type job_summary :: map()
  @type explorer_job_summary :: map()
  @type explorer_filters :: %{
          optional(:state) => String.t() | nil,
          optional(:worker) => String.t() | nil,
          optional(:attention) => String.t() | nil,
          optional(:target_kind) => String.t() | nil,
          optional(:target_id) => String.t() | nil,
          optional(:page) => pos_integer(),
          optional(:show_completed) => boolean()
        }
  @type explorer_page :: %{
          required(:items) => [explorer_job_summary()],
          required(:total) => non_neg_integer(),
          required(:limit) => pos_integer(),
          required(:offset) => non_neg_integer()
        }
  @type explorer_filter_values :: %{
          required(:workers) => [String.t()]
        }
  @type overview_status :: :attention_required | :healthy | :empty
  @type overview_bucket :: %{
          required(:count) => non_neg_integer(),
          required(:newest) => explorer_job_summary() | nil
        }
  @type jobs_overview :: %{
          required(:status) => overview_status(),
          required(:empty?) => boolean(),
          required(:healthy?) => boolean(),
          required(:total) => non_neg_integer(),
          required(:actionable_count) => non_neg_integer(),
          required(:completed_context_count) => non_neg_integer(),
          required(:buckets) => %{
            required(:active_failure) => overview_bucket(),
            required(:retry_pressure) => overview_bucket(),
            required(:stuck_executing) => overview_bucket(),
            required(:backlog_pressure) => overview_bucket()
          },
          required(:completed_context) => overview_bucket()
        }
  @type worker_job_summary :: %{
          latest: job_summary() | nil,
          latest_success: job_summary() | nil,
          latest_failure: job_summary() | nil,
          pending: job_summary() | nil,
          open: [job_summary()],
          unresolved_failures: [job_summary()]
        }
  @type worker_group_key :: atom() | String.t()
  @type worker_group :: %{
          required(:key) => worker_group_key(),
          required(:workers) => [String.t() | module()]
        }
  @type worker_job_summaries_by_group :: %{optional(worker_group_key()) => worker_job_summary()}
  @type scope_ref :: Scope.t() | :system | term()
  @type pool_ref :: Pool.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type identity_ref :: UpstreamIdentity.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()

  @single_worker_summary_group_key :worker_summary

  @spec list_system_jobs(keyword()) :: [job_summary()]
  def list_system_jobs(opts \\ []) do
    Oban.Job
    |> Query.latest_jobs_query(opts)
    |> Repo.all()
    |> Query.with_attention(opts)
  end

  @spec list_latest_jobs(scope_ref(), keyword()) :: [job_summary()]
  def list_latest_jobs(scope, opts \\ [])

  def list_latest_jobs(%Scope{} = scope, opts) do
    if Pools.owner?(scope), do: list_system_jobs(opts), else: []
  end

  def list_latest_jobs(:system, opts), do: list_system_jobs(opts)
  def list_latest_jobs(_scope, _opts), do: []

  @spec list_explorer_jobs(scope_ref(), explorer_filters(), keyword()) :: explorer_page()
  def list_explorer_jobs(scope, filters, opts \\ [])

  def list_explorer_jobs(%Scope{} = scope, filters, opts) do
    if Pools.owner?(scope),
      do: list_explorer_jobs(:system, filters, opts),
      else: Explorer.empty_page(filters)
  end

  def list_explorer_jobs(:system, filters, opts), do: Explorer.list(filters, opts)
  def list_explorer_jobs(_scope, filters, _opts), do: Explorer.empty_page(filters)

  @spec explorer_filter_values(scope_ref()) :: explorer_filter_values()
  def explorer_filter_values(%Scope{} = scope) do
    if Pools.owner?(scope),
      do: explorer_filter_values(:system),
      else: Explorer.empty_filter_values()
  end

  def explorer_filter_values(:system), do: Explorer.filter_values()
  def explorer_filter_values(_scope), do: Explorer.empty_filter_values()

  @spec jobs_overview(scope_ref(), explorer_filters(), keyword()) :: jobs_overview()
  def jobs_overview(scope, filters, opts \\ [])

  def jobs_overview(%Scope{} = scope, filters, opts) do
    if Pools.owner?(scope), do: jobs_overview(:system, filters, opts), else: Overview.empty()
  end

  def jobs_overview(:system, filters, opts), do: Overview.load(filters, opts)
  def jobs_overview(_scope, _filters, _opts), do: Overview.empty()

  @spec worker_job_summary(scope_ref(), [String.t()]) :: worker_job_summary()
  def worker_job_summary(_scope, []), do: WorkerSummaries.empty_summary()

  def worker_job_summary(scope, workers) do
    scope
    |> worker_job_summaries_by_group([
      %{key: @single_worker_summary_group_key, workers: workers}
    ])
    |> Map.fetch!(@single_worker_summary_group_key)
  end

  @spec worker_job_summaries_by_group(scope_ref(), [worker_group()], keyword()) ::
          worker_job_summaries_by_group()
  def worker_job_summaries_by_group(scope, worker_groups, opts \\ [])

  def worker_job_summaries_by_group(_scope, [], _opts), do: %{}

  def worker_job_summaries_by_group(%Scope{} = scope, worker_groups, opts) do
    if Pools.owner?(scope) do
      worker_job_summaries_by_group(:system, worker_groups, opts)
    else
      WorkerSummaries.empty_by_group(worker_groups)
    end
  end

  def worker_job_summaries_by_group(:system, worker_groups, opts),
    do: WorkerSummaries.load(worker_groups, opts)

  def worker_job_summaries_by_group(_scope, worker_groups, _opts) do
    WorkerSummaries.empty_by_group(worker_groups)
  end

  def list_recent_token_refresh_jobs(identity_or_id, opts \\ []) do
    identity_id = identity_id(identity_or_id)
    limit = opts |> Keyword.get(:limit, 5) |> max(1) |> min(50)

    results =
      Repo.all(
        from job in Oban.Job,
          where:
            job.worker == ^Query.worker_name(TokenRefreshWorker) and
              fragment("?->>?", job.args, "upstream_identity_id") == ^identity_id,
          order_by: [
            desc:
              fragment("COALESCE(?, ?, ?)", job.attempted_at, job.scheduled_at, job.inserted_at)
          ],
          limit: ^limit,
          select: %{
            id: job.id,
            state: job.state,
            worker: job.worker,
            queue: job.queue,
            args: job.args,
            errors: job.errors,
            attempt: job.attempt,
            max_attempts: job.max_attempts,
            inserted_at: job.inserted_at,
            scheduled_at: job.scheduled_at,
            attempted_at: job.attempted_at,
            completed_at: job.completed_at,
            discarded_at: job.discarded_at,
            cancelled_at: job.cancelled_at
          }
      )

    Query.with_attention(results, opts)
  end

  def list_recent_account_reconciliation_jobs(pool_or_id, opts \\ []) do
    pool_id = pool_id(pool_or_id)
    limit = opts |> Keyword.get(:limit, 10) |> max(1) |> min(50)

    results =
      Repo.all(
        from job in Oban.Job,
          where:
            job.worker == ^Query.worker_name(AccountReconciliationWorker) and
              fragment("?->>?", job.args, "pool_id") == ^pool_id,
          order_by: [
            desc:
              fragment("COALESCE(?, ?, ?)", job.attempted_at, job.scheduled_at, job.inserted_at)
          ],
          limit: ^limit,
          select: %{
            id: job.id,
            state: job.state,
            worker: job.worker,
            queue: job.queue,
            args: job.args,
            errors: job.errors,
            attempt: job.attempt,
            max_attempts: job.max_attempts,
            inserted_at: job.inserted_at,
            scheduled_at: job.scheduled_at,
            attempted_at: job.attempted_at,
            completed_at: job.completed_at,
            discarded_at: job.discarded_at,
            cancelled_at: job.cancelled_at
          }
      )

    Query.with_attention(results, opts)
  end

  @spec sanitize_projection(term()) :: term()
  defdelegate sanitize_projection(value), to: FailurePresentation

  defp pool_id(%{id: id}), do: id
  defp pool_id(id) when is_binary(id), do: id
  defp identity_id(%{id: id}), do: id
  defp identity_id(id) when is_binary(id), do: id
  defp identity_id(_id), do: nil
end
