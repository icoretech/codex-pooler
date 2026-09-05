defmodule CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.BridgeRing
  alias CodexPooler.Gateway.Routing.CircuitState
  alias CodexPooler.Gateway.Routing.RoutingSelection
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  defstruct [
    :auth,
    :endpoint,
    :payload,
    :model,
    :reserved,
    :request_options,
    :route_state,
    :route_plan,
    :assignment,
    :identity,
    :index,
    :retry_count,
    :allow_retry?,
    :routing_attempt_metadata,
    :route_class,
    :routing_circuit_state,
    :routing_circuit_admission,
    :attempt,
    :started,
    :auth_refresh_retry_attempted?,
    :client_retry_dispatch_authority
  ]

  @type t :: %__MODULE__{
          auth: CodexPooler.Access.auth_context(),
          endpoint: String.t(),
          payload: map(),
          model: Model.t(),
          reserved: Accounting.request_result_row(),
          request_options: RequestOptions.t(),
          route_state: RouteState.t(),
          route_plan: BridgeRing.route_plan(),
          assignment: PoolUpstreamAssignment.t(),
          identity: UpstreamIdentity.t(),
          index: non_neg_integer(),
          retry_count: non_neg_integer(),
          allow_retry?: boolean(),
          routing_attempt_metadata: map(),
          route_class: String.t(),
          routing_circuit_state: RoutingCircuitState.t() | nil,
          routing_circuit_admission: CircuitState.admission() | nil,
          attempt: Attempt.t() | nil,
          started: integer() | nil,
          auth_refresh_retry_attempted?: boolean() | nil,
          client_retry_dispatch_authority:
            CodexPooler.Accounting.ClientRetry.DispatchAuthority.t() | nil
        }

  @spec from_dispatch_context(Context.t() | t(), RoutingSelection.t(), boolean()) :: t()
  def from_dispatch_context(context, %RoutingSelection{} = selection, allow_retry?) do
    %__MODULE__{
      auth: context.auth,
      endpoint: context.endpoint,
      payload: context.payload,
      model: context.model,
      reserved: context.reserved,
      request_options: context.request_options,
      route_state: context.route_state,
      route_plan: context.route_plan,
      assignment: selection.assignment,
      identity: selection.identity,
      index: selection.index,
      retry_count: selection.index,
      allow_retry?: allow_retry?,
      routing_attempt_metadata: selection.attempt_metadata,
      route_class: selection.route_class,
      routing_circuit_admission: selection.circuit_admission,
      client_retry_dispatch_authority: context.client_retry_dispatch_authority
    }
  end
end
