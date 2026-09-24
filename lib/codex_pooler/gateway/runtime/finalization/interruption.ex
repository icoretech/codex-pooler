defmodule CodexPooler.Gateway.Runtime.Finalization.Interruption do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, ClientRetry, Request, RequestReplayEntitlement}
  alias CodexPooler.Accounting.PreAttemptRelease
  alias CodexPooler.Accounting.RequestLifecycle.{DeadExecutionResendRecovery, TurnClaimRelease}
  alias CodexPooler.Accounting.RequestLogFacts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Session, as: SessionStatus
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Turn, as: TurnStatus
  alias CodexPooler.Gateway.Runtime.Finalization.InterruptionOutcome
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata
  alias CodexPooler.Gateway.Runtime.Finalization.Streaming
  alias CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission.Binding
  alias CodexPooler.Gateway.Websocket.OwnerCleanup
  alias CodexPooler.Repo

  require Logger

  @default_reconnect_window_seconds 300
  @task_exception_status_code 500

  @type opts :: RequestOptions.t()
  @type session_ref :: CodexSession.t() | Ecto.UUID.t()

  @session_interrupted SessionStatus.interrupted_status()
  @session_closed SessionStatus.closed_status()
  @turn_in_progress TurnStatus.in_progress_status()
  @turn_succeeded TurnStatus.succeeded_status()
  @turn_failed TurnStatus.failed_status()
  @turn_interrupted TurnStatus.interrupted_status()

  # How much authority the interruption had over the turn it reports on. A zero
  # `interrupted_turn_count` has always meant two different things -- nothing
  # was in flight, or the caller could not name the turn that is -- and only the
  # first is a completed cleanup (icoretech/codex-pooler-findings#179). These
  # are fixed internal tokens, never row content.
  @authority_selected :selected
  @authority_session_idle :session_idle
  @authority_no_selector :no_selector
  @authority_unresolved :unresolved
  @authority_no_session :no_session

  @spec owner_finalization_pending?(OwnerCleanup.t()) :: boolean()
  def owner_finalization_pending?(%OwnerCleanup{} = witness) do
    Repo.exists?(
      from request in Request,
        left_join: turn in CodexTurn,
        on: turn.request_id == request.id and turn.codex_session_id == ^witness.session_id,
        left_join: attempt in Attempt,
        on: attempt.id == ^witness.attempt_id and attempt.request_id == request.id,
        where:
          request.id == ^witness.request_id and
            (turn.status == ^@turn_in_progress or request.status in ["accepted", "in_progress"] or
               attempt.status in ["queued", "in_progress"])
    )
  end

  @spec interrupt_direct_request(
          CodexPooler.Gateway.Websocket.DirectCleanup.receipt(),
          String.t()
        ) :: :ok | {:ok, %{after_commit_markers: [map()]}} | {:error, term()}
  def interrupt_direct_request(receipt, reason) do
    Repo.transaction(fn ->
      session = codex_session_for_update(receipt.session_id)
      _key = Access.lock_api_key_for_read(receipt.api_key_id)

      _turn =
        Repo.one(
          from t in CodexTurn,
            where: t.codex_session_id == ^receipt.session_id and t.request_id == ^receipt.request_id,
            lock: "FOR UPDATE"
        )

      request = request_for_update(receipt.request_id)

      case direct_interrupt_clause(session, request, receipt) do
        :matched ->
          request = mark_pre_attempt_owner_drain(request, receipt, reason)
          interrupt_direct_locked(:session, session, request, reason)

        :matched_superseded ->
          log_direct_interrupt_superseded(receipt, reason)
          request = mark_pre_attempt_owner_drain(request, receipt, reason)
          interrupt_direct_locked(:request, session, request, reason)

        {:not_matched, clause} ->
          log_direct_interrupt_not_matched(receipt, reason, clause)
          []
      end
    end)
    |> finalize_marker_transaction()
  end

  # A claim-only row that gave its claim up (findings#206 rows 206-419/206-420)
  # still answers to the receipt bound at claim time, which names that claim.
  defp direct_receipt_matches?(%CodexSession{} = session, %Request{} = request, receipt),
    do:
      is_binary(receipt.correlation_id) and
        receipt.correlation_id in [request.correlation_id, (request.request_metadata || %{})["released_turn_claim"]] and
        request.api_key_id == receipt.api_key_id and request.pool_id == session.pool_id

  defp direct_receipt_matches?(_session, _request, _receipt), do: false

  # The admission gate is expressed one named clause at a time so a gate that
  # never matches says which check refused instead of returning a silent
  # `:ok`. Every clause name is a fixed internal token, never row content.
  defp direct_interrupt_clause(session, request, receipt) do
    cond do
      is_nil(session) ->
        {:not_matched, "missing_session"}

      is_nil(request) ->
        {:not_matched, "missing_request"}

      not direct_receipt_matches?(session, request, receipt) ->
        {:not_matched, "receipt_identity"}

      request.status not in ["accepted", "in_progress"] ->
        {:not_matched, "request_already_terminal"}

      true ->
        admitted_direct_interrupt_scope(session, request, receipt)
    end
  end

  # A turn of the same session that is already `in_progress` is a successor,
  # not a reason to abandon this request. Refusing the whole finalization left
  # the interrupted request `in_progress` with its reservation outstanding and
  # nothing else ever settled it, because every other settler is gated on the
  # same session state (icoretech/codex-pooler-findings#252). The successor now
  # narrows the finalization to what the refusal was always protecting the
  # session from -- the session row itself and any turn that is not this
  # request's -- while this request, its own turn and its own attempt settle
  # exactly as they do without a successor. The provenance clauses still run
  # first in both scopes, so a receipt that cannot prove its owner settles
  # nothing either way.
  defp admitted_direct_interrupt_scope(session, request, receipt) do
    with :matched <- pre_attempt_owner_clause(session, request, receipt) do
      if replacement_turn_active?(receipt.session_id, receipt.request_id),
        do: :matched_superseded,
        else: :matched
    end
  end

  defp pre_attempt_owner_clause(
         session,
         request,
         %{
           owner_binding: %{
             owner_instance_id: owner,
             owner_lease_token: token,
             downstream_epoch: epoch
           }
         } = receipt
       )
       when is_binary(owner) and is_binary(token) and is_integer(epoch) and epoch > 0 do
    metadata = Map.get(request.request_metadata, "websocket_owner_forwarding", %{})

    # Split only to keep each group under the complexity bound. The order is
    # load-bearing: the session row is the cheapest check, the forwarding
    # metadata needs no query either, and the attempt lookup is last because it
    # is the only clause that touches the database.
    with :matched <- session_owner_clause(session, owner, token),
         :matched <- owner_forwarding_clause(metadata, owner, epoch) do
      admitted_attempt_clause(request, receipt)
    end
  end

  defp pre_attempt_owner_clause(_session, request, receipt) do
    cond do
      not is_nil(Map.get(receipt, :owner_binding)) ->
        {:not_matched, "owner_binding_malformed"}

      Map.has_key?(request.request_metadata, "websocket_owner_forwarding") ->
        {:not_matched, "owner_forwarded_request_without_binding"}

      true ->
        :matched
    end
  end

  defp session_owner_clause(session, owner, token) do
    cond do
      session.owner_lease_token != token ->
        {:not_matched, "session_owner_lease_token"}

      session.owner_instance_id != owner ->
        {:not_matched, "session_owner_instance_id"}

      not current_owner_lease?(session.owner_lease_expires_at) ->
        {:not_matched, "owner_lease_expired"}

      true ->
        :matched
    end
  end

  defp owner_forwarding_clause(metadata, owner, epoch) do
    cond do
      metadata["owner_instance_id"] != owner -> {:not_matched, "metadata_owner_instance_id"}
      metadata["downstream_epoch"] != epoch -> {:not_matched, "metadata_downstream_epoch"}
      true -> :matched
    end
  end

  defp admitted_attempt_clause(request, receipt) do
    if admitted_attempt_matches?(latest_attempt_for_update(request.id), receipt),
      do: :matched,
      else: {:not_matched, "admitted_attempt"}
  end

  # Ordinary lifecycle outcomes (the turn already finished, or another turn
  # replaced it) are the common case on every socket teardown and stay at
  # debug. A refused provenance clause is the interesting one: it is what
  # distinguishes "never called" from "called and rejected", and which check
  # rejected. The clause name and the interrupt reason are fixed internal
  # vocabularies and the correlators are trusted ids, so the whole line is
  # bounded sanitized cleartext in the message rather than in logger metadata,
  # which allowlists none of these keys.
  @routine_not_matched_clauses [
    "missing_session",
    "missing_request",
    "request_already_terminal"
  ]

  defp log_direct_interrupt_not_matched(receipt, reason, clause) do
    message =
      "websocket direct interrupt gate not matched " <>
        "codex_session_id=#{safe_log_value(Map.get(receipt, :session_id))} " <>
        "request_id=#{safe_log_value(Map.get(receipt, :request_id))} " <>
        "interrupt_reason=#{safe_log_value(reason)} " <>
        "refused_clause=#{safe_log_value(clause)}"

    if clause in @routine_not_matched_clauses,
      do: Logger.debug(message),
      else: Logger.info(message)

    :ok
  end

  # An admitted finalization that had to narrow its scope. It is not a refusal,
  # so it does not belong in the gate's refusal line, and it is the only record
  # that this request settled while its session kept serving a successor. Every
  # value is a trusted internal correlator or a fixed internal token.
  defp log_direct_interrupt_superseded(receipt, reason) do
    Logger.debug(
      "websocket direct interrupt narrowed to the request " <>
        "codex_session_id=#{safe_log_value(Map.get(receipt, :session_id))} " <>
        "request_id=#{safe_log_value(Map.get(receipt, :request_id))} " <>
        "interrupt_reason=#{safe_log_value(reason)} " <>
        "interrupt_scope=replacement_turn_active"
    )

    :ok
  end

  defp current_owner_lease?(%DateTime{} = expiry), do: DateTime.compare(expiry, now()) == :gt
  defp current_owner_lease?(_expiry), do: false

  defp admitted_attempt_matches?(nil, _receipt), do: true

  defp admitted_attempt_matches?(%Attempt{} = attempt, receipt),
    do:
      attempt.id == Map.get(receipt, :attempt_id) and
        attempt.replay_generation == Map.get(receipt, :replay_generation) and
        attempt.transport == "websocket"

  defp mark_pre_attempt_owner_drain(
         %{status: status} = request,
         %{owner_binding: binding},
         "owner_drained"
       )
       when is_map(binding) and status in ["accepted", "in_progress"] do
    if is_nil(latest_attempt_for_update(request.id)) do
      request
      |> Ecto.Changeset.change(request_metadata: Map.put(request.request_metadata, "websocket_pre_attempt_drain", true))
      |> Repo.update!()
    else
      request
    end
  end

  defp mark_pre_attempt_owner_drain(request, _receipt, _reason), do: request

  # A request the client left before its reservation sent nothing to the
  # provider, so its claim protects nothing, and kept on the closed row it fenced
  # every resend of the request with a permanent `409 duplicate_turn` (findings#206
  # row 206-419). The row gives the claim up and stays as history. The owner's
  # pre-attempt drain row keeps it: the drain resend chains from that row
  # (`ClientRetry.verified_claim_only_drain?/1`).
  defp close_claim_only_request!(%Request{request_metadata: %{"websocket_pre_attempt_drain" => true}} = request, changes),
    do: request |> Ecto.Changeset.change(changes) |> Repo.update!()

  defp close_claim_only_request!(%Request{} = request, changes),
    do: TurnClaimRelease.close!(request, changes, :client_left_before_reservation)

  defp interrupt_direct_locked(scope, session, request, reason) do
    turn = Repo.get_by(CodexTurn, request_id: request.id)
    attempt = latest_attempt_for_update(request.id)

    case recover_proven_dead_direct_request(request, attempt) do
      {:recovered, marker} ->
        [marker]

      :not_recovered ->
        do_interrupt_direct_locked(scope, session, request, turn, attempt, reason)
    end
  end

  defp recover_proven_dead_direct_request(request, %Attempt{}) do
    case recover_proven_dead_request(request, latest_attempt_for_update(request.id)) do
      %{kind: :stream_outcome} = marker -> {:recovered, marker}
      nil -> :not_recovered
    end
  end

  defp recover_proven_dead_direct_request(_request, _attempt), do: :not_recovered

  defp do_interrupt_direct_locked(scope, session, request, turn, attempt, reason) do
    case {request.status, turn, attempt} do
      {"accepted", nil, _} ->
        close_claim_only_request!(
          request,
          %{
            status: "failed",
            completed_at: ClientRetry.completion_timestamp(request, now()),
            response_status_code: 499,
            last_error_code: reason,
            usage_status: "usage_unknown"
          }
        )

        RequestLogFacts.record_request_created!(request)
        []

      {"in_progress", %CodexTurn{} = turn, nil} ->
        case Accounting.finalize_reservation_failure(request, %{
               last_error_code: reason,
               response_status_code: 499,
               usage_status: "usage_unknown",
               pre_attempt_phase: PreAttemptRelease.turn_interrupted()
             }) do
          {:ok, released} ->
            complete_interrupted_turn!(turn, nil, @turn_interrupted, reason, now())
            after_commit_markers(released)

          {:error, error} ->
            Repo.rollback(error)
        end

      _ ->
        opts = RequestOptions.for_websocket(%{request_id: request.correlation_id, reason: reason})
        interrupt_direct_attempted_turn(scope, session, request, opts, reason)
    end
  end

  defp interrupt_direct_attempted_turn(:session, session, _request, opts, _reason) do
    case interrupt_codex_turn(session, opts) do
      {:ok, result} ->
        Map.get(result, :after_commit_markers, [])

      {:error, {:deferred_after_commit, public_error, markers}} ->
        Repo.rollback(public_error: public_error, interrupted_outcomes: markers)

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  # The request-scoped half of `interrupt_selected_session_turn/2`: the same
  # turn resolution and the same writes to this request, its attempt and its
  # turn, without the session row update that the active successor still owns.
  # The turn is named by the receipt's own request id, never by a selector that
  # could widen onto the successor's turn.
  defp interrupt_direct_attempted_turn(:request, _session, request, opts, reason) do
    now = now()

    case Repo.get_by(CodexTurn, request_id: request.id) do
      nil ->
        []

      %CodexTurn{} = turn ->
        case preserve_succeeded_turn(turn, now) do
          :preserved ->
            []

          :continue ->
            # `interrupt_direct_request/2` hands these to
            # `finalize_marker_transaction/1`, which defers them past the commit
            # exactly as `finalize_transaction/1` does for the session scope.
            {_interrupted_turn_count, interrupted_outcomes} =
              interrupt_selected_turn(turn, opts, reason, now, Repo.in_transaction?())

            interrupted_outcomes
        end
    end
  end

  # A response task that dies by exception (not an owner crash, drain, or
  # client disconnect) finalizes its own request, attempt, and turn as failed
  # with a health-neutral reason: no circuit, demotion, or session/lease
  # write. It trusts the direct-cleanup receipt the task bound itself instead
  # of the owner witness, because in that shape the owner is still current
  # while the task is gone; the witness-based interrupt cannot close it and
  # can only roll back as `stale_owner_cleanup`, leaving an `in_progress`
  # turn that turns every byte-identical resend into `duplicate_turn`.
  @spec finalize_task_exception_request(
          CodexPooler.Gateway.Websocket.DirectCleanup.receipt(),
          String.t()
        ) :: :ok | {:ok, %{after_commit_markers: [map()]}} | {:error, term()}
  def finalize_task_exception_request(receipt, reason) when is_binary(reason) do
    Repo.transaction(fn ->
      session = codex_session_for_update(receipt.session_id)
      _key = Access.lock_api_key_for_read(receipt.api_key_id)

      turn =
        Repo.one(
          from t in CodexTurn,
            where: t.codex_session_id == ^receipt.session_id and t.request_id == ^receipt.request_id,
            lock: "FOR UPDATE"
        )

      request = request_for_update(receipt.request_id)
      attempt = latest_attempt_for_update(receipt.request_id)

      if direct_receipt_matches?(session, request, receipt) and
           task_exception_attempt_matches?(attempt, receipt) and
           request.status in ["accepted", "in_progress"] do
        fail_task_exception_locked(turn, request, attempt, reason)
      else
        []
      end
    end)
    |> finalize_marker_transaction()
  end

  defp task_exception_attempt_matches?(nil, _receipt), do: true

  defp task_exception_attempt_matches?(%Attempt{} = attempt, receipt) do
    attempt.id == Map.get(receipt, :attempt_id) and
      attempt.replay_generation == Map.get(receipt, :replay_generation)
  end

  # A task that raised between its turn claim and a committed reservation (a
  # reservation that raised and rolled back, findings#206 row 206-310) holds
  # nothing but the claim row, which has no reservation to release: the
  # reservation-failure write below raised `Ecto.NoResultsError`, and the claim
  # stayed `accepted` and fenced every resend for six hours. It is released
  # instead, as if it had been written by the rolled-back reservation
  # (findings#206 row 206-331); anything more than the claim is kept and
  # settled below.
  defp fail_task_exception_locked(nil, %Request{status: "accepted"} = request, nil, reason) do
    case Accounting.release_websocket_turn_claim(request) do
      {:ok, :released} -> []
      {:ok, :kept} -> fail_reserved_task_exception_locked(nil, request, nil, reason)
      {:error, error} -> Repo.rollback({:task_exception_accounting_failed, error})
    end
  end

  defp fail_task_exception_locked(turn, request, attempt, reason),
    do: fail_reserved_task_exception_locked(turn, request, attempt, reason)

  defp fail_reserved_task_exception_locked(turn, request, attempt, reason) do
    now = now()

    cond do
      active_attempt?(attempt) ->
        Accounting.finalize_request_with_disposition(request, attempt, %{
          request_status: "failed",
          attempt_status: "failed",
          response_status_code: @task_exception_status_code,
          last_error_code: reason,
          error_message: "websocket response task failed before settlement",
          usage: %{status: "usage_unknown", source: reason}
        })
        |> complete_task_exception_turn!(turn, attempt, reason, now)

      is_nil(attempt) ->
        Accounting.finalize_reservation_failure(request, %{
          last_error_code: reason,
          response_status_code: @task_exception_status_code,
          usage_status: "usage_unknown",
          pre_attempt_phase: PreAttemptRelease.task_exception()
        })
        |> complete_task_exception_turn!(turn, nil, reason, now)

      Accounting.reservation_outstanding?(request) ->
        # A terminal attempt with its reservation still live is the shape an
        # armed replay entitlement leaves behind (generation 1 armed, attempt
        # at generation 0); without an explicit close status the finalizer's
        # stale-generation arm writes nothing and the reservation leaks
        # (findings#221). The task raised, so the entitlement is revoked.
        Accounting.finalize_request_with_disposition(request, attempt, %{
          request_status: "failed",
          response_status_code: @task_exception_status_code,
          last_error_code: reason,
          preserve_replay_attempt: true,
          replay_entitlement_close_status: "revoked",
          usage: %{status: "usage_unknown", source: reason}
        })
        |> complete_task_exception_turn!(turn, attempt, reason, now)

      true ->
        # The reservation is already settled or released, so only the request
        # row is written here; an armed replay entitlement left behind by an
        # earlier release would otherwise stay open until the sweep (findings#221).
        _ = Accounting.revoke_armed_replay_entitlement!(request.id, attempt, now)

        request
        |> Ecto.Changeset.change(%{
          status: "failed",
          usage_status: "usage_unknown",
          completed_at: now,
          response_status_code: @task_exception_status_code,
          last_error_code: reason
        })
        |> Repo.update!()

        complete_task_exception_turn!({:ok, request}, turn, attempt, reason, now)
    end
  end

  defp complete_task_exception_turn!({:ok, result}, turn, attempt, reason, now) do
    if match?(%CodexTurn{status: @turn_in_progress}, turn) do
      complete_interrupted_turn!(turn, attempt, @turn_failed, reason, now)
    end

    after_commit_markers(result)
  end

  defp complete_task_exception_turn!({:error, error}, _turn, _attempt, _reason, _now),
    do: Repo.rollback({:task_exception_accounting_failed, error})

  @spec interrupt_codex_session(session_ref(), opts()) :: {:ok, term()} | {:error, term()}
  def interrupt_codex_session(%CodexSession{id: id}, opts), do: interrupt_codex_session(id, opts)

  def interrupt_codex_session(session_id, %RequestOptions{} = opts) when is_binary(session_id) do
    if opts.transport.websocket_owner.lease_token do
      interrupt_owner_request(session_id, opts, interrupt_reason(opts))
    else
      interrupt_codex_turn(session_id, opts)
    end
  end

  def interrupt_codex_session(_session_id, _opts), do: {:ok, :ok}

  @spec interrupt_codex_turn(session_ref(), opts()) :: {:ok, term()} | {:error, term()}
  def interrupt_codex_turn(%CodexSession{id: id}, opts), do: interrupt_codex_turn(id, opts)

  def interrupt_codex_turn(session_id, %RequestOptions{} = opts) when is_binary(session_id) do
    interrupt_session_turn(session_id, turn_selector(opts), opts, interrupt_reason(opts))
  end

  def interrupt_codex_turn(_session_id, _opts),
    do: {:ok, %{interrupted_turn_count: 0, turn_authority: @authority_no_session}}

  defp turn_selector(%RequestOptions{} = opts) do
    case request_id(opts) do
      nil -> :none
      request_id -> {:request_id, request_id}
    end
  end

  @spec interrupt_detached_codex_turn(session_ref(), opts()) ::
          {:ok, term()} | {:error, term()}
  def interrupt_detached_codex_turn(%CodexSession{id: id}, opts),
    do: interrupt_detached_codex_turn(id, opts)

  def interrupt_detached_codex_turn(session_id, %RequestOptions{} = opts)
      when is_binary(session_id) do
    interrupt_owner_request(session_id, opts, interrupt_reason(opts))
  end

  def interrupt_detached_codex_turn(_session_id, _opts),
    do: {:ok, %{interrupted_turn_count: 0, turn_authority: @authority_no_session}}

  @spec recover_owner_lifecycle_leftovers(session_ref(), atom() | String.t(), opts()) ::
          {:ok, term()} | {:error, term()}
  def recover_owner_lifecycle_leftovers(%CodexSession{id: id}, owner_reason, opts),
    do: recover_owner_lifecycle_leftovers(id, owner_reason, opts)

  def recover_owner_lifecycle_leftovers(session_id, owner_reason, %RequestOptions{} = opts)
      when is_binary(session_id) do
    reason = owner_recovery_reason(owner_reason)

    case interrupt_owner_request(session_id, opts, reason) do
      {:ok, _result} = ok ->
        ok

      {:error, failure} = error ->
        log_owner_lifecycle_recovery_failure(session_id, reason, failure)
        error
    end
  end

  def recover_owner_lifecycle_leftovers(_session_id, _owner_reason, _opts), do: {:ok, :ok}

  @spec release_owner_cleanup_lease(map(), String.t(), :idle_expiry | :drain_cut | nil) ::
          :ok | {:error, term()}
  def release_owner_cleanup_lease(state, reason, cause) do
    case Repo.transaction(fn -> release_owner_cleanup_lease_locked(state, reason, cause) end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_owner_cleanup_lease_locked(state, reason, cause) do
    session = codex_session_for_update(state.codex_session_id)
    witness = OwnerCleanup.from_owner_state(state)
    request_id = if witness, do: witness.request_id

    with %CodexSession{} <- session,
         true <- session.owner_lease_token == state.owner_lease_token,
         true <- session.owner_instance_id == state.owner_instance_id,
         true <- cleanup_release_attempt_matches?(witness),
         false <- other_active_turn?(session.id, request_id),
         :ok <-
           SessionContinuity.release_owner_lease(session, state.owner_lease_token, reason, cause) do
      :ok
    else
      _stale -> Repo.rollback(:stale_owner_cleanup)
    end
  end

  defp other_active_turn?(session_id, nil) do
    Repo.exists?(
      from turn in CodexTurn,
        where: turn.codex_session_id == ^session_id and turn.status == ^@turn_in_progress
    )
  end

  defp other_active_turn?(session_id, request_id),
    do: replacement_turn_active?(session_id, request_id)

  defp cleanup_release_attempt_matches?(nil), do: true

  defp cleanup_release_attempt_matches?(%OwnerCleanup{} = witness) do
    case latest_attempt_for_update(witness.request_id) do
      %Attempt{id: id, replay_generation: generation} ->
        id == witness.attempt_id and generation == witness.replay_generation

      _missing ->
        false
    end
  end

  @spec recover_expired_owner_lifecycle(map(), opts()) :: {:ok, term()} | {:error, term()}
  def recover_expired_owner_lifecycle(candidate, %RequestOptions{} = opts) do
    Repo.transaction(fn -> recover_expired_owner_locked(candidate, opts) end)
  end

  defp recover_expired_owner_locked(candidate, opts) do
    session = codex_session_for_update(candidate.session_id)

    if (session && session.owner_instance_id == candidate.owner_instance_id) and
         session.owner_lease_token == candidate.owner_lease_token and
         session.owner_lease_expires_at == candidate.owner_lease_expires_at and
         DateTime.compare(candidate.owner_lease_expires_at, now()) != :gt do
      # Keep the session lock before entering the shared finalization lock order.
      # Replay entitlement must still exist when execution recovery tests it.
      recovered_outcomes = recover_dead_session_executions(session.id, opts)

      close_expired_owner_replays!(candidate)

      case interrupt_session_transaction(candidate.session_id, opts, "owner_unavailable", true) do
        {:ok, result} ->
          %{result | interrupted_outcomes: recovered_outcomes ++ result.interrupted_outcomes}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    else
      :stale_owner
    end
  end

  defp close_expired_owner_replays!(candidate) do
    owner_snapshot =
      Map.take(candidate, [:owner_instance_id, :owner_lease_token, :owner_lease_expires_at])

    case Accounting.close_request_replays_for_session(
           candidate.session_id,
           owner_snapshot,
           :owner_shutdown
         ) do
      {:ok, _summary} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp recover_dead_session_executions(session_id, opts) do
    requests =
      Repo.all(
        from request in Request,
          join: turn in CodexTurn,
          on: turn.request_id == request.id,
          where: turn.codex_session_id == ^session_id and turn.status == ^@turn_in_progress,
          select: request
      )

    requests
    |> Enum.map(&recover_dead_request_execution(&1, opts))
    |> Enum.reject(&is_nil/1)
  end

  defp recover_dead_request_execution(request, opts) do
    attempt =
      Repo.one(
        from attempt in Attempt,
          where: attempt.request_id == ^request.id,
          order_by: [desc: attempt.attempt_number],
          limit: 1
      )

    if attempt do
      case Accounting.RequestLifecycle.recover_dead_execution(request, attempt, now()) do
        {:ok, :recovered} ->
          interruption_marker("interrupted", opts, bounded_transport(attempt.transport))

        {:ok, :noop} ->
          nil

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end
  end

  defp interrupt_owner_request(session_id, %RequestOptions{} = opts, reason) do
    caller_owned_transaction? = Repo.in_transaction?()

    Repo.transaction(fn ->
      session = codex_session_for_update(session_id)
      witness = opts.runtime.owner_cleanup

      with %OwnerCleanup{session_id: ^session_id} <- witness,
           %CodexSession{} <- session,
           true <- session.owner_lease_token == witness.owner_lease_token,
           true <- session.owner_instance_id == witness.owner_instance_id,
           true <- opts.transport.websocket_owner.lease_token == witness.owner_lease_token,
           %DateTime{} = expiry <- session.owner_lease_expires_at,
           true <- DateTime.compare(expiry, now()) == :gt,
           {:replacement_turn_active, false} <- {:replacement_turn_active, replacement_turn_active?(session_id, witness.request_id)},
           %Request{} = snapshot <- Repo.get(Request, witness.request_id),
           %APIKey{} <- Access.lock_api_key_for_read(snapshot.api_key_id),
           %CodexTurn{} = turn <- exact_owner_turn(session_id, witness),
           %Request{} = request <- request_for_update(witness.request_id),
           %Attempt{} = attempt <- latest_attempt_for_update(witness.request_id),
           true <- attempt.id == witness.attempt_id,
           true <- attempt.replay_generation == witness.replay_generation,
           true <- attempt.transport == "websocket",
           true <- request_owner_matches?(request, witness) do
        close_owner_replay!(witness.request_id)

        now = now()

        interrupt_selected_session_turn(session, %{
          turn: turn,
          opts: opts,
          reason: reason,
          now: now,
          next_status: @session_interrupted,
          lease_expires_at: DateTime.add(now, reconnect_window_seconds(opts), :second),
          caller_owned_transaction?: caller_owned_transaction?,
          turn_authority: @authority_selected
        })
      else
        # A later turn of the session is already running, so the owner-scoped
        # interrupt must not touch the session: the witnessed request, if it is
        # still open, is left to its request-scoped settlement (findings#252),
        # and a finished one needs nothing. Either way standing down is the
        # intended outcome, not a stale cleanup, so it gets its own reason and
        # the callers log it as routine rather than as a failure (findings#225).
        {:replacement_turn_active, true} -> Repo.rollback(:superseded_owner_cleanup)
        _missing_or_stale -> Repo.rollback(:stale_owner_cleanup)
      end
    end)
    |> finalize_transaction()
  end

  defp close_owner_replay!(request_id) do
    case Accounting.close_request_replay(request_id, :owner_shutdown) do
      {:ok, _disposition} -> :ok
      {:error, failure} -> Repo.rollback({:request_replay_close_failed, failure})
    end
  end

  defp replacement_turn_active?(session_id, request_id) do
    Repo.exists?(
      from turn in CodexTurn,
        where:
          turn.codex_session_id == ^session_id and turn.request_id != ^request_id and
            turn.status == ^@turn_in_progress
    )
  end

  defp exact_owner_turn(session_id, witness) do
    Repo.one(
      from turn in CodexTurn,
        where: turn.codex_session_id == ^session_id and turn.request_id == ^witness.request_id,
        lock: "FOR UPDATE"
    )
  end

  defp request_owner_matches?(
         request,
         %OwnerCleanup{replay_generation: 1, native_replay_binding: %Binding{} = binding} =
           witness
       ) do
    entitlement =
      Repo.one(
        from row in RequestReplayEntitlement,
          where: row.request_id == ^request.id,
          lock: "FOR UPDATE"
      )

    match?(%RequestReplayEntitlement{status: "consumed"}, entitlement) and
      entitlement.replay_attempt_id == witness.attempt_id and
      {binding.request_id, binding.replay_attempt_id} == {witness.request_id, witness.attempt_id} and
      replay_binding_identity_matches?(binding, entitlement) and
      binding.downstream_epoch == witness.downstream_epoch and
      binding.replay_generation == witness.replay_generation and
      binding.provisional_binding_digest == entitlement.provisional_binding_digest and
      binding.owner_lease_digest == entitlement.owner_lease_digest and
      RequestReplayEntitlement.verify_owner_lease_digest(
        witness.owner_lease_token,
        entitlement.owner_lease_key_version,
        entitlement.owner_lease_digest
      )
  end

  defp request_owner_matches?(_request, %OwnerCleanup{replay_generation: 1}), do: false

  defp request_owner_matches?(request, witness) do
    case request.request_metadata do
      %{
        "websocket_owner_forwarding" => %{
          "owner_instance_id" => owner,
          "downstream_epoch" => epoch
        }
      } ->
        owner == witness.owner_instance_id and epoch == witness.downstream_epoch

      _missing ->
        false
    end
  end

  defp replay_binding_identity_matches?(binding, entitlement) do
    fields = [:codex_turn_id, :eligible_attempt_id, :semantic_turn_digest, :replay_claim_digest]
    Map.take(binding, fields) == Map.take(entitlement, fields)
  end

  defp interrupt_session_transaction(session_id, opts, reason, caller_owned_transaction?) do
    now = now()
    reconnect_window = reconnect_window_seconds(opts)
    next_status = if reconnect_window > 0, do: @session_interrupted, else: @session_closed
    lease_expires_at = if reconnect_window > 0, do: DateTime.add(now, reconnect_window, :second)

    Repo.transaction(fn ->
      case codex_session_for_update(session_id) do
        %CodexSession{} = session ->
          interrupt_owned_session(
            session,
            opts,
            reason,
            now,
            next_status,
            lease_expires_at,
            caller_owned_transaction?
          )

        nil ->
          interruption_result(0, [])
      end
    end)
  end

  defp interrupt_owned_session(
         %CodexSession{} = session,
         %RequestOptions{} = opts,
         reason,
         now,
         next_status,
         lease_expires_at,
         caller_owned_transaction?
       ) do
    if terminating_owner_still_owns_session?(session, opts) do
      in_progress_turns =
        session.id
        |> in_progress_turns_for_session()
        |> Enum.filter(&owner_carried_turn?/1)

      interrupted_outcomes =
        in_progress_turns
        |> Enum.flat_map(&interrupt_turn!(&1, opts, reason, now, caller_owned_transaction?))

      session
      |> Ecto.Changeset.change(%{
        status: next_status,
        disconnected_at: now,
        closed_at: if(next_status == @session_closed, do: now, else: nil),
        owner_lease_expires_at: lease_expires_at,
        last_heartbeat_at: now,
        updated_at: now
      })
      |> Repo.update!()

      interruption_result(length(in_progress_turns), interrupted_outcomes)
    else
      interruption_result(0, [])
    end
  end

  defp interrupt_session_turn(session_id, turn_selector, %RequestOptions{} = opts, reason) do
    caller_owned_transaction? = Repo.in_transaction?()
    now = now()
    reconnect_window = reconnect_window_seconds(opts)
    next_status = if reconnect_window > 0, do: @session_interrupted, else: @session_closed
    lease_expires_at = if reconnect_window > 0, do: DateTime.add(now, reconnect_window, :second)

    interruption_context = %{
      opts: opts,
      reason: reason,
      now: now,
      next_status: next_status,
      lease_expires_at: lease_expires_at,
      caller_owned_transaction?: caller_owned_transaction?
    }

    Repo.transaction(fn ->
      session = codex_session_for_update(session_id)

      {turn, authority} = resolve_interrupt_turn(session, turn_selector, reason)

      interrupt_selected_session_turn(
        session,
        Map.merge(interruption_context, %{turn: turn, turn_authority: authority})
      )
    end)
    |> finalize_transaction()
  end

  # The exact selector is never widened: `turn_for_selector/2` still matches one
  # request correlation id and nothing else, because a selector that accepts
  # more identifier shapes lets a stale cleanup close a turn that is not its
  # own. What changes here is what happens when it names nothing. The session
  # row is already locked, so the session's own in-progress turns are resolved
  # under that lock, and the result says which of the two zeroes this is: an
  # idle session, or a turn that exists and the caller could not name
  # (icoretech/codex-pooler-findings#179).
  #
  # An unnamed in-progress turn is refused, never seized. The same rule already
  # governs `release_owner_cleanup_lease/3` through `other_active_turn?/2`: a
  # cleanup that cannot prove the in-progress turn is its own has no way to tell
  # an orphan apart from a turn another live connection is still serving, and
  # force-failing the second one is the harm the provenance fences exist to
  # prevent.
  defp resolve_interrupt_turn(nil, _selector, _reason), do: {nil, @authority_no_session}

  defp resolve_interrupt_turn(%CodexSession{} = session, selector, reason) do
    case turn_for_selector(session.id, selector) do
      %CodexTurn{} = turn -> {turn, @authority_selected}
      nil -> resolve_unnamed_turn(session, selector, reason)
    end
  end

  defp resolve_unnamed_turn(session, selector, reason) do
    case count_in_progress_turns(session.id) do
      0 ->
        {nil, if(selector == :none, do: @authority_no_selector, else: @authority_session_idle)}

      active_turn_count ->
        log_unresolved_turn_selector(session.id, selector, reason, active_turn_count)
        {nil, @authority_unresolved}
    end
  end

  # The miss that recorded nothing durable anywhere, which is why it stayed
  # invisible. Every value here is a fixed internal token, a trusted internal
  # correlator, or a bounded count, so the line is sanitized cleartext.
  defp log_unresolved_turn_selector(session_id, selector, reason, active_turn_count) do
    Logger.info(
      "websocket interrupt selector resolved no turn " <>
        "codex_session_id=#{safe_log_value(session_id)} " <>
        "interrupt_reason=#{safe_log_value(reason)} " <>
        "turn_selector=#{selector_kind(selector)} " <>
        "active_turn_count=#{active_turn_count} " <>
        "turn_authority=#{@authority_unresolved}"
    )

    :ok
  end

  defp selector_kind(:none), do: "absent"
  defp selector_kind({:request_id, _request_id}), do: "request_id"

  defp interrupt_selected_session_turn(nil, _interruption_context),
    do: interruption_result(0, [], @authority_no_session)

  defp interrupt_selected_session_turn(_session, %{turn: nil, turn_authority: authority}),
    do: interruption_result(0, [], authority)

  defp interrupt_selected_session_turn(%CodexSession{} = session, interruption_context) do
    %{
      turn: turn,
      opts: opts,
      reason: reason,
      now: now,
      next_status: next_status,
      lease_expires_at: lease_expires_at,
      caller_owned_transaction?: caller_owned_transaction?,
      turn_authority: authority
    } = interruption_context

    case preserve_succeeded_turn(turn, now) do
      :preserved ->
        interruption_result(0, [], authority)

      :continue ->
        {interrupted_count, interrupted_outcomes} =
          interrupt_selected_turn(turn, opts, reason, now, caller_owned_transaction?)

        session
        |> Ecto.Changeset.change(%{
          status: next_status,
          disconnected_at: now,
          closed_at: if(next_status == @session_closed, do: now, else: nil),
          owner_lease_expires_at: lease_expires_at,
          last_heartbeat_at: now,
          updated_at: now
        })
        |> Repo.update!()

        interruption_result(interrupted_count, interrupted_outcomes, authority)
    end
  end

  # The turn is always present here: `resolve_interrupt_turn/3` builds an
  # interruption context only when it has named one, and a session with nothing
  # in flight returns its authority before reaching this
  # (icoretech/codex-pooler-findings#179).
  defp preserve_succeeded_turn(%CodexTurn{} = turn, now) do
    request = request_for_update(turn.request_id)
    attempt = latest_attempt_for_update(turn.request_id)

    if request_completed_successfully?(request, attempt) do
      complete_interrupted_turn!(turn, attempt, @turn_succeeded, nil, now)
      :preserved
    else
      :continue
    end
  end

  defp interrupt_selected_turn(
         %CodexTurn{status: @turn_in_progress} = turn,
         opts,
         reason,
         now,
         caller_owned_transaction?
       ) do
    {1, interrupt_turn!(turn, opts, reason, now, caller_owned_transaction?)}
  end

  defp interrupt_selected_turn(_turn, _opts, _reason, _now, _caller_owned_transaction?),
    do: {0, []}

  defp interrupt_turn!(%CodexTurn{} = turn, opts, reason, now, caller_owned_transaction?) do
    request = request_for_update(turn.request_id)
    attempt = latest_attempt_for_update(turn.request_id)

    case recover_proven_dead_request(request, attempt) do
      %{kind: :stream_outcome} = marker ->
        [marker]

      nil ->
        do_interrupt_turn!(turn, request, attempt, opts, reason, now, caller_owned_transaction?)
    end
  end

  defp do_interrupt_turn!(turn, request, attempt, opts, reason, now, caller_owned_transaction?) do
    cond do
      request_completed_successfully?(request, attempt) ->
        complete_interrupted_turn!(turn, attempt, @turn_succeeded, nil, now)
        []

      request && request.status in ["accepted", "in_progress"] && active_attempt?(attempt) ->
        markers =
          finalize_interrupted_request!(
            request,
            attempt,
            opts,
            reason,
            caller_owned_transaction?
          )

        complete_interrupted_turn!(turn, attempt, @turn_interrupted, reason, now)
        List.wrap(markers)

      request && request.status in ["accepted", "in_progress"] ->
        # Release only. This branch is not drain-specific: it also serves
        # `client_disconnected` and the expired-owner sweeper's
        # `owner_unavailable`, and every one of them leaves a reservation that
        # has to go back (icoretech/codex-pooler-findings#167).
        #
        # It deliberately writes no `websocket_pre_attempt_drain` marker. The
        # only marker a client resend may act on is the one
        # `interrupt_direct_request/2` writes from a validated
        # `%DirectCleanup{}` receipt, where the owner relationship is proven
        # out of band rather than read back out of the same rows being
        # interrupted. A second producer here was removed as unreachable in
        # production (icoretech/codex-pooler-findings#178): do not restore one
        # without a receipt-equivalent provenance proof, because a marker
        # written on weaker evidence admits a resend whose predecessor may
        # still hold reserved budget.
        #
        # It was unreachable for reasons that are not structural, so do not
        # read the removal as proof that this branch cannot be entered -- it
        # can, and tests drive it through `interrupt_codex_turn/2` with a
        # turn's own correlation id. The caller that looked closest,
        # `cancel_direct_response_task/2`, runs only in the non-owner branch,
        # so `Adapter.response_options/3` builds its options with
        # `websocket_response_options/4` and no owner binding exists to gate
        # on. It also never reaches any selector: its `nil` branch is taken
        # only when the socket has no `%DirectCleanup{}` context for the task,
        # and the context is written exactly when `codex_session` is present,
        # so that branch always ran with no session at all. It used to pass the
        # socket's connection-level request id anyway -- which a native turn's
        # claim-key `correlation_id` never equals -- and now passes the
        # receipt's exact request id or records that it holds no turn identity
        # (icoretech/codex-pooler-findings#179). Neither shape revives this
        # branch from that caller.
        release_markers =
          release_unattempted_request!(
            request,
            attempt,
            opts,
            reason,
            now,
            caller_owned_transaction?
          )

        complete_interrupted_turn!(turn, attempt, @turn_interrupted, reason, now)

        release_markers ++
          [
            interruption_marker(
              "interrupted",
              opts,
              bounded_transport(attempt && attempt.transport)
            )
          ]

      true ->
        complete_interrupted_turn!(
          turn,
          attempt,
          terminal_turn_status(request),
          terminal_error_code(request),
          now
        )

        []
    end
  end

  defp recover_proven_dead_request(%Request{} = request, %Attempt{}) do
    case DeadExecutionResendRecovery.recover(request, true, now()) do
      {:ok, _recovered, %{kind: :stream_outcome} = marker} -> marker
      {:ok, _request, nil} -> nil
      {:error, :active_predecessor} -> nil
    end
  end

  defp recover_proven_dead_request(_request, _attempt), do: nil

  # A turn interrupted before any attempt existed still holds whatever the
  # reservation reserved, so the release is written for every reason this
  # branch serves, not only for drains; only the resend marker above is
  # drain-specific. The declared phase is the same `turn_interrupted` the
  # direct-receipt path writes, because the boundary is the same one: a live
  # turn interrupted before any attempt existed. Which entry point ran is an
  # accident of how the interruption arrived, and the reason it arrived for is
  # already in `release_reason`.
  #
  # A request that never reached the ledger (a claim rejected
  # before reservation) has nothing to release and keeps the plain failure
  # write, because `finalize_reservation_failure/2` requires the reservation
  # row to exist.
  #
  # A terminal attempt row (a retryable failure whose retry never started)
  # means the reservation did reach dispatch: releasing it as a pre-attempt
  # `turn_interrupted` would misdescribe the boundary and count a dispatched
  # abandonment in the pre-attempt series. The reservation is still released
  # in full (never settled: nothing was charged), but the release carries the
  # attempt's id and no phase key (findings#221). This stays on the
  # reservation-failure path on purpose: the disposition finalizer has a
  # write-nothing arm for a stale replay generation, and an armed replay
  # entitlement is exactly how a `retryable_failed` attempt arises.
  defp release_unattempted_request!(
         request,
         %Attempt{} = attempt,
         opts,
         reason,
         now,
         caller_owned_transaction?
       ) do
    if Accounting.reservation_outstanding?(request) do
      case Accounting.finalize_reservation_failure(request, %{
             last_error_code: reason,
             response_status_code: 499,
             usage_status: "usage_unknown",
             now: now,
             released_after_attempt: attempt
           }) do
        {:ok, released} ->
          # The armed entitlement that produced this terminal attempt has no
          # reservation left to consume; close it so the sweep does not
          # re-select it every pass (findings#221).
          _ = Accounting.revoke_armed_replay_entitlement!(request.id, attempt, now)
          after_commit_markers(released)

        {:error, error} ->
          rollback_interrupted_accounting(error, opts, attempt, caller_owned_transaction?)
      end
    else
      # No reservation left to release, but the terminal attempt may still be
      # the eligible attempt of an armed entitlement (findings#221).
      _ = Accounting.revoke_armed_replay_entitlement!(request.id, attempt, now)
      release_unattempted_request!(request, nil, opts, reason, now, caller_owned_transaction?)
    end
  end

  defp release_unattempted_request!(request, nil, opts, reason, now, caller_owned_transaction?) do
    if Accounting.reservation_outstanding?(request) do
      case Accounting.finalize_reservation_failure(request, %{
             last_error_code: reason,
             response_status_code: 499,
             usage_status: "usage_unknown",
             now: now,
             pre_attempt_phase: PreAttemptRelease.turn_interrupted()
           }) do
        {:ok, released} ->
          after_commit_markers(released)

        {:error, error} ->
          rollback_interrupted_accounting(error, opts, nil, caller_owned_transaction?)
      end
    else
      request
      |> Ecto.Changeset.change(%{
        status: "failed",
        usage_status: "usage_unknown",
        completed_at: now,
        response_status_code: 499,
        last_error_code: reason
      })
      |> Repo.update!()

      []
    end
  end

  defp finalize_interrupted_request!(request, attempt, opts, reason, caller_owned_transaction?) do
    case Accounting.finalize_request_with_disposition(request, attempt, %{
           request_status: "failed",
           attempt_status: "failed",
           response_status_code: 499,
           last_error_code: reason,
           error_message: "websocket client disconnected before the turn completed",
           usage: %{status: "usage_unknown", source: reason}
         }) do
      {:ok, %{finalization_disposition: :inserted}} ->
        interruption_marker("interrupted", opts, bounded_transport(attempt.transport))

      {:ok, %{finalization_disposition: disposition}}
      when disposition in [:reused, :replaced] ->
        nil

      {:error, error} ->
        rollback_interrupted_accounting(error, opts, attempt, caller_owned_transaction?)
    end
  rescue
    exception ->
      rollback_interrupted_accounting(exception, opts, attempt, caller_owned_transaction?)
  end

  # Failure markers are built before rollback for every caller. The outermost
  # transaction publishes them after it finishes; a caller-owned transaction
  # receives them in the deferred error result and can publish only if its own
  # transaction commits. A rollback therefore loses neither error identity nor
  # the information needed to make the commit decision.
  defp rollback_interrupted_accounting(error, opts, attempt, _caller_owned_transaction?) do
    Repo.rollback(
      public_error: {:interrupt_accounting_failed, error},
      interrupted_outcomes: [
        interruption_marker(
          "settlement_failed",
          opts,
          bounded_transport(attempt && attempt.transport)
        )
      ]
    )
  end

  defp in_progress_turns_for_session(session_id) do
    Repo.all(
      from turn in CodexTurn,
        where: turn.codex_session_id == ^session_id and turn.status == ^@turn_in_progress,
        order_by: [asc: turn.started_at]
    )
  end

  # A same-session turn that fell back to plain HTTP while this owner was
  # draining is served by a live request process under the same lease token;
  # the terminating owner must not force-fail it. Only turns actually carried
  # over this owner's websocket are interrupted. A turn with no attempt yet
  # keeps today's conservative interrupt because its carrier is undecided.
  defp owner_carried_turn?(%CodexTurn{request_id: request_id}) do
    case latest_attempt_transport(request_id) do
      nil -> true
      "websocket" -> true
      _transport -> false
    end
  end

  defp latest_attempt_transport(request_id) do
    Repo.one(
      from attempt in Attempt,
        where: attempt.request_id == ^request_id,
        order_by: [desc: attempt.attempt_number],
        limit: 1,
        select: attempt.transport
    )
  end

  defp turn_for_selector(_session_id, :none), do: nil

  defp turn_for_selector(session_id, {:request_id, request_id}) do
    Repo.one(
      from turn in CodexTurn,
        join: request in Request,
        on: request.id == turn.request_id,
        where: turn.codex_session_id == ^session_id and request.correlation_id == ^request_id,
        order_by: [desc: turn.started_at],
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  defp count_in_progress_turns(session_id) do
    Repo.aggregate(
      from(turn in CodexTurn,
        where: turn.codex_session_id == ^session_id and turn.status == ^@turn_in_progress
      ),
      :count
    )
  end

  defp latest_attempt_for_update(request_id) do
    Repo.one(
      from attempt in Attempt,
        where: attempt.request_id == ^request_id,
        order_by: [desc: attempt.attempt_number],
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  @spec codex_session_for_update(Ecto.UUID.t()) :: CodexSession.t() | nil
  defp codex_session_for_update(session_id) do
    Repo.one(
      from session in CodexSession,
        where: session.id == ^session_id,
        lock: "FOR UPDATE"
    )
  end

  @spec request_for_update(Ecto.UUID.t()) :: Request.t() | nil
  defp request_for_update(request_id) do
    Repo.one(
      from request in Request,
        where: request.id == ^request_id,
        lock: "FOR UPDATE"
    )
  end

  defp active_attempt?(%Attempt{status: status}), do: status in ["queued", "in_progress"]
  defp active_attempt?(_attempt), do: false

  defp request_completed_successfully?(%Request{status: "succeeded"}, _attempt), do: true
  defp request_completed_successfully?(_request, %Attempt{status: "succeeded"}), do: true
  defp request_completed_successfully?(_request, _attempt), do: false

  defp terminal_turn_status(%Request{status: "succeeded"}), do: @turn_succeeded

  # One vocabulary with the stream finalizers: a turn whose request failed
  # because it lost its client or its owner is interrupted, any other failure
  # is failed (findings#228).
  defp terminal_turn_status(%Request{status: "failed", last_error_code: error_code}) do
    if InterruptionOutcome.interrupted_error_code?(error_code),
      do: @turn_interrupted,
      else: @turn_failed
  end

  defp terminal_turn_status(%Request{status: status})
       when status in ["rejected", "cancelled"],
       do: @turn_failed

  defp terminal_turn_status(_request), do: @turn_interrupted

  defp terminal_error_code(%Request{status: "succeeded"}), do: nil
  defp terminal_error_code(%Request{last_error_code: code}) when is_binary(code), do: code
  defp terminal_error_code(_request), do: "client_disconnected"

  defp complete_interrupted_turn!(turn, attempt, status, error_code, now) do
    turn
    |> Ecto.Changeset.change(%{
      status: status,
      error_code: error_code,
      final_attempt_id: attempt && attempt.id,
      completed_at: now,
      updated_at: now
    })
    |> Repo.update!()
  end

  defp reconnect_window_seconds(%RequestOptions{} = opts) do
    case opts.continuity.reconnect_window_seconds || @default_reconnect_window_seconds do
      seconds when is_integer(seconds) and seconds >= 0 -> seconds
      _value -> @default_reconnect_window_seconds
    end
  end

  defp interrupt_reason(%RequestOptions{runtime: %{interrupt_reason: reason}})
       when is_binary(reason) and reason != "",
       do: reason

  defp interrupt_reason(%RequestOptions{}), do: "client_disconnected"

  defp request_id(%RequestOptions{request_metadata: %{request_id: request_id}})
       when is_binary(request_id) do
    request_id = String.trim(request_id)
    if request_id == "", do: nil, else: request_id
  end

  defp request_id(%RequestOptions{}), do: nil

  defp terminating_owner_still_owns_session?(
         %CodexSession{owner_lease_token: current_lease_token},
         %RequestOptions{transport: %{websocket_owner: %{lease_token: terminating_lease_token}}}
       )
       when is_binary(terminating_lease_token),
       do: current_lease_token == terminating_lease_token

  defp terminating_owner_still_owns_session?(%CodexSession{}, %RequestOptions{}), do: false

  defp owner_recovery_reason(:owner_drained), do: "owner_drained"
  defp owner_recovery_reason("owner_drained"), do: "owner_drained"
  defp owner_recovery_reason(:owner_crashed), do: "owner_crashed"
  defp owner_recovery_reason("owner_crashed"), do: "owner_crashed"
  defp owner_recovery_reason(_reason), do: "owner_unavailable"

  # Standing down because a later turn of the session is running is the
  # intended outcome of a recovery, not a failed one (findings#225, row 225-85).
  defp log_owner_lifecycle_recovery_failure(session_id, reason, :superseded_owner_cleanup) do
    Logger.info(
      "websocket owner lifecycle recovery superseded " <>
        "codex_session_id=#{safe_log_value(session_id)} " <>
        "recovery_reason=#{safe_log_value(reason)} " <>
        "reason_code=replacement_turn_active"
    )

    :ok
  end

  defp log_owner_lifecycle_recovery_failure(session_id, reason, failure) do
    Logger.warning(
      "websocket owner lifecycle recovery failed " <>
        "codex_session_id=#{safe_log_value(session_id)} " <>
        "recovery_reason=#{safe_log_value(reason)} " <>
        "failure_reason=#{safe_log_value(Metadata.safe_reason(failure))}"
    )

    :ok
  end

  defp safe_log_value(value) when is_binary(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9_.:-]+/, "_")
    |> String.slice(0, 120)
    |> case do
      "" -> "unknown"
      sanitized -> sanitized
    end
  end

  defp safe_log_value(_value), do: "unknown"

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp interruption_result(
         interrupted_turn_count,
         interrupted_outcomes,
         turn_authority \\ @authority_selected
       ) do
    %{
      public_result: %{
        interrupted_turn_count: interrupted_turn_count,
        turn_authority: turn_authority
      },
      interrupted_outcomes: interrupted_outcomes
    }
  end

  defp interruption_marker(outcome, opts, upstream_transport) do
    %{
      kind: :stream_outcome,
      outcome: outcome,
      downstream_transport: Streaming.downstream_transport(opts),
      upstream_transport: upstream_transport
    }
  end

  defp bounded_transport(transport) when transport in ["http_sse", "websocket"], do: transport
  defp bounded_transport(_transport), do: "unknown"

  @doc """
  Emits the interrupted outcomes of a committed expired-owner recovery.

  A caller that already holds a transaction has not committed anything yet, so
  the markers are handed back instead of emitted. `{:deferred, markers}` is not
  a promise that anyone emits them: the sole caller,
  `CodexPooler.Gateway.Persistence.RuntimeCleanup`, logs how many there were
  and returns `:ok`. What the return buys is that the drop is audible instead
  of silent, and that the caller — the only thing that knows when its own write
  becomes durable — is the one that decides.

  `CodexPooler.Jobs.RuntimeStateCleanup` runs every step bare, so the deferred
  arm is unreachable in production today. It is returned rather than assumed
  because that is the invariant the after-commit property rests on, and an
  invariant that has to hold is worth being told about when it stops holding.
  """
  @spec emit_committed_recovery_outcomes(%{interrupted_outcomes: [map()]}) ::
          :ok | {:deferred, [map()]}
  def emit_committed_recovery_outcomes(%{interrupted_outcomes: markers}),
    do: emit_outcomes_after_commit(markers)

  @doc false
  @spec emit_committed_deferred_outcomes([map()]) :: :ok | {:deferred, [map()]}
  def emit_committed_deferred_outcomes(markers) when is_list(markers),
    do: emit_outcomes_after_commit(markers)

  # The only place an interrupted outcome is emitted, and the only place the
  # after-commit rule is decided.
  #
  # findings#195 row 195-05 asks that every caller that can drop these markers
  # be audited. An enumeration of call sites answers that only until the next
  # one is written, so the property is placed in the gate instead: a caller
  # cannot emit an outcome without coming through here, and coming through here
  # cannot emit inside a transaction. A fourth site added tomorrow inherits the
  # rule rather than needing to be found.
  #
  # The check is `Repo.in_transaction?/0` rather than a flag threaded down from
  # the caller because the flag is a claim about the transaction and this is the
  # transaction itself.
  @spec emit_outcomes_after_commit([map()]) :: :ok | {:deferred, [map()]}
  defp emit_outcomes_after_commit(markers) do
    if Repo.in_transaction?() do
      {:deferred, markers}
    else
      emit_committed_markers(markers)
      :ok
    end
  end

  defp finalize_transaction({:ok, %{public_result: public_result, interrupted_outcomes: markers}}) do
    case emit_outcomes_after_commit(markers) do
      :ok -> {:ok, public_result}
      {:deferred, deferred} -> {:ok, Map.put(public_result, :after_commit_markers, deferred)}
    end
  end

  defp finalize_transaction({:error, [public_error: public_error, interrupted_outcomes: markers]}) do
    case emit_outcomes_after_commit(markers) do
      :ok -> {:error, public_error}
      {:deferred, deferred} -> {:error, {:deferred_after_commit, public_error, deferred}}
    end
  end

  defp finalize_transaction({:error, reason}), do: {:error, reason}

  defp finalize_marker_transaction({:ok, []}), do: :ok

  defp finalize_marker_transaction({:ok, markers}) when is_list(markers) do
    case emit_outcomes_after_commit(markers) do
      :ok -> :ok
      {:deferred, deferred} -> {:ok, %{after_commit_markers: deferred}}
    end
  end

  defp finalize_marker_transaction({:error, [public_error: public_error, interrupted_outcomes: markers]}) do
    case emit_outcomes_after_commit(markers) do
      :ok -> {:error, public_error}
      {:deferred, deferred} -> {:error, {:deferred_after_commit, public_error, deferred}}
    end
  end

  defp finalize_marker_transaction({:error, error}), do: {:error, error}

  defp emit_committed_markers(markers), do: Enum.each(markers, &emit_after_commit_marker/1)

  defp emit_after_commit_marker(%{kind: :pre_attempt_release} = marker),
    do: PreAttemptRelease.emit_marker(marker)

  defp emit_after_commit_marker(%{kind: :stream_outcome, outcome: "interrupted"} = marker) do
    InterruptionOutcome.emit(
      marker.downstream_transport,
      marker.upstream_transport
    )
  end

  defp emit_after_commit_marker(%{kind: :stream_outcome} = marker) do
    Streaming.emit_stream_outcome(
      marker.outcome,
      marker.downstream_transport,
      marker.upstream_transport
    )
  end

  defp after_commit_markers(%{after_commit_markers: markers}) when is_list(markers), do: markers
  defp after_commit_markers(_result), do: []
end
