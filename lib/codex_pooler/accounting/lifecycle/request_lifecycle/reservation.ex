defmodule CodexPooler.Accounting.RequestLifecycle.Reservation do
  @moduledoc false

  # The atomic successor transaction intentionally nests validation and writes.
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting

  import Ecto.Query

  alias CodexPooler.Access

  alias CodexPooler.Accounting.{
    ClientRetry,
    Metadata,
    NativeTurnProgress,
    PricingResolution,
    Request,
    RequestLogFacts,
    RequestReplay,
    ReservationPolicy
  }

  alias CodexPooler.Accounting.RequestLifecycle.{
    DeadExecutionResendRecovery,
    FailedPredecessorResend,
    LedgerEntries,
    TurnClaimRelease
  }

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.WebsocketTurnIdentity
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn, SessionContinuity}
  alias CodexPooler.Repo

  # The same NUMBER as `FailedPredecessorResend`'s own chain bound, and
  # deliberately not the same behaviour at it: that one returns
  # `{:error, :chain_exhausted}` and refuses, this one stops deriving and falls
  # open to a generated id. See `walk_native_turn_chain/4` for why (findings#212,
  # row 212-50).
  @native_turn_chain_depth 16

  @usage_pending "usage_pending"
  @usage_not_applicable "not_applicable"

  @spec claim_websocket_turn(
          CodexPooler.Access.auth_context(),
          Model.t(),
          map()
        ) :: {:ok, map()} | {:error, Metadata.accounting_error()}
  def claim_websocket_turn(%{pool: pool, api_key: api_key}, %Model{} = model, opts) do
    cond do
      ClientRetry.reserved_successor_claim?(attr(opts, :correlation_id)) ->
        {:error, duplicate_request_error(nil)}

      await_live_semantic_predecessor(opts) == :live ->
        {:error, duplicate_request_error(:active_predecessor)}

      true ->
        case do_claim_websocket_turn(pool, api_key, model, opts, nil) do
          {:error, %{code: :duplicate_request}} ->
            pool
            |> claim_failed_predecessor_resend(api_key, model, opts)
            |> retry_after_live_claim_holder(pool, api_key, model, opts)

          result ->
            result
        end
    end
  end

  # The released client drops a socket in the middle of a streaming turn and at
  # once sends the same turn again on a new socket, as full history without the
  # anchor, so under a different request claim than the request still running
  # on the dropped socket. With owner forwarding off nothing else stands between
  # that resend and the reservation: the dropped socket's direct task keeps the
  # predecessor turn `in_progress` until that socket's cleanup stops it (250 ms
  # after the close, plus its settlement), and a resend claimed inside that
  # window met the active-turn index (`codex_turns_active_semantic_turn_uq`)
  # when its turn started, answered `500 websocket_response_task_failed` and
  # left its claim `accepted` (findings#206 row 206-407). The claim therefore
  # waits, bounded, until the database no longer shows such a predecessor, and
  # a predecessor still live at the bound (its socket's close not seen yet) is
  # refused before anything is written, as the `409 duplicate_turn` a
  # byte-identical resend of a running request already gets. A resend carrying
  # the running request's own claim waits the same way once the resend policy
  # found that request still running (`retry_after_live_claim_holder/5`).
  # Nothing waits inside a caller's transaction.
  @live_predecessor_wait_budget_ms 1_000
  @live_predecessor_poll_ms 20

  defp await_live_semantic_predecessor(opts) do
    case live_predecessor_scope(opts) do
      nil ->
        :none

      scope ->
        started_ms = System.monotonic_time(:millisecond)

        if live_semantic_predecessor?(scope) do
          outcome =
            if Repo.in_transaction?(),
              do: :live,
              else: poll_live_predecessor(&live_semantic_predecessor?/1, scope, started_ms + @live_predecessor_wait_budget_ms, :other_claim)

          log_live_predecessor_wait(scope, outcome, System.monotonic_time(:millisecond) - started_ms, :other_claim)
          outcome
        else
          :none
        end
    end
  end

  defp live_predecessor_scope(opts) do
    with %CodexSession{id: session_id} when is_binary(session_id) <- attr(opts, :codex_session),
         <<_::256>> = digest <- attr(opts, :semantic_turn_digest),
         claim when is_binary(claim) <- attr(opts, :correlation_id) do
      %{codex_session_id: session_id, semantic_turn_digest: digest, claim: claim}
    else
      _no_semantic_turn -> nil
    end
  end

  # The released client resends a request only after the connection that carried
  # it failed: after about 200 ms on a new connection, then about 400 ms later,
  # then over HTTPS for the rest of its session. A native compaction is resent
  # under its own compaction claim, the running request's claim, so it met the
  # immediate refusal whenever the closed socket's cleanup (a 250 ms drain, then
  # the stop and its settlement) was still running: both websocket resends were
  # refused `409 duplicate_turn` and the session moved to HTTPS (findings#206
  # row 206-436, owner forwarding off). The resend policy's `active_predecessor`
  # refusal therefore waits for that request with the same bound and asks the
  # policy once more; a request still running at the bound (its socket's close
  # not seen yet) keeps the refusal.
  defp retry_after_live_claim_holder({:error, %{resend_disposition: :active_predecessor}} = refused, pool, api_key, model, opts) do
    case await_live_claim_holder(opts) do
      :settled -> claim_failed_predecessor_resend(pool, api_key, model, opts)
      _live_or_none -> refused
    end
  end

  defp retry_after_live_claim_holder(result, _pool, _api_key, _model, _opts), do: result

  defp await_live_claim_holder(opts) do
    with %{} = scope <- live_predecessor_scope(opts),
         false <- Repo.in_transaction?(),
         true <- live_semantic_turn?(scope) do
      started_ms = System.monotonic_time(:millisecond)
      outcome = poll_live_predecessor(&live_semantic_turn?/1, scope, started_ms + @live_predecessor_wait_budget_ms, :same_claim)
      log_live_predecessor_wait(scope, outcome, System.monotonic_time(:millisecond) - started_ms, :same_claim)
      outcome
    else
      _no_scope_or_not_live -> :none
    end
  end

  # `[:codex_pooler, :accounting, :websocket_turn_claim, :live_predecessor_wait]`
  # marks the start of a wait, so a test can hold the predecessor's settlement
  # until the claim is waiting on it.
  defp poll_live_predecessor(live?, scope, deadline_ms, claim_relation) do
    :telemetry.execute([:codex_pooler, :accounting, :websocket_turn_claim, :live_predecessor_wait], %{count: 1}, %{claim_relation: claim_relation})
    do_poll_live_predecessor(live?, scope, deadline_ms)
  end

  defp do_poll_live_predecessor(live?, scope, deadline_ms) do
    cond do
      not live?.(scope) ->
        :settled

      System.monotonic_time(:millisecond) >= deadline_ms ->
        :live

      true ->
        Process.sleep(@live_predecessor_poll_ms)
        do_poll_live_predecessor(live?, scope, deadline_ms)
    end
  end

  # Exactly the rows the active-turn index would refuse this turn for, less the
  # running request that carries this very claim.
  defp live_semantic_predecessor?(scope) do
    Repo.exists?(
      from turn in CodexTurn,
        join: request in Request,
        on: request.id == turn.request_id,
        where:
          turn.codex_session_id == ^scope.codex_session_id and turn.semantic_turn_digest == ^scope.semantic_turn_digest and
            turn.status == "in_progress" and request.status in ["accepted", "in_progress"] and request.correlation_id != ^scope.claim
    )
  end

  # The running request of this turn whatever claim it holds, this one included.
  # An open turn behind a terminal request is a settlement in flight too: the
  # request, its attempt and its ledger commit before the turn row, and the
  # resend policy refuses the open turn as a live predecessor until it is
  # written. Waiting only for an open request refused a resend arriving between
  # those commits at once (`409 duplicate_turn`, findings#206 row 206-609).
  defp live_semantic_turn?(scope) do
    Repo.exists?(
      from turn in CodexTurn,
        where:
          turn.codex_session_id == ^scope.codex_session_id and turn.semantic_turn_digest == ^scope.semantic_turn_digest and
            turn.status == "in_progress"
    )
  end

  defp log_live_predecessor_wait(scope, outcome, waited_ms, claim_relation) do
    require Logger

    Logger.info(
      "websocket turn claim met a live predecessor of the same turn " <>
        "codex_session_id=#{scope.codex_session_id} outcome=#{outcome} waited_ms=#{waited_ms} claim_relation=#{claim_relation}"
    )
  end

  # The first insert already met `requests_correlation_id_uq`. Only a claim
  # scoped by a codex session can be resolved against a terminally failed
  # predecessor: the second transaction holds the session lock while it
  # derives the resend claim, so concurrent resends of one frame serialize.
  defp claim_failed_predecessor_resend(pool, api_key, model, opts) do
    case attr(opts, :codex_session) do
      %CodexSession{pool_id: pool_id, api_key_id: api_key_id} = session
      when pool_id == pool.id and api_key_id == api_key.id ->
        do_claim_websocket_turn(pool, api_key, model, opts, session)

      %CodexSession{} ->
        {:error, duplicate_request_error(:authorization_changed)}

      _missing ->
        {:error, duplicate_request_error(:missing_session)}
    end
  end

  defp do_claim_websocket_turn(pool, api_key, model, opts, resend_session) do
    timestamp = now(opts)
    captured_epoch = runtime_revocation_epoch(api_key, opts)
    caller_owned_transaction? = Repo.in_transaction?()
    maybe_test_runtime_authorization_barrier(:claim, :before)

    Repo.transaction(fn ->
      :ok = lock_resend_session(resend_session)
      api_key = authorize_runtime_turn_for_read!(api_key, captured_epoch)
      maybe_test_runtime_authorization_barrier(:claim, :after)
      {correlation_id, client_resend} = resend_claim!(resend_session, pool, api_key, model, opts)

      request =
        %Request{
          pool_id: pool.id,
          api_key_id: api_key.id,
          model_id: model.id,
          requested_model: attr(opts, :requested_model) || model.exposed_model_id,
          endpoint: attr(opts, :endpoint),
          transport: "websocket",
          status: "accepted",
          usage_status: @usage_pending,
          correlation_id: correlation_id,
          client_ip: blank_to_nil(attr(opts, :client_ip)),
          user_agent: blank_to_nil(attr(opts, :user_agent)),
          request_metadata: claim_request_metadata(opts, client_resend),
          admitted_at: timestamp,
          retry_count: 0
        }
        |> Ecto.Changeset.change(ClientRetry.request_attrs(attr(opts, :native_client_retry_witness)))
        |> Repo.insert!()

      RequestLogFacts.record_request_created!(request)
      :ok = bind_direct_cleanup(opts, request)
      link_semantic_execution_retry!(opts, client_resend, request, timestamp)

      case client_resend do
        nil ->
          %{request: request}

        %{} ->
          %{request: request, client_resend: Map.delete(client_resend, :recovery_markers)}
          |> DeadExecutionResendRecovery.put_markers(client_resend)
      end
    end)
    |> unwrap_transaction()
    |> DeadExecutionResendRecovery.emit_after_commit(caller_owned_transaction?)
  rescue
    error in Ecto.ConstraintError ->
      if error.constraint == "requests_correlation_id_uq" do
        {:error, duplicate_request_error(if(resend_session, do: :successor_claimed))}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  # The claim above commits on its own, before the reservation transaction, so
  # a reservation that rolls back -- a database that stopped answering, or a
  # reservation that raised -- used to leave the claim `accepted`: every resend
  # of the request met `409 duplicate_turn` until the six-hour stale-claim
  # recovery, which leaves it failed and still fenced (findings#206 row
  # 206-331). Releasing it restores what a claim written inside the rolled-back
  # reservation would have left: no row. Only the row this claim inserted can be
  # named here, and only while it is nothing but that claim -- still
  # `accepted`, with no ledger entry, attempt, turn, replay entitlement or
  # successor -- so a reservation that committed, or a predecessor the claim
  # chained onto, is never released. Its request-log fact and its own
  # client-retry link go with it (`ON DELETE CASCADE`).
  @spec release_websocket_turn_claim(Request.t()) :: {:ok, :released | :kept} | {:error, term()}
  def release_websocket_turn_claim(%Request{id: request_id}) do
    Repo.transaction(fn ->
      case Repo.one(from request in Request, where: request.id == ^request_id, lock: "FOR UPDATE") do
        %Request{} = request ->
          if unreserved_turn_claim?(request) do
            _deleted = Repo.delete!(request)
            :released
          else
            :kept
          end

        nil ->
          :kept
      end
    end)
  end

  defp unreserved_turn_claim?(%Request{status: "accepted", transport: "websocket", completed_at: nil} = request),
    do: TurnClaimRelease.claim_only?(request)

  defp unreserved_turn_claim?(%Request{}), do: false

  defp link_semantic_execution_retry!(_opts, %{predecessor_request_id: id, predecessor_shape: :partial_http_tool_cut}, request, timestamp),
    do: ClientRetry.insert_link!(%Request{id: id}, request, timestamp)

  defp link_semantic_execution_retry!(opts, %{predecessor_request_id: id}, request, timestamp) do
    case attr(opts, :correlation_id) do
      "codex-turn:" <> _digest ->
        ClientRetry.insert_link!(%Request{id: id}, request, timestamp)

      _payload_claim ->
        :ok
    end
  end

  defp link_semantic_execution_retry!(_opts, nil, _request, _timestamp), do: :ok

  # Runtime writes lock the codex session before `api_keys`. A resend claim that
  # authorized the key first held it while waiting on a session an HTTP
  # reservation already held, which waited on the key in turn. The row is taken
  # without raising so a missing session still resolves the key authorization
  # first; `resend_claim!/5` then re-reads it under the lock this transaction
  # already holds and raises for a missing session exactly as before.
  defp lock_resend_session(nil), do: :ok

  defp lock_resend_session(%CodexSession{id: session_id}) do
    _locked_or_missing =
      Repo.one(from session in CodexSession, where: session.id == ^session_id, lock: "FOR UPDATE")

    :ok
  end

  defp resend_claim!(nil, _pool, _api_key, _model, opts), do: {attr(opts, :correlation_id), nil}

  defp resend_claim!(%CodexSession{} = session, pool, api_key, model, opts) do
    _locked = SessionContinuity.lock_codex_session_for_turn(session)

    scope = %{
      pool_id: pool.id,
      api_key_id: api_key.id,
      model_id: model.id,
      endpoint: attr(opts, :endpoint),
      codex_session_id: session.id,
      native_client_retry_witness: attr(opts, :native_client_retry_witness),
      anchor_present?: attr(opts, :anchor_present?) == true
    }

    case FailedPredecessorResend.resolve(attr(opts, :correlation_id), scope) do
      {:ok,
       %{
         claim: claim,
         predecessor: predecessor,
         predecessor_shape: shape,
         recovery_markers: recovery_markers
       }} ->
        {claim,
         %{
           predecessor_request_id: predecessor.id,
           reason: :failed_predecessor,
           predecessor_shape: shape,
           recovery_markers: recovery_markers
         }}

      {:error, disposition} ->
        Repo.rollback(duplicate_request_error(disposition))
    end
  end

  defp native_turn_resend_claim!(nil, %{correlation_id: correlation_id}),
    do: {correlation_id, nil, nil}

  # This reservation runs inside the caller's transaction, so a uniqueness
  # conflict cannot be rescued and re-resolved in a second transaction the way
  # `claim_websocket_turn/3` does: an aborted transaction cannot read. The
  # predecessor is therefore looked up first, under the codex session lock that
  # serializes concurrent resends of one turn, and only an actual predecessor
  # reaches the resend policy. A turn nobody has recorded keeps its claim and
  # inserts exactly as before, so an unfenceable first request is never taxed
  # with the policy's anchored/entitlement refusals.
  defp native_turn_resend_claim!(%CodexSession{} = session, context) do
    case websocket_compaction_successor(session, context) do
      {claim, %{} = client_resend} ->
        {claim, client_resend, nil}

      nil ->
        case steered_continuation_claim(context) do
          steered when is_binary(steered) ->
            {claim, client_resend} = walk_native_turn_chain(session, %{context | correlation_id: steered}, steered, 0)
            {claim, client_resend, "steered_continuation"}

          nil ->
            {claim, client_resend} = walk_native_turn_chain(session, context, context.correlation_id, 0)
            {claim, client_resend, nil}
        end
    end
  end

  # The released client drains user input steered into a running turn into the
  # same turn, under the same `turn_id`, so such a request derives the turn's
  # bare `codex-turn:` claim although it is a later request of the turn (after a
  # mid-turn compaction the drain comes right after it). A retry of the request
  # holding that claim only appends model output and keeps its recorded progress
  # digest; a request whose digest differs from the one a native HTTP holder
  # recorded therefore cannot be that retry, and is claimed under its own
  # steered claim instead, which its own rebuilt retries derive again
  # (findings#206 row 206-403). The holder may be a websocket opener that
  # recorded its full-history progress, which is how a steer sent over HTTPS
  # after the session fell back from the websocket is told apart (row 206-412).
  # A different digest alone is not enough: a resend of the holder with trimmed
  # history differs too, so the request must be further along the turn than the
  # holder (`NativeTurnProgress.advances?/2`, row 206-423). A holder without a
  # recorded position -- a row from before these releases, or a websocket
  # request whose socket could not know its history -- keeps the bare claim and
  # today's verdict.
  defp steered_continuation_claim(%{correlation_id: claim, opts: opts}) do
    with steered when is_binary(steered) <- attr(opts, :native_http_steered_claim),
         {_pivot, _user_messages} = position <- attr(opts, :native_http_turn_position),
         recorded = claim |> native_turn_predecessor() |> NativeTurnProgress.recorded_position(),
         true <- NativeTurnProgress.advances?(recorded, position) do
      steered
    else
      _not_steered -> nil
    end
  end

  # The released client's HTTPS fallback of a websocket compaction it did not
  # complete (after two refused websocket resends) carries the claim of that
  # compaction, so an ended one is chained exactly as its websocket resend
  # would be: one successor with its own single settlement (findings#206 row
  # 206-330). When it cannot be chained -- the predecessor is still live
  # (row 206-333: the fallback arrives about 1 s after the cut), or any other
  # verdict of the resend policy -- the fallback keeps its own payload-scoped
  # claim and is served as before. Refusing it would fail the user's turn and
  # lose the compaction (measured: three HTTP refusals end the turn `failed`),
  # which costs more than the purchase it would save.
  defp websocket_compaction_successor(session, context) do
    context.opts
    |> attr(:websocket_compaction_claims)
    |> List.wrap()
    |> Enum.find_value(fn claim ->
      case native_turn_predecessor(claim) do
        %Request{transport: "websocket"} -> resolve_websocket_compaction_successor(session, context, claim)
        _none -> nil
      end
    end)
  end

  defp resolve_websocket_compaction_successor(session, context, claim) do
    case FailedPredecessorResend.resolve(claim, native_turn_resend_scope(session, context)) do
      {:ok, resolution} -> {resolution.claim, client_resend(resolution)}
      {:error, _disposition} -> nil
    end
  end

  # Falling open must not abandon the turn's identity. A zero-output predecessor
  # is stepped over by deriving the next claim from it -- the same deterministic
  # derivation the websocket resend chain uses -- so the successor is still
  # named by this turn. Reserving a fresh UUID instead would park the turn's
  # claim on a row that can never be met again and switch the fence off for that
  # turn permanently, letting a later attempt that DOES deliver output be
  # resent and dispatched a second time.
  # At the bound the walk stops deriving, it does not start refusing. Every step
  # it took was a ZERO-OUTPUT predecessor -- `rate_limit_exceeded`, a relayed
  # 4xx, `no_eligible_backend`, a pre-first-event idle timeout -- and those are
  # the states `delivered_provider_output?/1` deliberately serves, which the
  # runbook records as served and a 409 for any of them as a defect. Rolling
  # back here turned the seventeenth consecutive zero-output attempt of one turn
  # into a hard terminal `409` on the default transport with no duplicate spend
  # anywhere to protect, an edge the unbounded pre-chain behaviour did not have
  # (findings#212, row 212-50).
  #
  # Falling open to a fresh id costs this turn its fence -- a LATER attempt that
  # does deliver output can then be resent and dispatched twice -- which is the
  # trade the chain exists to avoid. After sixteen consecutive attempts that
  # bought nothing it is the cheaper of the two, and it is what the missing app
  # secret arm below already does.
  defp walk_native_turn_chain(_session, _context, _claim, depth)
       when depth > @native_turn_chain_depth,
       do: {Ecto.UUID.generate(), nil}

  defp walk_native_turn_chain(session, context, claim, depth) do
    case native_turn_predecessor(claim) do
      nil ->
        {claim, nil}

      %Request{} = predecessor ->
        :ok = retire_forwarded_chain!(predecessor)

        if delivered_provider_output?(predecessor) do
          resolve_native_turn_resend!(session, context, claim)
        else
          step_over_native_turn_predecessor(session, context, claim, predecessor, depth)
        end
    end
  end

  # With owner forwarding on, the owner's client-retry preflight chains a
  # websocket resend onto a request of this turn (`client-retry-v1:`), outside
  # the turn claim this walk follows. When the released client falls back to
  # HTTPS after that successor was cut, the fallback is this turn's next
  # generation: an armed replay of the successor is retired as a newer turn
  # retires it (`RequestReplay.supersede/1`, the request settles `failed 499`
  # with nothing charged), so a later websocket resend cannot redeem it and
  # generate the served turn again, and a successor still running refuses the
  # fallback as a live duplicate (findings#206 row 206-538).
  defp retire_forwarded_chain!(%Request{transport: "websocket"} = predecessor) do
    case ClientRetry.forwarded_chain_state(predecessor) do
      {:armed, tail_request_id} ->
        case RequestReplay.supersede(%{request_id: tail_request_id}) do
          {:ok, _closed_or_noop} -> :ok
          {:error, _reason} -> Repo.rollback(duplicate_request_error(:entitlement_present))
        end

      :live ->
        Repo.rollback(duplicate_request_error(:active_predecessor))

      _none_or_settled ->
        :ok
    end
  end

  defp retire_forwarded_chain!(%Request{}), do: :ok

  defp step_over_native_turn_predecessor(session, context, claim, predecessor, depth) do
    case ClientRetry.deterministic_failed_predecessor_claim(claim, predecessor.id) do
      {:ok, derived} ->
        walk_native_turn_chain(session, context, derived, depth + 1)

      # Without the app secret no claim can be derived; keep today's behaviour
      # rather than refusing a request that has no duplicate.
      {:error, _reason} ->
        {Ecto.UUID.generate(), nil}
    end
  end

  defp resolve_native_turn_resend!(session, context, claim) do
    case FailedPredecessorResend.resolve(claim, native_turn_resend_scope(session, context)) do
      {:ok, resolution} -> {resolution.claim, client_resend(resolution)}
      {:error, disposition} -> Repo.rollback(duplicate_request_error(disposition))
    end
  end

  defp native_turn_resend_scope(session, context) do
    %{pool: pool, api_key: api_key, model: model, opts: opts} = context
    _locked = SessionContinuity.lock_codex_session_for_turn(session)

    %{
      pool_id: pool.id,
      api_key_id: api_key.id,
      model_id: model.id,
      endpoint: context.endpoint,
      codex_session_id: session.id,
      native_client_retry_witness: attr(opts, :native_client_retry_witness),
      native_http_input_count: attr(opts, :native_http_input_count),
      native_http_semantic_turn_key: attr(opts, :native_http_semantic_turn_key),
      native_http_transport: attr(opts, :transport),
      payload: context.payload,
      anchor_present?: attr(opts, :anchor_present?) == true
    }
  end

  defp client_resend(%{predecessor: predecessor, predecessor_shape: shape, recovery_markers: recovery_markers}),
    do: %{predecessor_request_id: predecessor.id, reason: :failed_predecessor, predecessor_shape: shape, recovery_markers: recovery_markers}

  defp native_turn_predecessor(correlation_id) do
    Repo.one(from request in Request, where: request.correlation_id == ^correlation_id)
  end

  # Codes whose failure happened after the relay to this client had begun. A
  # code outside this set failed before the provider produced anything for the
  # turn (a first-event verdict, a refusal, or no dispatch at all), so a resend
  # of it buys nothing twice.
  @post_relay_cut_codes [
    "owner_drained",
    "client_disconnected",
    "upstream_stream_error",
    "stream_idle_timeout",
    "owner_task_exception",
    "dead_execution_recovered"
  ]

  # The fence exists to stop the provider being paid twice for one turn, so it
  # refuses only a resend whose predecessor already delivered provider output
  # for that turn: a completed turn, or a cut that happened mid-relay. Anything
  # else falls open to today's behaviour -- a fresh correlation id and a
  # dispatch -- because there is nothing to protect and a refusal would be a new
  # terminal error on the default transport.
  #
  # `first_visible_output_at` alone cannot carry this: the Pooler marks a turn
  # visible when any downstream-visible event is written, including a relayed
  # error event, so a first-event `server_error` sets it exactly as a real
  # stream does (measured). Pairing it with the cut vocabulary is what separates
  # "output reached the client and was cut" from "the provider refused before
  # producing anything".
  #
  # What this deliberately serves rather than refuses: a predecessor left live
  # by a killed node (`completed_at` stays null until the `*/15` `runtime_cleanup`
  # cron finalizes it), a pre-attempt drain, a pre-first-event idle timeout,
  # `no_eligible_backend`, and every zero-output provider refusal such as
  # `rate_limit_exceeded`, a relayed 4xx, or a retryable first-event verdict.
  defp delivered_provider_output?(%Request{completed_at: nil}), do: false

  defp delivered_provider_output?(%Request{status: "succeeded"}), do: true

  defp delivered_provider_output?(%Request{last_error_code: code, id: request_id})
       when code in @post_relay_cut_codes do
    Repo.exists?(
      from turn in CodexTurn,
        where: turn.request_id == ^request_id and not is_nil(turn.first_visible_output_at)
    )
  end

  defp delivered_provider_output?(%Request{}), do: false

  defp witness_alternates(%ClientRetry.OriginalWitness{alternates: alternates}) when is_list(alternates),
    do: alternates

  defp witness_alternates(_witness), do: []

  defp witness_grown(%ClientRetry.OriginalWitness{grown: grown}) when is_list(grown), do: grown
  defp witness_grown(_witness), do: []

  defp claim_request_metadata(opts, nil),
    do: Metadata.sanitize_metadata(attr(opts, :request_metadata) || %{})

  defp claim_request_metadata(opts, %{predecessor_request_id: predecessor_request_id}) do
    opts
    |> claim_request_metadata(nil)
    |> Map.put("client_resend", %{
      "predecessor_request_id" => predecessor_request_id,
      "reason" => "failed_predecessor"
    })
  end

  defp duplicate_request_error(nil),
    do: Metadata.accounting_error(:duplicate_request, "request was already recorded")

  defp duplicate_request_error(disposition) when is_atom(disposition),
    do: Map.put(duplicate_request_error(nil), :resend_disposition, disposition)

  @spec claim_client_retry_successor(CodexPooler.Access.auth_context(), Model.t(), map(), map()) ::
          {:ok, ClientRetry.SuccessorClaim.t()} | {:error, atom() | map()}
  def claim_client_retry_successor(auth, model, payload, opts),
    do: claim_retry_successor(auth, model, payload, opts, :client_retry)

  @spec claim_compaction_retry_successor(
          CodexPooler.Access.auth_context(),
          Model.t(),
          map(),
          map()
        ) ::
          {:ok, ClientRetry.SuccessorClaim.t()} | {:error, atom() | map()}
  def claim_compaction_retry_successor(auth, model, payload, opts),
    do: claim_retry_successor(auth, model, payload, opts, :native_compaction)

  # One transaction intentionally owns every successor side effect.
  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
  defp claim_retry_successor(
         %{pool: pool, api_key: api_key} = auth,
         %Model{} = model,
         payload,
         %{codex_session: %CodexSession{} = session} = opts,
         retry_policy
       ) do
    captured_epoch = runtime_revocation_epoch(api_key, opts)

    Repo.transaction(fn ->
      session = SessionContinuity.lock_codex_session_for_turn(session)
      api_key = authorize_runtime_turn!(api_key, captured_epoch)
      authorize_client_retry_model!(api_key, model)

      input = %{
        retry_policy: retry_policy,
        full_history?: attr(opts, :full_history?),
        compaction_trigger_bridge?: attr(opts, :compaction_trigger_bridge?),
        endpoint: attr(opts, :endpoint) || "/backend-api/codex/responses",
        requested_model: attr(opts, :requested_model) || model.exposed_model_id,
        runtime_revocation_epoch: captured_epoch,
        semantic_turn_digest: attr(opts, :semantic_turn_digest),
        original_request_claim: attr(opts, :original_request_claim),
        replay_claim_digest: attr(opts, :replay_claim_digest),
        replay_claim_alternates: witness_alternates(attr(opts, :native_client_retry_witness)),
        grown_resend_candidates: witness_grown(attr(opts, :native_client_retry_witness)),
        anchor_present?: retry_anchor(opts, retry_policy),
        after_locks: attr(opts, :after_locks),
        owner_idle_validated?: attr(opts, :owner_idle_validated?) == true,
        owner_lease_token: attr(opts, :owner_lease_token),
        owner_instance_id: attr(opts, :owner_instance_id)
      }

      with {:ok, predecessor} <-
             ClientRetry.lock_eligible_predecessor!(session, api_key, model, input),
           {:ok, correlation_id} <- successor_correlation(predecessor, retry_policy, input) do
        if predecessor.successor do
          reclaim_compaction_successor!(predecessor, opts)
        else
          auth = %{auth | api_key: api_key}
          timestamp = predecessor.db_now
          requested_model = input.requested_model
          pricing = PricingResolution.lookup(model, requested_model, payload, opts, timestamp)
          effective_model = ReservationPolicy.effective_model(model, requested_model, opts)

          policy =
            ReservationPolicy.policy_for_update(
              api_key,
              effective_model,
              nil
            )

          {:ok, estimate} =
            PricingResolution.reservation_estimate(
              payload,
              pricing.snapshot,
              policy,
              attr(opts, :reservation_estimate)
            )

          case ReservationPolicy.enforce_reservation_limits(api_key, policy, estimate) do
            :ok ->
              :ok

            {:error, reason} ->
              Repo.rollback(reason)
          end

          context = %{
            pool: pool,
            api_key: api_key,
            model: model,
            payload: payload,
            requested_model: requested_model,
            endpoint: input.endpoint,
            transport: "websocket",
            correlation_id: correlation_id,
            auth: auth,
            pricing: pricing,
            estimate: estimate,
            # Original witnesses belong to generation zero; a successor must
            # dispatch through its link authority instead.
            opts:
              opts
              |> Map.put(:turn_claim, nil)
              |> Map.delete(:native_client_retry_witness),
            timestamp: timestamp
          }

          request = insert_reserved_request!(context)
          RequestLogFacts.record_request_created!(request)

          reservation =
            request
            |> LedgerEntries.reservation_attrs(auth, api_key, pricing, estimate, timestamp)
            |> LedgerEntries.create_or_get!()

          turn =
            ClientRetry.insert_successor_turn!(
              session,
              request,
              input.semantic_turn_digest,
              timestamp
            )

          maybe_test_client_retry_storage_failure!(opts)
          link = ClientRetry.insert_link!(predecessor.request, request, timestamp)
          dispatch_authority = ClientRetry.dispatch_authority(predecessor.request, request, link)

          %ClientRetry.SuccessorClaim{
            predecessor_request_id: predecessor.request.id,
            request: request,
            codex_turn: turn,
            reservation: reservation,
            pricing_snapshot: pricing.snapshot,
            pricing_status: pricing.status,
            pricing_service_tier: pricing.service_tier,
            estimate: estimate,
            link: link,
            correlation_id: correlation_id,
            dispatch_authority: dispatch_authority
          }
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, claim} -> {:ok, claim}
      {:error, reason} -> {:error, normalize_retry_claim_error(reason)}
    end
  rescue
    error in Ecto.ConstraintError ->
      if error.constraint in [
           "requests_correlation_id_uq",
           "request_client_retry_links_predecessor_request_id_uq"
         ],
         do: {:error, :successor_claimed},
         else: reraise(error, __STACKTRACE__)
  end

  defp claim_retry_successor(_auth, _model, _payload, _opts, _retry_policy),
    do: {:error, :authorization_changed}

  defp reclaim_compaction_successor!(predecessor, opts) do
    %{request: request, turn: turn, reservation: reservation, link: link} = predecessor.successor
    incoming = Metadata.sanitize_metadata(attr(opts, :request_metadata) || %{})
    old_owner = request.request_metadata["websocket_owner_forwarding"]
    new_owner = incoming["websocket_owner_forwarding"]

    unless changed_cleanup_owner?(old_owner, new_owner, opts),
      do: Repo.rollback(:successor_claimed)

    metadata =
      request.request_metadata
      |> Map.merge(Map.take(incoming, ["websocket_owner_forwarding", "request_id"]))

    request = request |> Ecto.Changeset.change(request_metadata: metadata) |> Repo.update!()
    :ok = bind_direct_cleanup(opts, request)
    estimate_metadata = request.request_metadata["reservation"]

    estimate =
      Map.new(
        [
          :input_tokens,
          :cached_input_tokens,
          :output_tokens,
          :reasoning_tokens,
          :total_tokens,
          :strategy
        ],
        &{&1, estimate_metadata[Atom.to_string(&1)]}
      )
      |> Map.put(
        :estimated_cost_micros,
        case estimate_metadata["estimated_cost_micros"] do
          nil -> nil
          value -> Decimal.new(value)
        end
      )

    %ClientRetry.SuccessorClaim{
      predecessor_request_id: predecessor.request.id,
      request: request,
      codex_turn: turn,
      reservation: reservation,
      pricing_snapshot:
        reservation.pricing_snapshot_id &&
          Repo.get!(CodexPooler.Catalog.PricingSnapshot, reservation.pricing_snapshot_id),
      pricing_status: reservation.details["pricing_status"],
      pricing_service_tier: reservation.details["service_tier"],
      estimate: estimate,
      link: link,
      correlation_id: request.correlation_id,
      dispatch_authority: ClientRetry.dispatch_authority(predecessor.request, request, link)
    }
  end

  defp changed_cleanup_owner?(
         %{"owner_instance_id" => old_owner, "downstream_epoch" => old_epoch},
         %{"owner_instance_id" => new_owner, "downstream_epoch" => new_epoch},
         opts
       )
       when is_binary(old_owner) and is_integer(old_epoch) and old_epoch > 0 and
              is_binary(new_owner) and is_integer(new_epoch) and new_epoch > 0 do
    new_owner == attr(opts, :owner_instance_id) and
      (old_owner != new_owner or old_epoch != new_epoch)
  end

  defp changed_cleanup_owner?(_old_owner, _new_owner, _opts), do: false

  defp normalize_retry_claim_error(%Ecto.Changeset{}), do: :successor_claimed

  # A key policy refusal is the successor's own refusal, answered and recorded
  # as the ordinary reservation answers it, never a lost claim (findings#206
  # row 206-428).
  defp normalize_retry_claim_error(%{code: code} = reason)
       when code in [:api_key_concurrency_limit_exceeded, :api_key_policy_limit_exceeded],
       do: reason

  defp normalize_retry_claim_error(reason) when is_map(reason), do: :authorization_changed
  defp normalize_retry_claim_error(reason), do: reason

  defp retry_anchor(opts, :native_compaction), do: Map.get(opts, :anchor_present?)
  defp retry_anchor(opts, _policy), do: attr(opts, :anchor_present?) == true

  defp successor_correlation(predecessor, :native_compaction, input),
    do:
      ClientRetry.deterministic_compaction_successor_claim(
        predecessor.request,
        predecessor.turn,
        input.replay_claim_digest
      )

  # The resend chains onto the original request or onto the last of its
  # client-retry successors (findings#206 row 206-525); either way the claim is
  # named by the original request and the node it chains onto.
  defp successor_correlation(predecessor, _policy, _input),
    do: ClientRetry.deterministic_successor_claim(predecessor.original, predecessor.request.id)

  defp authorize_client_retry_model!(api_key, %Model{status: "active"} = model) do
    with {:ok, policy} <- Access.normalize_api_key_policy(api_key),
         {:ok, _policy} <-
           Access.authorize_api_key_policy(policy, %{model_identifier: model.exposed_model_id}) do
      :ok
    else
      _error -> Repo.rollback(:authorization_changed)
    end
  end

  defp authorize_client_retry_model!(_api_key, _model),
    do: Repo.rollback(:authorization_changed)

  if Mix.env() == :test do
    defp maybe_test_client_retry_storage_failure!(%{force_client_retry_storage_failure: true}),
      do: Repo.rollback(:storage_failure)

    defp maybe_test_client_retry_storage_failure!(_opts), do: :ok
  else
    defp maybe_test_client_retry_storage_failure!(_opts), do: :ok
  end

  @spec reserve_for_model(CodexPooler.Access.auth_context(), Model.t(), map(), map()) ::
          {:ok, map()} | {:error, Metadata.accounting_error()}
  def reserve_for_model(%{pool: pool, api_key: api_key} = auth, %Model{} = model, payload, opts) do
    timestamp = now(opts)
    requested_model = requested_model(payload, opts)
    endpoint = attr(opts, :endpoint) || "/backend-api/codex/responses"
    transport = attr(opts, :transport) || transport_from_payload(payload)
    correlation_id = attr(opts, :correlation_id) || Ecto.UUID.generate()
    pricing = PricingResolution.lookup(model, requested_model, payload, opts, timestamp)
    effective_model = ReservationPolicy.effective_model(model, requested_model, opts)
    captured_epoch = runtime_revocation_epoch(api_key, opts)

    if ClientRetry.reserved_successor_claim?(correlation_id) do
      {:error, duplicate_request_error(nil)}
    else
      do_reserve_for_model(
        auth,
        pool,
        api_key,
        model,
        payload,
        opts,
        timestamp,
        requested_model,
        endpoint,
        transport,
        correlation_id,
        pricing,
        effective_model,
        captured_epoch,
        native_turn_resend_session(opts, transport, correlation_id)
      )
    end
  end

  # A native Codex HTTP turn reserves under the same turn claim its websocket
  # twin uses, so a resend of one turn meets `requests_correlation_id_uq`
  # instead of buying a second upstream dispatch (findings#212). Only that shape
  # takes the resend path; a generated correlation id, a websocket reservation
  # (which already claimed its row in `claim_websocket_turn/3` and only updates
  # it here), and a request without a codex session are untouched.
  defp native_turn_resend_session(opts, transport, correlation_id) do
    with true <- transport != "websocket",
         true <- is_nil(attr(opts, :turn_claim)),
         true <- native_turn_claim?(correlation_id),
         %CodexSession{} = session <- attr(opts, :codex_session) do
      session
    else
      _not_a_native_http_turn -> nil
    end
  end

  # Every claim shape the native HTTP resolver can produce: the bare turn claim
  # that names a turn's opening request, and the payload-scoped `codex-request:`
  # claims that name one later request of it -- a tool-result continuation, the
  # resume after a compaction, the compaction itself, and a `prewarm`/`memory`
  # request that shares the turn id. Those four are one prefix on purpose: they
  # differ by HMAC domain, not by name, so this predicate keeps routing all of
  # them into the resend path without enumerating them (findings#212, 212-54).
  defp native_turn_claim?(correlation_id) when is_binary(correlation_id),
    do: WebsocketTurnIdentity.native_claim?(correlation_id)

  defp native_turn_claim?(_correlation_id), do: false

  # Existing reservation inputs stay explicit at the private handoff.
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp do_reserve_for_model(
         auth,
         pool,
         api_key,
         model,
         payload,
         opts,
         timestamp,
         requested_model,
         endpoint,
         transport,
         correlation_id,
         pricing,
         effective_model,
         captured_epoch,
         resend_session
       ) do
    caller_owned_transaction? = Repo.in_transaction?()

    Repo.transaction(fn ->
      :ok = lock_resend_session(resend_session)
      api_key = authorize_runtime_turn!(api_key, captured_epoch)
      auth = Map.put(auth, :api_key, api_key)
      maybe_test_runtime_authorization_barrier(:reserve, :after)

      {correlation_id, client_resend, claim_arm} =
        native_turn_resend_claim!(resend_session, %{
          correlation_id: correlation_id,
          pool: pool,
          api_key: api_key,
          model: model,
          endpoint: endpoint,
          opts: opts,
          payload: payload
        })

      policy =
        ReservationPolicy.policy_for_update(
          api_key,
          effective_model
        )

      {:ok, estimate} =
        PricingResolution.reservation_estimate(
          payload,
          pricing.snapshot,
          policy,
          attr(opts, :reservation_estimate)
        )

      case ReservationPolicy.enforce_reservation_limits(api_key, policy, estimate) do
        :ok -> :ok
        {:error, error} -> Repo.rollback(error)
      end

      request_context = %{
        pool: pool,
        api_key: api_key,
        model: model,
        payload: payload,
        requested_model: requested_model,
        endpoint: endpoint,
        transport: transport,
        correlation_id: correlation_id,
        client_resend: client_resend,
        native_http_claim_arm: claim_arm,
        auth: auth,
        pricing: pricing,
        estimate: estimate,
        opts: opts,
        timestamp: timestamp
      }

      request = insert_reserved_request!(request_context)
      RequestLogFacts.record_request_created!(request)
      # An HTTPS resend admitted under the turn's semantic claim is linked to its
      # predecessor like the websocket claim's (findings#232 row 232-231).
      link_semantic_execution_retry!(opts, client_resend, request, timestamp)

      reservation =
        request
        |> LedgerEntries.reservation_attrs(auth, api_key, pricing, estimate, timestamp)
        |> LedgerEntries.create_or_get!()

      %{
        request: request,
        pricing_snapshot: pricing.snapshot,
        pricing_status: pricing.status,
        pricing_service_tier: pricing.service_tier,
        reservation: reservation,
        estimate: estimate
      }
      |> DeadExecutionResendRecovery.put_markers(client_resend)
    end)
    |> unwrap_transaction()
    |> DeadExecutionResendRecovery.emit_after_commit(caller_owned_transaction?)
  end

  @spec record_denied_request(CodexPooler.Access.auth_context(), term(), map()) ::
          {:ok, map()} | {:error, Metadata.accounting_error()}
  def record_denied_request(%{pool: pool, api_key: api_key} = auth, model_or_id, opts) do
    timestamp = now(opts)
    model = normalize_model(model_or_id)
    requested_model = attr(opts, :requested_model)
    endpoint = attr(opts, :endpoint) || "/backend-api/codex/responses"
    transport = attr(opts, :transport) || "http_json"
    reason = attr(opts, :last_error_code) || "policy_denied"

    Repo.transaction(fn ->
      # A deletion after authentication clears attribution, not rejection history.
      # Hold a surviving key through insertion so deletion cannot race the foreign key.
      persisted_api_key = Access.lock_api_key_for_read(api_key.id)

      attrs =
        denied_request_attrs(%{
          auth: auth,
          pool: pool,
          api_key_id: persisted_api_key && persisted_api_key.id,
          model: model,
          requested_model: requested_model,
          endpoint: endpoint,
          transport: transport,
          reason: reason,
          timestamp: timestamp,
          opts: opts
        })

      request = insert_or_update_claimed_request!(attrs, attr(opts, :turn_claim))
      RequestLogFacts.record_request_created!(request)

      %{request: request}
    end)
    |> unwrap_transaction()
  end

  defp denied_request_attrs(context) do
    %{
      pool_id: context.pool.id,
      api_key_id: context.api_key_id,
      model_id: context.model && context.model.id,
      requested_model:
        blank_to_nil(context.requested_model) ||
          (context.model && context.model.exposed_model_id) || context.endpoint,
      endpoint: context.endpoint,
      transport: context.transport,
      status: "rejected",
      usage_status: @usage_not_applicable,
      correlation_id: attr(context.opts, :correlation_id) || Ecto.UUID.generate(),
      client_ip: blank_to_nil(attr(context.opts, :client_ip)),
      user_agent: blank_to_nil(attr(context.opts, :user_agent)),
      request_metadata: denied_request_metadata(context.auth, context.opts),
      admitted_at: context.timestamp,
      completed_at: context.timestamp,
      response_status_code: attr(context.opts, :response_status_code),
      retry_count: 0,
      last_error_code: to_string(context.reason)
    }
  end

  # A refusal of a claimed turn before anything reached the provider records the
  # refusal on the claimed row and gives the claim up (findings#206 row 206-420).
  defp insert_or_update_claimed_request!(attrs, %Request{} = turn_claim),
    do: update_claimed_request!(turn_claim, attrs, :reservation_refused)

  # A refusal without a claim of its own records history; it never takes a
  # claim away from the row that holds it. Its correlation id is taken already
  # when an earlier refusal of the same socket recorded the websocket handshake
  # request id every frame of that socket shares (a frame that names no Codex turn, or one refused before its
  # turn was claimed), or when an earlier row holds the request claim. The
  # conflict used to escape as `Ecto.ConstraintError` and the client got `500
  # websocket_response_task_failed` instead of the refusal (findings#206 row
  # 206-361); the refusal is recorded under a fresh correlation id instead,
  # like every unclaimed admission, and the earlier row keeps the claim.
  defp insert_or_update_claimed_request!(attrs, nil) do
    case insert_denied_request(attrs) do
      {:ok, %Request{} = request} ->
        request

      {:error, %Ecto.Changeset{}} ->
        %Request{}
        |> Ecto.Changeset.change(Map.put(attrs, :correlation_id, Ecto.UUID.generate()))
        |> Repo.insert!()
    end
  end

  # The savepoint keeps the surrounding transaction usable after the unique
  # conflict, so the refusal can still be recorded in it.
  defp insert_denied_request(attrs) do
    %Request{}
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.unique_constraint(:correlation_id, name: :requests_correlation_id_uq)
    |> Repo.insert(mode: :savepoint)
  end

  defp update_claimed_request!(%Request{id: request_id}, attrs, release_reason \\ nil) do
    request =
      Repo.one!(
        from request in Request,
          where: request.id == ^request_id,
          lock: "FOR UPDATE"
      )

    if request.status == "accepted" do
      # The claimed row already owns its durable claim and resend attribution:
      # a resend admitted under a derived claim keeps both rather than meeting
      # the predecessor's claim again at reservation.
      changes =
        attrs
        |> Map.drop([:admitted_at, :correlation_id])
        |> preserve_client_resend_metadata(request)

      case release_reason do
        nil -> request |> Ecto.Changeset.change(changes) |> Repo.update!()
        reason -> TurnClaimRelease.close!(request, changes, reason)
      end
    else
      Repo.rollback(Metadata.accounting_error(:request_already_finalized, "request was already finalized"))
    end
  end

  defp preserve_client_resend_metadata(
         %{request_metadata: metadata} = attrs,
         %Request{request_metadata: %{"client_resend" => client_resend}}
       )
       when is_map(metadata) and is_map(client_resend),
       do: %{attrs | request_metadata: Map.put(metadata, "client_resend", client_resend)}

  defp preserve_client_resend_metadata(attrs, _request), do: attrs

  defp insert_reserved_request!(context) do
    request_metadata =
      context.auth
      |> reserve_metadata(context.pricing, context.estimate, context.opts)
      |> put_client_resend_metadata(Map.get(context, :client_resend))
      |> put_native_http_claim_arm(Map.get(context, :native_http_claim_arm))

    settings_snapshot =
      PricingResolution.request_settings_snapshot(
        context.payload,
        request_metadata,
        context.pricing
      )

    attrs =
      %{
        pool_id: context.pool.id,
        api_key_id: context.api_key.id,
        model_id: context.model.id,
        requested_model: context.requested_model,
        endpoint: context.endpoint,
        transport: context.transport,
        status: "in_progress",
        usage_status: @usage_pending,
        correlation_id: context.correlation_id,
        client_ip: blank_to_nil(attr(context.opts, :client_ip)),
        user_agent: blank_to_nil(attr(context.opts, :user_agent)),
        request_metadata: request_metadata,
        reasoning_effort: settings_snapshot.reasoning_effort,
        requested_service_tier: settings_snapshot.requested_service_tier,
        actual_service_tier: settings_snapshot.actual_service_tier,
        service_tier: settings_snapshot.service_tier,
        admitted_at: context.timestamp
      }
      |> Map.merge(ClientRetry.request_attrs(attr(context.opts, :native_client_retry_witness)))

    request =
      case attr(context.opts, :turn_claim) do
        %Request{} = turn_claim ->
          update_claimed_request!(turn_claim, attrs)

        nil ->
          request =
            %Request{}
            |> Ecto.Changeset.change(attrs)
            |> Repo.insert!()

          request
      end

    :ok = bind_direct_cleanup(context.opts, request)
    request
  end

  defp put_native_http_claim_arm(metadata, nil), do: metadata
  defp put_native_http_claim_arm(metadata, arm) when is_binary(arm), do: Map.put(metadata, "native_http_claim_arm", arm)

  defp put_client_resend_metadata(metadata, nil), do: metadata

  defp put_client_resend_metadata(metadata, %{predecessor_request_id: predecessor_request_id}) do
    Map.put(metadata, "client_resend", %{
      "predecessor_request_id" => predecessor_request_id,
      "reason" => "failed_predecessor"
    })
  end

  defp bind_direct_cleanup(opts, request) do
    case attr(opts, :direct_cleanup_bind) do
      callback when is_function(callback, 1) -> callback.(request)
      nil -> :ok
    end
  end

  defp reserve_metadata(auth, pricing, estimate, opts) do
    opts_metadata = attr(opts, :request_metadata) || %{}

    opts_metadata
    |> Metadata.sanitize_metadata()
    |> Map.merge(%{
      "pricing" => PricingResolution.metadata(pricing),
      "reservation" => %{
        "input_tokens" => estimate.input_tokens,
        "cached_input_tokens" => estimate.cached_input_tokens,
        "output_tokens" => estimate.output_tokens,
        "reasoning_tokens" => estimate.reasoning_tokens,
        "total_tokens" => estimate.total_tokens,
        "estimated_cost_micros" => decimal_string_or_nil(estimate.estimated_cost_micros),
        "strategy" => estimate.strategy
      },
      "api_key" => %{"id" => auth.api_key.id, "prefix" => auth.api_key.key_prefix}
    })
  end

  defp denied_request_metadata(auth, opts) do
    opts_metadata = attr(opts, :request_metadata) || %{}

    opts_metadata
    |> Metadata.sanitize_metadata()
    |> Map.merge(%{"api_key" => %{"id" => auth.api_key.id, "prefix" => auth.api_key.key_prefix}})
  end

  defp requested_model(payload, opts), do: attr(opts, :requested_model) || attr(payload, :model)

  # Window limits are checked against usage summed over the whole key, while
  # only the effective policy binding row is locked, so two same-key requests
  # that resolve to different bindings (a model binding and the default one)
  # need a key-wide mutex of their own. `authorize_api_key_runtime_turn/2`
  # supplies it as an advisory lock and reads the key under the reader lock, so
  # the mutex covers this transaction's whole write set without making every
  # `api_keys` reader on the key wait for it to commit.
  defp authorize_runtime_turn!(api_key, captured_epoch) do
    case Access.authorize_api_key_runtime_turn(api_key, captured_epoch) do
      {:ok, %{api_key: authorized_api_key}} -> authorized_api_key
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A websocket claim writes no ledger entry and checks no window limit; the
  # session lock and `requests_correlation_id_uq` fence concurrent claims, so it
  # takes the reader lock and never writes the key row afterwards.
  defp authorize_runtime_turn_for_read!(api_key, captured_epoch) do
    case Access.authorize_api_key_runtime_turn_for_read(api_key, captured_epoch) do
      {:ok, %{api_key: authorized_api_key}} -> authorized_api_key
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp runtime_revocation_epoch(api_key, opts) do
    case attr(opts, :runtime_revocation_epoch) do
      epoch when is_integer(epoch) and epoch >= 0 -> epoch
      _value -> api_key.runtime_revocation_epoch
    end
  end

  if Mix.env() == :test do
    defp maybe_test_runtime_authorization_barrier(operation, phase) do
      case Process.get({__MODULE__, :runtime_authorization_barrier}) do
        {owner_pid, ref, {^operation, ^phase}} when is_pid(owner_pid) ->
          send(owner_pid, {:runtime_authorization_barrier, ref, operation, phase, self()})

          receive do
            {:runtime_authorization_release, ^ref} -> :ok
          end

        _value ->
          :ok
      end
    end
  else
    defp maybe_test_runtime_authorization_barrier(_operation, _phase), do: :ok
  end

  defp transport_from_payload(payload) do
    if attr(payload, :stream), do: "http_sse", else: "http_json"
  end

  defp normalize_model(%Model{} = model), do: model
  defp normalize_model(id) when is_binary(id), do: Repo.get(Model, id)
  defp normalize_model(_id), do: nil

  defp attr(map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp now(opts),
    do:
      (attr(opts, :now) || DateTime.utc_now())
      |> DateTime.truncate(:microsecond)

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)
  defp decimal_string_or_nil(nil), do: nil
  defp decimal_string_or_nil(%Decimal{} = value), do: Decimal.to_string(value)
  defp decimal_string_or_nil(value), do: to_string(value)
  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, value}), do: {:error, value}
end
