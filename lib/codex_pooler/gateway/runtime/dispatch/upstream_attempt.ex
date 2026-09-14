defmodule CodexPooler.Gateway.Runtime.Dispatch.UpstreamAttempt do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.ContinuityPayload
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Gateway.Runtime.Dispatch.HttpAuthRefresh
  alias CodexPooler.Gateway.Runtime.Dispatch.PreparedContext
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Gateway.Runtime.Dispatch.WebsocketAttempt
  alias CodexPooler.Gateway.Runtime.Dispatch.WebsocketBridge
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.Streaming.StreamDispatch
  alias CodexPooler.Gateway.Runtime.Streaming.StreamLifecycle
  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl.TurnSnapshot
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Gateway.Transports.UpstreamDispatch.Request, as: DispatchRequest
  alias CodexPooler.Upstreams.ResponsesAPICompaction
  alias CodexPooler.Upstreams.ResponsesAPIHistory
  alias CodexPooler.Upstreams.ResponsesAPITools
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @type callbacks :: %{
          required(:register_continuity) => (term(), term(), term() -> term()),
          required(:retry_dispatch) => (PreparedContext.t() -> dispatch_result())
        }
  @type dispatch_result :: CodexPooler.Gateway.Runtime.Dispatch.dispatch_result()

  @spec dispatch(PreparedContext.t(), callbacks()) :: dispatch_result()
  def dispatch(%PreparedContext{context: context} = prepared_context, callbacks) do
    if UpstreamIdentity.responses_api?(context.identity) do
      dispatch_http(prepared_context, callbacks)
    else
      dispatch_selected_transport(prepared_context, callbacks)
    end
  end

  defp dispatch_selected_transport(
         %PreparedContext{context: context} = prepared_context,
         callbacks
       ) do
    case transport_decision(context.request_options) do
      :websocket ->
        dispatch_websocket(prepared_context, callbacks)

      :websocket_without_upstream ->
        fail_closed_websocket_transport(prepared_context)

      :http ->
        if WebsocketBridge.eligible?(prepared_context) do
          dispatch_websocket_bridge(prepared_context, callbacks)
        else
          dispatch_http(prepared_context, callbacks)
        end
    end
  end

  @doc """
  Chooses the upstream transport family for a selected attempt.

  A turn whose request transport is `websocket` never falls back to HTTP: it
  uses the upstream websocket when it has a downstream writer or a
  connection-bound compaction collector, whatever its `stream` flag, and has
  no upstream path otherwise. Every other transport keeps its HTTP decision,
  where the public streaming bridge is still considered.
  """
  @spec transport_decision(RequestOptions.t()) ::
          :websocket | :websocket_without_upstream | :http
  def transport_decision(
        %RequestOptions{transport: %{transport: "websocket"} = transport} = request_options
      ) do
    if is_function(transport.websocket_writer, 1) or
         RequestOptions.connection_bound_compaction?(request_options),
       do: :websocket,
       else: :websocket_without_upstream
  end

  def transport_decision(%RequestOptions{}), do: :http

  @doc """
  The fixed Pooler error for a websocket turn without a websocket upstream path.
  """
  @spec websocket_transport_required_error() :: %{
          status: 500,
          code: String.t(),
          message: String.t(),
          param: nil
        }
  def websocket_transport_required_error do
    %{
      status: 500,
      code: "websocket_transport_required",
      message: "websocket turn requires the websocket upstream transport",
      param: nil
    }
  end

  # Prepared websocket frames are rejected with the same decision before
  # reservation in `Service`; a direct `Service.execute/4` caller with a
  # websocket transport and no writer reaches this branch, which settles the
  # reserved turn instead of posting its frame body to the HTTP endpoint.
  defp fail_closed_websocket_transport(%PreparedContext{context: context}) do
    Finalization.Websocket.finalize_failed(context, %{
      reason: :websocket_transport_required,
      error: websocket_transport_required_error(),
      body: "",
      headers: [],
      started: context.started
    })
  end

  # A bridged turn falls back to plain HTTP only with positive proof that the
  # failure preceded upstream submission. Silence and ambiguous failures stay
  # on the websocket attempt and finalize through the standard streaming path.
  defp dispatch_websocket_bridge(%PreparedContext{} = prepared_context, callbacks) do
    case WebsocketBridge.open(prepared_context) do
      {:ok, %PreparedContext{context: context}, response} ->
        Finalization.handle_http_response(
          response,
          context,
          finalization_callbacks(callbacks)
        )

      {:fallback, reason} ->
        WebsocketBridge.log_fallback(prepared_context, reason)
        dispatch_http(prepared_context, callbacks)

      {:error, :owner_unavailable} ->
        Finalization.Websocket.finalize_failed(prepared_context.context, %{
          reason: :owner_unavailable,
          body: "",
          headers: [],
          started: prepared_context.context.started
        })
    end
  end

  defp dispatch_http(%PreparedContext{context: context} = prepared_context, callbacks) do
    dispatch_request = dispatch_request(prepared_context)

    with {:ok, response} <- UpstreamDispatch.http_request(dispatch_request),
         response =
           ResponsesAPITools.response(
             response,
             context.request_options.payload_context.responses_api_tools
           ),
         {:ok, response} <- ResponsesAPICompaction.finish(response, context) do
      response =
        ResponsesAPIHistory.remember_json(
          response,
          context.request_options.payload_context.responses_api_history
        )

      if HttpAuthRefresh.eligible?(prepared_context, response) do
        HttpAuthRefresh.handle(prepared_context, response, &dispatch_http(&1, callbacks))
      else
        Finalization.handle_http_response(response, context, finalization_callbacks(callbacks))
      end
    else
      {:error, reason} ->
        Finalization.handle_dispatch_error(reason, context, elapsed_ms(context.started))
    end
  end

  defp dispatch_websocket(%PreparedContext{context: context} = prepared_context, callbacks) do
    writer = context.request_options.transport.websocket_writer

    dispatch_request =
      dispatch_request(prepared_context,
        accounting_request: context.reserved.request,
        accounting_attempt: context.attempt,
        writer: writer,
        original_payload: nil
      )

    prepared_context = release_websocket_payload(prepared_context)

    WebsocketAttempt.dispatch(
      prepared_context,
      dispatch_request,
      finalization_callbacks(callbacks)
    )
  end

  defp finalization_callbacks(callbacks) do
    %{
      register_continuity: Map.fetch!(callbacks, :register_continuity),
      stream_result: fn response, context ->
        StreamDispatch.streaming_result(response, context, %{
          finalization_callbacks: finalization_callbacks(callbacks),
          http_first_event_retry:
            StreamLifecycle.http_first_event_retry(Map.fetch!(callbacks, :retry_dispatch))
        })
      end
    }
  end

  defp dispatch_request(%PreparedContext{context: context} = prepared_context, opts \\ []) do
    %DispatchRequest{
      url: prepared_context.url,
      token: prepared_context.token,
      upstream_payload: prepared_context.upstream_payload,
      original_payload: Keyword.get(opts, :original_payload, context.payload),
      identity: context.identity,
      routing_hint_authorized?: prepared_context.routing_hint_authorized?,
      accounting_request: Keyword.get(opts, :accounting_request),
      accounting_attempt: Keyword.get(opts, :accounting_attempt),
      writer: Keyword.get(opts, :writer),
      assignment_advertised?:
        ModelMetadata.assignment_source?(context.model, context.assignment.id),
      native_codex_response_control: native_codex_response_control(context),
      request_options: context.request_options,
      client_retry_dispatch_authority: context.client_retry_dispatch_authority
    }
  end

  defp native_codex_response_control(%{
         route_state: route_state,
         request_options: %{transport: %{transport: "websocket"}}
       }) do
    case RouteState.codex_models_etag(route_state) do
      models_etag when is_binary(models_etag) -> %TurnSnapshot{models_etag: models_etag}
      nil -> nil
    end
  end

  defp native_codex_response_control(_context), do: nil

  defp release_websocket_payload(%PreparedContext{context: context} = prepared_context) do
    %{prepared_context | context: %{context | payload: continuity_payload(context.payload)}}
  end

  defp continuity_payload(payload) when is_map(payload) do
    case ContinuityPayload.previous_response_id(payload) do
      previous_response_id when is_binary(previous_response_id) ->
        %{"previous_response_id" => previous_response_id}

      nil ->
        %{}
    end
  end

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)
end
