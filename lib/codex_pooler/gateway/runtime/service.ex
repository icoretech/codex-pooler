defmodule CodexPooler.Gateway.Runtime.Service do
  @moduledoc """
  Codex backend gateway execution.
  """

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Payloads.TranscriptionPayload
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.SessionContinuity, as: PersistenceSessionContinuity
  alias CodexPooler.Gateway.Persistence.SessionContinuity.Aliases, as: SessionAliases
  alias CodexPooler.Gateway.Routing.BridgeRing
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.RouteFiltering
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation
  alias CodexPooler.Gateway.Runtime.Dispatch.CandidateDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.FileDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.ReplayPreparation
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Dispatch.UpstreamAttempt
  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame.ValidationClaim

  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame.Capability,
    as: PreparedFrameCapability

  alias CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAuthorizationObservation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionTrace
  alias CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission
  alias CodexPooler.Gateway.Transports.Websocket.ResponseProcessed
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPooler.Repo
  alias CodexPooler.RouteClass

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
  @type replay_intent :: :fresh | :active_reattach | :suspended_replay
  @type authorization_binding :: %{
          required(:api_key_id) => Ecto.UUID.t(),
          required(:api_key_runtime_epoch) => non_neg_integer(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:codex_session_id) => Ecto.UUID.t(),
          required(:model_identifier) => String.t()
        }
  @type replay_intent_result :: %{
          required(:intent) => replay_intent(),
          required(:authorization_binding) => authorization_binding(),
          required(:lifecycle) => map() | nil
        }
  @typep validation_authority ::
           :validate
           | {:prepared_websocket, ValidationClaim.t() | term()}
           | {:prepared_websocket, ValidationClaim.t() | term(), RuntimeAdmissionProof.t() | nil}
  @typedoc false
  @type session_routable_context :: %{
          required(:auth) => auth(),
          required(:endpoint) => String.t(),
          required(:payload) => payload(),
          required(:request_options) => opts(),
          required(:model) => Model.t(),
          required(:candidates) => list(),
          required(:route_state) => RouteState.t(),
          required(:turn_claim) => CodexPooler.Accounting.Request.t() | nil,
          optional(:authorized_correlation_id) => Ecto.UUID.t() | nil
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
           | nil,
           Ecto.UUID.t()
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
    execute_with_validation(auth, endpoint, payload, opts, :validate)
  end

  def execute(_auth, _endpoint, _payload, %RequestOptions{}),
    do: {:error, error(400, "invalid_request", "request body must be a JSON object")}

  defp execute_with_validation(auth, endpoint, payload, %RequestOptions{} = opts, validation)
       when is_map(payload) do
    opts = RequestOptions.capture_api_key_runtime_epoch(opts, auth)

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

          execute_requested_model(
            auth,
            endpoint,
            payload,
            request_options,
            model_name,
            validation
          )

        {:error, %{code: _code} = reason} ->
          {:error, reason}
      end
    end
  end

  defp image_generation_permission_denied?(
         %{pool: pool},
         %RequestOptions{
           payload_context: %{image_generation_permission_required?: permission_required?}
         }
       )
       when permission_required? == true,
       do: not PoolRouting.allow_image_generation?(pool)

  defp image_generation_permission_denied?(_auth, %RequestOptions{}), do: false

  defp execute_requested_model(
         auth,
         endpoint,
         payload,
         request_options,
         model_name,
         validation
       ) do
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
              effective_model_name,
              validation
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

  @spec execute_effective_model(
          auth(),
          String.t(),
          payload(),
          opts(),
          String.t(),
          validation_authority()
        ) ::
          {:ok, gateway_result()} | {:error, gateway_error()}
  defp execute_effective_model(
         auth,
         endpoint,
         payload,
         request_options,
         effective_model_name,
         validation
       ) do
    case visible_model_context(auth.pool, effective_model_name, endpoint, request_options) do
      %{visible_model: %Model{} = model} = visible_model_data ->
        execute_visible_model(
          auth,
          endpoint,
          payload,
          request_options,
          model,
          visible_model_data,
          validation
        )

      nil ->
        reason = error(400, "invalid_model", "model is not available for this pool", "model")

        Denials.log_gateway(denial_context(auth, nil, reason, endpoint, payload, request_options))
    end
  end

  defp execute_visible_model(
         auth,
         endpoint,
         payload,
         request_options,
         model,
         visible_model_data,
         validation
       ) do
    replay_proof = runtime_admission_proof(validation)

    if native_replay_execution?(request_options, replay_proof) do
      execute_replay_visible_model(
        auth,
        endpoint,
        payload,
        request_options,
        model,
        replay_proof
      )
    else
      execute_fresh_visible_model(
        auth,
        endpoint,
        payload,
        request_options,
        model,
        visible_model_data,
        validation
      )
    end
  end

  defp execute_fresh_visible_model(
         auth,
         endpoint,
         payload,
         request_options,
         model,
         visible_model_data,
         validation
       ) do
    case PreDispatch.prepare(
           auth,
           endpoint,
           payload,
           request_options,
           model,
           visible_model_data,
           validation
         ) do
      {:ok, prepared} ->
        case claim_explicit_websocket_turn(
               auth,
               model,
               payload,
               endpoint,
               prepared.request_options,
               prepared.route_state,
               runtime_admission_proof(validation)
             ) do
          {:ok, turn_claim, authorized_correlation_id} ->
            execute_session_routable_model(%{
              auth: auth,
              endpoint: endpoint,
              payload: payload,
              request_options: prepared.request_options,
              model: model,
              candidates: prepared.candidates,
              route_state: prepared.route_state,
              turn_claim: turn_claim,
              authorized_correlation_id: authorized_correlation_id
            })

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

  defp native_replay_execution?(
         %RequestOptions{runtime: %{native_replay_binding: %NativeReplayAdmission.Binding{}}},
         %RuntimeAdmissionProof{kind: :native_replay}
       ),
       do: true

  defp native_replay_execution?(%RequestOptions{}, _proof), do: false

  defp execute_replay_visible_model(
         auth,
         endpoint,
         payload,
         %RequestOptions{} = request_options,
         %Model{} = model,
         %RuntimeAdmissionProof{kind: :native_replay}
       ) do
    with lifecycle when is_map(lifecycle) <- request_options.runtime.replay_lifecycle_binding,
         {:ok, replay} <- Accounting.request_replay_dispatch_lifecycle(lifecycle),
         true <-
           replay.request.model_id == model.id and replay.request.pool_id == auth.pool.id and
             replay.request.api_key_id == auth.api_key.id and
             replay.request.endpoint == endpoint,
         identity when not is_nil(identity) <-
           CodexPooler.Upstreams.get_upstream_identity(replay.attempt.upstream_identity_id),
         %Accounting.Attempt{request_id: original_request_id} = original_attempt <-
           Repo.get(Accounting.Attempt, replay.entitlement.eligible_attempt_id),
         true <- original_request_id == replay.request.id,
         {:ok, request_options, routing_settings} <-
           ReplayPreparation.restore(request_options, original_attempt.response_metadata) do
      dispatch_replay_candidate(
        auth,
        endpoint,
        payload,
        model,
        request_options,
        Map.put(replay, :routing_settings, routing_settings),
        identity
      )
    else
      _failure -> {:error, duplicate_turn_error()}
    end
  end

  defp execute_session_routable_model(context),
    do: execute_session_routable_model(context, &reserve_and_start_turn/8)

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
      when is_list(candidates) and is_function(reserve_and_start_turn, 8) do
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
         } = context,
         reserve_and_start_turn
       )
       when is_list(candidates) and is_function(reserve_and_start_turn, 8) do
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
               turn_claim,
               Map.get(context, :authorized_correlation_id)
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
        clear_native_compaction_admission(request_options)
        {:error, reason}

      {:error, {:reset_probe_scope_mismatch, reason}} ->
        clear_native_compaction_admission(request_options)

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
        clear_native_compaction_admission(request_options)

        Denials.log_gateway(
          denial_context(auth, model, reason, endpoint, payload, request_options),
          turn_claim
        )

      {:error, reason} ->
        clear_native_compaction_admission(request_options)
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

  defp clear_native_compaction_admission(%RequestOptions{} = request_options) do
    _result = RequestOptions.clear_native_compaction_admission(request_options)
    :ok
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
    with {:ok, prepared} <- prepare_websocket_response(raw_payload, opts, push_frame),
         {:ok, result} <- execute_prepared_websocket_response(auth, prepared, true) do
      WebsocketCodec.deliver_result(result, push_frame)
    end
  end

  def execute_websocket_response(_auth, _raw_payload, _opts, _push_frame) do
    {:error, error(400, "invalid_request", "websocket message must be a text JSON frame")}
  end

  @type socket_completion_source :: :local_complete | :owner_completion_pending

  @spec prepare_websocket_response(binary(), opts(), (binary() -> any())) ::
          {:ok, PreparedWebsocketFrame.t()} | {:error, gateway_error()}
  def prepare_websocket_response(raw_payload, %RequestOptions{} = opts, push_frame),
    do: WebsocketCodec.prepare_frame(raw_payload, opts, push_frame)

  @spec prepare_replay_intent(auth(), PreparedWebsocketFrame.t()) ::
          {:ok, replay_intent_result()} | {:error, gateway_error() | term()}
  def prepare_replay_intent(auth, %PreparedWebsocketFrame{} = prepared) do
    with :ok <- validate_replay_prepared_frame(prepared),
         {:ok, replay_context} <- replay_preflight_context(auth, prepared) do
      prepare_replay_intent_transaction(replay_context)
    end
  end

  def prepare_replay_intent(_auth, _prepared),
    do: {:error, error(400, "invalid_request", "prepared websocket frame provenance is invalid")}

  defp validate_replay_prepared_frame(%PreparedWebsocketFrame{} = prepared) do
    case WebsocketCodec.validate_prepared_frame(prepared) do
      :ok ->
        :ok

      {:error, :consumed} ->
        {:error,
         error(409, "prepared_frame_consumed", "prepared websocket frame was already consumed")}

      {:error, :invalid} ->
        {:error, error(400, "invalid_request", "prepared websocket frame provenance is invalid")}
    end
  end

  defp replay_preflight_context(
         %{api_key: %{id: api_key_id}, pool: %{id: pool_id}} = auth,
         %PreparedWebsocketFrame{
           variant: :native_response_create,
           payload: payload,
           semantic_turn_key: semantic_turn_digest,
           replay_claim_digest: replay_claim_digest,
           request_options:
             %RequestOptions{
               continuity: %{codex_session: %CodexSession{id: codex_session_id}},
               runtime: %{api_key_runtime_epoch: api_key_runtime_epoch}
             } = request_options
         } = prepared
       )
       when is_binary(api_key_id) and is_binary(pool_id) and is_binary(codex_session_id) and
              is_integer(api_key_runtime_epoch) and api_key_runtime_epoch >= 0 and
              is_binary(semantic_turn_digest) and byte_size(semantic_turn_digest) == 32 and
              is_binary(replay_claim_digest) and byte_size(replay_claim_digest) == 32 do
    with {:ok, requested_model} <- requested_model(payload) do
      {:ok,
       %{
         auth: auth,
         session: request_options.continuity.codex_session,
         api_key_runtime_epoch: api_key_runtime_epoch,
         endpoint: prepared.endpoint,
         request_options: request_options,
         requested_model: requested_model,
         semantic_turn_digest: semantic_turn_digest,
         replay_claim_digest: replay_claim_digest
       }}
    end
  end

  defp replay_preflight_context(_auth, %PreparedWebsocketFrame{}),
    do: {:error, duplicate_turn_error()}

  defp prepare_replay_intent_transaction(context) do
    Repo.transaction(fn ->
      locked_session = PersistenceSessionContinuity.lock_codex_session_for_turn(context.session)

      with :ok <- validate_replay_session_binding(locked_session, context.auth),
           {:ok, authorization} <-
             Access.authorize_api_key_runtime_turn(
               context.auth.api_key.id,
               context.api_key_runtime_epoch
             ),
           :ok <- validate_replay_api_key_pool(authorization.api_key, locked_session),
           {:ok, pool} <- load_active_replay_pool(locked_session.pool_id),
           {:ok, model} <- authorize_replay_model(authorization.api_key, pool, context) do
        classify_replay_intent(locked_session, authorization, model, context)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify_replay_intent(locked_session, authorization, model, context) do
    authorization_binding = replay_authorization_binding(locked_session, authorization, model)

    preflight = %{
      codex_session_id: locked_session.id,
      api_key_id: authorization_binding.api_key_id,
      api_key_runtime_epoch: authorization_binding.api_key_runtime_epoch,
      pool_id: authorization_binding.pool_id,
      model_id: model.id,
      model_identifier: authorization_binding.model_identifier,
      semantic_turn_digest: context.semantic_turn_digest,
      replay_claim_digest: context.replay_claim_digest
    }

    case Accounting.replay_preflight_snapshot(preflight) do
      :none ->
        replay_intent_result(:fresh, authorization_binding, nil)

      {:active_generation_zero, lifecycle} ->
        replay_intent_result(:active_reattach, authorization_binding, lifecycle)

      {:armed_generation_one, lifecycle} ->
        replay_intent_result(:suspended_replay, authorization_binding, lifecycle)

      {:error, _reason} ->
        Repo.rollback(duplicate_turn_error())
    end
  end

  defp validate_replay_session_binding(
         %CodexSession{pool_id: pool_id, api_key_id: api_key_id} = session,
         %{pool: %{id: pool_id}, api_key: %{id: api_key_id}}
       ) do
    if CodexSession.reconnectable?(session), do: :ok, else: {:error, duplicate_turn_error()}
  end

  defp validate_replay_session_binding(%CodexSession{}, _auth),
    do: {:error, duplicate_turn_error()}

  defp validate_replay_api_key_pool(
         %{pool_id: pool_id},
         %CodexSession{pool_id: pool_id}
       ),
       do: :ok

  defp validate_replay_api_key_pool(_api_key, %CodexSession{}),
    do: {:error, duplicate_turn_error()}

  defp load_active_replay_pool(pool_id) do
    case Repo.get(Pool, pool_id) do
      %Pool{status: "active"} = pool -> {:ok, pool}
      %Pool{} -> {:error, duplicate_turn_error()}
      nil -> {:error, duplicate_turn_error()}
    end
  end

  defp authorize_replay_model(api_key, pool, context) do
    with {:ok, policy} <- Access.normalize_api_key_policy(api_key),
         {:ok, effective_model} <-
           effective_model_name(
             policy,
             context.requested_model,
             context.endpoint,
             context.request_options
           ),
         %Model{} = model <- Catalog.get_model_by_exposed_id(pool, effective_model),
         true <- model.status == "active",
         {:ok, _policy} <-
           Access.authorize_api_key_policy(policy, %{model_identifier: model.exposed_model_id}) do
      {:ok, model}
    else
      nil ->
        {:error, error(400, "invalid_model", "model is not available for this pool", "model")}

      false ->
        {:error, error(400, "invalid_model", "model is not available for this pool", "model")}

      {:error, %{code: _code} = reason} ->
        {:error, reason}

      {:error, _reason} ->
        {:error, error(403, "model_not_allowed", "api key is not allowed to use this model")}
    end
  end

  defp replay_authorization_binding(session, authorization, model) do
    %{
      api_key_id: authorization.api_key.id,
      api_key_runtime_epoch: authorization.runtime_revocation_epoch,
      pool_id: session.pool_id,
      codex_session_id: session.id,
      model_identifier: model.exposed_model_id
    }
  end

  defp replay_intent_result(intent, authorization_binding, lifecycle) do
    %{intent: intent, authorization_binding: authorization_binding, lifecycle: lifecycle}
  end

  @spec execute_prepared_websocket_response(
          auth(),
          PreparedWebsocketFrame.t(),
          boolean()
        ) :: {:ok, gateway_result()} | {:error, gateway_error()}
  def execute_prepared_websocket_response(
        auth,
        prepared,
        compact_admission? \\ true
      )

  def execute_prepared_websocket_response(
        auth,
        %PreparedWebsocketFrame{} = prepared,
        compact_admission?
      ) do
    execute_prepared_websocket_response(auth, prepared, compact_admission?, & &1.())
  end

  @spec execute_prepared_websocket_response(
          auth(),
          PreparedWebsocketFrame.t(),
          boolean(),
          ((-> {:ok, gateway_result()} | {:error, gateway_error()}) ->
             {:ok, gateway_result()} | {:error, gateway_error()})
        ) :: {:ok, gateway_result()} | {:error, gateway_error()}
  def execute_prepared_websocket_response(
        auth,
        %PreparedWebsocketFrame{} = prepared,
        compact_admission?,
        execution_wrapper
      )
      when is_function(execution_wrapper, 1) do
    case WebsocketCodec.consume_prepared_frame(prepared) do
      {:ok, runtime_admission_proof} ->
        execution_wrapper.(fn ->
          do_execute_prepared_websocket_response(
            auth,
            prepared,
            compact_admission?,
            runtime_admission_proof
          )
        end)

      {:error, :consumed} ->
        {:error,
         error(409, "prepared_frame_consumed", "prepared websocket frame was already consumed")}

      {:error, :invalid} ->
        {:error, error(400, "invalid_request", "prepared websocket frame provenance is invalid")}
    end
  end

  defp do_execute_prepared_websocket_response(
         auth,
         %PreparedWebsocketFrame{variant: :response_processed} = prepared,
         _compact_admission?,
         _runtime_admission_proof
       ) do
    ResponseProcessed.handle_prepared(auth, prepared.payload, prepared.request_options)
  end

  defp do_execute_prepared_websocket_response(
         _auth,
         %PreparedWebsocketFrame{variant: :prewarm},
         _compact_admission?,
         _runtime_admission_proof
       ),
       do: {:ok, WebsocketCodec.warmup_result()}

  defp do_execute_prepared_websocket_response(
         auth,
         %PreparedWebsocketFrame{variant: variant} = prepared,
         compact_admission?,
         runtime_admission_proof
       )
       when variant in [:native_response_create, :public_response_create] do
    prepared
    |> execute_prepared_response_create(auth, compact_admission?, runtime_admission_proof)
    |> adapt_websocket_result(prepared)
  end

  @spec execute_websocket_response_for_socket(
          auth(),
          binary(),
          opts(),
          (binary() -> any())
        ) ::
          {:socket_response_result, socket_completion_source(), :ok | {:error, gateway_error()}}
  def execute_websocket_response_for_socket(
        auth,
        raw_payload,
        %RequestOptions{} = opts,
        push_frame
      )
      when is_binary(raw_payload) and is_function(push_frame, 1) do
    case prepare_websocket_response(raw_payload, opts, push_frame) do
      {:ok, prepared} ->
        execute_prepared_websocket_response_for_socket(auth, prepared, push_frame)

      {:error, reason} ->
        {:socket_response_result, :local_complete, {:error, reason}}
    end
  end

  def execute_websocket_response_for_socket(_auth, _raw_payload, _opts, _push_frame) do
    {:socket_response_result, :local_complete,
     {:error, error(400, "invalid_request", "websocket message must be a text JSON frame")}}
  end

  @spec execute_prepared_websocket_response_for_socket(
          auth(),
          PreparedWebsocketFrame.t(),
          (binary() -> any())
        ) ::
          {:socket_response_result, socket_completion_source(), :ok | {:error, gateway_error()}}
  def execute_prepared_websocket_response_for_socket(
        auth,
        %PreparedWebsocketFrame{} = prepared,
        push_frame
      )
      when is_function(push_frame, 1) do
    execute_prepared_websocket_response_for_socket(auth, prepared, push_frame, & &1.())
  end

  @spec execute_prepared_websocket_response_for_socket(
          auth(),
          PreparedWebsocketFrame.t(),
          (binary() -> any()),
          ((-> {:ok, gateway_result()} | {:error, gateway_error()}) ->
             {:ok, gateway_result()} | {:error, gateway_error()})
        ) ::
          {:socket_response_result, socket_completion_source(), :ok | {:error, gateway_error()}}
  def execute_prepared_websocket_response_for_socket(
        auth,
        %PreparedWebsocketFrame{} = prepared,
        push_frame,
        execution_wrapper
      )
      when is_function(push_frame, 1) and is_function(execution_wrapper, 1) do
    submission_ref = make_ref()
    caller = self()

    prepared =
      update_prepared_request_options(prepared, fn request_options ->
        RequestOptions.put_transport(
          request_options,
          websocket_writer: WebsocketCodec.response_writer(request_options, push_frame),
          websocket_owner_submission_observer: fn ->
            send(caller, {:websocket_owner_request_submitted, submission_ref})
          end
        )
      end)

    result =
      with {:ok, result} <-
             execute_prepared_websocket_response(auth, prepared, true, execution_wrapper) do
        WebsocketCodec.deliver_result(result, push_frame)
      end

    completion_source =
      receive do
        {:websocket_owner_request_submitted, ^submission_ref} -> :owner_completion_pending
      after
        0 -> :local_complete
      end

    {:socket_response_result, completion_source, result}
  end

  defp update_prepared_request_options(%PreparedWebsocketFrame{} = prepared, update)
       when is_function(update, 1),
       do: %{prepared | request_options: update.(prepared.request_options)}

  defp adapt_websocket_result(result, %{result_adapter: result_adapter})
       when is_function(result_adapter, 1),
       do: result_adapter.(result)

  defp adapt_websocket_result(result, _coerced), do: result

  defp execute_prepared_response_create(
         %PreparedWebsocketFrame{
           request_options: %{transport: %{route_class: route_class}}
         } = prepared,
         auth,
         true,
         runtime_admission_proof
       ) do
    if route_class == RouteClass.proxy_compact() do
      Admission.run(route_class, websocket_admission_metadata(prepared), fn ->
        execute_prevalidated(auth, prepared, runtime_admission_proof)
      end)
    else
      execute_prevalidated(auth, prepared, runtime_admission_proof)
    end
  end

  defp execute_prepared_response_create(prepared, auth, _compact_admission?, runtime_proof) do
    execute_prevalidated(auth, prepared, runtime_proof)
  end

  defp execute_prevalidated(auth, %PreparedWebsocketFrame{} = prepared, runtime_proof) do
    request_options =
      case runtime_proof do
        %RuntimeAdmissionProof{kind: :native_replay} = proof ->
          RequestOptions.put_runtime_context(prepared.request_options, native_replay_proof: proof)

        _proof ->
          prepared.request_options
      end

    execute_with_validation(
      auth,
      prepared.endpoint,
      prepared.payload,
      request_options,
      {:prepared_websocket, prepared.provenance.validation, runtime_proof}
    )
  end

  defp websocket_admission_metadata(%{endpoint: endpoint, request_options: request_options}) do
    %{
      request_id: request_options.request_metadata.request_id,
      endpoint: endpoint,
      transport: request_options.transport.transport
    }
  end

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
    dispatch_fresh_candidates(
      auth,
      endpoint,
      payload,
      model,
      reserved,
      candidates,
      request_options,
      route_state
    )
  end

  defp dispatch_fresh_candidates(
         auth,
         endpoint,
         payload,
         model,
         reserved,
         candidates,
         request_options,
         route_state
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

  defp dispatch_replay_candidate(
         auth,
         endpoint,
         payload,
         model,
         request_options,
         replay,
         identity
       ) do
    route_state =
      RouteState.new(%{
        visible_model: model,
        candidates: [{replay.assignment, identity}],
        routing_settings: replay.routing_settings
      })

    context = %SelectedCandidateContext{
      auth: auth,
      endpoint: endpoint,
      payload: payload,
      model: model,
      reserved: %{
        request: replay.request,
        reservation: replay.reservation,
        codex_turn: replay.codex_turn
      },
      request_options: request_options,
      route_state: route_state,
      route_plan:
        replay_route_plan(
          auth,
          model,
          {replay.assignment, identity},
          request_options,
          replay.request
        ),
      assignment: replay.assignment,
      identity: identity,
      index: 0,
      retry_count: 0,
      allow_retry?: false,
      routing_attempt_metadata: %{},
      route_class: request_options.transport.route_class,
      attempt: replay.attempt,
      started: System.monotonic_time(:millisecond)
    }

    CandidateDispatch.dispatch_selected(context, &dispatch_decrypted_candidate/1)
  end

  @spec replay_route_plan(
          auth(),
          Model.t(),
          BridgeRing.candidate(),
          RequestOptions.t(),
          Accounting.Request.t()
        ) :: BridgeRing.route_plan()
  defp replay_route_plan(auth, model, {assignment, _identity} = candidate, options, request) do
    routing_metadata = Map.get(request.request_metadata || %{}, "routing", %{})

    %{
      strategy: Map.get(routing_metadata, "strategy", "bridge_ring"),
      bridge_ring_size: 1,
      candidates: [candidate],
      affinity: %{
        enabled?: false,
        kind: nil,
        key_hash: nil,
        seed: request.correlation_id,
        row: nil,
        status: "disabled",
        fallback_reason: nil,
        pool_id: auth.pool.id,
        api_key_id: auth.api_key.id,
        model_identifier: model.exposed_model_id
      },
      demotions: %{},
      locality: %{},
      model_serving_mode_snapshot: RequestOptions.model_serving_mode_snapshot(options),
      request_metadata: routing_metadata,
      selected_assignment_id: assignment.id
    }
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
         _auth,
         _model,
         _payload,
         _endpoint,
         %RequestOptions{
           runtime: %{native_replay_binding: %NativeReplayAdmission.Binding{} = binding}
         },
         %RouteState{},
         %RuntimeAdmissionProof{} = proof
       ) do
    with {:ok, expected_digest} <- NativeReplayAdmission.binding_digest(binding),
         true <- proof.kind == :native_replay and proof.binding_digest == expected_digest do
      {:ok, nil, nil}
    else
      _invalid -> {:error, invalid_runtime_admission_error()}
    end
  end

  defp claim_explicit_websocket_turn(
         _auth,
         _model,
         _payload,
         _endpoint,
         %RequestOptions{} = request_options,
         %RouteState{},
         %RuntimeAdmissionProof{} = proof
       ) do
    with {:ok, expected_digest} <-
           RequestOptions.native_compaction_admission_digest(
             request_options,
             :native_response_create
           ),
         {:ok, correlation_id} <-
           PreparedFrameCapability.redeem_runtime_admission(proof, expected_digest) do
      :ok = emit_runtime_proof_redeemed(request_options)
      {:ok, nil, correlation_id}
    else
      _invalid -> {:error, invalid_runtime_admission_error()}
    end
  end

  defp claim_explicit_websocket_turn(
         _auth,
         _model,
         _payload,
         _endpoint,
         %RequestOptions{
           native_compaction_admission: %RequestOptions.NativeCompactionAdmission{}
         },
         %RouteState{},
         nil
       ),
       do: {:error, invalid_runtime_admission_error()}

  defp claim_explicit_websocket_turn(
         auth,
         model,
         payload,
         endpoint,
         %RequestOptions{
           transport: %{transport: "websocket"},
           continuity: %{request_claim_key: request_claim_key}
         } = request_options,
         %RouteState{} = route_state,
         nil
       )
       when is_binary(request_claim_key) do
    attrs = AccountingReservation.attrs(auth, payload, endpoint, request_options, route_state)

    case Accounting.claim_websocket_turn(auth, model, attrs) do
      {:ok, %{request: request}} -> {:ok, request, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_explicit_websocket_turn(
         _auth,
         _model,
         _payload,
         _endpoint,
         %RequestOptions{},
         %RouteState{},
         nil
       ),
       do: {:ok, nil, nil}

  defp runtime_admission_proof({:prepared_websocket, _token, runtime_admission_proof}),
    do: runtime_admission_proof

  defp runtime_admission_proof(_validation), do: nil

  defp invalid_runtime_admission_error do
    error(409, "invalid_runtime_admission", "websocket runtime admission proof is invalid")
  end

  defp emit_runtime_proof_redeemed(%RequestOptions{} = request_options) do
    case RequestOptions.native_compaction_admission(request_options) do
      {:ok, capability, _owner, _lifecycle} ->
        :ok =
          NativeCompactionAuthorizationObservation.emit_capability(
            capability,
            :runtime_proof_redeemed
          )

        _trace =
          NativeCompactionTrace.emit_capability(:runtime_proof_redeemed, capability, %{
            stage: :runtime_proof_redeemed
          })

        :ok

      :none ->
        :ok
    end
  end

  defp reserve(
         auth,
         model,
         payload,
         endpoint,
         %RequestOptions{} = request_options,
         %RouteState{} = route_state,
         turn_claim,
         authorized_correlation_id
       ) do
    attrs =
      auth
      |> AccountingReservation.attrs(
        payload,
        endpoint,
        request_options,
        route_state,
        authorized_correlation_id
      )
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
         turn_claim,
         authorized_correlation_id
       ) do
    maybe_test_runtime_authorization_barrier(:reserve, :before)

    Repo.transaction(fn ->
      request_options = lock_codex_session_before_reservation(request_options)

      with {:ok, reserved} <-
             reserve(
               auth,
               model,
               payload,
               endpoint,
               request_options,
               route_state,
               turn_claim,
               authorized_correlation_id
             ),
           {:ok, reserved} <- SessionContinuity.start_turn(reserved, request_options),
           :ok <-
             register_final_window_alias(
               auth,
               payload,
               request_options,
               authorized_correlation_id
             ),
           :ok <-
             RequestOptions.mark_native_compaction_accounting_started(
               request_options,
               System.system_time(:millisecond)
             ) do
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

  defp register_final_window_alias(auth, payload, request_options, authorized_correlation_id)
       when is_binary(authorized_correlation_id) do
    case ReplayPreparation.final_window_alias_hash(request_options, payload) do
      {:ok, hash} ->
        SessionAliases.register_session_header_hash(
          request_options.continuity.codex_session,
          auth,
          hash,
          DateTime.utc_now() |> DateTime.truncate(:microsecond)
        )

      :none ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp register_final_window_alias(_auth, _payload, _request_options, _correlation), do: :ok

  defp lock_codex_session_before_reservation(
         %RequestOptions{continuity: %{codex_session: %CodexSession{} = session}} =
           request_options
       ) do
    locked_session = PersistenceSessionContinuity.lock_codex_session_for_turn(session)
    RequestOptions.put_continuity(request_options, codex_session: locked_session)
  end

  defp lock_codex_session_before_reservation(%RequestOptions{} = request_options),
    do: request_options

  defp duplicate_turn_reservation_constraint?(
         %Ecto.ConstraintError{constraint: "requests_correlation_id_uq"},
         %RequestOptions{
           transport: %{transport: "websocket"},
           continuity: %{request_claim_key: request_claim_key}
         }
       )
       when is_binary(request_claim_key),
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

  defp error(status, code, message, param \\ nil, metadata \\ %{}),
    do: Map.merge(%{status: status, code: code, message: message, param: param}, metadata)
end
