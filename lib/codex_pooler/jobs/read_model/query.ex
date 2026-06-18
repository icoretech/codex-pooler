defmodule CodexPooler.Jobs.ReadModel.Query do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  alias CodexPooler.Jobs.{AccountReconciliationWorker, HealthPolicy, Schedule}

  @admin_jobs_default_limit 15
  @admin_jobs_max_limit 50
  @identity_recovered_reconciliation_error_pattern "quota_refresh_auth_unavailable|pool_account_not_reconcilable"

  def reauth_required_reconciliation_failure?(%{worker: worker, target: target})
      when is_map(target) do
    worker == worker_name(AccountReconciliationWorker) and reauth_required_target?(target)
  end

  def reauth_required_reconciliation_failure?(_job), do: false

  def reauth_required_target?(%{assignment_status: "reauth_required"}), do: true

  def reauth_required_target?(%{assignment_identity_status: "reauth_required"}), do: true

  def reauth_required_target?(_target), do: false

  def with_attention(jobs, opts) when is_list(jobs) do
    now = attention_now(opts)
    Enum.map(jobs, &put_attention(&1, now))
  end

  def with_attention(nil, _opts), do: nil

  def with_attention(job, opts) when is_map(job) do
    put_attention(job, attention_now(opts))
  end

  def attention_now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp put_attention(job, now) do
    job
    |> drop_blank_trigger_kind()
    |> HealthPolicy.put_attention(now: now)
  end

  defp drop_blank_trigger_kind(%{trigger_kind: trigger_kind} = job)
       when trigger_kind in [nil, ""],
       do: Map.delete(job, :trigger_kind)

  defp drop_blank_trigger_kind(job), do: job

  def group_worker_rows_by_index(worker_groups) do
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

  defmacrop job_summary_projection(
              job,
              pool,
              assignment,
              assignment_identity,
              direct_identity,
              api_key
            ) do
    quote do
      %{
        id: unquote(job).id,
        worker: unquote(job).worker,
        queue: unquote(job).queue,
        state: unquote(job).state,
        trigger_kind: fragment("?->>?", unquote(job).args, "trigger_kind"),
        errors: unquote(job).errors,
        attempt: unquote(job).attempt,
        max_attempts: unquote(job).max_attempts,
        inserted_at: unquote(job).inserted_at,
        scheduled_at: unquote(job).scheduled_at,
        attempted_at: unquote(job).attempted_at,
        completed_at: unquote(job).completed_at,
        discarded_at: unquote(job).discarded_at,
        cancelled_at: unquote(job).cancelled_at,
        target: %{
          target_kind: fragment("?->>?", unquote(job).args, "target_kind"),
          pool_id: fragment("?->>?", unquote(job).args, "pool_id"),
          pool_name: unquote(pool).name,
          pool_slug: unquote(pool).slug,
          assignment_id: fragment("?->>?", unquote(job).args, "pool_upstream_assignment_id"),
          assignment_label: unquote(assignment).assignment_label,
          assignment_status: unquote(assignment).status,
          assignment_identity_id: type(unquote(assignment).upstream_identity_id, :string),
          upstream_identity_id: fragment("?->>?", unquote(job).args, "upstream_identity_id"),
          assignment_identity_label: unquote(assignment_identity).account_label,
          assignment_identity_status: unquote(assignment_identity).status,
          direct_identity_label: unquote(direct_identity).account_label,
          direct_identity_status: unquote(direct_identity).status,
          api_key_id: fragment("?->>?", unquote(job).args, "api_key_id"),
          api_key_label: unquote(api_key).display_name,
          api_key_prefix: unquote(api_key).key_prefix,
          rollup_date: fragment("?->>?", unquote(job).args, "rollup_date")
        }
      }
    end
  end

  def grouped_job_metadata_query(grouped_query, order \\ nil) do
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
             job:
               job_summary_projection(
                 job,
                 pool,
                 assignment,
                 assignment_identity,
                 direct_identity,
                 api_key
               )
           }

    grouped_job_metadata_order(query, order)
  end

  def grouped_job_metadata_order(query, :scheduled) do
    from [job, grouped_job, _pool, _assignment, _assignment_identity, _direct_identity, _api_key] in query,
      order_by: [asc: grouped_job.group_index, asc: job.scheduled_at, desc: job.id]
  end

  def grouped_job_metadata_order(query, :inserted_desc) do
    from [job, grouped_job, _pool, _assignment, _assignment_identity, _direct_identity, _api_key] in query,
      order_by: [asc: grouped_job.group_index, desc: job.inserted_at, desc: job.id]
  end

  def grouped_job_metadata_order(query, _order), do: query

  def grouped_job_lists_by_group(grouped_jobs, group_keys_by_index) do
    grouped_jobs
    |> Enum.reduce(%{}, fn %{group_index: group_index, job: job}, acc ->
      group_key = Map.fetch!(group_keys_by_index, group_index)
      Map.update(acc, group_key, [job], &[job | &1])
    end)
    |> Map.new(fn {group_key, jobs} -> {group_key, Enum.reverse(jobs)} end)
  end

  def maybe_where_states(queryable, state: state) do
    from job in queryable, where: job.state == ^state
  end

  def maybe_where_states(queryable, states: states) do
    from job in queryable, where: job.state in ^states
  end

  def maybe_where_states(queryable, _opts), do: queryable

  def open_job_states, do: ["available", "scheduled", "executing", "retryable"]
  def failure_states, do: ["discarded", "retryable", "cancelled"]

  def normalize_worker_groups(worker_groups) when is_list(worker_groups) do
    worker_groups
    |> Enum.map(&normalize_worker_group/1)
    |> Enum.reject(fn {group_key, _workers} -> is_nil(group_key) end)
  end

  def normalize_worker_groups(_worker_groups), do: []

  def normalize_worker_group(%{key: group_key, workers: workers}) do
    {group_key, normalize_worker_names(workers)}
  end

  def normalize_worker_group(%{"key" => group_key, "workers" => workers}) do
    {group_key, normalize_worker_names(workers)}
  end

  def normalize_worker_group(_group), do: {nil, []}

  def normalize_worker_names(workers) when is_list(workers) do
    workers
    |> Enum.map(&normalize_worker_name/1)
    |> Enum.filter(&is_binary/1)
  end

  def normalize_worker_names(_workers), do: []

  def normalize_worker_name(nil), do: nil
  def normalize_worker_name(worker) when is_binary(worker), do: worker
  def normalize_worker_name(worker) when is_atom(worker), do: worker_name(worker)
  def normalize_worker_name(_worker), do: nil

  def latest_jobs_query(queryable, opts) do
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

  def configured_worker_values do
    Schedule.entries()
    |> Enum.flat_map(fn entry ->
      [Map.get(entry, :scheduled_worker) | Map.get(entry, :workers, [])]
    end)
    |> normalize_worker_names()
  end

  def configured_queue_values do
    :codex_pooler
    |> Application.get_env(Oban, [])
    |> Keyword.get(:queues, [])
    |> case do
      queues when is_list(queues) -> Enum.map(queues, &queue_name/1)
      _queues_disabled -> []
    end
    |> Enum.filter(&is_binary/1)
  end

  def queue_name({queue, _limit}) when is_atom(queue), do: Atom.to_string(queue)
  def queue_name({queue, _limit}) when is_binary(queue), do: queue
  def queue_name(queue) when is_atom(queue), do: Atom.to_string(queue)
  def queue_name(queue) when is_binary(queue), do: queue
  def queue_name(_queue), do: nil

  def filter_option_values(configured_values, persisted_values) do
    [configured_values, persisted_values]
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  def distinct_job_field_values(field) when field in [:worker, :queue] do
    Repo.all(
      from job in Oban.Job,
        where: not is_nil(field(job, ^field)) and field(job, ^field) != "",
        select: field(job, ^field),
        distinct: true,
        order_by: field(job, ^field)
    )
  end

  def normalize_explorer_filters(filters) when is_map(filters) do
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

  def normalize_explorer_filters(_filters) do
    normalize_explorer_filters(%{})
  end

  def filter_value(filters, key) do
    Map.get(filters, key) || Map.get(filters, Atom.to_string(key))
  end

  def normalized_page(page) when is_integer(page) and page > 0, do: page
  def normalized_page(_page), do: 1

  def explorer_offset(page, limit), do: (page - 1) * limit

  def maybe_filter_resolved_failure_visibility(queryable, %{attention: attention})
      when attention in ["active_failure", "retry_pressure", "cancelled"] do
    exclude_resolved_failure_jobs_query(queryable)
  end

  def maybe_filter_resolved_failure_visibility(queryable, %{state: state})
      when is_binary(state),
      do: queryable

  def maybe_filter_resolved_failure_visibility(queryable, %{show_completed: true}), do: queryable

  def maybe_filter_resolved_failure_visibility(queryable, _filters) do
    exclude_resolved_failure_jobs_query(queryable)
  end

  def maybe_filter_explorer_worker(queryable, nil), do: queryable

  def maybe_filter_explorer_worker(queryable, worker) do
    from job in queryable, where: job.worker == ^worker
  end

  def maybe_filter_explorer_queue(queryable, nil), do: queryable

  def maybe_filter_explorer_queue(queryable, queue) do
    from job in queryable, where: job.queue == ^queue
  end

  def maybe_filter_explorer_target(queryable, nil, _target_id), do: queryable

  def maybe_filter_explorer_target(queryable, "assignment", target_id),
    do: where_arg(queryable, "pool_upstream_assignment_id", target_id)

  def maybe_filter_explorer_target(queryable, "upstream_identity", target_id),
    do: where_arg(queryable, "upstream_identity_id", target_id)

  def maybe_filter_explorer_target(queryable, "pool", target_id),
    do: where_arg(queryable, "pool_id", target_id)

  def maybe_filter_explorer_target(queryable, "api_key", target_id),
    do: where_arg(queryable, "api_key_id", target_id)

  def maybe_filter_explorer_target(queryable, "rollup_date", target_id),
    do: where_arg(queryable, "rollup_date", target_id)

  def maybe_filter_explorer_target(queryable, "system", _target_id) do
    from job in queryable,
      where:
        is_nil(fragment("?->>?", job.args, "pool_id")) and
          is_nil(fragment("?->>?", job.args, "pool_upstream_assignment_id")) and
          is_nil(fragment("?->>?", job.args, "upstream_identity_id")) and
          is_nil(fragment("?->>?", job.args, "api_key_id")) and
          is_nil(fragment("?->>?", job.args, "rollup_date"))
  end

  def maybe_filter_explorer_target(queryable, _target_kind, _target_id), do: queryable

  def where_arg(queryable, _key, nil), do: queryable

  def where_arg(queryable, key, value) do
    from job in queryable, where: fragment("?->>?", job.args, ^key) == ^value
  end

  defmacrop later_resolved_failure_absent?(
              job,
              account_reconciliation_worker,
              identity_recovered_reconciliation_error_pattern
            ) do
    quote do
      fragment(
        """
        NOT EXISTS (
          SELECT 1
          FROM oban_jobs resolved
          LEFT JOIN pool_upstream_assignments resolved_assignment
            ON resolved_assignment.id::text =
              resolved.args->>'pool_upstream_assignment_id'
          LEFT JOIN pool_upstream_assignments failed_assignment
            ON failed_assignment.id::text =
              ?->>'pool_upstream_assignment_id'
          WHERE resolved.worker = ?
            AND resolved.state = 'completed'
            AND (
              resolved.inserted_at > ?
              OR (resolved.inserted_at = ? AND resolved.id > ?)
            )
            AND (
              (
                COALESCE(resolved.args->>'pool_id', '') = COALESCE(?->>'pool_id', '')
                AND COALESCE(resolved.args->>'pool_upstream_assignment_id', '') = COALESCE(?->>'pool_upstream_assignment_id', '')
                AND COALESCE(resolved.args->>'upstream_identity_id', '') = COALESCE(?->>'upstream_identity_id', '')
                AND COALESCE(resolved.args->>'api_key_id', '') = COALESCE(?->>'api_key_id', '')
                AND COALESCE(resolved.args->>'rollup_date', '') = COALESCE(?->>'rollup_date', '')
              )
              OR (
                ? = ?
                AND COALESCE(resolved.args->>'pool_id', '') = COALESCE(?->>'pool_id', '')
                AND COALESCE(
                  resolved.args->>'upstream_identity_id',
                  resolved_assignment.upstream_identity_id::text
                ) = COALESCE(
                  ?->>'upstream_identity_id',
                  failed_assignment.upstream_identity_id::text
                )
                AND COALESCE(
                  ?->>'upstream_identity_id',
                  failed_assignment.upstream_identity_id::text
                ) IS NOT NULL
              )
              OR (
                ? = ?
                AND ?::text ~ ?
                AND COALESCE(
                  resolved.args->>'upstream_identity_id',
                  resolved_assignment.upstream_identity_id::text
                ) = COALESCE(
                  ?->>'upstream_identity_id',
                  failed_assignment.upstream_identity_id::text
                )
                AND COALESCE(
                  ?->>'upstream_identity_id',
                  failed_assignment.upstream_identity_id::text
                ) IS NOT NULL
              )
            )
        )
        """,
        unquote(job).args,
        unquote(job).worker,
        unquote(job).inserted_at,
        unquote(job).inserted_at,
        unquote(job).id,
        unquote(job).args,
        unquote(job).args,
        unquote(job).args,
        unquote(job).args,
        unquote(job).args,
        unquote(job).worker,
        unquote(account_reconciliation_worker),
        unquote(job).args,
        unquote(job).args,
        unquote(job).args,
        unquote(job).worker,
        unquote(account_reconciliation_worker),
        unquote(job).errors,
        unquote(identity_recovered_reconciliation_error_pattern),
        unquote(job).args,
        unquote(job).args
      )
    end
  end

  def exclude_resolved_failure_jobs_query(queryable) do
    account_reconciliation_worker = worker_name(AccountReconciliationWorker)

    identity_recovered_reconciliation_error_pattern =
      @identity_recovered_reconciliation_error_pattern

    queryable
    |> exclude_terminal_reauth_reconciliation_failures()
    |> then(fn queryable ->
      from job in queryable,
        where:
          job.state not in ^failure_states() or
            later_resolved_failure_absent?(
              job,
              ^account_reconciliation_worker,
              ^identity_recovered_reconciliation_error_pattern
            )
    end)
  end

  def exclude_resolved_failure_matches(queryable) do
    account_reconciliation_worker = worker_name(AccountReconciliationWorker)

    identity_recovered_reconciliation_error_pattern =
      @identity_recovered_reconciliation_error_pattern

    from job in queryable,
      where:
        later_resolved_failure_absent?(
          job,
          ^account_reconciliation_worker,
          ^identity_recovered_reconciliation_error_pattern
        )
  end

  def exclude_terminal_reauth_reconciliation_failures(queryable) do
    account_reconciliation_worker = worker_name(AccountReconciliationWorker)
    failure_states = failure_states()
    assignment_reauth_required = PoolUpstreamAssignment.reauth_required_status()
    identity_reauth_required = UpstreamIdentity.reauth_required_status()

    from job in queryable,
      where:
        job.state not in ^failure_states or job.worker != ^account_reconciliation_worker or
          not fragment(
            """
            EXISTS (
              SELECT 1
              FROM pool_upstream_assignments account_reconciliation_assignment
              LEFT JOIN upstream_identities account_reconciliation_assignment_identity
                ON account_reconciliation_assignment_identity.id =
                  account_reconciliation_assignment.upstream_identity_id
              WHERE account_reconciliation_assignment.id::text =
                ?->>'pool_upstream_assignment_id'
                AND (
                  account_reconciliation_assignment.status = ?
                  OR account_reconciliation_assignment_identity.status = ?
                )
            )
            OR EXISTS (
              SELECT 1
              FROM upstream_identities account_reconciliation_direct_identity
              WHERE account_reconciliation_direct_identity.id::text =
                ?->>'upstream_identity_id'
                AND account_reconciliation_direct_identity.status = ?
            )
            """,
            job.args,
            ^assignment_reauth_required,
            ^identity_reauth_required,
            job.args,
            ^identity_reauth_required
          )
  end

  def job_metadata_query(queryable) do
    from [
           job,
           pool,
           assignment,
           assignment_identity,
           direct_identity,
           api_key
         ] in job_target_metadata_query(queryable),
         select:
           job_summary_projection(
             job,
             pool,
             assignment,
             assignment_identity,
             direct_identity,
             api_key
           )
  end

  def job_target_metadata_query(queryable) do
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

  def grouped_job_target_metadata_query(queryable) do
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

  def worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
end
