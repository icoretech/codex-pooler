defmodule CodexPooler.Accounting.RequestLifecycle.Reservation do
  @moduledoc false

  # The atomic successor transaction intentionally nests validation and writes.
  # credo:disable-for-this-file Credo.Check.Refactor.Nesting

  import Ecto.Query

  alias CodexPooler.Access

  alias CodexPooler.Accounting.{
    ClientRetry,
    Metadata,
    PricingResolution,
    Request,
    RequestLogFacts,
    ReservationPolicy
  }

  alias CodexPooler.Accounting.RequestLifecycle.{FailedPredecessorResend, LedgerEntries}
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Persistence.{CodexSession, SessionContinuity}
  alias CodexPooler.Repo

  @usage_pending "usage_pending"
  @usage_not_applicable "not_applicable"

  @spec claim_websocket_turn(
          CodexPooler.Access.auth_context(),
          Model.t(),
          map()
        ) :: {:ok, map()} | {:error, Metadata.accounting_error()}
  def claim_websocket_turn(%{pool: pool, api_key: api_key}, %Model{} = model, opts) do
    if ClientRetry.reserved_successor_claim?(attr(opts, :correlation_id)) do
      {:error, duplicate_request_error(nil)}
    else
      case do_claim_websocket_turn(pool, api_key, model, opts, nil) do
        {:error, %{code: :duplicate_request}} ->
          claim_failed_predecessor_resend(pool, api_key, model, opts)

        result ->
          result
      end
    end
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
          idempotency_key: nil,
          client_ip: blank_to_nil(attr(opts, :client_ip)),
          user_agent: blank_to_nil(attr(opts, :user_agent)),
          request_metadata: claim_request_metadata(opts, client_resend),
          admitted_at: timestamp,
          retry_count: 0
        }
        |> Ecto.Changeset.change(
          ClientRetry.request_attrs(attr(opts, :native_client_retry_witness))
        )
        |> Repo.insert!()

      RequestLogFacts.record_request_created!(request)
      :ok = bind_direct_cleanup(opts, request)

      case client_resend do
        nil -> %{request: request}
        %{} -> %{request: request, client_resend: client_resend}
      end
    end)
    |> unwrap_transaction()
  rescue
    error in Ecto.ConstraintError ->
      if error.constraint == "requests_correlation_id_uq" do
        {:error, duplicate_request_error(if(resend_session, do: :successor_claimed))}
      else
        reraise(error, __STACKTRACE__)
      end
  end

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
      anchor_present?: attr(opts, :anchor_present?) == true
    }

    case FailedPredecessorResend.resolve(attr(opts, :correlation_id), scope) do
      {:ok, %{claim: claim, predecessor: predecessor, predecessor_shape: shape}} ->
        {claim,
         %{
           predecessor_request_id: predecessor.id,
           reason: :failed_predecessor,
           predecessor_shape: shape
         }}

      {:error, disposition} ->
        Repo.rollback(duplicate_request_error(disposition))
    end
  end

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

          case ReservationPolicy.enforce_reservation_limits(api_key, policy, estimate, timestamp) do
            :ok -> :ok
            {:error, _reason} -> Repo.rollback(:authorization_changed)
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
            opts: Map.put(opts, :turn_claim, nil),
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

  defp successor_correlation(predecessor, _policy, _input),
    do: ClientRetry.deterministic_successor_claim(predecessor.request)

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
        captured_epoch
      )
    end
  end

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
         captured_epoch
       ) do
    Repo.transaction(fn ->
      api_key = authorize_runtime_turn!(api_key, captured_epoch)
      auth = Map.put(auth, :api_key, api_key)
      maybe_test_runtime_authorization_barrier(:reserve, :after)

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

      case ReservationPolicy.enforce_reservation_limits(api_key, policy, estimate, timestamp) do
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
        auth: auth,
        pricing: pricing,
        estimate: estimate,
        opts: opts,
        timestamp: timestamp
      }

      request = insert_reserved_request!(request_context)
      RequestLogFacts.record_request_created!(request)

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
    end)
    |> unwrap_transaction()
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
      attrs =
        denied_request_attrs(%{
          auth: auth,
          pool: pool,
          api_key: api_key,
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
      api_key_id: context.api_key.id,
      model_id: context.model && context.model.id,
      requested_model:
        blank_to_nil(context.requested_model) ||
          (context.model && context.model.exposed_model_id) || context.endpoint,
      endpoint: context.endpoint,
      transport: context.transport,
      status: "rejected",
      usage_status: @usage_not_applicable,
      correlation_id: attr(context.opts, :correlation_id) || Ecto.UUID.generate(),
      idempotency_key: nil,
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

  defp insert_or_update_claimed_request!(attrs, %Request{} = turn_claim),
    do: update_claimed_request!(turn_claim, attrs)

  defp insert_or_update_claimed_request!(attrs, nil) do
    request =
      %Request{}
      |> Ecto.Changeset.change(attrs)
      |> Repo.insert!()

    request
  end

  defp update_claimed_request!(%Request{id: request_id}, attrs) do
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
      request
      |> Ecto.Changeset.change(
        attrs
        |> Map.drop([:admitted_at, :correlation_id])
        |> preserve_client_resend_metadata(request)
      )
      |> Repo.update!()
    else
      Repo.rollback(
        Metadata.accounting_error(:request_already_finalized, "request was already finalized")
      )
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
      reserve_metadata(context.auth, context.pricing, context.estimate, context.opts)

    settings_snapshot =
      PricingResolution.request_settings_snapshot(
        context.payload,
        request_metadata,
        context.pricing
      )

    attrs = %{
      pool_id: context.pool.id,
      api_key_id: context.api_key.id,
      model_id: context.model.id,
      requested_model: context.requested_model,
      endpoint: context.endpoint,
      transport: context.transport,
      status: "in_progress",
      usage_status: @usage_pending,
      correlation_id: context.correlation_id,
      idempotency_key: nil,
      client_ip: blank_to_nil(attr(context.opts, :client_ip)),
      user_agent: blank_to_nil(attr(context.opts, :user_agent)),
      request_metadata: request_metadata,
      reasoning_effort: settings_snapshot.reasoning_effort,
      requested_service_tier: settings_snapshot.requested_service_tier,
      actual_service_tier: settings_snapshot.actual_service_tier,
      service_tier: settings_snapshot.service_tier,
      admitted_at: context.timestamp
    }

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
