defmodule CodexPooler.Accounting.RequestLifecycle.AdmissionExecutionRecovery do
  @moduledoc false
  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, ClientRetry, LedgerEntry, PreAttemptRelease, Request, RequestLifecycle, RequestReplayEntitlement}
  alias CodexPooler.Accounting.RequestLifecycle.LedgerEntries
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn, RuntimeCleanup}
  alias CodexPooler.Platform.{ExecutionTerminalProof, ExecutionTerminalProofs, InstancePresence, TransientDatabaseError}
  alias CodexPooler.Repo

  @request_statuses ~w(accepted in_progress)
  @recovery_code "admission_execution_recovered"
  @database_unavailable :admission_recovery_database_unavailable
  @identity_fields [:admission_instance_id, :admission_instance_boot_id, :admission_process_id, :admission_execution_id]

  @type summary :: %{
          required(:admission_only_requests_recovered) => non_neg_integer(),
          optional(:after_commit_markers) => [PreAttemptRelease.marker()]
        }
  @type result :: {:ok, summary()} | {:error, term(), summary()}

  @spec recover(DateTime.t(), keyword()) :: result()
  def recover(now, opts \\ []), do: recover_candidates(:scheduled, now, opts)

  @spec recover_published(DateTime.t(), keyword()) :: result()
  def recover_published(now, opts \\ []), do: recover_candidates(:published, now, opts)

  @spec recover_execution_ids([Ecto.UUID.t()], DateTime.t(), keyword()) :: result()
  def recover_execution_ids(ids, now, opts \\ []) when is_list(ids),
    do: recover_candidates({:execution_ids, ids}, now, opts)

  @doc false
  @spec recover_native_retry(Request.t(), map(), DateTime.t()) :: {:ok, Request.t(), [PreAttemptRelease.marker()]} | :unchanged | {:error, atom()}
  def recover_native_retry(%Request{transport: "http_sse", endpoint: "/backend-api/codex/responses"} = request, scope, now) do
    turn = Repo.one(from(turn in CodexTurn, where: turn.request_id == ^request.id))

    cond do
      not match?(%CodexTurn{}, turn) ->
        :unchanged

      not native_retry_candidate?(request, turn) ->
        :unchanged

      not recovery_authorized?(request, turn, [], []) ->
        if request.last_error_code == @recovery_code, do: {:error, :terminal_predecessor}, else: :unchanged

      not native_retry_scope?(request, turn, scope) ->
        {:error, :authorization_changed}

      request.last_error_code == @recovery_code ->
        if recovered_native_turn?(request, turn), do: {:ok, request, []}, else: {:error, :terminal_predecessor}

      true ->
        recover_native_candidate(request, now)
    end
  end

  def recover_native_retry(_request, _scope, _now), do: :unchanged

  defp native_retry_candidate?(request, turn), do: request.last_error_code == @recovery_code or unstarted_native_turn?(turn, request)

  defp recover_native_candidate(request, now) do
    case recover_candidate(request, now, include_superseded: false, skip_locked: false) do
      {:ok, :recovered, markers} -> {:ok, Repo.reload!(request), markers}
      {:ok, :noop, []} -> :unchanged
      {:error, _reason} -> {:error, :active_predecessor}
    end
  end

  defp native_retry_scope?(request, turn, scope) do
    fields = [:pool_id, :api_key_id, :model_id, :endpoint]

    Map.take(request, fields) == Map.take(scope, fields) and turn.codex_session_id == scope.codex_session_id and
      not scope.anchor_present? and native_retry_witness?(request, scope)
  end

  defp native_retry_witness?(request, scope) do
    case scope.native_client_retry_witness do
      %ClientRetry.OriginalWitness{version: 1, digest: digest, auth_epoch: epoch, alternates: alternates} ->
        ClientRetry.original_witness_eligible?(request) and request.native_client_retry_auth_epoch == epoch and epoch == scope.auth_epoch and
          ClientRetry.witness_matches?(request.native_client_retry_digest, digest, alternates)

      _missing ->
        false
    end
  end

  defp recovered_native_turn?(%Request{status: "failed", usage_status: "not_applicable", completed_at: %DateTime{}} = request, %CodexTurn{status: "interrupted", error_code: @recovery_code, transport_kind: "http_sse", final_attempt_id: nil, first_visible_output_at: nil, completed_at: %DateTime{}}) do
    recovery_authorized?(request, %CodexTurn{}, [], []) and
      not Repo.exists?(from(attempt in Attempt, where: attempt.request_id == ^request.id)) and
      not Repo.exists?(from(replay in RequestReplayEntitlement, where: replay.request_id == ^request.id)) and
      native_release_proven?(request)
  end

  defp recovered_native_turn?(_request, _turn), do: false

  defp native_release_proven?(request) do
    entries = Repo.all(from(entry in LedgerEntry, where: entry.request_id == ^request.id, order_by: entry.entry_kind))
    fields = [:pool_id, :api_key_id, :model_id, :transport, :currency_code, :input_tokens, :cached_input_tokens, :output_tokens, :reasoning_tokens, :total_tokens, :request_count, :estimated_cost_micros]

    case entries do
      [%LedgerEntry{entry_kind: "release", amount_status: "recorded", usage_status: "not_applicable", attempt_id: nil, settled_cost_micros: %Decimal{}, details: %{"release_reason" => @recovery_code, "pre_attempt_phase" => "turn_interrupted", "request_status" => "failed", "reservation_source_event_id" => reservation_source}} = release, %LedgerEntry{entry_kind: "reservation", amount_status: "recorded", attempt_id: nil} = reservation] ->
        reservation_source == reservation.source_event_id and
          release.source_event_id == LedgerEntries.release_source_event_id(request.id) and
          reservation.source_event_id == LedgerEntries.reservation_source_event_id(request.id) and
          Map.take(release, fields) == Map.take(reservation, fields) and Decimal.equal?(release.settled_cost_micros, 0)

      _other ->
        false
    end
  end

  defp recover_candidates(selector, now, opts) do
    caller_owned_transaction? = Repo.in_transaction?()

    opts =
      opts
      |> Keyword.put(:include_superseded, selector == :scheduled)
      |> Keyword.put(:skip_locked, selector == :published and not caller_owned_transaction?)
      |> put_query_deadline()

    {summary, failures, markers} =
      selector
      |> candidates(opts)
      |> Enum.reduce_while({initial_summary(), [], []}, fn candidate, acc ->
        recover_candidate(candidate, acc, now, opts)
      end)

    summary = publish_committed_markers(summary, markers, caller_owned_transaction?)

    if failures == [],
      do: {:ok, summary},
      else: {:error, {:admission_execution_candidates_failed, Enum.reverse(failures)}, summary}
  rescue
    exception ->
      {:error, {:admission_execution_candidates_failed, [{nil, failure_reason(exception)}]}, initial_summary()}
  catch
    :exit, _reason ->
      {:error, {:admission_execution_candidates_failed, [{nil, @database_unavailable}]}, initial_summary()}
  end

  defp candidates(selector, opts) do
    eligible =
      from request in Request,
        as: :request,
        where:
          request.status in ^@request_statuses and is_nil(request.completed_at) and
            not is_nil(request.admission_execution_id) and not is_nil(request.admission_instance_id) and
            not is_nil(request.admission_instance_boot_id) and not is_nil(request.admission_process_id),
        where:
          exists(
            from entry in LedgerEntry,
              where:
                entry.request_id == parent_as(:request).id and entry.entry_kind == "reservation" and
                  entry.amount_status == "recorded",
              select: 1
          ),
        where:
          not exists(
            from entry in LedgerEntry,
              where: entry.request_id == parent_as(:request).id and entry.entry_kind in ["release", "settlement"],
              select: 1
          ),
        where:
          not exists(
            from attempt in Attempt,
              where: attempt.request_id == parent_as(:request).id,
              select: 1
          ),
        where: not exists(subquery(unrecoverable_turns())),
        where:
          not exists(
            from replay in RequestReplayEntitlement,
              where: replay.request_id == parent_as(:request).id,
              select: 1
          ),
        order_by: [asc: fragment("COALESCE(?, ?)", request.admission_execution_checked_at, request.admitted_at), asc: request.id],
        limit: ^min(Keyword.get(opts, :limit, 100), 100)

    eligible
    |> select_authority(selector)
    |> skip_locked_candidates(opts)
    |> Repo.all(query_options(opts))
  end

  defp unrecoverable_turns do
    from turn in CodexTurn,
      where: turn.request_id == parent_as(:request).id,
      where:
        parent_as(:request).transport != "http_sse" or parent_as(:request).endpoint != "/backend-api/codex/responses" or
          turn.transport_kind != "http_sse" or turn.status != "in_progress" or
          not is_nil(turn.first_visible_output_at) or not is_nil(turn.final_attempt_id) or not is_nil(turn.completed_at),
      select: 1
  end

  defp select_authority(query, :scheduled), do: query

  defp select_authority(query, :published), do: join_terminal_proof(query)

  defp select_authority(query, {:execution_ids, ids}) do
    query
    |> where([request], request.admission_execution_id in ^ids)
    |> join_terminal_proof()
  end

  defp skip_locked_candidates(query, opts) do
    if Keyword.fetch!(opts, :skip_locked), do: lock(query, "FOR UPDATE SKIP LOCKED"), else: query
  end

  # Publication notifications are an accelerator, not a queue: this exact-proof
  # join retains work through a publisher/runner restart and never makes live
  # waiters consume a proof-only recovery batch.
  defp join_terminal_proof(query) do
    from request in query,
      join: proof in ExecutionTerminalProof,
      on:
        proof.execution_id == request.admission_execution_id and
          proof.owner_instance_id == request.admission_instance_id and
          proof.owner_instance_boot_id == request.admission_instance_boot_id and
          proof.owner_process_id == request.admission_process_id,
      where: is_nil(proof.interruption_code),
      select: request
  end

  defp recover_candidate(candidate, {summary, failures, markers}, now, opts) do
    case recover_candidate(candidate, now, opts) do
      {:ok, :recovered, committed_markers} ->
        summary = %{summary | admission_only_requests_recovered: summary.admission_only_requests_recovered + 1}
        {:cont, {summary, failures, markers ++ committed_markers}}

      {:ok, :noop, []} ->
        {:cont, {summary, failures, markers}}

      {:error, reason} ->
        acc = {summary, [{candidate.id, reason} | failures], markers}
        if reason == @database_unavailable, do: {:halt, acc}, else: {:cont, acc}
    end
  end

  defp recover_candidate(candidate, now, opts) do
    # Durable progress advances failed/live candidates behind untouched rows,
    # even if settlement rolls back or a different replica runs the next pass.
    db_opts = query_options(opts)

    prefix = if Repo.in_transaction?(), do: lock_native_turn_prefix(candidate, opts, db_opts)

    if prefix == :locked do
      {:ok, :noop, []}
    else
      case stamp_candidate(candidate, now, opts, db_opts) do
        {0, _rows} -> {:ok, :noop, []}
        {1, _rows} -> finalize_candidate(candidate, now, opts, db_opts)
      end
    end
  rescue
    exception -> {:error, failure_reason(exception)}
  catch
    :exit, _reason -> {:error, @database_unavailable}
  end

  defp finalize_candidate(candidate, now, opts, db_opts) do
    case Repo.transaction(fn -> recover_locked(candidate, now, opts, db_opts) end, db_opts) do
      {:ok, {:recovered, markers}} -> {:ok, :recovered, markers}
      {:ok, :noop} -> {:ok, :noop, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stamp_candidate(candidate, now, opts, db_opts) do
    query =
      from(request in Request,
        where:
          request.id == ^candidate.id and request.status in ^@request_statuses and
            request.admission_execution_id == ^candidate.admission_execution_id and
            request.admission_instance_id == ^candidate.admission_instance_id and
            request.admission_instance_boot_id == ^candidate.admission_instance_boot_id and
            request.admission_process_id == ^candidate.admission_process_id
      )

    query =
      if Keyword.fetch!(opts, :skip_locked) do
        # A row another lifecycle transaction holds is deferred, not a database
        # outage. Keep its proof queued while this pass reaches unlocked work.
        available = from(request in query, select: request.id, lock: "FOR UPDATE SKIP LOCKED")
        from(request in Request, where: request.id in subquery(available))
      else
        query
      end

    Repo.update_all(query, [set: [admission_execution_checked_at: now]], db_opts)
  end

  defp recover_locked(candidate, now, opts, db_opts) do
    turn = lock_native_turn_prefix(candidate, opts, db_opts)
    query = from(request in Request, where: request.id == ^candidate.id)
    query = if Keyword.fetch!(opts, :skip_locked), do: lock(query, "FOR UPDATE SKIP LOCKED"), else: lock(query, "FOR UPDATE")
    request = Repo.one(query, db_opts)

    # create_attempt and replay consumption serialize on this request lock.
    # Recheck everything after the wait; a stale candidate cannot release a
    # request the dispatcher or replay owner transitioned in the meantime.
    if turn != :locked and admission_only?(request, candidate, db_opts) and recovery_authorized?(request, turn, opts, db_opts) do
      case RequestLifecycle.finalize_reserved_request_failure(request, %{
             request_status: "failed",
             response_status_code: 499,
             last_error_code: @recovery_code,
             usage_status: "not_applicable",
             pre_attempt_phase: PreAttemptRelease.turn_interrupted(),
             now: now,
             before_commit: if(turn, do: fn _result -> RuntimeCleanup.recover_stale_request_turn(request.id, nil, now: now, error_code: @recovery_code) end)
           }) do
        {:ok, result} -> {:recovered, Map.get(result, :after_commit_markers, [])}
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      :noop
    end
  end

  defp admission_only?(%Request{} = request, candidate, opts) do
    request.status in @request_statuses and is_nil(request.completed_at) and
      Map.take(request, @identity_fields) == Map.take(candidate, @identity_fields) and
      admission_lifecycle_unstarted?(request, opts) and admission_reservation_open?(request.id, opts)
  end

  defp admission_only?(_missing, _candidate, _opts), do: false

  defp admission_lifecycle_unstarted?(%Request{id: id} = request, opts) do
    not Repo.exists?(from(attempt in Attempt, where: attempt.request_id == ^id), opts) and
      Enum.all?(Repo.all(from(turn in CodexTurn, where: turn.request_id == ^id), opts), &unstarted_native_turn?(&1, request)) and
      not Repo.exists?(from(replay in RequestReplayEntitlement, where: replay.request_id == ^id), opts)
  end

  defp unstarted_native_turn?(%CodexTurn{transport_kind: "http_sse", status: "in_progress", first_visible_output_at: nil, final_attempt_id: nil, completed_at: nil}, %Request{transport: "http_sse", endpoint: "/backend-api/codex/responses"}), do: true
  defp unstarted_native_turn?(_turn, _request), do: false

  # Native admission commits its turn with the reservation. Recover it under
  # the same session/key/turn/request order as dispatch and finalization.
  defp lock_native_turn_prefix(request, opts, db_opts) do
    case Repo.one(from(turn in CodexTurn, where: turn.request_id == ^request.id), db_opts) do
      nil ->
        nil

      %CodexTurn{codex_session_id: session_id} ->
        session_query = from(session in CodexSession, where: session.id == ^session_id)
        turn_query = from(turn in CodexTurn, where: turn.request_id == ^request.id)

        if Repo.one(recovery_lock(session_query, opts), db_opts) do
          _key = CodexPooler.Access.lock_api_key_for_read(request.api_key_id)
          Repo.one(recovery_lock(turn_query, opts), db_opts) || :locked
        else
          :locked
        end
    end
  end

  defp recovery_lock(query, opts) do
    if Keyword.fetch!(opts, :skip_locked), do: lock(query, "FOR UPDATE SKIP LOCKED"), else: lock(query, "FOR UPDATE")
  end

  defp admission_reservation_open?(id, opts) do
    Repo.exists?(from(entry in LedgerEntry, where: entry.request_id == ^id and entry.entry_kind == "reservation" and entry.amount_status == "recorded"), opts) and
      not Repo.exists?(from(entry in LedgerEntry, where: entry.request_id == ^id and entry.entry_kind in ["release", "settlement"]), opts)
  end

  defp recovery_authorized?(request, %CodexTurn{}, _opts, db_opts) do
    identity = execution_identity(request)
    ExecutionTerminalProofs.valid_identity?(identity) and ExecutionTerminalProofs.terminal?(identity, Keyword.put(db_opts, :include_interrupted, false))
  end

  defp recovery_authorized?(request, nil, opts, db_opts) do
    identity = execution_identity(request)
    proof_opts = Keyword.put(db_opts, :include_interrupted, Keyword.get(opts, :include_superseded, false))

    ExecutionTerminalProofs.valid_identity?(identity) and
      (ExecutionTerminalProofs.terminal?(identity, proof_opts) or
         (Keyword.get(opts, :include_superseded, true) and superseded_instance?(identity, opts)))
  end

  defp superseded_instance?(identity, opts) do
    owner = InstancePresence.Identity.owner(identity.owner_instance_id, identity.owner_instance_boot_id)
    now = InstancePresence.database_now()

    InstancePresence.observer_fresh?(now, opts) and
      InstancePresence.absent?(owner, now, opts) and InstancePresence.superseded?(owner)
  end

  defp execution_identity(request) do
    %{
      owner_instance_id: request.admission_instance_id,
      owner_instance_boot_id: request.admission_instance_boot_id,
      owner_process_id: request.admission_process_id,
      owner_execution_id: request.admission_execution_id
    }
  end

  defp put_query_deadline(opts) do
    case Keyword.get(opts, :timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> Keyword.put_new(opts, :deadline, System.monotonic_time(:millisecond) + timeout)
      _default -> opts
    end
  end

  defp query_options(opts), do: opts |> Keyword.take([:timeout, :deadline]) |> Keyword.put(:checkout_retries, 0)

  defp failure_reason(exception) do
    if TransientDatabaseError.transient?(exception), do: @database_unavailable, else: exception.__struct__
  end

  defp publish_committed_markers(summary, [], _caller_owned_transaction?), do: summary

  defp publish_committed_markers(summary, markers, true), do: Map.put(summary, :after_commit_markers, markers)

  defp publish_committed_markers(summary, markers, false) do
    Enum.each(markers, &PreAttemptRelease.emit_marker/1)
    summary
  end

  defp initial_summary, do: %{admission_only_requests_recovered: 0}
end
