defmodule CodexPooler.Gateway.Persistence.ConversationAffinity do
  @moduledoc """
  Bounded, advisory conversation routing. The row id and generation captured by
  a route plan fence later completion against failover and expiry/recreation.
  Call reserve/succeed under the canonical assignment reference locks.
  """

  import Ecto.Query

  alias CodexPooler.Gateway.Persistence.BridgeAffinity
  alias CodexPooler.Repo

  @kind "durable_conversation"
  @conflict_target {:unsafe_fragment,
                    "(pool_id, api_key_id, model_identifier, affinity_kind, affinity_key_hash) WHERE status = 'active'"}

  def kind, do: @kind

  def lookup(scope, now) do
    scope_query(scope)
    |> where([affinity], affinity.expires_at > ^now)
    |> Repo.one()
  end

  def reserve(scope, assignment, identity, now) do
    require_transaction!()

    scope_query(scope)
    |> where([affinity], affinity.expires_at <= ^now)
    |> Repo.delete_all()

    %BridgeAffinity{
      pool_id: scope.pool_id,
      api_key_id: scope.api_key_id,
      model_identifier: scope.model_identifier,
      affinity_kind: @kind,
      affinity_key_hash: scope.key_hash,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      status: "active",
      generation: 0,
      expires_at: DateTime.add(now, scope.idle_seconds, :second),
      metadata: %{"source" => "gateway_route_plan"},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!(on_conflict: :nothing, conflict_target: @conflict_target)

    lookup(scope, now)
  end

  def succeed(%{row: %BridgeAffinity{} = observed} = scope, assignment, identity) do
    require_transaction!()

    # Check time only after the row lock is acquired: a writer may have waited
    # behind another transaction longer than the remaining idle retention.
    case witnessed_query(observed) |> lock("FOR UPDATE") |> Repo.one() do
      %BridgeAffinity{} -> write_success(scope, assignment, identity, DateTime.utc_now())
      nil -> :ok
    end
  end

  def succeed(_scope, _assignment, _identity), do: :ok

  defp write_success(%{row: observed} = scope, assignment, identity, now) do
    # Same-account completions can renew without invalidating concurrent turns.
    # Only a successful account change advances the generation. A stale writer
    # cannot overwrite even if its wall-clock completion is the latest one.
    generation =
      observed.generation +
        if(observed.pool_upstream_assignment_id == assignment.id, do: 0, else: 1)

    expires_at = DateTime.add(now, scope.idle_seconds, :second)

    from(affinity in witnessed_query(observed),
      where: affinity.expires_at > ^now,
      update: [
        set: [
          pool_upstream_assignment_id: ^assignment.id,
          upstream_identity_id: ^identity.id,
          generation: ^generation,
          last_hit_at: fragment("GREATEST(?, ?)", affinity.last_hit_at, ^now),
          expires_at: fragment("GREATEST(?, ?)", affinity.expires_at, ^expires_at),
          metadata: ^%{"source" => "gateway_success"},
          updated_at: fragment("GREATEST(?, ?)", affinity.updated_at, ^now)
        ]
      ]
    )
    |> Repo.update_all([])

    :ok
  end

  def miss(%{row: %BridgeAffinity{} = observed}, now) do
    witnessed_query(observed)
    |> Repo.update_all(set: [last_miss_at: now])

    :ok
  end

  def miss(_scope, _now), do: :ok

  @doc "Deletes at most one indexed batch; failed attempts never renew retention."
  def cleanup(now, batch_size \\ 1000) do
    expired =
      from affinity in BridgeAffinity,
        where:
          affinity.affinity_kind == ^@kind and affinity.status == "active" and
            affinity.expires_at <= ^now,
        order_by: [asc: affinity.expires_at, asc: affinity.id],
        limit: ^batch_size,
        lock: "FOR UPDATE SKIP LOCKED",
        select: affinity.id

    {count, _} =
      BridgeAffinity
      |> where([affinity], affinity.id in subquery(expired))
      |> Repo.delete_all()

    count
  end

  defp require_transaction! do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "conversation affinity requires reference-locked transaction")
  end

  defp witnessed_query(observed) do
    from affinity in BridgeAffinity,
      where:
        affinity.id == ^observed.id and affinity.generation == ^observed.generation and
          affinity.status == "active"
  end

  defp scope_query(scope) do
    from affinity in BridgeAffinity,
      where:
        affinity.pool_id == ^scope.pool_id and affinity.api_key_id == ^scope.api_key_id and
          affinity.model_identifier == ^scope.model_identifier and
          affinity.affinity_kind == ^@kind and
          affinity.affinity_key_hash == ^scope.key_hash and affinity.status == "active"
  end
end
