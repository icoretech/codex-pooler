defmodule CodexPooler.Gateway.Runtime.Dispatch do
  @moduledoc """
  Runtime route dispatch lifecycle after a request has been admitted and reserved.
  """

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Gateway.Contracts, as: GatewayContracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.{ModelMetadata, RouteLifecycle, RoutingSelection}
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization.AttemptSettlement

  @type dispatch_callback ::
          (SelectedCandidateContext.t() ->
             {:ok, GatewayContracts.gateway_result()} | {:error, map()} | {:retry, term()})
  @type dispatch_context :: Context.t() | SelectedCandidateContext.t()
  @type dispatch_result ::
          {:ok, GatewayContracts.gateway_result()} | {:error, map()} | {:retry, term() | nil}

  @spec dispatch(Context.t(), dispatch_callback()) ::
          {:ok, GatewayContracts.gateway_result()} | {:error, map()}
  def dispatch(%Context{} = context, transport_dispatch)
      when is_function(transport_dispatch, 1) do
    context
    |> dispatch_from(0, transport_dispatch)
    |> finalize_dispatch_result()
  end

  @spec dispatch_from(dispatch_context(), non_neg_integer(), dispatch_callback()) ::
          dispatch_result()
  def dispatch_from(context, start_index, transport_dispatch)
      when is_integer(start_index) and start_index >= 0 and is_function(transport_dispatch, 1) do
    context.route_plan.candidates
    |> Enum.with_index()
    |> Enum.drop(start_index)
    |> Enum.reduce_while({:retry, nil}, fn {{assignment, identity}, index}, _last ->
      allow_retry? = index < length(context.route_plan.candidates) - 1

      case dispatch_candidate(
             context,
             assignment,
             identity,
             index,
             allow_retry?,
             transport_dispatch
           ) do
        {:retry, reason} -> {:cont, {:retry, reason}}
        {:ok, result} -> {:halt, {:ok, result}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec candidate_available?(dispatch_context(), non_neg_integer()) :: boolean()
  def candidate_available?(context, index) when is_integer(index) and index >= 0 do
    index < length(context.route_plan.candidates)
  end

  defp finalize_dispatch_result({:retry, _reason}) do
    {:error,
     error(
       503,
       "no_eligible_backend",
       "no healthy eligible backend is currently available",
       "model"
     )}
  end

  defp finalize_dispatch_result(result) do
    result
  end

  @spec dispatch_candidate(
          dispatch_context(),
          term(),
          term(),
          non_neg_integer(),
          boolean(),
          dispatch_callback()
        ) ::
          {:ok, GatewayContracts.gateway_result()} | {:error, map()} | {:retry, term()}
  defp dispatch_candidate(
         context,
         assignment,
         identity,
         index,
         allow_retry?,
         transport_dispatch
       )
       when is_function(transport_dispatch, 1) do
    selection =
      RoutingSelection.prepare_candidate(%{
        route_plan: context.route_plan,
        assignment: assignment,
        identity: identity,
        index: index,
        route_class: context.route_class
      })

    with {:ok, context} <- apply_route_selection(context, selection, allow_retry?),
         {:ok, context} <- validate_reset_probe_scope(context),
         {:ok, context} <- persist_route_metadata(context),
         {:ok, context} <- begin_candidate_circuit(context, selection),
         {:ok, context} <- start_dispatch_attempt(context, selection) do
      transport_dispatch.(context)
    end
  end

  defp begin_candidate_circuit(
         %SelectedCandidateContext{} = context,
         %RoutingSelection{} = selection
       ) do
    case RoutingSelection.begin_circuit(selection, context.auth, context.model) do
      {:ok, %{circuit_state: circuit_state}} ->
        {:ok, put_routing_circuit_state(context, circuit_state)}

      {:error, reason}
      when reason in [:routing_circuit_open, :routing_circuit_probe_in_flight] ->
        handle_unavailable_routing_circuit(context, reason)

      {:error, reason} ->
        FailureResponse.accounting_failure(
          :begin_routing_circuit_attempt,
          context.reserved.request,
          nil,
          reason
        )
    end
  end

  defp apply_route_selection(context, %RoutingSelection{} = selection, allow_retry?) do
    case Accounting.accumulate_request_metadata(
           context.reserved.request,
           selection.selected_metadata
         ) do
      {:ok, request} ->
        request_options =
          RequestOptions.put_routing(
            context.request_options,
            route_selection_updates(context, selection)
          )

        selected_context =
          context
          |> refresh_request_options(request_options)
          |> Map.put(:reserved, %{context.reserved | request: request})
          |> SelectedCandidateContext.from_dispatch_context(selection, allow_retry?)

        {:ok, selected_context}

      {:error, reason} ->
        FailureResponse.accounting_failure(
          :merge_route_selection_metadata,
          context.reserved.request,
          nil,
          reason
        )
    end
  end

  @spec route_selection_updates(dispatch_context(), RoutingSelection.t()) :: keyword()
  defp route_selection_updates(context, %RoutingSelection{} = selection) do
    updates = [
      routing_attempt_metadata: selection.attempt_metadata,
      supports_reasoning_summary_parameter?:
        selected_supports_reasoning_summary_parameter?(
          context.model,
          selection.assignment
        )
    ]

    case RequestOptions.model_serving_mode_snapshot(context.request_options) do
      nil ->
        Keyword.put(
          updates,
          :use_responses_lite?,
          selected_uses_responses_lite?(context.model, selection.assignment)
        )

      _resolved_snapshot ->
        updates
    end
  end

  defp selected_uses_responses_lite?(model, assignment) do
    metadata = ModelMetadata.selected_assignment_metadata(model, assignment.id)
    ModelMetadata.bool_metadata(metadata, "use_responses_lite")
  end

  defp selected_supports_reasoning_summary_parameter?(model, assignment) do
    model
    |> ModelMetadata.selected_assignment_metadata(assignment.id)
    |> ModelMetadata.supports_reasoning_summary_parameter?()
  end

  defp put_routing_circuit_state(
         %SelectedCandidateContext{} = context,
         %RoutingCircuitState{} = state
       ) do
    request_options =
      RequestOptions.put_routing(context.request_options, routing_circuit_state: state)

    context
    |> refresh_request_options(request_options)
    |> Map.put(:routing_circuit_state, state)
  end

  defp put_routing_circuit_state(%SelectedCandidateContext{} = context, nil), do: context

  defp persist_route_metadata(%SelectedCandidateContext{} = context) do
    case Accounting.persist_request_metadata(context.reserved.request,
           reload?: route_metadata_reload?(context)
         ) do
      {:ok, request} ->
        {:ok, %{context | reserved: %{context.reserved | request: request}}}

      {:error, reason} ->
        FailureResponse.accounting_failure(
          :merge_route_selection_metadata,
          context.reserved.request,
          nil,
          reason
        )
    end
  end

  defp validate_reset_probe_scope(%SelectedCandidateContext{} = context) do
    case context.request_options.routing.reset_probe do
      %ResetProbe{} = probe ->
        validate_bound_reset_probe_scope(context, probe)

      nil ->
        {:ok, context}
    end
  end

  defp validate_bound_reset_probe_scope(context, %ResetProbe{} = probe) do
    cond do
      ResetProbe.unbound?(probe) ->
        {:ok, context}

      ResetProbe.matches?(
        probe,
        context.assignment.id,
        context.identity.id,
        effective_model(context),
        context.route_class
      ) ->
        {:ok, context}

      true ->
        finalize_reset_probe_scope_mismatch(context)
    end
  end

  defp effective_model(%SelectedCandidateContext{} = context),
    do: context.request_options.routing.effective_model || context.model.exposed_model_id

  defp finalize_reset_probe_scope_mismatch(%SelectedCandidateContext{} = context) do
    case AttemptSettlement.finalize_reservation_failure(context.reserved.request, %{
           response_status_code: 503,
           last_error_code: "no_eligible_backend",
           usage_status: "not_applicable"
         }) do
      {:ok, _finalized} ->
        {:error,
         error(
           503,
           "no_eligible_backend",
           "no healthy eligible backend is currently available",
           "model"
         )}

      {:error, gateway_error} ->
        {:error, gateway_error}
    end
  end

  defp route_metadata_reload?(%SelectedCandidateContext{index: index}), do: index != 0

  defp start_dispatch_attempt(
         %SelectedCandidateContext{} = context,
         %RoutingSelection{} = selection
       ) do
    case Accounting.create_attempt(context.reserved.request, context.assignment, %{
           model: context.model,
           pricing_snapshot: Map.get(context.reserved, :pricing_snapshot),
           upstream_identity: context.identity,
           response_metadata:
             Map.merge(context.request_options.routing.routing_attempt_metadata || %{}, %{
               "pool_upstream_assignment_id" => context.assignment.id,
               "upstream_identity_id" => context.identity.id
             })
         }) do
      {:ok, attempt} ->
        {:ok, %{context | attempt: attempt, started: System.monotonic_time(:millisecond)}}

      {:error, %{code: :request_already_finalized}} ->
        release_unstarted_attempt_circuit(
          context,
          selection,
          "release_finalized_request_circuit_probe"
        )

        {:error,
         error(
           499,
           "request_already_finalized",
           "request lifecycle completed before upstream dispatch",
           "request"
         )}

      {:error, reason} ->
        release_unstarted_attempt_circuit(
          context,
          selection,
          "release_failed_attempt_circuit_probe"
        )

        FailureResponse.accounting_failure(
          :create_attempt,
          context.reserved.request,
          nil,
          reason
        )
    end
  end

  # No attempt started and no upstream was contacted, so the circuit
  # acquisition (including a claimed half-open probe slot) must complete
  # neutrally: it would otherwise strand probe_in_flight_count until the
  # staleness self-heal.
  defp release_unstarted_attempt_circuit(context, %RoutingSelection{} = selection, operation) do
    selection = %{selection | circuit_state: context.routing_circuit_state}

    RouteLifecycle.log_optional_result(
      operation,
      [request_id: context.reserved.request.id],
      RouteLifecycle.selection_neutral_completion(context.auth, context.model, selection)
    )
  end

  defp refresh_request_options(context, %RequestOptions{} = request_options) do
    %{
      context
      | request_options: request_options,
        route_class: request_options.transport.route_class
    }
  end

  defp handle_unavailable_routing_circuit(%SelectedCandidateContext{} = context, reason) do
    if context.allow_retry? do
      {:retry, reason}
    else
      case AttemptSettlement.finalize_reservation_failure(context.reserved.request, %{
             response_status_code: 503,
             last_error_code: "no_eligible_backend",
             usage_status: "not_applicable"
           }) do
        {:ok, _finalized} ->
          {:error,
           error(
             503,
             "no_eligible_backend",
             "no healthy eligible backend is currently available",
             "model"
           )}

        {:error, gateway_error} ->
          {:error, gateway_error}
      end
    end
  end

  defp error(status, code, message, param) do
    %{
      status: status,
      code: code,
      message: message,
      param: param
    }
  end
end
