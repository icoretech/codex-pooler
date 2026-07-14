defmodule CodexPooler.Admin.UpstreamAssignmentWorkflow do
  @moduledoc """
  Coordinates the operator workflow for attaching an existing upstream identity to a Pool.
  """

  require Logger

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit
  alias CodexPooler.Events
  alias CodexPooler.Jobs
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments, as: UpstreamAssignments
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @audit_action "upstream_account.assign_pool"
  @catalog_trigger_kind "manual"

  @type workflow_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type workflow_result ::
          {:ok, PoolUpstreamAssignment.t()}
          | {:error, Ecto.Changeset.t() | workflow_error()}

  @spec assign_to_pool(Scope.t(), Pool.t(), UpstreamIdentity.t() | Ecto.UUID.t()) ::
          workflow_result()
  def assign_to_pool(
        %Scope{user: %User{}} = scope,
        %Pool{} = pool,
        identity_or_id
      ) do
    with {:ok, _decision} <-
           Pools.require_capability(scope, Pools.capability(:pool_operate), pool_id: pool.id),
         {:ok, identity} <- authorize_identity(scope, identity_or_id),
         {:ok, assignment} <- UpstreamAssignments.assign_pool_assignment(pool, identity) do
      record_audit(scope, pool, identity, assignment)
      broadcast_assignment(pool, identity, assignment)
      enqueue_catalog_sync(pool)

      {:ok, assignment}
    end
  end

  def assign_to_pool(_scope, _pool, _identity_or_id),
    do: {:error, workflow_error(:invalid_request, "user scope and Pool are required")}

  defp authorize_identity(%Scope{} = scope, identity_or_id) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{} = identity ->
        authorize_loaded_identity(scope, identity)

      nil ->
        {:error, workflow_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  defp authorize_loaded_identity(scope, identity) do
    if Pools.owner?(scope) or visible_identity?(scope, identity.id) do
      {:ok, identity}
    else
      {:error,
       workflow_error(
         :capability_denied,
         "the upstream identity is not available in the operator's Pool scope"
       )}
    end
  end

  defp visible_identity?(scope, identity_id) do
    scope
    |> Upstreams.list_visible_upstream_identities()
    |> Enum.any?(&(&1.id == identity_id))
  end

  defp normalize_identity(%UpstreamIdentity{id: identity_id}),
    do: Upstreams.get_upstream_identity(identity_id)

  defp normalize_identity(identity_id) when is_binary(identity_id),
    do: Upstreams.get_upstream_identity(identity_id)

  defp normalize_identity(_identity_or_id), do: nil

  defp record_audit(%Scope{user: %User{} = user}, pool, identity, assignment) do
    Audit.record_user_event(user, %{
      pool_id: pool.id,
      action: @audit_action,
      target_type: "upstream_identity",
      target_id: identity.id,
      details: %{
        upstream_identity_id: identity.id,
        pool_assignment_ids: [assignment.id],
        assignment_status: assignment.status
      }
    })

    :ok
  end

  defp broadcast_assignment(pool, identity, assignment) do
    Events.broadcast_upstreams(pool, "upstream_assignment_assigned", %{
      assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      assignment_status: assignment.status
    })

    :ok
  end

  defp enqueue_catalog_sync(pool) do
    case Jobs.enqueue_catalog_sync(pool, trigger_kind: @catalog_trigger_kind) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          "upstream assignment catalog sync enqueue failed pool_id=#{pool.id} " <>
            "trigger_kind=#{@catalog_trigger_kind} reason=#{catalog_enqueue_error_code(reason)}"
        end)

        :ok
    end
  end

  defp catalog_enqueue_error_code(%Ecto.Changeset{}), do: "invalid_job"
  defp catalog_enqueue_error_code(%{code: code}) when is_atom(code), do: Atom.to_string(code)
  defp catalog_enqueue_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp catalog_enqueue_error_code(_reason), do: "unknown"

  defp workflow_error(code, message), do: %{code: code, message: message}
end
