defmodule CodexPooler.Gateway.Runtime.Dispatch.UpstreamAttempt do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.ContinuityPayload
  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Gateway.Runtime.Dispatch.PreparedContext
  alias CodexPooler.Gateway.Runtime.Dispatch.WebsocketAttempt
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.Streaming.StreamDispatch
  alias CodexPooler.Gateway.Runtime.Streaming.StreamLifecycle
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Gateway.Transports.UpstreamDispatch.Request, as: DispatchRequest
  alias CodexPooler.RouteClass

  @type callbacks :: %{
          required(:register_continuity) => (term(), term(), term() -> term()),
          required(:retry_dispatch) => (PreparedContext.t() -> dispatch_result())
        }
  @type dispatch_result :: CodexPooler.Gateway.Runtime.Dispatch.dispatch_result()

  @spec dispatch(PreparedContext.t(), callbacks()) :: dispatch_result()
  def dispatch(%PreparedContext{context: context} = prepared_context, callbacks) do
    if websocket_upstream?(context.payload, context.request_options.transport) do
      dispatch_websocket(prepared_context, callbacks)
    else
      dispatch_http(prepared_context, callbacks)
    end
  end

  defp dispatch_http(%PreparedContext{context: context} = prepared_context, callbacks) do
    dispatch_request = dispatch_request(prepared_context)

    case UpstreamDispatch.http_request(dispatch_request) do
      {:ok, response} ->
        Finalization.handle_http_response(
          response,
          context,
          finalization_callbacks(callbacks)
        )

      {:error, reason} ->
        Finalization.handle_dispatch_error(reason, context, elapsed_ms(context.started))
    end
  end

  defp dispatch_websocket(%PreparedContext{context: context} = prepared_context, callbacks) do
    writer = context.request_options.transport.websocket_writer

    dispatch_request =
      dispatch_request(prepared_context,
        accounting_request: context.reserved.request,
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
      accounting_request: Keyword.get(opts, :accounting_request),
      writer: Keyword.get(opts, :writer),
      assignment_advertised?:
        ModelMetadata.assignment_source?(context.model, context.assignment.id),
      request_options: context.request_options
    }
  end

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

  defp websocket_upstream?(payload, opts) do
    opts.transport == "websocket" and RouteClass.streaming?(payload) and
      is_function(opts.websocket_writer, 1)
  end

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)
end
