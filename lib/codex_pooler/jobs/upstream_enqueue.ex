defmodule CodexPooler.Jobs.UpstreamEnqueue do
  @moduledoc false

  alias CodexPooler.Events

  alias CodexPooler.Jobs.{
    AccountReconciliationWorker,
    Options,
    SavedResetRedemptionWorker,
    TokenRefreshWorker
  }

  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @type pool_ref :: Pool.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type assignment_ref ::
          PoolUpstreamAssignment.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type identity_ref :: UpstreamIdentity.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type missing_ref_error ::
          :pool_id_required
          | :pool_upstream_assignment_id_required
          | :upstream_identity_id_required
  @type job_insert_result ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t() | missing_ref_error()}

  @spec enqueue_token_refresh(identity_ref(), keyword()) :: job_insert_result()
  def enqueue_token_refresh(identity_or_id, opts \\ []) do
    with {:ok, identity_id} <- identity_id(identity_or_id) do
      %{
        "upstream_identity_id" => identity_id,
        "trigger_kind" => Keyword.get(opts, :trigger_kind, "manual")
      }
      |> TokenRefreshWorker.new(Options.job_options(opts, unique_keys: [:upstream_identity_id]))
      |> Oban.insert()
    end
  end

  @spec enqueue_assignment_priming(pool_ref(), assignment_ref(), keyword()) ::
          job_insert_result() | {:error, term()}
  def enqueue_assignment_priming(pool_or_id, assignment_or_id, opts \\ []) do
    trigger_kind = Keyword.get(opts, :trigger_kind, "account_link")

    with {:ok, pool_id} <- pool_id(pool_or_id),
         {:ok, assignment_id} <- assignment_id(assignment_or_id),
         {:ok, _assignment} <-
           Quota.PrimingState.record(pool_id, assignment_id, %{
             "status" => "unknown",
             "trigger_kind" => trigger_kind,
             "enqueued_at" => timestamp_iso()
           }) do
      enqueue_account_reconciliation(
        pool_id,
        assignment_id,
        Keyword.put(opts, :trigger_kind, trigger_kind)
      )
      |> tap_assignment_priming_enqueue_result(pool_id, assignment_id, trigger_kind)
    end
  end

  @spec enqueue_account_reconciliation(pool_ref(), assignment_ref(), keyword()) ::
          job_insert_result()
  def enqueue_account_reconciliation(pool_or_id, assignment_or_id, opts \\ []) do
    with {:ok, pool_id} <- pool_id(pool_or_id),
         {:ok, assignment_id} <- assignment_id(assignment_or_id) do
      pool_id
      |> account_reconciliation_args(assignment_id, opts)
      |> maybe_put_recovery_fence(assignment_or_id)
      |> AccountReconciliationWorker.new(
        Options.job_options(opts, unique_keys: [:pool_id, :pool_upstream_assignment_id])
      )
      |> Oban.insert()
      |> tap_job_status_event(pool_id, "account_reconciliation", "scheduled")
    end
  end

  @spec enqueue_saved_reset_redemption(assignment_ref(), keyword()) :: job_insert_result()
  def enqueue_saved_reset_redemption(assignment_or_id, opts \\ []) do
    with {:ok, assignment_id} <- assignment_id(assignment_or_id) do
      %{
        "pool_upstream_assignment_id" => assignment_id,
        "trigger_kind" => Keyword.get(opts, :trigger_kind, "admin_manual")
      }
      |> SavedResetRedemptionWorker.new(
        Options.job_options(opts, unique_keys: [:pool_upstream_assignment_id])
      )
      |> Oban.insert()
      |> tap_saved_reset_redemption_enqueue(assignment_or_id)
    end
  end

  @spec enqueue_scheduled_identity_account_reconciliation(PoolUpstreamAssignment.t(), keyword()) ::
          job_insert_result()
  def enqueue_scheduled_identity_account_reconciliation(
        %PoolUpstreamAssignment{} = assignment,
        opts \\ []
      ) do
    assignment.pool_id
    |> account_reconciliation_args(assignment.id, opts)
    |> Map.merge(%{
      "upstream_identity_id" => assignment.upstream_identity_id,
      "target_kind" => "upstream_identity"
    })
    |> maybe_put_recovery_fence(assignment)
    |> AccountReconciliationWorker.new(
      Options.job_options(opts, unique_keys: [:upstream_identity_id, :trigger_kind])
    )
    |> Oban.insert()
    |> tap_job_status_event(assignment.pool_id, "account_reconciliation", "scheduled")
  end

  defp tap_job_status_event(
         {:ok, %Oban.Job{conflict?: true}} = result,
         _pool_id,
         _worker,
         _status
       ),
       do: result

  defp tap_job_status_event({:ok, job} = result, pool_id, worker, status) do
    Events.broadcast_job_status(pool_id, "job_status_updated", %{
      id: Integer.to_string(job.id),
      worker: worker,
      status: status
    })

    result
  end

  defp tap_job_status_event(result, _pool_id, _worker, _status), do: result

  defp tap_saved_reset_redemption_enqueue(
         {:ok, %Oban.Job{conflict?: true}} = result,
         _assignment_or_id
       ),
       do: result

  defp tap_saved_reset_redemption_enqueue(
         {:ok, job} = result,
         %PoolUpstreamAssignment{} = assignment
       ) do
    Events.broadcast_job_status(assignment.pool_id, "saved_reset_redemption", %{
      pool_upstream_assignment_id: assignment.id,
      id: Integer.to_string(job.id),
      worker: "saved_reset_redemption",
      status: "scheduled"
    })

    result
  end

  defp tap_saved_reset_redemption_enqueue(result, _assignment_or_id), do: result

  defp tap_assignment_priming_enqueue_result(
         {:ok, %Oban.Job{conflict?: true}} = result,
         pool_id,
         assignment_id,
         trigger_kind
       ) do
    _record =
      Quota.PrimingState.record(pool_id, assignment_id, %{
        "status" => "blocked",
        "trigger_kind" => trigger_kind,
        "blocked_at" => timestamp_iso(),
        "reason" => %{
          "code" => "oban_unique_conflict",
          "message" => "account reconciliation is already queued"
        }
      })

    result
  end

  defp tap_assignment_priming_enqueue_result(result, _pool_id, _assignment_id, _trigger_kind),
    do: result

  defp timestamp_iso,
    do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp account_reconciliation_args(pool_id, assignment_id, opts) do
    %{
      "pool_id" => pool_id,
      "pool_upstream_assignment_id" => assignment_id,
      "trigger_kind" => Keyword.get(opts, :trigger_kind, "manual")
    }
  end

  defp maybe_put_recovery_fence(args, %PoolUpstreamAssignment{} = assignment) do
    if CredentialFencing.awaiting_provider_auth_recovery?(assignment.upstream_identity_id) do
      args
      |> Map.put("upstream_identity_id", assignment.upstream_identity_id)
      |> Map.put(
        "credential_epoch",
        CredentialFencing.credential_epoch(assignment.upstream_identity_id)
      )
      |> Map.put("recovery_required", true)
    else
      args
    end
  end

  defp maybe_put_recovery_fence(args, _assignment), do: args

  defp pool_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp pool_id(id) when is_binary(id), do: {:ok, id}
  defp pool_id(_id), do: {:error, :pool_id_required}

  defp assignment_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp assignment_id(id) when is_binary(id), do: {:ok, id}
  defp assignment_id(_id), do: {:error, :pool_upstream_assignment_id_required}

  defp identity_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp identity_id(id) when is_binary(id), do: {:ok, id}
  defp identity_id(_id), do: {:error, :upstream_identity_id_required}
end
