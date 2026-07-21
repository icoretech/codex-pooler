defmodule CodexPooler.Accounting.RequestLifecycle.ReferenceLocks do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.Metadata
  alias CodexPooler.Repo

  alias CodexPooler.Upstreams.Schemas.{
    PoolUpstreamAssignment,
    UpstreamIdentity
  }

  @type identity_id :: Ecto.UUID.t() | nil
  @type assignment_id :: Ecto.UUID.t() | nil

  @spec lock_and_validate!(identity_id(), assignment_id()) :: :ok | no_return()
  def lock_and_validate!(upstream_identity_id, pool_upstream_assignment_id) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "upstream reference locks require an active transaction"
    end

    lock_pair!(upstream_identity_id, pool_upstream_assignment_id)
  end

  defp lock_pair!(nil, nil), do: :ok

  defp lock_pair!(nil, _pool_upstream_assignment_id) do
    rollback!(:upstream_identity_not_found, "upstream identity was not found")
  end

  defp lock_pair!(_upstream_identity_id, nil) do
    rollback!(:pool_upstream_assignment_not_found, "pool upstream assignment was not found")
  end

  defp lock_pair!(upstream_identity_id, pool_upstream_assignment_id) do
    identity =
      Repo.one(
        from identity in UpstreamIdentity,
          where: identity.id == ^upstream_identity_id,
          lock: "FOR KEY SHARE"
      ) || rollback!(:upstream_identity_not_found, "upstream identity was not found")

    assignment =
      Repo.one(
        from assignment in PoolUpstreamAssignment,
          where: assignment.id == ^pool_upstream_assignment_id,
          lock: "FOR SHARE"
      ) ||
        rollback!(:pool_upstream_assignment_not_found, "pool upstream assignment was not found")

    if assignment.upstream_identity_id == identity.id do
      :ok
    else
      rollback!(
        :upstream_reference_mismatch,
        "pool upstream assignment does not belong to upstream identity"
      )
    end
  end

  defp rollback!(code, message), do: Repo.rollback(Metadata.accounting_error(code, message))
end
