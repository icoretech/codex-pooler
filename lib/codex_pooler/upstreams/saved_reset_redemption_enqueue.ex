defmodule CodexPooler.Upstreams.SavedResetRedemptionEnqueue do
  @moduledoc """
  Scoped admin enqueue API for manual saved reset redemption.
  """

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Events
  alias CodexPooler.Jobs
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.{AccountAudit, AccountLifecycle}
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets

  @assignment_deleted PoolUpstreamAssignment.deleted_status()
  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}

  @spec enqueue_for_scope(
          Scope.t(),
          UpstreamIdentity.t() | Ecto.UUID.t(),
          Ecto.UUID.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, lifecycle_error() | Ecto.Changeset.t()}
  def enqueue_for_scope(scope, identity_or_id, pool_id, opts \\ [])

  def enqueue_for_scope(%Scope{} = scope, identity_or_id, pool_id, opts) do
    with {:ok, identity} <- AccountLifecycle.authorize(scope, identity_or_id),
         {:ok, assignment} <- find_assignment(identity, pool_id),
         {:ok, _assignment, _identity} <- ensure_available(assignment),
         {:ok, job} <-
           Jobs.enqueue_saved_reset_redemption(assignment, trigger_kind: "admin_manual") do
      status = if job.conflict?, do: :already_queued, else: :queued
      result = result(identity, status, job)

      {:ok, result}
      |> AccountAudit.record_change(scope, "upstream_account.saved_reset_redeem_enqueue",
        trigger_kind: Keyword.get(opts, :trigger_kind)
      )
      |> tap_broadcast("upstream_account_saved_reset_redeem_queued")
    end
  end

  def enqueue_for_scope(_scope, _identity_or_id, _pool_id, _opts),
    do: {:error, lifecycle_error(:invalid_request, "user scope is required")}

  defp find_assignment(%UpstreamIdentity{} = identity, pool_id) when is_binary(pool_id) do
    case Repo.one(
           from assignment in PoolUpstreamAssignment,
             where:
               assignment.upstream_identity_id == ^identity.id and assignment.pool_id == ^pool_id and
                 assignment.status != ^@assignment_deleted,
             order_by: [asc: assignment.created_at, asc: assignment.id],
             limit: 1
         ) do
      %PoolUpstreamAssignment{} = assignment ->
        {:ok, assignment}

      nil ->
        {:error, lifecycle_error(:pool_assignment_not_found, "pool assignment was not found")}
    end
  end

  defp find_assignment(_identity, _pool_id),
    do: {:error, lifecycle_error(:pool_assignment_not_found, "pool assignment was not found")}

  defp ensure_available(%PoolUpstreamAssignment{} = assignment) do
    case SavedResetRedemption.ensure_manual_available(assignment) do
      {:error, :redemption_in_progress} ->
        {:error,
         lifecycle_error(
           :saved_reset_redemption_in_progress,
           "saved reset redemption is already in progress"
         )}

      result ->
        result
    end
  end

  defp result(%UpstreamIdentity{} = identity, status, job) do
    identity = Repo.reload!(identity)

    %{
      status: status,
      identity: identity,
      assignments: PoolAssignments.list_pool_assignments_for_identity(identity.id),
      secret_status: Secrets.secret_status(identity),
      job: job
    }
  end

  defp tap_broadcast({:ok, %{assignments: assignments, identity: identity}} = result, reason) do
    Enum.each(assignments, fn assignment ->
      Events.broadcast_upstreams(assignment.pool_id, reason, %{
        assignment_id: assignment.id,
        upstream_identity_id: identity.id
      })
    end)

    result
  end

  defp tap_broadcast(result, _reason), do: result

  defp lifecycle_error(code, message), do: %{code: code, message: message}
end
