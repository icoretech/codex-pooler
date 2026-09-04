defmodule CodexPooler.Gateway.Runtime.Finalization do
  @moduledoc """
  Finalizes gateway runtime dispatch attempts after upstream transport returns.
  """

  alias CodexPooler.Gateway.Payloads.{CompactionTrigger, RequestOptions}
  alias CodexPooler.Gateway.Runtime.Dispatch.ResponseContext
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
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
  alias CodexPooler.Gateway.Transports.{MisalignmentPolicyViolation, ModelUnavailability}
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

        Metadata.json_content?(response) and not StreamProtocol.valid_json?(body) ->
          finalize_invalid_json_response(response, context)

        true ->
          finalize_valid_json_response(response, context, body, callbacks)
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
        finalize_upstream_status_failure(response, context, body,
          failure_projection: :canonical_full
        )

      assignment_model_unavailable?(status, body, context) ->
        finalize_assignment_model_unavailable(response, context, body)

      true ->
        finalize_upstream_status_failure(response, context, body,
          before_finalize: fn -> maybe_record_unauthorized_route_failure(status, context) end
        )
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
    case Jason.decode(body) do
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
               ),
             before_finalize: fn ->
               SideEffects.observe_http_response(context, response, body)
               record_status_route_failure(context, status)
             end
           }) do
        {:stale_generation, finalized} -> {:ok, finalized}
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

    if allow_retry? and not compact_endpoint?(endpoint) do
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
             )
           ) do
        {:stale_generation, finalized} ->
          {:ok, finalized}

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
         opts
       ) do
    %{
      reserved: reserved,
      attempt: attempt,
      payload: payload,
      request_options: request_options
    } = context

    status = response.status

    error_code =
      Keyword.get_lazy(opts, :error_code, fn ->
        Metadata.upstream_status_error_code(status, request_options)
      end)

    accounting_message = Keyword.get(opts, :accounting_message, "upstream returned #{status}")

    attrs =
      SettlementAttrs.failure(
        context,
        status,
        error_code,
        accounting_message,
        Metadata.response_metadata(response, error_code, request_options),
        latency_ms: elapsed_ms(context.started),
        usage: %{status: "usage_unknown", source: "upstream_status"}
      )

    attrs =
      attrs
      |> apply_failure_settlement_options(opts)
      |> observe_http_response(context, response, body)

    case AttemptSettlement.finalize_failure(reserved.request, attempt, attrs) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

      {:ok, _finalized} ->
        headers =
          Metadata.response_headers(response, RouteClass.streaming?(payload), request_options)

        result =
          failure_result(
            status,
            headers,
            body,
            request_options,
            payload,
            error_code,
            opts,
            Metadata.rejection_error(response)
          )

        case result do
          {:error, error} -> {:error, error}
          result -> {:ok, result}
        end

      {:error, gateway_error} ->
        {:error, gateway_error}
    end
  end

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

    if native_compaction_websocket?(request_options) do
      {:error, native_compaction_rejection(status, error_code, rejection_error)}
    else
      project_failure_result(
        status,
        headers,
        body,
        request_options,
        error_code,
        opts,
        marker
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
         marker
       ) do
    case {Keyword.get(opts, :failure_projection, :mode_scoped),
          Metadata.explicit_full_ordinary_responses?(request_options)} do
      {{:misalignment_policy_violation, summary}, _explicit_full?} ->
        error =
          %{"code" => summary.code, "message" => summary.message}
          |> maybe_put_misalignment(summary)

        %{
          status: status,
          headers: headers,
          raw_body: Jason.encode!(%{"error" => error})
        }

      {:canonical_full, _explicit_full?} ->
        %{status: status, headers: headers, body: @canonical_full_failure_body}

      {:mode_scoped, true} ->
        %{
          status: status,
          headers: headers,
          body: @canonical_full_failure_body,
          public_input_file_upstream_404?: marker
        }

      {_projection, _explicit_full?} ->
        %{
          status: status,
          headers: headers,
          raw_body: body,
          public_stream_startup_error_code:
            stream_startup_error_code(error_code, request_options),
          public_input_file_upstream_404?: marker
        }
    end
  end

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
      RequestOptions.OpenAICompatibility.translated_responses_surface?(
        request_options.openai_compatibility
      ) and contains_input_file?(payload)
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
           )
         ) do
      {:stale_generation, finalized} -> {:ok, finalized}
      {:ok, _finalized} -> {:error, error(502, code, message)}
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
             latency_ms: latency,
             before_finalize: fn ->
               SideEffects.observe_http_response(
                 context,
                 response,
                 Metadata.response_body(response)
               )
             end
           )
         ) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

      {:ok, _finalized} ->
        {:error, error(502, "invalid_upstream_response", "upstream response was not valid json")}

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

  defp finalize_valid_json_response(response, context, body, callbacks) do
    with :ok <- validate_public_compaction_response(response, context, body) do
      finalize_successful_json_response(response, context, body, callbacks)
    end
  end

  defp finalize_invalid_public_compaction(response, context, error) do
    finalize_invalid_compaction(response, context, error, public_compaction_error?: true)
  end

  defp finalize_invalid_compaction(response, context, error, opts \\ []) do
    %{reserved: reserved, attempt: attempt, request_options: request_options} = context

    attrs =
      SettlementAttrs.failure(
        context,
        error.status,
        error.code,
        error.message,
        Metadata.response_metadata(response, error.code, request_options),
        latency_ms: elapsed_ms(context.started),
        before_finalize: fn ->
          SideEffects.observe_http_response(context, response, Metadata.response_body(response))
        end
      )

    case AttemptSettlement.finalize_failure(reserved.request, attempt, attrs) do
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
           )
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
