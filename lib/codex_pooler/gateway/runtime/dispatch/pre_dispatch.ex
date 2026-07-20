defmodule CodexPooler.Gateway.Runtime.Dispatch.PreDispatch do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Contracts, as: GatewayContracts
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.InputShape
  alias CodexPooler.Gateway.Payloads.ReasoningEffort
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.StrictSchema
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Pools
  alias CodexPooler.Pools.ModelServingMode
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPooler.RouteClass

  @type candidate :: CandidateEligibility.FilterInput.candidate()
  @type visible_model_context :: CandidateEligibility.visible_model_context()
  @type prepared :: %{
          required(:request_options) => RequestOptions.t(),
          required(:candidates) => [candidate()],
          required(:route_state) => RouteState.t()
        }

  @spec prepare(
          CodexPooler.Access.auth_context(),
          String.t(),
          map(),
          RequestOptions.t(),
          Model.t()
        ) :: {:ok, prepared()} | {:error, GatewayContracts.gateway_error()}
  def prepare(auth, endpoint, payload, %RequestOptions{} = request_options, %Model{} = model) do
    hydration = CandidateEligibility.hydrate_model_visibility(model, models: [model])

    prepare(
      auth,
      endpoint,
      payload,
      request_options,
      model,
      Map.merge(hydration, %{
        requested_model: request_options.routing.requested_model || model.exposed_model_id,
        effective_model: request_options.routing.effective_model || model.exposed_model_id,
        visible_model: model,
        visible_models: [model],
        candidate_snapshots: Map.get(hydration.candidates_by_model_id, model.id, [])
      })
    )
  end

  @spec prepare(
          CodexPooler.Access.auth_context(),
          String.t(),
          map(),
          RequestOptions.t(),
          Model.t(),
          visible_model_context()
        ) :: {:ok, prepared()} | {:error, GatewayContracts.gateway_error()}
  def prepare(
        auth,
        endpoint,
        payload,
        %RequestOptions{} = request_options,
        %Model{} = model,
        %{visible_model: %Model{} = visible_model, visible_models: visible_models} =
          visible_model_context
      )
      when is_list(visible_models) do
    with :ok <- authorize_model_policy(auth, model, endpoint, payload, request_options),
         {:ok, request_options} <-
           resolve_reasoning_effort(auth, model, payload, request_options),
         {:ok, request_options} <-
           SessionContinuity.attach_file_affinity(auth, endpoint, payload, request_options),
         :ok <- ensure_model_supports(model, endpoint, payload, request_options),
         :ok <- StrictSchema.validate(payload),
         :ok <- InputShape.validate(payload),
         {:ok, request_options, effective_model_serving_modes} <-
           resolve_model_serving_modes(
             auth,
             model,
             visible_model_context,
             visible_models,
             request_options
           ),
         {:ok, candidate_snapshots} <-
           CandidateEligibility.routable_candidates(visible_model_context, model),
         route_state =
           RouteState.new(%{
             visible_model_context: visible_model_context,
             visible_model: visible_model,
             visible_models: visible_models,
             effective_model_serving_modes: effective_model_serving_modes,
             candidate_snapshots: candidate_snapshots,
             candidates: candidate_snapshots,
             routing_settings: PoolRouting.routing_settings_with_defaults(auth.pool)
           })
           |> maybe_put_codex_models_etag(endpoint, request_options),
         {:ok, candidates} <-
           CandidateEligibility.filter_runtime_compatible_candidates(
             CandidateEligibility.FilterInput.new(%{
               auth: auth,
               model: model,
               endpoint: endpoint,
               payload: payload,
               request_options: request_options,
               candidates: candidate_snapshots
             })
           ),
         {:ok, candidates} <- SessionContinuity.filter_file_affinity(candidates, request_options),
         {:ok, candidates} <- CandidateEligibility.maybe_filter_compact(endpoint, candidates),
         {:ok, request_options} <-
           SessionContinuity.attach_codex_session(auth, payload, request_options),
         {:ok, candidates} <-
           SessionContinuity.apply_codex_session_assignment(candidates, request_options, model) do
      route_state =
        route_state
        |> RouteState.put_candidates(candidates)
        |> RouteState.preload_routing_snapshots(auth, model, request_options)
        |> RouteState.put_reservation_snapshot_inputs(
          AccountingReservation.reservation_snapshot_inputs(
            auth,
            model,
            payload,
            endpoint,
            request_options
          )
        )

      {:ok, %{request_options: request_options, candidates: candidates, route_state: route_state}}
    end
  end

  defp maybe_put_codex_models_etag(
         %RouteState{} = route_state,
         endpoint,
         %RequestOptions{} = request_options
       ) do
    if codex_models_etag_eligible?(endpoint, request_options) do
      policy = request_options.routing.api_key_policy

      visible_models = policy_visible_models(route_state, policy)

      pricing_buckets = CodexPooler.Catalog.pricing_buckets_by_identifier(visible_models)
      context_window_overrides = OperationalSettings.current().model_context_window_overrides

      %{etag: etag} =
        CodexCatalog.build(
          route_state.visible_models,
          policy,
          pricing_buckets,
          context_window_overrides,
          route_state.effective_model_serving_modes
        )

      RouteState.put_codex_models_etag(route_state, etag)
    else
      route_state
    end
  end

  defp codex_models_etag_eligible?(endpoint, %RequestOptions{} = request_options) do
    source_endpoint = request_options.openai_compatibility.source_endpoint || endpoint

    source_endpoint in [
      "/backend-api/codex/responses",
      "/backend-api/codex/v1/responses"
    ] and request_options.transport.transport in ["http_json", "http_sse"] and
      request_options.transport.route_class in [
        RouteClass.proxy_http(),
        RouteClass.proxy_stream()
      ]
  end

  defp visible_models(%RouteState{visible_models: models}) do
    Enum.filter(models, &match?(%Model{}, &1))
  end

  defp policy_visible_models(%RouteState{} = route_state, %{} = policy) do
    route_state
    |> visible_models()
    |> CandidateEligibility.policy_visible_models(policy)
  end

  defp policy_visible_models(%RouteState{} = route_state, nil), do: visible_models(route_state)

  defp resolve_model_serving_modes(
         auth,
         %Model{} = effective_model,
         visible_model_context,
         visible_models,
         %RequestOptions{} = request_options
       ) do
    policy_visible_models =
      case request_options.routing.api_key_policy do
        %{} = policy -> CandidateEligibility.policy_visible_models(visible_models, policy)
        nil -> visible_models
      end

    overrides =
      auth.pool.id
      |> then(&Pools.model_serving_modes_by_pool_ids([&1]))
      |> Map.get(auth.pool.id, %{})

    resolutions =
      Map.new(policy_visible_models, fn model ->
        resolution =
          ModelServingMode.resolve(
            Map.get(
              overrides,
              ModelServingOverride.canonical_exposed_model_id(model.exposed_model_id)
            ),
            ModelMetadata.metadata(model),
            routable_source_ids(visible_model_context, model)
          )

        {model.exposed_model_id, resolution}
      end)

    effective_modes =
      Map.new(resolutions, fn
        {model_identifier, {:ok, resolution}} ->
          {model_identifier, resolution.effective_mode}

        {model_identifier, :no_runtime_model} ->
          {model_identifier, nil}
      end)

    case Map.get(resolutions, effective_model.exposed_model_id) do
      {:ok, resolution} ->
        {:ok, RequestOptions.put_model_serving_mode(request_options, resolution), effective_modes}

      :no_runtime_model ->
        CandidateEligibility.routable_candidates(visible_model_context, effective_model)

      nil
      when request_options.routing.effective_model != effective_model.exposed_model_id ->
        {:ok, request_options, effective_modes}

      nil ->
        {:error, error(400, "invalid_model", "model is not available for this pool", "model")}
    end
  end

  defp routable_source_ids(visible_model_context, %Model{} = model) do
    visible_model_context
    |> Map.get(:candidates_by_model_id, %{})
    |> Map.get(model.id, [])
    |> Enum.map(fn {assignment, _identity} -> assignment.id end)
  end

  defp authorize_model_policy(
         _auth,
         %Model{} = model,
         _endpoint,
         _payload,
         %RequestOptions{} = opts
       ) do
    policy = opts.routing.api_key_policy

    model_identifier = opts.routing.effective_model || model.exposed_model_id

    case Access.authorize_api_key_policy(policy, %{model_identifier: model_identifier}) do
      {:ok, _policy} ->
        :ok

      {:error, reason} ->
        {:error, policy_error(reason)}
    end
  end

  defp resolve_reasoning_effort(auth, model, payload, request_options) do
    requested_effort = ReasoningEffort.extract(payload, request_options)

    {model_efforts, model_default} =
      reasoning_model_availability(auth.api_key, model)

    case Access.resolve_reasoning_effort(
           auth.api_key,
           requested_effort,
           model_efforts,
           model_default
         ) do
      {:ok, decision} ->
        {:ok, RequestOptions.put_routing(request_options, reasoning_effort_decision: decision)}

      {:error, :reasoning_effort_not_allowed} ->
        {:error,
         error(
           400,
           "reasoning_effort_not_allowed",
           "reasoning effort is not available for this API key",
           ReasoningEffort.parameter(request_options)
         )
         |> Map.put(
           :reasoning_policy,
           Access.project_reasoning_effort_denial_metadata(auth.api_key, requested_effort)
         )}
    end
  end

  defp reasoning_model_availability(%{maximum_reasoning_effort: effort}, model)
       when is_binary(effort),
       do: ModelMetadata.reasoning_levels_and_default(model)

  defp reasoning_model_availability(_api_key, _model), do: {nil, nil}

  defp ensure_model_supports(
         %Model{},
         "/backend-api/transcribe",
         _payload,
         %RequestOptions{payload_context: %{forced_transcription_model: model}}
       )
       when is_binary(model),
       do: :ok

  defp ensure_model_supports(%Model{} = model, "/backend-api/transcribe", _payload, _opts) do
    if ModelMetadata.has_capability_evidence?(model) and
         not ModelMetadata.supports_audio_transcription?(model) do
      {:error,
       error(
         400,
         "unsupported_model_capability",
         "model does not support audio transcription",
         "model"
       )}
    else
      :ok
    end
  end

  defp ensure_model_supports(%Model{} = model, _endpoint, payload, _opts) do
    cond do
      not model.supports_responses ->
        {:error,
         error(400, "unsupported_model_capability", "model does not support responses", "model")}

      RouteClass.streaming?(payload) and not model.supports_streaming ->
        {:error,
         error(400, "unsupported_model_capability", "model does not support streaming", "stream")}

      CandidateEligibility.payload_has_input_image?(payload) and
        ModelMetadata.has_capability_evidence?(model) and
          not ModelMetadata.supports_image_input?(ModelMetadata.metadata(model)) ->
        {:error,
         error(400, "unsupported_model_capability", "model does not support image input", "input")}

      true ->
        :ok
    end
  end

  defp policy_error(:model_not_allowed),
    do: error(403, "model_not_allowed", "api key is not allowed to use this model", nil)

  defp error(status, code, message, param),
    do: %{status: status, code: code, message: message, param: param}
end
