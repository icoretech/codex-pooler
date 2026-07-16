defmodule CodexPooler.Upstreams.Assignments do
  @moduledoc """
  Public upstream assignment workflows.

  This module is the caller-facing boundary for pool/upstream assignment reads
  and mutations. The root `CodexPooler.Upstreams` context keeps compatibility
  delegates, but new production callers should depend on this narrower API.
  """

  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()
  @type assignment_ref :: PoolUpstreamAssignment.t() | Ecto.UUID.t()
  @type assignment_result ::
          {:ok, PoolUpstreamAssignment.t()} | {:error, Ecto.Changeset.t() | lifecycle_error()}
  @type lifecycle_result :: {:ok, map()} | {:error, Ecto.Changeset.t() | lifecycle_error()}

  @spec sync_pool_assignments_for_pool_edit(Pool.t(), [Ecto.UUID.t()], keyword()) ::
          :ok | {:error, term()}
  defdelegate sync_pool_assignments_for_pool_edit(pool, selected_ids, opts \\ []),
    to: PoolAssignments

  @spec assign_pool_assignment(Pool.t(), identity_ref(), map()) :: assignment_result()
  defdelegate assign_pool_assignment(pool, identity_or_id, attrs \\ %{}), to: PoolAssignments

  @spec put_assignment_cooldown(assignment_ref(), DateTime.t(), map()) :: assignment_result()
  defdelegate put_assignment_cooldown(assignment_or_id, cooldown_until, attrs \\ %{}),
    to: PoolAssignments

  @spec list_pool_assignments(Pool.t() | Ecto.UUID.t()) :: [PoolUpstreamAssignment.t()]
  defdelegate list_pool_assignments(pool_or_id), to: PoolAssignments

  @spec count_pool_assignments_by_pool_ids([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => non_neg_integer()
        }
  defdelegate count_pool_assignments_by_pool_ids(pool_ids), to: PoolAssignments

  @spec list_active_pool_assignments(Pool.t() | Ecto.UUID.t()) :: [PoolUpstreamAssignment.t()]
  defdelegate list_active_pool_assignments(pool_or_id), to: PoolAssignments

  @spec list_pool_assignments_for_identity(identity_ref()) :: [PoolUpstreamAssignment.t()]
  defdelegate list_pool_assignments_for_identity(identity_or_id), to: PoolAssignments

  @spec list_eligible_pool_assignments(Pool.t() | Ecto.UUID.t(), keyword()) ::
          [PoolUpstreamAssignment.t()]
  defdelegate list_eligible_pool_assignments(pool_or_id, opts \\ []), to: PoolAssignments

  @spec reconcile_pool_account(Pool.t() | Ecto.UUID.t(), assignment_ref(), keyword()) ::
          lifecycle_result()
  defdelegate reconcile_pool_account(pool_or_id, assignment_or_id, opts \\ []),
    to: CodexPooler.Upstreams.Reconciliation.PoolReconciliation
end
