defmodule CodexPooler.Gateway.Runtime.Dispatch.PreDispatch do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Contracts, as: GatewayContracts
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.InputShape
  alias CodexPooler.Gateway.Payloads.PayloadNormalizer
  alias CodexPooler.Gateway.Payloads.ReasoningEffort
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.OpenAICompatibility
  alias CodexPooler.Gateway.Payloads.StrictSchema
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Gateway.Routing.PartitionRoutability
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame.ValidationClaim
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
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
  @type validation_authority ::
          :validate
          | {:prepared_websocket, ValidationClaim.t() | term()}
          | {:prepared_websocket, ValidationClaim.t() | term(), term()}

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
      }),
      :validate
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
        %{visible_model: %Model{}, visible_models: visible_models} = visible_model_context
      )
      when is_list(visible_models) do
    prepare(auth, endpoint, payload, request_options, model, visible_model_context, :validate)
  end

  @spec prepare(
          CodexPooler.Access.auth_context(),
          String.t(),
          map(),
          RequestOptions.t(),
          Model.t(),
          visible_model_context(),
          validation_authority()
        ) :: {:ok, prepared()} | {:error, GatewayContracts.gateway_error()}
  def prepare(
        auth,
        endpoint,
        payload,
        %RequestOptions{} = request_options,
        %Model{} = model,
        %{visible_model: %Model{} = visible_model, visible_models: visible_models} =
          visible_model_context,
        validation_authority
      )
      when is_list(visible_models) do
    visible_models = visible_models(visible_models)

    visible_model_context =
      visible_model_context
      |> Map.put(:visible_models, visible_models)
      |> put_valid_canonical_assignment_ids(model)

    has_input_image? = CandidateEligibility.payload_has_input_image?(payload)

    with :ok <- authorize_model_policy(auth, model, endpoint, payload, request_options),
         {:ok, request_options} <-
           resolve_reasoning_effort(auth, model, payload, request_options),
         {:ok, request_options} <-
           SessionContinuity.attach_file_affinity(auth, endpoint, payload, request_options),
         :ok <- ensure_model_supports(model, endpoint, payload, request_options, has_input_image?),
         :ok <- validate_strict_schema_once(payload, request_options, validation_authority),
         :ok <- validate_input_shape_once(payload, request_options, validation_authority),
         {:ok, request_options, effective_model_serving_modes} <-
           resolve_model_serving_modes(
             auth,
             model,
             visible_model_context,
             visible_models,
             request_options
           ),
         :ok <- validate_payload_once(payload, request_options, validation_authority),
         {:ok, candidate_snapshots} <-
           CandidateEligibility.routable_candidates(visible_model_context, model),
         quota_snapshots =
           RouteState.load_quota_snapshots(
             quota_snapshot_candidates(
               visible_model_context,
               candidate_snapshots,
               endpoint,
               request_options
             )
           ),
         visible_model_context =
           put_selected_partition_assignment_ids(
             visible_model_context,
             model,
             quota_snapshots
           ),
         request_options =
           put_canonical_partition_metadata(request_options, visible_model_context),
         route_state =
           RouteState.new(%{
             visible_model_context: visible_model_context,
             visible_model: visible_model,
             visible_models: visible_models,
             effective_model_serving_modes: effective_model_serving_modes,
             candidate_snapshots: candidate_snapshots,
             candidates: candidate_snapshots,
             quota_snapshots: quota_snapshots,
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
               has_input_image?: has_input_image?,
               request_options: request_options,
               candidates: candidate_snapshots
             })
           ),
         route_state = RouteState.put_saved_reset_auto_cohort(route_state, candidates),
         {:ok, request_options} <-
           SessionContinuity.attach_codex_session(auth, payload, request_options),
         canonical_filter_input_candidates = candidates,
         allowed_canonical_assignment_ids =
           allowed_canonical_assignment_ids(visible_model_context, request_options),
         {:ok, candidates} <-
           CandidateEligibility.filter_allowed_canonical_candidates(
             candidates,
             allowed_canonical_assignment_ids,
             continuity_assignment_ids(
               request_options,
               visible_model_context.valid_canonical_assignment_ids
             )
           ),
         {:ok, candidates, request_compatible_capacity} <-
           finish_canonical_filtering(
             candidates,
             canonical_filter_input_candidates,
             visible_model_context.valid_canonical_assignment_ids,
             endpoint,
             request_options,
             model
           ) do
      route_state =
        route_state
        |> RouteState.put_saved_reset_auto_capacity(request_compatible_capacity)
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

  defp validate_strict_schema(payload, %RequestOptions{openai_compatibility: compatibility}) do
    if OpenAICompatibility.translated_responses_surface?(compatibility),
      do: StrictSchema.validate_public(payload),
      else: StrictSchema.validate(payload)
  end

  defp validate_strict_schema_once(payload, request_options, validation_authority) do
    validate_once(:strict_schema, payload, request_options, validation_authority, fn ->
      validate_strict_schema(payload, request_options)
    end)
  end

  defp validate_input_shape_once(payload, request_options, validation_authority) do
    validate_once(:input_shape, payload, request_options, validation_authority, fn ->
      InputShape.validate(payload)
    end)
  end

  defp validate_payload_once(payload, request_options, validation_authority) do
    validate_once(:payload, payload, request_options, validation_authority, fn ->
      PayloadNormalizer.validate(payload, request_options)
    end)
  end

  defp validate_once(family, payload, request_options, validation_authority, validation)
       when is_function(validation, 0) do
    if valid_prepared_authority?(family, payload, request_options, validation_authority) do
      :ok
    else
      notify_validation_observer(request_options)
      validation.()
    end
  end

  defp valid_prepared_authority?(
         family,
         payload,
         request_options,
         {:prepared_websocket, claim}
       ),
       do: WebsocketCodec.prevalidated_request?(payload, request_options, claim, family)

  defp valid_prepared_authority?(
         family,
         payload,
         request_options,
         {:prepared_websocket, claim, _runtime_admission_proof}
       ),
       do: WebsocketCodec.prevalidated_request?(payload, request_options, claim, family)

  defp valid_prepared_authority?(_family, _payload, _request_options, :validate), do: false
  defp valid_prepared_authority?(_family, _payload, _request_options, _invalid), do: false

  if Mix.env() == :test do
    defp notify_validation_observer(%RequestOptions{
           extra: %{payload_validation_observer: observer}
         })
         when is_function(observer, 0),
         do: observer.()

    defp notify_validation_observer(%RequestOptions{}), do: :ok
  else
    defp notify_validation_observer(%RequestOptions{}), do: :ok
  end

  defp put_valid_canonical_assignment_ids(visible_model_context, %Model{} = model) do
    candidates =
      visible_model_context
      |> Map.get(:candidates_by_model_id, %{})
      |> Map.get(model.id, [])

    Map.put(
      visible_model_context,
      :valid_canonical_assignment_ids,
      CodexCatalog.valid_canonical_assignment_ids(model, candidates)
    )
  end

  defp quota_snapshot_candidates(
         visible_model_context,
         candidate_snapshots,
         endpoint,
         %RequestOptions{} = request_options
       ) do
    etag_candidates =
      if codex_models_etag_eligible?(endpoint, request_options) do
        visible_model_context
        |> context_policy_visible_models(request_options.routing.api_key_policy)
        |> Enum.flat_map(fn model ->
          visible_model_context
          |> Map.get(:candidates_by_model_id, %{})
          |> Map.get(model.id, [])
        end)
      else
        []
      end

    (candidate_snapshots ++ etag_candidates)
    |> Enum.uniq_by(fn {assignment, identity} -> {assignment.id, identity.id} end)
  end

  defp context_policy_visible_models(visible_model_context, %{} = policy) do
    visible_model_context
    |> Map.get(:visible_models, [])
    |> policy_visible_models(policy)
  end

  defp context_policy_visible_models(visible_model_context, nil),
    do: visible_model_context |> Map.get(:visible_models, []) |> policy_visible_models(nil)

  # Runs after policy, payload validation, and candidate hydration so the quota
  # snapshot that feeds partition selection is read once, only for requests that
  # can still dispatch, and is then reused by the routing snapshots.
  defp put_selected_partition_assignment_ids(
         visible_model_context,
         %Model{} = model,
         quota_snapshots
       ) do
    candidates_by_model_id = Map.get(visible_model_context, :candidates_by_model_id, %{})

    partition =
      [model]
      |> CodexCatalog.select_canonical_sources(candidates_by_model_id,
        routable_assignment_ids_by_model_id: fn ->
          PartitionRoutability.routable_assignment_ids_by_model_id(
            [model],
            candidates_by_model_id,
            quota_snapshots
          )
        end
      )
      |> List.first()

    visible_model_context
    |> Map.put(:selected_partition_assignment_ids, selected_partition_assignment_ids(partition))
    |> Map.put(
      :canonical_partition_summary,
      canonical_partition_summary(partition, visible_model_context)
    )
  end

  defp selected_partition_assignment_ids(%{assignment_ids: assignment_ids}), do: assignment_ids
  defp selected_partition_assignment_ids(nil), do: []

  # Bounded, metadata-only evidence that canonical partition filtering held back
  # otherwise-valid assignments. Without it a partition-starved pool logs a
  # quota denial naming only the seats inside the selected partition, and an
  # operator cannot tell that the healthy seats were never read at all. Only a
  # 12-character digest prefix is recorded — never a full digest or any payload.
  defp canonical_partition_summary(nil, _visible_model_context), do: nil
  defp canonical_partition_summary(%{partition_count: 1}, _visible_model_context), do: nil

  defp canonical_partition_summary(partition, visible_model_context) do
    selected_count = length(partition.assignment_ids)

    valid_count =
      visible_model_context
      |> Map.get(:valid_canonical_assignment_ids, [])
      |> length()

    %{
      "digest_prefix" => String.slice(partition.digest, 0, 12),
      "partition_count" => partition.partition_count,
      "selected_count" => selected_count,
      "filtered_count" => max(valid_count - selected_count, 0),
      "routable_selection" => partition.routable_selection?
    }
  end

  # Only the surfaces that are actually capped to one partition carry the
  # evidence. The translated Responses surface starts from every valid canonical
  # assignment, so reporting seats as filtered there would be a lie.
  defp put_canonical_partition_metadata(
         %RequestOptions{openai_compatibility: compatibility} = request_options,
         visible_model_context
       ) do
    summary = Map.get(visible_model_context, :canonical_partition_summary)

    if is_map(summary) and not OpenAICompatibility.translated_responses_surface?(compatibility) do
      RequestOptions.put_routing(request_options, canonical_partition: summary)
    else
      request_options
    end
  end

  defp continuity_assignment_ids(%RequestOptions{} = request_options, valid_assignment_ids) do
    valid_assignment_ids = MapSet.new(valid_assignment_ids)

    [
      request_options.routing.file_affinity_assignment_id,
      codex_session_assignment_id(request_options)
    ]
    |> Enum.filter(&(is_binary(&1) and MapSet.member?(valid_assignment_ids, &1)))
    |> Enum.uniq()
  end

  defp codex_session_assignment_id(%RequestOptions{
         continuity: %{codex_session: %{pool_upstream_assignment_id: assignment_id}}
       }),
       do: assignment_id

  defp codex_session_assignment_id(%RequestOptions{}), do: nil

  defp allowed_canonical_assignment_ids(
         visible_model_context,
         %RequestOptions{openai_compatibility: compatibility}
       ) do
    if OpenAICompatibility.translated_responses_surface?(compatibility) do
      visible_model_context.valid_canonical_assignment_ids
    else
      visible_model_context.selected_partition_assignment_ids
    end
  end

  defp finish_canonical_filtering(
         candidates,
         canonical_filter_input_candidates,
         valid_canonical_assignment_ids,
         endpoint,
         %RequestOptions{} = request_options,
         %Model{} = model
       ) do
    result =
      with {:ok, candidates} <-
             SessionContinuity.filter_file_affinity(candidates, request_options),
           {:ok, candidates} <- CandidateEligibility.maybe_filter_compact(endpoint, candidates),
           request_compatible_capacity = candidates,
           {:ok, candidates} <-
             SessionContinuity.apply_codex_session_assignment(candidates, request_options, model),
           :ok <- ensure_candidates_available(candidates) do
        {:ok, candidates, request_compatible_capacity}
      end

    if canonical_filter_zero_work?(
         result,
         candidates,
         canonical_filter_input_candidates,
         valid_canonical_assignment_ids,
         request_options
       ) do
      mark_zero_work_error(result)
    else
      result
    end
  end

  defp canonical_filter_zero_work?(
         _result,
         [],
         _canonical_filter_input_candidates,
         _valid_canonical_assignment_ids,
         %RequestOptions{}
       ),
       do: true

  defp canonical_filter_zero_work?(
         {:error, %{code: "pinned_continuation_unavailable"}},
         _candidates,
         canonical_filter_input_candidates,
         valid_canonical_assignment_ids,
         %RequestOptions{} = request_options
       ) do
    assignment_id = codex_session_assignment_id(request_options)

    is_binary(assignment_id) and
      Enum.any?(canonical_filter_input_candidates, fn {assignment, _identity} ->
        assignment.id == assignment_id
      end) and assignment_id not in valid_canonical_assignment_ids
  end

  defp canonical_filter_zero_work?(
         _result,
         _candidates,
         _canonical_filter_input_candidates,
         _valid_canonical_assignment_ids,
         %RequestOptions{}
       ),
       do: false

  defp mark_zero_work_error({:error, reason}),
    do: {:error, Map.put(reason, :accounting_disposition, :zero_work)}

  defp mark_zero_work_error(result), do: result

  defp ensure_candidates_available([_candidate | _candidates]), do: :ok

  defp ensure_candidates_available([]) do
    {:error,
     error(
       503,
       "no_eligible_backend",
       "no healthy eligible backend is currently available",
       "model"
     )}
  end

  defp maybe_put_codex_models_etag(
         %RouteState{} = route_state,
         endpoint,
         %RequestOptions{} = request_options
       ) do
    if codex_models_etag_eligible?(endpoint, request_options) do
      policy = request_options.routing.api_key_policy

      visible_models = policy_visible_models(route_state.visible_models, policy)

      pricing_buckets = CodexPooler.Catalog.pricing_buckets_by_identifier(visible_models)
      context_window_overrides = OperationalSettings.current().model_context_window_overrides

      candidates_by_model_id =
        Map.get(route_state.visible_model_context, :candidates_by_model_id, %{})

      %{etag: etag} =
        CodexCatalog.build_canonical(
          visible_models,
          candidates_by_model_id,
          policy,
          pricing_buckets,
          context_window_overrides,
          route_state.effective_model_serving_modes,
          routable_assignment_ids_by_model_id: fn ->
            PartitionRoutability.routable_assignment_ids_by_model_id(
              visible_models,
              candidates_by_model_id,
              route_state.quota_snapshots
            )
          end
        )

      RouteState.put_codex_models_etag(route_state, etag)
    else
      route_state
    end
  end

  defp codex_models_etag_eligible?(endpoint, %RequestOptions{} = request_options) do
    source_endpoint = request_options.openai_compatibility.source_endpoint || endpoint

    native_responses? =
      source_endpoint in [
        "/backend-api/codex/responses",
        "/backend-api/codex/v1/responses"
      ]

    supported_transport? =
      {request_options.transport.transport, request_options.transport.route_class} in [
        {"http_json", RouteClass.proxy_http()},
        {"http_sse", RouteClass.proxy_stream()},
        {"websocket", RouteClass.proxy_websocket()}
      ]

    native_responses? and supported_transport?
  end

  defp visible_models(models) when is_list(models) do
    Enum.filter(models, &match?(%Model{}, &1))
  end

  defp policy_visible_models(models, %{} = policy) when is_list(models) do
    models
    |> visible_models()
    |> CandidateEligibility.policy_visible_models(policy)
  end

  defp policy_visible_models(models, nil) when is_list(models), do: visible_models(models)

  defp resolve_model_serving_modes(
         auth,
         %Model{} = effective_model,
         visible_model_context,
         visible_models,
         %RequestOptions{} = request_options
       ) do
    policy_visible_models =
      policy_visible_models(visible_models, request_options.routing.api_key_policy)

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

      nil ->
        resolve_visible_image_host_serving_mode(
          overrides,
          effective_model,
          visible_model_context,
          request_options,
          effective_modes
        )
    end
  end

  defp resolve_visible_image_host_serving_mode(
         overrides,
         %Model{} = effective_model,
         visible_model_context,
         %RequestOptions{} = request_options,
         effective_modes
       ) do
    cond do
      visible_image_host_request?(request_options, effective_model) ->
        resolution =
          ModelServingMode.resolve(
            Map.get(
              overrides,
              ModelServingOverride.canonical_exposed_model_id(effective_model.exposed_model_id)
            ),
            ModelMetadata.metadata(effective_model),
            routable_source_ids(visible_model_context, effective_model)
          )

        case resolution do
          {:ok, resolution} ->
            {:ok, RequestOptions.put_model_serving_mode(request_options, resolution),
             effective_modes}

          :no_runtime_model ->
            CandidateEligibility.routable_candidates(visible_model_context, effective_model)
        end

      request_options.routing.effective_model != effective_model.exposed_model_id ->
        {:ok, request_options, effective_modes}

      true ->
        {:error, error(400, "invalid_model", "model is not available for this pool", "model")}
    end
  end

  defp visible_image_host_request?(
         %RequestOptions{
           routing: %{effective_model: requested_model},
           openai_compatibility: %{collect_openai_image_stream: true}
         },
         %Model{exposed_model_id: host_model}
       )
       when is_binary(requested_model) and is_binary(host_model),
       do: requested_model != host_model

  defp visible_image_host_request?(%RequestOptions{}, %Model{}), do: false

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
         %RequestOptions{payload_context: %{forced_transcription_model: model}},
         _has_input_image?
       )
       when is_binary(model),
       do: :ok

  defp ensure_model_supports(
         %Model{} = model,
         "/backend-api/transcribe",
         _payload,
         _opts,
         _has_input_image?
       ) do
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

  defp ensure_model_supports(%Model{} = model, _endpoint, payload, _opts, has_input_image?) do
    cond do
      not model.supports_responses ->
        {:error,
         error(400, "unsupported_model_capability", "model does not support responses", "model")}

      RouteClass.streaming?(payload) and not model.supports_streaming ->
        {:error,
         error(400, "unsupported_model_capability", "model does not support streaming", "stream")}

      has_input_image? and
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
