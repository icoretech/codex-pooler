defmodule CodexPooler.Upstreams.QuotaReconciliationEnqueue do
  @moduledoc false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Jobs.UpstreamEnqueue
  alias CodexPooler.Repo

  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.{AccountAudit, AccountLifecycle}
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets

  @reconcilable_assignment_statuses [
    PoolUpstreamAssignment.active_status(),
    PoolUpstreamAssignment.refresh_due_status(),
    PoolUpstreamAssignment.refresh_failed_status()
  ]
  @deleted_assignment PoolUpstreamAssignment.deleted_status()

  @type lifecycle_error :: CodexPooler.Upstreams.lifecycle_error()
  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()

  @spec enqueue_for_scope(Scope.t(), identity_ref(), keyword()) ::
          {:ok, map()} | {:error, lifecycle_error() | Ecto.Changeset.t()}
  def enqueue_for_scope(scope, identity_or_id, opts \\ [])

  def enqueue_for_scope(%Scope{} = scope, identity_or_id, opts) when is_list(opts) do
    trigger_kind = Keyword.get(opts, :trigger_kind, "admin_upstreams_live")

    with {:ok, identity} <- AccountLifecycle.authorize(scope, identity_or_id),
         assignments = linked_assignments(identity),
         [_first | _rest] = candidates <- reconcilable_assignments(assignments),
         {:ok, job} <- enqueue_one(candidates, opts, trigger_kind) do
      result = %{
        status: if(job.conflict?, do: :already_queued, else: :queued),
        identity: Repo.reload!(identity),
        assignments: assignments,
        secret_status: Secrets.secret_status(identity),
        job: job
      }

      {:ok, result}
      |> AccountAudit.record_change(scope, "upstream_account.quota_reconciliation_enqueue",
        trigger_kind: trigger_kind,
        job_conflict?: job.conflict?
      )
    else
      [] ->
        {:error,
         CodexPooler.Upstreams.lifecycle_error(
           :quota_reconciliation_unavailable,
           "no active pool assignment is available for quota refresh"
         )}

      {:error, _reason} = error ->
        error
    end
  end

  def enqueue_for_scope(_scope, _identity_or_id, _opts),
    do:
      {:error, CodexPooler.Upstreams.lifecycle_error(:invalid_request, "user scope is required")}

  defp linked_assignments(identity) do
    identity.id
    |> PoolAssignments.list_pool_assignments_for_identity()
    |> Enum.reject(&(&1.status == @deleted_assignment))
  end

  defp reconcilable_assignments(assignments) do
    assignments
    |> Enum.filter(&(&1.status in @reconcilable_assignment_statuses))
  end

  defp enqueue_one([assignment | _rest], opts, trigger_kind) do
    UpstreamEnqueue.enqueue_identity_account_reconciliation(
      assignment.pool_id,
      assignment,
      Keyword.put(opts, :trigger_kind, trigger_kind)
    )
  end
end
