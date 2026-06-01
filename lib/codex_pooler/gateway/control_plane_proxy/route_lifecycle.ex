defmodule CodexPooler.Gateway.ControlPlaneProxy.RouteLifecycle do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.ControlPlaneProxy
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState

  alias CodexPooler.Gateway.Routing.{
    CandidateEligibility,
    RouteFiltering,
    RouteLifecycle,
    RoutePlanInput,
    RoutingSelection
  }

  alias CodexPooler.Pools

  @control_plane_model_identifier "__control_plane__"

  @type auth :: ControlPlaneProxy.auth()
  @type gateway_error :: ControlPlaneProxy.gateway_error()

  @spec select_and_begin_route(
          auth(),
          String.t(),
          RequestOptions.t(),
          CodexPooler.Pools.RoutingSettings.t() | nil
        ) ::
          {:ok, Model.t(), RoutingSelection.t(), RequestOptions.t()} | {:error, gateway_error()}
  def select_and_begin_route(
        auth,
        endpoint,
        %RequestOptions{} = request_options,
        routing_settings \\ nil
      ) do
    with {:ok, model, visibility, routing_settings} <-
           control_plane_route_model(auth, routing_settings),
         {:ok, candidate_snapshots} <- CandidateEligibility.routable_candidates(visibility, model),
         route_state =
           control_plane_route_state(model, visibility, candidate_snapshots, routing_settings)
           |> RouteState.preload_routing_snapshots(auth, model, request_options),
         {:ok, candidates, request_options, route_state} <-
           route_filter_input(auth, model, endpoint, request_options, candidate_snapshots)
           |> RouteFiltering.filter_candidates(route_state, quota_mode: :optional),
         {:ok, selection} <-
           RoutingSelection.select_and_begin_circuit(%{
             auth: auth,
             model: model,
             candidates: candidates,
             route_plan_input: RoutePlanInput.from_request_opts(request_options),
             endpoint: endpoint,
             payload: %{},
             request_options: request_options,
             route_state: route_state
           }) do
      {:ok, model, selection, request_options}
    else
      {:error, %{status: _status} = reason} ->
        {:error, reason}

      {:error, %{code: :no_eligible_backend}} ->
        {:error, no_eligible_backend_error()}

      {:error, reason} ->
        {:error, error(503, to_string(reason), "control-plane backend is unavailable")}
    end
  end

  @spec record_outcome(auth(), Model.t(), RoutingSelection.t(), non_neg_integer()) :: :ok
  def record_outcome(auth, model, selection, status) when status in 200..299 do
    record_result(
      "control_plane_route_success",
      selection,
      RouteLifecycle.selection_success(auth, model, selection)
    )
  end

  def record_outcome(auth, model, selection, 401) do
    record_result(
      "control_plane_route_failure",
      selection,
      RouteLifecycle.selection_failure(
        auth,
        model,
        selection,
        nil,
        "upstream_unauthorized"
      )
    )
  end

  def record_outcome(auth, model, selection, status) when status >= 500 do
    record_result(
      "control_plane_route_failure",
      selection,
      RouteLifecycle.selection_failure(auth, model, selection, nil, "upstream_5xx")
    )
  end

  def record_outcome(_auth, _model, _selection, _status), do: :ok

  @spec record_dispatch_failure(auth(), Model.t(), RoutingSelection.t(), String.t()) :: :ok
  def record_dispatch_failure(auth, model, selection, code) do
    record_result(
      "control_plane_route_dispatch_failure",
      selection,
      RouteLifecycle.selection_failure(auth, model, selection, nil, code)
    )
  end

  defp control_plane_route_model(auth, routing_settings) do
    case Access.normalize_api_key_policy(auth.api_key) do
      {:ok, policy} ->
        routing_settings = routing_settings || Pools.routing_settings_with_defaults(auth.pool)
        visibility = CandidateEligibility.hydrate_model_visibility(auth.pool)
        models = CandidateEligibility.policy_visible_models(visibility, policy)

        case configured_control_plane_model(auth.pool, models, routing_settings) do
          {:ok, %Model{} = model} -> {:ok, model, visibility, routing_settings}
          :default -> default_control_plane_model(auth.pool, models, visibility, routing_settings)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error,
         error(401, to_string(reason), "API key policy could not be evaluated", "authorization")}
    end
  end

  defp configured_control_plane_model(_pool, models, routing_settings) do
    case configured_control_plane_model_identifier(routing_settings) do
      nil -> :default
      identifier -> find_configured_control_plane_model(identifier, models)
    end
  end

  defp find_configured_control_plane_model(identifier, models) do
    Enum.find_value(models, {:error, control_plane_model_unavailable_error()}, fn model ->
      if identifier in [model.exposed_model_id, model.upstream_model_id], do: {:ok, model}
    end)
  end

  defp configured_control_plane_model_identifier(%{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("control_plane_model", Map.get(metadata, "control_plane_model_identifier"))
    |> clean_string()
  end

  defp configured_control_plane_model_identifier(_settings), do: nil

  defp default_control_plane_model(pool, models, visibility, routing_settings) do
    case models do
      [] ->
        {:error, error(400, "invalid_model", "model is not available for this pool", "model")}

      models ->
        source_assignment_ids = visible_source_assignment_ids(models, visibility)

        {:ok,
         %Model{
           pool_id: pool.id,
           upstream_model_id: @control_plane_model_identifier,
           exposed_model_id: @control_plane_model_identifier,
           display_name: "Control plane",
           status: "active",
           supports_responses: true,
           supports_streaming: false,
           supports_tools: false,
           supports_reasoning: false,
           source_assignment_count: length(source_assignment_ids),
           metadata: %{
             "control_plane_route" => true,
             "source_assignment_ids" => source_assignment_ids
           }
         }, visibility, routing_settings}
    end
  end

  defp control_plane_route_state(model, visibility, candidate_snapshots, routing_settings) do
    RouteState.new(%{
      visible_model_context: Map.put(visibility, :visible_model, model),
      visible_model: model,
      visible_models: [model],
      candidate_snapshots: candidate_snapshots,
      candidates: candidate_snapshots,
      routing_settings: routing_settings
    })
  end

  defp clean_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp clean_string(_value), do: nil

  defp control_plane_model_unavailable_error do
    error(400, "invalid_model", "control-plane model is not available for this pool", "model")
  end

  defp visible_source_assignment_ids(models, visibility) do
    visible_candidates = Map.get(visibility, :visible_candidates_by_model_id, %{})

    models
    |> Enum.flat_map(fn model ->
      visible_candidates
      |> Map.get(model.id, [])
      |> Enum.map(fn {assignment, _identity} -> assignment.id end)
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp route_filter_input(auth, model, endpoint, request_options, candidates) do
    CandidateEligibility.FilterInput.new(%{
      auth: auth,
      model: model,
      endpoint: endpoint,
      payload: %{},
      request_options: request_options,
      candidates: candidates
    })
  end

  defp record_result(operation, selection, result) do
    RouteLifecycle.log_optional_result(operation, metadata(selection), result)
  end

  defp metadata(selection) do
    [
      pool_upstream_assignment_id: selection.assignment.id,
      route_class: selection.route_class
    ]
  end

  defp no_eligible_backend_error do
    error(
      503,
      "no_eligible_backend",
      "no healthy eligible backend is currently available",
      "model"
    )
  end

  defp error(status, code, message, param \\ nil, metadata \\ %{}),
    do: Map.merge(%{status: status, code: code, message: message, param: param}, metadata)
end
