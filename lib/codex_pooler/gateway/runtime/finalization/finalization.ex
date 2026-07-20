defmodule CodexPooler.Gateway.Runtime.Finalization do
  @moduledoc """
  Finalizes gateway runtime dispatch attempts after upstream transport returns.
  """

  alias CodexPooler.Gateway.Runtime.Dispatch.ResponseContext
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Runtime.Streaming.Types, as: StreamTypes

  alias CodexPooler.Gateway.Runtime.Finalization.{
    AttemptSettlement,
    Metadata,
    ResponseUsage,
    SettlementAttrs,
    SideEffects,
    Streaming,
    Websocket
  }

  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Gateway.Runtime.Routing.DispatchLifecycle
  alias CodexPooler.Gateway.Transports.ModelUnavailability
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.RouteClass

  @canonical_full_failure_body %{
    "error" => %{
      "code" => "server_error",
      "message" => "upstream request failed",
      "type" => "server_error"
    }
  }

  @type callbacks :: %{
          required(:register_continuity) => (term(), term(), term() -> term()),
          required(:stream_result) => StreamTypes.stream_result_callback()
        }
  @type completed_websocket_finalization :: %{
          required(:body) => binary(),
          required(:status) => pos_integer(),
          required(:headers) => list(),
          required(:started) => integer(),
          required(:callbacks) => callbacks(),
          optional(atom()) => term()
        }
  @type terminal_websocket_finalization :: %{
          required(:body) => binary(),
          required(:terminal) => term(),
          required(:status) => pos_integer(),
          required(:headers) => list(),
          required(:started) => integer(),
          optional(atom()) => term()
        }
  @type failed_websocket_finalization :: %{
          required(:body) => binary(),
          required(:reason) => term(),
          required(:headers) => list(),
          required(:started) => integer(),
          optional(atom()) => term()
        }
  @type stream_failure :: StreamProtocol.terminal_failure()
  @type stream_finalization_result :: {:ok, term()} | {:error, map()}
  @spec handle_http_response(
          Req.Response.t(),
          SelectedCandidateContext.t(),
          callbacks()
        ) ::
          {:ok, map()} | {:error, map()} | {:retry, term()}
  def handle_http_response(
        %Req.Response{status: status} = response,
        %SelectedCandidateContext{} = context,
        _callbacks
      )
      when status == 429 or status >= 500 do
    %{identity: identity} = context

    RateLimitObserver.record_headers(identity, response)

    if Metadata.response_body_limit_exceeded?(response) do
      finalize_response_body_limit_exceeded(response, context)
    else
      body = Metadata.response_body(response)
      RateLimitObserver.record_error(identity, body)

      finalize_retryable_non_success_response(response, context, body)
    end
  end

  def handle_http_response(
        %Req.Response{status: status} = response,
        %SelectedCandidateContext{} = context,
        callbacks
      )
      when status >= 200 and status < 300 do
    %{identity: identity} = context

    RateLimitObserver.record_headers(identity, response)

    if Metadata.response_body_limit_exceeded?(response) do
      finalize_response_body_limit_exceeded(response, context)
    else
      %{reserved: reserved, assignment: assignment, payload: payload} = context

      body = Metadata.response_body(response)
      SideEffects.maybe_enqueue_gateway_reconciliation(reserved.request.pool_id, assignment)

      cond do
        RouteClass.streaming?(payload) ->
          normalize_stream_result(callbacks.stream_result.(response, context))

        Metadata.json_content?(response) and not StreamProtocol.valid_json?(body) ->
          finalize_invalid_json_response(response, context)

        true ->
          finalize_successful_json_response(response, context, body, callbacks)
      end
    end
  end

  def handle_http_response(
        %Req.Response{} = response,
        %SelectedCandidateContext{} = context,
        _callbacks
      ) do
    %{identity: identity} = context

    RateLimitObserver.record_headers(identity, response)

    if Metadata.response_body_limit_exceeded?(response) do
      finalize_response_body_limit_exceeded(response, context)
    else
      body = Metadata.response_body(response)
      RateLimitObserver.record_error(identity, body)

      finalize_non_success_response(response, context, body)
    end
  end

  defp normalize_stream_result({:ok, result}), do: {:ok, result}
  defp normalize_stream_result({:error, reason}), do: {:error, reason}
  defp normalize_stream_result(result), do: {:ok, result}

  defp finalize_non_success_response(%Req.Response{status: status} = response, context, body) do
    if assignment_model_unavailable?(status, body, context) do
      finalize_assignment_model_unavailable(response, context, body)
    else
      with :ok <- maybe_record_unauthorized_route_failure(status, context) do
        finalize_upstream_status_failure(response, context, body)
      end
    end
  end

  defp finalize_retryable_non_success_response(
         %Req.Response{status: status} = response,
         context,
         body
       ) do
    if assignment_model_unavailable?(status, body, context) do
      finalize_assignment_model_unavailable(response, context, body)
    else
      with :ok <- record_status_route_failure(context, status) do
        finalize_retryable_status_or_failure(response, context, body)
      end
    end
  end

  @spec handle_dispatch_error(term(), SelectedCandidateContext.t(), non_neg_integer()) ::
          {:error, map()} | {:retry, term()}
  def handle_dispatch_error(reason, %SelectedCandidateContext{} = context, latency) do
    %{
      request_options: request_options
    } = context

    code = dispatch_error_code(reason)

    attempt_metadata =
      Map.merge(Metadata.route_attempt_metadata(request_options), %{
        "error_code" => code,
        "message" => Metadata.safe_reason(reason)
      })
      |> maybe_put_transport_failure_metadata(reason)

    with :ok <- record_dispatch_route_failure(code, context) do
      finalize_dispatch_error_after_route_failure(
        reason,
        context,
        latency,
        code,
        attempt_metadata
      )
    end
  end

  @spec finalize_completed_websocket_response(
          SelectedCandidateContext.t(),
          completed_websocket_finalization()
        ) :: {:ok, map()} | {:error, map()}
  defdelegate finalize_completed_websocket_response(context, finalization),
    to: Websocket,
    as: :finalize_completed

  @spec finalize_terminal_websocket_response(
          SelectedCandidateContext.t(),
          terminal_websocket_finalization()
        ) :: {:ok, map()} | {:error, map()}
  defdelegate finalize_terminal_websocket_response(context, finalization),
    to: Websocket,
    as: :finalize_terminal

  @spec finalize_failed_websocket_response(
          SelectedCandidateContext.t(),
          failed_websocket_finalization()
        ) ::
          {:error, map()}
  defdelegate finalize_failed_websocket_response(context, finalization),
    to: Websocket,
    as: :finalize_failed

  @spec finalize_stream_success(binary(), ResponseContext.t(), callbacks()) ::
          stream_finalization_result()
  defdelegate finalize_stream_success(body, response_context, callbacks),
    to: Streaming,
    as: :finalize_success

  @spec finalize_stream_success(binary(), ResponseContext.t(), callbacks(), term()) ::
          stream_finalization_result()
  defdelegate finalize_stream_success(body, response_context, callbacks, stream_state),
    to: Streaming,
    as: :finalize_success

  @spec record_retryable_first_event_stream_failure(
          binary(),
          stream_failure(),
          ResponseContext.t(),
          keyword()
        ) :: stream_finalization_result()
  defdelegate record_retryable_first_event_stream_failure(
                body,
                failure,
                response_context,
                opts \\ []
              ),
              to: Streaming,
              as: :record_retryable_first_event_failure

  @spec finalize_first_event_stream_failure(binary(), stream_failure(), ResponseContext.t()) ::
          stream_finalization_result()
  defdelegate finalize_first_event_stream_failure(body, failure, response_context),
    to: Streaming,
    as: :finalize_first_event_failure

  @spec finalize_stream_failure(binary(), term(), ResponseContext.t()) ::
          stream_finalization_result()
  defdelegate finalize_stream_failure(body, reason, response_context),
    to: Streaming,
    as: :finalize_failure

  @spec finalize_stream_failure(binary(), term(), ResponseContext.t(), term()) ::
          stream_finalization_result()
  defdelegate finalize_stream_failure(body, reason, response_context, stream_state),
    to: Streaming,
    as: :finalize_failure

  @spec stream_error_code(term()) :: String.t()
  defdelegate stream_error_code(reason), to: Streaming, as: :error_code

  defp finalize_retryable_status_or_failure(
         %Req.Response{status: status} = response,
         %SelectedCandidateContext{} = context,
         body
       ) do
    %{
      reserved: reserved,
      attempt: attempt,
      allow_retry?: allow_retry?,
      endpoint: endpoint,
      request_options: request_options
    } = context

    if allow_retry? and not compact_endpoint?(endpoint) do
      latency = elapsed_ms(context.started)

      case AttemptSettlement.record_retryable_failure(reserved.request, attempt, %{
             response_status_code: status,
             last_error_code: "retryable_upstream_status",
             error_message: "upstream returned #{status}",
             latency_ms: latency,
             attempt_metadata:
               Metadata.response_metadata(
                 response,
                 "retryable_upstream_status",
                 request_options
               )
           }) do
        {:ok, _attempt} -> {:retry, :retryable_status}
        {:error, gateway_error} -> {:error, gateway_error}
      end
    else
      finalize_upstream_status_failure(response, context, body,
        attempt_status: if(allow_retry?, do: "retryable_failed", else: "failed")
      )
    end
  end

  defp finalize_assignment_model_unavailable(response, context, body) do
    with :ok <- record_dispatch_route_failure("upstream_model_unavailable", context) do
      if context.allow_retry? do
        record_assignment_model_unavailable_retry(response, context)
      else
        finalize_upstream_status_failure(response, context, body,
          failure_projection: :passthrough
        )
      end
    end
  end

  defp record_assignment_model_unavailable_retry(response, context) do
    %{reserved: reserved, attempt: attempt, request_options: request_options} = context

    case AttemptSettlement.record_retryable_failure(reserved.request, attempt, %{
           response_status_code: response.status,
           last_error_code: "upstream_model_unavailable",
           error_message: "upstream model unavailable",
           latency_ms: elapsed_ms(context.started),
           attempt_metadata:
             Metadata.response_metadata(
               response,
               "upstream_model_unavailable",
               request_options
             )
         }) do
      {:ok, _attempt} -> {:retry, :upstream_model_unavailable}
      {:error, gateway_error} -> {:error, gateway_error}
    end
  end

  defp assignment_model_unavailable?(status, body, context) do
    not compact_endpoint?(context.endpoint) and
      ModelUnavailability.http_response?(
        status,
        body,
        ModelMetadata.assignment_source?(context.model, context.assignment.id)
      )
  end

  defp finalize_dispatch_error_after_route_failure(
         reason,
         %SelectedCandidateContext{} = context,
         latency,
         code,
         attempt_metadata
       ) do
    %{
      reserved: reserved,
      attempt: attempt,
      allow_retry?: allow_retry?,
      endpoint: endpoint
    } = context

    if allow_retry? and not compact_endpoint?(endpoint) do
      case AttemptSettlement.record_retryable_failure(reserved.request, attempt, %{
             last_error_code: code,
             error_message: Metadata.safe_reason(reason),
             latency_ms: latency,
             attempt_metadata: attempt_metadata
           }) do
        {:ok, _attempt} -> {:retry, code}
        {:error, gateway_error} -> {:error, gateway_error}
      end
    else
      case AttemptSettlement.finalize_failure(
             reserved.request,
             attempt,
             SettlementAttrs.failure(
               context,
               502,
               code,
               Metadata.safe_reason(reason),
               attempt_metadata,
               latency_ms: latency
             )
           ) do
        {:ok, _finalized} ->
          {:error,
           error(502, "upstream_request_failed", Metadata.upstream_failure_message(endpoint))}

        {:error, gateway_error} ->
          {:error, gateway_error}
      end
    end
  end

  defp record_status_route_failure(%SelectedCandidateContext{} = context, status) do
    status |> status_demotion_code() |> record_dispatch_route_failure(context)
  end

  defp record_dispatch_route_failure(code, %SelectedCandidateContext{} = context) do
    case DispatchLifecycle.failure(context, code) do
      {:ok, _demotion_reason} -> :ok
      {:error, gateway_error} -> {:error, gateway_error}
    end
  end

  defp maybe_record_unauthorized_route_failure(401, %SelectedCandidateContext{} = context) do
    record_dispatch_route_failure("upstream_unauthorized", context)
  end

  defp maybe_record_unauthorized_route_failure(_status, %SelectedCandidateContext{}), do: :ok

  defp finalize_upstream_status_failure(
         response,
         %SelectedCandidateContext{} = context,
         body,
         opts \\ []
       ) do
    %{
      reserved: reserved,
      attempt: attempt,
      payload: payload,
      request_options: request_options
    } = context

    status = response.status
    error_code = Metadata.upstream_status_error_code(status, request_options)

    attrs =
      SettlementAttrs.failure(
        context,
        status,
        error_code,
        "upstream returned #{status}",
        Metadata.response_metadata(response, error_code, request_options),
        latency_ms: elapsed_ms(context.started),
        usage: %{status: "usage_unknown", source: "upstream_status"}
      )

    attrs =
      case Keyword.fetch(opts, :attempt_status) do
        {:ok, attempt_status} -> Map.put(attrs, :attempt_status, attempt_status)
        :error -> attrs
      end

    case AttemptSettlement.finalize_failure(reserved.request, attempt, attrs) do
      {:ok, _finalized} ->
        headers =
          Metadata.response_headers(response, RouteClass.streaming?(payload), request_options)

        result = failure_result(status, headers, body, request_options, opts)

        {:ok, result}

      {:error, gateway_error} ->
        {:error, gateway_error}
    end
  end

  defp failure_result(status, headers, body, request_options, opts) do
    case {Keyword.get(opts, :failure_projection, :mode_scoped),
          Metadata.explicit_full_ordinary_responses?(request_options)} do
      {:mode_scoped, true} ->
        %{status: status, headers: headers, body: @canonical_full_failure_body}

      {_projection, _explicit_full?} ->
        %{status: status, headers: headers, raw_body: body}
    end
  end

  defp finalize_response_body_limit_exceeded(response, %SelectedCandidateContext{} = context) do
    %{reserved: reserved, attempt: attempt, request_options: request_options} = context

    code = "upstream_response_too_large"
    message = "upstream response body exceeded maximum allowed size"
    latency = elapsed_ms(context.started)

    with :ok <- record_dispatch_route_failure(code, context),
         {:ok, _finalized} <-
           AttemptSettlement.finalize_failure(
             reserved.request,
             attempt,
             SettlementAttrs.failure(
               context,
               502,
               code,
               message,
               Metadata.response_metadata(response, code, request_options),
               latency_ms: latency
             )
           ) do
      {:error, error(502, code, message)}
    else
      {:error, gateway_error} -> {:error, gateway_error}
    end
  end

  defp finalize_invalid_json_response(response, %SelectedCandidateContext{} = context) do
    %{reserved: reserved, attempt: attempt, request_options: request_options} = context

    latency = elapsed_ms(context.started)

    case AttemptSettlement.finalize_failure(
           reserved.request,
           attempt,
           SettlementAttrs.failure(
             context,
             502,
             "invalid_upstream_response",
             "upstream response was not valid json",
             Metadata.response_metadata(response, "invalid_upstream_response", request_options),
             latency_ms: latency
           )
         ) do
      {:ok, _finalized} ->
        {:error, error(502, "invalid_upstream_response", "upstream response was not valid json")}

      {:error, gateway_error} ->
        {:error, gateway_error}
    end
  end

  defp finalize_successful_json_response(
         response,
         %SelectedCandidateContext{} = context,
         body,
         callbacks
       ) do
    %{
      reserved: reserved,
      attempt: attempt,
      payload: payload,
      request_options: request_options
    } = context

    latency = elapsed_ms(context.started)

    case AttemptSettlement.finalize_success(
           reserved.request,
           attempt,
           ResponseUsage.from_json(body),
           SettlementAttrs.success(
             context,
             response.status,
             Metadata.response_metadata(response, nil, request_options),
             latency_ms: latency
           )
         ) do
      {:ok, _finalized} ->
        SideEffects.record_success(context, payload, body, request_options, callbacks)

        {:ok,
         %{
           status: response.status,
           headers: Metadata.response_headers(response, false, request_options),
           raw_body: body
         }}

      {:error, gateway_error} ->
        {:error, gateway_error}
    end
  end

  defp compact_endpoint?(endpoint), do: endpoint == "/backend-api/codex/responses/compact"

  @spec maybe_put_transport_failure_metadata(map(), term()) :: map()
  defp maybe_put_transport_failure_metadata(metadata, %{transport_failure: transport_failure})
       when is_map(transport_failure) and map_size(transport_failure) > 0 do
    Map.put(metadata, "transport_failure", transport_failure)
  end

  defp maybe_put_transport_failure_metadata(metadata, %{"transport_failure" => transport_failure})
       when is_map(transport_failure) and map_size(transport_failure) > 0 do
    Map.put(metadata, "transport_failure", transport_failure)
  end

  defp maybe_put_transport_failure_metadata(metadata, _reason), do: metadata

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)
  defp dispatch_error_code(:invalid_upstream_base_url), do: "invalid_upstream_base_url"
  defp dispatch_error_code(%{code: code}), do: to_string(code)
  defp dispatch_error_code(_reason), do: "upstream_network_error"
  defp status_demotion_code(401), do: "upstream_unauthorized"
  defp status_demotion_code(429), do: "upstream_rate_limited"
  defp status_demotion_code(status) when status >= 500, do: "upstream_5xx"
  defp status_demotion_code(_status), do: "upstream_status"

  defp error(status, code, message, param \\ nil, metadata \\ %{}),
    do: Map.merge(%{status: status, code: code, message: message, param: param}, metadata)
end
