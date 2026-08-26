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

  @automatic_reconciliation_unique [
    fields: [:args, :queue, :worker],
    keys: [:upstream_identity_id],
    states: :successful,
    period: 60
  ]
  @scheduled_reconciliation_unique [
    fields: [:args, :queue, :worker],
    keys: [:upstream_identity_id],
    states: :successful,
    period: 55
  ]
  @scheduled_saved_reset_unique [
    fields: [:args, :queue, :worker],
    keys: [:upstream_identity_id],
    states: :incomplete,
    period: :infinity
  ]
  @stale_consuming_recovery_unique [
    fields: [:args, :queue, :worker],
    keys: [:upstream_identity_id, :attempt_id, :generation, :recovery_kind],
    states: :incomplete,
    period: :infinity
  ]
  # Oban applies the unique period to incomplete states too, so an
  # executing/available job older than the cooldown would stop blocking new
  # inserts. The untimed incomplete-state guard below keeps at most one
  # non-terminal automatic reconciliation per identity regardless of its age.
  @incomplete_job_states ~w(suspended available scheduled executing retryable)
  @gateway_reconciliation_gate_seconds 60

  defmodule GatewayReconciliationGate do
    @moduledoc false
    use GenServer

    @table __MODULE__

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl GenServer
    def init(_opts) do
      table =
        :ets.new(@table, [
          :named_table,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      {:ok, %{table: table}}
    end

    @spec claim(String.t(), pos_integer()) :: :ok | :duplicate
    def claim(identity_id, ttl_seconds) do
      now = System.monotonic_time(:second)

      case :ets.lookup(@table, identity_id) do
        [{^identity_id, expires_at}] when expires_at > now ->
          :duplicate

        [{^identity_id, _expires_at} = expired_claim] ->
          :ets.delete_object(@table, expired_claim)
          insert_claim(identity_id, now + ttl_seconds)

        [] ->
          insert_claim(identity_id, now + ttl_seconds)
      end
    end

    @spec release(String.t()) :: true
    def release(identity_id), do: :ets.delete(@table, identity_id)

    defp insert_claim(identity_id, expires_at) do
      if :ets.insert_new(@table, {identity_id, expires_at}), do: :ok, else: :duplicate
    end
  end

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

  @spec enqueue_scheduled_saved_reset_redemption(PoolUpstreamAssignment.t()) ::
          job_insert_result()
  def enqueue_scheduled_saved_reset_redemption(%PoolUpstreamAssignment{} = assignment) do
    with {:ok, assignment_id} <- assignment_id(assignment),
         {:ok, identity_id} <- identity_id(assignment.upstream_identity_id) do
      %{
        "pool_upstream_assignment_id" => assignment_id,
        "upstream_identity_id" => identity_id,
        "target_kind" => "upstream_identity",
        "trigger_kind" => "scheduled_expiry_rescue"
      }
      |> SavedResetRedemptionWorker.new(unique: @scheduled_saved_reset_unique)
      |> Oban.insert()
      |> tap_saved_reset_redemption_enqueue(assignment)
    end
  end

  def enqueue_scheduled_saved_reset_redemption(_assignment),
    do: {:error, :pool_upstream_assignment_id_required}

  @spec enqueue_stale_consuming_saved_reset_recovery(
          assignment_ref(),
          identity_ref(),
          Ecto.UUID.t(),
          non_neg_integer()
        ) :: job_insert_result()
  def enqueue_stale_consuming_saved_reset_recovery(
        assignment_or_id,
        identity_or_id,
        attempt_id,
        generation
      ) do
    with {:ok, assignment_id} <- assignment_id(assignment_or_id),
         {:ok, identity_id} <- identity_id(identity_or_id),
         {:ok, attempt_id} <- Ecto.UUID.cast(attempt_id),
         true <- is_integer(generation) and generation >= 0 do
      %{
        "pool_upstream_assignment_id" => assignment_id,
        "upstream_identity_id" => identity_id,
        "attempt_id" => attempt_id,
        "generation" => generation,
        "recovery_kind" => "stale_consuming"
      }
      |> SavedResetRedemptionWorker.new(unique: @stale_consuming_recovery_unique)
      |> Oban.insert()
      |> tap_saved_reset_redemption_enqueue(assignment_or_id)
    else
      false -> {:error, :saved_reset_recovery_generation_required}
      :error -> {:error, :saved_reset_recovery_attempt_id_required}
      {:error, _reason} -> {:error, :saved_reset_recovery_attempt_id_required}
    end
  end

  @spec enqueue_scheduled_identity_account_reconciliation(PoolUpstreamAssignment.t(), keyword()) ::
          job_insert_result()
  def enqueue_scheduled_identity_account_reconciliation(
        %PoolUpstreamAssignment{} = assignment,
        opts \\ []
      ) do
    enqueue_automatic_identity_account_reconciliation(
      assignment.pool_id,
      assignment,
      Keyword.put_new(opts, :trigger_kind, "scheduled")
    )
  end

  @spec enqueue_gateway_account_reconciliation(pool_ref(), PoolUpstreamAssignment.t()) ::
          job_insert_result()
  def enqueue_gateway_account_reconciliation(pool_or_id, %PoolUpstreamAssignment{} = assignment) do
    with {:ok, pool_id} <- pool_id(pool_or_id) do
      enqueue_automatic_identity_account_reconciliation(
        pool_id,
        assignment,
        trigger_kind: "gateway"
      )
    end
  end

  @spec claim_gateway_reconciliation_gate(UpstreamIdentity.t() | Ecto.UUID.t()) ::
          :ok | :duplicate
  def claim_gateway_reconciliation_gate(identity_or_id) do
    with {:ok, identity_id} <- identity_id(identity_or_id) do
      GatewayReconciliationGate.claim(identity_id, @gateway_reconciliation_gate_seconds)
    end
  end

  @spec release_gateway_reconciliation_gate(UpstreamIdentity.t() | Ecto.UUID.t()) :: true
  def release_gateway_reconciliation_gate(identity_or_id) do
    case identity_id(identity_or_id) do
      {:ok, identity_id} -> GatewayReconciliationGate.release(identity_id)
      {:error, _reason} -> true
    end
  end

  # Scheduled and gateway triggers share one automatic dedup boundary per
  # upstream identity: an incomplete job of either shape blocks a new insert
  # regardless of age, and cancelled/discarded jobs are replaceable immediately.
  # Gateway enqueue attempts retain a 60-second inserted-at cooldown. Scheduled
  # fanout uses 55 seconds so small cron/queue timing differences do not suppress
  # the next minute; the untimed incomplete guard still prevents overlap when
  # reconciliation itself runs longer. The check-then-insert pair is deliberately
  # not serialized here: a racing enqueue falls through to Oban's advisory-locked
  # unique insert and resolves as conflict?: true.
  defp enqueue_automatic_identity_account_reconciliation(pool_id, assignment, opts) do
    args =
      pool_id
      |> account_reconciliation_args(assignment.id, opts)
      |> Map.merge(%{
        "upstream_identity_id" => assignment.upstream_identity_id,
        "target_kind" => "upstream_identity"
      })
      |> maybe_put_recovery_fence(assignment)

    case incomplete_automatic_reconciliation_job(assignment.upstream_identity_id) do
      %Oban.Job{} = job ->
        {:ok, %{job | conflict?: true}}

      nil ->
        args
        |> AccountReconciliationWorker.new(automatic_reconciliation_job_options(opts))
        |> Oban.insert()
    end
    |> tap_job_status_event(pool_id, "account_reconciliation", "scheduled")
  end

  defp incomplete_automatic_reconciliation_job(identity_id) do
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

  defp automatic_reconciliation_job_options(opts) do
    unique =
      if Keyword.get(opts, :trigger_kind) == "scheduled" do
        @scheduled_reconciliation_unique
      else
        @automatic_reconciliation_unique
      end

    opts
    |> Keyword.take([:scheduled_at, :scheduled_in])
    |> Keyword.put(:unique, unique)
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
