defmodule CodexPooler.Accounting.RequestLifecycle do
  @moduledoc """
  Request admission, attempt settlement, and ledger lifecycle APIs.

  The context stores metadata-only request information. Caller payloads may be
  used for token estimates, but raw prompt/output bodies are never persisted.
  """

  import Ecto.Query

  alias CodexPooler.Accounting.{
    Attempt,
    ClientRetry,
    LedgerEntry,
    Metadata,
    PricingResolution,
    Request,
    RequestLogFacts,
    RequestReplayEntitlement,
    Rollups
  }

  alias CodexPooler.Accounting.RequestLifecycle.{
    IdentitySnapshot,
    LedgerEntries,
    Recovery,
    ReferenceLocks,
    Reservation
  }

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Events
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @usage_pending "usage_pending"
  @usage_known "usage_known"
  @usage_unknown "usage_unknown"
  @usage_not_applicable "not_applicable"
  @dispatchable_request_statuses ~w(accepted in_progress)
  @retryable_attempt_statuses ~w(queued in_progress)
  @type auth :: CodexPooler.Access.auth_context()
  @type model_ref :: Model.t() | Ecto.UUID.t() | String.t() | nil
  @type accounting_error :: Metadata.accounting_error()
  @type request_result_row :: %{required(:request) => Request.t(), optional(atom()) => term()}
  @type request_result :: {:ok, request_result_row()} | {:error, accounting_error()}
  @type finalization_disposition :: :inserted | :replaced | :reused

  @type internal_request_result_row :: %{
          required(:request) => Request.t(),
          required(:finalization_disposition) => finalization_disposition(),
          optional(atom()) => term()
        }

  @type internal_request_result ::
          {:ok, internal_request_result_row()} | {:error, accounting_error()}

  @spec reserve(auth(), model_ref(), map(), map()) :: request_result()
  def reserve(auth, model_or_id, payload, opts \\ %{})

  # Reason: public boundary accepts multiple model lookup outcomes.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def reserve(%{pool: _pool, api_key: _api_key} = auth, model_or_id, payload, opts)
      when is_map(payload) do
    case normalize_model(model_or_id) do
      %Model{} = model ->
        auth
        |> Reservation.reserve_for_model(model, payload, opts)
        |> tap_request_log_event("request_reserved")

      nil ->
        {:error, Metadata.accounting_error(:model_not_found, "model was not found")}

      {:error, _reason} = error ->
        error
    end
  end

  def reserve(_auth, _model_or_id, _payload, _opts),
    do:
      {:error,
       Metadata.accounting_error(:invalid_request, "authenticated pool and api key are required")}

  @spec claim_websocket_turn(auth(), model_ref(), map()) :: request_result()
  def claim_websocket_turn(%{pool: _pool, api_key: _api_key} = auth, model_or_id, opts) do
    case normalize_model(model_or_id) do
      %Model{} = model -> Reservation.claim_websocket_turn(auth, model, opts)
      nil -> {:error, Metadata.accounting_error(:model_not_found, "model was not found")}
      {:error, _reason} = error -> error
    end
  end

  def claim_websocket_turn(_auth, _model_or_id, _opts),
    do:
      {:error,
       Metadata.accounting_error(:invalid_request, "authenticated pool and api key are required")}

  @spec claim_client_retry_successor(auth(), model_ref(), map(), map()) ::
          {:ok, CodexPooler.Accounting.ClientRetry.SuccessorClaim.t()} | {:error, atom() | map()}
  def claim_client_retry_successor(
        %{pool: _pool, api_key: _api_key} = auth,
        model_or_id,
        payload,
        opts
      )
      when is_map(payload) and is_map(opts) do
    case normalize_model(model_or_id) do
      %Model{} = model -> Reservation.claim_client_retry_successor(auth, model, payload, opts)
      nil -> {:error, :authorization_changed}
      {:error, _reason} -> {:error, :authorization_changed}
    end
  end

  def claim_client_retry_successor(_auth, _model_or_id, _payload, _opts),
    do: {:error, :authorization_changed}

  @spec record_denied_request(auth(), model_ref(), map()) :: request_result()
  def record_denied_request(auth, model_or_id, opts \\ %{})

  # Reason: denied requests still need complete metadata normalization.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def record_denied_request(%{pool: _pool, api_key: _api_key} = auth, model_or_id, opts) do
    Reservation.record_denied_request(auth, model_or_id, opts)
    |> tap_request_log_event("request_rejected")
  end

  def record_denied_request(_auth, _model_or_id, _opts),
    do:
      {:error,
       Metadata.accounting_error(:invalid_request, "authenticated pool and api key are required")}

  @spec recover_stale_reservations(DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def recover_stale_reservations(now \\ DateTime.utc_now(), opts \\ []) do
    Recovery.recover_stale_reservations(DateTime.truncate(now, :microsecond), opts)
  end

  @spec create_attempt(Request.t(), PoolUpstreamAssignment.t(), map()) ::
          {:ok, Attempt.t()} | {:error, Ecto.Changeset.t() | accounting_error()}
  def create_attempt(%Request{} = request, %PoolUpstreamAssignment{} = assignment, attrs \\ %{}) do
    timestamp = now(attrs)

    Repo.transaction(fn ->
      request =
        Repo.one!(
          from locked_request in Request,
            where: locked_request.id == ^request.id,
            lock: "FOR UPDATE"
        )

      ensure_request_dispatchable!(request)
      ensure_no_request_replay!(request.id)
      insert_attempt!(request, assignment, attrs, timestamp)
    end)
    |> unwrap_transaction()
  end

  @spec create_client_retry_dispatch_attempt(
          Request.t(),
          PoolUpstreamAssignment.t(),
          ClientRetry.DispatchAuthority.t(),
          map()
        ) :: {:ok, Attempt.t()} | {:error, Ecto.Changeset.t() | accounting_error()}
  def create_client_retry_dispatch_attempt(request, assignment, authority, attrs \\ %{})

  def create_client_retry_dispatch_attempt(
        %Request{} = request,
        %PoolUpstreamAssignment{} = assignment,
        %ClientRetry.DispatchAuthority{} = authority,
        attrs
      ) do
    timestamp = now(attrs)

    Repo.transaction(fn ->
      request =
        Repo.one!(
          from locked_request in Request,
            where: locked_request.id == ^request.id,
            lock: "FOR UPDATE"
        )

      ensure_request_dispatchable!(request)

      case ClientRetry.validate_dispatch_authority(request, authority) do
        :ok ->
          :ok

        {:error, :invalid_client_retry_dispatch_authority} ->
          Repo.rollback(
            Metadata.accounting_error(
              :invalid_client_retry_dispatch_authority,
              "client retry dispatch authority is invalid"
            )
          )
      end

      ensure_no_request_replay!(request.id)

      if Repo.exists?(from attempt in Attempt, where: attempt.request_id == ^request.id) do
        Repo.rollback(
          Metadata.accounting_error(
            :client_retry_dispatch_claimed,
            "client retry dispatch attempt was already claimed"
          )
        )
      end

      insert_attempt!(request, assignment, Map.put(attrs, :replay_generation, 0), timestamp)
    end)
    |> unwrap_transaction()
  end

  def create_client_retry_dispatch_attempt(_request, _assignment, _authority, _attrs),
    do:
      {:error,
       Metadata.accounting_error(
         :invalid_client_retry_dispatch_authority,
         "client retry dispatch authority is invalid"
       )}

  @spec record_retryable_attempt_failure(Attempt.t(), map()) ::
          {:ok, Attempt.t()} | {:error, Ecto.Changeset.t() | accounting_error()}
  @doc """
  Records the upstream transport an attempt actually used when it differs from
  the request's downstream transport (an HTTP turn bridged over an upstream
  websocket). The request keeps the downstream protocol.
  """
  @spec mark_attempt_upstream_transport(Attempt.t(), String.t()) ::
          {:ok, Attempt.t()} | {:error, Ecto.Changeset.t()}
  def mark_attempt_upstream_transport(%Attempt{} = attempt, transport)
      when is_binary(transport) do
    attempt
    |> Ecto.Changeset.change(%{transport: transport})
    |> Repo.update()
  end

  def record_retryable_attempt_failure(%Attempt{} = attempt, attrs \\ %{}) do
    timestamp = now(attrs)

    Repo.transaction(fn ->
      request_snapshot = Repo.get!(Request, attempt.request_id)
      :ok = lock_replay_prefix(request_snapshot)

      request =
        Repo.one!(
          from locked_request in Request,
            where: locked_request.id == ^attempt.request_id,
            lock: "FOR UPDATE"
        )

      ensure_request_dispatchable!(request)

      attempt =
        Repo.one!(
          from locked_attempt in Attempt,
            where: locked_attempt.id == ^attempt.id,
            lock: "FOR UPDATE"
        )

      replay_entitlement =
        Repo.one(
          from replay in RequestReplayEntitlement,
            where: replay.request_id == ^request.id,
            lock: "FOR UPDATE"
        )

      if replay_finalization_authority(attempt, replay_entitlement, attrs) == :stale_generation do
        %{
          request: Repo.reload!(request),
          attempt: Repo.reload!(attempt),
          finalization_disposition: :reused,
          stale_generation?: true
        }
      else
        ensure_attempt_retryable!(attempt)
        run_before_finalize!(attrs)
        persist_retryable_attempt_failure(attempt, attrs, timestamp)
      end
    end)
    |> unwrap_transaction()
  end

  defp persist_retryable_attempt_failure(attempt, attrs, timestamp) do
    attempt
    |> Ecto.Changeset.change(%{
      status: Map.get(attrs, :attempt_status, "retryable_failed"),
      completed_at: timestamp,
      upstream_status_code: Map.get(attrs, :response_status_code),
      retryable: true,
      network_error_code: blank_to_nil(Map.get(attrs, :last_error_code)),
      error_message: blank_to_nil(Map.get(attrs, :error_message)),
      latency_ms: Map.get(attrs, :latency_ms),
      usage_status: Map.get(attrs, :usage_status, @usage_unknown),
      response_metadata: Metadata.sanitize_metadata(Map.get(attrs, :attempt_metadata, %{}))
    })
    |> Repo.update()
    |> case do
      {:ok, attempt} ->
        RequestLogFacts.record_attempt_written!(attempt)
        attempt

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  @doc false
  @spec with_current_replay_generation(Request.t(), Attempt.t(), (-> result)) ::
          {:ok, result} | {:error, :stale_generation}
        when result: term()
  def with_current_replay_generation(%Request{} = request, %Attempt{} = attempt, callback)
      when is_function(callback, 0) do
    Repo.transaction(fn ->
      request = Repo.get!(Request, request.id)

      {_request, attempt, _reservation, _settlement, entitlement} =
        lock_finalization_rows(request, attempt)

      if replay_finalization_authority(attempt, entitlement, %{}) == :stale_generation do
        Repo.rollback(:stale_generation)
      else
        callback.()
      end
    end)
    |> unwrap_transaction()
  end

  defp ensure_request_dispatchable!(%Request{status: status, completed_at: nil})
       when status in @dispatchable_request_statuses,
       do: :ok

  defp ensure_request_dispatchable!(%Request{}) do
    Repo.rollback(
      Metadata.accounting_error(
        :request_already_finalized,
        "request lifecycle completed before another upstream attempt could start"
      )
    )
  end

  defp ensure_no_request_replay!(request_id) do
    if Repo.exists?(
         from replay in RequestReplayEntitlement, where: replay.request_id == ^request_id
       ) do
      Repo.rollback(
        Metadata.accounting_error(
          :request_replay_required,
          "request replay attempt requires one-shot replay authorization"
        )
      )
    end

    :ok
  end

  defp ensure_attempt_retryable!(%Attempt{status: status, completed_at: nil})
       when status in @retryable_attempt_statuses,
       do: :ok

  defp ensure_attempt_retryable!(%Attempt{}) do
    Repo.rollback(
      Metadata.accounting_error(
        :attempt_already_finalized,
        "upstream attempt completed before retryable failure could be recorded"
      )
    )
  end

  @spec finalize_reserved_request_failure(Request.t(), map()) :: request_result()
  def finalize_reserved_request_failure(%Request{} = request, attrs \\ %{}) do
    timestamp = now(attrs)
    request_status = Map.get(attrs, :request_status, Map.get(attrs, :status, "failed"))
    last_error_code = blank_to_nil(Map.get(attrs, :last_error_code))
    usage_status = Map.get(attrs, :usage_status, @usage_not_applicable)

    Repo.transaction(fn ->
      request =
        Repo.one!(
          from locked_request in Request,
            where: locked_request.id == ^request.id,
            lock: "FOR UPDATE"
        )

      request =
        request
        |> Ecto.Changeset.change(%{
          status: request_status,
          usage_status: usage_status,
          completed_at: timestamp,
          response_status_code: Map.get(attrs, :response_status_code),
          last_error_code: last_error_code
        })
        |> Repo.update!()

      reservation =
        Repo.get_by!(
          LedgerEntry,
          source_event_id: LedgerEntries.reservation_source_event_id(request.id)
        )

      release =
        request
        |> LedgerEntries.reservation_failure_release_attrs(
          reservation,
          usage_status,
          last_error_code,
          timestamp
        )
        |> LedgerEntries.create_or_get!()

      %{request: request, attempt: nil, release: release}
    end)
    |> unwrap_transaction()
    |> tap_request_finalized_events_unless_stale()
  end

  defp tap_request_finalized_events_unless_stale({:ok, %{stale_generation?: true}} = result),
    do: result

  defp tap_request_finalized_events_unless_stale(result), do: tap_request_finalized_events(result)

  @spec finalize_request(Request.t(), Attempt.t(), map()) :: request_result()
  def finalize_request(%Request{} = request, %Attempt{} = attempt, attrs \\ %{}) do
    request
    |> finalize_request_with_disposition(attempt, attrs)
    |> strip_finalization_disposition()
  end

  @doc false
  @spec finalize_request_with_disposition(Request.t(), Attempt.t(), map()) ::
          internal_request_result()
  def finalize_request_with_disposition(
        %Request{} = request,
        %Attempt{} = attempt,
        attrs \\ %{}
      ) do
    request_status = Map.get(attrs, :request_status, Map.get(attrs, :status, "succeeded"))

    attempt_status =
      Map.get(attrs, :attempt_status, request_status_to_attempt_status(request_status))

    usage = normalize_final_usage(Map.get(attrs, :usage, %{}), request_status)
    response_status_code = Map.get(attrs, :response_status_code)
    retry_count = Map.get(attrs, :retry_count, request.retry_count || 0)
    last_error_code = blank_to_nil(Map.get(attrs, :last_error_code))
    error_message = blank_to_nil(Map.get(attrs, :error_message))

    finalization = %{
      attempt_status: attempt_status,
      request_status: request_status,
      response_status_code: response_status_code,
      retry_count: retry_count,
      last_error_code: last_error_code,
      error_message: error_message,
      timestamp: nil
    }

    Repo.transaction(fn ->
      {request, attempt, reservation, existing_settlement, replay_entitlement} =
        lock_finalization_rows(request, attempt)

      timestamp = if replay_entitlement, do: replay_db_now(), else: now(attrs)
      finalization = %{finalization | timestamp: timestamp}

      replay_entitlement =
        replay_finalization_authority(attempt, replay_entitlement, attrs)

      if replay_entitlement == :stale_generation do
        %{
          request: Repo.reload!(request),
          attempt: Repo.reload!(attempt),
          finalization_disposition: :reused,
          stale_generation?: true
        }
      else
        finalize_current_generation(
          request,
          attempt,
          reservation,
          existing_settlement,
          replay_entitlement,
          usage,
          attrs,
          finalization
        )
      end
    end)
    |> unwrap_transaction()
    |> tap_request_finalized_events_unless_stale()
  end

  defp finalize_current_generation(
         request,
         attempt,
         reservation,
         existing_settlement,
         replay_entitlement,
         usage,
         attrs,
         finalization
       ) do
    timestamp = finalization.timestamp

    case finalization_action(existing_settlement, usage) do
      {:reuse, settlement} ->
        release =
          Repo.get_by!(
            LedgerEntry,
            source_event_id: LedgerEntries.release_source_event_id(request.id)
          )

        close_replay_entitlement(replay_entitlement, timestamp, attrs)

        %{
          request: request,
          attempt: attempt,
          settlement: settlement,
          release: release,
          finalization_disposition: :reused
        }

      action ->
        run_before_finalize!(attrs)
        previous_request = request
        attempt = persist_final_attempt(attempt, usage, attrs, finalization)
        RequestLogFacts.record_attempt_written!(attempt)

        pricing =
          PricingResolution.lookup_for_settlement(
            request,
            attempt,
            reservation,
            usage,
            attrs,
            timestamp
          )

        request = persist_final_request(request, usage, pricing, finalization, replay_entitlement)

        settlement_state =
          build_settlement_context(request, attempt, reservation, usage, pricing, finalization)

        %{settlement: settlement, release: release, status: settlement_status} =
          persist_settlement_entries(
            request,
            attempt,
            reservation,
            settlement_state,
            previous_request,
            settlement_to_replace(action)
          )

        record_settlement_fact!(settlement, settlement_status)
        close_replay_entitlement(replay_entitlement, timestamp, attrs)

        %{
          request: request,
          attempt: attempt,
          settlement: settlement,
          release: release,
          finalization_disposition: finalization_disposition(settlement_status)
        }
    end
  end

  defp replay_finalization_authority(attempt, nil, _attrs) do
    if attempt.replay_generation == 0, do: nil, else: :stale_generation
  end

  defp replay_finalization_authority(attempt, entitlement, attrs) do
    cond do
      consumed_replay_attempt?(attempt, entitlement) ->
        entitlement

      closing_armed_replay_attempt?(attempt, entitlement, attrs) ->
        entitlement

      true ->
        :stale_generation
    end
  end

  defp consumed_replay_attempt?(attempt, entitlement) do
    attempt.replay_generation == entitlement.replay_generation and
      entitlement.status == "consumed" and entitlement.replay_attempt_id == attempt.id and
      is_nil(entitlement.closed_at)
  end

  defp closing_armed_replay_attempt?(attempt, entitlement, attrs) do
    Map.get(attrs, :replay_entitlement_close_status) in ["expired", "revoked"] and
      attempt.replay_generation == 0 and entitlement.status == "armed" and
      entitlement.eligible_attempt_id == attempt.id and is_nil(entitlement.closed_at)
  end

  defp lock_replay_prefix(request) do
    session_id =
      Repo.one(
        from turn in CodexPooler.Gateway.Persistence.CodexTurn,
          where: turn.request_id == ^request.id,
          select: turn.codex_session_id
      )

    if is_nil(session_id), do: :ok, else: lock_replay_session_prefix(request, session_id)
  end

  defp lock_replay_session_prefix(request, session_id) do
    _session =
      Repo.one!(
        from session in CodexPooler.Gateway.Persistence.CodexSession,
          where: session.id == ^session_id,
          lock: "FOR UPDATE"
      )

    _api_key =
      Repo.one!(
        from api_key in CodexPooler.Access.APIKey,
          where: api_key.id == ^request.api_key_id,
          lock: "FOR UPDATE"
      )

    _turn =
      Repo.one!(
        from turn in CodexPooler.Gateway.Persistence.CodexTurn,
          where: turn.request_id == ^request.id,
          lock: "FOR UPDATE"
      )

    :ok
  end

  defp replay_db_now do
    Repo.one!(
      from request in Request,
        limit: 1,
        select: type(fragment("request_replay_db_now()"), :utc_datetime_usec)
    )
  end

  defp close_replay_entitlement(nil, _timestamp, _attrs), do: :ok

  defp close_replay_entitlement(%RequestReplayEntitlement{} = entitlement, timestamp, attrs) do
    closed_at =
      case entitlement.last_liveness_at || entitlement.started_at || entitlement.consumed_at do
        %DateTime{} = state_at ->
          if DateTime.compare(timestamp, state_at) == :gt,
            do: timestamp,
            else: DateTime.add(state_at, 1, :microsecond)

        _state_at ->
          timestamp
      end

    close_attrs =
      case Map.get(attrs, :replay_entitlement_close_status) do
        status when status in ["expired", "revoked"] ->
          %{
            status: status,
            terminal_at: timestamp,
            closed_at: DateTime.add(timestamp, 1, :microsecond)
          }

        _status ->
          %{closed_at: closed_at}
      end

    entitlement
    |> RequestReplayEntitlement.changeset(close_attrs)
    |> Repo.update!()

    :ok
  end

  defp lock_finalization_rows(%Request{} = request, %Attempt{} = attempt) do
    :ok = lock_replay_prefix(request)

    request =
      Repo.one!(
        from locked_request in Request,
          where: locked_request.id == ^request.id,
          lock: "FOR UPDATE"
      )

    attempt =
      Repo.one!(
        from locked_attempt in Attempt,
          where: locked_attempt.id == ^attempt.id,
          lock: "FOR UPDATE"
      )

    latest_attempt =
      Repo.one!(
        from row in Attempt,
          where: row.request_id == ^request.id,
          order_by: [desc: row.attempt_number],
          limit: 1,
          lock: "FOR UPDATE"
      )

    entitlement =
      Repo.one(
        from replay in RequestReplayEntitlement,
          where: replay.request_id == ^request.id,
          lock: "FOR UPDATE"
      )

    reservation_source_event_id = LedgerEntries.reservation_source_event_id(request.id)

    reservation_query =
      from entry in LedgerEntry,
        where: entry.source_event_id == ^reservation_source_event_id

    ledger_entries =
      Repo.all(
        from entry in LedgerEntry,
          where:
            entry.request_id == ^request.id and
              (entry.source_event_id == ^reservation_source_event_id or
                 (entry.entry_kind == "settlement" and entry.amount_status == "recorded")),
          lock: "FOR UPDATE"
      )

    reservation =
      Enum.find(ledger_entries, &(&1.source_event_id == reservation_source_event_id)) ||
        raise Ecto.NoResultsError, queryable: reservation_query

    existing_settlement =
      Enum.find(
        ledger_entries,
        &(&1.entry_kind == "settlement" and &1.amount_status == "recorded")
      )

    attempt = if latest_attempt.id == attempt.id, do: latest_attempt, else: attempt
    {request, attempt, reservation, existing_settlement, entitlement}
  end

  defp finalization_action(nil, _usage), do: :insert

  defp finalization_action(%LedgerEntry{usage_status: @usage_known} = settlement, _usage),
    do: {:reuse, settlement}

  defp finalization_action(%LedgerEntry{} = settlement, %{status: @usage_known}),
    do: {:replace, settlement}

  defp finalization_action(%LedgerEntry{} = settlement, _usage), do: {:reuse, settlement}

  defp run_before_finalize!(attrs) do
    case Map.get(attrs, :before_finalize) do
      nil ->
        :ok

      callback when is_function(callback, 0) ->
        case callback.() do
          :ok -> :ok
          {:ok, _value} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp settlement_to_replace({:replace, settlement}), do: settlement
  defp settlement_to_replace(:insert), do: nil

  defp persist_final_attempt(attempt, usage, attrs, finalization) do
    attempt_attrs =
      if Map.get(attrs, :preserve_replay_attempt, false) do
        %{}
      else
        %{
          status: finalization.attempt_status,
          completed_at: finalization.timestamp,
          upstream_status_code: finalization.response_status_code,
          retryable: Map.get(attrs, :retryable, false),
          network_error_code: finalization.last_error_code,
          error_message: finalization.error_message,
          latency_ms: Map.get(attrs, :latency_ms),
          usage_status: usage.status,
          response_metadata: Metadata.sanitize_metadata(Map.get(attrs, :attempt_metadata, %{}))
        }
      end

    attempt =
      attempt
      |> Ecto.Changeset.change(attempt_attrs)
      |> Repo.update!()

    attempt
  end

  defp persist_final_request(request, usage, pricing, finalization, replay_entitlement) do
    request_attrs =
      %{
        status: finalization.request_status,
        usage_status: usage.status,
        completed_at: finalization.timestamp,
        response_status_code: finalization.response_status_code,
        retry_count: finalization.retry_count,
        last_error_code: finalization.last_error_code
      }
      |> maybe_merge_finalized_identity_snapshot(request, pricing, replay_entitlement)

    request
    |> Ecto.Changeset.change(request_attrs)
    |> Repo.update!()
  end

  defp maybe_merge_finalized_identity_snapshot(
         attrs,
         _request,
         _pricing,
         %RequestReplayEntitlement{}
       ),
       do: attrs

  defp maybe_merge_finalized_identity_snapshot(attrs, request, pricing, nil),
    do: Map.merge(attrs, IdentitySnapshot.finalized_request_snapshot_attrs(request, pricing))

  defp build_settlement_context(_request, _attempt, reservation, usage, pricing, finalization) do
    usage = fill_unknown_usage_from_reservation(usage, reservation, finalization.timestamp)
    snapshot = pricing.snapshot

    settled_cost =
      if usage.status == @usage_known and pricing.status == "priced",
        do: PricingResolution.cost_micros(snapshot, usage),
        else: nil

    %{
      pricing: pricing,
      usage: usage,
      timestamp: finalization.timestamp,
      settlement_context: %{
        response_status_code: finalization.response_status_code,
        retry_count: finalization.retry_count,
        settled_cost: settled_cost
      }
    }
  end

  defp persist_settlement_entries(
         request,
         attempt,
         reservation,
         state,
         previous_request,
         previous_settlement
       ) do
    settlement_attrs =
      LedgerEntries.settlement_attrs(request, attempt, reservation, %{
        usage: state.usage,
        pricing: state.pricing,
        context: state.settlement_context,
        timestamp: state.timestamp
      })

    {settlement, settlement_status} =
      case previous_settlement do
        %LedgerEntry{} = existing ->
          {LedgerEntries.replace_settlement!(existing, settlement_attrs), :replaced}

        nil ->
          LedgerEntries.create_or_get_with_status!(settlement_attrs)
      end

    release =
      request
      |> LedgerEntries.release_attrs(attempt, reservation, %{
        usage: state.usage,
        pricing: state.pricing,
        timestamp: state.timestamp
      })
      |> LedgerEntries.create_or_get!()

    case settlement_status do
      :inserted -> Rollups.accumulate!(request, settlement)
      :replaced -> Rollups.replace!(previous_request, previous_settlement, request, settlement)
      :existing -> :ok
    end

    %{settlement: settlement, release: release, status: settlement_status}
  end

  defp record_settlement_fact!(settlement, :replaced),
    do: RequestLogFacts.replace_settlement_written!(settlement)

  defp record_settlement_fact!(settlement, _status),
    do: RequestLogFacts.record_settlement_written!(settlement)

  defp finalization_disposition(:inserted), do: :inserted
  defp finalization_disposition(:replaced), do: :replaced
  defp finalization_disposition(:existing), do: :reused

  defp strip_finalization_disposition({:ok, result}),
    do: {:ok, Map.delete(result, :finalization_disposition)}

  defp strip_finalization_disposition({:error, _reason} = error), do: error

  defp tap_request_log_event({:ok, %{request: request}} = result, reason) do
    Events.broadcast_request_logs(request.pool_id, reason, %{
      request_id: request.id,
      status: request.status
    })

    result
  end

  defp tap_request_log_event(result, _reason), do: result

  defp tap_request_finalized_events({:ok, %{request: request}} = result) do
    Events.broadcast_request_logs(request.pool_id, "request_finalized", %{
      request_id: request.id,
      status: request.status
    })

    Events.broadcast_usage(request.pool_id, "usage_updated", %{
      request_id: request.id,
      status: request.status,
      usage_status: request.usage_status
    })

    result
  end

  defp tap_request_finalized_events(result), do: result

  defp attr(map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  # Reason: usage finalization accepts atom and string payload shapes.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp normalize_final_usage(usage, request_status) do
    status =
      attr(usage, :status) ||
        if(request_status == "succeeded", do: @usage_pending, else: @usage_unknown)

    input_tokens = get_int(usage, [:input_tokens, "input_tokens"])
    cached_input_tokens = optional_usage_counter(usage, :cached_input_tokens)
    cache_write_tokens = optional_usage_counter(usage, :cache_write_tokens)
    output_tokens = get_int(usage, [:output_tokens, "output_tokens"])
    reasoning_tokens = get_int(usage, [:reasoning_tokens, "reasoning_tokens"]) || 0

    total_tokens =
      get_int(usage, [:total_tokens, "total_tokens"]) ||
        (input_tokens || 0) + (output_tokens || 0)

    valid_usage? =
      status != @usage_known or
        valid_reported_usage?(
          input_tokens,
          cached_input_tokens,
          cache_write_tokens,
          output_tokens,
          total_tokens
        )

    normalized_status =
      if status in [@usage_known, @usage_pending, @usage_unknown, @usage_not_applicable] and
           valid_usage?,
         do: status,
         else: @usage_unknown

    %{
      status: normalized_status,
      input_tokens: input_tokens || 0,
      cached_input_tokens: reported_counter_value(cached_input_tokens),
      cache_write_tokens: reported_counter_value(cache_write_tokens),
      output_tokens: output_tokens || 0,
      reasoning_tokens: reasoning_tokens,
      total_tokens: total_tokens,
      source:
        if(valid_usage?,
          do: attr(usage, :source) || default_usage_source(normalized_status),
          else: "invalid_usage_tokens"
        ),
      service_tier: attr(usage, :service_tier),
      recorded_at: attr(usage, :recorded_at) || now()
    }
  end

  defp optional_usage_counter(usage, key) do
    case Map.fetch(usage, key) do
      {:ok, value} ->
        normalize_reported_counter(value)

      :error ->
        case Map.fetch(usage, Atom.to_string(key)) do
          {:ok, value} -> normalize_reported_counter(value)
          :error -> :unreported
        end
    end
  end

  defp normalize_reported_counter(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp normalize_reported_counter(_value), do: :invalid

  defp reported_counter_value({:ok, value}), do: value
  defp reported_counter_value(_unreported_or_invalid), do: nil

  defp valid_reported_usage?(
         input_tokens,
         cached_input_tokens,
         cache_write_tokens,
         output_tokens,
         total_tokens
       ) do
    with true <- nonnegative_integer?(input_tokens),
         true <- valid_optional_counter?(cached_input_tokens),
         true <- valid_optional_counter?(cache_write_tokens),
         true <- nonnegative_integer?(output_tokens),
         true <- nonnegative_integer?(total_tokens),
         {:ok, reads} <- optional_counter_for_sum(cached_input_tokens),
         {:ok, writes} <- optional_counter_for_sum(cache_write_tokens) do
      reads + writes <= input_tokens
    else
      _invalid -> false
    end
  end

  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0
  defp valid_optional_counter?(:unreported), do: true
  defp valid_optional_counter?({:ok, _value}), do: true
  defp valid_optional_counter?(:invalid), do: false
  defp optional_counter_for_sum(:unreported), do: {:ok, 0}
  defp optional_counter_for_sum({:ok, value}), do: {:ok, value}

  defp fill_unknown_usage_from_reservation(
         %{status: @usage_known} = usage,
         _reservation,
         _timestamp
       ),
       do: usage

  defp fill_unknown_usage_from_reservation(usage, reservation, timestamp) do
    %{
      usage
      | input_tokens: reservation.input_tokens || 0,
        cached_input_tokens: reservation.cached_input_tokens || 0,
        output_tokens: reservation.output_tokens || 0,
        reasoning_tokens: reservation.reasoning_tokens || 0,
        total_tokens: reservation.total_tokens || 0,
        recorded_at: timestamp
    }
  end

  defp normalize_model(%Model{} = model), do: model
  defp normalize_model(id) when is_binary(id), do: Repo.get(Model, id)
  defp normalize_model(_id), do: nil

  defp attempt_model(_request, %{model: %Model{} = model}), do: model

  defp attempt_model(%Request{model_id: model_id}, _attrs) when is_binary(model_id),
    do: Repo.get(Model, model_id)

  defp attempt_model(_request, _attrs), do: nil

  defp insert_attempt!(request, assignment, attrs, timestamp) do
    model = attempt_model(request, attrs)
    pricing_snapshot = attempt_pricing_snapshot(request, model, attrs)

    attempt_number =
      Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count, :id) + 1

    attempt_changes = %Attempt{
      id: Map.get(attrs, :id),
      request_id: request.id,
      attempt_number: attempt_number,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      pricing_snapshot_id: pricing_snapshot && pricing_snapshot.id,
      model_id: request.model_id,
      upstream_model_id: (model && model.upstream_model_id) || request.requested_model,
      transport: request.transport,
      status: Map.get(attrs, :status, "in_progress"),
      started_at: timestamp,
      retryable: Map.get(attrs, :retryable, false),
      usage_status: Map.get(attrs, :usage_status, @usage_pending),
      response_metadata: Metadata.sanitize_metadata(Map.get(attrs, :response_metadata, %{})),
      replay_generation: Map.get(attrs, :replay_generation, 0)
    }

    ReferenceLocks.lock_and_validate!(assignment.upstream_identity_id, assignment.id)

    case Repo.insert(attempt_changes,
           on_conflict: {:replace, [:id]},
           conflict_target: :id,
           returning: true
         ) do
      {:ok, attempt} ->
        IdentitySnapshot.persist_request_identity_snapshot(request, assignment, attrs)
        RequestLogFacts.record_attempt_written!(attempt)
        attempt

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp attempt_pricing_snapshot(_request, _model, %{pricing_snapshot: pricing_snapshot}),
    do: pricing_snapshot

  defp attempt_pricing_snapshot(%Request{} = request, model, _attrs),
    do: PricingResolution.latest_snapshot_for_request(request, model)

  defp request_status_to_attempt_status("succeeded"), do: "succeeded"
  defp request_status_to_attempt_status("cancelled"), do: "cancelled"
  defp request_status_to_attempt_status(_status), do: "failed"
  defp default_usage_source(@usage_known), do: "upstream_usage"
  defp default_usage_source(@usage_pending), do: "usage_pending"
  defp default_usage_source(_status), do: "usage_unknown"
  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: value)

  defp now(opts \\ %{}),
    do:
      (attr(opts, :now) || DateTime.utc_now())
      |> DateTime.truncate(:microsecond)

  defp get_int(map, keys),
    do: keys |> Enum.find_value(fn key -> Map.get(map, key) end) |> int_value()

  defp int_value(nil), do: nil
  defp int_value(%Decimal{} = value), do: decimal_to_integer(value)
  defp int_value(value) when is_integer(value), do: value

  defp int_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp int_value(_value), do: nil

  defp decimal_to_integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer()

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, value}), do: {:error, value}
end
