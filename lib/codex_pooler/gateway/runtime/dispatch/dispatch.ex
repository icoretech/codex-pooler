defmodule CodexPooler.Gateway.Runtime.Dispatch do
  @moduledoc """
  Runtime route dispatch lifecycle after a request has been admitted and reserved.
  """

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Gateway.Contracts, as: GatewayContracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput, RoutingSelection}
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Gateway.Runtime.Finalization.AttemptSettlement

  @type dispatch_input :: %{
          required(:auth) => CodexPooler.Access.auth_context(),
          required(:endpoint) => String.t(),
          required(:payload) => map(),
          required(:model) => CodexPooler.Catalog.Model.t(),
          required(:reserved) => Accounting.request_result_row(),
          required(:candidates) => [BridgeRing.candidate()],
          required(:request_options) => RequestOptions.t(),
          required(:route_state) => RouteState.t()
        }

  @type dispatch_callback ::
          (Context.t() ->
             {:ok, GatewayContracts.gateway_result()} | {:error, map()} | {:retry, term()})
  @type dispatch_context :: Context.t()
  @type dispatch_result ::
          {:ok, GatewayContracts.gateway_result()} | {:error, map()} | {:retry, term() | nil}

  @spec dispatch(dispatch_input(), dispatch_callback()) ::
          {:ok, GatewayContracts.gateway_result()} | {:error, map()}
  def dispatch(input, transport_dispatch)
      when is_map(input) and is_function(transport_dispatch, 1) do
    with {:ok, context} <- build_context(input) do
      context
      |> dispatch_from(0, transport_dispatch)
      |> finalize_dispatch_result()
    end
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

  defp build_context(input) do
    request_options = Map.fetch!(input, :request_options)

    route_plan =
      BridgeRing.plan_route(
        input.auth,
        input.model,
        input.candidates,
        RoutePlanInput.from_reserved(input.reserved),
        request_options,
        input.route_state
      )

    case Accounting.accumulate_request_metadata(input.reserved.request, %{
           "routing" => route_plan.request_metadata
         }) do
      {:ok, request} ->
        {:ok,
         %Context{
           auth: input.auth,
           endpoint: input.endpoint,
           payload: input.payload,
           model: input.model,
           reserved: %{input.reserved | request: request},
           candidates: input.candidates,
           request_options: request_options,
           route_state: input.route_state,
           route_plan: route_plan,
           route_class: request_options.transport.route_class
         }}

      {:error, reason} ->
        FailureResponse.accounting_failure(
          :merge_route_plan_metadata,
          input.reserved.request,
          nil,
          reason
        )
    end
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
         {:ok, context} <- persist_route_metadata(context),
         {:ok, context} <- begin_candidate_circuit(context, selection),
         {:ok, context} <- start_dispatch_attempt(context) do
      transport_dispatch.(context)
    end
  end

  defp begin_candidate_circuit(%Context{} = context, %RoutingSelection{} = selection) do
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
          RequestOptions.put_routing(context.request_options,
            routing_attempt_metadata: selection.attempt_metadata
          )

        selected_context =
          context
          |> refresh_request_options(request_options)
          |> Map.merge(%{
            reserved: %{context.reserved | request: request},
            assignment: selection.assignment,
            identity: selection.identity,
            index: selection.index,
            retry_count: selection.index,
            allow_retry?: allow_retry?,
            routing_attempt_metadata: selection.attempt_metadata,
            route_class: selection.route_class
          })

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

  defp put_routing_circuit_state(%Context{} = context, %RoutingCircuitState{} = state) do
    request_options =
      RequestOptions.put_routing(context.request_options, routing_circuit_state: state)

    context
    |> refresh_request_options(request_options)
    |> Map.put(:routing_circuit_state, state)
  end

  defp put_routing_circuit_state(%Context{} = context, nil), do: context

  defp persist_route_metadata(%Context{} = context) do
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

  defp route_metadata_reload?(%Context{index: index}), do: index != 0

  defp start_dispatch_attempt(%Context{} = context) do
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

      {:error, reason} ->
        FailureResponse.accounting_failure(
          :create_attempt,
          context.reserved.request,
          nil,
          reason
        )
    end
  end

  defp refresh_request_options(context, %RequestOptions{} = request_options) do
    %{
      context
      | request_options: request_options,
        route_class: request_options.transport.route_class
    }
  end

  defp handle_unavailable_routing_circuit(%Context{} = context, reason) do
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
