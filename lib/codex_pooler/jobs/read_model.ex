defmodule CodexPooler.Jobs.ReadModel do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  alias CodexPooler.Jobs.{
    AccountReconciliationWorker,
    TokenRefreshWorker
  }

  @admin_jobs_default_limit 15
  @admin_jobs_max_limit 50

  @type job_summary :: map()
  @type worker_job_summary :: %{
          latest: job_summary() | nil,
          latest_success: job_summary() | nil,
          latest_failure: job_summary() | nil,
          pending: job_summary() | nil,
          active: [job_summary()],
          unresolved_failures: [job_summary()]
        }
  @type scope_ref :: Scope.t() | :system | term()
  @type pool_ref :: Pool.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type identity_ref :: UpstreamIdentity.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()

  @spec list_system_jobs(keyword()) :: [job_summary()]
  def list_system_jobs(opts \\ []) do
    Oban.Job
    |> latest_jobs_query(opts)
    |> Repo.all()
  end

  @spec list_latest_jobs(scope_ref(), keyword()) :: [job_summary()]
  def list_latest_jobs(scope, opts \\ [])

  def list_latest_jobs(%Scope{} = scope, opts) do
    if Pools.owner?(scope), do: list_system_jobs(opts), else: []
  end

  def list_latest_jobs(:system, opts) do
    list_system_jobs(opts)
  end

  def list_latest_jobs(_scope, _opts), do: []

  @spec worker_job_summary(scope_ref(), [String.t()]) :: worker_job_summary()
  def worker_job_summary(scope, workers)

  def worker_job_summary(_scope, []), do: empty_worker_job_summary()

  def worker_job_summary(%Scope{} = scope, workers) do
    if Pools.owner?(scope) do
      worker_job_summary(:system, workers)
    else
      empty_worker_job_summary()
    end
  end

  def worker_job_summary(:system, workers) do
    Oban.Job
    |> worker_job_summary_query(workers)
  end

  def worker_job_summary(_scope, _workers), do: empty_worker_job_summary()

  @spec list_recent_token_refresh_jobs(identity_ref(), keyword()) :: [job_summary()]
  def list_recent_token_refresh_jobs(identity_or_id, opts \\ []) do
    identity_id = identity_id(identity_or_id)
    limit = opts |> Keyword.get(:limit, 5) |> max(1) |> min(50)

    Repo.all(
      from job in Oban.Job,
        where:
          job.worker == ^worker_name(TokenRefreshWorker) and
            fragment("?->>?", job.args, "upstream_identity_id") == ^identity_id,
        order_by: [
          desc: fragment("COALESCE(?, ?, ?)", job.attempted_at, job.scheduled_at, job.inserted_at)
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
  end

  @spec list_recent_account_reconciliation_jobs(pool_ref(), keyword()) :: [job_summary()]
  def list_recent_account_reconciliation_jobs(pool_or_id, opts \\ []) do
    pool_id = pool_id(pool_or_id)
    limit = opts |> Keyword.get(:limit, 10) |> max(1) |> min(50)

    Repo.all(
      from job in Oban.Job,
        where:
          job.worker == ^worker_name(AccountReconciliationWorker) and
            fragment("?->>?", job.args, "pool_id") == ^pool_id,
        order_by: [
          desc: fragment("COALESCE(?, ?, ?)", job.attempted_at, job.scheduled_at, job.inserted_at)
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
  end

  defp where_worker_in(queryable, workers) do
    from job in queryable, where: job.worker in ^workers
  end

  defp worker_job_summary_query(queryable, workers) do
    queryable = where_worker_in(queryable, workers)

    %{
      latest: queryable |> latest_worker_job_query() |> Repo.one(),
      latest_success: queryable |> latest_worker_job_query(state: "completed") |> Repo.one(),
      latest_failure:
        queryable |> latest_worker_job_query(states: failure_states()) |> Repo.one(),
      pending: queryable |> next_pending_worker_job_query() |> Repo.one(),
      active: queryable |> active_worker_jobs_query() |> Repo.all(),
      unresolved_failures: queryable |> unresolved_failure_worker_jobs_query() |> Repo.all()
    }
  end

  defp latest_worker_job_query(queryable, opts \\ []) do
    queryable
    |> maybe_where_states(opts)
    |> job_metadata_query()
    |> order_by([job], desc: job.inserted_at, desc: job.id)
    |> limit(1)
  end

  defp next_pending_worker_job_query(queryable) do
    queryable
    |> where([job], job.state in ^pending_states())
    |> job_metadata_query()
    |> order_by([job], asc: job.scheduled_at, desc: job.id)
    |> limit(1)
  end

  defp active_worker_jobs_query(queryable) do
    queryable
    |> where([job], job.state in ^pending_states())
    |> job_metadata_query()
    |> order_by([job], asc: job.scheduled_at, desc: job.id)
  end

  defp unresolved_failure_worker_jobs_query(queryable) do
    queryable
    |> where([job], job.state in ^failure_states())
    |> where(
      [job],
      fragment(
        """
        NOT EXISTS (
          SELECT 1
          FROM oban_jobs resolved
          WHERE resolved.worker = ?
            AND resolved.state = 'completed'
            AND (
              resolved.inserted_at > ?
              OR (resolved.inserted_at = ? AND resolved.id > ?)
            )
            AND COALESCE(resolved.args->>'pool_id', '') = COALESCE(?->>'pool_id', '')
            AND COALESCE(resolved.args->>'pool_upstream_assignment_id', '') = COALESCE(?->>'pool_upstream_assignment_id', '')
            AND COALESCE(resolved.args->>'upstream_identity_id', '') = COALESCE(?->>'upstream_identity_id', '')
            AND COALESCE(resolved.args->>'api_key_id', '') = COALESCE(?->>'api_key_id', '')
            AND COALESCE(resolved.args->>'rollup_date', '') = COALESCE(?->>'rollup_date', '')
        )
        """,
        job.worker,
        job.inserted_at,
        job.inserted_at,
        job.id,
        job.args,
        job.args,
        job.args,
        job.args,
        job.args
      )
    )
    |> job_metadata_query()
    |> order_by([job], desc: job.inserted_at, desc: job.id)
  end

  defp maybe_where_states(queryable, state: state) do
    from job in queryable, where: job.state == ^state
  end

  defp maybe_where_states(queryable, states: states) do
    from job in queryable, where: job.state in ^states
  end

  defp maybe_where_states(queryable, _opts), do: queryable

  defp pending_states, do: ["available", "scheduled", "executing", "retryable"]
  defp failure_states, do: ["discarded", "retryable", "cancelled"]

  defp empty_worker_job_summary do
    %{
      latest: nil,
      latest_success: nil,
      latest_failure: nil,
      pending: nil,
      active: [],
      unresolved_failures: []
    }
  end

  defp latest_jobs_query(queryable, opts) do
    limit =
      opts
      |> Keyword.get(:limit, @admin_jobs_default_limit)
      |> max(1)
      |> min(@admin_jobs_max_limit)

    queryable
    |> job_metadata_query()
    |> order_by([job], desc: job.inserted_at, desc: job.id)
    |> limit(^limit)
  end

  defp job_metadata_query(queryable) do
    from job in queryable,
      left_join: pool in Pool,
      on: fragment("?->>?", job.args, "pool_id") == type(pool.id, :string),
      left_join: assignment in PoolUpstreamAssignment,
      on:
        fragment("?->>?", job.args, "pool_upstream_assignment_id") ==
          type(assignment.id, :string),
      left_join: assignment_identity in UpstreamIdentity,
      on: assignment.upstream_identity_id == assignment_identity.id,
      left_join: direct_identity in UpstreamIdentity,
      on:
        fragment("?->>?", job.args, "upstream_identity_id") == type(direct_identity.id, :string),
      left_join: api_key in APIKey,
      on: fragment("?->>?", job.args, "api_key_id") == type(api_key.id, :string),
      select: %{
        id: job.id,
        worker: job.worker,
        queue: job.queue,
        state: job.state,
        errors: job.errors,
        attempt: job.attempt,
        max_attempts: job.max_attempts,
        inserted_at: job.inserted_at,
        scheduled_at: job.scheduled_at,
        attempted_at: job.attempted_at,
        completed_at: job.completed_at,
        discarded_at: job.discarded_at,
        cancelled_at: job.cancelled_at,
        target: %{
          pool_id: fragment("?->>?", job.args, "pool_id"),
          pool_name: pool.name,
          pool_slug: pool.slug,
          assignment_id: fragment("?->>?", job.args, "pool_upstream_assignment_id"),
          assignment_label: assignment.assignment_label,
          assignment_status: assignment.status,
          upstream_identity_id: fragment("?->>?", job.args, "upstream_identity_id"),
          assignment_identity_label: assignment_identity.account_label,
          assignment_identity_status: assignment_identity.status,
          direct_identity_label: direct_identity.account_label,
          direct_identity_status: direct_identity.status,
          api_key_id: fragment("?->>?", job.args, "api_key_id"),
          api_key_label: api_key.display_name,
          api_key_prefix: api_key.key_prefix,
          rollup_date: fragment("?->>?", job.args, "rollup_date")
        }
      }
  end

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  defp pool_id(%{id: id}), do: id
  defp pool_id(id) when is_binary(id), do: id
  defp identity_id(%{id: id}), do: id
  defp identity_id(id) when is_binary(id), do: id
  defp identity_id(_id), do: nil
end
