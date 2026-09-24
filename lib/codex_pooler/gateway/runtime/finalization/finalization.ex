defmodule CodexPooler.Gateway.Runtime.Finalization do
  @moduledoc """
  Finalizes gateway runtime dispatch attempts after upstream transport returns.
  """

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.OpenAICompatibility.NativeImageResult
  alias CodexPooler.Gateway.Payloads.{CompactionTrigger, RequestOptions}
  alias CodexPooler.Gateway.Payloads.RequestOptions.OpenAICompatibility
  alias CodexPooler.Gateway.Runtime.Dispatch.PartitionFallback
  alias CodexPooler.Gateway.Runtime.Dispatch.ResponseContext
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Streaming.Types, as: StreamTypes

  alias CodexPooler.Gateway.Runtime.Finalization.{
    AttemptSettlement,
    Metadata,
    NativeRateLimitRelay,
    ProviderUsageLimit,
    ResponseUsage,
    SettlementAttrs,
    SideEffects,
    Streaming,
    UsageLimitRefusal,
    ValidationRejection,
    Websocket
  }

  alias CodexPooler.Gateway.Routing.CandidateEligibility.PoolReturn
  alias CodexPooler.Gateway.Routing.CircuitRetryAfter
  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Gateway.Runtime.Routing.DispatchLifecycle

  alias CodexPooler.Gateway.Transports.{
    MisalignmentPolicyViolation,
    ModelUnavailability,
    TransportFailureReason
  }

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.RouteClass

  @canonical_full_failure_message "upstream request failed"
  @canonical_full_failure_body %{
    "error" => %{
      "code" => "server_error",
      "message" => @canonical_full_failure_message,
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
  @type stream_finalization_result :: Streaming.finalization_result()
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
    if Metadata.response_body_limit_exceeded?(response) do
      finalize_response_body_limit_exceeded(response, context)
    else
      body = Metadata.response_body(response)
      finalize_retryable_non_success_response(response, context, body)
    end
  end

  def handle_http_response(
        %Req.Response{status: status} = response,
        %SelectedCandidateContext{} = context,
        callbacks
      )
      when status >= 200 and status < 300 do
    if Metadata.response_body_limit_exceeded?(response) do
      finalize_response_body_limit_exceeded(response, context)
    else
      %{
        payload: payload,
        request_options: request_options
      } =
        context

      body = Metadata.response_body(response)

      cond do
        RouteClass.streaming?(payload) or CompactionTrigger.streaming_result?(request_options) ->
          normalize_stream_result(callbacks.stream_result.(response, context))

        native_compaction_result?(context) ->
          finalize_native_compaction_response(response, context, body, callbacks)

        true ->
          finalize_json_response(response, context, body, callbacks)
      end
    end
  end

  def handle_http_response(
        %Req.Response{} = response,
        %SelectedCandidateContext{} = context,
        _callbacks
      ) do
    if Metadata.response_body_limit_exceeded?(response) do
      finalize_response_body_limit_exceeded(response, context)
    else
      body = Metadata.response_body(response)
      finalize_non_success_response(response, context, body)
    end
  end

  defp normalize_stream_result({:ok, result}), do: {:ok, result}
  defp normalize_stream_result({:error, reason}), do: {:error, reason}
  defp normalize_stream_result(result), do: {:ok, result}

  defp finalize_non_success_response(%Req.Response{} = response, context, body) do
    case misalignment_policy_violation_summary(response, context, body) do
      {:ok, summary} ->
        finalize_misalignment_policy_violation(response, context, summary)

      :no_match ->
        finalize_other_non_success_response(response, context, body)
    end
  end

  defp finalize_other_non_success_response(
         %Req.Response{status: status} = response,
         context,
         body
       ) do
    cond do
      public_ineligible_misalignment_policy_violation?(status, body, context) ->
        finalize_upstream_status_failure(response, context, body, failure_projection: :canonical_full)

      assignment_model_unavailable?(status, body, context) ->
        finalize_assignment_model_unavailable(response, context, body)

      true ->
        finalize_upstream_status_failure(response, context, body, before_finalize: fn -> record_client_error_route_health(status, context) end)
    end
  end

  defp misalignment_policy_violation_summary(response, context, body) do
    case MisalignmentPolicyViolation.fetch_summary(response) do
      %{code: _code, message: _message} = summary ->
        {:ok, summary}

      nil ->
        MisalignmentPolicyViolation.classify_http(response.status, body, context.request_options)
    end
  end

  defp finalize_misalignment_policy_violation(response, context, summary) do
    finalize_upstream_status_failure(response, context, "",
      error_code: summary.code,
      accounting_message: MisalignmentPolicyViolation.fallback_message(),
      failure_projection: {:misalignment_policy_violation, summary},
      before_finalize: fn -> DispatchLifecycle.neutral_completion(context) end
    )
  end

  defp public_ineligible_misalignment_policy_violation?(status, body, context)
       when status in [400, 403] and is_binary(body) do
    request_options = context.request_options

    is_binary(request_options.openai_compatibility.source_endpoint) and
      not MisalignmentPolicyViolation.eligible_route?(request_options) and
      direct_misalignment_policy_violation_body?(body)
  end

  defp public_ineligible_misalignment_policy_violation?(_status, _body, _context), do: false

  defp direct_misalignment_policy_violation_body?(body) do
    case CodexPooler.JSON.decode(body) do
      {:ok, %{"error" => %{"code" => code}}} -> code == MisalignmentPolicyViolation.code()
      _other -> false
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
      finalize_retryable_status_or_failure(response, context, body)
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
      request_options
      |> Metadata.route_attempt_metadata()
      |> Map.merge(RequestOptions.prompt_cache_controls_attempt_metadata(request_options))
      |> Map.merge(%{
        "error_code" => code,
        "message" => Metadata.safe_reason(reason)
      })
      |> maybe_put_transport_failure_metadata(reason)

    finalize_dispatch_error_after_route_failure(
      reason,
      context,
      latency,
      code,
      attempt_metadata
    )
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

  # A failed websocket finalization may also ask the dispatcher to move to
  # the next route candidate (`{:retry, code}`) or report an already
  # finalized request (`{:ok, finalized}`); declaring only `{:error, map()}`
  # hid the failover contract from callers (findings#208).
  @spec finalize_failed_websocket_response(
          SelectedCandidateContext.t(),
          failed_websocket_finalization()
        ) ::
          {:ok, map()} | {:error, map()} | {:retry, term()}
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

    retry_reason = status_retry_reason(response, context, allow_retry? and not compact_endpoint?(endpoint))

    if retry_reason do
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
               ),
             before_finalize: fn ->
               SideEffects.observe_http_response(context, response, body)
               record_status_route_health(context, response)
             end
           }) do
        {:stale_generation, finalized} -> {:ok, finalized}
        {:ok, _attempt} -> {:retry, retry_reason}
        {:error, gateway_error} -> {:error, gateway_error}
      end
    else
      # The last candidate and the compact route (which never moves to another
      # candidate) record the same route failure the retry branch records: the
      # upstream answered 5xx or 429, so a half-open probe it answered is
      # resolved and the failure counts toward opening the circuit. Without it
      # the probe stayed counted in flight and blocked the assignment until
      # its lease ran out, and a single-assignment Pool never opened its
      # circuit on HTTP (findings#254 row 254-50).
      finalize_upstream_status_failure(response, context, body,
        attempt_status: if(allow_retry?, do: "retryable_failed", else: "failed"),
        before_finalize: fn -> record_status_route_health(context, response) end
      )
    end
  end

  # The last candidate of the selected canonical partition refused with a
  # provider usage limit before any output, and a candidate partition selection
  # held back can serve the model now: the dispatcher moves the turn there once,
  # as the next request's partition selection would (findings#206 row 206-586).
  # The refusal is recorded as the retryable 429 it is.
  defp status_retry_reason(_response, _context, true), do: :retryable_status

  defp status_retry_reason(response, context, false),
    do: if(partition_fallback?(response, context), do: :partition_fallback)

  defp partition_fallback?(%Req.Response{status: 429} = response, %SelectedCandidateContext{} = context),
    do: not compact_endpoint?(context.endpoint) and PartitionFallback.available?(context) and ProviderUsageLimit.usage_limit_refusal?(response)

  defp partition_fallback?(_response, _context), do: false

  defp finalize_assignment_model_unavailable(response, context, body) do
    if context.allow_retry? do
      record_assignment_model_unavailable_retry(response, context)
    else
      finalize_upstream_status_failure(response, context, body,
        failure_projection: :passthrough,
        before_finalize: fn ->
          record_dispatch_route_failure("upstream_model_unavailable", context)
        end
      )
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
             ),
           before_finalize: fn ->
             SideEffects.observe_http_response(
               context,
               response,
               Metadata.response_body(response)
             )

             record_dispatch_route_failure("upstream_model_unavailable", context)
           end
         }) do
      {:stale_generation, finalized} -> {:ok, finalized}
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

    if retry_dispatch_error?(allow_retry?, endpoint, reason) do
      case AttemptSettlement.record_retryable_failure(reserved.request, attempt, %{
             last_error_code: code,
             error_message: Metadata.safe_reason(reason),
             latency_ms: latency,
             attempt_metadata: attempt_metadata,
             before_finalize: fn -> record_dispatch_route_failure(code, context) end
           }) do
        {:stale_generation, finalized} -> {:ok, finalized}
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
               latency_ms: latency,
               before_finalize: fn -> record_dispatch_route_failure(code, context) end
             ),
             context.request_options.runtime.session_owner_witness
           ) do
        {:stale_generation, finalized} ->
          {:ok, finalized}

        {:ok, _finalized} ->
          {:error, error(502, "upstream_request_failed", Metadata.upstream_failure_message(endpoint))}

        {:error, gateway_error} ->
          {:error, gateway_error}
      end
    end
  end

  defp retry_dispatch_error?(allow_retry?, endpoint, reason) do
    allow_retry? and not compact_endpoint?(endpoint) and
      TransportFailureReason.retry_safe_before_submission?(reason)
  end

  # A provider usage limit whose headers exclude the refusing account is a
  # quota answer, not a route failure: no demotion, no circuit failure
  # (findings#206 row 206-594; `UsageLimitRefusal`). Every other 5xx and 429
  # keeps the status route failure.
  defp record_status_route_health(%SelectedCandidateContext{model: model} = context, %Req.Response{status: status} = response) do
    if UsageLimitRefusal.route_neutral?(response, model.upstream_model_id),
      do: DispatchLifecycle.neutral_completion(context),
      else: record_status_route_failure(context, status)
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

  defp record_client_error_route_health(401, %SelectedCandidateContext{} = context) do
    record_dispatch_route_failure("upstream_unauthorized", context)
  end

  # Any other non-429 4xx is the client's error and says nothing against the
  # route: no demotion, no circuit failure. It still proves the upstream
  # answered, so a half-open probe it answered is resolved neutrally, as the
  # websocket does for the same refusal; otherwise the probe stayed counted in
  # flight and blocked every other turn on the assignment until its lease ran
  # out (findings#254 row 254-32). Outside a probe the neutral completion
  # writes nothing.
  defp record_client_error_route_health(_status, %SelectedCandidateContext{} = context),
    do: DispatchLifecycle.neutral_completion(context)

  defp finalize_upstream_status_failure(
         response,
         %SelectedCandidateContext{} = context,
         body,
         opts
       ) do
    %{
      reserved: reserved,
      attempt: attempt,
      request_options: request_options
    } = context

    status = response.status

    error_code =
      Keyword.get_lazy(opts, :error_code, fn ->
        Metadata.upstream_status_error_code(status, request_options)
      end)

    accounting_message = Keyword.get(opts, :accounting_message, "upstream returned #{status}")

    # Classified once, before settlement, so the persisted bounded
    # supported-values fact and the message every projection renders come from
    # the same parse of the same body rather than from two reads of it
    # (codex-pooler-findings#177).
    validation_rejection = ValidationRejection.fetch(response, request_options)

    # Decided before settlement so the attempt records the reset the client
    # is told (findings#206 row 206-553).
    relayed_usage_limit = relayed_usage_limit(response, context)

    attrs =
      SettlementAttrs.failure(
        context,
        status,
        error_code,
        accounting_message,
        response
        |> Metadata.response_metadata(error_code, request_options)
        |> Map.merge(ValidationRejection.attempt_metadata(validation_rejection))
        |> Map.merge(relayed_usage_limit_metadata(relayed_usage_limit)),
        latency_ms: elapsed_ms(context.started),
        usage: %{status: "usage_unknown", source: "upstream_status"}
      )

    attrs =
      attrs
      |> apply_failure_settlement_options(opts)
      |> observe_http_response(context, response, body)

    case AttemptSettlement.finalize_failure(
           reserved.request,
           attempt,
           attrs,
           request_options.runtime.session_owner_witness
         ) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

      {:ok, _finalized} ->
        case relayed_usage_limit do
          {:ok, usage_limit_error} ->
            {:error, usage_limit_error}

          :unknown ->
            unanswered_failure_result(response, context, body, error_code, validation_rejection, opts)
        end

      {:error, gateway_error} ->
        {:error, gateway_error}
    end
  end

  defp relayed_failure_result(response, %SelectedCandidateContext{} = context, body, error_code, validation_rejection, opts) do
    %{payload: payload, request_options: request_options} = context
    headers = Metadata.response_headers(response, RouteClass.streaming?(payload), request_options)

    # The client reads the rejection's `input[N]` in its own positions;
    # the attempt above keeps the provider's (findings#254 row 254-61).
    index_map = request_options.runtime.upstream_input_index_map

    result =
      if native_rate_limit_relay?(response, request_options) do
        native_rate_limit_result(response, headers)
      else
        failure_result(
          response.status,
          headers,
          body,
          request_options,
          payload,
          error_code,
          Keyword.put(opts, :validation_rejection, ValidationRejection.for_client(validation_rejection, index_map)),
          response |> Metadata.rejection_error() |> ValidationRejection.for_client(index_map)
        )
      end

    case result do
      {:error, error} -> {:error, error}
      result -> {:ok, result}
    end
  end

  # A provider usage-limit `429` on the last eligible candidate whose reset
  # the provider named answers the Pooler's terminal usage-limit refusal on
  # every HTTP surface, as routing does once every candidate is exhausted
  # (findings#206 rows 206-508, 206-531). The attempt and the request row
  # above keep the provider's `429` and `upstream_rate_limited`. The native
  # compaction bridges keep their own result shapes.
  defp relayed_usage_limit(%Req.Response{status: 429} = response, %SelectedCandidateContext{request_options: request_options} = context) do
    if native_compaction_websocket?(request_options) or CompactionTrigger.streaming_result?(request_options),
      do: :unknown,
      else: ProviderUsageLimit.error(response, fn -> other_candidates_return(context) end)
  end

  defp relayed_usage_limit(_response, _context), do: :unknown

  defp relayed_usage_limit_metadata({:ok, usage_limit_error}) do
    case Contracts.usage_limit_record(usage_limit_error) do
      record when map_size(record) == 2 -> %{"usage_limit" => record}
      _none -> %{}
    end
  end

  defp relayed_usage_limit_metadata(:unknown), do: %{}

  # The Pool's other candidates, as route filtering classified them (findings#206 row 206-545).
  defp other_candidates_return(%SelectedCandidateContext{model: model, route_state: route_state, assignment: assignment}),
    do: PoolReturn.others(model, RouteState.route_filter_candidates(route_state), assignment.id, DateTime.utc_now())

  defp apply_failure_settlement_options(attrs, opts) do
    attrs =
      case Keyword.fetch(opts, :attempt_status) do
        {:ok, attempt_status} -> Map.put(attrs, :attempt_status, attempt_status)
        :error -> attrs
      end

    case Keyword.fetch(opts, :before_finalize) do
      {:ok, callback} -> SettlementAttrs.chain_before_finalize(attrs, callback)
      :error -> attrs
    end
  end

  defp failure_result(
         status,
         headers,
         body,
         request_options,
         payload,
         error_code,
         opts,
         rejection_error
       ) do
    marker = public_input_file_upstream_404?(status, request_options, payload)

    cond do
      native_compaction_websocket?(request_options) ->
        {:error, native_compaction_rejection(status, error_code, rejection_error)}

      CompactionTrigger.streaming_result?(request_options) ->
        full_failure_result(
          status,
          headers,
          relayable_rejection_error(status, rejection_error),
          Keyword.get(opts, :validation_rejection),
          marker
        )

      true ->
        project_failure_result(
          status,
          headers,
          body,
          request_options,
          error_code,
          opts,
          marker,
          relayable_rejection_error(status, rejection_error)
        )
    end
  end

  defp project_failure_result(
         status,
         headers,
         body,
         request_options,
         error_code,
         opts,
         marker,
         relayable_rejection_error
       ) do
    validation_rejection = Keyword.get(opts, :validation_rejection)

    projection = failure_projection(Keyword.get(opts, :failure_projection, :mode_scoped), status, request_options)

    case {projection, Metadata.explicit_full_ordinary_responses?(request_options)} do
      {:native_final_refusal, _explicit_full?} ->
        native_refusal_result(status, headers, relayable_rejection_error)

      {{:misalignment_policy_violation, summary}, _explicit_full?} ->
        error =
          %{"code" => summary.code, "message" => summary.message}
          |> maybe_put_misalignment(summary)

        %{
          status: status,
          headers: json_content_type(headers),
          raw_body: CodexPooler.JSON.encode!(%{"error" => error})
        }

      {:canonical_full, _explicit_full?} ->
        %{
          status: status,
          headers: json_content_type(headers),
          body: canonical_failure_body(request_options)
        }

      {:mode_scoped, true} ->
        full_failure_result(
          status,
          headers,
          relayable_rejection_error,
          validation_rejection,
          marker
        )

      {:mode_scoped, false} when is_map(validation_rejection) ->
        validation_rejection_result(status, headers, validation_rejection)

      {:mode_scoped, false} when status == 400 ->
        if native_ordinary_responses_route?(request_options),
          do: native_refusal_result(status, headers, relayable_rejection_error),
          else: passthrough_failure_result(status, headers, body, request_options, error_code, marker)

      {_projection, _explicit_full?} ->
        passthrough_failure_result(status, headers, body, request_options, error_code, marker)
    end
  end

  defp failure_projection(:mode_scoped, status, request_options) do
    if native_final_refusal?(status, request_options), do: :native_final_refusal, else: :mode_scoped
  end

  defp failure_projection(projection, _status, _request_options), do: projection

  defp passthrough_failure_result(status, headers, body, request_options, error_code, marker) do
    %{
      status: status,
      headers: headers,
      raw_body: body,
      public_stream_startup_error_code: stream_startup_error_code(error_code, request_options),
      public_input_file_upstream_404?: marker
    }
  end

  # A native 400 refusal outside the relayable validation set (the provider's
  # codeless refusal, an unknown code, a `{"detail": ...}` body) answers the
  # Pooler-authored error the native websocket sends for the same refusal,
  # built from the sanitized tokens only (`ValidationRejection.refusal_error/2`;
  # the param was already mapped through the turn's input index map). A
  # streaming request used to get the 400 with an empty body, because the
  # drain leaves no public body, and the released Codex client then showed an
  # empty error; a non-streaming one relayed the provider body verbatim
  # (findings#254 row 254-70). Public `/v1` surfaces keep their own redacted
  # projection.
  #
  # A native refusal with another final 4xx (404, 409, 413, 422, a 403 that
  # demotes nothing, ...) answers the same error as a 400 whose message names
  # the provider status, whatever the serving mode, as the native websocket
  # does since row 254-71: the released Codex client retries every HTTP status
  # but 400 as an unexpected status, and the Pooler admitted each retry as a
  # new request that reached the provider again, six provider requests per
  # turn on the released-client lane (row 254-80). The attempt, the request
  # row and route health keep the provider status.
  defp native_refusal_result(status, headers, relayable_rejection_error) do
    %{
      status: 400,
      headers: json_content_type(headers),
      raw_body: CodexPooler.JSON.encode!(%{"error" => ValidationRejection.refusal_error(relayable_rejection_error, index_map: :identity, upstream_status: status)})
    }
  end

  # Every 403 reaching this point completes the route neutrally (a credential
  # 403 is taken by the HTTP auth refresh before it and answered as its
  # retryable 503), so a client retry would only reach the same account again.
  defp native_final_refusal?(status, request_options) do
    status != 400 and ValidationRejection.final_refusal_status?(status) and native_ordinary_responses_route?(request_options)
  end

  defp native_ordinary_responses_route?(%RequestOptions{openai_compatibility: %{source_endpoint: nil}} = request_options),
    do: Metadata.ordinary_responses_route?(request_options)

  defp native_ordinary_responses_route?(%RequestOptions{}), do: false

  # The relayed validation error is the native JSON error envelope whether the
  # native request streamed (the drain leaves no public body) or not. A
  # materialized body used to pass through verbatim: the provider message,
  # which quotes submitted and Pooler-rewritten values, and the provider's
  # `input[N]`, a position the client never sent under Lite (findings#254 row
  # 254-54). Public /v1 surfaces project the marker instead.
  defp validation_rejection_result(status, headers, validation_rejection) do
    %{
      status: status,
      headers: json_content_type(headers),
      raw_body: CodexPooler.JSON.encode!(%{"error" => ValidationRejection.error(validation_rejection)}),
      public_validation_rejection: validation_rejection
    }
  end

  defp unanswered_failure_result(response, context, body, error_code, validation_rejection, opts) do
    if public_rate_limit_relay?(response, context.request_options),
      do: {:error, public_rate_limit_error(context)},
      else: relayed_failure_result(response, context, body, error_code, validation_rejection, opts)
  end

  # A `/v1` Responses or Chat `429` the terminal usage limit did not answer is
  # the redacted `rate_limit_error` in Full and Lite alike (Full used to answer
  # the canonical `server_error`), with `Retry-After` when a sibling taken out
  # by an open circuit bounds the wait; the same over HTTP and over the
  # upstream websocket bridge (findings#206 rows 206-531, 206-593).
  defp public_rate_limit_relay?(%Req.Response{status: 429}, %RequestOptions{openai_compatibility: compatibility} = request_options),
    do: OpenAICompatibility.translated_responses_surface?(compatibility) and not CompactionTrigger.streaming_result?(request_options)

  defp public_rate_limit_relay?(_response, _request_options), do: false

  defp public_rate_limit_error(%SelectedCandidateContext{} = context) do
    others =
      context.route_state
      |> RouteState.route_filter_candidates()
      |> Enum.reject(fn {assignment, _identity} -> assignment.id == context.assignment.id end)

    error = %{status: 429, code: "upstream_rate_limited", message: "upstream request failed", param: nil}

    case CircuitRetryAfter.current_seconds(context.auth, context.model, others, context.route_class) do
      seconds when is_integer(seconds) -> Map.put(error, :circuit_retry_after_seconds, seconds)
      nil -> error
    end
  end

  # A native `429` the terminal usage limit did not answer keeps the tokens
  # the released client classifies it by, in Full and Lite, streaming or not
  # (findings#206 row 206-589; `NativeRateLimitRelay`). The compaction
  # bridges keep their own result shapes.
  defp native_rate_limit_relay?(%Req.Response{status: 429}, request_options) do
    native_ordinary_responses_route?(request_options) and not native_compaction_websocket?(request_options) and
      not CompactionTrigger.streaming_result?(request_options)
  end

  defp native_rate_limit_relay?(_response, _request_options), do: false

  # A relayed reset carries the house retry advice, `Retry-After` plus
  # `x-should-retry: false` above a minute, as the Pooler's own usage-limit
  # answer does (findings#206 row 206-597).
  defp native_rate_limit_result(response, headers) do
    error = NativeRateLimitRelay.error(response)

    %{
      status: 429,
      headers: headers |> json_content_type() |> put_retry_advice(NativeRateLimitRelay.retry_after_seconds(error)),
      raw_body: CodexPooler.JSON.encode!(%{"error" => error})
    }
  end

  defp put_retry_advice(headers, nil), do: headers

  # The provider's own `Retry-After` never reaches this point
  # (`Metadata.response_headers/3` drops it), so the advice is appended.
  defp put_retry_advice(headers, seconds),
    do: headers ++ Contracts.usage_limit_response_headers(%{status: 429, usage_limit: %{resets_in_seconds: seconds}})

  defp json_content_type(headers) do
    headers
    |> Enum.reject(fn {name, _value} -> String.downcase(to_string(name)) == "content-type" end)
    |> then(&[{"content-type", "application/json"} | &1])
  end

  # A non-429 4xx rejection already has its sanitized `type`, `code`, and
  # `param` persisted as attempt metadata and projected into request logs, so
  # relaying those bounded tokens to the client discloses nothing new. Keeping
  # them back is actively wrong: the canonical body says `server_error`, which
  # is in the retryable vocabulary, so an SDK retries a terminal
  # `invalid_request_error` forever while Pooler has already settled the
  # request as failed. Only the tokens travel. The provider message and
  # body stay unpersisted and unrelayed, and the message stays server-owned.
  #
  # The relay window is exactly `Metadata.rejection_metadata_status?/1`. A 429
  # and a 5xx persist no rejection metadata, so there is nothing sanitized to
  # relay and their bodies stay byte-identical.
  defp relayable_rejection_error(status, rejection_error) do
    if Metadata.rejection_metadata_status?(status), do: rejection_error, else: %{}
  end

  # A Full body is rendered once here for the native route and carried as a
  # structured `public_full_rejection` for the public `/v1` sender, which
  # re-renders `param` and `message` from the same constructor through the
  # caller-facing parameter mapper (codex-pooler-findings#219). Rendering the
  # message from the provider param and mapping only `param` afterwards left a
  # Chat client reading `"param": "reasoning_effort"` next to a message naming
  # `reasoning.effort`. The structured rejection is a projection input only;
  # the persisted attempt metadata keeps the provider parameter evidence.
  defp full_failure_result(
         status,
         headers,
         %{type: type} = rejection_error,
         validation_rejection,
         marker
       )
       when is_binary(type) do
    rejection = full_rejection(rejection_error, validation_rejection)

    # The relayed body is rebuilt as JSON whatever the request's transport, so
    # a streaming request whose upstream 400 carried no content-type must not
    # inherit `text/event-stream` (findings#219).
    %{
      status: status,
      headers: json_content_type(headers),
      body: full_failure_body(type, rejection),
      public_full_rejection: rejection,
      public_input_file_upstream_404?: marker
    }
  end

  defp full_failure_result(status, headers, _rejection_error, _validation_rejection, marker) do
    %{
      status: status,
      headers: json_content_type(headers),
      body: @canonical_full_failure_body,
      public_input_file_upstream_404?: marker
    }
  end

  # `param` is set unconditionally: a rejection carrying a type but no param
  # emits an explicit `"param": null`, which is what the provider's own error
  # bodies do and what an OpenAI SDK expects to read.
  defp full_rejection(rejection_error, validation_rejection) do
    %{
      code: ValidationRejection.relayed_code(rejection_error),
      param: Map.get(rejection_error, :param),
      supported_values: relayed_supported_values(validation_rejection),
      supported_values_state: nil
    }
  end

  defp full_failure_body(type, %{code: code, param: param} = rejection) do
    %{
      "error" => %{
        "type" => type,
        "code" => code,
        "param" => param,
        "message" => full_failure_message(rejection)
      }
    }
  end

  # Present only when `ValidationRejection.fetch/2` admitted this rejection, so
  # a 401, a 404, a compact route, an unrecognized code, and every rejection
  # whose message stated no parseable list all relay the base sentence
  # unchanged. Those dominate the observed Full rejection population.
  defp relayed_supported_values(%{supported_values: [_value | _rest] = values}), do: values
  defp relayed_supported_values(_validation_rejection), do: nil

  # Serving mode must not decide how much a client is told. The non-Full
  # mode-scoped branch already names the refused parameter, while Full used to
  # answer the same provider rejection with the canonical
  # `upstream request failed` (codex-pooler-findings#173), so a
  # client that moved between Pools saw its diagnostics change for reasons
  # unrelated to its request — and the advanced override gave the *less*
  # informative answer.
  #
  # Both paths now build the sentence with one constructor,
  # `ValidationRejection.error/1`, from the code and param this body already
  # carries as separate fields. Nothing new is disclosed: both tokens are
  # sanitized, persisted as attempt metadata, and already relayed above.
  #
  # The supported-values suffix used to be withheld here
  # (codex-pooler-findings#173) because it was read from the live provider body
  # rather than from a persisted field, and #161 left provider prose unrelayed.
  # It is now parsed once by the same bounded parser, persisted as attempt
  # metadata next to the code and param, and rendered from that one classified
  # fact (codex-pooler-findings#177) — so the mode that does *not* rewrite the
  # client's request stops telling the client less about it. Only the bounded
  # enumeration travels; the surrounding message stays unrelayed and
  # unpersisted on every path.
  # `supported_values_state` is part of `ValidationRejection.rejection()` and is
  # carried here even though rendering never reads it: the type is what keeps
  # the four outcomes distinguishable at rest, and a caller that omits the key
  # is a caller that has not decided which of them it is looking at.
  defp full_failure_message(rejection) do
    rejection
    |> ValidationRejection.error()
    |> Map.fetch!("message")
  end

  defp canonical_failure_body(%RequestOptions{
         payload_context: %{native_image_request?: true},
         openai_compatibility: %{source_endpoint: endpoint}
       })
       when endpoint in ["/v1/images/generations", "/v1/images/edits"] do
    put_in(@canonical_full_failure_body, ["error", "code"], "upstream_status")
  end

  defp canonical_failure_body(_request_options), do: @canonical_full_failure_body

  defp maybe_put_misalignment(error, %{misalignment: misalignment}),
    do: Map.put(error, "misalignment", misalignment)

  defp maybe_put_misalignment(error, _summary), do: error

  defp native_compaction_websocket?(%RequestOptions{
         payload_context: %{
           compaction_trigger_bridge?: true,
           compaction_result_mode: :native_websocket
         }
       }),
       do: true

  defp native_compaction_websocket?(%RequestOptions{}), do: false

  defp native_compaction_rejection(status, fallback_code, rejection_error) do
    code = Map.get(rejection_error, :code) || fallback_code

    %{
      status: status,
      code: code,
      message: "upstream rejected the compact request",
      param: Map.get(rejection_error, :param)
    }
  end

  defp public_input_file_upstream_404?(404, %RequestOptions{} = request_options, payload)
       when is_map(payload) do
    request_options.openai_compatibility.source_endpoint == "/v1/responses" and
      RequestOptions.OpenAICompatibility.translated_responses_surface?(request_options.openai_compatibility) and contains_input_file?(payload)
  end

  defp public_input_file_upstream_404?(_status, _request_options, _payload), do: false

  defp contains_input_file?(%{"type" => "input_file"}), do: true

  defp contains_input_file?(%{} = value),
    do: Enum.any?(value, fn {_key, item} -> contains_input_file?(item) end)

  defp contains_input_file?(values) when is_list(values),
    do: Enum.any?(values, &contains_input_file?/1)

  defp contains_input_file?(_value), do: false

  defp stream_startup_error_code(error_code, %RequestOptions{
         transport: %{transport: "http_sse"},
         openai_compatibility: %{public_openai_responses_stream: true}
       }),
       do: error_code

  defp stream_startup_error_code(_error_code, %RequestOptions{}), do: nil

  defp finalize_response_body_limit_exceeded(response, %SelectedCandidateContext{} = context) do
    %{reserved: reserved, attempt: attempt, request_options: request_options} = context

    code = "upstream_response_too_large"
    message = "upstream response body exceeded maximum allowed size"
    latency = elapsed_ms(context.started)

    case AttemptSettlement.finalize_failure(
           reserved.request,
           attempt,
           SettlementAttrs.failure(
             context,
             502,
             code,
             message,
             Metadata.response_metadata(response, code, request_options),
             latency_ms: latency,
             before_finalize: fn ->
               SideEffects.observe_http_response(
                 context,
                 response,
                 Metadata.response_body(response)
               )

               record_dispatch_route_failure(code, context)
             end
           ),
           request_options.runtime.session_owner_witness
         ) do
      {:stale_generation, finalized} -> {:ok, finalized}
      {:ok, _finalized} -> {:error, error(502, code, message)}
      {:error, gateway_error} -> {:error, gateway_error}
    end
  end

  defp invalid_transcription_response?(
         %SelectedCandidateContext{endpoint: "/backend-api/transcribe"},
         body
       ) do
    case CodexPooler.JSON.decode(body) do
      {:ok, %{"text" => text} = decoded} when is_binary(text) -> not is_nil(decoded["error"])
      _invalid -> true
    end
  end

  defp invalid_transcription_response?(%SelectedCandidateContext{}, _body), do: false

  defp finalize_invalid_json_response(
         response,
         %SelectedCandidateContext{} = context,
         code \\ "invalid_upstream_response",
         message \\ "upstream response was not valid json",
         attrs \\ []
       ) do
    %{reserved: reserved, attempt: attempt, request_options: request_options} = context

    latency = elapsed_ms(context.started)

    case AttemptSettlement.finalize_failure(
           reserved.request,
           attempt,
           SettlementAttrs.failure(
             context,
             502,
             code,
             message,
             Metadata.response_metadata(response, code, request_options),
             latency_ms: latency,
             before_finalize: fn ->
               SideEffects.observe_http_response(
                 context,
                 response,
                 Metadata.response_body(response)
               )
             end
           )
           |> Map.merge(Map.new(attrs)),
           request_options.runtime.session_owner_witness
         ) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

      {:ok, _finalized} ->
        {:error, error(502, code, message)}

      {:error, gateway_error} ->
        {:error, gateway_error}
    end
  end

  defp validate_public_compaction_response(
         response,
         %SelectedCandidateContext{
           request_options: %RequestOptions{
             payload_context: %{compaction_trigger_bridge?: true},
             openai_compatibility: %{source_endpoint: "/v1/responses"}
           }
         } = context,
         body
       ) do
    result =
      {:ok,
       %{
         status: response.status,
         headers: Metadata.response_headers(response, false, context.request_options),
         raw_body: body
       }}

    case CompactionTrigger.adapt_gateway_result(result, :response) do
      {:ok, _adapted} -> :ok
      {:error, error} -> finalize_invalid_public_compaction(response, context, error)
    end
  end

  defp validate_public_compaction_response(_response, %SelectedCandidateContext{}, _body), do: :ok

  defp native_compaction_result?(%SelectedCandidateContext{
         request_options: %RequestOptions{
           payload_context: %{
             compaction_trigger_bridge?: true,
             compaction_result_transport: :buffered,
             compaction_result_mode: :native_websocket
           }
         }
       }),
       do: true

  defp native_compaction_result?(%SelectedCandidateContext{}), do: false

  defp finalize_native_compaction_response(response, context, body, callbacks) do
    result =
      {:ok,
       %{
         status: response.status,
         headers: Metadata.response_headers(response, false, context.request_options),
         raw_body: body
       }}

    case CompactionTrigger.adapt_gateway_result(result, :native_websocket) do
      {:ok, _adapted} -> finalize_successful_json_response(response, context, body, callbacks)
      {:error, error} -> finalize_invalid_compaction(response, context, error)
    end
  end

  defp finalize_json_response(response, context, body, callbacks) do
    cond do
      invalid_public_native_image?(context, body) ->
        finalize_invalid_json_response(
          response,
          context,
          "image_generation_failed",
          "upstream image response was invalid",
          upstream_status_code: response.status,
          usage: ResponseUsage.from_json(body),
          before_finalize: fn ->
            SideEffects.observe_http_response(context, response, body)
            DispatchLifecycle.neutral_completion(context)
          end
        )

      invalid_transcription_response?(context, body) ->
        finalize_invalid_json_response(
          response,
          context,
          "invalid_transcription_response",
          "upstream transcription response was invalid",
          upstream_status_code: response.status,
          before_finalize: fn ->
            SideEffects.observe_http_response(context, response, body)
            DispatchLifecycle.neutral_completion(context)
          end
        )

      Metadata.json_content?(response) and not StreamProtocol.valid_json?(body) ->
        finalize_invalid_json_response(response, context)

      true ->
        with :ok <- validate_public_compaction_response(response, context, body) do
          finalize_successful_json_response(response, context, body, callbacks)
        end
    end
  end

  defp invalid_public_native_image?(
         %SelectedCandidateContext{
           request_options: %RequestOptions{
             payload_context: %{native_image_request?: true},
             openai_compatibility: %{source_endpoint: endpoint}
           }
         },
         body
       )
       when endpoint in ["/v1/images/generations", "/v1/images/edits"],
       do: not NativeImageResult.valid?(body)

  defp invalid_public_native_image?(_context, _body), do: false

  defp finalize_invalid_public_compaction(response, context, error) do
    finalize_invalid_compaction(response, context, error, public_compaction_error?: true)
  end

  defp finalize_invalid_compaction(response, context, error, opts \\ []) do
    %{reserved: reserved, attempt: attempt, request_options: request_options} = context

    response_metadata =
      Metadata.response_metadata(response, error.code, request_options)
      |> maybe_put_compaction_invalid_reason(error)

    attrs =
      SettlementAttrs.failure(
        context,
        error.status,
        error.code,
        error.message,
        response_metadata,
        latency_ms: elapsed_ms(context.started),
        before_finalize: fn ->
          SideEffects.observe_http_response(context, response, Metadata.response_body(response))
        end
      )

    case AttemptSettlement.finalize_failure(
           reserved.request,
           attempt,
           attrs,
           request_options.runtime.session_owner_witness
         ) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

      {:ok, _finalized} ->
        if Keyword.get(opts, :public_compaction_error?, false) do
          {:error, Map.put(error, :public_compaction_error?, true)}
        else
          {:error, error}
        end

      {:error, gateway_error} ->
        {:error, gateway_error}
    end
  end

  defp maybe_put_compaction_invalid_reason(metadata, %{compaction_invalid_reason: reason})
       when is_binary(reason), do: Map.put(metadata, "compaction_invalid_reason", reason)

  defp maybe_put_compaction_invalid_reason(metadata, _error), do: metadata

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
             latency_ms: latency,
             before_finalize: fn ->
               SideEffects.observe_http_response(context, response, body)
               SideEffects.before_finalize_success(context, request_options)
             end
           ),
           request_options.runtime.session_owner_witness
         ) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

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

  defp observe_http_response(attrs, context, response, body) do
    SettlementAttrs.chain_before_finalize(attrs, fn ->
      SideEffects.observe_http_response(context, response, body)
    end)
  end

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
