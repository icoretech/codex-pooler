defmodule CodexPooler.Jobs.UpstreamEnqueue do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Events

  alias CodexPooler.Jobs.{
    AccountReconciliationWorker,
    Options,
    SavedResetRedemptionWorker,
    TokenRefreshWorker
  }

  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
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

  @identity_reconciliation_unique [
    fields: [:args, :queue, :worker],
    keys: [:upstream_identity_id],
    states: :successful,
    period: 60
  ]
  # Oban applies the unique period to incomplete states too, so an
  # executing/available job older than the cooldown would stop blocking new
  # inserts. The untimed incomplete-state guard below keeps at most one
  # non-terminal automatic reconciliation per identity regardless of its age.
  @incomplete_job_states ~w(suspended available scheduled executing retryable)

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
    enqueue_identity_account_reconciliation(
      assignment.pool_id,
      assignment,
      Keyword.put_new(opts, :trigger_kind, "scheduled")
    )
  end

  @spec enqueue_identity_account_reconciliation(
          pool_ref(),
          PoolUpstreamAssignment.t(),
          keyword()
        ) :: job_insert_result()
  def enqueue_identity_account_reconciliation(
        pool_or_id,
        %PoolUpstreamAssignment{} = assignment,
        opts \\ []
      ) do
    with {:ok, pool_id} <- pool_id(pool_or_id) do
      enqueue_identity_scoped_account_reconciliation(pool_id, assignment, opts)
    end
  end

  @spec enqueue_gateway_account_reconciliation(pool_ref(), PoolUpstreamAssignment.t()) ::
          job_insert_result()
  def enqueue_gateway_account_reconciliation(pool_or_id, %PoolUpstreamAssignment{} = assignment) do
    enqueue_identity_account_reconciliation(pool_or_id, assignment, trigger_kind: "gateway")
  end

  # Scheduled, gateway, and admin triggers share one dedup boundary per
  # upstream identity: an incomplete job of any shape blocks a new insert
  # regardless of age, a completed job imposes the 60-second inserted-at
  # cooldown from the Oban unique config, and cancelled/discarded jobs are
  # replaceable immediately. The check-then-insert pair is deliberately not
  # serialized here: a racing enqueue falls through to Oban's advisory-locked
  # unique insert and resolves as conflict?: true.
  defp enqueue_identity_scoped_account_reconciliation(pool_id, assignment, opts) do
    args =
      pool_id
      |> account_reconciliation_args(assignment.id, opts)
      |> Map.merge(%{
        "upstream_identity_id" => assignment.upstream_identity_id,
        "target_kind" => "upstream_identity"
      })
      |> maybe_put_recovery_fence(assignment)

    case incomplete_identity_reconciliation_job(assignment.upstream_identity_id) do
      %Oban.Job{} = job ->
        {:ok, %{job | conflict?: true}}

      nil ->
        args
        |> AccountReconciliationWorker.new(identity_reconciliation_job_options(opts))
        |> Oban.insert()
    end
    |> tap_job_status_event(pool_id, "account_reconciliation", "scheduled")
  end

  defp incomplete_identity_reconciliation_job(identity_id) do
    worker = Oban.Worker.to_string(AccountReconciliationWorker)

    Oban.Job
    |> where([job], job.worker == ^worker and job.state in ^@incomplete_job_states)
    |> where(
      [job],
      fragment("?->>'upstream_identity_id' = ?", job.args, ^identity_id) or
        fragment(
          # Legacy gateway jobs enqueued by not-yet-upgraded nodes carry only
          # the assignment; resolve them to the identity. Remove one release
          # after every node writes identity-shaped args.
          """
          EXISTS (
            SELECT 1
            FROM pool_upstream_assignments AS reconciliation_assignment
            WHERE reconciliation_assignment.id::text = ?->>'pool_upstream_assignment_id'
              AND reconciliation_assignment.upstream_identity_id::text = ?
          )
          """,
          job.args,
          ^identity_id
        )
    )
    |> order_by([job], desc: job.inserted_at, desc: job.id)
    |> limit(1)
    |> Repo.one()
  end

  defp identity_reconciliation_job_options(opts) do
    opts
    |> Keyword.take([:scheduled_at, :schedule_in])
    |> Keyword.put(:unique, identity_reconciliation_unique(opts))
  end

  # A quota confirmation must run after its evidence span even when another
  # reconciliation completed inside the normal 60-second enqueue cooldown.
  # The explicit incomplete-job query above still prevents overlap, while this
  # narrower Oban boundary retains advisory-lock protection for enqueue races.
  defp identity_reconciliation_unique(opts) do
    if Keyword.get(opts, :bypass_successful_cooldown?, false) do
      Keyword.put(@identity_reconciliation_unique, :states, :incomplete)
    else
      @identity_reconciliation_unique
    end
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
