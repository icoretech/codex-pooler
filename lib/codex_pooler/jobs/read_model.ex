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
    HealthPolicy,
    TokenRefreshWorker
  }

  @admin_jobs_default_limit 15
  @admin_jobs_max_limit 50
  @explorer_page_size 20
  @completed_state "completed"
  @overview_action_buckets [:active_failure, :retry_pressure, :stuck_executing, :backlog_pressure]

  @type job_summary :: map()
  @type explorer_job_summary :: map()
  @type explorer_filters :: %{
          optional(:state) => String.t() | nil,
          optional(:worker) => String.t() | nil,
          optional(:queue) => String.t() | nil,
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
          active: [job_summary()],
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
    |> latest_jobs_query(opts)
    |> Repo.all()
    |> with_attention(opts)
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

  @spec list_explorer_jobs(scope_ref(), explorer_filters(), keyword()) :: explorer_page()
  def list_explorer_jobs(scope, filters, opts \\ [])

  def list_explorer_jobs(%Scope{} = scope, filters, opts) do
    if Pools.owner?(scope),
      do: list_explorer_jobs(:system, filters, opts),
      else: empty_explorer_page(filters)
  end

  def list_explorer_jobs(:system, filters, opts) do
    filters = normalize_explorer_filters(filters)
    limit = @explorer_page_size
    offset = explorer_offset(filters.page, limit)

    query =
      Oban.Job
      |> apply_explorer_filters(filters)
      |> maybe_filter_resolved_failure_visibility(filters)

    if filters.attention do
      attention_filtered_explorer_page(query, filters.attention, limit, offset, opts)
    else
      total = Repo.aggregate(query, :count, :id)

      items =
        query
        |> job_explorer_metadata_query()
        |> order_by([job], desc: job.inserted_at, desc: job.id)
        |> limit(^limit)
        |> offset(^offset)
        |> Repo.all()
        |> sanitize_explorer_error_summaries()
        |> with_attention(opts)

      %{items: items, total: total, limit: limit, offset: offset}
    end
  end

  def list_explorer_jobs(_scope, filters, _opts), do: empty_explorer_page(filters)

  @spec jobs_overview(scope_ref(), explorer_filters(), keyword()) :: jobs_overview()
  def jobs_overview(scope, filters, opts \\ [])

  def jobs_overview(%Scope{} = scope, filters, opts) do
    if Pools.owner?(scope),
      do: jobs_overview(:system, filters, opts),
      else: empty_jobs_overview()
  end

  def jobs_overview(:system, filters, opts) do
    filters = normalize_explorer_filters(filters)
    now = attention_now(opts)

    {:ok, overview} =
      Repo.transaction(fn ->
        Oban.Job
        |> apply_overview_filters(filters)
        |> job_explorer_metadata_query()
        |> order_by([job], desc: job.inserted_at, desc: job.id)
        |> Repo.stream()
        |> Enum.reduce(empty_jobs_overview(), &collect_overview_job(&1, &2, now))
        |> finalize_jobs_overview()
      end)

    overview
  end

  def jobs_overview(_scope, _filters, _opts), do: empty_jobs_overview()

  @spec worker_job_summary(scope_ref(), [String.t()]) :: worker_job_summary()
  def worker_job_summary(_scope, []), do: empty_worker_job_summary()

  def worker_job_summary(scope, workers) do
    scope
    |> worker_job_summaries_by_group([
      %{key: @single_worker_summary_group_key, workers: workers}
    ])
    |> Map.fetch!(@single_worker_summary_group_key)
  end

  @spec worker_job_summaries_by_group(scope_ref(), [worker_group()]) ::
          worker_job_summaries_by_group()
  def worker_job_summaries_by_group(scope, worker_groups)

  def worker_job_summaries_by_group(_scope, []), do: %{}

  def worker_job_summaries_by_group(%Scope{} = scope, worker_groups) do
    if Pools.owner?(scope) do
      worker_job_summaries_by_group(:system, worker_groups)
    else
      empty_worker_job_summaries_by_group(worker_groups)
    end
  end

  def worker_job_summaries_by_group(:system, worker_groups) do
    now = DateTime.utc_now()
    worker_groups = normalize_worker_groups(worker_groups)
    latest_by_group = latest_worker_jobs_by_group(worker_groups)
    latest_success_by_group = latest_worker_jobs_by_group(worker_groups, state: @completed_state)
    latest_failure_by_group = latest_worker_jobs_by_group(worker_groups, states: failure_states())
    pending_by_group = next_pending_worker_jobs_by_group(worker_groups)
    active_by_group = active_worker_jobs_by_group(worker_groups)
    unresolved_failures_by_group = unresolved_failure_worker_jobs_by_group(worker_groups)

    Map.new(worker_groups, fn {group_key, _workers} ->
      summary = %{
        empty_worker_job_summary()
        | latest: Map.get(latest_by_group, group_key),
          latest_success: Map.get(latest_success_by_group, group_key),
          latest_failure: Map.get(latest_failure_by_group, group_key),
          pending: Map.get(pending_by_group, group_key),
          active: Map.get(active_by_group, group_key, []),
          unresolved_failures: Map.get(unresolved_failures_by_group, group_key, [])
      }

      {group_key, with_worker_summary_attention(summary, now: now)}
    end)
  end

  def worker_job_summaries_by_group(_scope, worker_groups) do
    empty_worker_job_summaries_by_group(worker_groups)
  end

  @spec list_recent_token_refresh_jobs(identity_ref(), keyword()) :: [job_summary()]
  def list_recent_token_refresh_jobs(identity_or_id, opts \\ []) do
    identity_id = identity_id(identity_or_id)
    limit = opts |> Keyword.get(:limit, 5) |> max(1) |> min(50)

    results =
      Repo.all(
        from job in Oban.Job,
          where:
            job.worker == ^worker_name(TokenRefreshWorker) and
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

    with_attention(results, opts)
  end

  @spec list_recent_account_reconciliation_jobs(pool_ref(), keyword()) :: [job_summary()]
  def list_recent_account_reconciliation_jobs(pool_or_id, opts \\ []) do
    pool_id = pool_id(pool_or_id)
    limit = opts |> Keyword.get(:limit, 10) |> max(1) |> min(50)

    results =
      Repo.all(
        from job in Oban.Job,
          where:
            job.worker == ^worker_name(AccountReconciliationWorker) and
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

    with_attention(results, opts)
  end

  defp reauth_required_reconciliation_failure?(%{worker: worker, target: target})
       when is_map(target) do
    worker == worker_name(AccountReconciliationWorker) and reauth_required_target?(target)
  end

  defp reauth_required_reconciliation_failure?(_job), do: false

  defp reauth_required_target?(%{assignment_status: "reauth_required"}), do: true

  defp reauth_required_target?(%{assignment_identity_status: "reauth_required"}), do: true

  defp reauth_required_target?(_target), do: false

  defp with_worker_summary_attention(summary, opts) do
    now = attention_now(opts)

    %{
      summary
      | latest: with_attention(summary.latest, now: now),
        latest_success: with_attention(summary.latest_success, now: now),
        latest_failure: with_attention(summary.latest_failure, now: now),
        pending: with_attention(summary.pending, now: now),
        active: with_attention(summary.active, now: now),
        unresolved_failures: with_attention(summary.unresolved_failures, now: now)
    }
  end

  defp with_attention(jobs, opts) when is_list(jobs) do
    now = attention_now(opts)
    Enum.map(jobs, &HealthPolicy.put_attention(&1, now: now))
  end

  defp with_attention(nil, _opts), do: nil

  defp with_attention(job, opts) when is_map(job) do
    HealthPolicy.put_attention(job, now: attention_now(opts))
  end

  defp attention_now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp latest_worker_jobs_by_group(worker_groups, opts \\ []) do
    {group_worker_rows, group_keys_by_index} = group_worker_rows_by_index(worker_groups)

    if group_worker_rows == [] do
      %{}
    else
      group_worker_rows
      |> ranked_latest_worker_jobs_query(opts)
      |> grouped_job_metadata_query()
      |> Repo.all()
      |> Map.new(fn %{group_index: group_index, job: job} ->
        {Map.fetch!(group_keys_by_index, group_index), job}
      end)
    end
  end

  defp group_worker_rows_by_index(worker_groups) do
    worker_groups = Enum.with_index(worker_groups)

    group_worker_rows =
      for {{_group_key, workers}, group_index} <- worker_groups,
          worker <- Enum.uniq(workers) do
        %{group_index: group_index, worker: worker}
      end

    group_keys_by_index =
      Map.new(worker_groups, fn {{group_key, _workers}, group_index} ->
        {group_index, group_key}
      end)

    {group_worker_rows, group_keys_by_index}
  end

  defp ranked_latest_worker_jobs_query(group_worker_rows, opts) do
    group_worker_types = %{group_index: :integer, worker: :string}

    ranked_query =
      from job in Oban.Job,
        join: group_worker in values(group_worker_rows, group_worker_types),
        on: job.worker == group_worker.worker,
        windows: [
          group_partition: [
            partition_by: group_worker.group_index,
            order_by: [desc: job.inserted_at, desc: job.id]
          ]
        ],
        select: %{
          id: job.id,
          group_index: group_worker.group_index,
          row_number: over(row_number(), :group_partition)
        }

    ranked_query
    |> maybe_where_states(opts)
    |> subquery()
    |> then(fn ranked ->
      from ranked_job in ranked,
        where: ranked_job.row_number == 1,
        select: %{id: ranked_job.id, group_index: ranked_job.group_index}
    end)
  end

  defp grouped_job_metadata_query(grouped_query, order \\ nil) do
    queryable =
      from job in Oban.Job,
        join: grouped_job in subquery(grouped_query),
        on: grouped_job.id == job.id

    query =
      from [
             job,
             grouped_job,
             pool,
             assignment,
             assignment_identity,
             direct_identity,
             api_key
           ] in grouped_job_target_metadata_query(queryable),
           select: %{
             group_index: grouped_job.group_index,
             job: %{
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
                 assignment_identity_id: type(assignment.upstream_identity_id, :string),
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
           }

    grouped_job_metadata_order(query, order)
  end

  defp grouped_job_metadata_order(query, :scheduled) do
    from [job, grouped_job, _pool, _assignment, _assignment_identity, _direct_identity, _api_key] in query,
      order_by: [asc: grouped_job.group_index, asc: job.scheduled_at, desc: job.id]
  end

  defp grouped_job_metadata_order(query, :inserted_desc) do
    from [job, grouped_job, _pool, _assignment, _assignment_identity, _direct_identity, _api_key] in query,
      order_by: [asc: grouped_job.group_index, desc: job.inserted_at, desc: job.id]
  end

  defp grouped_job_metadata_order(query, _order), do: query

  defp next_pending_worker_jobs_by_group(worker_groups) do
    {group_worker_rows, group_keys_by_index} = group_worker_rows_by_index(worker_groups)

    if group_worker_rows == [] do
      %{}
    else
      group_worker_rows
      |> ranked_next_pending_worker_jobs_query()
      |> grouped_job_metadata_query()
      |> Repo.all()
      |> Map.new(fn %{group_index: group_index, job: job} ->
        {Map.fetch!(group_keys_by_index, group_index), job}
      end)
    end
  end

  defp ranked_next_pending_worker_jobs_query(group_worker_rows) do
    group_worker_types = %{group_index: :integer, worker: :string}

    ranked_query =
      from job in Oban.Job,
        join: group_worker in values(group_worker_rows, group_worker_types),
        on: job.worker == group_worker.worker,
        where: job.state in ^pending_states(),
        windows: [
          group_partition: [
            partition_by: group_worker.group_index,
            order_by: [asc: job.scheduled_at, desc: job.id]
          ]
        ],
        select: %{
          id: job.id,
          group_index: group_worker.group_index,
          row_number: over(row_number(), :group_partition)
        }

    ranked_query
    |> subquery()
    |> then(fn ranked ->
      from ranked_job in ranked,
        where: ranked_job.row_number == 1,
        select: %{id: ranked_job.id, group_index: ranked_job.group_index}
    end)
  end

  defp active_worker_jobs_by_group(worker_groups) do
    {group_worker_rows, group_keys_by_index} = group_worker_rows_by_index(worker_groups)

    if group_worker_rows == [] do
      %{}
    else
      group_worker_rows
      |> grouped_active_worker_jobs_query()
      |> grouped_job_metadata_query(:scheduled)
      |> Repo.all()
      |> grouped_job_lists_by_group(group_keys_by_index)
    end
  end

  defp grouped_active_worker_jobs_query(group_worker_rows) do
    group_worker_types = %{group_index: :integer, worker: :string}

    from job in Oban.Job,
      join: group_worker in values(group_worker_rows, group_worker_types),
      on: job.worker == group_worker.worker,
      where: job.state in ^pending_states(),
      select: %{id: job.id, group_index: group_worker.group_index}
  end

  defp unresolved_failure_worker_jobs_by_group(worker_groups) do
    {group_worker_rows, group_keys_by_index} = group_worker_rows_by_index(worker_groups)

    if group_worker_rows == [] do
      %{}
    else
      group_worker_rows
      |> grouped_unresolved_failure_worker_jobs_query()
      |> grouped_job_metadata_query(:inserted_desc)
      |> Repo.all()
      |> reject_reauth_required_grouped_reconciliation_failures()
      |> grouped_job_lists_by_group(group_keys_by_index)
    end
  end

  defp grouped_unresolved_failure_worker_jobs_query(group_worker_rows) do
    group_worker_types = %{group_index: :integer, worker: :string}

    from job in Oban.Job,
      join: group_worker in values(group_worker_rows, group_worker_types),
      on: job.worker == group_worker.worker,
      where: job.state in ^failure_states(),
      where:
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
        ),
      select: %{id: job.id, group_index: group_worker.group_index}
  end

  defp reject_reauth_required_grouped_reconciliation_failures(grouped_jobs) do
    Enum.reject(grouped_jobs, fn %{job: job} -> reauth_required_reconciliation_failure?(job) end)
  end

  defp grouped_job_lists_by_group(grouped_jobs, group_keys_by_index) do
    grouped_jobs
    |> Enum.reduce(%{}, fn %{group_index: group_index, job: job}, acc ->
      group_key = Map.fetch!(group_keys_by_index, group_index)
      Map.update(acc, group_key, [job], &[job | &1])
    end)
    |> Map.new(fn {group_key, jobs} -> {group_key, Enum.reverse(jobs)} end)
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

  defp empty_worker_job_summaries_by_group(worker_groups) do
    Map.new(normalize_worker_groups(worker_groups), fn {group_key, _workers} ->
      {group_key, empty_worker_job_summary()}
    end)
  end

  defp normalize_worker_groups(worker_groups) when is_list(worker_groups) do
    worker_groups
    |> Enum.map(&normalize_worker_group/1)
    |> Enum.reject(fn {group_key, _workers} -> is_nil(group_key) end)
  end

  defp normalize_worker_groups(_worker_groups), do: []

  defp normalize_worker_group(%{key: group_key, workers: workers}) do
    {group_key, normalize_worker_names(workers)}
  end

  defp normalize_worker_group(%{"key" => group_key, "workers" => workers}) do
    {group_key, normalize_worker_names(workers)}
  end

  defp normalize_worker_group(_group), do: {nil, []}

  defp normalize_worker_names(workers) when is_list(workers) do
    workers
    |> Enum.map(&normalize_worker_name/1)
    |> Enum.filter(&is_binary/1)
  end

  defp normalize_worker_names(_workers), do: []

  defp normalize_worker_name(worker) when is_binary(worker), do: worker
  defp normalize_worker_name(worker) when is_atom(worker), do: worker_name(worker)
  defp normalize_worker_name(_worker), do: nil

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

  defp empty_explorer_page(filters) do
    limit = @explorer_page_size

    offset =
      filters |> normalize_explorer_filters() |> Map.fetch!(:page) |> explorer_offset(limit)

    %{items: [], total: 0, limit: limit, offset: offset}
  end

  defp normalize_explorer_filters(filters) when is_map(filters) do
    %{
      state: filter_value(filters, :state),
      worker: filter_value(filters, :worker),
      queue: filter_value(filters, :queue),
      attention: filter_value(filters, :attention),
      target_kind: filter_value(filters, :target_kind),
      target_id: filter_value(filters, :target_id),
      page: normalized_page(filter_value(filters, :page)),
      show_completed: filter_value(filters, :show_completed) == true
    }
  end

  defp normalize_explorer_filters(_filters) do
    normalize_explorer_filters(%{})
  end

  defp filter_value(filters, key) do
    Map.get(filters, key) || Map.get(filters, Atom.to_string(key))
  end

  defp normalized_page(page) when is_integer(page) and page > 0, do: page
  defp normalized_page(_page), do: 1

  defp explorer_offset(page, limit), do: (page - 1) * limit

  defp apply_explorer_filters(queryable, filters) do
    queryable
    |> maybe_filter_explorer_completed_visibility(filters)
    |> maybe_filter_explorer_state(filters.state)
    |> maybe_filter_explorer_worker(filters.worker)
    |> maybe_filter_explorer_queue(filters.queue)
    |> maybe_filter_explorer_target(filters.target_kind, filters.target_id)
  end

  defp maybe_filter_resolved_failure_visibility(queryable, %{attention: attention})
       when attention in ["active_failure", "retry_pressure", "cancelled"] do
    exclude_resolved_failure_jobs_query(queryable)
  end

  defp maybe_filter_resolved_failure_visibility(queryable, %{state: state})
       when is_binary(state),
       do: queryable

  defp maybe_filter_resolved_failure_visibility(queryable, %{show_completed: true}),
    do: queryable

  defp maybe_filter_resolved_failure_visibility(queryable, _filters) do
    exclude_resolved_failure_jobs_query(queryable)
  end

  defp maybe_filter_explorer_completed_visibility(queryable, %{show_completed: true}),
    do: queryable

  defp maybe_filter_explorer_completed_visibility(queryable, %{state: @completed_state}),
    do: queryable

  defp maybe_filter_explorer_completed_visibility(queryable, _filters) do
    from job in queryable, where: job.state != @completed_state
  end

  defp maybe_filter_explorer_state(queryable, nil), do: queryable

  defp maybe_filter_explorer_state(queryable, state) do
    from job in queryable, where: job.state == ^state
  end

  defp maybe_filter_explorer_worker(queryable, nil), do: queryable

  defp maybe_filter_explorer_worker(queryable, worker) do
    from job in queryable, where: job.worker == ^worker
  end

  defp maybe_filter_explorer_queue(queryable, nil), do: queryable

  defp maybe_filter_explorer_queue(queryable, queue) do
    from job in queryable, where: job.queue == ^queue
  end

  defp maybe_filter_explorer_target(queryable, nil, _target_id), do: queryable

  defp maybe_filter_explorer_target(queryable, "assignment", target_id),
    do: where_arg(queryable, "pool_upstream_assignment_id", target_id)

  defp maybe_filter_explorer_target(queryable, "upstream_identity", target_id),
    do: where_arg(queryable, "upstream_identity_id", target_id)

  defp maybe_filter_explorer_target(queryable, "pool", target_id),
    do: where_arg(queryable, "pool_id", target_id)

  defp maybe_filter_explorer_target(queryable, "api_key", target_id),
    do: where_arg(queryable, "api_key_id", target_id)

  defp maybe_filter_explorer_target(queryable, "rollup_date", target_id),
    do: where_arg(queryable, "rollup_date", target_id)

  defp maybe_filter_explorer_target(queryable, "system", _target_id) do
    from job in queryable,
      where:
        is_nil(fragment("?->>?", job.args, "pool_id")) and
          is_nil(fragment("?->>?", job.args, "pool_upstream_assignment_id")) and
          is_nil(fragment("?->>?", job.args, "upstream_identity_id")) and
          is_nil(fragment("?->>?", job.args, "api_key_id")) and
          is_nil(fragment("?->>?", job.args, "rollup_date"))
  end

  defp maybe_filter_explorer_target(queryable, _target_kind, _target_id), do: queryable

  defp where_arg(queryable, _key, nil), do: queryable

  defp where_arg(queryable, key, value) do
    from job in queryable, where: fragment("?->>?", job.args, ^key) == ^value
  end

  defp empty_jobs_overview do
    %{
      status: :empty,
      empty?: true,
      healthy?: false,
      total: 0,
      actionable_count: 0,
      completed_context_count: 0,
      buckets: Map.new(@overview_action_buckets, &{&1, empty_overview_bucket()}),
      completed_context: empty_overview_bucket()
    }
  end

  defp empty_overview_bucket, do: %{count: 0, newest: nil}

  defp apply_overview_filters(queryable, filters) do
    queryable
    |> maybe_filter_explorer_worker(filters.worker)
    |> maybe_filter_explorer_queue(filters.queue)
    |> maybe_filter_explorer_target(filters.target_kind, filters.target_id)
    |> exclude_resolved_failure_jobs_query()
  end

  defp exclude_resolved_failure_jobs_query(queryable) do
    from job in queryable,
      where:
        job.state not in ^failure_states() or
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
  end

  defp collect_overview_job(job, overview, now) do
    job = job |> sanitize_explorer_error_summary() |> HealthPolicy.put_attention(now: now)
    overview = %{overview | total: overview.total + 1}

    case job.attention_state do
      attention_state when attention_state in @overview_action_buckets ->
        collect_overview_actionable_job(overview, attention_state, job)

      :healthy_context ->
        collect_completed_context_job(overview, job)

      _other_state ->
        overview
    end
  end

  defp collect_overview_actionable_job(overview, attention_state, job) do
    bucket = Map.fetch!(overview.buckets, attention_state)

    bucket = %{
      bucket
      | count: bucket.count + 1,
        newest: bucket.newest || job
    }

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

  defp finalize_jobs_overview(%{total: 0} = overview), do: overview

  defp finalize_jobs_overview(%{actionable_count: actionable_count} = overview)
       when actionable_count > 0 do
    %{overview | status: :attention_required, empty?: false, healthy?: false}
  end

  defp finalize_jobs_overview(overview) do
    %{overview | status: :healthy, empty?: false, healthy?: true}
  end

  defp attention_filtered_explorer_page(queryable, attention, limit, offset, opts) do
    now = attention_now(opts)

    {:ok, {total, items}} =
      Repo.transaction(fn ->
        queryable
        |> job_explorer_metadata_query()
        |> order_by([job], desc: job.inserted_at, desc: job.id)
        |> Repo.stream()
        |> Enum.reduce({0, []}, fn job, {total, items} ->
          collect_attention_explorer_item({total, items}, job, attention, now, limit, offset)
        end)
      end)

    %{
      items: items |> Enum.reverse() |> sanitize_explorer_error_summaries(),
      total: total,
      limit: limit,
      offset: offset
    }
  end

  defp collect_attention_explorer_item({total, items}, job, attention, now, limit, offset) do
    job = HealthPolicy.put_attention(job, now: now)

    if Atom.to_string(job.attention_state) == attention do
      {total + 1, maybe_collect_explorer_item(items, job, total, limit, offset)}
    else
      {total, items}
    end
  end

  defp maybe_collect_explorer_item(items, job, total, limit, offset) do
    if total >= offset and length(items) < limit do
      [job | items]
    else
      items
    end
  end

  defp job_metadata_query(queryable) do
    from [
           job,
           pool,
           assignment,
           assignment_identity,
           direct_identity,
           api_key
         ] in job_target_metadata_query(queryable),
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
             assignment_identity_id: type(assignment.upstream_identity_id, :string),
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

  defp job_explorer_metadata_query(queryable) do
    from [
           job,
           pool,
           assignment,
           assignment_identity,
           direct_identity,
           api_key
         ] in job_target_metadata_query(queryable),
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
             assignment_identity_id: type(assignment.upstream_identity_id, :string),
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

  defp sanitize_explorer_error_summaries(jobs),
    do: Enum.map(jobs, &sanitize_explorer_error_summary/1)

  defp sanitize_explorer_error_summary(%{errors: errors} = job) when is_list(errors) do
    job
    |> Map.delete(:errors)
    |> maybe_put_failure_summary(latest_error_by_attempt(errors))
  end

  defp sanitize_explorer_error_summary(job), do: Map.delete(job, :errors)

  defp maybe_put_failure_summary(job, latest_error) when is_map(latest_error),
    do: Map.put(job, :failure_summary, failure_summary(latest_error))

  defp maybe_put_failure_summary(job, _latest_error), do: job

  defp failure_summary(error) do
    %{
      title: failure_title(error),
      message: error |> Map.get("error") |> safe_failure_message()
    }
  end

  defp latest_error_by_attempt(errors) do
    errors
    |> Enum.filter(&is_map/1)
    |> Enum.max_by(&error_attempt_number/1, fn -> nil end)
  end

  defp error_attempt_number(%{"attempt" => attempt}) when is_integer(attempt), do: attempt

  defp error_attempt_number(%{"attempt" => attempt}) when is_binary(attempt) do
    case Integer.parse(attempt) do
      {attempt, ""} -> attempt
      _not_integer -> -1
    end
  end

  defp error_attempt_number(_error), do: -1

  defp failure_title(%{"error" => message} = error) when is_binary(message) do
    [failure_attempt(error), operator_failure_title(message) || failure_kind(error)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "Failure detail"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp failure_title(error) do
    [failure_attempt(error), failure_kind(error)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "Failure detail"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp failure_attempt(%{"attempt" => attempt}) when is_integer(attempt), do: "Attempt #{attempt}"
  defp failure_attempt(%{"attempt" => attempt}) when is_binary(attempt), do: "Attempt #{attempt}"
  defp failure_attempt(_error), do: nil

  defp failure_kind(%{"kind" => kind}) when is_binary(kind) and kind != "", do: kind
  defp failure_kind(_error), do: nil

  defp safe_failure_message(message) when is_binary(message) do
    message
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> redact_failure_secrets()
    |> unwrap_oban_failure_message()
    |> operator_failure_message()
    |> String.trim()
    |> truncate_failure_message()
    |> case do
      "" -> "No diagnostic message recorded."
      message -> message
    end
  end

  defp safe_failure_message(_message), do: "No diagnostic message recorded."

  defp redact_failure_secrets(message) do
    message
    |> String.replace(~r/(?i)bearer\s+[a-z0-9._~+\/=:-]+/, "Bearer [redacted]")
    |> String.replace(~r/(?i)\bsecret[-_a-z0-9]*\b/, "[redacted]")
    |> String.replace(
      ~r/(?i)\b(authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|refresh[_-]?token|password|prompt|secret|token)\b\s*[:=]\s*[^,;\s]+/,
      "[redacted]"
    )
  end

  defp unwrap_oban_failure_message(message) do
    cond do
      match = Regex.run(~r/failed with \{:error, "([^"]+)"\}/, message) ->
        [_full, inner] = match
        inner

      match = Regex.run(~r/failed with \{:error, %\{[^}]*message: "([^"]+)"/, message) ->
        [_full, inner] = match
        inner

      oban_discard_failure?(message) ->
        "The job stopped without additional diagnostics."

      true ->
        message
    end
  end

  defp operator_failure_title(message) do
    code = message |> unwrap_oban_failure_message() |> reconciliation_failure_code()
    code = code || oban_map_failure_code(message)

    cond do
      oban_discard_failure?(message) ->
        "Run discarded"

      catalog_sync_invalid_trigger_kind?(message) ->
        "Invalid catalog sync trigger"

      catalog_sync_in_progress?(message) ->
        "Catalog sync already running"

      title = quota_failure_title(code) ->
        title

      is_binary(code) ->
        humanize_failure_code(code)

      true ->
        nil
    end
  end

  defp quota_failure_title("quota_refresh_auth_unavailable"), do: "Quota refresh blocked"
  defp quota_failure_title("quota_refresh_unavailable"), do: "Quota unavailable"
  defp quota_failure_title("quota_refresh_failed"), do: "Quota refresh failed"
  defp quota_failure_title(_code), do: nil

  defp operator_failure_message(message) do
    cond do
      catalog_sync_invalid_trigger_kind?(message) ->
        "Manual catalog sync could not start because the enqueue action used an unsupported trigger kind."

      catalog_sync_in_progress?(message) ->
        "Catalog sync could not start because this pool already has a sync run marked as running."

      true ->
        case reconciliation_failure_code(message) do
          "quota_refresh_auth_unavailable" ->
            "Quota refresh needs account reauthentication."

          "quota_refresh_unavailable" ->
            "Quota data was not available from the upstream account."

          "quota_refresh_failed" ->
            "Quota refresh failed for the upstream account."

          code when is_binary(code) ->
            "Account reconciliation needs attention: #{humanize_failure_code(code)}."

          nil ->
            message
        end
    end
  end

  defp reconciliation_failure_code("account reconciliation partial: " <> code),
    do: String.trim(code)

  defp reconciliation_failure_code(_message), do: nil

  defp oban_map_failure_code(message) do
    case Regex.run(~r/failed with \{:error, %\{[^}]*code: :([a-z0-9_]+)/, message) do
      [_full, code] -> code
      _no_match -> nil
    end
  end

  defp oban_discard_failure?(message), do: Regex.match?(~r/failed with :discard\b/, message)

  defp catalog_sync_invalid_trigger_kind?(message) do
    String.contains?(message, "CodexPooler.Jobs.CatalogSyncWorker") and
      String.contains?(message, "trigger_kind:") and
      String.contains?(message, "is invalid")
  end

  defp catalog_sync_in_progress?(message) do
    String.contains?(message, "catalog sync already running") or
      String.contains?(message, "code: :catalog_sync_in_progress")
  end

  defp humanize_failure_code(code) do
    code
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp truncate_failure_message(message) when byte_size(message) > 240,
    do: message |> binary_part(0, 240) |> String.trim() |> Kernel.<>("…")

  defp truncate_failure_message(message), do: message

  defp job_target_metadata_query(queryable) do
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
      on: fragment("?->>?", job.args, "api_key_id") == type(api_key.id, :string)
  end

  defp grouped_job_target_metadata_query(queryable) do
    from [job, _grouped_job] in queryable,
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
      on: fragment("?->>?", job.args, "api_key_id") == type(api_key.id, :string)
  end

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  defp pool_id(%{id: id}), do: id
  defp pool_id(id) when is_binary(id), do: id
  defp identity_id(%{id: id}), do: id
  defp identity_id(id) when is_binary(id), do: id
  defp identity_id(_id), do: nil
end
