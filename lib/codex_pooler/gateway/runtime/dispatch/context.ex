defmodule CodexPooler.Gateway.Runtime.Dispatch.Context do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState

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
    :route_class,
    :client_retry_dispatch_authority
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
          route_class: String.t(),
          client_retry_dispatch_authority:
            CodexPooler.Accounting.ClientRetry.DispatchAuthority.t() | nil
        }

  @type input :: %{
          required(:auth) => CodexPooler.Access.auth_context(),
          required(:endpoint) => String.t(),
          required(:payload) => map(),
          required(:model) => Model.t(),
          required(:reserved) => Accounting.request_result_row(),
          required(:candidates) => [BridgeRing.candidate()],
          required(:request_options) => RequestOptions.t(),
          required(:route_state) => RouteState.t()
        }

  @spec new(input()) :: {:ok, t()} | {:error, map()}
  def new(input) when is_map(input) do
    request_options = Map.fetch!(input, :request_options)

    route_plan =
      BridgeRing.plan_route(%{
        auth: input.auth,
        model: input.model,
        candidates: input.candidates,
        route_plan_input: RoutePlanInput.from_reserved(input.reserved),
        request_options: request_options,
        route_state: input.route_state
      })

    case Accounting.accumulate_request_metadata(
           input.reserved.request,
           dispatch_request_metadata(route_plan, request_options)
         ) do
      {:ok, request} ->
        {:ok,
         %__MODULE__{
           auth: input.auth,
           endpoint: input.endpoint,
           payload: input.payload,
           model: input.model,
           reserved: %{input.reserved | request: request},
           candidates: input.candidates,
           request_options: request_options,
           route_state: input.route_state,
           route_plan: route_plan,
           route_class: request_options.transport.route_class,
           client_retry_dispatch_authority: Map.get(input.reserved, :dispatch_authority)
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

  # Successful turns persist the same top-level canonical_partition evidence the
  # denial path records, so one request-log query covers both outcomes. The
  # summary is present only on surfaces the partition cap applies to and only
  # when the pool actually has more than one partition; PreDispatch gates both.
  defp dispatch_request_metadata(route_plan, %RequestOptions{} = request_options) do
    metadata = %{"routing" => route_plan.request_metadata}

    case request_options.routing.canonical_partition do
      %{} = summary -> Map.put(metadata, "canonical_partition", summary)
      _absent -> metadata
    end
  end
end
