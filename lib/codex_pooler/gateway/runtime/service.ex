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
  alias CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata
  alias CodexPooler.Gateway.Payloads.NativeHttpTurnIdentity
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Payloads.TranscriptionPayload
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.SessionContinuity, as: PersistenceSessionContinuity
  alias CodexPooler.Gateway.Persistence.SessionContinuity.Aliases, as: SessionAliases
  alias CodexPooler.Gateway.Persistence.SessionContinuity.OwnerWitness
  alias CodexPooler.Gateway.Routing.BridgeRing
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.ModelMetadata
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
  alias CodexPooler.Gateway.Runtime.DuplicateTurnTelemetry
  alias CodexPooler.Gateway.Runtime.SessionLeaseHeartbeat
  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame.ValidationClaim

  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame.Capability,
    as: PreparedFrameCapability

  alias CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.Websocket.CompactionRetrySubmitHold
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAuthorizationObservation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionTrace
  alias CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission
  alias CodexPooler.Gateway.Transports.Websocket.ResponseProcessed
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Websocket.Adapter
  alias CodexPooler.Gateway.Websocket.DirectCleanup
  alias CodexPooler.Platform.TransientDatabaseError
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{ModelServingMode, ModelServingOverride, Pool}
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPooler.Repo
  alias CodexPooler.RouteClass

  require Logger

  @backend_transcription_model "gpt-4o-transcribe"
  # The key's own refusals of a retry successor's reservation: answered and
  # recorded as the ordinary reservation answers them, never `409 duplicate_turn`
  # (findings#206 row 206-428).
  @retry_claim_policy_refusals [:api_key_concurrency_limit_exceeded, :api_key_policy_limit_exceeded]
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
          required(:lifecycle) => map() | nil,
          optional(:replay_claim_digest) => <<_::256>>
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
          optional(:authorized_correlation_id) => String.t() | nil
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
      {:error, Denials.policy_denial_error(:model_not_allowed)}
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
    opts =
      opts
      |> RequestOptions.capture_api_key_runtime_epoch(auth)
      |> RequestOptions.capture_tenant_scope(auth)

    if image_generation_permission_denied?(auth, opts) do
      {:error,
       Denials.policy_error(
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
            Denials.log_gateway(denial_context(auth, nil, reason, endpoint, payload, request_options))
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

      {:error, %{code: "unsupported_parameter", param: "mask"} = reason} ->
        {:error, reason}

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
    case DirectCleanup.begin(request_options) do
      :ok ->
        try do
          do_execute_fresh_visible_model(
            auth,
            endpoint,
            payload,
            request_options,
            model,
            visible_model_data,
            validation
          )
        after
          DirectCleanup.ready(request_options)
          DirectCleanup.finish(request_options)
        end

      {:error, :cancelled} ->
        {:error, error(499, "client_disconnected", "request cancelled before admission")}

      {:error, :owner_unavailable} ->
        {:error, error(503, "owner_unavailable", "websocket owner admission is unavailable")}

      {:error, :stale_owner} ->
        {:error, error(409, "stale_owner", "websocket owner lease is stale")}
    end
  end

  defp do_execute_fresh_visible_model(
         auth,
         endpoint,
         payload,
         request_options,
         model,
         visible_model_data,
         validation
       ) do
    case before_dispatch("pre_dispatch", fn -> PreDispatch.prepare(auth, endpoint, payload, request_options, model, visible_model_data, validation) end) do
      {:ok, prepared} ->
        case claim_prepared_turn(auth, model, payload, endpoint, prepared, validation) do
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

          {:error, %{code: :duplicate_request} = reason} ->
            websocket_turn_claim_duplicate(prepared.request_options, reason)

          # The claim rolled back; an admitted compaction must not keep the
          # owner waiting for a turn that will not run.
          {:error, %{code: "service_unavailable"} = reason} ->
            clear_native_compaction_admission(prepared.request_options)
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end

      # Not recorded as a denied request: the record needs the database that
      # just failed (findings#206 row 206-368).
      {:error, %{code: code} = reason} when code in ["duplicate_turn", "service_unavailable"] ->
        {:error, reason}

      {:error, %{code: "unsupported_parameter", param: "mask"} = reason} ->
        {:error, reason}

      {:error, %{code: _code} = reason} ->
        log_gateway_denial(denial_context(auth, model, reason, endpoint, payload, request_options))
    end
  end

  defp claim_prepared_turn(auth, model, payload, endpoint, prepared, validation) do
    before_dispatch("turn_claim", fn ->
      claim_explicit_websocket_turn(auth, model, payload, endpoint, prepared.request_options, prepared.route_state, runtime_admission_proof(validation))
    end)
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
        replay
        |> Map.put(:routing_settings, routing_settings)
        |> Map.put(
          :models_etag,
          ReplayPreparation.models_etag(original_attempt.response_metadata)
        ),
        identity
      )
    else
      _failure ->
        log_duplicate_turn(request_options, :replay_lifecycle_mismatch,
          stage: "native_replay_dispatch",
          endpoint: endpoint
        )

        {:error, duplicate_turn_error()}
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
    request_options = context.request_options
    maybe_test_runtime_authorization_barrier(:heartbeat, :before)

    SessionLeaseHeartbeat.run(request_options, fn heartbeat, request_options ->
      context
      |> Map.put(:request_options, request_options)
      |> do_execute_session_routable_model(reserve_and_start_turn)
      |> wrap_deferred_session_lease_stream(heartbeat)
    end)
    |> normalize_session_lease_heartbeat_failure(context)
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
        case DirectCleanup.ready(request_options) do
          :ok ->
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

          {:error, :cancelled} ->
            {:error, error(499, "client_disconnected", "request cancelled before dispatch")}
        end

      {:error, %{accounting_disposition: :zero_work} = reason} ->
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

      # A database failure is not recorded as a denied request: the record
      # needs the database that just failed (findings#206 row 206-358). The
      # turn claim committed before the reservation is released with it, or it
      # fences every resend of this request (findings#206 row 206-331).
      {:error, %{code: code} = reason} when code in ["duplicate_turn", "service_unavailable"] ->
        clear_native_compaction_admission(request_options)
        release_turn_claim(turn_claim)
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

        reject_pre_attempt_failure(
          %{auth: auth, model: model, endpoint: endpoint, payload: payload, request_options: request_options, turn_claim: turn_claim},
          reason
        )
    end
  end

  defp reject_pre_attempt_failure(context, reason) when reason in [:owner_unavailable, :stale_owner],
    do: reject_owner_lease_refusal(context, reason, "reservation")

  defp reject_pre_attempt_failure(context, reason) do
    %{auth: auth, model: model, endpoint: endpoint, payload: payload, request_options: request_options, turn_claim: turn_claim} = context
    reason = AccountingReservation.pre_attempt_failure(reason, request_options)
    reject_claimed_turn(auth, model, reason, endpoint, payload, request_options, turn_claim)
  end

  defp clear_native_compaction_admission(%RequestOptions{} = request_options) do
    case RequestOptions.clear_native_compaction_admission(request_options) do
      :ok -> :ok
      {:error, reason} -> log_compaction_admission_cleanup_failure(reason)
    end
  rescue
    exception -> log_compaction_admission_cleanup_failure(exception.__struct__)
  catch
    kind, _reason -> log_compaction_admission_cleanup_failure(kind)
  end

  defp log_compaction_admission_cleanup_failure(reason) do
    Logger.warning(
      "native compaction reservation cleanup failed " <>
        "reason_code=#{DiagnosticTaxonomy.reason_code(reason) || "unknown"}"
    )
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
      |> RequestOptions.put_payload_context(forced_transcription_model: @backend_transcription_model)

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
  def prepare_websocket_response(raw_payload, %RequestOptions{} = opts, push_frame) do
    with {:ok, prepared} <- WebsocketCodec.prepare_frame(raw_payload, opts, push_frame) do
      before_dispatch("steered_turn_claim", fn -> maybe_rebind_steered_turn_claim(prepared) end)
    end
  end

  # The released client drains user input steered into a running turn into the
  # same turn once a request of it completed. When the connection that
  # delivered that response is gone (or the session fell back to HTTPS) the
  # steer goes out as full history and derives the turn's bare claim, which the
  # turn's opener holds (findings#206 row 206-412). A frame further along the
  # turn than the holder -- more user messages after the same compaction point,
  # or a compaction point the holder did not end on -- cannot be a retry of it,
  # which only appends model output, nor a resend of it with trimmed history,
  # which stands behind it (row 206-423); it takes the steered claim of its own
  # progress, the claim every other form of that steer derives too. A holder
  # that recorded no position, and a frame whose progress its socket could not
  # know, keep the bare claim and today's verdict.
  defp maybe_rebind_steered_turn_claim(%PreparedWebsocketFrame{} = prepared) do
    with {:ok, _progress, steered_claim} <- WebsocketCodec.steered_turn_claim(prepared),
         {_pivot, _user_messages} = position <- Map.get(prepared.request_options.extra, :native_turn_position),
         recorded = Accounting.native_turn_recorded_position(prepared.turn_claim_key),
         true <- Accounting.native_turn_progress_advances?(recorded, position),
         {:ok, rebound} <- WebsocketCodec.rebind_steered_turn_claim(prepared, steered_claim) do
      log_steered_turn_claim_rebound(rebound)
      {:ok, rebound}
    else
      {:error, _reason} -> {:error, prepared_frame_provenance_breach(prepared, "steered_turn_claim")}
      _not_steered -> {:ok, prepared}
    end
  end

  defp log_steered_turn_claim_rebound(%PreparedWebsocketFrame{request_options: request_options}) do
    session = Map.get(request_options.continuity, :codex_session)
    session_id = if is_struct(session, CodexSession), do: session.id
    Logger.info("native websocket steered turn claim rebound codex_session_id=#{session_id} claim_class=steered_continuation")
  end

  @doc """
  The owner's replay preflight for a replay-eligible native frame. A frame
  whose model the key or the Pool refuses is recorded as a refused request
  unless `record_model_denial: false`: a caller that submits the frame to the
  ordinary checks after any refusal here (the queued-frame dequeue) leaves the
  record to those checks, so one refusal is never recorded twice.
  """
  @spec prepare_replay_intent(auth(), PreparedWebsocketFrame.t(), keyword()) ::
          {:ok, replay_intent_result()} | {:error, gateway_error() | term()}
  def prepare_replay_intent(auth, prepared, opts \\ [])

  def prepare_replay_intent(auth, %PreparedWebsocketFrame{} = prepared, opts) when is_list(opts) do
    with :ok <- validate_replay_prepared_frame(prepared),
         {:ok, replay_context} <- replay_preflight_context(auth, prepared) do
      replay_context = Map.put(replay_context, :record_model_denial?, Keyword.get(opts, :record_model_denial, true))
      before_dispatch("replay_intent", fn -> prepare_replay_intent_transaction(replay_context) end)
    end
  end

  def prepare_replay_intent(_auth, _prepared, _opts),
    do: {:error, log_prepared_frame_provenance_breach("replay_intent_shape", :unknown, nil, nil, nil)}

  defp validate_replay_prepared_frame(%PreparedWebsocketFrame{} = prepared) do
    case WebsocketCodec.validate_prepared_frame(prepared) do
      :ok ->
        :ok

      {:error, :consumed} ->
        {:error, error(409, "prepared_frame_consumed", "prepared websocket frame was already consumed")}

      {:error, :invalid} ->
        {:error, prepared_frame_provenance_breach(prepared, "replay_frame_validation")}
    end
  end

  # A prepared frame is minted and verified milliseconds later in the same OS
  # process, so a digest that stops verifying is a gateway invariant breach, not
  # a malformed client request. The client-blamed `400 invalid_request` this
  # replaces was also completely silent — findings#168 could only be traced
  # from the client's local store, because none of the three emit sites logged
  # and the rejection telemetry event is not registered. `request_id`,
  # `codex_session_id`, `endpoint` and `variant` are not in the logger metadata
  # allowlist in `config/config.exs`, so they travel inside the message.
  defp prepared_frame_provenance_breach(%PreparedWebsocketFrame{} = prepared, stage) do
    session = Map.get(prepared.request_options.continuity, :codex_session)
    session_id = if is_struct(session, CodexSession), do: session.id

    log_prepared_frame_provenance_breach(
      stage,
      prepared.variant,
      prepared.request_options.request_metadata.request_id,
      session_id,
      prepared.endpoint
    )
  end

  defp log_prepared_frame_provenance_breach(stage, variant, request_id, session_id, endpoint) do
    Logger.error(fn ->
      "prepared websocket frame provenance invalid " <>
        "stage=#{stage} " <>
        "frame_variant=#{variant} " <>
        "request_id=#{DiagnosticTaxonomy.safe_correlator(request_id)} " <>
        "codex_session_id=#{DiagnosticTaxonomy.safe_correlator(session_id)} " <>
        "endpoint=#{DiagnosticTaxonomy.safe_correlator(endpoint)} transport=websocket"
    end)

    error(500, "server_error", "prepared websocket frame provenance could not be verified")
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
         payload: payload,
         request_options: request_options,
         requested_model: requested_model,
         semantic_turn_claim_key: prepared.turn_claim_key,
         semantic_turn_digest: semantic_turn_digest,
         replay_claim_digest: replay_claim_digest,
         replay_claim_alternates: witness_alternates(prepared.native_client_retry_witness),
         grown_resend_candidates: witness_grown(prepared.native_client_retry_witness)
       }}
    end
  end

  # A replay-eligible frame always carries its session, runtime epoch and both
  # digests, and the socket's auth always names its key and Pool, so a frame
  # that reaches here is a gateway invariant breach rather than a resend of a
  # recorded turn: it was never matched to one (findings#225, row 225-83).
  defp replay_preflight_context(_auth, %PreparedWebsocketFrame{request_options: request_options}) do
    public_error = error(500, "server_error", "websocket replay context could not be established")
    log_pre_classification_refusal(request_options, nil, :invalid_replay_context, public_error)

    {:error, public_error}
  end

  defp witness_alternates(%{alternates: alternates}) when is_list(alternates), do: alternates
  defp witness_alternates(_witness), do: []

  defp witness_grown(%{grown: grown}) when is_list(grown), do: grown
  defp witness_grown(_witness), do: []

  defp prepare_replay_intent_transaction(context) do
    Repo.transaction(fn ->
      locked_session = PersistenceSessionContinuity.lock_codex_session_for_turn(context.session)

      with :ok <- validate_replay_session_binding(locked_session, context.auth),
           {:ok, authorization} <-
             Access.authorize_api_key_runtime_turn_for_read(
               context.auth.api_key.id,
               context.api_key_runtime_epoch
             ),
           :ok <- validate_replay_api_key_pool(authorization.api_key, locked_session),
           {:ok, pool} <- load_active_replay_pool(locked_session.pool_id, authorization),
           {:ok, model} <- authorize_replay_model(authorization.api_key, pool, context) do
        classify_replay_intent(locked_session, authorization, model, context)
      else
        {:error, {:pre_classification_refusal, reason, public_error}} ->
          refuse_replay_before_classification(context, reason, public_error)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, {:replay_model_denial, denial}} -> refuse_replay_model(context, denial)
      {:error, reason} -> {:error, reason}
    end
  end

  # The key's policy or the Pool's catalog refuses the frame's model before it
  # is matched to any recorded turn, so it refuses a brand-new turn: recorded
  # and logged as the fresh path records the same refusal, once the preflight
  # transaction has rolled back, so the record outlives it. Forwarding on, the
  # released client's turn (its turn metadata makes the frame replay-eligible)
  # met this refusal here and left no row and no log line (production rev 50,
  # Codex 0.156.1).
  #
  # The record carries the routing the fresh path has put on its request
  # options by the same refusal: the requested model always, and once the
  # key's policy resolved it, the effective model and the policy (the source
  # of `enforced_model`). Without them the preflight's row read as a refusal
  # of the requested model when the key had substituted an enforced one
  # (findings#206 row 206-535).
  defp refuse_replay_model(%{record_model_denial?: false}, {:policy, _model, reason, _routing}),
    do: {:error, Denials.policy_denial_error(reason)}

  defp refuse_replay_model(%{record_model_denial?: false}, {:gateway, _model, reason, _routing}),
    do: {:error, reason}

  defp refuse_replay_model(context, {kind, model, reason, routing}) do
    denial_context = %Denials.Context{
      auth: context.auth,
      model: model,
      reason: reason,
      endpoint: context.endpoint,
      payload: context.payload,
      opts: RequestOptions.put_routing(context.request_options, [requested_model: context.requested_model] ++ routing)
    }

    {:error, public_error} =
      case kind do
        :policy -> Denials.log_policy(denial_context)
        :gateway -> Denials.log_gateway(denial_context)
      end

    log_pre_classification_refusal(context.request_options, context.session, public_error.code, public_error)
    {:error, public_error}
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
      replay_claim_digest: context.replay_claim_digest,
      replay_claim_alternates: context.replay_claim_alternates
    }

    if final_native_compaction_admission?(context.request_options) do
      replay_intent_result(:fresh, authorization_binding, nil)
    else
      classify_replay_preflight(
        preflight,
        locked_session,
        authorization,
        model,
        context,
        authorization_binding
      )
    end
  end

  defp classify_replay_preflight(
         preflight,
         locked_session,
         authorization,
         model,
         context,
         authorization_binding
       ) do
    case Accounting.replay_preflight_snapshot(preflight) do
      :none ->
        classify_client_retry_intent(
          locked_session,
          authorization.api_key,
          model,
          context,
          authorization_binding
        )

      {:active_generation_zero, lifecycle} ->
        replay_intent_result(:active_reattach, authorization_binding, lifecycle)

      {:armed_generation_one, lifecycle} ->
        replay_intent_result(:suspended_replay, authorization_binding, lifecycle)

      {:error, :lifecycle_conflict} ->
        # An unattempted compaction successor cannot be reattached or replayed.
        # Only its native full-history retry may reach the owner-idle check and
        # the transactional successor claim, which validates exact reclamation.
        if native_full_history_compaction?(context.endpoint, context.request_options) do
          classify_native_compaction_lifecycle_conflict(
            locked_session,
            authorization.api_key,
            model,
            context,
            authorization_binding
          )
        else
          reject_replay_intent(context, locked_session, :lifecycle_conflict)
        end

      {:error, reason} ->
        reject_replay_intent(context, locked_session, reason)
    end
  end

  defp final_native_compaction_admission?(%RequestOptions{
         native_compaction_admission: %RequestOptions.NativeCompactionAdmission{capability: %{phase: :final}} = admission
       }),
       do: RequestOptions.NativeCompactionAdmission.valid?(admission)

  defp final_native_compaction_admission?(%RequestOptions{}), do: false

  defp classify_native_compaction_lifecycle_conflict(
         session,
         api_key,
         model,
         context,
         authorization_binding
       ) do
    case native_compaction_retry_preflight(session, api_key, model, context) do
      {:ok, lifecycle} ->
        replay_intent_result(:fresh, authorization_binding, lifecycle)

      {:error, :successor_claimed} ->
        replay_intent_result(:fresh, authorization_binding, %{
          replay_generation: 0,
          compaction_successor_pending?: true
        })

      :none ->
        reject_replay_intent(context, session, :missing_witness)

      {:error, reason} ->
        reject_replay_intent(context, session, reason)
    end
  end

  defp classify_client_retry_intent(
         session,
         api_key,
         model,
         %{
           endpoint: "/backend-api/codex/responses/compact",
           requested_model: requested_model,
           semantic_turn_digest: semantic_turn_digest,
           replay_claim_digest: replay_claim_digest,
           request_options:
             %RequestOptions{
               payload_context: %{
                 compaction_trigger_bridge?: true,
                 compaction_result_mode: :native_websocket,
                 native_codex_turn_metadata: %NativeCodexTurnMetadata{request_kind: :compaction}
               }
             } = options
         } = context,
         authorization_binding
       ) do
    cond do
      valid_incremental_compaction_admission?(options) ->
        replay_intent_result(:fresh, authorization_binding, nil)

      native_full_history_compaction_preflight?(options) ->
        case native_compaction_retry_preflight(session, api_key, model, %{
               requested_model: requested_model,
               semantic_turn_digest: semantic_turn_digest,
               replay_claim_digest: replay_claim_digest,
               request_options: options
             }) do
          :none -> replay_intent_result(:fresh, authorization_binding, nil)
          {:ok, lifecycle} -> replay_intent_result(:fresh, authorization_binding, lifecycle)
          {:error, reason} -> reject_replay_intent(context, session, reason)
        end

      true ->
        reject_replay_intent(context, session, :missing_witness)
    end
  end

  defp classify_client_retry_intent(
         _session,
         _api_key,
         _model,
         %{
           semantic_turn_claim_key: semantic_claim,
           request_options: %{continuity: %{request_claim_key: request_claim}}
         },
         authorization_binding
       )
       when is_binary(request_claim) and is_binary(semantic_claim) and
              request_claim != semantic_claim do
    replay_intent_result(:fresh, authorization_binding, nil)
  end

  defp classify_client_retry_intent(session, api_key, model, context, authorization_binding) do
    input = %{
      endpoint: context.endpoint,
      requested_model: context.requested_model,
      runtime_revocation_epoch: authorization_binding.api_key_runtime_epoch,
      semantic_turn_digest: context.semantic_turn_digest,
      original_request_claim: context.request_options.continuity.request_claim_key,
      replay_claim_digest: context.replay_claim_digest,
      replay_claim_alternates: context.replay_claim_alternates,
      grown_resend_candidates: Map.get(context, :grown_resend_candidates, []),
      anchor_present?: not is_nil(context.request_options.continuity.previous_response_id)
    }

    case Accounting.client_retry_preflight_snapshot(session, api_key, model, input) do
      :none -> replay_intent_result(:fresh, authorization_binding, nil)
      {:ok, lifecycle} -> replay_intent_result(:fresh, authorization_binding, lifecycle)
      {:error, :terminal_predecessor} -> reject_terminal_predecessor(context, session, input)
      {:error, reason} -> reject_replay_intent(context, session, reason)
    end
  end

  # Owner forwarding off: the resend meets the turn claim instead of the owner
  # replay preflight, with the same rule (findings#254 row 254-100).
  defp websocket_turn_claim_duplicate(%RequestOptions{} = request_options, reason) do
    with :terminal_predecessor <- Map.get(reason, :resend_disposition),
         {:ok, session, input} <- turn_claim_refusal_input(request_options),
         {:ok, metadata} <- Accounting.final_refusal_predecessor(session, input),
         {:ok, %{"code" => code, "message" => message} = refusal} <- Adapter.recorded_final_refusal_error(metadata) do
      public_error = error(400, code, message, Map.get(refusal, "param"))
      log_pre_classification_refusal(request_options, session, :final_refusal_predecessor, public_error)
      {:error, public_error}
    else
      _no_recorded_refusal ->
        log_duplicate_turn(request_options, :reservation_duplicate,
          stage: "websocket_turn_claim",
          extra: [resend_disposition: Map.get(reason, :resend_disposition)]
        )

        {:error, duplicate_turn_error()}
    end
  end

  defp turn_claim_refusal_input(%RequestOptions{
         continuity: %{codex_session: %CodexSession{} = session, semantic_turn_key: semantic_turn_digest},
         native_client_retry_witness: %{digest: digest, auth_epoch: auth_epoch} = witness
       }),
       do:
         {:ok, session,
          %{
            semantic_turn_digest: semantic_turn_digest,
            replay_claim_digest: digest,
            replay_claim_alternates: witness_alternates(witness),
            runtime_revocation_epoch: auth_epoch
          }}

  defp turn_claim_refusal_input(_request_options), do: :none

  # A turn whose provider refusal went out as the final wrapped 400 is never
  # served again, and its resend is answered with that same refusal rather than
  # `409 duplicate_turn`: the released client's in-band compaction resends a
  # refused compaction frame five more times and then showed the duplicate
  # refusal instead of the provider's (findings#254 row 254-100, Codex 0.156.1).
  # Nothing is dispatched or reserved for the resend, as for any refused one.
  defp reject_terminal_predecessor(context, session, input) do
    with {:ok, metadata} <- Accounting.final_refusal_predecessor(session, input),
         {:ok, %{"code" => code, "message" => message} = refusal} <- Adapter.recorded_final_refusal_error(metadata) do
      public_error = error(400, code, message, Map.get(refusal, "param"))
      log_pre_classification_refusal(context.request_options, session, :final_refusal_predecessor, public_error)
      Repo.rollback(public_error)
    else
      :none -> reject_replay_intent(context, session, :terminal_predecessor)
    end
  end

  defp native_compaction_retry_preflight(
         session,
         api_key,
         model,
         %{
           requested_model: requested_model,
           semantic_turn_digest: semantic_turn_digest,
           replay_claim_digest: replay_claim_digest,
           request_options:
             %RequestOptions{
               runtime: %{api_key_runtime_epoch: api_key_runtime_epoch},
               continuity: %{previous_response_id: previous_response_id},
               payload_context: payload_context
             } = options
         }
       ) do
    Accounting.client_retry_preflight_snapshot(session, api_key, model, %{
      endpoint: "/backend-api/codex/responses/compact",
      requested_model: requested_model,
      runtime_revocation_epoch: api_key_runtime_epoch,
      semantic_turn_digest: semantic_turn_digest,
      original_request_claim: options.continuity.request_claim_key,
      replay_claim_digest: replay_claim_digest,
      anchor_present?: not is_nil(previous_response_id),
      retry_policy: :native_compaction,
      full_history?: payload_context.compaction_input_mode == :full_history,
      compaction_trigger_bridge?: true
    })
  end

  defp native_full_history_compaction_preflight?(%RequestOptions{
         payload_context: %{compaction_input_mode: :full_history},
         transport: %{websocket_delivery_mode: :collect_full_history}
       }),
       do: true

  defp native_full_history_compaction_preflight?(%RequestOptions{}), do: false

  defp valid_incremental_compaction_admission?(
         %RequestOptions{
           payload_context: %{compaction_input_mode: :incremental},
           transport: %{websocket_delivery_mode: :collect_compaction}
         } = options
       ) do
    match?(
      {:ok, %{phase: :compact}, _owner, _lifecycle},
      RequestOptions.native_compaction_admission(options)
    )
  end

  defp valid_incremental_compaction_admission?(%RequestOptions{}), do: false

  # These checks run before the frame is matched to any recorded turn, so they
  # refuse a brand-new turn exactly as they refuse a resend and must not answer
  # `duplicate_turn` or count as one (findings#225, row 225-83). A session the
  # caller cannot continue gets the code the owner-lease and takeover paths
  # give a non-reconnectable session, `503 owner_unavailable`; the released
  # Codex client drops its websocket after any error frame, so its retry
  # upgrades again and lands in a session scoped to its own key and Pool.
  defp validate_replay_session_binding(
         %CodexSession{pool_id: pool_id, api_key_id: api_key_id} = session,
         %{pool: %{id: pool_id}, api_key: %{id: api_key_id}}
       ) do
    if CodexSession.reconnectable?(session),
      do: :ok,
      else: session_unavailable_refusal(:session_not_reconnectable)
  end

  defp validate_replay_session_binding(%CodexSession{}, _auth),
    do: session_unavailable_refusal(:session_binding_mismatch)

  defp validate_replay_api_key_pool(
         %{pool_id: pool_id},
         %CodexSession{pool_id: pool_id}
       ),
       do: :ok

  defp validate_replay_api_key_pool(_api_key, %CodexSession{}),
    do: session_unavailable_refusal(:session_pool_mismatch)

  # The authorization read one statement earlier already refuses a key whose
  # Pool is inactive or gone, as the runtime `pool_inactive` refusal carrying
  # the key's epoch; this reload only sees a Pool disabled or deleted after that
  # read, and answers the same refusal so the socket latches it the same way.
  defp load_active_replay_pool(pool_id, authorization) do
    maybe_test_replay_pool_hook()

    case Repo.get(Pool, pool_id) do
      %Pool{status: "active"} = pool -> {:ok, pool}
      %Pool{} -> pool_inactive_refusal(:pool_inactive, authorization)
      nil -> pool_inactive_refusal(:pool_missing, authorization)
    end
  end

  defp session_unavailable_refusal(reason) do
    {:error, {:pre_classification_refusal, reason, error(503, "owner_unavailable", "websocket owner session is unavailable")}}
  end

  defp pool_inactive_refusal(reason, %{runtime_revocation_epoch: epoch}) do
    {:error, {:pre_classification_refusal, reason, %{status: 401, code: :pool_inactive, message: "pool is not active", disabling_epoch: epoch}}}
  end

  defp refuse_replay_before_classification(context, reason, public_error) do
    log_pre_classification_refusal(context.request_options, context.session, reason, public_error)
    Repo.rollback(public_error)
  end

  # Each refusal answers what the fresh path answers for the same condition:
  # a policy that fails normalization its own reason, recorded as a policy
  # denial; a model the Pool does not serve `invalid_model`; a model the key
  # may not use `model_not_allowed`, recorded against that model. A policy
  # that failed normalization answered `model_not_allowed` here.
  defp authorize_replay_model(api_key, pool, context) do
    with {:ok, policy} <- normalize_replay_policy(api_key),
         {:ok, effective_model} <- effective_replay_model_name(policy, context) do
      authorize_replay_catalog_model(pool, policy, effective_model, context)
    end
  end

  defp normalize_replay_policy(api_key) do
    case Access.normalize_api_key_policy(api_key) do
      {:ok, policy} -> {:ok, policy}
      {:error, reason} -> replay_model_denial(:policy, nil, reason, [])
    end
  end

  defp effective_replay_model_name(policy, context) do
    case effective_model_name(policy, context.requested_model, context.endpoint, context.request_options) do
      {:ok, effective_model} -> {:ok, effective_model}
      {:error, reason} -> replay_model_denial(:gateway, nil, reason, [])
    end
  end

  # HTTP and the fresh path judge the Pool's visible models before the key's
  # policy, so a model the key does not allow that the catalog lists as active
  # but no assignment serves is `invalid_model` there. The preflight reads the
  # catalog row alone, so it asks for visibility before it answers
  # `model_not_allowed`; it answered `model_not_allowed` for that model and the
  # code depended on the forwarding mode (findings#206 row 206-549). A model
  # the key allows is admitted on the catalog row, as before: the fresh path
  # that runs next judges its visibility and records its own refusal.
  defp authorize_replay_catalog_model(pool, policy, effective_model, context) do
    routing = [api_key_policy: policy, effective_model: effective_model]

    case Catalog.get_model_by_exposed_id(pool, effective_model) do
      %Model{status: "active"} = model ->
        case Access.authorize_api_key_policy(policy, %{model_identifier: model.exposed_model_id}) do
          {:ok, _policy} -> {:ok, model}
          {:error, reason} -> refuse_replay_policy_model(pool, model, reason, routing, context)
        end

      _missing_or_inactive ->
        replay_invalid_model(routing)
    end
  end

  defp refuse_replay_policy_model(pool, model, reason, routing, context) do
    if replay_model_visible?(pool, Keyword.fetch!(routing, :effective_model), context),
      do: replay_model_denial(:gateway, model, Denials.policy_denial_error(reason), routing),
      else: replay_invalid_model(routing)
  end

  defp replay_model_visible?(pool, effective_model, context),
    do: match?(%{visible_model: %Model{}}, visible_model_context(pool, effective_model, context.endpoint, context.request_options))

  defp replay_invalid_model(routing),
    do: replay_model_denial(:gateway, nil, error(400, "invalid_model", "model is not available for this pool", "model"), routing)

  defp replay_model_denial(kind, model, reason, routing), do: {:error, {:replay_model_denial, {kind, model, reason, routing}}}

  defp replay_authorization_binding(session, authorization, model) do
    %{
      api_key_id: authorization.api_key.id,
      api_key_runtime_epoch: authorization.runtime_revocation_epoch,
      pool_id: session.pool_id,
      codex_session_id: session.id,
      model_identifier: model.exposed_model_id
    }
  end

  # A lifecycle matched through a full-history resend of an anchored request
  # names the claim the armed request holds; the socket rebinds the frame to it
  # before any owner check (findings#232 row 232-160).
  defp replay_intent_result(intent, authorization_binding, %{matched_replay_claim_digest: matched} = lifecycle) do
    intent
    |> replay_intent_result(authorization_binding, Map.delete(lifecycle, :matched_replay_claim_digest))
    |> Map.put(:replay_claim_digest, matched)
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
        {:error, error(409, "prepared_frame_consumed", "prepared websocket frame was already consumed")}

      {:error, :invalid} ->
        {:error, prepared_frame_provenance_breach(prepared, "prepared_dispatch_consume")}
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
    {:socket_response_result, :local_complete, {:error, error(400, "invalid_request", "websocket message must be a text JSON frame")}}
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
       do: maybe_adapt_websocket_result(result, result_adapter)

  defp adapt_websocket_result(result, _coerced), do: result

  defp maybe_adapt_websocket_result(
         {:ok, %{websocket_messages: [%{"type" => type}]}} = result,
         _result_adapter
       )
       when type in ["response.failed", "response.incomplete", "error"],
       do: result

  defp maybe_adapt_websocket_result(result, result_adapter), do: result_adapter.(result)

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

    # A websocket turn must reach the upstream websocket; fail closed before
    # validation, reservation, or upstream work rather than posting its body
    # to the HTTP endpoint.
    case UpstreamAttempt.transport_decision(request_options) do
      :websocket_without_upstream ->
        {:error, UpstreamAttempt.websocket_transport_required_error()}

      _decision ->
        execute_with_validation(
          auth,
          prepared.endpoint,
          prepared.payload,
          request_options,
          {:prepared_websocket, prepared.provenance.validation, runtime_proof}
        )
    end
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
  after
    case Map.get(reserved, :compaction_retry_submit_hold) do
      %CompactionRetrySubmitHold{} = hold ->
        WebsocketOwnerForwarder.cancel_compaction_retry_v7(hold)

      nil ->
        :ok
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
      |> put_replay_models_etag(replay)

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

  # A native replay does not rebuild the catalog snapshot: it re-emits the
  # original turn's models ETag (backend_responses_etag.snapshot_lifetime).
  defp put_replay_models_etag(%RouteState{} = route_state, %{models_etag: models_etag})
       when is_binary(models_etag),
       do: RouteState.put_codex_models_etag(route_state, models_etag)

  defp put_replay_models_etag(%RouteState{} = route_state, _replay), do: route_state

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
      selected_assignment_id: assignment.id,
      # A replay plans its single pinned route here, so this is its turn start
      # for `BridgeRing.record_success/3`'s demotion-resolution fence.
      planned_at: DateTime.utc_now()
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

  # The claim row this request inserted in `claim_prepared_turn/6`, never a
  # predecessor it chained onto. Best effort: a database still failing keeps the
  # row for the stale-claim recovery, and the refusal the client gets is the one
  # it would have got anyway.
  defp release_turn_claim(nil), do: :ok

  defp release_turn_claim(%Accounting.Request{} = turn_claim) do
    case Accounting.release_websocket_turn_claim(turn_claim) do
      {:ok, _released_or_kept} -> :ok
      {:error, reason} -> log_turn_claim_release_failure(reason)
    end
  rescue
    exception -> log_turn_claim_release_failure(exception.__struct__)
  catch
    kind, _reason -> log_turn_claim_release_failure(kind)
  end

  defp log_turn_claim_release_failure(reason) do
    Logger.warning("websocket turn claim release failed reason_code=#{DiagnosticTaxonomy.reason_code(reason) || "unknown"}")
  end

  defp claim_explicit_websocket_turn(
         _auth,
         _model,
         _payload,
         _endpoint,
         %RequestOptions{
           runtime: %{replay_lifecycle_binding: %{compaction_successor_pending?: true}}
         } = request_options,
         %RouteState{},
         runtime_admission_proof
       ) do
    redeem_client_retry_runtime_admission(request_options, runtime_admission_proof)
  end

  defp claim_explicit_websocket_turn(
         _auth,
         _model,
         _payload,
         _endpoint,
         %RequestOptions{
           runtime: %{
             replay_lifecycle_binding: %{client_retry_predecessor_request_id: request_id}
           }
         } = request_options,
         %RouteState{},
         runtime_admission_proof
       )
       when is_binary(request_id) do
    redeem_client_retry_runtime_admission(request_options, runtime_admission_proof)
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
         auth,
         model,
         payload,
         endpoint,
         %RequestOptions{} = request_options,
         %RouteState{} = route_state,
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

      case WebsocketCodec.admitted_compaction_claim(endpoint, payload, request_options) do
        compaction_claim when is_binary(compaction_claim) -> {:ok, nil, compaction_claim}
        nil -> claim_admitted_compaction_resume(auth, model, payload, endpoint, request_options, route_state, correlation_id)
      end
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
      {:ok, %{request: request} = claim} ->
        maybe_log_client_resend_admitted(request_options, endpoint, claim)
        {:ok, request, nil}

      {:error, reason} ->
        {:error, reason}
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

  # An admitted native compaction is recorded under the durable claim its own
  # full-history resend derives instead of the runtime proof's generated
  # correlation: a client cut during it resends the whole history on a new
  # socket, and with owner forwarding off that resend found no claim, was
  # served and billed a second time after the first one had been billed, or
  # raced the closing socket into the active-turn index and left an accepted
  # row behind (findings#206 row 206-310). The claim is written by the
  # reservation itself, so a reservation that rolls back leaves no row that
  # would fence the client's retry. An anchored request never takes the
  # failed-predecessor resend path, so claiming it first would add nothing.
  #
  # The resume of a turn after its mid-turn compaction is admitted by the
  # runtime proof, yet the same resume sent again on another socket or over
  # HTTP derives the durable `codex-resume:` claim and would find it free, so
  # the provider would be paid for the same history twice (findings#225, row
  # 225-87; the fence of findings#250). The admitted resume therefore takes that
  # claim itself, through the same claim path and resend policy as any native
  # turn; the reservation keeps the claimed row, and the runtime-proof
  # correlation still marks the final admission for its window alias.
  defp claim_admitted_compaction_resume(auth, model, payload, endpoint, request_options, route_state, correlation_id) do
    case WebsocketCodec.post_compaction_resume_claim(payload, request_options) do
      resume_claim when is_binary(resume_claim) ->
        claim_options = RequestOptions.put_continuity(request_options, request_claim_key: resume_claim)
        attrs = AccountingReservation.attrs(auth, payload, endpoint, claim_options, route_state)

        case Accounting.claim_websocket_turn(auth, model, attrs) do
          {:ok, %{request: request} = claim} ->
            maybe_log_client_resend_admitted(claim_options, endpoint, claim)
            {:ok, request, correlation_id}

          {:error, reason} ->
            {:error, reason}
        end

      nil ->
        {:ok, nil, correlation_id}
    end
  end

  defp redeem_client_retry_runtime_admission(_request_options, nil), do: {:ok, nil, nil}

  defp redeem_client_retry_runtime_admission(
         %RequestOptions{} = request_options,
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

      _no_usable_admission ->
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
    # Resolved once: the reservation attributes and the final-refusal lookup
    # both read it, and building it hashes the payload for the resend witness.
    native_http_claim = NativeHttpTurnIdentity.request_claim(request_options, payload)

    attrs =
      auth
      |> AccountingReservation.attrs(
        payload,
        endpoint,
        request_options,
        route_state,
        authorized_correlation_id,
        native_http_claim
      )
      |> Map.put(:reservation_estimate, AccountingReservation.reservation_estimate(route_state))
      |> Map.put(:turn_claim, turn_claim)

    case request_options.runtime.replay_lifecycle_binding do
      %{client_retry_predecessor_request_id: predecessor_request_id}
      when is_binary(predecessor_request_id) ->
        reserve_client_retry(auth, model, payload, endpoint, request_options, attrs)

      %{compaction_successor_pending?: true} ->
        reserve_client_retry(auth, model, payload, endpoint, request_options, attrs)

      _ordinary ->
        with :none <- native_http_final_refusal(request_options, native_http_claim) do
          auth
          |> Accounting.reserve(model, payload, attrs)
          |> normalize_native_http_turn_duplicate(endpoint, request_options)
        end
    end
  end

  # A native Codex HTTP turn now reserves under the same turn claim a websocket
  # frame does, so its resend meets the resend policy inside the reservation
  # transaction and comes back as an accounting duplicate. It gets the public
  # websocket verdict rather than a reservation failure (findings#212).
  defp normalize_native_http_turn_duplicate(
         {:error, %{code: :duplicate_request} = reason},
         endpoint,
         %RequestOptions{} = request_options
       ) do
    if NativeHttpTurnIdentity.fenced?(request_options) do
      log_duplicate_turn(request_options, :reservation_duplicate,
        stage: "native_http_turn_claim",
        endpoint: endpoint,
        extra: [resend_disposition: Map.get(reason, :resend_disposition)]
      )

      {:error, duplicate_turn_error()}
    else
      {:error, reason}
    end
  end

  defp normalize_native_http_turn_duplicate(result, _endpoint, %RequestOptions{}), do: result

  # The HTTPS resend of a native websocket turn whose provider refusal went out
  # as the final wrapped 400 is answered with that refusal, like its websocket
  # resend (findings#254 rows 254-100 and 254-130), before anything is
  # reserved. The native HTTP turn claim steps over a zero-output predecessor
  # (findings#212 row 212-50), so this resend used to be dispatched again and
  # refused again by the provider; the opening request's witness is the
  # websocket request's (findings#232 row 232-231), so the refused turn is found
  # the way its websocket resend finds it. An HTTP predecessor records no
  # provider status of its own and keeps that step-over. The claim is the one
  # `reserve/8` resolved for the reservation attributes, not derived again.
  defp native_http_final_refusal(%RequestOptions{transport: %{transport: transport}, continuity: %{codex_session: %CodexSession{} = session}} = request_options, native_http_claim)
       when transport in ["http_sse", "http_json"] do
    with true <- NativeHttpTurnIdentity.fenced?(request_options),
         {:ok, %{arm: :opening, semantic_turn_key: semantic_turn_digest, native_client_retry_witness: %{digest: digest, auth_epoch: auth_epoch} = witness}} <-
           native_http_claim,
         {:ok, metadata} <-
           Accounting.final_refusal_predecessor(session, %{
             semantic_turn_digest: semantic_turn_digest,
             replay_claim_digest: digest,
             replay_claim_alternates: witness_alternates(witness),
             runtime_revocation_epoch: auth_epoch
           }),
         {:ok, %{"code" => code, "message" => message} = refusal} <- Adapter.recorded_final_refusal_error(metadata) do
      public_error = error(400, code, message, Map.get(refusal, "param"))
      log_pre_classification_refusal(request_options, session, :final_refusal_predecessor, public_error)
      {:error, public_error}
    else
      _no_recorded_refusal -> :none
    end
  end

  defp native_http_final_refusal(_request_options, _native_http_claim), do: :none

  defp reserve_client_retry(auth, model, payload, endpoint, request_options, attrs) do
    if native_full_history_compaction?(endpoint, request_options) do
      reserve_compaction_retry(auth, model, payload, request_options, attrs)
    else
      retry_attrs =
        attrs
        |> Map.put(:codex_session, request_options.continuity.codex_session)
        |> Map.put(:semantic_turn_digest, request_options.continuity.semantic_turn_key)
        |> Map.put(:original_request_claim, request_options.continuity.request_claim_key)
        |> Map.put(:replay_claim_digest, request_options.continuity.replay_claim_digest)
        |> Map.put(:anchor_present?, not is_nil(request_options.continuity.previous_response_id))
        |> Map.put(
          :owner_idle_validated?,
          Map.get(request_options.runtime.replay_lifecycle_binding, :owner_idle_validated?) ==
            true
        )
        |> Map.put(
          :owner_lease_token,
          Map.get(request_options.runtime.replay_lifecycle_binding, :owner_lease_token)
        )
        |> Map.put(
          :owner_instance_id,
          Map.get(request_options.runtime.replay_lifecycle_binding, :owner_instance_id)
        )

      case Accounting.claim_client_retry_successor(auth, model, payload, retry_attrs) do
        {:ok, claim} ->
          {:ok, Map.from_struct(claim)}

        {:error, %{code: code}} = denial when code in @retry_claim_policy_refusals ->
          denial

        {:error, reason} ->
          log_duplicate_turn(request_options, reason,
            stage: "client_retry_claim",
            endpoint: endpoint
          )

          {:error, duplicate_turn_error()}
      end
    end
  end

  defp native_full_history_compaction?(
         "/backend-api/codex/responses/compact",
         %RequestOptions{
           native_compaction_admission: nil,
           continuity: %{previous_response_id: nil, request_claim_key: claim},
           payload_context: %{
             compaction_trigger_bridge?: true,
             compaction_result_mode: :native_websocket,
             compaction_input_mode: :full_history,
             native_codex_turn_metadata: %NativeCodexTurnMetadata{request_kind: :compaction}
           },
           transport: %{
             transport: "websocket",
             websocket_delivery_mode: :collect_full_history
           }
         }
       )
       when is_binary(claim),
       do: true

  defp native_full_history_compaction?(_endpoint, %RequestOptions{}), do: false

  defp reserve_compaction_retry(auth, model, payload, request_options, attrs) do
    lifecycle = request_options.runtime.replay_lifecycle_binding || %{}

    retry_attrs =
      Map.merge(attrs, %{
        codex_session: request_options.continuity.codex_session,
        semantic_turn_digest: request_options.continuity.semantic_turn_key,
        original_request_claim: request_options.continuity.request_claim_key,
        replay_claim_digest: request_options.continuity.replay_claim_digest,
        full_history?: true,
        anchor_present?: false,
        compaction_trigger_bridge?: true,
        owner_idle_validated?: Map.get(lifecycle, :owner_idle_validated?) == true,
        owner_lease_token: Map.get(lifecycle, :owner_lease_token),
        owner_instance_id: Map.get(lifecycle, :owner_instance_id)
      })

    case Accounting.claim_compaction_retry_successor(auth, model, payload, retry_attrs) do
      {:ok, claim} ->
        {:ok, Map.from_struct(claim)}

      {:error, %{code: code}} = denial when code in @retry_claim_policy_refusals ->
        denial

      {:error, reason} ->
        log_duplicate_turn(request_options, reason, stage: "compaction_retry_claim")
        {:error, duplicate_turn_error()}
    end
  end

  defp reserve_compaction_retry_owner(
         %RequestOptions{
           transport: %{websocket_owner: %{enabled?: true} = owner}
         } = request_options
       ) do
    case WebsocketOwnerForwarder.reserve_compaction_retry_v7(
           owner.session,
           owner.lease_token,
           owner.downstream,
           owner.forwarder_opts
         ) do
      {:ok, %CompactionRetrySubmitHold{} = hold} ->
        {:ok, RequestOptions.put_runtime_context(request_options, compaction_retry_submit_hold: hold)}

      {:error, :owner_unavailable} ->
        {:error,
         error(503, "owner_unavailable", "websocket owner admission is unavailable", nil, %{
           accounting_disposition: :zero_work
         })}
    end
  end

  defp reserve_compaction_retry_owner(%RequestOptions{} = request_options),
    do: {:ok, request_options}

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

    hold_result =
      if is_nil(turn_claim) and native_full_history_compaction?(endpoint, request_options) do
        reserve_compaction_retry_owner(request_options)
      else
        {:ok, request_options}
      end

    with :ok <- CodexPooler.Gateway.Admission.checkpoint(),
         {:ok, request_options} <- hold_result do
      transact_reserved_turn(
        auth,
        model,
        payload,
        endpoint,
        request_options,
        route_state,
        turn_claim,
        authorized_correlation_id
      )
    end
  end

  defp transact_reserved_turn(
         auth,
         model,
         payload,
         endpoint,
         request_options,
         route_state,
         turn_claim,
         authorized_correlation_id
       ) do
    maybe_test_runtime_authorization_barrier(:reservation_lock, :before)

    # Owner renewal locks this session too. Enter the capability phase before
    # acquiring database locks, so renewal cannot prevent this control's reply.
    # This is a preparation latch: reservation and send authority still follow,
    # and every failed transaction clears this capability outside the lock.
    with :ok <-
           RequestOptions.mark_native_compaction_accounting_started(
             request_options,
             System.system_time(:millisecond)
           ) do
      reserve_turn_transaction(
        auth,
        model,
        payload,
        endpoint,
        request_options,
        route_state,
        turn_claim,
        authorized_correlation_id
      )
    end
    |> case do
      {:ok, reserved} ->
        case request_options.runtime.compaction_retry_submit_hold do
          %CompactionRetrySubmitHold{} = hold ->
            {:ok, Map.put(reserved, :compaction_retry_submit_hold, hold)}

          nil ->
            {:ok, reserved}
        end

      {:error, reason} ->
        cancel_compaction_retry_hold(request_options)
        {:error, reason}
    end
  rescue
    error in Ecto.ConstraintError ->
      cancel_compaction_retry_hold(request_options)

      case reservation_constraint_error(error, request_options) do
        {:error, _gateway_error} = result ->
          result

        :reraise ->
          clear_native_compaction_admission(request_options)
          reraise(error, __STACKTRACE__)
      end

    # The reservation transaction rolled back and nothing was sent upstream, so a
    # database that stopped answering, restarted or cancelled the statement is a
    # retryable 503, not the 500 an escaping exception renders (findings#206 row
    # 206-358). A statement that outlived its timeout during COMMIT may still have
    # committed on the server; that orphan was left behind by the 500 as well.
    # The 503 returns to `handle_session_routable_result/2`, which clears the
    # admitted compaction like every other refusal; clearing it here as well made
    # that second clear find no admission and log a false cleanup failure
    # (`reason_code=capability_mismatch`, findings#206 row 206-388).
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      cancel_compaction_retry_hold(request_options)

      if TransientDatabaseError.transient?(error) do
        database_unavailable("reservation", error)
      else
        clear_native_compaction_admission(request_options)
        reraise(error, __STACKTRACE__)
      end

    error ->
      clear_native_compaction_admission(request_options)
      cancel_compaction_retry_hold(request_options)
      reraise(error, __STACKTRACE__)
  catch
    kind, reason ->
      clear_native_compaction_admission(request_options)
      cancel_compaction_retry_hold(request_options)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # Work that meets a transient database failure (`TransientDatabaseError`)
  # before anything was reserved or sent upstream answers the retryable 503 of
  # `Contracts.database_unavailable_error/0` instead of raising: over HTTP the
  # exception rendered a 500, and a websocket turn's response task ended as
  # `websocket_response_task_failed` (`owner_task_exception`). The reservation
  # transaction (`transact_reserved_turn/8`, which also holds the retry
  # successor claims) has its own rescue; this one bounds the preparation, the
  # websocket turn claim and the replay intent read. Any other database error
  # still raises (findings#206 rows 206-358 and 206-368).
  defp before_dispatch(stage, fun) do
    fun.()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      if TransientDatabaseError.transient?(error),
        do: database_unavailable(stage, error),
        else: reraise(error, __STACKTRACE__)
  end

  defp database_unavailable(stage, error) do
    Logger.warning("runtime request refused before dispatch stage=#{stage} reason_class=#{TransientDatabaseError.reason_class(error)}")
    {:error, Contracts.database_unavailable_error()}
  end

  defp reserve_turn_transaction(
         auth,
         model,
         payload,
         endpoint,
         request_options,
         route_state,
         turn_claim,
         authorized_correlation_id
       ) do
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
           {:ok, reserved} <- maybe_start_reserved_turn(reserved, request_options),
           :ok <-
             register_final_window_alias(
               auth,
               payload,
               request_options,
               authorized_correlation_id
             ) do
        reserved
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp cancel_compaction_retry_hold(%RequestOptions{
         runtime: %{compaction_retry_submit_hold: %CompactionRetrySubmitHold{} = hold}
       }),
       do: WebsocketOwnerForwarder.cancel_compaction_retry_v7(hold)

  defp cancel_compaction_retry_hold(%RequestOptions{}), do: :ok

  defp maybe_start_reserved_turn(
         %{codex_turn: %CodexPooler.Gateway.Persistence.CodexTurn{}} = reserved,
         _request_options
       ),
       do: {:ok, reserved}

  defp maybe_start_reserved_turn(reserved, request_options),
    do: SessionContinuity.start_turn(reserved, request_options)

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
        register_frame_window_alias(auth, payload, request_options)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp register_final_window_alias(auth, payload, request_options, _correlation),
    do: register_frame_window_alias(auth, payload, request_options)

  # A turn frame naming a newer window than the socket's session is keyed by:
  # the client's reconnect names that window, so the window must lead to this
  # session, whose owner holds the turn's replay (findings#206, P115). Best
  # effort: the lookup aid never fails the turn.
  defp register_frame_window_alias(auth, payload, %RequestOptions{continuity: %{codex_session: %CodexSession{} = session}} = request_options) do
    case ReplayPreparation.frame_window_alias_hash(request_options, payload) do
      {:ok, hash} ->
        disposition = SessionAliases.point_frame_window_hash(session, auth, hash, DateTime.utc_now() |> DateTime.truncate(:microsecond))
        Logger.info("websocket frame window alias codex_session_id=#{session.id} alias_preview=#{hash |> Base.encode16(case: :lower) |> String.slice(0, 16)} disposition=#{disposition}")
        :ok

      :none ->
        :ok
    end
  end

  defp register_frame_window_alias(_auth, _payload, _request_options), do: :ok

  defp lock_codex_session_before_reservation(%RequestOptions{runtime: %{session_owner_witness: %OwnerWitness{}}} = request_options) do
    :ok =
      PersistenceSessionContinuity.validate_session_owner_witness_for_reservation(request_options)

    request_options
  end

  defp lock_codex_session_before_reservation(
         %RequestOptions{continuity: %{codex_session: %CodexSession{} = session}} =
           request_options
       ) do
    locked_session = PersistenceSessionContinuity.lock_codex_session_for_turn(session)
    RequestOptions.put_continuity(request_options, codex_session: locked_session)
  end

  defp lock_codex_session_before_reservation(%RequestOptions{} = request_options),
    do: request_options

  defp normalize_session_lease_heartbeat_failure({:error, reason}, context)
       when reason in [:stale_owner, :owner_unavailable],
       do: reject_owner_lease_refusal(context, reason, "synchronous_renewal")

  defp normalize_session_lease_heartbeat_failure(result, _context), do: result

  # A session owner refusal before any attempt is a client-visible answer, so
  # it gets a rejected request row like every other refusal (findings#206 row
  # 206-564): no attempt, turn or ledger entry, the refusal code, and the phase
  # that refused it (`synchronous_renewal` or `reservation`). Recording is best
  # effort, because the database can be what failed the renewal; the client
  # gets the same refusal either way, and a claimed turn is released.
  defp reject_owner_lease_refusal(context, reason, phase) do
    %{auth: auth, model: model, endpoint: endpoint, payload: payload, request_options: request_options, turn_claim: turn_claim} = context

    error =
      reason
      |> AccountingReservation.pre_attempt_failure(request_options)
      |> Map.put(:continuity_denial, %{
        "denial_family" => "session_owner_lease",
        "internal_reason" => Atom.to_string(reason),
        "failure_phase" => phase,
        "operator_action" => "none needed; the session changed owner before this request could run, and a resend attaches to the current owner"
      })

    try do
      Denials.log_gateway(denial_context(auth, model, error, endpoint, payload, request_options), turn_claim)
    rescue
      exception ->
        Logger.warning("session owner refusal not recorded reason_code=#{DiagnosticTaxonomy.reason_code(exception.__struct__)}")
        release_turn_claim(turn_claim)
        {:error, error}
    end
  end

  defp wrap_deferred_session_lease_stream({:ok, %{stream: stream} = result}, heartbeat)
       when is_function(stream, 1) do
    {:ok, %{result | stream: wrap_session_lease_stream(stream, heartbeat)}}
  end

  defp wrap_deferred_session_lease_stream(result, _heartbeat), do: result

  defp wrap_session_lease_stream(stream, heartbeat) do
    fn conn ->
      :ok = SessionLeaseHeartbeat.stream_started(heartbeat)

      try do
        stream.(conn)
      after
        :ok = SessionLeaseHeartbeat.stop(heartbeat)
      end
    end
  end

  defp duplicate_turn_reservation_constraint?(
         %Ecto.ConstraintError{constraint: "requests_correlation_id_uq"},
         %RequestOptions{
           transport: %{transport: "websocket"},
           continuity: %{request_claim_key: request_claim_key}
         }
       )
       when is_binary(request_claim_key),
       do: true

  # The native HTTP fence resolves its predecessor under the codex session lock
  # before inserting, so this is only the race backstop: a claim that met the
  # constraint anyway is the same duplicate turn, not a gateway fault.
  defp duplicate_turn_reservation_constraint?(
         %Ecto.ConstraintError{constraint: "requests_correlation_id_uq"},
         %RequestOptions{} = request_options
       ),
       do: NativeHttpTurnIdentity.fenced?(request_options)

  defp duplicate_turn_reservation_constraint?(_error, _opts), do: false

  @doc false
  @spec reservation_constraint_error(Exception.t(), RequestOptions.t()) ::
          {:error, gateway_error()} | :reraise
  def reservation_constraint_error(%Ecto.ConstraintError{} = error, %RequestOptions{} = opts) do
    if duplicate_turn_reservation_constraint?(error, opts) do
      log_replay_rejection(opts, :reservation_duplicate)
      {:error, duplicate_turn_error()}
    else
      :reraise
    end
  end

  defp duplicate_turn_error do
    error(
      409,
      "duplicate_turn",
      "duplicate Codex turn was already recorded for this session",
      "request_id"
    )
  end

  defp reject_replay_intent(context, session, reason) do
    log_replay_rejection(context, session, reason)
    Repo.rollback(duplicate_turn_error())
  end

  defp log_replay_rejection(context, session, reason) when is_map(context) do
    request_options = Map.fetch!(context, :request_options)

    log_replay_rejection(
      request_options,
      session,
      reason,
      Map.get(context, :endpoint, "unknown")
    )
  end

  defp log_replay_rejection(%RequestOptions{} = request_options, reason) do
    log_replay_rejection(
      request_options,
      Map.get(request_options.continuity, :codex_session),
      reason,
      Map.get(request_options.transport, :upstream_endpoint, "unknown")
    )
  end

  defp log_replay_rejection(%RequestOptions{} = request_options, session, reason, endpoint) do
    emit_replay_rejection(
      request_options,
      session,
      reason,
      endpoint,
      "runtime_replay_preflight",
      []
    )
  end

  # Every silent `duplicate_turn` producer outside the replay preflight logs
  # through here with the same bounded, metadata-only vocabulary, so operators
  # can tell a claim-stage duplicate from a rejected retry or replay binding.
  defp log_duplicate_turn(%RequestOptions{} = request_options, reason, opts) do
    endpoint =
      Keyword.get(opts, :endpoint) ||
        Map.get(request_options.transport, :upstream_endpoint, "unknown")

    emit_replay_rejection(
      request_options,
      Map.get(request_options.continuity, :codex_session),
      reason,
      endpoint,
      Keyword.fetch!(opts, :stage),
      Keyword.get(opts, :extra, [])
    )
  end

  defp emit_replay_rejection(request_options, session, reason, endpoint, stage, extra) do
    :ok = DuplicateTurnTelemetry.emit_refused(stage, request_options.transport.transport)
    log_replay_rejection_line(request_options, session, reason, endpoint, stage, extra)
  end

  # Same line as a counted refusal, so a grep for the stage still finds it, but
  # not counted: the frame was refused before it was matched to any turn, and
  # `public_code` says what the client actually received.
  defp log_pre_classification_refusal(%RequestOptions{} = request_options, session, reason, public_error) do
    log_replay_rejection_line(
      request_options,
      session || Map.get(request_options.continuity, :codex_session),
      reason,
      Map.get(request_options.transport, :upstream_endpoint, "unknown"),
      "runtime_replay_preflight",
      public_code: public_error.code
    )
  end

  defp log_replay_rejection_line(request_options, session, reason, endpoint, stage, extra) do
    reason_code = replay_rejection_reason_code(reason)
    request_id = request_options.request_metadata.request_id
    session_id = if is_struct(session, CodexSession), do: session.id

    extra_fields =
      extra
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(fn {key, value} ->
        " #{key}=#{DiagnosticTaxonomy.reason_code(value) || "unknown"}"
      end)

    {label, transport} = replay_rejection_channel(request_options)

    Logger.info(fn ->
      label <>
        " replay rejection " <>
        "stage=#{stage} " <>
        "reason_code=#{reason_code} " <>
        "request_id=#{DiagnosticTaxonomy.safe_correlator(request_id)} " <>
        "codex_session_id=#{DiagnosticTaxonomy.safe_correlator(session_id)} " <>
        "endpoint=#{DiagnosticTaxonomy.safe_correlator(endpoint)} transport=#{transport}" <>
        extra_fields
    end)
  end

  # The websocket line is load-bearing for triage and greps, so it stays exactly
  # as it was. A native HTTP refusal is a different path and must say so rather
  # than claim a websocket that does not exist (findings#212).
  defp replay_rejection_channel(%RequestOptions{transport: %{transport: transport}})
       when is_binary(transport) and transport != "websocket",
       do: {"native http", DiagnosticTaxonomy.safe_correlator(transport)}

  defp replay_rejection_channel(%RequestOptions{}), do: {"websocket", "websocket"}

  defp maybe_log_client_resend_admitted(
         %RequestOptions{} = request_options,
         endpoint,
         %{client_resend: %{predecessor_request_id: predecessor_request_id} = client_resend}
       ) do
    request_id = request_options.request_metadata.request_id
    session = Map.get(request_options.continuity, :codex_session)
    session_id = if is_struct(session, CodexSession), do: session.id

    predecessor_shape =
      DiagnosticTaxonomy.resend_predecessor_shape(Map.get(client_resend, :predecessor_shape)) ||
        "unknown"

    Logger.info(fn ->
      "websocket client resend admitted " <>
        "stage=websocket_turn_claim " <>
        "reason_code=failed_predecessor_retry " <>
        "predecessor_shape=#{predecessor_shape} " <>
        "request_id=#{DiagnosticTaxonomy.safe_correlator(request_id)} " <>
        "predecessor_request_id=#{DiagnosticTaxonomy.safe_correlator(predecessor_request_id)} " <>
        "codex_session_id=#{DiagnosticTaxonomy.safe_correlator(session_id)} " <>
        "endpoint=#{DiagnosticTaxonomy.safe_correlator(endpoint)} transport=websocket"
    end)
  end

  defp maybe_log_client_resend_admitted(_request_options, _endpoint, _claim), do: :ok

  defp replay_rejection_reason_code(:replay_claim_mismatch), do: "payload_mismatch"

  defp replay_rejection_reason_code(reason),
    do: DiagnosticTaxonomy.reason_code(reason) || "unknown"

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

  if Mix.env() == :test do
    defp maybe_test_replay_pool_hook do
      case Process.get({__MODULE__, :replay_pool_hook}) do
        hook when is_function(hook, 0) -> hook.()
        _value -> :ok
      end

      :ok
    end
  else
    defp maybe_test_replay_pool_hook, do: :ok
  end

  defp visible_model_context(
         pool,
         requested_model,
         endpoint,
         %RequestOptions{} = request_options
       ) do
    if request_options.payload_context.masked_image_request? do
      masked_image_host_context(pool, requested_model)
    else
      default_visible_model_context(pool, requested_model, endpoint, request_options)
    end
  end

  defp default_visible_model_context(pool, requested_model, endpoint, request_options) do
    case CandidateEligibility.visible_model_context(pool, requested_model) do
      %{visible_model: %Model{}} = context ->
        context

      nil ->
        media_host_model_context(pool, requested_model, endpoint, request_options)
    end
  end

  defp masked_image_host_context(pool, requested_model) do
    hydration = CandidateEligibility.hydrate_model_visibility(pool)
    overrides = Pools.model_serving_modes_by_pool_ids([pool.id]) |> Map.get(pool.id, %{})
    requested = ModelServingOverride.canonical_exposed_model_id(requested_model)

    exact =
      Enum.find(hydration.visible_models, fn model ->
        ModelServingOverride.canonical_exposed_model_id(model.exposed_model_id) == requested
      end)

    models =
      case Map.get(overrides, requested) do
        %ModelServingOverride{mode: "lite"} -> []
        _ -> if exact, do: [exact], else: sort_media_hosts(hydration.visible_models)
      end

    host = Enum.find(models, &full_media_host?(&1, hydration, overrides))

    case host do
      %Model{} ->
        media_host_context(host, hydration, requested_model)

      nil ->
        {:error,
         error(
           400,
           "unsupported_parameter",
           "mask requires an eligible Full Responses backend",
           "mask"
         )}
    end
  end

  defp full_media_host?(model, hydration, overrides) do
    source_ids =
      hydration.candidates_by_model_id
      |> Map.get(model.id, [])
      |> Enum.map(fn {assignment, _identity} -> assignment.id end)

    override =
      Map.get(overrides, ModelServingOverride.canonical_exposed_model_id(model.exposed_model_id))

    resolution = ModelServingMode.resolve(override, ModelMetadata.metadata(model), source_ids)

    media_host_model?(model) and ModelMetadata.supports_image_input?(model) and
      match?({:ok, %{effective_mode: "full"}}, resolution)
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
    |> sort_media_hosts()
    |> Enum.find(&media_host_model?/1)
    |> media_host_context(hydration, requested_model)
  end

  defp legacy_media_host_model_context(pool, requested_model, request_options) do
    hydration = CandidateEligibility.hydrate_model_visibility(pool)

    hydration.visible_models
    |> order_media_hosts(request_options)
    |> Enum.find(&media_host_model?(&1, request_options))
    |> media_host_context(hydration, requested_model)
  end

  defp order_media_hosts(models, %RequestOptions{
         openai_compatibility: %{collect_openai_image_stream: true}
       }),
       do: sort_media_hosts(models)

  defp order_media_hosts(models, %RequestOptions{}), do: models

  defp sort_media_hosts(models) do
    Enum.sort_by(models, fn model ->
      metadata = ModelMetadata.metadata(model)

      visibility =
        case metadata["visibility"] do
          "list" -> 0
          hidden when hidden in ["hide", "none"] -> 2
          _unspecified -> 1
        end

      priority = metadata["priority"]
      rank = if is_integer(priority), do: {0, priority}, else: {1, 0}
      {visibility, rank, model.exposed_model_id}
    end)
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
