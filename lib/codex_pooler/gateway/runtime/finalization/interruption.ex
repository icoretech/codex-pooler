defmodule CodexPooler.Gateway.Runtime.Finalization.Interruption do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request, RequestReplayEntitlement}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Session, as: SessionStatus
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Turn, as: TurnStatus
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata
  alias CodexPooler.Gateway.Runtime.Finalization.Streaming
  alias CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission.Binding
  alias CodexPooler.Gateway.Websocket.OwnerCleanup
  alias CodexPooler.Repo

  require Logger

  @default_reconnect_window_seconds 300

  @type opts :: RequestOptions.t()
  @type session_ref :: CodexSession.t() | Ecto.UUID.t()

  @session_interrupted SessionStatus.interrupted_status()
  @session_closed SessionStatus.closed_status()
  @turn_in_progress TurnStatus.in_progress_status()
  @turn_succeeded TurnStatus.succeeded_status()
  @turn_failed TurnStatus.failed_status()
  @turn_interrupted TurnStatus.interrupted_status()

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
    case request_id(opts) do
      nil ->
        {:ok, %{interrupted_turn_count: 0}}

      request_id ->
        interrupt_session_turn(
          session_id,
          {:request_id, request_id},
          opts,
          interrupt_reason(opts)
        )
    end
  end

  def interrupt_codex_turn(_session_id, _opts), do: {:ok, %{interrupted_turn_count: 0}}

  @spec interrupt_detached_codex_turn(session_ref(), opts()) ::
          {:ok, term()} | {:error, term()}
  def interrupt_detached_codex_turn(%CodexSession{id: id}, opts),
    do: interrupt_detached_codex_turn(id, opts)

  def interrupt_detached_codex_turn(session_id, %RequestOptions{} = opts)
      when is_binary(session_id) do
    interrupt_owner_request(session_id, opts, interrupt_reason(opts))
  end

  def interrupt_detached_codex_turn(_session_id, _opts),
    do: {:ok, %{interrupted_turn_count: 0}}

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
      case interrupt_session(candidate.session_id, opts, "owner_unavailable") do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      Repo.rollback(:stale_owner_cleanup)
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
           false <- replacement_turn_active?(session_id, witness.request_id),
           %Request{} = snapshot <- Repo.get(Request, witness.request_id),
           %APIKey{} <-
             Repo.one(
               from key in APIKey, where: key.id == ^snapshot.api_key_id, lock: "FOR UPDATE"
             ),
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
          caller_owned_transaction?: caller_owned_transaction?
        })
      else
        _missing_or_stale -> Repo.rollback(:stale_owner_cleanup)
      end
    end)
    |> finalize_transaction(caller_owned_transaction?)
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

  defp interrupt_session(session_id, %RequestOptions{} = opts, reason) do
    caller_owned_transaction? = Repo.in_transaction?()
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
    |> finalize_transaction(caller_owned_transaction?)
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
        |> Enum.map(&interrupt_turn!(&1, opts, reason, now, caller_owned_transaction?))
        |> Enum.reject(&is_nil/1)

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
      turn = turn_for_selector(session_id, turn_selector)
      interrupt_selected_session_turn(session, Map.put(interruption_context, :turn, turn))
    end)
    |> finalize_transaction(caller_owned_transaction?)
  end

  defp interrupt_selected_session_turn(nil, _interruption_context),
    do: interruption_result(0, [])

  defp interrupt_selected_session_turn(_session, %{turn: nil}),
    do: interruption_result(0, [])

  defp interrupt_selected_session_turn(%CodexSession{} = session, interruption_context) do
    %{
      turn: turn,
      opts: opts,
      reason: reason,
      now: now,
      next_status: next_status,
      lease_expires_at: lease_expires_at,
      caller_owned_transaction?: caller_owned_transaction?
    } = interruption_context

    case preserve_succeeded_turn(turn, now) do
      :preserved ->
        interruption_result(0, [])

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

        interruption_result(interrupted_count, interrupted_outcomes)
    end
  end

  defp preserve_succeeded_turn(turn, now) do
    case turn do
      %CodexTurn{} = turn ->
        request = request_for_update(turn.request_id)
        attempt = latest_attempt_for_update(turn.request_id)

        if request_completed_successfully?(request, attempt) do
          complete_interrupted_turn!(turn, attempt, @turn_succeeded, nil, now)
          :preserved
        else
          :continue
        end

      nil ->
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
    marker = interrupt_turn!(turn, opts, reason, now, caller_owned_transaction?)
    {1, if(marker, do: [marker], else: [])}
  end

  defp interrupt_selected_turn(_turn, _opts, _reason, _now, _caller_owned_transaction?),
    do: {0, []}

  defp interrupt_turn!(%CodexTurn{} = turn, opts, reason, now, caller_owned_transaction?) do
    request = request_for_update(turn.request_id)
    attempt = latest_attempt_for_update(turn.request_id)

    cond do
      request_completed_successfully?(request, attempt) ->
        complete_interrupted_turn!(turn, attempt, @turn_succeeded, nil, now)
        nil

      request && request.status in ["accepted", "in_progress"] && active_attempt?(attempt) ->
        marker =
          finalize_interrupted_request!(
            request,
            attempt,
            opts,
            reason,
            caller_owned_transaction?
          )

        complete_interrupted_turn!(turn, attempt, @turn_interrupted, reason, now)
        marker

      request && request.status in ["accepted", "in_progress"] ->
        request
        |> Ecto.Changeset.change(%{
          status: "failed",
          usage_status: "usage_unknown",
          completed_at: now,
          response_status_code: 499,
          last_error_code: reason
        })
        |> Repo.update!()

        complete_interrupted_turn!(turn, attempt, @turn_interrupted, reason, now)
        interruption_marker("interrupted", opts, "unknown")

      true ->
        complete_interrupted_turn!(
          turn,
          attempt,
          terminal_turn_status(request),
          terminal_error_code(request),
          now
        )

        nil
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

  defp rollback_interrupted_accounting(error, _opts, _attempt, true) do
    Repo.rollback({:interrupt_accounting_failed, error})
  end

  defp rollback_interrupted_accounting(error, opts, attempt, false) do
    Repo.rollback(
      public_error: {:interrupt_accounting_failed, error},
      interrupted_outcomes: [
        interruption_marker("settlement_failed", opts, bounded_transport(attempt.transport))
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

  defp terminal_turn_status(%Request{status: "failed", last_error_code: error_code})
       when error_code in ["client_disconnected", "owner_drained", "owner_unavailable"],
       do: @turn_interrupted

  defp terminal_turn_status(%Request{status: status})
       when status in ["failed", "rejected", "cancelled"],
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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp interruption_result(interrupted_turn_count, interrupted_outcomes) do
    %{
      public_result: %{interrupted_turn_count: interrupted_turn_count},
      interrupted_outcomes: interrupted_outcomes
    }
  end

  defp interruption_marker(outcome, opts, upstream_transport) do
    %{
      outcome: outcome,
      downstream_transport: Streaming.downstream_transport(opts),
      upstream_transport: upstream_transport
    }
  end

  defp bounded_transport(transport) when transport in ["http_sse", "websocket"], do: transport
  defp bounded_transport(_transport), do: "unknown"

  defp finalize_transaction(
         {:ok, %{public_result: public_result, interrupted_outcomes: markers}},
         caller_owned_transaction?
       ) do
    unless caller_owned_transaction?, do: Enum.each(markers, &emit_interrupted_outcome/1)
    {:ok, public_result}
  end

  defp finalize_transaction(
         {:error, [public_error: public_error, interrupted_outcomes: markers]},
         caller_owned_transaction?
       ) do
    unless caller_owned_transaction?, do: Enum.each(markers, &emit_interrupted_outcome/1)
    {:error, public_error}
  end

  defp finalize_transaction({:error, reason}, _caller_owned_transaction?), do: {:error, reason}

  defp emit_interrupted_outcome(marker) do
    Streaming.emit_stream_outcome(
      marker.outcome,
      marker.downstream_transport,
      marker.upstream_transport
    )
  end
end
