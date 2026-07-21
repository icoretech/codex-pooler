defmodule CodexPooler.Gateway.Persistence.SessionContinuity.ExpiredSessions do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession
  }

  alias CodexPooler.Repo

  @alias_active BridgeSessionAlias.active_status()
  @alias_expired BridgeSessionAlias.expired_status()
  @lease_active BridgeOwnerLease.active_status()
  @lease_expired BridgeOwnerLease.expired_status()
  @session_closed CodexSession.closed_status()
  @session_reconnectable_statuses CodexSession.reconnectable_statuses()

  @spec close_for_key!(Ecto.UUID.t(), String.t(), DateTime.t()) ::
          {non_neg_integer(), nil | [term()]}
  def close_for_key!(pool_id, session_key, %DateTime{} = now) do
    session_ids = lock_expired_session_ids(pool_id, session_key, now)
    lock_active_leases!(session_ids)
    lock_active_aliases!(session_ids)

    expire_leases!(session_ids, now)
    expire_aliases!(session_ids, now)
    close_sessions!(session_ids, now)
  end

  defp lock_expired_session_ids(pool_id, session_key, now) do
    Repo.all(
      from session in CodexSession,
        where:
          session.pool_id == ^pool_id and
            fragment("lower(?)", session.session_key) == ^String.downcase(session_key) and
            session.status in ^@session_reconnectable_statuses and
            not is_nil(session.owner_lease_expires_at) and
            session.owner_lease_expires_at <= ^now,
        order_by: [asc: session.id],
        select: session.id,
        lock: "FOR UPDATE"
    )
  end

  defp lock_active_leases!([]), do: []

  defp lock_active_leases!(session_ids) do
    Repo.all(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id in ^session_ids and lease.status == ^@lease_active,
        order_by: [asc: lease.id],
        select: lease.id,
        lock: "FOR UPDATE"
    )
  end

  defp lock_active_aliases!([]), do: []

  defp lock_active_aliases!(session_ids) do
    Repo.all(
      from alias_record in BridgeSessionAlias,
        where:
          alias_record.codex_session_id in ^session_ids and
            alias_record.status == ^@alias_active,
        order_by: [asc: alias_record.id],
        select: alias_record.id,
        lock: "FOR UPDATE"
    )
  end

  defp expire_leases!([], _now), do: {0, nil}

  defp expire_leases!(session_ids, now) do
    BridgeOwnerLease
    |> where(
      [lease],
      lease.codex_session_id in ^session_ids and lease.status == ^@lease_active
    )
    |> Repo.update_all(set: [status: @lease_expired, released_at: now, updated_at: now])
  end

  defp expire_aliases!([], _now), do: {0, nil}

  defp expire_aliases!(session_ids, now) do
    BridgeSessionAlias
    |> where(
      [alias_record],
      alias_record.codex_session_id in ^session_ids and
        alias_record.status == ^@alias_active
    )
    |> Repo.update_all(set: [status: @alias_expired, updated_at: now])
  end

  defp close_sessions!([], _now), do: {0, nil}

  defp close_sessions!(session_ids, now) do
    CodexSession
    |> where([session], session.id in ^session_ids)
    |> Repo.update_all(set: [status: @session_closed, closed_at: now, updated_at: now])
  end
end
