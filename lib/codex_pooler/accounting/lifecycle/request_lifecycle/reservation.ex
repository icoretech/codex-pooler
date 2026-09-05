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

  alias CodexPooler.Accounting.RequestLifecycle.LedgerEntries
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
      {:error, Metadata.accounting_error(:duplicate_request, "request was already recorded")}
    else
      do_claim_websocket_turn(pool, api_key, model, opts)
    end
  end

  defp do_claim_websocket_turn(pool, api_key, model, opts) do
    timestamp = now(opts)
    captured_epoch = runtime_revocation_epoch(api_key, opts)
    maybe_test_runtime_authorization_barrier(:claim, :before)

    Repo.transaction(fn ->
      api_key = authorize_runtime_turn!(api_key, captured_epoch)
      maybe_test_runtime_authorization_barrier(:claim, :after)

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
          correlation_id: attr(opts, :correlation_id),
          idempotency_key: nil,
          client_ip: blank_to_nil(attr(opts, :client_ip)),
          user_agent: blank_to_nil(attr(opts, :user_agent)),
          request_metadata: Metadata.sanitize_metadata(attr(opts, :request_metadata) || %{}),
          admitted_at: timestamp,
          retry_count: 0
        }
        |> Ecto.Changeset.change(
          ClientRetry.request_attrs(attr(opts, :native_client_retry_witness))
        )
        |> Repo.insert!()

      RequestLogFacts.record_request_created!(request)
      %{request: request}
    end)
    |> unwrap_transaction()
  rescue
    error in Ecto.ConstraintError ->
      if error.constraint == "requests_correlation_id_uq" do
        {:error, Metadata.accounting_error(:duplicate_request, "request was already recorded")}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  @spec claim_client_retry_successor(CodexPooler.Access.auth_context(), Model.t(), map(), map()) ::
          {:ok, ClientRetry.SuccessorClaim.t()} | {:error, atom() | map()}
  # One transaction intentionally owns every successor side effect.
  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
  def claim_client_retry_successor(
        %{pool: pool, api_key: api_key} = auth,
        %Model{} = model,
        payload,
        %{codex_session: %CodexSession{} = session} = opts
      ) do
    captured_epoch = runtime_revocation_epoch(api_key, opts)

    Repo.transaction(fn ->
      session = SessionContinuity.lock_codex_session_for_turn(session)
      api_key = authorize_runtime_turn!(api_key, captured_epoch)
      authorize_client_retry_model!(api_key, model)

      input = %{
        endpoint: attr(opts, :endpoint) || "/backend-api/codex/responses",
        requested_model: attr(opts, :requested_model) || model.exposed_model_id,
        runtime_revocation_epoch: captured_epoch,
        semantic_turn_digest: attr(opts, :semantic_turn_digest),
        replay_claim_digest: attr(opts, :replay_claim_digest),
        anchor_present?: attr(opts, :anchor_present?) == true,
        after_locks: attr(opts, :after_locks),
        owner_idle_validated?: attr(opts, :owner_idle_validated?) == true,
        owner_lease_token: attr(opts, :owner_lease_token),
        owner_instance_id: attr(opts, :owner_instance_id)
      }

      with {:ok, predecessor} <-
             ClientRetry.lock_eligible_predecessor!(session, api_key, model, input),
           {:ok, correlation_id} <- ClientRetry.deterministic_successor_claim(predecessor.request) do
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

  def claim_client_retry_successor(_auth, _model, _payload, _opts),
    do: {:error, :authorization_changed}

  defp normalize_retry_claim_error(%Ecto.Changeset{}), do: :successor_claimed
  defp normalize_retry_claim_error(reason) when is_map(reason), do: :authorization_changed
  defp normalize_retry_claim_error(reason), do: reason

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
      {:error, Metadata.accounting_error(:duplicate_request, "request was already recorded")}
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
      request
      |> Ecto.Changeset.change(Map.delete(attrs, :admitted_at))
      |> Repo.update!()
    else
      Repo.rollback(
        Metadata.accounting_error(:request_already_finalized, "request was already finalized")
      )
    end
  end

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

  defp authorize_runtime_turn!(api_key, captured_epoch) do
    case Access.authorize_api_key_runtime_turn(api_key, captured_epoch) do
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
