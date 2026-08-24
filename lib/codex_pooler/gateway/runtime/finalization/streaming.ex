defmodule CodexPooler.Gateway.Runtime.Finalization.Streaming do
  @moduledoc false

  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Gateway.Runtime.Dispatch.ResponseContext
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext

  alias CodexPooler.Gateway.Runtime.Finalization.{
    AttemptSettlement,
    Metadata,
    ResponseUsage,
    SettlementAttrs,
    SideEffects
  }

  alias CodexPooler.Gateway.Runtime.Routing.DispatchLifecycle
  alias CodexPooler.Gateway.Runtime.Streaming.{DownstreamStream, StreamUsageObserver}
  alias CodexPooler.Gateway.Runtime.Streaming.Types, as: StreamTypes
  alias CodexPooler.Gateway.Transports.MisalignmentPolicyViolation
  alias CodexPooler.Gateway.Transports.ModelUnavailability
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.UpstreamErrorParam
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketBridgeStream
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Quotas.Evidence.CodexParsers.RateLimitReachedType

  @type callbacks :: %{
          required(:register_continuity) => (term(), term(), term() -> term()),
          required(:stream_result) => StreamTypes.stream_result_callback()
        }
  @type stream_failure :: StreamProtocol.terminal_failure()
  @type finalization_result :: AttemptSettlement.settlement_result()
  @type health_result :: DispatchLifecycle.success_result()

  @spec finalize_success(binary(), ResponseContext.t(), callbacks()) ::
          finalization_result()
  @spec finalize_success(binary(), ResponseContext.t(), callbacks(), term()) ::
          finalization_result()
  def finalize_success(
        body,
        %ResponseContext{context: context, response: response} = response_context,
        callbacks,
        stream_state \\ nil
      ) do
    %{
      reserved: reserved,
      attempt: attempt,
      started: started,
      payload: payload,
      request_options: request_options
    } = context

    usage = stream_usage(body, stream_state)
    attempt_metadata = upstream_websocket_attempt_metadata(response_context)
    upstream_websocket_connection = attempt_metadata.upstream_websocket_connection
    transports = resolved_transports(response_context, attempt_metadata)

    case AttemptSettlement.finalize_success(
           reserved.request,
           attempt,
           usage,
           SettlementAttrs.success(
             context,
             response.status,
             response
             |> Metadata.response_metadata(nil, request_options)
             |> Metadata.merge_stream_state_metadata(stream_state)
             |> merge_upstream_websocket_connection(upstream_websocket_connection),
             started: started
           )
         ) do
      {:ok, _finalized} = result ->
        emit_stream_finalization(
          usage,
          transports.downstream_transport,
          transports.upstream_transport
        )

        emit_settlement_outcome(result, "succeeded", transports)
        SideEffects.record_success(context, payload, body, request_options, callbacks)

        result

      {:error, _gateway_error} = error ->
        emit_settlement_failure(error, transports)
        error
    end
  end

  @spec record_retryable_first_event_failure(
          binary(),
          stream_failure(),
          ResponseContext.t(),
          keyword()
        ) ::
          finalization_result()
  def record_retryable_first_event_failure(
        body,
        failure,
        %ResponseContext{context: context, response: response} = response_context,
        opts \\ []
      ) do
    code = stream_failure_code(failure, context)
    health_code = stream_health_code(failure, code)
    failure = %{failure | code: code}

    health_result =
      cond do
        compact_assignment_model_miss?(failure, context) ->
          :ok

        Keyword.get(opts, :record_health?, true) ->
          record_health_failure(health_code, health_code, context)

        true ->
          :ok
      end

    with :ok <- health_result do
      websocket_attempt_metadata = upstream_websocket_attempt_metadata(response_context)

      AttemptSettlement.record_retryable_failure(
        context.reserved.request,
        context.attempt,
        %{
          response_status_code: response.status,
          last_error_code: code,
          error_message: "upstream stream returned retryable first event #{code}",
          latency_ms: elapsed_ms(context.started),
          usage_status: ResponseUsage.from_sse(body)[:status] || "usage_unknown",
          attempt_metadata:
            first_event_attempt_metadata(
              response_context,
              websocket_attempt_metadata,
              failure,
              "retryable_first_event"
            ),
          retry_count: context.retry_count
        }
      )
    end
  end

  @spec finalize_first_event_failure(binary(), stream_failure(), ResponseContext.t()) ::
          finalization_result()
  def finalize_first_event_failure(
        body,
        failure,
        %ResponseContext{context: context, response: response} = response_context
      ) do
    code = stream_failure_code(failure, context)
    health_code = stream_health_code(failure, code)
    failure = %{failure | code: code}

    health_result =
      if compact_assignment_model_miss?(failure, context),
        do: :ok,
        else: record_terminal_health_failure(health_code, response.headers, context)

    case health_result do
      :ok ->
        websocket_attempt_metadata = upstream_websocket_attempt_metadata(response_context)
        transports = resolved_transports(response_context, websocket_attempt_metadata)

        result =
          AttemptSettlement.finalize_partial_stream_failure(
            context.reserved.request,
            context.attempt,
            stream_usage(body, nil),
            SettlementAttrs.partial_stream_failure(
              context,
              response.status,
              code,
              terminal_failure_message(code, "upstream stream returned first event #{code}"),
              first_event_attempt_metadata(
                response_context,
                websocket_attempt_metadata,
                failure,
                "first_event_stream_failure"
              )
              |> terminal_failure_attempt_metadata(code)
            )
          )

        emit_terminal_outcome(result, code, transports)
        result

      {:error, _gateway_error} = error ->
        error
    end
  end

  @spec first_event_attempt_metadata(ResponseContext.t(), map(), map(), String.t()) :: map()
  defp first_event_attempt_metadata(
         %ResponseContext{context: context, response: response},
         websocket_attempt_metadata,
         failure,
         error_kind
       ) do
    response
    |> Metadata.first_event_stream_metadata(failure, error_kind, context.request_options)
    |> merge_upstream_websocket_connection(
      websocket_attempt_metadata.upstream_websocket_connection
    )
  end

  @spec finalize_failure(binary(), term(), ResponseContext.t()) :: finalization_result()
  @spec finalize_failure(binary(), term(), ResponseContext.t(), term()) :: finalization_result()
  def finalize_failure(
        body,
        reason,
        %ResponseContext{context: context, response: response} = response_context,
        stream_state \\ nil
      ) do
    code = error_code(reason)
    terminal_failure = terminal_failure_reason(reason)
    websocket_attempt_metadata = upstream_websocket_attempt_metadata(response_context)
    transports = resolved_transports(response_context, websocket_attempt_metadata)

    case record_stream_failure_health(
           reason,
           code,
           terminal_failure,
           response.headers,
           context
         ) do
      :ok ->
        attempt_metadata =
          response
          |> Metadata.response_metadata("stream_interrupted", context.request_options)
          |> Metadata.merge_stream_state_metadata(stream_state)
          |> merge_upstream_websocket_connection(
            websocket_attempt_metadata.upstream_websocket_connection
          )
          |> Metadata.maybe_put_masked_error_metadata(
            terminal_failure && terminal_failure.upstream_code,
            code
          )
          |> non_first_event_terminal_attempt_metadata(terminal_failure, code)
          |> TransportFailureReason.maybe_put_upstream_stream_interrupted_metadata(reason, body)
          |> merge_websocket_transport_failure(
            websocket_attempt_metadata.transport_failure,
            stream_state
          )

        result =
          AttemptSettlement.finalize_partial_stream_failure(
            context.reserved.request,
            context.attempt,
            stream_usage(body, stream_state),
            SettlementAttrs.partial_stream_failure(
              context,
              response.status,
              code,
              terminal_failure_message(code, Metadata.safe_reason(reason)),
              attempt_metadata
            )
          )

        emit_terminal_outcome(result, code, transports)
        result

      {:error, _gateway_error} = error ->
        error
    end
  end

  defp emit_terminal_outcome(result, code, transports) do
    outcome = if code == "client_disconnected", do: "interrupted", else: "failed"

    case result do
      {:ok, _finalized} -> emit_settlement_outcome(result, outcome, transports)
      {:error, _gateway_error} -> emit_settlement_failure(result, transports)
    end
  end

  defp emit_settlement_outcome({:ok, finalized}, outcome, transports) do
    if AttemptSettlement.first_settlement?(finalized) do
      emit_stream_outcome(
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
    emit_stream_outcome(
      "settlement_failed",
      transports.downstream_transport,
      transports.upstream_transport
    )
  end

  defp emit_settlement_failure({:error, _gateway_error}, _transports), do: :ok

  defp resolved_transports(
         %ResponseContext{context: context, upstream_transport: transport_override},
         websocket_attempt_metadata
       ) do
    %{
      downstream_transport: downstream_transport(context.request_options),
      upstream_transport:
        upstream_transport(
          transport_override,
          websocket_attempt_metadata.upstream_websocket_connection
        )
    }
  end

  defp merge_upstream_websocket_connection(metadata, connection) do
    metadata
    |> Map.drop(["upstream_websocket_connection", :upstream_websocket_connection])
    |> Map.merge(Metadata.upstream_websocket_connection_attempt_metadata(connection))
  end

  defp upstream_websocket_attempt_metadata(%ResponseContext{
         upstream_websocket_connection: connection
       })
       when not is_nil(connection),
       do: %{upstream_websocket_connection: connection, transport_failure: nil}

  defp upstream_websocket_attempt_metadata(%ResponseContext{
         response: %Req.Response{body: %WebsocketBridgeStream{} = stream}
       }) do
    WebsocketBridgeStream.take_upstream_websocket_attempt_metadata(stream)
  end

  defp upstream_websocket_attempt_metadata(%ResponseContext{}),
    do: %{upstream_websocket_connection: nil, transport_failure: nil}

  defp merge_websocket_transport_failure(metadata, transport_failure, stream_state) do
    transport_failure =
      TransportFailureReason.sanitize_transport_failure_metadata(transport_failure)

    if map_size(transport_failure) > 0 do
      transport_failure = put_actual_visibility(transport_failure, stream_state)
      inferred_failure = Map.get(metadata, "transport_failure", %{})

      merged_failure =
        inferred_failure
        |> Map.merge(transport_failure)
        |> preserve_upstream_commitment(inferred_failure, transport_failure)

      Map.put(metadata, "transport_failure", merged_failure)
    else
      metadata
    end
  end

  defp put_actual_visibility(transport_failure, stream_state) do
    case DownstreamStream.public_openai_responses_stream_metadata(stream_state) do
      %{"public_openai_responses_stream" => %{"visible_seen" => visible_seen}}
      when is_boolean(visible_seen) ->
        Map.put(transport_failure, "pre_visible_output", not visible_seen)

      _metadata ->
        transport_failure
    end
  end

  defp preserve_upstream_commitment(merged, inferred, retained) do
    if inferred["upstream_committed"] == true or retained["upstream_committed"] == true do
      Map.put(merged, "upstream_committed", true)
    else
      merged
    end
  end

  @spec error_code(term()) :: String.t()
  def error_code({:chunk, :closed}), do: "client_disconnected"
  def error_code({:chunk, _reason}), do: "downstream_stream_error"
  def error_code({:upstream_idle_timeout, _reason}), do: "stream_idle_timeout"
  def error_code({:upstream_stream_interrupted, _reason}), do: "upstream_stream_error"
  def error_code(:upstream_websocket_receive_timeout), do: "stream_idle_timeout"
  def error_code({:terminal_stream_failure, %{code: code}}) when is_binary(code), do: code
  def error_code(:upstream_unauthorized), do: "upstream_unauthorized"
  def error_code(_reason), do: "upstream_stream_error"

  @spec record_health_failure(term(), term(), SelectedCandidateContext.t()) :: health_result()
  def record_health_failure({:chunk, _reason}, _code, _context), do: :ok

  def record_health_failure(_reason, code, %SelectedCandidateContext{} = context)
      when is_binary(code) do
    if health_neutral_error_code?(code) do
      DispatchLifecycle.neutral_completion(context)
    else
      route_failure(context, code)
    end
  end

  def record_health_failure(_reason, code, %SelectedCandidateContext{} = context) do
    route_failure(context, code)
  end

  @spec record_terminal_health_failure(term(), term(), SelectedCandidateContext.t()) ::
          health_result()
  def record_terminal_health_failure(code, headers, %SelectedCandidateContext{} = context)
      when is_binary(code) do
    if health_neutral_terminal_failure?(code, headers) do
      DispatchLifecycle.neutral_completion(context)
    else
      record_health_failure(code, code, context)
    end
  end

  def record_terminal_health_failure(code, _headers, %SelectedCandidateContext{} = context) do
    record_health_failure(code, code, context)
  end

  defp record_stream_failure_health(
         :upstream_stream_interrupted,
         "upstream_stream_error",
         nil,
         _headers,
         context
       ),
       do: DispatchLifecycle.neutral_completion(context)

  defp record_stream_failure_health(
         {:upstream_stream_interrupted, _reason},
         "upstream_stream_error",
         nil,
         _headers,
         context
       ),
       do: DispatchLifecycle.neutral_completion(context)

  defp record_stream_failure_health(reason, code, nil, _headers, context) do
    record_health_failure(reason, code, context)
  end

  defp record_stream_failure_health(
         _reason,
         code,
         terminal_failure,
         headers,
         %SelectedCandidateContext{} = context
       ) do
    if compact_assignment_model_miss?(terminal_failure, context) do
      :ok
    else
      health_code = terminal_failure.upstream_code || code
      record_terminal_health_failure(health_code, headers, context)
    end
  end

  defp route_failure(%SelectedCandidateContext{} = context, code) do
    case DispatchLifecycle.failure(context, code) do
      {:ok, _demotion_reason} -> :ok
      {:error, gateway_error} -> {:error, gateway_error}
    end
  end

  defp health_neutral_error_code?(code) do
    code in [
      "context_length_exceeded",
      "cyber_policy",
      "invalid_request",
      "invalid_request_error",
      "invalid_previous_response_id",
      "misalignment_policy_violation",
      "missing_required_parameter",
      "overloaded_error",
      "previous_response_not_found",
      "server_is_overloaded",
      "server_error",
      "unsupported_input_image_format",
      "unsupported_parameter",
      "unsupported_value",
      "usage_limit_exceeded",
      "usage_limit_reached"
    ]
  end

  defp health_neutral_terminal_failure?(code, headers) do
    health_neutral_error_code?(code) or
      workspace_quota_depleted?(code) or
      workspace_quota_depleted?(RateLimitReachedType.parse_header(headers))
  end

  defp workspace_quota_depleted?(code) do
    code in [
      "workspace_member_credits_depleted",
      "workspace_member_usage_limit_reached",
      "workspace_owner_credits_depleted",
      "workspace_owner_usage_limit_reached"
    ]
  end

  defp terminal_failure_message(code, default) do
    if code == MisalignmentPolicyViolation.code(),
      do: MisalignmentPolicyViolation.fallback_message(),
      else: default
  end

  defp terminal_failure_attempt_metadata(metadata, code) do
    if code == MisalignmentPolicyViolation.code(),
      do: Map.delete(metadata, "upstream_error_param"),
      else: metadata
  end

  defp non_first_event_terminal_attempt_metadata(
         metadata,
         %{diagnostic_upstream_code: diagnostic_upstream_code} = failure,
         code
       ) do
    metadata
    |> maybe_put_compaction_terminal_code(diagnostic_upstream_code)
    |> maybe_put_compaction_terminal_type(failure.event_type)
    |> Map.delete("upstream_error_param")
    |> Metadata.maybe_put_upstream_error_param(%{
      upstream_error_param: UpstreamErrorParam.sanitize(failure.upstream_error_param)
    })
    |> terminal_failure_attempt_metadata(code)
  end

  defp non_first_event_terminal_attempt_metadata(metadata, failure, code) do
    metadata
    |> Metadata.maybe_put_upstream_error_param(failure)
    |> terminal_failure_attempt_metadata(code)
  end

  defp maybe_put_compaction_terminal_code(metadata, diagnostic_upstream_code) do
    case DiagnosticTaxonomy.identifier(diagnostic_upstream_code) do
      code when is_binary(code) -> Map.put(metadata, "upstream_error_code", code)
      nil -> metadata
    end
  end

  defp maybe_put_compaction_terminal_type(metadata, event_type) do
    case DiagnosticTaxonomy.identifier(event_type) do
      type when is_binary(type) -> Map.put(metadata, "stream_terminal_type", type)
      nil -> metadata
    end
  end

  defp terminal_failure_reason({:terminal_stream_failure, %{} = failure}), do: failure
  defp terminal_failure_reason(_reason), do: nil

  defp stream_failure_code(nil, _context), do: nil

  defp stream_failure_code(failure, context) do
    assignment_advertised? =
      ModelMetadata.assignment_source?(context.model, context.assignment.id)

    if not compact_stream?(context) and
         ModelUnavailability.terminal_failure?(failure, assignment_advertised?) do
      "upstream_model_unavailable"
    else
      failure.code
    end
  end

  defp stream_health_code(_failure, "upstream_model_unavailable"),
    do: "upstream_model_unavailable"

  defp stream_health_code(failure, code), do: failure.upstream_code || code

  defp compact_assignment_model_miss?(failure, context) do
    compact_stream?(context) and
      ModelUnavailability.terminal_failure?(
        failure,
        ModelMetadata.assignment_source?(context.model, context.assignment.id)
      )
  end

  defp compact_stream?(%SelectedCandidateContext{endpoint: endpoint}),
    do: endpoint == "/backend-api/codex/responses/compact"

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)

  defp stream_usage(body, stream_state) do
    StreamUsageObserver.usage(stream_state_usage(stream_state)) || ResponseUsage.from_sse(body)
  end

  @doc false
  @spec emit_stream_finalization(map(), String.t(), String.t()) :: :ok
  def emit_stream_finalization(usage, downstream_transport, upstream_transport) do
    :telemetry.execute(
      [:codex_pooler, :gateway, :stream, :finalization],
      %{count: 1},
      %{
        usage_status: usage[:status],
        usage_source: usage_source_class(usage),
        downstream_transport: downstream_transport,
        upstream_transport: upstream_transport
      }
    )
  end

  @doc false
  @spec emit_stream_outcome(String.t(), String.t(), String.t()) :: :ok
  def emit_stream_outcome(outcome, downstream_transport, upstream_transport) do
    :telemetry.execute(
      [:codex_pooler, :gateway, :stream, :outcome],
      %{count: 1},
      %{
        outcome: outcome,
        downstream_transport: downstream_transport,
        upstream_transport: upstream_transport
      }
    )
  end

  defp usage_source_class(%{status: "usage_known", source: "websocket_upstream_usage"}),
    do: "websocket_upstream_usage"

  defp usage_source_class(%{status: "usage_known"}), do: "upstream_usage"
  defp usage_source_class(_usage), do: "unknown"

  @doc false
  @spec downstream_transport(term()) :: String.t()
  def downstream_transport(%{transport: %{transport: transport}})
      when transport in ["http_sse", "websocket"],
      do: transport

  def downstream_transport(_request_options), do: "unknown"

  @doc false
  @spec upstream_transport(:websocket | nil, term()) :: String.t()
  def upstream_transport(:websocket, _connection), do: "websocket"
  def upstream_transport(nil, nil), do: "http_sse"
  def upstream_transport(nil, _connection), do: "websocket"

  defp stream_state_usage(%{usage_observer: %{} = usage_state}), do: usage_state
  defp stream_state_usage(_stream_state), do: StreamUsageObserver.new()
end
