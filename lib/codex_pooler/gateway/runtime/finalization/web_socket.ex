defmodule CodexPooler.Gateway.Runtime.Finalization.WebSocket do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Dispatch.Context, as: DispatchContext

  alias CodexPooler.Gateway.Runtime.Finalization.{
    AttemptSettlement,
    Metadata,
    ResponseUsage,
    SettlementAttrs,
    SideEffects,
    Streaming
  }

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract

  @spec finalize_completed(DispatchContext.t(), map()) :: {:ok, map()} | {:error, map()}
  def finalize_completed(context, finalization) do
    %{
      body: body,
      status: status,
      headers: headers,
      started: started,
      callbacks: callbacks
    } = finalization

    %{
      reserved: reserved,
      attempt: attempt,
      payload: payload,
      request_options: request_options
    } =
      context

    case AttemptSettlement.finalize_success(
           reserved.request,
           attempt,
           ResponseUsage.from_websocket_body(body),
           SettlementAttrs.success(
             context,
             status,
             Metadata.websocket_response_metadata(
               headers,
               nil,
               request_options,
               Map.get(finalization, :websocket_frame_headers, %{})
             ),
             started: started
           )
         ) do
      {:ok, _finalized} ->
        SideEffects.record_success(context, payload, body, request_options, callbacks)

        {:ok, %{status: 200, headers: [], websocket_messages: []}}

      {:error, gateway_error} ->
        {:error, gateway_error}
    end
  end

  @spec finalize_terminal(DispatchContext.t(), map()) :: {:ok, map()} | {:error, map()}
  def finalize_terminal(context, finalization) do
    %{
      body: body,
      terminal: terminal,
      status: status,
      headers: headers,
      started: started
    } = finalization

    %{reserved: reserved, attempt: attempt, request_options: request_options} =
      context

    upstream_code =
      Map.get(finalization, :upstream_error_code) ||
        StreamProtocol.terminal_error_code(body, terminal)

    code = StreamProtocol.client_visible_error_code(upstream_code)
    websocket_frame_headers = Map.get(finalization, :websocket_frame_headers, %{})
    metadata_headers = headers ++ Map.to_list(websocket_frame_headers)

    with :ok <- Streaming.record_terminal_health_failure(upstream_code, metadata_headers, context) do
      case AttemptSettlement.finalize_partial_stream_failure(
             reserved.request,
             attempt,
             ResponseUsage.from_websocket_body(body),
             SettlementAttrs.partial_stream_failure(
               context,
               status,
               code,
               code,
               metadata_headers
               |> Metadata.websocket_response_metadata(
                 code,
                 request_options,
                 websocket_frame_headers
               )
               |> Metadata.maybe_put_masked_error_metadata(upstream_code, code),
               started: started
             )
           ) do
        {:ok, _finalized} ->
          {:ok, %{status: 200, headers: [], websocket_messages: []}}

        {:error, gateway_error} ->
          {:error, gateway_error}
      end
    end
  end

  @spec finalize_failed(DispatchContext.t(), map()) :: {:error, map()}
  def finalize_failed(context, %{reason: :client_disconnected} = finalization) do
    %{headers: headers, started: started} = finalization

    %{reserved: reserved, attempt: attempt, request_options: request_options, endpoint: endpoint} =
      context

    code = "client_disconnected"

    case AttemptSettlement.finalize_partial_stream_failure(
           reserved.request,
           attempt,
           ResponseUsage.from_websocket_body(""),
           SettlementAttrs.partial_stream_failure(
             context,
             499,
             code,
             code,
             Metadata.websocket_response_metadata(
               headers,
               code,
               request_options,
               Map.get(finalization, :websocket_frame_headers, %{})
             ),
             started: started
           )
         ) do
      {:ok, _finalized} ->
        {:error, error(499, code, Metadata.upstream_failure_message(endpoint))}

      {:error, gateway_error} ->
        {:error, gateway_error}
    end
  end

  def finalize_failed(context, %{reason: reason} = finalization)
      when reason in [
             :owner_unavailable,
             :stale_owner,
             :owner_forward_timeout,
             :owner_crashed,
             :owner_drained,
             :duplicate_downstream,
             :stale_downstream,
             :owner_busy
           ] do
    %{body: body, headers: headers, started: started} = finalization
    %{reserved: reserved, attempt: attempt, request_options: request_options} = context
    {:ok, owner_payload} = WebsocketOwnerContract.safe_error_payload(reason, nil)

    case AttemptSettlement.finalize_partial_stream_failure(
           reserved.request,
           attempt,
           ResponseUsage.from_websocket_body(body),
           SettlementAttrs.partial_stream_failure(
             context,
             owner_payload.status,
             owner_payload.code,
             owner_payload.metadata.reason,
             Metadata.websocket_response_metadata(
               headers,
               owner_payload.code,
               request_options,
               Map.get(finalization, :websocket_frame_headers, %{})
             ),
             started: started
           )
         ) do
      {:ok, _finalized} ->
        {:error,
         error(owner_payload.status, owner_payload.code, owner_payload.message, nil, %{
           owner_error: owner_payload.metadata.owner_error
         })}

      {:error, gateway_error} ->
        {:error, gateway_error}
    end
  end

  def finalize_failed(context, finalization) do
    %{reason: reason, headers: headers} = finalization
    %{request_options: request_options} = context

    code = Streaming.error_code(reason)

    metadata =
      Metadata.websocket_response_metadata(
        headers,
        code,
        request_options,
        Map.get(finalization, :websocket_frame_headers, %{})
      )
      |> maybe_put_transport_failure_metadata(finalization)

    with :ok <- Streaming.record_health_failure(code, code, context) do
      finalize_failed_after_health(context, finalization, code, metadata)
    end
  end

  defp maybe_put_transport_failure_metadata(metadata, %{transport_failure: transport_failure})
       when is_map(transport_failure) and map_size(transport_failure) > 0 do
    Map.put(metadata, "transport_failure", transport_failure)
  end

  defp maybe_put_transport_failure_metadata(metadata, _finalization), do: metadata

  defp finalize_failed_after_health(
         %DispatchContext{allow_retry?: true, reserved: reserved, attempt: attempt},
         %{body: "", reason: reason, started: started},
         code,
         metadata
       ) do
    case AttemptSettlement.record_retryable_failure(reserved.request, attempt, %{
           last_error_code: code,
           error_message: Metadata.safe_reason(reason),
           latency_ms: elapsed_ms(started),
           attempt_metadata: metadata
         }) do
      {:ok, _attempt} -> {:retry, code}
      {:error, gateway_error} -> {:error, gateway_error}
    end
  end

  defp finalize_failed_after_health(context, finalization, code, metadata) do
    %{body: body, reason: reason, started: started} = finalization
    %{reserved: reserved, attempt: attempt, endpoint: endpoint} = context

    case AttemptSettlement.finalize_partial_stream_failure(
           reserved.request,
           attempt,
           ResponseUsage.from_websocket_body(body),
           SettlementAttrs.partial_stream_failure(
             context,
             502,
             code,
             Metadata.safe_reason(reason),
             metadata,
             started: started
           )
         ) do
      {:ok, _finalized} ->
        {:error, failed_error_response(endpoint, code, reason)}

      {:error, gateway_error} ->
        {:error, gateway_error}
    end
  end

  defp failed_error_response(_endpoint, "stream_idle_timeout", reason) do
    error(502, "stream_idle_timeout", Metadata.safe_reason(reason))
  end

  defp failed_error_response(endpoint, _code, _reason) do
    error(502, "upstream_request_failed", Metadata.upstream_failure_message(endpoint))
  end

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)

  defp error(status, code, message, param \\ nil, metadata \\ %{}),
    do: Map.merge(%{status: status, code: code, message: message, param: param}, metadata)
end
