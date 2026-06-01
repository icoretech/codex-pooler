defmodule CodexPooler.Gateway.Routing.RoutingSelection do
  @moduledoc """
  Concrete route-plan selection for gateway dispatch surfaces.
  """

  alias CodexPooler.Access
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.{BridgeRing, CircuitState, RoutePlanInput}
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  defstruct [
    :assignment,
    :identity,
    :index,
    :route_plan,
    :route_class,
    :selected_metadata,
    :attempt_metadata,
    :route_metadata,
    :circuit_state
  ]

  @type candidate :: {PoolUpstreamAssignment.t(), UpstreamIdentity.t()}
  @type auth :: Access.auth_context()
  @type input :: %{
          required(:auth) => auth(),
          required(:model) => Model.t(),
          required(:candidates) => [candidate()],
          required(:route_plan_input) => RoutePlanInput.t(),
          required(:endpoint) => String.t(),
          required(:payload) => map(),
          required(:request_options) => RequestOptions.t(),
          optional(:route_state) => RouteState.t()
        }
  @type t :: %__MODULE__{
          assignment: PoolUpstreamAssignment.t(),
          identity: UpstreamIdentity.t(),
          index: non_neg_integer(),
          route_plan: BridgeRing.route_plan(),
          route_class: String.t(),
          selected_metadata: map(),
          attempt_metadata: map(),
          route_metadata: map(),
          circuit_state: RoutingCircuitState.t() | nil
        }

  @spec select_and_begin_circuit(input()) :: {:ok, t()} | {:error, map()}
  def select_and_begin_circuit(
        %{
          auth: auth,
          model: %Model{} = model,
          candidates: candidates,
          route_plan_input: %RoutePlanInput{} = route_plan_input,
          endpoint: endpoint,
          payload: payload,
          request_options: %RequestOptions{} = request_options
        } = input
      )
      when is_list(candidates) and is_map(payload) do
    route_class = RequestOptions.route_class(request_options)

    route_state = Map.get(input, :route_state)

    route_plan =
      BridgeRing.plan_route(
        auth,
        model,
        candidates,
        route_plan_input,
        request_options,
        route_state
      )

    route_plan.candidates
    |> Enum.with_index()
    |> Enum.reduce_while({:error, no_eligible_backend(endpoint, route_class, [])}, fn
      {{assignment, identity}, index}, {:error, %{candidate_exclusions: exclusions}} ->
        selection =
          prepare_candidate(%{
            route_plan: route_plan,
            assignment: assignment,
            identity: identity,
            index: index,
            route_class: route_class
          })

        case begin_circuit(selection, auth, model, route_state) do
          {:ok, selection} ->
            {:halt, {:ok, selection}}

          {:error, reason} ->
            {:cont,
             {:error,
              no_eligible_backend(endpoint, route_class, [
                candidate_exclusion(selection, reason) | exclusions
              ])}}
        end
    end)
    |> normalize_exclusions()
  end

  @spec prepare_candidate(%{
          required(:route_plan) => BridgeRing.route_plan(),
          required(:assignment) => PoolUpstreamAssignment.t(),
          required(:identity) => UpstreamIdentity.t(),
          required(:index) => non_neg_integer(),
          required(:route_class) => String.t()
        }) :: t()
  def prepare_candidate(%{
        route_plan: route_plan,
        assignment: %PoolUpstreamAssignment{} = assignment,
        identity: %UpstreamIdentity{} = identity,
        index: index,
        route_class: route_class
      })
      when is_binary(route_class) do
    selected_metadata = BridgeRing.selected_metadata(route_plan, assignment, index)
    attempt_metadata = BridgeRing.attempt_metadata(route_plan, assignment, identity, index)

    %__MODULE__{
      assignment: assignment,
      identity: identity,
      index: index,
      route_plan: route_plan,
      route_class: route_class,
      selected_metadata: selected_metadata,
      attempt_metadata: attempt_metadata,
      route_metadata: route_metadata(route_plan, selected_metadata, route_class)
    }
  end

  @spec begin_circuit(t(), auth(), Model.t(), RouteState.t() | nil) ::
          {:ok, t()} | {:error, term()}
  def begin_circuit(%__MODULE__{} = selection, auth, %Model{} = model, route_state \\ nil) do
    snapshot = circuit_snapshot(route_state, selection.assignment.id)

    case CircuitState.begin_attempt(
           auth,
           model,
           selection.assignment,
           selection.route_class,
           snapshot
         ) do
      {:ok, circuit_state} -> {:ok, %{selection | circuit_state: circuit_state}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp circuit_snapshot(%RouteState{} = route_state, assignment_id),
    do: RouteState.circuit_snapshot(route_state, assignment_id)

  defp circuit_snapshot(_route_state, _assignment_id), do: nil

  defp route_metadata(route_plan, selected_metadata, route_class) do
    route_plan.request_metadata
    |> deep_merge(selected_metadata)
    |> Map.update("routing", %{"route_class" => route_class}, fn routing ->
      Map.put(routing, "route_class", route_class)
    end)
  end

  defp no_eligible_backend(endpoint, route_class, exclusions) do
    %{
      code: :no_eligible_backend,
      endpoint: endpoint,
      route_class: route_class,
      candidate_exclusions: exclusions
    }
  end

  defp candidate_exclusion(%__MODULE__{} = selection, reason) do
    %{
      pool_upstream_assignment_id: selection.assignment.id,
      upstream_identity_id: selection.identity.id,
      reasons: [%{"code" => to_string(reason), "route_class" => selection.route_class}]
    }
  end

  defp normalize_exclusions({:error, %{candidate_exclusions: exclusions} = reason}) do
    {:error, %{reason | candidate_exclusions: Enum.reverse(exclusions)}}
  end

  defp normalize_exclusions(result), do: result

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = left_value, %{} = right_value ->
        deep_merge(left_value, right_value)

      _key, _left_value, right_value ->
        right_value
    end)
  end
end
