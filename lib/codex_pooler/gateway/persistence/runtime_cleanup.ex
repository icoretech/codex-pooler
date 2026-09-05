defmodule CodexPooler.Gateway.Persistence.RuntimeCleanup do
  @moduledoc """
  Cleanup helpers for expired gateway runtime persistence records.
  """

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    IdempotencyKey
  }

  alias CodexPooler.Gateway.Persistence.StatusVocabulary.OwnerLease, as: OwnerLeaseStatus
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Repo

  @owner_lease_active OwnerLeaseStatus.active_status()

  @type request_ref :: Ecto.UUID.t() | %{required(:id) => Ecto.UUID.t()}
  @type attempt_ref :: Ecto.UUID.t() | %{required(:id) => Ecto.UUID.t()} | nil
  @type expired_owner_candidate :: %{
          required(:session_id) => Ecto.UUID.t(),
          required(:owner_instance_id) => String.t(),
          required(:owner_lease_token) => Ecto.UUID.t(),
          required(:owner_lease_expires_at) => DateTime.t()
        }

  @spec cleanup_expired_runtime_state(DateTime.t()) :: {:ok, map()} | {:error, term()}
  def cleanup_expired_runtime_state(now \\ now()) do
    with {:ok, recovered_summary} <- recover_expired_owner_runtime_state(now),
         {:ok, cleanup_summary} <- cleanup_expired(now) do
      {:ok, Map.merge(cleanup_summary, recovered_summary)}
    end
  end

  @spec active_runtime_request?(request_ref(), DateTime.t()) :: boolean()
  def active_runtime_request?(%{id: request_id}, %DateTime{} = now) do
    active_runtime_request?(request_id, now)
  end

  def active_runtime_request?(request_id, %DateTime{} = now) when is_binary(request_id) do
    Repo.exists?(
      from turn in CodexTurn,
        join: session in CodexSession,
        on: session.id == turn.codex_session_id,
        left_join: lease in BridgeOwnerLease,
        on:
          lease.codex_session_id == session.id and
            lease.status == ^@owner_lease_active and lease.expires_at > ^now,
        where:
          turn.request_id == ^request_id and turn.status == ^CodexTurn.in_progress_status() and
            (session.owner_lease_expires_at > ^now or not is_nil(lease.id))
    )
  end

  def active_runtime_request?(_request_ref, %DateTime{}), do: false

  @spec recover_stale_request_turn(request_ref(), attempt_ref(), keyword()) :: :ok
  def recover_stale_request_turn(request_ref, attempt_ref, opts) when is_list(opts) do
    request_id = ref_id(request_ref)
    final_attempt_id = ref_id(attempt_ref)
    now = opts |> Keyword.fetch!(:now) |> DateTime.truncate(:microsecond)
    error_code = Keyword.fetch!(opts, :error_code)

    CodexTurn
    |> where(
      [turn],
      turn.request_id == ^request_id and turn.status == ^CodexTurn.in_progress_status()
    )
    |> Repo.update_all(
      set: [
        status: CodexTurn.interrupted_status(),
        error_code: error_code,
        final_attempt_id: final_attempt_id,
        completed_at: now,
        updated_at: now
      ]
    )

    :ok
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
    candidates = expired_owner_sessions_with_active_turns(now)

    maybe_wait_after_expired_owner_candidates(candidates)

    candidates
    |> Enum.reduce_while({:ok, 0}, &recover_expired_owner_session/2)
    |> case do
      {:ok, recovered_count} -> {:ok, %{expired_owner_sessions_recovered: recovered_count}}
      {:error, reason} -> {:error, reason}
    end
  end

  if Mix.env() == :test do
    defp maybe_wait_after_expired_owner_candidates(candidates) do
      case Application.get_env(:codex_pooler, :runtime_cleanup_owner_candidate_test_barrier) do
        {test_pid, barrier_ref} when is_pid(test_pid) and is_reference(barrier_ref) ->
          send(
            test_pid,
            {:runtime_cleanup_owner_candidates_selected, self(), barrier_ref, candidates}
          )

          receive do
            {:release_runtime_cleanup_owner_candidates, ^barrier_ref} -> :ok
          end

        _no_barrier ->
          :ok
      end
    end
  else
    defp maybe_wait_after_expired_owner_candidates(_candidates), do: :ok
  end

  defp recover_expired_owner_session(candidate, {:ok, recovered_count}) do
    case Repo.transaction(fn -> recover_expired_owner_session_locked(candidate) end) do
      {:ok, :stale_owner} -> {:cont, {:ok, recovered_count}}
      {:ok, :recovered} -> {:cont, {:ok, recovered_count + 1}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp recover_expired_owner_session_locked(candidate) do
    owner_snapshot =
      Map.take(candidate, [:owner_instance_id, :owner_lease_token, :owner_lease_expires_at])

    case Accounting.close_request_replays_for_session(
           candidate.session_id,
           owner_snapshot,
           :owner_shutdown
         ) do
      {:ok, :stale_owner} ->
        :stale_owner

      {:ok, _summary} ->
        opts =
          %{}
          |> RequestOptions.for_websocket()
          |> RequestOptions.put_transport(
            websocket_owner_lease_token: candidate.owner_lease_token
          )

        case Interruption.recover_expired_owner_lifecycle(
               candidate,
               opts
             ) do
          {:ok, _result} -> :recovered
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp ref_id(nil), do: nil
  defp ref_id(%{id: id}), do: id
  defp ref_id(id) when is_binary(id), do: id

  defp expired_owner_sessions_with_active_turns(%DateTime{} = now) do
    Repo.all(
      from session in CodexSession,
        join: lease in BridgeOwnerLease,
        on:
          lease.codex_session_id == session.id and
            lease.status == ^BridgeOwnerLease.active_status() and
            lease.expires_at <= ^now and lease.lease_token == session.owner_lease_token and
            lease.owner_instance_id == session.owner_instance_id,
        join: turn in CodexTurn,
        on:
          turn.codex_session_id == session.id and
            turn.status == ^CodexTurn.in_progress_status(),
        distinct: session.id,
        select: %{
          session_id: session.id,
          owner_instance_id: session.owner_instance_id,
          owner_lease_token: session.owner_lease_token,
          owner_lease_expires_at: session.owner_lease_expires_at
        }
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
