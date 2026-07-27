defmodule CodexPooler.Jobs.AccountReconciliationWorker do
  @moduledoc """
  Refreshes one pool assignment's account health, quota windows, and catalog state.

  Automatic jobs may target an upstream identity for dedupe and operator display while
  still carrying the assignment used to execute reconciliation.
  """

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 1,
    tags: ["account_reconciliation"],
    unique: [
      fields: [:args, :queue, :worker],
      keys: [:pool_id, :pool_upstream_assignment_id],
      states: :incomplete,
      period: {7, :days}
    ]

  alias CodexPooler.Jobs
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Reconciliation.AccountReconciliation
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @dev_features_build_enabled Application.compile_env(
                                :codex_pooler,
                                :dev_features_build_enabled,
                                false
                              )

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.minutes(20)

  @impl Oban.Worker
  if @dev_features_build_enabled do
    alias CodexPooler.Jobs.DevelopmentControls

    def perform(%Oban.Job{
          args:
            %{
              "pool_id" => pool_id,
              "pool_upstream_assignment_id" => assignment_id
            } = args
        }) do
      if DevelopmentControls.account_reconciliation_paused?() do
        :ok
      else
        run_account_reconciliation(pool_id, assignment_id, args)
      end
    end
  else
    def perform(%Oban.Job{
          args:
            %{
              "pool_id" => pool_id,
              "pool_upstream_assignment_id" => assignment_id
            } = args
        }) do
      run_account_reconciliation(pool_id, assignment_id, args)
    end
  end

  defp run_account_reconciliation(pool_id, assignment_id, args) do
    if recovery_probe_required?(args) do
      trigger_kind = Map.get(args, "trigger_kind", "manual")
      reconciliation_started_at = now()

      case AccountReconciliation.run(pool_id, assignment_id, trigger_kind) do
        {:ok, result} ->
          complete_reconciliation(args, result, reconciliation_started_at)

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp complete_reconciliation(args, result, reconciliation_started_at) do
    case maybe_enqueue_scheduled_expiry_rescue(args, result, reconciliation_started_at) do
      :ok -> reconciliation_outcome(result)
      {:error, reason} -> {:error, reason}
    end
  end

  defp recovery_probe_required?(%{
         "recovery_required" => true,
         "upstream_identity_id" => identity_id,
         "credential_epoch" => credential_epoch
       }) do
    CredentialFencing.current_credential_epoch?(identity_id, credential_epoch) and
      CredentialFencing.awaiting_provider_auth_recovery?(identity_id)
  end

  defp recovery_probe_required?(_args), do: true

  defp maybe_enqueue_scheduled_expiry_rescue(
         %{
           "trigger_kind" => "scheduled",
           "target_kind" => "upstream_identity",
           "upstream_identity_id" => identity_id
         } = args,
         %{
           quota: %{status: :succeeded, code: "quota_refreshed"},
           identity: %UpstreamIdentity{id: result_identity_id},
           assignment: %PoolUpstreamAssignment{} = result_assignment
         },
         %DateTime{} = reconciliation_started_at
       )
       when is_binary(identity_id) and byte_size(identity_id) > 0 do
    with true <- String.trim(identity_id) != "",
         true <- identity_id == result_identity_id,
         true <- identity_id == result_assignment.upstream_identity_id,
         true <- Map.get(args, "pool_upstream_assignment_id") == result_assignment.id,
         true <- Map.get(args, "pool_id") == result_assignment.pool_id,
         %UpstreamIdentity{} = identity <- Upstreams.get_upstream_identity(identity_id),
         %PoolUpstreamAssignment{} = canonical_assignment <-
           canonical_active_assignment(identity),
         true <- canonical_assignment.id == result_assignment.id,
         true <- saved_reset_observed_at_or_after?(identity, reconciliation_started_at) do
      enqueue_scheduled_expiry_rescue(identity, canonical_assignment)
    else
      _noncanonical_or_nonfresh -> :ok
    end
  end

  defp maybe_enqueue_scheduled_expiry_rescue(_args, _result, _reconciliation_started_at),
    do: :ok

  defp canonical_active_assignment(%UpstreamIdentity{} = identity) do
    identity
    |> PoolAssignments.list_pool_assignments_for_identity()
    |> Enum.map(& &1.pool_id)
    |> PoolAssignments.list_canonical_active_assignments_for_pools()
    |> Enum.find(&(&1.upstream_identity_id == identity.id))
  end

  defp saved_reset_observed_at_or_after?(identity, reconciliation_started_at) do
    with observed_at when is_binary(observed_at) <-
           get_in(identity.metadata || %{}, ["saved_resets", "observed_at"]),
         {:ok, observed_at, _offset} <- DateTime.from_iso8601(observed_at) do
      DateTime.compare(observed_at, reconciliation_started_at) != :lt
    else
      _missing_or_invalid -> false
    end
  end

  defp enqueue_scheduled_expiry_rescue(identity, assignment) do
    if AutoEligibility.scheduled_expiry_candidate?(identity, now()) do
      case Jobs.enqueue_scheduled_saved_reset_redemption(assignment) do
        {:ok, %Oban.Job{}} -> :ok
        {:error, _reason} -> {:error, "scheduled saved-reset redemption enqueue failed"}
      end
    else
      :ok
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    min(trunc(:math.pow(2, attempt) * 15), 3_600)
  end

  @spec reconciliation_outcome(map()) :: :ok | {:error, String.t()}
  defp reconciliation_outcome(result) do
    if AccountReconciliation.successful_status?(result) do
      :ok
    else
      {:error, "account reconciliation #{result.status}: #{first_failure_code(result)}"}
    end
  end

  defp first_failure_code(result) do
    [result.health, result.quota, result.catalog]
    |> Enum.find(&(&1.status == :failed))
    |> case do
      %{code: code} -> code
      nil -> "failed"
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
