defmodule CodexPooler.Upstreams.Quota.PrimingState do
  @moduledoc false

  alias CodexPooler.Events
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.StatusVocabulary.Assignment, as: AssignmentStatus
  alias CodexPooler.Upstreams.StatusVocabulary.Identity, as: IdentityStatus

  @active IdentityStatus.active_status()
  @assignment_active AssignmentStatus.active_status()
  @eligible AssignmentStatus.eligible_status()
  @health_active AssignmentStatus.active_health_status()

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type assignment_ref :: PoolUpstreamAssignment.t() | Ecto.UUID.t()

  @spec candidate?(assignment_ref()) :: boolean()
  def candidate?(assignment_or_id) do
    with %PoolUpstreamAssignment{} = assignment <- normalize_assignment(assignment_or_id),
         %UpstreamIdentity{} = identity <- normalize_identity(assignment.upstream_identity_id) do
      candidate_assignment?(assignment, identity) and primed_candidate?(assignment)
    else
      _missing -> false
    end
  end

  @spec record(Pool.t() | Ecto.UUID.t(), assignment_ref(), map()) ::
          {:ok, PoolUpstreamAssignment.t()} | {:error, lifecycle_error()}
  def record(pool_or_id, assignment_or_id, attrs) when is_map(attrs) do
    pool_id = pool_id(pool_or_id)
    assignment_id = assignment_id(assignment_or_id)

    case Repo.get_by(PoolUpstreamAssignment, id: assignment_id, pool_id: pool_id) do
      %PoolUpstreamAssignment{} = assignment ->
        assignment
        |> PoolUpstreamAssignment.changeset(%{
          metadata: Map.put(assignment.metadata || %{}, "quota_priming", attrs)
        })
        |> Repo.update()
        |> tap_priming_change(pool_id)

      nil ->
        {:error,
         lifecycle_error(:pool_upstream_assignment_not_found, "pool assignment was not found")}
    end
  end

  def record(_pool_or_id, _assignment_or_id, _attrs),
    do: {:error, lifecycle_error(:invalid_request, "quota priming metadata is invalid")}

  defp candidate_assignment?(
         %PoolUpstreamAssignment{} = assignment,
         %UpstreamIdentity{} = identity
       ) do
    assignment.status == @assignment_active and assignment.eligibility_status == @eligible and
      assignment.health_status == @health_active and identity.status == @active
  end

  defp primed_candidate?(%PoolUpstreamAssignment{
         metadata: %{"quota_priming" => %{"status" => status}}
       })
       when status in ["known", "weekly_only_probe"],
       do: true

  defp primed_candidate?(_assignment), do: false

  defp normalize_identity(%UpstreamIdentity{id: id}), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(id) when is_binary(id), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(_id), do: nil

  defp normalize_assignment(%PoolUpstreamAssignment{} = assignment), do: assignment
  defp normalize_assignment(id) when is_binary(id), do: Repo.get(PoolUpstreamAssignment, id)
  defp normalize_assignment(_id), do: nil

  defp assignment_id(%PoolUpstreamAssignment{id: id}), do: id
  defp assignment_id(id) when is_binary(id), do: id
  defp assignment_id(_id), do: nil

  defp pool_id(%Pool{id: id}), do: id
  defp pool_id(id) when is_binary(id), do: id
  defp pool_id(_id), do: nil

  defp tap_priming_change({:ok, %PoolUpstreamAssignment{} = assignment} = result, pool_id) do
    Events.broadcast_upstreams(pool_id, "quota_priming_updated", %{
      assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      assignment_status: assignment.status,
      quota_priming_status: get_in(assignment.metadata || %{}, ["quota_priming", "status"])
    })

    result
  end

  defp tap_priming_change(result, _pool_id), do: result

  defp lifecycle_error(code, message), do: %{code: code, message: message}
end
