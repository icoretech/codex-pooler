defmodule CodexPooler.Gateway.Runtime.Service do
  @moduledoc """
  Codex backend gateway execution.
  """

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Payloads.TranscriptionPayload
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.SessionContinuity, as: PersistenceSessionContinuity
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.RouteFiltering
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation
  alias CodexPooler.Gateway.Runtime.Dispatch.CandidateDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.FileDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Gateway.Runtime.Dispatch.UpstreamAttempt
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.Websocket.ResponseProcessed
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPooler.Repo

  @backend_transcription_model "gpt-4o-transcribe"
  @native_image_endpoints [
    "/backend-api/codex/images/generations",
    "/backend-api/codex/images/edits"
  ]

  @type auth :: Access.auth_context()
  @type payload :: map()
  @type opts :: RequestOptions.t()
  @type gateway_error :: Contracts.gateway_error()
  @type gateway_result :: Contracts.gateway_result()
  @typedoc false
  @type session_routable_context :: %{
          required(:auth) => auth(),
          required(:endpoint) => String.t(),
          required(:payload) => payload(),
          required(:request_options) => opts(),
          required(:model) => Model.t(),
          required(:candidates) => list(),
          required(:route_state) => RouteState.t(),
          required(:turn_claim) => CodexPooler.Accounting.Request.t() | nil
        }
  @typep session_routable_result ::
           {:ok, map(), list(), opts(), RouteState.t()} | {:error, term()}
  @typedoc false
  @type reserve_and_start_turn_fun ::
          (auth(),
           Model.t(),
           payload(),
           String.t(),
           opts(),
           RouteState.t(),
           CodexPooler.Accounting.Request.t()
           | nil ->
             {:ok, map()} | {:error, term()})

  @spec backend_transcription_model() :: String.t()
  def backend_transcription_model, do: @backend_transcription_model

  @spec create_upstream_file(auth(), map(), opts()) :: FileDispatch.file_result()
  def create_upstream_file(auth, params, %RequestOptions{} = opts),
    do: FileDispatch.create_upstream_file(auth, params, opts)

  @spec create_v1_file(
          auth(),
          %{required(:purpose) => String.t(), required(:file) => map()},
          opts()
        ) :: FileDispatch.file_result()
  def create_v1_file(auth, params, %RequestOptions{} = opts),
    do: FileDispatch.create_v1_file(auth, params, opts)

  @spec mark_uploaded(auth(), String.t(), opts()) :: FileDispatch.file_result()
  def mark_uploaded(auth, file_id, %RequestOptions{} = opts),
    do: FileDispatch.mark_uploaded(auth, file_id, opts)

  defp normalize_policy_or_log(auth, endpoint, payload, opts) do
    case Access.normalize_api_key_policy(auth.api_key) do
      {:ok, policy} ->
        {:ok, policy}

      {:error, reason} ->
        Denials.log_policy(denial_context(auth, nil, reason, endpoint, payload, opts))
    end
  end

  defp effective_model_name(
         %{enforced_model_identifier: enforced_model},
         requested_model,
         endpoint,
         %RequestOptions{} = request_options
       )
       when is_binary(enforced_model) do
    if native_image_request?(endpoint, request_options) and
         canonical_model_identifier(requested_model) != canonical_model_identifier(enforced_model) do
      {:error, error(403, "model_not_allowed", "api key is not allowed to use this model")}
    else
      {:ok, enforced_model}
    end
  end

  defp effective_model_name(_policy, requested_model, _endpoint, _opts),
    do: {:ok, requested_model}

  defp policy_request_opts(
         %RequestOptions{} = request_options,
         policy,
         requested_model,
         effective_model
       ) do
    RequestOptions.put_routing(request_options,
      api_key_policy: policy,
      requested_model: requested_model,
      effective_model: effective_model
    )
  end

  @spec request_options(opts(), String.t(), payload()) :: RequestOptions.t()
  defp request_options(%RequestOptions{} = request_options, endpoint, payload),
    do: RequestOptions.for_payload(request_options, endpoint, payload)

  @spec execute_request_options(opts(), String.t(), payload(), String.t()) :: RequestOptions.t()
  defp execute_request_options(
         %RequestOptions{} = request_options,
         endpoint,
         payload,
         requested_model
       ) do
    request_options
    |> request_options(endpoint, payload)
    |> RequestOptions.put_routing(requested_model: requested_model)
  end

  @spec execute(auth(), String.t(), payload(), opts()) ::
          {:ok, gateway_result()} | {:error, gateway_error()}
  def execute(auth, endpoint, payload, %RequestOptions{} = opts) when is_map(payload) do
    if image_generation_permission_denied?(auth, opts) do
      {:error,
       error(
         403,
         "image_generation_disabled",
         "Image generation is disabled for this pool"
       )}
    else
      case requested_model(payload) do
        {:ok, model_name} ->
          request_options = execute_request_options(opts, endpoint, payload, model_name)
          execute_requested_model(auth, endpoint, payload, request_options, model_name)

        {:error, %{code: _code} = reason} ->
          {:error, reason}
      end
    end
  end

  def execute(_auth, _endpoint, _payload, %RequestOptions{}),
    do: {:error, error(400, "invalid_request", "request body must be a JSON object")}

  defp image_generation_permission_denied?(
         %{pool: pool},
         %RequestOptions{
           payload_context: %{image_generation_permission_required?: permission_required?}
         }
       )
       when permission_required? == true,
       do: not PoolRouting.allow_image_generation?(pool)

  defp image_generation_permission_denied?(_auth, %RequestOptions{}), do: false

  defp execute_requested_model(auth, endpoint, payload, request_options, model_name) do
    case normalize_policy_or_log(auth, endpoint, payload, request_options) do
      {:ok, policy} ->
        case effective_model_name(policy, model_name, endpoint, request_options) do
          {:ok, effective_model_name} ->
            request_options =
              policy_request_opts(request_options, policy, model_name, effective_model_name)

            execute_effective_model(
              auth,
              endpoint,
              payload,
              request_options,
              effective_model_name
            )

          {:error, reason} ->
            Denials.log_gateway(
              denial_context(auth, nil, reason, endpoint, payload, request_options)
            )
        end

      {:error, %{code: _code} = reason} ->
        {:error, reason}
    end
  end

  @spec execute_effective_model(auth(), String.t(), payload(), opts(), String.t()) ::
          {:ok, gateway_result()} | {:error, gateway_error()}
  defp execute_effective_model(auth, endpoint, payload, request_options, effective_model_name) do
    case visible_model_context(auth.pool, effective_model_name, endpoint, request_options) do
      %{visible_model: %Model{} = model} = visible_model_data ->
        execute_visible_model(
          auth,
          endpoint,
          payload,
          request_options,
          model,
          visible_model_data
        )

      nil ->
        reason = error(400, "invalid_model", "model is not available for this pool", "model")

        Denials.log_gateway(denial_context(auth, nil, reason, endpoint, payload, request_options))
    end
  end

  defp execute_visible_model(auth, endpoint, payload, request_options, model, visible_model_data) do
    case PreDispatch.prepare(auth, endpoint, payload, request_options, model, visible_model_data) do
      {:ok, prepared} ->
        case claim_explicit_websocket_turn(
               auth,
               model,
               payload,
               endpoint,
               prepared.request_options,
               prepared.route_state
             ) do
          {:ok, turn_claim} ->
            execute_session_routable_model(
              auth,
              endpoint,
              payload,
              prepared.request_options,
              model,
              prepared.candidates,
              prepared.route_state,
              turn_claim
            )

          {:error, %{code: :duplicate_request}} ->
            {:error, duplicate_turn_error()}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, %{code: "duplicate_turn"} = reason} ->
        {:error, reason}

      {:error, %{code: _code} = reason} ->
        log_gateway_denial(
          denial_context(auth, model, reason, endpoint, payload, request_options)
        )
    end
  end

  defp execute_session_routable_model(
         auth,
         endpoint,
         payload,
         request_options,
         model,
         candidates,
         %RouteState{} = route_state,
         turn_claim
       ) do
    %{
      auth: auth,
      endpoint: endpoint,
      payload: payload,
      request_options: request_options,
      model: model,
      candidates: candidates,
      route_state: route_state,
      turn_claim: turn_claim
    }
    |> execute_session_routable_model(&reserve_and_start_turn/7)
  end

  @doc false
  @spec execute_session_routable_model(
          session_routable_context(),
          reserve_and_start_turn_fun()
        ) :: {:ok, gateway_result()} | {:error, gateway_error()}
  def execute_session_routable_model(
        %{
          auth: _auth,
          endpoint: _endpoint,
          payload: _payload,
          request_options: %RequestOptions{},
          model: %Model{},
          candidates: candidates,
          route_state: %RouteState{},
          turn_claim: _turn_claim
        } = context,
        reserve_and_start_turn
      )
      when is_list(candidates) and is_function(reserve_and_start_turn, 7) do
    do_execute_session_routable_model(context, reserve_and_start_turn)
  end

  defp do_execute_session_routable_model(
         %{
           auth: auth,
           endpoint: endpoint,
           payload: payload,
           request_options: %RequestOptions{} = request_options,
           model: %Model{} = model,
           candidates: candidates,
           route_state: %RouteState{} = route_state,
           turn_claim: turn_claim
         },
         reserve_and_start_turn
       )
       when is_list(candidates) and is_function(reserve_and_start_turn, 7) do
    request_options =
      RequestOptions.put_routing(request_options, reset_probe: ResetProbe.new())

    result =
      with {:ok, candidates, request_options, route_state} <-
             route_filter_input(
               auth,
               model,
               endpoint,
               payload,
               request_options,
               candidates
             )
             |> RouteFiltering.filter_candidates_with_route_state(route_state),
           :ok <-
             AccountingReservation.validate_reset_probe_scope(
               candidates,
               request_options,
               route_state
             ),
           {:ok, reserved} <-
             reserve_and_start_turn.(
               auth,
               model,
               payload,
               endpoint,
               request_options,
               route_state,
               turn_claim
             ) do
        {:ok, reserved, candidates, request_options, route_state}
      end

    handle_session_routable_result(result, %{
      auth: auth,
      endpoint: endpoint,
      payload: payload,
      request_options: request_options,
      model: model,
      candidates: candidates,
      route_state: route_state,
      turn_claim: turn_claim
    })
  end

  @spec handle_session_routable_result(session_routable_result(), session_routable_context()) ::
          {:ok, gateway_result()} | {:error, gateway_error()}
  defp handle_session_routable_result(
         result,
         %{
           auth: auth,
           endpoint: endpoint,
           payload: payload,
           request_options: request_options,
           model: model,
           turn_claim: turn_claim
         }
       ) do
    case result do
      {:ok, reserved, candidates, request_options, route_state} ->
        dispatch_candidates(
          auth,
          endpoint,
          payload,
          model,
          reserved,
          candidates,
          request_options,
          route_state
        )

      {:error, %{code: "duplicate_turn"} = reason} ->
        {:error, reason}

      {:error, {:reset_probe_scope_mismatch, reason}} ->
        reject_claimed_turn(
          auth,
          model,
          reason,
          endpoint,
          payload,
          request_options,
          turn_claim
        )

      {:error, %{code: _code} = reason} ->
        Denials.log_gateway(
          denial_context(auth, model, reason, endpoint, payload, request_options),
          turn_claim
        )

      {:error, reason} ->
        reason = AccountingReservation.pre_attempt_failure(reason, request_options)

        reject_claimed_turn(
          auth,
          model,
          reason,
          endpoint,
          payload,
          request_options,
          turn_claim
        )
    end
  end

  defp route_filter_input(auth, model, endpoint, payload, request_options, candidates) do
    CandidateEligibility.FilterInput.new(%{
      auth: auth,
      model: model,
      endpoint: endpoint,
      payload: payload,
      request_options: request_options,
      candidates: candidates
    })
  end

  @spec execute_multipart(auth(), String.t(), payload(), opts()) ::
          {:ok, gateway_result()} | {:error, gateway_error()}
  def execute_multipart(
        auth,
        "/backend-api/transcribe" = endpoint,
        payload,
        %RequestOptions{} = opts
      )
      when is_map(payload) do
    request_options =
      opts
      |> request_options(endpoint, payload)
      |> RequestOptions.put_payload_context(
        forced_transcription_model: @backend_transcription_model
      )

    case TranscriptionPayload.normalize(payload, request_options) do
      {:ok, safe_payload, media_opts} -> execute(auth, endpoint, safe_payload, media_opts)
      {:error, reason} -> {:error, reason}
    end
  end

  def execute_multipart(_auth, _endpoint, _payload, %RequestOptions{}),
    do: {:error, error(400, "invalid_request", "request body must be multipart/form-data")}

  @spec execute_websocket_response(auth(), binary(), opts(), (binary() -> any())) ::
          :ok | {:error, gateway_error()}
  def execute_websocket_response(auth, raw_payload, %RequestOptions{} = opts, push_frame)
      when is_binary(raw_payload) and is_function(push_frame, 1) do
    with {:ok, payload} <- decode_websocket_payload(raw_payload),
         {:ok, result} <-
           execute_websocket_payload(auth, payload, opts, push_frame) do
      WebsocketCodec.deliver_result(result, push_frame)
    end
  end

  def execute_websocket_response(_auth, _raw_payload, _opts, _push_frame) do
    {:error, error(400, "invalid_request", "websocket message must be a text JSON frame")}
  end

  defp execute_websocket_payload(auth, payload, opts, push_frame) do
    cond do
      WebsocketCodec.response_processed_payload?(payload) ->
        ResponseProcessed.handle(auth, payload, opts)

      WebsocketCodec.warmup_payload?(payload) ->
        {:ok, WebsocketCodec.warmup_result()}

      true ->
        with {:ok, coerced} <- WebsocketCodec.coerce_request(payload, opts, push_frame) do
          auth
          |> execute(coerced.endpoint, coerced.payload, coerced.request_options)
          |> adapt_websocket_result(coerced)
        end
    end
  end

  defp adapt_websocket_result(result, %{result_adapter: result_adapter})
       when is_function(result_adapter, 1),
       do: result_adapter.(result)

  defp adapt_websocket_result(result, _coerced), do: result

  defp dispatch_candidates(
         auth,
         endpoint,
         payload,
         model,
         reserved,
         candidates,
         request_options,
         %RouteState{} = route_state
       ) do
    with {:ok, context} <-
           Context.new(%{
             auth: auth,
             endpoint: endpoint,
             payload: payload,
             model: model,
             reserved: reserved,
             candidates: candidates,
             request_options: request_options,
             route_state: route_state
           }) do
      CandidateDispatch.dispatch(context, &dispatch_decrypted_candidate/1)
    end
  end

  defp dispatch_decrypted_candidate(prepared_context) do
    UpstreamAttempt.dispatch(prepared_context, upstream_attempt_callbacks())
  end

  defp upstream_attempt_callbacks do
    %{
      register_continuity: &register_codex_continuity/3,
      retry_dispatch: &dispatch_decrypted_candidate/1
    }
  end

  defp denial_context(auth, model, reason, endpoint, payload, opts) do
    %Denials.Context{
      auth: auth,
      model: model,
      reason: reason,
      endpoint: endpoint,
      payload: payload,
      opts: request_options(opts, endpoint, payload)
    }
  end

  defp log_gateway_denial(%Denials.Context{
         reason: %{accounting_disposition: :zero_work} = reason
       }),
       do: {:error, reason}

  defp log_gateway_denial(%Denials.Context{} = context), do: Denials.log_gateway(context)

  defp reject_claimed_turn(
         _auth,
         _model,
         reason,
         _endpoint,
         _payload,
         _request_options,
         nil
       ),
       do: {:error, reason}

  defp reject_claimed_turn(
         auth,
         model,
         reason,
         endpoint,
         payload,
         request_options,
         turn_claim
       ) do
    Denials.log_gateway(
      denial_context(auth, model, reason, endpoint, payload, request_options),
      turn_claim
    )
  end

  defp claim_explicit_websocket_turn(
         auth,
         model,
         payload,
         endpoint,
         %RequestOptions{
           transport: %{transport: "websocket"},
           continuity: %{codex_turn_id: turn_id}
         } = request_options,
         %RouteState{} = route_state
       )
       when is_binary(turn_id) do
    attrs = AccountingReservation.attrs(auth, payload, endpoint, request_options, route_state)

    case Accounting.claim_websocket_turn(auth, model, attrs) do
      {:ok, %{request: request}} -> {:ok, request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_explicit_websocket_turn(
         _auth,
         _model,
         _payload,
         _endpoint,
         %RequestOptions{},
         %RouteState{}
       ),
       do: {:ok, nil}

  defp reserve(
         auth,
         model,
         payload,
         endpoint,
         %RequestOptions{} = request_options,
         %RouteState{} = route_state,
         turn_claim
       ) do
    attrs =
      auth
      |> AccountingReservation.attrs(payload, endpoint, request_options, route_state)
      |> Map.put(:reservation_estimate, AccountingReservation.reservation_estimate(route_state))
      |> Map.put(:turn_claim, turn_claim)

    Accounting.reserve(
      auth,
      model,
      payload,
      attrs
    )
  end

  defp reserve_and_start_turn(
         auth,
         model,
         payload,
         endpoint,
         %RequestOptions{} = request_options,
         %RouteState{} = route_state,
         turn_claim
       ) do
    Repo.transaction(fn ->
      with {:ok, reserved} <-
             reserve(auth, model, payload, endpoint, request_options, route_state, turn_claim),
           {:ok, reserved} <- SessionContinuity.start_turn(reserved, request_options) do
        reserved
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, reserved} -> {:ok, reserved}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Ecto.ConstraintError ->
      if duplicate_turn_reservation_constraint?(error, request_options) do
        {:error, duplicate_turn_error()}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp duplicate_turn_reservation_constraint?(
         %Ecto.ConstraintError{constraint: "requests_correlation_id_uq"},
         %RequestOptions{
           transport: %{transport: "websocket"},
           continuity: %{codex_turn_id: turn_id}
         }
       )
       when is_binary(turn_id),
       do: true

  defp duplicate_turn_reservation_constraint?(_error, _opts), do: false

  defp duplicate_turn_error do
    error(
      409,
      "duplicate_turn",
      "duplicate Codex turn was already recorded for this session",
      "request_id"
    )
  end

  defp visible_model_context(
         pool,
         requested_model,
         endpoint,
         %RequestOptions{} = request_options
       ) do
    case CandidateEligibility.visible_model_context(pool, requested_model) do
      %{visible_model: %Model{}} = context ->
        context

      nil ->
        media_host_model_context(pool, requested_model, endpoint, request_options)
    end
  end

  defp media_host_model_context(
         pool,
         requested_model,
         endpoint,
         %RequestOptions{} = request_options
       ) do
    if native_image_request?(endpoint, request_options) and
         not CandidateEligibility.catalog_model_present?(pool, requested_model) do
      visible_media_host_context(pool, requested_model)
    else
      legacy_media_host_model_context(pool, requested_model, request_options)
    end
  end

  defp visible_media_host_context(pool, requested_model) do
    hydration = CandidateEligibility.hydrate_model_visibility(pool)

    hydration.visible_models
    |> Enum.find(&media_host_model?/1)
    |> media_host_context(hydration, requested_model)
  end

  defp legacy_media_host_model_context(pool, requested_model, request_options) do
    hydration = CandidateEligibility.hydrate_model_visibility(pool)

    hydration.visible_models
    |> Enum.find(&media_host_model?(&1, request_options))
    |> media_host_context(hydration, requested_model)
  end

  defp media_host_context(%Model{} = model, hydration, requested_model) do
    Map.merge(hydration, %{
      requested_model: requested_model,
      effective_model: requested_model,
      visible_model: model,
      candidate_snapshots: Map.get(hydration.candidates_by_model_id, model.id, [])
    })
  end

  defp media_host_context(nil, _hydration, _requested_model), do: nil

  defp media_host_model?(%Model{} = model) do
    model.supports_responses and model.supports_streaming and model.supports_tools
  end

  defp media_host_model?(%Model{} = model, %RequestOptions{
         openai_compatibility: %{collect_openai_image_stream: true}
       }) do
    media_host_model?(model)
  end

  defp media_host_model?(%Model{}, %RequestOptions{
         payload_context: %{forced_transcription_model: model}
       })
       when is_binary(model),
       do: true

  defp media_host_model?(%Model{}, %RequestOptions{}), do: false

  defp native_image_request?(endpoint, %RequestOptions{
         payload_context: %{native_image_request?: true}
       }),
       do: endpoint in @native_image_endpoints

  defp native_image_request?(_endpoint, %RequestOptions{}), do: false

  defp canonical_model_identifier(model_identifier) do
    model_identifier |> String.trim() |> String.downcase()
  end

  defp requested_model(payload) do
    case Map.get(payload, "model") || Map.get(payload, :model) do
      model when is_binary(model) ->
        case String.trim(model) do
          "" -> {:error, error(400, "invalid_request", "model is required", "model")}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:error, error(400, "invalid_request", "model is required", "model")}
    end
  end

  defp register_codex_continuity(
         %RequestOptions{continuity: %{codex_session: %CodexSession{} = session}} =
           request_options,
         payload,
         body
       ) do
    PersistenceSessionContinuity.register_codex_session_continuity(
      session,
      payload,
      body,
      request_options
    )
  end

  defp register_codex_continuity(_opts, _payload, _body), do: :ok

  defp decode_websocket_payload(payload) do
    case WebsocketCodec.decode_payload(payload) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, :not_object} ->
        {:error, error(400, "invalid_request", "websocket message must be a JSON object")}

      {:error, :invalid_json} ->
        {:error, error(400, "invalid_request", "websocket message must be valid JSON")}
    end
  end

  defp error(status, code, message, param \\ nil, metadata \\ %{}),
    do: Map.merge(%{status: status, code: code, message: message, param: param}, metadata)
end
