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

  alias CodexPooler.Jobs.AccountQuotaConfirmationWorker
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Reconciliation.AccountReconciliation

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

      with {:ok, result} <- AccountReconciliation.run(pool_id, assignment_id, trigger_kind),
           :ok <- enqueue_quota_confirmation(result, trigger_kind) do
        reconciliation_outcome(result)
      end
    else
      :ok
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

  defp enqueue_quota_confirmation(result, trigger_kind) do
    case AccountQuotaConfirmationWorker.enqueue_if_pending(result, trigger_kind) do
      :not_needed -> :ok
      {:ok, %Oban.Job{}} -> :ok
      {:error, _changeset} -> {:error, "quota confirmation enqueue failed"}
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
end
