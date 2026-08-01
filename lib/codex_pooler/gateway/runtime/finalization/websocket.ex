defmodule CodexPooler.Gateway.Runtime.Finalization.Websocket do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext

  alias CodexPooler.Gateway.Runtime.Finalization.{
    AttemptSettlement,
    Metadata,
    ResponseUsage,
    SettlementAttrs,
    SideEffects,
    Streaming
  }

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract

  @spec finalize_completed(SelectedCandidateContext.t(), map()) :: {:ok, map()} | {:error, map()}
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

    usage = ResponseUsage.from_websocket_body(body)
    transports = resolved_transports(context)

    case AttemptSettlement.finalize_success(
           reserved.request,
           attempt,
           usage,
           SettlementAttrs.success(
             context,
             status,
             Metadata.websocket_response_metadata(
               headers,
               nil,
               request_options,
               Map.get(finalization, :websocket_frame_headers, %{}),
               Map.get(finalization, :upstream_websocket_connection)
             ),
             started: started
           )
         ) do
      {:ok, _finalized} = result ->
        Streaming.emit_stream_finalization(
          usage,
          transports.downstream_transport,
          transports.upstream_transport
        )

        emit_settlement_outcome(result, "succeeded", transports)
        request_options = request_options_with_response_id(request_options, finalization)
        SideEffects.record_success(context, payload, body, request_options, callbacks)

        {:ok, %{status: 200, headers: [], websocket_messages: []}}

      {:error, gateway_error} = error ->
        emit_settlement_failure(error, transports)
        {:error, gateway_error}
    end
  end

  defp request_options_with_response_id(
         %RequestOptions{} = request_options,
         %{response_id: response_id}
       )
       when is_binary(response_id) do
    case String.trim(response_id) do
      "" -> request_options
      response_id -> RequestOptions.put_continuity(request_options, response_id: response_id)
    end
  end

  defp request_options_with_response_id(request_options, _finalization), do: request_options

  @spec finalize_terminal(SelectedCandidateContext.t(), map()) :: {:ok, map()} | {:error, map()}
  def finalize_terminal(context, finalization) do
    %{body: body, terminal: terminal} = finalization

    case websocket_terminal_outcome(terminal, body) do
      {:ok, %{kind: kind}} when kind in [:completed, :incomplete] ->
        finalize_completed(context, finalization)

      _outcome ->
        finalize_terminal_failure(context, finalization)
    end
  end

  defp finalize_terminal_failure(context, finalization) do
    %{body: body, terminal: terminal, headers: headers} = finalization

    upstream_code =
      Map.get(finalization, :upstream_error_code) ||
        StreamProtocol.terminal_error_code(body, terminal)

    code = StreamProtocol.client_visible_error_code(upstream_code)
    websocket_frame_headers = Map.get(finalization, :websocket_frame_headers, %{})
    metadata_headers = headers ++ Map.to_list(websocket_frame_headers)

    attempt_metadata =
      terminal_failure_metadata(
        context,
        metadata_headers,
        websocket_frame_headers,
        Map.get(finalization, :upstream_websocket_connection),
        code,
        upstream_code,
        Map.get(finalization, :upstream_error_param),
        Map.get(finalization, :transport_failure)
      )

    case Streaming.record_terminal_health_failure(upstream_code, metadata_headers, context) do
      :ok ->
        settle_terminal_failure(context, finalization, body, code, attempt_metadata)

      {:error, _gateway_error} = error ->
        error
    end
  end

  defp terminal_failure_metadata(
         context,
         metadata_headers,
         websocket_frame_headers,
         upstream_websocket_connection,
         code,
         upstream_code,
         upstream_error_param,
         transport_failure
       ) do
    continuation_guard = continuation_guard_metadata(upstream_code, transport_failure)

    upstream_error_param =
      if upstream_code == "previous_response_not_found",
        do: "previous_response_id",
        else: upstream_error_param

    metadata_headers
    |> Metadata.websocket_response_metadata(
      code,
      context.request_options,
      websocket_frame_headers,
      upstream_websocket_connection
    )
    |> Metadata.maybe_put_masked_error_metadata(upstream_code, code)
    |> Metadata.maybe_put_upstream_error_param(%{upstream_error_param: upstream_error_param})
    |> maybe_put_terminal_transport_failure(continuation_guard)
  end

  defp maybe_put_terminal_transport_failure(metadata, transport_failure)
       when map_size(transport_failure) > 0,
       do: Map.put(metadata, "transport_failure", transport_failure)

  defp maybe_put_terminal_transport_failure(metadata, _transport_failure), do: metadata

  defp continuation_guard_metadata("previous_response_not_found", transport_failure),
    do: TransportFailureReason.sanitize_continuation_generation_guard_metadata(transport_failure)

  defp continuation_guard_metadata(_upstream_code, _transport_failure), do: %{}

  defp settle_terminal_failure(context, finalization, body, code, attempt_metadata) do
    %{reserved: reserved, attempt: attempt} = context
    transports = resolved_transports(context)

    case AttemptSettlement.finalize_partial_stream_failure(
           reserved.request,
           attempt,
           ResponseUsage.from_websocket_body(body),
           SettlementAttrs.partial_stream_failure(
             context,
             finalization.status,
             code,
             code,
             attempt_metadata,
             started: finalization.started
           )
         ) do
      {:ok, _finalized} = result ->
        emit_settlement_outcome(result, "failed", transports)
        {:ok, %{status: 200, headers: [], websocket_messages: []}}

      {:error, gateway_error} = error ->
        emit_settlement_failure(error, transports)
        {:error, gateway_error}
    end
  end

  defp websocket_terminal_outcome("response.completed", _body), do: {:ok, %{kind: :completed}}
  defp websocket_terminal_outcome(_terminal, body), do: StreamProtocol.terminal_outcome(body)

  @spec finalize_failed(SelectedCandidateContext.t(), map()) :: {:error, map()}
  def finalize_failed(context, %{reason: :client_disconnected} = finalization) do
    %{headers: headers, started: started} = finalization

    %{reserved: reserved, attempt: attempt, request_options: request_options, endpoint: endpoint} =
      context

    code = "client_disconnected"
    transports = resolved_transports(context)

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
               Map.get(finalization, :websocket_frame_headers, %{}),
               Map.get(finalization, :upstream_websocket_connection)
             ),
             started: started
           )
         ) do
      {:ok, _finalized} = result ->
        emit_settlement_outcome(result, "interrupted", transports)
        {:error, error(499, code, Metadata.upstream_failure_message(endpoint))}

      {:error, gateway_error} = error ->
        emit_settlement_failure(error, transports)
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
    transports = resolved_transports(context)

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
               Map.get(finalization, :websocket_frame_headers, %{}),
               Map.get(finalization, :upstream_websocket_connection)
             ),
             started: started
           )
         ) do
      {:ok, _finalized} = result ->
        emit_settlement_outcome(result, "failed", transports)

        {:error,
         error(owner_payload.status, owner_payload.code, owner_payload.message, nil, %{
           owner_error: owner_payload.metadata.owner_error
         })}

      {:error, gateway_error} = error ->
        emit_settlement_failure(error, transports)
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
        Map.get(finalization, :websocket_frame_headers, %{}),
        Map.get(finalization, :upstream_websocket_connection)
      )
      |> maybe_put_transport_failure_metadata(finalization)
      |> Metadata.maybe_put_upstream_error_param(finalization)

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
         %SelectedCandidateContext{allow_retry?: true, reserved: reserved, attempt: attempt},
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
    transports = resolved_transports(context)

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
      {:ok, _finalized} = result ->
        emit_settlement_outcome(result, "failed", transports)
        {:error, failed_error_response(endpoint, code, reason)}

      {:error, gateway_error} = error ->
        emit_settlement_failure(error, transports)
        {:error, gateway_error}
    end
  end

  defp emit_settlement_outcome({:ok, finalized}, outcome, transports) do
    if AttemptSettlement.first_settlement?(finalized) do
      Streaming.emit_stream_outcome(
        outcome,
        transports.downstream_transport,
        transports.upstream_transport
      )
    end
  end

  defp emit_settlement_failure(
         {:error, %{code: "gateway_accounting_failed"}},
         transports
       ) do
    Streaming.emit_stream_outcome(
      "settlement_failed",
      transports.downstream_transport,
      transports.upstream_transport
    )
  end

  defp emit_settlement_failure({:error, _gateway_error}, _transports), do: :ok

  defp resolved_transports(context) do
    %{
      downstream_transport: Streaming.downstream_transport(context.request_options),
      upstream_transport: "websocket"
    }
  end

  defp failed_error_response(_endpoint, "stream_idle_timeout", reason) do
    error(502, "stream_idle_timeout", Metadata.safe_reason(reason))
  end

  defp failed_error_response(endpoint, _code, _reason) do
    error(
      502,
      ErrorCodes.upstream_request_failed_code(),
      Metadata.upstream_failure_message(endpoint)
    )
  end

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)

  defp error(status, code, message, param \\ nil, metadata \\ %{}),
    do: Map.merge(%{status: status, code: code, message: message, param: param}, metadata)
end
