defmodule CodexPooler.Gateway.Runtime.Finalization.Streaming do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Dispatch.ResponseContext
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Streaming.Types, as: StreamTypes

  alias CodexPooler.Gateway.Runtime.Finalization.{
    AttemptSettlement,
    Metadata,
    ResponseUsage,
    SettlementAttrs,
    SideEffects
  }

  alias CodexPooler.Gateway.Runtime.Routing.DispatchLifecycle
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.TransportFailureReason
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
  def finalize_success(body, %ResponseContext{context: context, response: response}, callbacks) do
    %{
      reserved: reserved,
      attempt: attempt,
      started: started,
      payload: payload,
      request_options: request_options
    } = context

    case AttemptSettlement.finalize_success(
           reserved.request,
           attempt,
           ResponseUsage.from_sse(body),
           SettlementAttrs.success(
             context,
             response.status,
             Metadata.response_metadata(response, nil, request_options),
             started: started
           )
         ) do
      {:ok, _finalized} = result ->
        SideEffects.record_success(context, payload, body, request_options, callbacks)

        result

      {:error, _gateway_error} = error ->
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
        %ResponseContext{context: context, response: response},
        opts \\ []
      ) do
    code = failure.code
    health_code = failure.upstream_code || code

    health_result =
      if Keyword.get(opts, :record_health?, true),
        do: record_health_failure(health_code, health_code, context),
        else: :ok

    with :ok <- health_result do
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
            Metadata.first_event_stream_metadata(
              response,
              failure,
              "retryable_first_event",
              context.request_options
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
        %ResponseContext{context: context, response: response}
      ) do
    code = failure.code

    health_code = failure.upstream_code || code

    with :ok <- record_terminal_health_failure(health_code, response.headers, context) do
      AttemptSettlement.finalize_partial_stream_failure(
        context.reserved.request,
        context.attempt,
        ResponseUsage.from_sse(body),
        SettlementAttrs.partial_stream_failure(
          context,
          response.status,
          code,
          "upstream stream returned first event #{code}",
          Metadata.first_event_stream_metadata(
            response,
            failure,
            "first_event_stream_failure",
            context.request_options
          )
        )
      )
    end
  end

  @spec finalize_failure(binary(), term(), ResponseContext.t()) :: finalization_result()
  def finalize_failure(body, reason, %ResponseContext{context: context, response: response}) do
    code = error_code(reason)
    terminal_failure = terminal_failure_reason(reason)

    with :ok <-
           record_stream_failure_health(reason, code, terminal_failure, response.headers, context) do
      attempt_metadata =
        response
        |> Metadata.response_metadata("stream_interrupted", context.request_options)
        |> Metadata.maybe_put_masked_error_metadata(
          terminal_failure && terminal_failure.upstream_code,
          code
        )
        |> TransportFailureReason.maybe_put_upstream_stream_interrupted_metadata(reason, body)

      AttemptSettlement.finalize_partial_stream_failure(
        context.reserved.request,
        context.attempt,
        ResponseUsage.from_sse(body),
        SettlementAttrs.partial_stream_failure(
          context,
          response.status,
          code,
          Metadata.safe_reason(reason),
          attempt_metadata
        )
      )
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

  defp record_stream_failure_health(_reason, code, terminal_failure, headers, context) do
    health_code = terminal_failure.upstream_code || code
    record_terminal_health_failure(health_code, headers, context)
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
      "invalid_request",
      "invalid_request_error",
      "invalid_previous_response_id",
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
      workspace_usage_limit_reached?(code) or
      workspace_usage_limit_reached?(RateLimitReachedType.parse_header(headers))
  end

  defp workspace_usage_limit_reached?(code) do
    code in [
      "workspace_member_usage_limit_reached",
      "workspace_owner_usage_limit_reached"
    ]
  end

  defp terminal_failure_reason({:terminal_stream_failure, %{} = failure}), do: failure
  defp terminal_failure_reason(_reason), do: nil

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)
end
