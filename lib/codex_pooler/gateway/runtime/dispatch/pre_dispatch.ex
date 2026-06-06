defmodule CodexPooler.Gateway.Runtime.Dispatch.PreDispatch do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Contracts, as: GatewayContracts
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Gateway.Payloads.InputShape
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.StrictSchema
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Pools
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
           SessionContinuity.attach_file_affinity(auth, endpoint, payload, request_options),
         :ok <- ensure_model_supports(model, endpoint, payload, request_options),
         :ok <- StrictSchema.validate(payload),
         :ok <- InputShape.validate(payload),
         {:ok, candidate_snapshots} <-
           CandidateEligibility.routable_candidates(visible_model_context, model),
         route_state =
           RouteState.new(%{
             visible_model_context: visible_model_context,
             visible_model: visible_model,
             visible_models: visible_models,
             candidate_snapshots: candidate_snapshots,
             candidates: candidate_snapshots,
             routing_settings: Pools.routing_settings_with_defaults(auth.pool)
           }),
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

  defp authorize_model_policy(auth, %Model{} = model, endpoint, payload, %RequestOptions{} = opts) do
    policy = opts.routing.api_key_policy

    model_identifier = opts.routing.effective_model || model.exposed_model_id

    case Access.authorize_api_key_policy(policy, %{model_identifier: model_identifier}) do
      {:ok, _policy} ->
        :ok

      {:error, reason} ->
        Denials.log_policy(denial_context(auth, model, reason, endpoint, payload, opts))
    end
  end

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

  defp denial_context(auth, model, reason, endpoint, payload, opts) do
    %Denials.Context{
      auth: auth,
      model: model,
      reason: reason,
      endpoint: endpoint,
      payload: payload,
      opts: opts
    }
  end

  defp error(status, code, message, param),
    do: %{status: status, code: code, message: message, param: param}
end
