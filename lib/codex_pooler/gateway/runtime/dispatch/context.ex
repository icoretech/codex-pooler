defmodule CodexPooler.Gateway.Runtime.Dispatch.Context do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Gateway.Runtime.Dispatch.{ContentFilterRetryPin, RouteState}
  alias CodexPooler.Gateway.Transports.Websocket.CompactionRetrySubmitHold
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder

  defstruct [
    :auth,
    :endpoint,
    :payload,
    :prepared_native_payloads,
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
          prepared_native_payloads: CodexPooler.Gateway.Runtime.Dispatch.PreparedNativePayloads.t() | nil,
          model: Model.t(),
          reserved: Accounting.request_result_row(),
          candidates: [BridgeRing.candidate()],
          request_options: RequestOptions.t(),
          route_state: RouteState.t(),
          route_plan: BridgeRing.route_plan(),
          route_class: String.t(),
          client_retry_dispatch_authority: CodexPooler.Accounting.ClientRetry.DispatchAuthority.t() | nil
        }

  @type input :: %{
          required(:auth) => CodexPooler.Access.auth_context(),
          required(:endpoint) => String.t(),
          required(:payload) => map(),
          optional(:prepared_native_payloads) => CodexPooler.Gateway.Runtime.Dispatch.PreparedNativePayloads.t(),
          required(:model) => Model.t(),
          required(:reserved) => Accounting.request_result_row(),
          required(:candidates) => [BridgeRing.candidate()],
          required(:request_options) => RequestOptions.t(),
          required(:route_state) => RouteState.t()
        }

  @spec new(input()) :: {:ok, t()} | {:error, map()}
  def new(input) when is_map(input) do
    request_options =
      input
      |> Map.fetch!(:request_options)
      |> RequestOptions.put_runtime_context(compaction_retry_submit_hold: Map.get(input.reserved, :compaction_retry_submit_hold))

    # A verified guided content-filter retry is routed only to the account its
    # binding names (findings#318).
    case ContentFilterRetryPin.candidates(input.reserved.request, input.candidates) do
      {:ok, candidates} ->
        build(%{input | candidates: candidates}, request_options)

      :unavailable ->
        cancel_compaction_retry_hold(request_options)
        ContentFilterRetryPin.refuse(%{input | request_options: request_options})
    end
  end

  defp build(input, request_options) do
    route_state = RouteState.preload_routing_snapshots(input.route_state, input.auth, input.model, request_options)

    route_plan =
      BridgeRing.plan_route(%{
        auth: input.auth,
        model: input.model,
        candidates: input.candidates,
        route_plan_input: RoutePlanInput.from_reserved(input.reserved),
        request_options: request_options,
        route_state: route_state
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
           prepared_native_payloads: Map.get(input, :prepared_native_payloads),
           model: input.model,
           reserved: %{input.reserved | request: request},
           candidates: input.candidates,
           request_options: request_options,
           route_state: route_state,
           route_plan: route_plan,
           route_class: request_options.transport.route_class,
           client_retry_dispatch_authority: Map.get(input.reserved, :dispatch_authority)
         }}

      {:error, reason} ->
        cancel_compaction_retry_hold(request_options)

        FailureResponse.accounting_failure(
          :merge_route_plan_metadata,
          input.reserved.request,
          nil,
          reason
        )
    end
  end

  defp cancel_compaction_retry_hold(%RequestOptions{
         runtime: %{compaction_retry_submit_hold: %CompactionRetrySubmitHold{} = hold}
       }),
       do: WebsocketOwnerForwarder.cancel_compaction_retry_v7(hold)

  defp cancel_compaction_retry_hold(%RequestOptions{}), do: :ok

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
