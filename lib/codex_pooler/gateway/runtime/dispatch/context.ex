defmodule CodexPooler.Gateway.Runtime.Dispatch.Context do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.BridgeRing
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  defstruct [
    :auth,
    :endpoint,
    :payload,
    :model,
    :reserved,
    :candidates,
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
    :attempt,
    :started,
    :auth_refresh_retry_attempted?
  ]

  @type t :: %__MODULE__{
          auth: CodexPooler.Access.auth_context(),
          endpoint: String.t(),
          payload: map(),
          model: Model.t(),
          reserved: Accounting.request_result_row(),
          candidates: [BridgeRing.candidate()],
          request_options: RequestOptions.t(),
          route_state: RouteState.t(),
          route_plan: BridgeRing.route_plan(),
          assignment: PoolUpstreamAssignment.t() | nil,
          identity: UpstreamIdentity.t() | nil,
          index: non_neg_integer() | nil,
          retry_count: non_neg_integer() | nil,
          allow_retry?: boolean() | nil,
          routing_attempt_metadata: map() | nil,
          route_class: String.t(),
          routing_circuit_state: RoutingCircuitState.t() | nil,
          attempt: Attempt.t() | nil,
          started: integer() | nil,
          auth_refresh_retry_attempted?: boolean() | nil
        }
end
