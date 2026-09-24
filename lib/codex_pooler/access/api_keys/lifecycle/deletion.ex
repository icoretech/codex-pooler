defmodule CodexPooler.Access.APIKeys.Deletion do
  @moduledoc """
  Deletes an API key, in the background when its history is large.

  Deleting an `api_keys` row keeps the key's requests and ledger entries and sets their
  `api_key_id` to NULL by foreign key, in one statement. The ledger update also runs the usage
  component trigger over every updated row. On a production-sized database a key with 177 thousand
  requests and 140 thousand ledger rows needed 110 s (ledger SET NULL 36 s, its trigger 38 s,
  requests SET NULL 30 s), and the busiest key, with 834 thousand requests and 2.2 million ledger
  rows, would need many minutes. The Repo cancelled such a delete at its 15 s timeout, and the
  admin page crashed on the error (findings#206 row 206-561). So:

    * a key with a small history is deleted at once, in one transaction bounded by a 10 s
      statement timeout;
    * a larger key, or one whose immediate delete runs out of that bound, is revoked at once,
      so it stops working, and handed to `CodexPooler.Jobs.APIKeyDeletionWorker`. The job
      detaches the history in batches and deletes the key's sessions and bridge rows, each batch
      in its own short transaction, and then deletes the key row.

  A revoked key cannot be resumed, so nothing brings it back while the job runs. The pending
  deletion job marks the key as being deleted (`states/1`). The `api_key.delete` audit event is
  written in the transaction that deletes the key row, in both paths.
  """

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.APIKeys
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Jobs.APIKeyDeletionWorker
  alias CodexPooler.Repo

  @status_revoked "revoked"
  @immediate_request_limit 2_000
  @immediate_ledger_limit 5_000
  @immediate_statement_timeout_ms 10_000
  @batch_statement_timeout_ms 30_000
  @final_statement_timeout_ms 60_000
  # A literal, not `inspect(APIKeyDeletionWorker)`: a module attribute is evaluated at compile
  # time and would make this context a compile-time dependent of the worker.
  @worker_name "CodexPooler.Jobs.APIKeyDeletionWorker"
  @pending_job_states ~w(available scheduled executing retryable)
  @failed_job_states ~w(discarded cancelled)

  # {:detach | :delete, table, rows per batch}; every condition is `api_key_id = $1`, which the
  # foreign key indexes serve. History is detached, as the foreign key's SET NULL would do; the
  # rows the key owns are deleted, as its CASCADE would do.
  @history_steps [
    {:detach, "requests", 2_000},
    {:detach, "ledger_entries", 1_000},
    {:delete, "codex_sessions", 500},
    {:delete, "bridge_session_aliases", 5_000},
    {:delete, "bridge_owner_leases", 5_000},
    {:delete, "bridge_affinities", 5_000},
    {:delete, "bridge_demotions", 5_000},
    {:delete, "api_key_usage_buckets", 5_000},
    {:delete, "daily_rollups", 5_000}
  ]

  @type state :: :in_progress | :failed
  @type request_result :: {:ok, APIKey.t()} | {:deleting, APIKey.t()} | {:error, term()}

  @doc """
  Deletes `api_key` at once when its history is small enough, otherwise revokes it and schedules
  its deletion. The caller has authorized the delete.
  """
  @spec request(Scope.t(), APIKey.t()) :: request_result()
  def request(%Scope{} = scope, %APIKey{} = api_key) do
    cond do
      pending?(api_key.id) -> {:deleting, api_key}
      small_history?(api_key.id) -> delete_now_or_schedule(scope, api_key)
      true -> schedule(scope, api_key)
    end
  end

  defp delete_now_or_schedule(scope, api_key) do
    case APIKeys.delete_api_key_row(scope, api_key, @immediate_statement_timeout_ms) do
      {:error, :statement_timeout} -> schedule(scope, api_key)
      result -> result
    end
  end

  @doc """
  Revokes the key, so it stops admitting work at once, and inserts its deletion job.
  """
  @spec schedule(Scope.t(), APIKey.t()) :: request_result()
  def schedule(%Scope{} = scope, %APIKey{} = api_key) do
    with {:ok, revoked} <- ensure_revoked(scope, api_key),
         {:ok, _job} <- Oban.insert(APIKeyDeletionWorker.new(job_args(revoked, scope))) do
      {:deleting, revoked}
    end
  end

  defp ensure_revoked(_scope, %APIKey{status: @status_revoked} = api_key), do: {:ok, api_key}
  defp ensure_revoked(scope, %APIKey{} = api_key), do: APIKeys.revoke_api_key(scope, api_key)

  defp job_args(%APIKey{id: api_key_id}, %Scope{user: %User{id: user_id}}),
    do: %{"api_key_id" => api_key_id, "requested_by_user_id" => user_id}

  defp job_args(%APIKey{id: api_key_id}, %Scope{}), do: %{"api_key_id" => api_key_id}

  @doc """
  Continues a scheduled deletion: history batches until `deadline` (monotonic milliseconds), then
  the key row with its audit event. `:more` while history is left, `:deleted` once the key is
  gone, `:gone` when there was nothing to delete.
  """
  @spec continue(Ecto.UUID.t(), Ecto.UUID.t() | nil, integer()) ::
          :more | :deleted | :gone | {:cancel, :api_key_not_revoked} | {:error, term()}
  def continue(api_key_id, requested_by_user_id, deadline) when is_binary(api_key_id) do
    case Repo.get(APIKey, api_key_id) do
      nil ->
        :gone

      %APIKey{status: @status_revoked} = api_key ->
        with :done <- purge_history(api_key.id, deadline) do
          finish(api_key, requested_by_user_id)
        end

      %APIKey{} ->
        {:cancel, :api_key_not_revoked}
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, error}
  end

  defp finish(api_key, requested_by_user_id) do
    user = if is_binary(requested_by_user_id), do: Repo.get(User, requested_by_user_id)

    case APIKeys.delete_api_key_row(%Scope{user: user}, api_key, @final_statement_timeout_ms) do
      {:ok, _deleted} -> :deleted
      {:error, %{code: :api_key_not_found}} -> :gone
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec purge_history(Ecto.UUID.t(), integer()) :: :done | :more
  def purge_history(api_key_id, deadline) when is_binary(api_key_id),
    do: purge_steps(@history_steps, Ecto.UUID.dump!(api_key_id), deadline)

  defp purge_steps([], _api_key_id, _deadline), do: :done

  defp purge_steps([{kind, table, batch} | rest] = steps, api_key_id, deadline) do
    cond do
      System.monotonic_time(:millisecond) >= deadline -> :more
      run_batch(kind, table, batch, api_key_id) < batch -> purge_steps(rest, api_key_id, deadline)
      true -> purge_steps(steps, api_key_id, deadline)
    end
  end

  defp run_batch(kind, table, batch, api_key_id) do
    rows = "ARRAY(SELECT ctid FROM #{table} WHERE api_key_id = $1 LIMIT $2)"

    sql =
      case kind do
        :detach -> "UPDATE #{table} SET api_key_id = NULL WHERE ctid = ANY(#{rows})"
        :delete -> "DELETE FROM #{table} WHERE ctid = ANY(#{rows})"
      end

    {:ok, count} =
      Repo.transaction(fn ->
        Repo.query!("SELECT set_config('statement_timeout', $1, true)", ["#{@batch_statement_timeout_ms}ms"])
        %{num_rows: count} = Repo.query!(sql, [api_key_id, batch], timeout: @batch_statement_timeout_ms + 5_000)
        count
      end)

    count
  end

  @doc "Whether a deletion job still owns the key."
  @spec pending?(Ecto.UUID.t()) :: boolean()
  def pending?(api_key_id) when is_binary(api_key_id), do: Map.get(states([api_key_id]), api_key_id) == :in_progress

  @doc """
  The deletion state of each key that has one: `:in_progress` while a deletion job is pending or
  running, `:failed` when its latest deletion job was discarded or cancelled and the key exists.
  """
  @spec states([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => state()}
  def states([]), do: %{}

  def states(api_key_ids) when is_list(api_key_ids) do
    from(job in Oban.Job,
      where: job.worker == ^@worker_name and fragment("?->>'api_key_id'", job.args) in ^api_key_ids,
      where: job.state in ^(@pending_job_states ++ @failed_job_states),
      select: {fragment("?->>'api_key_id'", job.args), job.state}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {api_key_id, job_states} ->
      {api_key_id, if(Enum.any?(job_states, &(&1 in @pending_job_states)), do: :in_progress, else: :failed)}
    end)
  end

  defp small_history?(api_key_id) do
    under_limit?("requests", api_key_id, immediate_limit(:requests)) and
      under_limit?("ledger_entries", api_key_id, immediate_limit(:ledger_entries))
  end

  defp under_limit?(table, api_key_id, limit) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM (SELECT 1 FROM #{table} WHERE api_key_id = $1 LIMIT $2) bounded",
        [Ecto.UUID.dump!(api_key_id), limit]
      )

    count < limit
  end

  # Tests move the boundary instead of building thousands of requests.
  if Mix.env() == :test do
    defp immediate_limit(:requests),
      do: Application.get_env(:codex_pooler, :api_key_deletion_immediate_request_limit, @immediate_request_limit)

    defp immediate_limit(:ledger_entries),
      do: Application.get_env(:codex_pooler, :api_key_deletion_immediate_ledger_limit, @immediate_ledger_limit)
  else
    defp immediate_limit(:requests), do: @immediate_request_limit
    defp immediate_limit(:ledger_entries), do: @immediate_ledger_limit
  end
end
