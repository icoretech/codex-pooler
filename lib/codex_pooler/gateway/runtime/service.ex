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
  alias CodexPooler.Gateway.Payloads.TranscriptionPayload
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Persistence.SessionContinuity, as: PersistenceSessionContinuity
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.RouteFiltering
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation
  alias CodexPooler.Gateway.Runtime.Dispatch.CandidateDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.FileDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Gateway.Runtime.Dispatch.UpstreamAttempt
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.Websocket.ResponseProcessed
  alias CodexPooler.Repo

  @backend_transcription_model "gpt-4o-transcribe"

  @type auth :: Access.auth_context()
  @type payload :: map()
  @type opts :: RequestOptions.t()
  @type gateway_error :: Contracts.gateway_error()
  @type gateway_result :: Contracts.gateway_result()

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

  defp effective_model_name(%{enforced_model_identifier: model}, _requested_model)
       when is_binary(model),
       do: model

  defp effective_model_name(_policy, requested_model), do: requested_model

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
    case requested_model(payload) do
      {:ok, model_name} ->
        request_options = execute_request_options(opts, endpoint, payload, model_name)
        execute_requested_model(auth, endpoint, payload, request_options, model_name)

      {:error, %{code: _code} = reason} ->
        {:error, reason}
    end
  end

  def execute(_auth, _endpoint, _payload, %RequestOptions{}),
    do: {:error, error(400, "invalid_request", "request body must be a JSON object")}

  defp execute_requested_model(auth, endpoint, payload, request_options, model_name) do
    case normalize_policy_or_log(auth, endpoint, payload, request_options) do
      {:ok, policy} ->
        effective_model_name = effective_model_name(policy, model_name)

        request_options =
          policy_request_opts(request_options, policy, model_name, effective_model_name)

        case visible_model_context(auth.pool, effective_model_name, request_options) do
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

            Denials.log_gateway(
              denial_context(auth, nil, reason, endpoint, payload, request_options)
            )
        end

      {:error, %{code: _code} = reason} ->
        {:error, reason}
    end
  end

  defp execute_visible_model(auth, endpoint, payload, request_options, model, visible_model_data) do
    case PreDispatch.prepare(auth, endpoint, payload, request_options, model, visible_model_data) do
      {:ok, prepared} ->
        execute_session_routable_model(
          auth,
          endpoint,
          payload,
          prepared.request_options,
          model,
          prepared.candidates,
          prepared.route_state
        )

      {:error, %{code: "duplicate_turn"} = reason} ->
        {:error, reason}

      {:error, %{code: _code} = reason} ->
        Denials.log_gateway(
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
         %RouteState{} = route_state
       ) do
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
         :ok <- SessionContinuity.ensure_unique_turn(request_options),
         {:ok, reserved} <-
           reserve_and_start_turn(auth, model, payload, endpoint, request_options, route_state) do
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
    else
      {:error, %{code: "duplicate_turn"} = reason} ->
        {:error, reason}

      {:error, %{code: _code} = reason} ->
        Denials.log_gateway(
          denial_context(auth, model, reason, endpoint, payload, request_options)
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
          execute(auth, coerced.endpoint, coerced.payload, coerced.request_options)
        end
    end
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
    CandidateDispatch.dispatch(
      %{
        auth: auth,
        endpoint: endpoint,
        payload: payload,
        model: model,
        reserved: reserved,
        candidates: candidates,
        request_options: request_options,
        route_state: route_state
      },
      &dispatch_decrypted_candidate/1
    )
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

  defp reserve(
         auth,
         model,
         payload,
         endpoint,
         %RequestOptions{} = request_options,
         %RouteState{} = route_state
       ) do
    Accounting.reserve(
      auth,
      model,
      payload,
      AccountingReservation.attrs(auth, payload, endpoint, request_options, route_state)
    )
  end

  defp reserve_and_start_turn(
         auth,
         model,
         payload,
         endpoint,
         %RequestOptions{} = request_options,
         %RouteState{} = route_state
       ) do
    Repo.transaction(fn ->
      with {:ok, reserved} <-
             reserve(auth, model, payload, endpoint, request_options, route_state),
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

  defp visible_model_context(pool, requested_model, %RequestOptions{} = request_options) do
    case CandidateEligibility.visible_model_context(pool, requested_model) do
      %{visible_model: %Model{}} = context ->
        context

      nil ->
        media_host_model_context(pool, requested_model, request_options)
    end
  end

  defp media_host_model_context(pool, requested_model, %RequestOptions{} = request_options) do
    hydration = CandidateEligibility.hydrate_model_visibility(pool)

    hydration.visible_models
    |> Enum.find(&media_host_model?(&1, request_options))
    |> case do
      %Model{} = model ->
        Map.merge(hydration, %{
          requested_model: requested_model,
          effective_model: requested_model,
          visible_model: model,
          candidate_snapshots: Map.get(hydration.candidates_by_model_id, model.id, [])
        })

      nil ->
        nil
    end
  end

  defp media_host_model?(%Model{} = model, %RequestOptions{
         openai_compatibility: %{collect_openai_image_stream: true}
       }) do
    model.supports_responses and model.supports_streaming and model.supports_tools
  end

  defp media_host_model?(%Model{}, %RequestOptions{
         payload_context: %{forced_transcription_model: model}
       })
       when is_binary(model),
       do: true

  defp media_host_model?(%Model{}, %RequestOptions{}), do: false

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
