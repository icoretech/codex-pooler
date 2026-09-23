defmodule CodexPooler.Gateway.Persistence.RuntimeCleanup do
  @moduledoc """
  Cleanup helpers for expired gateway runtime persistence records.
  """

  import Ecto.Query

  require Logger

  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    IdempotencyKey
  }

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.OwnerLease, as: OwnerLeaseStatus
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Session, as: SessionStatus
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Platform.InstancePresence
  alias CodexPooler.Repo

  @owner_lease_active OwnerLeaseStatus.active_status()

  @type request_ref :: Ecto.UUID.t() | %{required(:id) => Ecto.UUID.t()}
  @type attempt_ref :: Ecto.UUID.t() | %{required(:id) => Ecto.UUID.t()} | nil
  @type attempt_owner_ref ::
          %{
            required(:owner_instance_id) => String.t() | nil,
            required(:owner_instance_boot_id) => String.t() | nil
          }
          | nil
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

  @doc """
  Whether this request still has an in-progress turn held by a live owner.

  An unexpired lease protects its work unless a fresh observer can establish
  that the exact owner incarnation ended. Stale presence alone cannot do so:
  a live VM can lose database access while still streaming. Local live owners,
  owners with no later incarnation proof, and legacy owners with no incarnation
  retain the lease guard. A later database heartbeat from a different
  incarnation under the same non-anonymous node name proves the predecessor is
  gone even when the cleanup role cannot reach either VM over BEAM distribution.
  """
  @spec active_runtime_request?(request_ref(), DateTime.t(), keyword()) :: boolean()
  def active_runtime_request?(%{id: request_id}, %DateTime{} = now, opts) do
    active_runtime_request?(request_id, now, opts)
  end

  # Ownership is evidenced two ways and either one is enough, so they are asked
  # separately and the cheap `or` stops at the first that holds.
  def active_runtime_request?(request_id, %DateTime{} = now, opts) when is_binary(request_id) do
    held_by_live_session_owner?(request_id, now, opts) or
      held_by_live_lease_owner?(request_id, now, opts)
  end

  def active_runtime_request?(_request_ref, %DateTime{}, _opts), do: false

  @doc """
  Whether the work of `attempt` is still held by a live owner.

  The session-scoped question above asks whichever incarnation currently holds
  the session, which is the wrong incarnation to ask about an attempt a
  recovery pass is considering. A released client whose owner was killed falls
  back to another transport within seconds; the live peer that serves it moves
  the session's owner stamp and renews the lease on the same `codex_sessions`
  row, and the dead owner's stranded attempt was then sheltered by a VM that
  never executed it, with no terminal proof to release it either because a
  `SIGKILL` publishes none (findings#253, findings#217).

  So the attempt's own incarnation decides: an attempt whose owner is provably
  gone is not live work, whoever holds its session now. A live owner of *this
  attempt* still vetoes, and the session-scoped evidence still has to show an
  in-progress turn under an unexpired owner stamp or lease before anything is
  sheltered — proving an owner gone never creates a shelter, it only removes
  one.

  The fail-closed rules are those of the session-scoped question: an attempt
  that names no incarnation — an anonymous owner, or any attempt written
  before incarnations existed — is an owner this cannot reason about and keeps
  the shelter, exact reachable VM identity is the normal authority, and a
  later incarnation under the same non-anonymous node name is the death proof
  absent-instance recovery accepts.
  """
  @spec active_runtime_request?(request_ref(), attempt_owner_ref(), DateTime.t(), keyword()) ::
          boolean()
  def active_runtime_request?(request_ref, attempt, %DateTime{} = now, opts) when is_list(opts) do
    # Asked first: an attempt whose owner is provably gone needs no session
    # query to answer, and that is the pass this predicate exists to unblock.
    attempt_owner_may_be_alive?(attempt, opts) and
      active_runtime_request?(request_ref, now, opts)
  end

  # The session's own owner stamp is still in the future and the VM it names is
  # not provably absent.
  defp held_by_live_session_owner?(request_id, now, opts) do
    Repo.all(
      from turn in CodexTurn,
        join: session in CodexSession,
        on: session.id == turn.codex_session_id,
        where:
          turn.request_id == ^request_id and turn.status == ^CodexTurn.in_progress_status() and
            session.owner_lease_expires_at > ^now,
        select: {session.owner_instance_id, session.owner_instance_boot_id}
    )
    |> Enum.any?(&owner_may_be_alive?(&1, opts))
  end

  # An active owner lease has not expired and the VM holding it is not provably
  # absent.
  defp held_by_live_lease_owner?(request_id, now, opts) do
    Repo.all(
      from turn in CodexTurn,
        join: lease in BridgeOwnerLease,
        on:
          lease.codex_session_id == turn.codex_session_id and
            lease.status == ^@owner_lease_active and lease.expires_at > ^now,
        where: turn.request_id == ^request_id and turn.status == ^CodexTurn.in_progress_status(),
        select: {lease.owner_instance_id, lease.owner_instance_boot_id}
    )
    |> Enum.any?(&owner_may_be_alive?(&1, opts))
  end

  # Database freshness selects a candidate. Exact reachable VM identity is the
  # normal authority; when it is unreachable, a later incarnation publishing
  # under the same node name is the same exact death proof absent-instance
  # recovery accepts. A live owner vetoes both, and anonymous/non-incarnation
  # identities remain unknown.
  defp owner_may_be_alive?({node_name, boot_id}, opts) do
    identity = InstancePresence.Identity.owner(node_name, boot_id)
    presence_now = InstancePresence.database_now()

    not (InstancePresence.observer_fresh?(presence_now, opts) and
           InstancePresence.absent?(identity, presence_now, opts) and
           owner_proven_gone?(identity))
  end

  # The attempt's own incarnation, when it names one. Anything else — an
  # attempt with no boot id, a caller with no attempt in hand — is an owner
  # this cannot reason about and stays sheltered, the same direction absence
  # itself is one-directional in.
  defp attempt_owner_may_be_alive?(
         %{owner_instance_id: node_name, owner_instance_boot_id: boot_id},
         opts
       ) do
    case InstancePresence.Identity.owner(node_name, boot_id) do
      nil -> true
      %InstancePresence.Identity{} -> owner_may_be_alive?({node_name, boot_id}, opts)
    end
  end

  defp attempt_owner_may_be_alive?(_attempt, _opts), do: true

  defp owner_proven_gone?(identity) do
    case InstancePresence.status(identity) do
      :dead -> true
      :alive -> false
      :unknown -> InstancePresence.superseded?(identity)
    end
  end

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

      {closed_retired_sessions, _} = close_retired_sessions!(now, active_alias_status, active_lease_status)

      %{
        expired_aliases: expired_aliases,
        expired_owner_leases: expired_leases,
        expired_idempotency_keys: expired_idempotency_keys,
        closed_retired_sessions: closed_retired_sessions
      }
    end)
  end

  # A session is closed only by a later start of the same key and session key
  # (`ExpiredSessions.close_for_key!/4`, which is also what hands the findings#141
  # assignment preference to the recreated session) or by an interruption of an
  # active turn. When its idle owner releases the lease and the window is never
  # used again, the row stayed reconnectable forever: counted as an active
  # session and kept in the per-key unique index (findings#225, row 225-89).
  #
  # Retire it once nothing can resume it and the preference no longer points at
  # anything warm: its lease expired longer ago than the expired-alias retention
  # (the same Instance Setting that bounds how long its aliases resolve), no
  # alias of it is still active, no lease row is active and no turn of it is in
  # progress. A start that races this rereads the row under its own lock and
  # either renews it first (the WHERE no longer matches) or finds it closed and
  # recreates without a preference, exactly as after any other close.
  defp close_retired_sessions!(now, active_alias_status, active_lease_status) do
    cutoff = DateTime.add(now, -OperationalSettings.current().expired_alias_ttl_seconds, :second)
    reconnectable = SessionStatus.reconnectable_statuses()
    in_progress = CodexTurn.in_progress_status()

    from(session in CodexSession, as: :session)
    |> where(
      [session],
      session.status in ^reconnectable and
        coalesce(session.owner_lease_expires_at, session.updated_at) <= ^cutoff and
        not exists(
          from alias_record in BridgeSessionAlias,
            where: alias_record.codex_session_id == parent_as(:session).id and alias_record.status == ^active_alias_status
        ) and
        not exists(
          from lease in BridgeOwnerLease,
            where: lease.codex_session_id == parent_as(:session).id and lease.status == ^active_lease_status
        ) and
        not exists(
          from turn in CodexTurn,
            where: turn.codex_session_id == parent_as(:session).id and turn.status == ^in_progress
        )
    )
    |> Repo.update_all(set: [status: SessionStatus.closed_status(), closed_at: now, updated_at: now])
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

  # Every committed outcome of this transaction goes through the same emission,
  # which is what makes the producer side of the after-commit property hold the
  # way the emitter side does. `Interruption.emit_outcomes_after_commit/1`
  # guarantees that nothing emits a marker inside a transaction; it cannot
  # guarantee that a marker a recovery produced ever reaches it, and the
  # `:stale_owner` arm used to skip the call rather than carry an empty list. A
  # second arm written the same way would drop a recovery's outcomes with no
  # gate, no log and no test — the shape findings#195 row 195-05's third site
  # had. There is now one `{:ok, _}` shape and it always carries the markers.
  defp recover_expired_owner_session(candidate, {:ok, recovered_count}) do
    candidate
    |> then(&Repo.transaction(fn -> recover_expired_owner_session_locked(&1) end))
    |> complete_expired_owner_recovery(recovered_count)
  end

  @doc false
  @spec complete_expired_owner_recovery(
          {:ok, {non_neg_integer(), map()}} | {:error, term()},
          non_neg_integer()
        ) :: {:cont, {:ok, non_neg_integer()}} | {:halt, {:error, term()}}
  def complete_expired_owner_recovery({:ok, {recovered, result}}, recovered_count)
      when is_integer(recovered) and recovered >= 0 do
    emit_recovery_outcomes(result)
    {:cont, {:ok, recovered_count + recovered}}
  end

  def complete_expired_owner_recovery({:error, reason}, _recovered_count),
    do: {:halt, {:error, reason}}

  # The after-commit property of these outcomes rests on this step running bare,
  # which `RuntimeStateCleanup.run/1` guarantees today. If a future caller wraps
  # it, the markers are not this function's to emit and it has nowhere to put
  # them; saying so beats losing a recovery's outcomes silently. Only the count
  # crosses into the log.
  defp emit_recovery_outcomes(result) do
    case Interruption.emit_committed_recovery_outcomes(result) do
      :ok ->
        :ok

      {:deferred, markers} ->
        Logger.warning(
          "expired-owner recovery outcomes dropped inside a caller transaction " <>
            "outcomes=#{length(markers)}"
        )

        :ok
    end
  end

  defp recover_expired_owner_session_locked(candidate) do
    opts =
      %{}
      |> RequestOptions.for_websocket()
      |> RequestOptions.put_transport(websocket_owner_lease_token: candidate.owner_lease_token)

    case Interruption.recover_expired_owner_lifecycle(candidate, opts) do
      {:ok, :stale_owner} -> {0, %{interrupted_outcomes: []}}
      {:ok, result} -> {1, result}
      {:error, reason} -> Repo.rollback(reason)
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
