defmodule CodexPooler.Gateway.Persistence.RuntimeCleanup do
  @moduledoc """
  Cleanup helpers for expired gateway runtime persistence records.
  """

  import Ecto.Query

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    IdempotencyKey
  }

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Repo

  @spec cleanup_expired_runtime_state(DateTime.t()) :: {:ok, map()} | {:error, term()}
  def cleanup_expired_runtime_state(now \\ now()) do
    with {:ok, recovered_summary} <- recover_expired_owner_runtime_state(now),
         {:ok, cleanup_summary} <- cleanup_expired(now) do
      {:ok, Map.merge(cleanup_summary, recovered_summary)}
    end
  end

  @spec cleanup_expired(DateTime.t()) :: {:ok, map()} | {:error, term()}
  def cleanup_expired(now \\ now()) do
    now = DateTime.truncate(now, :microsecond)
    active_alias_status = BridgeSessionAlias.active_status()
    active_lease_status = BridgeOwnerLease.active_status()
    expired_alias_status = BridgeSessionAlias.expired_status()
    expired_lease_status = BridgeOwnerLease.expired_status()
    expired_idempotency_status = IdempotencyKey.expired_status()
    expirable_idempotency_statuses = IdempotencyKey.expirable_statuses()

    Repo.transaction(fn ->
      {expired_aliases, _} =
        BridgeSessionAlias
        |> where(
          [alias_record],
          alias_record.status == ^active_alias_status and alias_record.expires_at <= ^now
        )
        |> Repo.update_all(set: [status: expired_alias_status, updated_at: now])

      {expired_leases, _} =
        BridgeOwnerLease
        |> where([lease], lease.status == ^active_lease_status and lease.expires_at <= ^now)
        |> Repo.update_all(set: [status: expired_lease_status, released_at: now, updated_at: now])

      {expired_idempotency_keys, _} =
        IdempotencyKey
        |> where(
          [key],
          key.status in ^expirable_idempotency_statuses and key.expires_at <= ^now
        )
        |> Repo.update_all(set: [status: expired_idempotency_status, updated_at: now])

      %{
        expired_aliases: expired_aliases,
        expired_owner_leases: expired_leases,
        expired_idempotency_keys: expired_idempotency_keys
      }
    end)
  end

  defp recover_expired_owner_runtime_state(%DateTime{} = now) do
    now = DateTime.truncate(now, :microsecond)

    now
    |> expired_owner_sessions_with_active_turns()
    |> Enum.reduce_while({:ok, 0}, &recover_expired_owner_session/2)
    |> case do
      {:ok, recovered_count} -> {:ok, %{expired_owner_sessions_recovered: recovered_count}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recover_expired_owner_session(session_id, {:ok, recovered_count}) do
    case Interruption.recover_owner_lifecycle_leftovers(
           session_id,
           :owner_unavailable,
           RequestOptions.for_websocket(%{})
         ) do
      {:ok, _result} -> {:cont, {:ok, recovered_count + 1}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp expired_owner_sessions_with_active_turns(%DateTime{} = now) do
    Repo.all(
      from session in CodexSession,
        join: lease in BridgeOwnerLease,
        on:
          lease.codex_session_id == session.id and
            lease.status == ^BridgeOwnerLease.active_status() and
            lease.expires_at <= ^now,
        join: turn in CodexTurn,
        on:
          turn.codex_session_id == session.id and
            turn.status == ^CodexTurn.in_progress_status(),
        distinct: session.id,
        select: session.id
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
