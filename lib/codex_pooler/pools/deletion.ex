defmodule CodexPooler.Pools.Deletion do
  @moduledoc """
  Deletes an archived Pool together with its history.

  Deleting the `pools` row removes everything the Pool owns by foreign key cascade, and the
  cascade's cost grows with the Pool's request history: on a production-sized database an archived
  Pool with about 49 thousand requests needed 87 s, and one with a million requests would need tens
  of minutes, far beyond what an admin page can wait for (findings#206 row 206-550). So:

    * a Pool with little history (fewer than 2,000 requests) is deleted at once, in one
      transaction bounded by a statement timeout below the Repo's 15 s query timeout and the admin
      page's 30 s push timeout;
    * a larger Pool, or one whose immediate delete runs out of that bound, is handed to
      `CodexPooler.Jobs.PoolDeletionWorker`, which removes the Pool's history in bounded batches,
      each in its own short transaction, and then deletes the Pool row.

  An archived Pool already routes nothing, refuses its API keys and is visible to owners only, so
  the Pool stays archived while its history is removed; a pending deletion job marks it as being
  deleted (`states/1`) and blocks its reactivation. The `pool.delete` audit event is written in the
  transaction that deletes the Pool row, so an audit event exists exactly when the Pool is gone
  (findings#206 row 206-551), and it names the operator who asked for the deletion.
  """

  import Ecto.Query

  alias CodexPooler.Accounts.User
  alias CodexPooler.Audit
  alias CodexPooler.Jobs.PoolDeletionWorker
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @status_archived "archived"
  @immediate_request_limit 2_000
  @immediate_statement_timeout_ms 10_000
  @batch_statement_timeout_ms 30_000
  @final_statement_timeout_ms 60_000
  @worker_name "CodexPooler.Jobs.PoolDeletionWorker"
  @pending_job_states ~w(available scheduled executing retryable)
  @failed_job_states ~w(discarded cancelled)

  # The Pool's history in deletion order, each as {table, condition on $1 = Pool id, batch rows}.
  # Requests go first: they carry attempts, ledger entries, turns and log facts by cascade on
  # their own indexed request id, so no later cascade has to touch those tables again. Sync runs a
  # model still names stay for the final cascade, which removes the models with them.
  @history_steps [
    {"requests", "pool_id = $1", 500},
    {"codex_sessions", "pool_id = $1", 1_000},
    {"bridge_session_aliases", "pool_id = $1", 5_000},
    {"bridge_owner_leases", "pool_id = $1", 5_000},
    {"bridge_affinities", "pool_id = $1", 5_000},
    {"bridge_demotions", "pool_id = $1", 5_000},
    {"ledger_entries", "pool_id = $1", 2_000},
    {"daily_rollups", "pool_id = $1", 5_000},
    {"hourly_model_usage_rollups", "pool_id = $1", 5_000},
    {"api_key_usage_buckets", "api_key_id IN (SELECT id FROM api_keys WHERE pool_id = $1)", 5_000},
    {"sync_runs", "pool_id = $1 AND NOT EXISTS (SELECT 1 FROM models WHERE models.last_sync_run_id = sync_runs.id)", 5_000}
  ]

  @type state :: :in_progress | :failed
  @type request_result :: {:ok, Pool.t()} | {:deleting, Pool.t()} | {:error, :pool_not_found | :pool_not_archived | term()}
  @type purge_result :: :done | :more
  @type finish_result :: {:ok, Pool.t()} | {:error, :pool_not_found | :pool_not_archived | term()}

  @doc """
  Deletes the archived `pool` at once when its history is small enough, otherwise schedules its
  deletion. `{:ok, pool}` means the Pool is gone; `{:deleting, pool}` means a deletion job owns it.
  """
  @spec request(User.t() | nil, Pool.t()) :: request_result()
  def request(user, %Pool{} = pool) do
    cond do
      pending?(pool.id) -> {:deleting, pool}
      small_history?(pool.id) -> delete_now_or_schedule(user, pool)
      true -> schedule(user, pool)
    end
  end

  defp delete_now_or_schedule(user, pool) do
    case delete_pool_row(user, pool, @immediate_statement_timeout_ms) do
      {:error, :statement_timeout} -> schedule(user, pool)
      result -> result
    end
  end

  @doc """
  Deletes the Pool's history in batches until `deadline` (monotonic milliseconds) passes. Returns
  `:done` when nothing is left but the rows the final cascade removes, `:more` otherwise.
  """
  @spec purge_history(Ecto.UUID.t(), integer()) :: purge_result()
  def purge_history(pool_id, deadline) when is_binary(pool_id) do
    pool_id = Ecto.UUID.dump!(pool_id)
    purge_steps(@history_steps, pool_id, deadline)
  end

  defp purge_steps([], _pool_id, _deadline), do: :done

  defp purge_steps([{table, condition, batch} | rest] = steps, pool_id, deadline) do
    cond do
      System.monotonic_time(:millisecond) >= deadline -> :more
      delete_batch(table, condition, batch, pool_id) < batch -> purge_steps(rest, pool_id, deadline)
      true -> purge_steps(steps, pool_id, deadline)
    end
  end

  defp delete_batch(table, condition, batch, pool_id) do
    {:ok, count} =
      Repo.transaction(fn ->
        put_statement_timeout(@batch_statement_timeout_ms)

        %{num_rows: count} =
          Repo.query!(
            "DELETE FROM #{table} WHERE ctid = ANY(ARRAY(SELECT ctid FROM #{table} WHERE #{condition} LIMIT $2))",
            [pool_id, batch],
            timeout: @batch_statement_timeout_ms + 5_000
          )

        count
      end)

    count
  end

  @doc """
  Deletes the Pool row and writes its `pool.delete` audit event in one transaction, once the
  Pool's history is gone. The actor is the operator who asked for the deletion.
  """
  @spec finish(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: finish_result()
  def finish(pool_id, requested_by_user_id) when is_binary(pool_id) do
    user = if is_binary(requested_by_user_id), do: Repo.get(User, requested_by_user_id)

    case Repo.get(Pool, pool_id) do
      %Pool{} = pool -> delete_pool_row(user, pool, @final_statement_timeout_ms)
      nil -> {:error, :pool_not_found}
    end
  end

  # The audit event commits with the delete or not at all. A Pool that another operator deleted
  # or reactivated meanwhile is re-read under its row lock and left alone.
  defp delete_pool_row(user, %Pool{id: pool_id}, statement_timeout_ms) do
    Repo.transaction(
      fn ->
        put_statement_timeout(statement_timeout_ms)

        with %Pool{status: @status_archived} = pool <- lock_pool(pool_id),
             :ok <- record_delete_audit_event(user, pool),
             {:ok, deleted} <- Repo.delete(pool) do
          deleted
        else
          nil -> Repo.rollback(:pool_not_found)
          %Pool{} -> Repo.rollback(:pool_not_archived)
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      timeout: statement_timeout_ms + 5_000
    )
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: :query_canceled}} -> {:error, :statement_timeout}
        _other -> reraise error, __STACKTRACE__
      end
  end

  defp record_delete_audit_event(user, %Pool{} = pool) do
    attrs = %{
      pool_id: pool.id,
      action: "pool.delete",
      target_type: "pool",
      target_id: pool.id,
      details: %{pool_id: pool.id, slug: pool.slug, name: pool.name, status: pool.status}
    }

    result =
      case user do
        %User{} -> Audit.record_user_event(user, attrs)
        nil -> Audit.record_system_event(attrs)
      end

    case result do
      {:ok, _event} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Schedules the Pool's deletion. The job is inserted under the Pool's row lock, so a concurrent
  reactivation either sees it and refuses or commits first and the Pool is no longer archived.
  """
  @spec schedule(User.t() | nil, Pool.t()) :: request_result()
  def schedule(user, %Pool{id: pool_id}) do
    Repo.transaction(fn ->
      with %Pool{status: @status_archived} = pool <- lock_pool(pool_id),
           {:ok, _job} <- Oban.insert(PoolDeletionWorker.new(job_args(pool, user))) do
        pool
      else
        nil -> Repo.rollback(:pool_not_found)
        %Pool{} -> Repo.rollback(:pool_not_archived)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, pool} -> {:deleting, pool}
      {:error, _reason} = error -> error
    end
  end

  defp job_args(%Pool{id: pool_id}, %User{id: user_id}), do: %{"pool_id" => pool_id, "requested_by_user_id" => user_id}
  defp job_args(%Pool{id: pool_id}, nil), do: %{"pool_id" => pool_id}

  @doc "Whether a deletion job still owns the Pool."
  @spec pending?(Ecto.UUID.t()) :: boolean()
  def pending?(pool_id) when is_binary(pool_id), do: Map.get(states([pool_id]), pool_id) == :in_progress

  @doc """
  The deletion state of each Pool that has one: `:in_progress` while a deletion job is pending or
  running, `:failed` when its latest deletion job was discarded or cancelled and the Pool still
  exists.
  """
  @spec states([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => state()}
  def states([]), do: %{}

  def states(pool_ids) when is_list(pool_ids) do
    from(job in Oban.Job,
      where: job.worker == ^@worker_name and fragment("?->>'pool_id'", job.args) in ^pool_ids,
      where: job.state in ^(@pending_job_states ++ @failed_job_states),
      order_by: [asc: job.id],
      select: {fragment("?->>'pool_id'", job.args), job.state}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {pool_id, job_states} ->
      {pool_id, if(Enum.any?(job_states, &(&1 in @pending_job_states)), do: :in_progress, else: :failed)}
    end)
  end

  defp small_history?(pool_id) do
    limit = immediate_request_limit()

    Repo.one(
      from(request in subquery(from r in "requests", where: r.pool_id == type(^pool_id, :binary_id), limit: ^limit, select: %{id: r.id}),
        select: count()
      )
    ) < limit
  end

  # Tests move the boundary instead of building thousands of requests.
  if Mix.env() == :test do
    defp immediate_request_limit, do: Application.get_env(:codex_pooler, :pool_deletion_immediate_request_limit, @immediate_request_limit)
  else
    defp immediate_request_limit, do: @immediate_request_limit
  end

  defp lock_pool(pool_id), do: Repo.one(from pool in Pool, where: pool.id == ^pool_id, lock: "FOR UPDATE")

  defp put_statement_timeout(ms), do: Repo.query!("SELECT set_config('statement_timeout', $1, true)", ["#{ms}ms"])
end
