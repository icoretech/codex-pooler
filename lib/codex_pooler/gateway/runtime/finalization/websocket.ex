defmodule CodexPooler.Gateway.Runtime.Finalization.Websocket do
  @moduledoc false

  require Logger

  alias CodexPooler.Accounting.ClientRetry
  alias CodexPooler.Accounting.NativeContentFilterRetry
  alias CodexPooler.Gateway.Payloads.{CompactionTrigger, NativeCodexTurnMetadata, RequestOptions}
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.Finalization.ExpiredOwnerGenerationCleanup
  alias CodexPooler.Gateway.Runtime.Routing.DispatchLifecycle
  alias CodexPooler.Gateway.Runtime.Streaming.CompactionResultCollector

  alias CodexPooler.Gateway.Runtime.Finalization.{
    AttemptSettlement,
    InterruptionOutcome,
    Metadata,
    ResponseUsage,
    SettlementAttrs,
    SideEffects,
    Streaming,
    ValidationRejection
  }

  alias CodexPooler.Gateway.Transports.MisalignmentPolicyViolation
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Gateway.Transports.Websocket.OrdinarySuccessResult

  alias CodexPooler.Gateway.Transports.Websocket.{
    DiagnosticTaxonomy,
    NativeCompactionAdmission,
    UpstreamWebsocketSession,
    WebsocketOwnerAdmissionControlV1,
    WebsocketOwnerContract,
    WebsocketOwnerForwarder
  }

  @spec finalize_completed(SelectedCandidateContext.t(), map()) :: {:ok, map()} | {:error, map()}
  def finalize_completed(context, finalization) do
    case prepare_completed_finalization(context, finalization) do
      {:ok, finalization} ->
        finalize_completed_success(context, finalization)

      {:provider_failure, failure} ->
        finalize_collected_provider_failure(context, finalization, failure)

      {:error, error} ->
        finalize_invalid_compaction(context, finalization, error)
    end
  end

  defp prepare_completed_finalization(
         %SelectedCandidateContext{
           request_options:
             %RequestOptions{
               payload_context: %{compaction_result_mode: mode}
             } = request_options
         },
         %{body: body} = finalization
       )
       when mode in [:native_websocket, :public_websocket] do
    if RequestOptions.connection_bound_compaction?(request_options) do
      item_mode = if mode == :public_websocket, do: :public, else: :native

      case CompactionResultCollector.collect_websocket_body(body, item_mode, terminal_source(finalization)) do
        {:ok,
         %{
           status: status,
           headers: headers,
           raw_body: canonical_body,
           compaction_item: compaction_item
         }} ->
          {:ok,
           finalization
           |> Map.put(:body, canonical_body)
           |> Map.put(:status, status)
           |> Map.put(:result_headers, headers)
           |> Map.put(:normalized_compaction_item, compaction_item)}

        {:provider_failure, failure} ->
          {:provider_failure, failure}

        {:error, error} ->
          {:error, error}
      end
    else
      validate_public_compaction_response(request_options, finalization)
    end
  end

  defp prepare_completed_finalization(
         %SelectedCandidateContext{request_options: request_options},
         finalization
       ) do
    validate_public_compaction_response(request_options, finalization)
  end

  defp finalize_completed_success(context, finalization) do
    context = %{context | provider_credits_admission: Map.get(finalization, :provider_credits_admission)}

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
    } = context

    usage = response_usage(finalization, body)
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
             )
             |> NativeContentFilterRetry.observation_metadata(finalization)
             |> NativeContentFilterRetry.terminal_metadata(StreamProtocol.terminal_outcome(body), context),
             started: started,
             before_finalize: fn ->
               SideEffects.observe_websocket_response(context, finalization)
               SideEffects.before_finalize_success(context, request_options)
             end
           ),
           request_options.runtime.session_owner_witness
         ) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

      {:ok, _finalized} = result ->
        Streaming.emit_stream_finalization(
          usage,
          transports.downstream_transport,
          transports.upstream_transport
        )

        emit_settlement_outcome(result, "succeeded", transports)
        request_options = request_options_with_response_id(request_options, finalization)
        SideEffects.record_success(context, payload, body, request_options, callbacks)

        with :ok <- acknowledge_native_completed_success(context, request_options, finalization) do
          completed_result(request_options, body, finalization)
        end

      {:error, gateway_error} = error ->
        emit_settlement_failure(error, transports)
        {:error, gateway_error}
    end
  end

  @spec finalize_collected_provider_failure(
          SelectedCandidateContext.t(),
          map(),
          StreamProtocol.terminal_failure()
        ) :: {:ok, map()} | {:error, map()}
  defp finalize_collected_provider_failure(context, finalization, failure) do
    finalization =
      finalization
      |> Map.put(:terminal, failure.event_type || failure.data_type)
      |> Map.put(:status, collected_provider_failure_status(failure))
      |> Map.put(:upstream_error_code, failure.upstream_code)
      |> Map.put(:upstream_error_param, failure.upstream_error_param)
      |> Map.put(:collected_provider_failure, failure)

    finalization =
      cond do
        anchor_refusal?(context.request_options, finalization, failure) ->
          Map.put(finalization, :collected_provider_failure_event, previous_response_retry_event())

        native_full_history_compaction?(context.request_options) or
            (native_collected_compaction?(context.request_options) and finalization.status == 502) ->
          Map.put(
            finalization,
            :collected_provider_failure_event,
            CompactionResultCollector.provider_failure_websocket_event(failure)
          )

        true ->
          finalization
      end

    finalize_terminal_failure(context, finalization)
  end

  # The compaction's anchor was refused before any execution. The client gets
  # the event an ordinary continuation gets for the same refusal,
  # `previous_response_not_found`, which the released client retries as a full
  # request without the anchor; the collected-compaction answer to any other
  # provider refusal, a 400 its client reads as a fatal invalid request, stays.
  # Two refusals are proven to precede any execution:
  # - the connection-bound guard's, before anything went upstream, after the
  #   connection that produced the anchor closed (findings#278); only the
  #   guard's exact metadata proves it (`continuation_guard_metadata/2`);
  # - the provider's own (findings#270 row 270-238): the Codex backend's
  #   codeless wrapped `error` event, status 400 `invalid_request_error`, with
  #   the fixed `Invalid previous_response_id` message class, sent instead of a
  #   response (no `response.created`; a `response.failed` with the same code
  #   follows a created response and stays fatal), and checked before the
  #   model (findings#232 rows 232-277 and 232-279).
  # The resend policies admit the retry of both (`ClientRetry.compaction_resend_shape/3`).
  defp anchor_refusal?(request_options, finalization, failure) do
    native_collected_compaction?(request_options) and
      (map_size(continuation_guard_metadata(failure.upstream_code, Map.get(finalization, :transport_failure))) > 0 or
         provider_anchor_refusal?(request_options, finalization, failure))
  end

  defp provider_anchor_refusal?(request_options, %{body: body}, %{upstream_code: "previous_response_not_found", event_type: "error"}) when is_binary(body) do
    match?(
      %{"rejection_upstream_status" => 400, "rejection_error_type" => "invalid_request_error", "rejection_message_class" => "invalid_previous_response_id"},
      provider_rejection_metadata(body, request_options)
    )
  end

  defp provider_anchor_refusal?(_request_options, _finalization, _failure), do: false

  # The guard's refusal passes through the collector as if the provider had
  # sent it, so its terminal decision line names the guard instead
  # (findings#270 row 270-238).
  defp terminal_source(finalization) do
    if map_size(TransportFailureReason.sanitize_continuation_generation_guard_metadata(Map.get(finalization, :transport_failure))) > 0,
      do: :continuation_guard,
      else: :provider_terminal
  end

  defp previous_response_retry_event do
    ~s({"type":"error","error":{"code":"previous_response_not_found"}})
    |> StreamProtocol.canonicalize_native_codex_responses_json_message()
    |> CodexPooler.JSON.decode!()
  end

  defp validate_public_compaction_response(
         %RequestOptions{
           payload_context: %{compaction_trigger_bridge?: true},
           openai_compatibility: %{source_endpoint: "/v1/responses"}
         },
         %{body: body, status: status, headers: headers} = finalization
       ) do
    result = {:ok, %{status: status, headers: headers, raw_body: body}}

    case CompactionTrigger.adapt_gateway_result(result, :websocket) do
      {:ok, _adapted} -> {:ok, finalization}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_public_compaction_response(%RequestOptions{}, finalization),
    do: {:ok, finalization}

  defp finalize_invalid_compaction(context, finalization, error) do
    %{reserved: reserved, attempt: attempt, request_options: request_options} = context
    transports = resolved_transports(context)

    attrs =
      SettlementAttrs.failure(
        context,
        error.status,
        error.code,
        error.message,
        Metadata.websocket_response_metadata(
          finalization.headers,
          error.code,
          request_options,
          Map.get(finalization, :websocket_frame_headers, %{}),
          Map.get(finalization, :upstream_websocket_connection)
        )
        |> collected_compaction_diagnostics(finalization)
        |> maybe_put_compaction_invalid_reason(error),
        started: finalization.started,
        before_finalize: fn ->
          SideEffects.observe_websocket_response(context, finalization)

          if native_full_history_compaction?(request_options) do
            Streaming.record_health_failure(error.code, error.code, context)
          else
            :ok
          end
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

      {:ok, _finalized} = result ->
        emit_settlement_outcome(result, "failed", transports)
        {:error, maybe_mark_public_compaction_error(error, request_options)}

      {:error, gateway_error} = failure ->
        emit_settlement_failure(failure, transports)
        {:error, gateway_error}
    end
  end

  defp collected_compaction_diagnostics(metadata, %{collected_provider_failure: failure}) do
    metadata
    |> maybe_put_terminal_error_code(failure.upstream_code)
    |> maybe_put_stream_terminal_type(failure.event_type)
    |> Metadata.maybe_put_upstream_error_param(failure)
  end

  defp collected_compaction_diagnostics(metadata, _finalization), do: metadata

  # The collector's own rejection diagnosis travels on the internal gateway
  # error map; persisting it keeps the six collector failure modes separable
  # after the logs age out. Public error renderers project a fixed field set,
  # so the key never reaches a wire payload.
  defp maybe_put_compaction_invalid_reason(metadata, %{compaction_invalid_reason: reason}) do
    case DiagnosticTaxonomy.identifier(reason) do
      code when is_binary(code) -> Map.put(metadata, "compaction_invalid_reason", code)
      nil -> metadata
    end
  end

  defp maybe_put_compaction_invalid_reason(metadata, _error), do: metadata

  defp native_full_history_compaction?(%RequestOptions{
         payload_context: %{
           compaction_trigger_bridge?: true,
           compaction_input_mode: :full_history,
           compaction_result_mode: :native_websocket
         },
         transport: %{transport: "websocket", websocket_delivery_mode: :collect_full_history}
       }),
       do: true

  defp native_full_history_compaction?(%RequestOptions{}), do: false

  defp native_collected_compaction?(%RequestOptions{
         payload_context: %{
           compaction_trigger_bridge?: true,
           compaction_result_mode: :native_websocket
         },
         transport: %{transport: "websocket", websocket_delivery_mode: mode}
       })
       when mode in [:collect_compaction, :collect_full_history],
       do: true

  defp native_collected_compaction?(%RequestOptions{}), do: false

  defp completed_result(
         %RequestOptions{payload_context: %{compaction_result_mode: mode}} = request_options,
         body,
         finalization
       )
       when mode in [:native_websocket, :public_websocket] do
    if RequestOptions.connection_bound_compaction?(request_options) do
      {:ok,
       %{
         status: 200,
         headers: Map.get(finalization, :result_headers, []),
         raw_body: body
       }}
    else
      {:ok, %{status: 200, headers: [], websocket_messages: []}}
    end
  end

  defp completed_result(%RequestOptions{}, _body, _finalization),
    do: {:ok, %{status: 200, headers: [], websocket_messages: []}}

  defp maybe_mark_public_compaction_error(
         error,
         %RequestOptions{openai_compatibility: %{source_endpoint: "/v1/responses"}}
       ),
       do: Map.put(error, :public_compaction_error?, true)

  defp maybe_mark_public_compaction_error(error, %RequestOptions{}), do: error

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

  defp acknowledge_native_ordinary_success(
         %SelectedCandidateContext{request_options: request_options} = context,
         %RequestOptions{
           payload_context: %{
             compaction_trigger_bridge?: false,
             native_codex_turn_metadata: %NativeCodexTurnMetadata{request_kind: :turn} = metadata
           }
         },
         %{
           response_id: response_id,
           upstream_websocket_connection: connection,
           ordinary_success_result: %OrdinarySuccessResult{} = receipt
         }
       )
       when is_binary(response_id) and is_map(connection) do
    with {:ok, lifecycle} <- connection_lifecycle(connection),
         true <-
           receipt.request_id == context.reserved.request.id and
             receipt.attempt_id == context.attempt.id,
         true <-
           receipt.model_digest ==
             NativeCompactionAdmission.FirstCompactResult.model_digest(context.model.upstream_model_id),
         {:ok, topology, owner} <- admission_owner(request_options),
         binding <-
           ordinary_success_binding(request_options, metadata, response_id, lifecycle, topology) do
      _result = record_ordinary_success(owner, binding, receipt)
      :ok
    else
      _invalid_or_unavailable -> :ok
    end
  end

  defp acknowledge_native_ordinary_success(_context, _request_options, _finalization), do: :ok

  @spec native_response_steering_acknowledgement(SelectedCandidateContext.t(), map(), {:ok, map()} | {:error, map()}) :: {:ok, NativeCompactionAdmission.Binding.t(), OrdinarySuccessResult.t()} | :none
  def native_response_steering_acknowledgement(_context, _finalization, {:ok, %{stale_generation?: true}}), do: :none

  def native_response_steering_acknowledgement(context, %{terminal: terminal, response_id: response_id, upstream_websocket_connection: connection, ordinary_success_result: %OrdinarySuccessResult{} = receipt}, {:ok, %{}}) when terminal in ["response.completed", "response.done", "response.incomplete"] do
    options = context.request_options

    with %NativeCodexTurnMetadata{request_kind: :turn} = metadata <- options.payload_context.native_codex_turn_metadata,
         {:ok, lifecycle} <- connection_lifecycle(connection),
         true <- receipt.request_id == context.reserved.request.id and receipt.attempt_id == context.attempt.id,
         true <- receipt.model_digest == NativeCompactionAdmission.FirstCompactResult.model_digest(context.model.upstream_model_id),
         {:ok, topology, _owner} <- admission_owner(options) do
      {:ok, ordinary_success_binding(options, metadata, response_id, lifecycle, topology), receipt}
    else
      _unavailable -> :none
    end
  end

  def native_response_steering_acknowledgement(_context, _finalization, _result), do: :none

  defp acknowledge_native_completed_success(_context, _request_options, %{native_response_steering_terminal?: true}), do: :ok

  defp acknowledge_native_completed_success(context, request_options, finalization) do
    case request_options.payload_context.compaction_result_mode do
      :native_websocket ->
        with :ok <- validate_first_compact_result(context, request_options, finalization),
             do: acknowledge_native_compact_success(request_options, finalization)

      _other ->
        acknowledge_native_ordinary_success(context, request_options, finalization)
    end
  end

  defp validate_first_compact_result(
         context,
         %RequestOptions{
           native_compaction_admission: nil,
           first_compact_collection: nil,
           payload_context: %{compaction_input_mode: :full_history}
         },
         %{first_compact_result: %NativeCompactionAdmission.FirstCompactResult{} = receipt}
       ) do
    if receipt.request_id == context.reserved.request.id and
         receipt.attempt_id == context.attempt.id and
         receipt.model_digest ==
           NativeCompactionAdmission.FirstCompactResult.model_digest(context.model.upstream_model_id) do
      :ok
    else
      {:error, compact_ack_error()}
    end
  end

  defp validate_first_compact_result(
         _context,
         %RequestOptions{
           native_compaction_admission: nil,
           first_compact_collection: nil,
           payload_context: %{compaction_input_mode: :full_history}
         },
         _finalization
       ),
       do: {:error, compact_ack_error()}

  defp validate_first_compact_result(_context, _options, _finalization), do: :ok

  defp acknowledge_native_compact_success(
         %RequestOptions{
           first_compact_collection: nil,
           native_compaction_admission: nil,
           payload_context: %{
             compaction_input_mode: :full_history,
             native_codex_turn_metadata: %NativeCodexTurnMetadata{} = metadata
           }
         } = options,
         %{
           upstream_websocket_connection: connection,
           normalized_compaction_item: item,
           first_compact_result: %NativeCompactionAdmission.FirstCompactResult{} = receipt
         } =
           finalization
       )
       when is_map(item) do
    with {:ok, lifecycle} <- connection_lifecycle(connection),
         {:ok, topology, owner} <- admission_owner(options),
         binding <- %NativeCompactionAdmission.Binding{
           semantic_turn_key: metadata.semantic_turn_key,
           window_digest: metadata.window_id_digest,
           context_digest: metadata.context_window_id_digest,
           window_number: metadata.window_number,
           serving_mode: serving_mode(options),
           topology: topology,
           lifecycle_id: lifecycle.lifecycle_id,
           generation: lifecycle.generation
         },
         true <- receipt.item_digest == NativeCodexTurnMetadata.compaction_item_digest(item) do
      case authorize_collected_first(owner, binding, receipt) do
        {:ok, provenance} ->
          options
          |> RequestOptions.put_first_compact_collection(provenance)
          |> acknowledge_native_compact_success(finalization)

        {:error, reason} ->
          deliver_unless_refused(options, :authorize, reason)
      end
    else
      _invalid -> {:error, compact_ack_error()}
    end
  end

  defp acknowledge_native_compact_success(
         %RequestOptions{
           payload_context: %{native_codex_turn_metadata: %NativeCodexTurnMetadata{} = metadata}
         } = request_options,
         %{normalized_compaction_item: item}
       )
       when is_map(item) do
    case compact_confirmation_provenance(request_options) do
      {:ok, topology, lifecycle} ->
        acknowledge_native_compact_confirmation(request_options, metadata, item, topology, lifecycle)

      {:error, reason} ->
        log_compact_confirmation_refusal(request_options, reason)
        {:error, compact_ack_error()}
    end
  end

  defp acknowledge_native_compact_success(_request_options, _finalization),
    do: {:error, compact_ack_error()}

  defp authorize_collected_first({:direct, owner}, binding, receipt),
    do: UpstreamWebsocketSession.authorize_first_compact_collection(owner, binding, receipt)

  defp authorize_collected_first({:forwarded, session, lease, downstream, opts}, binding, receipt) do
    with {:ok, control} <-
           WebsocketOwnerAdmissionControlV1.new(%{
             version: 1,
             action: :authorize_first_compact_collection,
             downstream: Map.take(downstream, [:pid, :epoch, :correlation_id]),
             binding: binding,
             phase: nil,
             control_ref: receipt.result_ref,
             capability: nil,
             disposition: nil,
             success?: nil,
             compaction_item_digest: nil,
             confirmation: nil,
             first_compact_collection: receipt,
             expires_at_ms: nil,
             now_ms: nil
           }) do
      WebsocketOwnerForwarder.admission_control(session, lease, control, opts)
    end
  end

  defp acknowledge_native_compact_confirmation(request_options, metadata, item, topology, lifecycle) do
    digest = NativeCodexTurnMetadata.compaction_item_digest(item)

    binding = %NativeCompactionAdmission.Binding{
      semantic_turn_key: metadata.semantic_turn_key,
      window_digest: metadata.window_id_digest,
      context_digest: metadata.context_window_id_digest,
      window_number: metadata.window_number,
      compaction_item_digest: digest,
      previous_response_digest: previous_response_digest(request_options),
      serving_mode: serving_mode(request_options),
      topology: topology,
      lifecycle_id: lifecycle.lifecycle_id,
      generation: lifecycle.generation
    }

    case RequestOptions.acknowledge_native_compact_finalization(
           request_options,
           digest,
           binding,
           System.system_time(:millisecond) + NativeCompactionAdmission.reservation_ttl_ms()
         ) do
      :ok -> :ok
      {:error, reason} -> deliver_unless_refused(request_options, :confirm, reason)
    end
  end

  # A compaction the provider served and billed and the collector validated
  # reaches its client unless its owner refused to confirm it. The owner may
  # not answer within its call budget (a slow owner, or the connection's slow
  # session with forwarding off) and apply the confirmation once it answers
  # again, which arms the final against the item the client received; or it
  # may be gone (exited, drained, replaced) and never apply it, which leaves
  # the final to run as an ordinary turn, as when the provider closed the
  # connection before the confirmation (findings#275). Both used to answer
  # `502 invalid_compaction_response`: the client resent the compaction with its
  # full history, and on the same connection the late confirmation's
  # `pending_final` refused that resend's first-compact authorization after the
  # provider had served and billed it, on every retry (findings#270 row
  # 270-249; the owner gone between collection and confirmation, row 270-170).
  # A refusal of the admission's own still answers the 502.
  defp deliver_unless_refused(request_options, step, reason) do
    case RequestOptions.compact_confirmation_outcome(reason) do
      :refused ->
        {:error, compact_ack_error()}

      outcome ->
        log_unconfirmed_compaction_answer(request_options, step, reason, outcome)
        :ok
    end
  end

  defp log_unconfirmed_compaction_answer(%RequestOptions{} = request_options, step, reason, outcome) do
    Logger.warning(fn ->
      "native compaction answered without owner confirmation " <>
        "step=#{step} " <>
        "reason=#{DiagnosticTaxonomy.identifier(reason) || "unknown"} " <>
        "confirmation=#{outcome} " <>
        "compaction_input_mode=#{compact_confirmation_input_mode(request_options)} " <>
        "serving_mode=#{serving_mode(request_options)} " <>
        "correlation_id=#{DiagnosticTaxonomy.safe_correlator(RequestOptions.websocket_request_correlation_id(request_options))} " <>
        "codex_session_id=#{DiagnosticTaxonomy.safe_correlator(compact_confirmation_session_id(request_options))}"
    end)

    :ok
  end

  # The confirmation binding is only authorized against provenance the request
  # itself carries: the admission capability the socket reserved, or the
  # first-compact collection this finalizer just collected. An incremental
  # compaction whose owner reservation answered `:owner_unavailable` reaches
  # this point with neither, and the confirmation fails closed with its own
  # reason instead of dereferencing an absent provenance (findings#257).
  defp compact_confirmation_provenance(%RequestOptions{} = request_options) do
    case RequestOptions.native_compaction_admission(request_options) do
      {:ok, capability, _owner, lifecycle} -> {:ok, capability.binding.topology, lifecycle}
      _no_usable_admission -> first_compact_confirmation_provenance(request_options)
    end
  end

  defp first_compact_confirmation_provenance(%RequestOptions{
         first_compact_collection: %NativeCompactionAdmission.FirstCompactCollection{
           binding: %NativeCompactionAdmission.Binding{} = binding
         }
       }),
       do: {:ok, binding.topology, binding}

  # Which provenance is missing is the whole diagnosis, so the reason keeps them
  # apart: nothing was ever reserved, or an admission is carried and no longer
  # unwraps into a usable capability.
  defp first_compact_confirmation_provenance(%RequestOptions{native_compaction_admission: nil}),
    do: {:error, :missing_confirmation_provenance}

  defp first_compact_confirmation_provenance(%RequestOptions{}),
    do: {:error, :unusable_admission_provenance}

  # A refused confirmation settles the upstream turn as it really ended and
  # refuses only the compaction acknowledgement, so the reason survives nowhere
  # else: keep it in one bounded line instead of losing which provenance was
  # missing.
  defp log_compact_confirmation_refusal(%RequestOptions{} = request_options, reason) do
    Logger.warning(fn ->
      "native compact confirmation refused " <>
        "reason=#{DiagnosticTaxonomy.identifier(reason) || "unknown"} " <>
        "code=#{compact_ack_error().code} " <>
        "status=#{compact_ack_error().status} " <>
        "compaction_input_mode=#{compact_confirmation_input_mode(request_options)} " <>
        "serving_mode=#{serving_mode(request_options)} " <>
        "correlation_id=#{DiagnosticTaxonomy.safe_correlator(RequestOptions.websocket_request_correlation_id(request_options))} " <>
        "codex_session_id=#{DiagnosticTaxonomy.safe_correlator(compact_confirmation_session_id(request_options))}"
    end)

    :ok
  end

  defp compact_confirmation_input_mode(%RequestOptions{payload_context: %{compaction_input_mode: mode}})
       when mode in [:incremental, :full_history],
       do: mode

  defp compact_confirmation_input_mode(%RequestOptions{}), do: "unknown"

  defp compact_confirmation_session_id(%RequestOptions{continuity: %{codex_session: %{id: id}}})
       when is_binary(id),
       do: id

  defp compact_confirmation_session_id(%RequestOptions{}), do: "none"

  defp previous_response_digest(%RequestOptions{continuity: %{previous_response_id: value}})
       when is_binary(value),
       do: NativeCodexTurnMetadata.response_id_digest(value)

  defp previous_response_digest(%RequestOptions{}), do: nil

  defp compact_ack_error do
    %{
      status: 502,
      code: "invalid_compaction_response",
      message: "upstream compact stream was invalid"
    }
  end

  defp connection_lifecycle(%{lifecycle_id: lifecycle_id, generation: generation})
       when is_integer(generation) and generation > 0 do
    if match?({:ok, _uuid}, Ecto.UUID.cast(lifecycle_id)) do
      {:ok, %{lifecycle_id: lifecycle_id, generation: generation}}
    else
      {:error, :invalid_lifecycle}
    end
  end

  defp connection_lifecycle(_connection), do: {:error, :invalid_lifecycle}

  defp admission_owner(%RequestOptions{
         transport: %{
           upstream_websocket_session: owner,
           websocket_owner: %{enabled?: false}
         }
       })
       when is_pid(owner),
       do: {:ok, %NativeCompactionAdmission.Topology.Direct{}, {:direct, owner}}

  defp admission_owner(%RequestOptions{
         transport: %{
           upstream_websocket_session: nil,
           websocket_owner: owner
         }
       })
       when is_map(owner) and owner.enabled? == true do
    downstream = Map.take(owner.downstream, [:pid, :epoch, :correlation_id])

    topology =
      WebsocketOwnerAdmissionControlV1.forwarded_topology(
        owner.owner_instance_id,
        owner.lease_token,
        owner.downstream_epoch
      )

    {:ok, topology, {:forwarded, owner.session, owner.lease_token, downstream, owner.forwarder_opts}}
  end

  defp admission_owner(%RequestOptions{}), do: {:error, :owner_unavailable}

  defp ordinary_success_binding(request_options, metadata, response_id, lifecycle, topology) do
    %NativeCompactionAdmission.Binding{
      semantic_turn_key: metadata.semantic_turn_key,
      window_digest: metadata.window_id_digest,
      context_digest: metadata.context_window_id_digest,
      window_number: metadata.window_number,
      previous_response_digest: NativeCodexTurnMetadata.response_id_digest(response_id),
      serving_mode: serving_mode(request_options),
      topology: topology,
      lifecycle_id: lifecycle.lifecycle_id,
      generation: lifecycle.generation
    }
  end

  defp serving_mode(%RequestOptions{} = request_options) do
    case RequestOptions.model_serving_mode(request_options) do
      "lite" -> :lite
      _other -> :full
    end
  end

  defp record_ordinary_success({:direct, owner}, binding, receipt) do
    UpstreamWebsocketSession.arm_compact(
      owner,
      binding,
      System.system_time(:millisecond) + NativeCompactionAdmission.reservation_ttl_ms(),
      receipt
    )
  end

  defp record_ordinary_success(
         {:forwarded, session, lease_token, downstream, opts},
         binding,
         receipt
       ) do
    with {:ok, control} <-
           WebsocketOwnerAdmissionControlV1.new(%{
             version: 1,
             action: :record_ordinary_success,
             downstream: downstream,
             binding: binding,
             phase: nil,
             control_ref: nil,
             capability: nil,
             disposition: nil,
             success?: nil,
             compaction_item_digest: nil,
             confirmation: nil,
             first_compact_collection: receipt,
             expires_at_ms: System.system_time(:millisecond) + NativeCompactionAdmission.reservation_ttl_ms(),
             now_ms: nil
           }) do
      WebsocketOwnerForwarder.admission_control(session, lease_token, control, opts)
    end
  end

  @spec finalize_terminal(SelectedCandidateContext.t(), map()) :: {:ok, map()} | {:error, map()}
  def finalize_terminal(context, %{upstream_error_code: "unsupported_native_inflight_message"} = finalization) do
    code = "unsupported_native_inflight_message"
    metadata = terminal_failure_metadata(context, finalization.headers, Map.get(finalization, :websocket_frame_headers, %{}), Map.get(finalization, :upstream_websocket_connection), code, code, nil, %{})
    metadata = Map.merge(metadata, provider_rejection_metadata(finalization.body, context.request_options))

    attrs =
      SettlementAttrs.partial_stream_failure(context, 400, code, "native inflight control is unsupported by the provider", metadata,
        started: finalization.started,
        before_finalize: fn ->
          SideEffects.observe_websocket_response(context, finalization)
          DispatchLifecycle.neutral_completion(context)
        end
      )

    case AttemptSettlement.finalize_partial_stream_failure(context.reserved.request, context.attempt, response_usage(finalization, finalization.body), attrs, context.request_options.runtime.session_owner_witness) do
      {:ok, _settled} = result ->
        emit_settlement_outcome(result, "failed", resolved_transports(context))
        {:ok, %{status: 200, headers: [], websocket_messages: []}}

      {:stale_generation, finalized} ->
        {:ok, finalized}

      {:error, _error} = error ->
        error
    end
  end

  def finalize_terminal(context, finalization) do
    %{body: body, terminal: terminal} = finalization

    if collected_compaction?(context) do
      finalize_completed(context, finalization)
    else
      case websocket_terminal_outcome(terminal, body) do
        {:ok, %{kind: kind}} when kind in [:completed, :incomplete] ->
          finalize_completed(context, finalization)

        _outcome ->
          finalize_terminal_failure(context, finalization)
      end
    end
  end

  defp collected_compaction?(%SelectedCandidateContext{
         request_options: %RequestOptions{payload_context: %{compaction_result_mode: mode}} = request_options
       })
       when mode in [:native_websocket, :public_websocket],
       do: RequestOptions.connection_bound_compaction?(request_options)

  defp collected_compaction?(%SelectedCandidateContext{}), do: false

  defp finalize_terminal_failure(context, finalization) do
    %{body: body, terminal: terminal, headers: headers} = finalization

    upstream_code =
      Map.get(finalization, :upstream_error_code) ||
        StreamProtocol.terminal_error_code(body, terminal)

    health_code =
      cond do
        ErrorCodes.unknown_provider_refusal?(provider_refusal_status(body), upstream_code) -> :neutral
        Streaming.health_neutral_terminal_failure?(upstream_code, headers) -> upstream_code
        true -> StreamProtocol.terminal_error_code(body, terminal)
      end

    code = if Map.get(finalization, :public_tool_completion_reason), do: "upstream_stream_error", else: StreamProtocol.client_visible_error_code(upstream_code)
    websocket_frame_headers = Map.get(finalization, :websocket_frame_headers, %{})
    metadata_headers = headers ++ Map.to_list(websocket_frame_headers)
    continuation_guard = continuation_guard_metadata(upstream_code, Map.get(finalization, :transport_failure))

    attempt_metadata =
      terminal_failure_metadata(
        context,
        metadata_headers,
        websocket_frame_headers,
        Map.get(finalization, :upstream_websocket_connection),
        code,
        upstream_code,
        Map.get(finalization, :upstream_error_param),
        continuation_guard
      )
      |> collected_compaction_diagnostics(finalization)
      |> Map.merge(provider_rejection_metadata(body, context.request_options))

    settle_terminal_failure(
      context,
      finalization,
      terminal_failure_usage(finalization, body, continuation_guard),
      code,
      attempt_metadata,
      health_code,
      metadata_headers
    )
  end

  # The connection-bound guard refuses an anchor before anything is sent on
  # the connection (`UpstreamWebsocketSession`'s
  # `guard_connection_bound_continuation`), and only its exact metadata
  # survives `TransportFailureReason.sanitize_continuation_generation_guard_metadata/1`,
  # so that metadata proves the provider never received the request: it
  # settles with no usage. As unknown usage it kept the reservation estimate,
  # which the key's window usage counts as provisional tokens. The provider's
  # own `Invalid previous_response_id` refusal, canonicalized to the same code,
  # carries no guard metadata and keeps the unknown usage of a request the
  # provider received.
  defp terminal_failure_usage(_finalization, _body, continuation_guard) when map_size(continuation_guard) > 0,
    do: ResponseUsage.undispatched()

  defp terminal_failure_usage(finalization, body, _continuation_guard), do: response_usage(finalization, body)

  # A provider refusal the upstream websocket sent as its wrapped error frame
  # (`{"type": "error", "status": 4xx, "error": {...}}`) records the rejection
  # fields the HTTP path records for the same provider response, read from that
  # frame as the equivalent HTTP response (findings#254 row 254-15). Nothing is
  # recorded outside `Metadata.rejection_metadata_status?/1`. A native turn
  # collects the frame after its canonicalization into `response.failed`,
  # which keeps the wrapped frame's integer `status` next to the error object
  # (a provider `response.failed` carries none), so that shape records the same
  # fields (findings#254 row 254-30). The canonicalization writes a code into
  # an error the provider sent without one (its `type`, or the
  # `upstream_terminal_failure` fallback); that code is the Pooler's
  # derivation, not the provider's, so it is left out as the HTTP path leaves
  # out the absent code of the same refusal (findings#254 row 254-60). The
  # same holds for the `previous_response_not_found` code the native
  # canonicalization gives the provider's codeless `Invalid previous_response_id`
  # refusal, whose fixed message the attempt records as its class (findings#232
  # row 232-278).
  defp provider_rejection_metadata(body, request_options) do
    with {:ok, %{"type" => type, "error" => %{} = error} = frame} when type in ["error", "response.failed"] <- last_terminal_frame(body),
         status = Map.get(frame, "status", Map.get(frame, "status_code")) || if(Map.get(error, "code") == "unsupported_native_inflight_message", do: 400),
         true <- Metadata.rejection_metadata_status?(status) do
      error = if type == "response.failed", do: drop_derived_code(error), else: drop_previous_response_miss_code(error)
      response = %Req.Response{status: status, body: CodexPooler.JSON.encode!(%{"error" => error})}

      response
      |> Metadata.rejection_metadata()
      |> Map.merge(ValidationRejection.attempt_metadata(ValidationRejection.fetch(response, request_options)))
      |> put_native_refusal_status(status, request_options)
    else
      _other -> %{}
    end
  end

  # The integer status of the provider refusal the upstream websocket sent as
  # its wrapped error frame (public turns retain that frame, native turns the
  # canonical `response.failed` that keeps its status); nil for any other
  # terminal, a provider `response.failed` included.
  defp provider_refusal_status(body) do
    case last_terminal_frame(body) do
      {:ok, %{"type" => type} = frame} when type in ["error", "response.failed"] ->
        case Map.get(frame, "status", Map.get(frame, "status_code")) do
          status when is_integer(status) -> status
          _other -> nil
        end

      _other ->
        nil
    end
  end

  # A native turn's refusal keeps the provider status next to the sanitized
  # tokens, so a resend of a finally refused turn is answered with the refusal
  # it got (findings#254 row 254-100); a websocket row keeps no provider status
  # of its own. The public `/v1` websocket keeps exactly the fields its HTTP
  # path records (findings#254 row 254-15).
  defp put_native_refusal_status(metadata, status, %RequestOptions{openai_compatibility: %{public_openai_responses_stream: false}}),
    do: Map.put(metadata, "rejection_upstream_status", status)

  defp put_native_refusal_status(metadata, _status, _request_options), do: metadata

  defp drop_derived_code(%{"code" => code, "type" => code} = error), do: Map.delete(error, "code")
  defp drop_derived_code(%{"code" => "upstream_terminal_failure"} = error), do: Map.delete(error, "code")
  defp drop_derived_code(error), do: error

  defp drop_previous_response_miss_code(%{"code" => "previous_response_not_found", "message" => message} = error) do
    if message == ErrorCodes.invalid_previous_response_id_message(), do: Map.delete(error, "code"), else: error
  end

  defp drop_previous_response_miss_code(error), do: error

  defp last_terminal_frame(body) when is_binary(body) do
    case StreamProtocol.complete_sse_blocks(body, bounded?: false) do
      {[_block | _rest] = blocks, _remaining} ->
        {_event_type, decoded} = StreamProtocol.stream_block_event(List.last(blocks))
        {:ok, decoded}

      _other ->
        :error
    end
  end

  defp last_terminal_frame(_body), do: :error

  defp terminal_failure_metadata(
         context,
         metadata_headers,
         websocket_frame_headers,
         upstream_websocket_connection,
         code,
         upstream_code,
         upstream_error_param,
         continuation_guard
       ) do
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
    |> terminal_failure_attempt_metadata(code)
    |> maybe_put_terminal_transport_failure(continuation_guard)
  end

  defp terminal_failure_attempt_metadata(metadata, code) do
    if code == MisalignmentPolicyViolation.code(),
      do: Map.delete(metadata, "upstream_error_param"),
      else: metadata
  end

  defp maybe_put_terminal_error_code(metadata, upstream_code) when is_binary(upstream_code),
    do:
      Map.put(
        metadata,
        "upstream_error_code",
        DiagnosticTaxonomy.identifier(upstream_code)
      )

  defp maybe_put_terminal_error_code(metadata, _upstream_code), do: metadata

  defp maybe_put_stream_terminal_type(metadata, terminal) when is_binary(terminal),
    do: Map.put(metadata, "stream_terminal_type", DiagnosticTaxonomy.identifier(terminal))

  defp maybe_put_stream_terminal_type(metadata, _terminal), do: metadata

  defp maybe_put_terminal_transport_failure(metadata, transport_failure)
       when map_size(transport_failure) > 0,
       do: Map.put(metadata, "transport_failure", transport_failure)

  defp maybe_put_terminal_transport_failure(metadata, _transport_failure), do: metadata

  defp continuation_guard_metadata("previous_response_not_found", transport_failure),
    do: TransportFailureReason.sanitize_continuation_generation_guard_metadata(transport_failure)

  defp continuation_guard_metadata(_upstream_code, _transport_failure), do: %{}

  defp settle_terminal_failure(
         context,
         finalization,
         usage,
         code,
         attempt_metadata,
         upstream_code,
         metadata_headers
       ) do
    %{reserved: reserved, attempt: attempt} = context
    transports = resolved_transports(context)

    case AttemptSettlement.finalize_partial_stream_failure(
           reserved.request,
           attempt,
           usage,
           SettlementAttrs.partial_stream_failure(
             context,
             finalization.status,
             code,
             terminal_accounting_message(code),
             attempt_metadata,
             started: finalization.started
           )
           |> Map.put(
             :before_finalize,
             fn ->
               SideEffects.observe_websocket_response(context, finalization)
               record_terminal_health(upstream_code, metadata_headers, context)
             end
           ),
           context.request_options.runtime.session_owner_witness
         ) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

      {:ok, _finalized} = result ->
        emit_settlement_outcome(result, "failed", transports)
        terminal_failure_result(finalization, code)

      {:error, gateway_error} = error ->
        emit_settlement_failure(error, transports)
        {:error, gateway_error}
    end
  end

  # An unknown provider 4xx refusal completes the route neutrally, as the HTTP
  # answer of the same refusal does (findings#254 row 254-81).
  defp record_terminal_health(:neutral, _headers, context), do: DispatchLifecycle.neutral_completion(context)
  defp record_terminal_health(code, headers, context), do: Streaming.record_terminal_health_failure(code, headers, context)

  defp websocket_terminal_outcome("response.completed", _body), do: {:ok, %{kind: :completed}}
  defp websocket_terminal_outcome(_terminal, body), do: StreamProtocol.terminal_outcome(body)

  defp terminal_accounting_message(code) do
    if code == MisalignmentPolicyViolation.code(),
      do: MisalignmentPolicyViolation.fallback_message(),
      else: code
  end

  defp terminal_failure_result(
         %{collected_provider_failure_event: event},
         _code
       ) do
    {:ok, %{status: 200, headers: [], websocket_messages: [event]}}
  end

  defp terminal_failure_result(
         %{collected_provider_failure: failure, status: status},
         code
       ) do
    {:error,
     error(
       status,
       code,
       collected_provider_failure_message(code),
       failure.upstream_error_param
     )}
  end

  defp terminal_failure_result(_finalization, _code),
    do: {:ok, %{status: 200, headers: [], websocket_messages: []}}

  defp collected_provider_failure_status(%{code: code, upstream_code: upstream_code})
       when code in ["invalid_request", "invalid_request_error"] or
              upstream_code in [
                "misalignment_policy_violation",
                "previous_response_not_found",
                "invalid_previous_response_id"
              ],
       do: 400

  defp collected_provider_failure_status(_failure), do: 502

  defp collected_provider_failure_message(code) do
    if code == "stream_incomplete" do
      "upstream stream incomplete"
    else
      "upstream rejected the compact request"
    end
  end

  @spec finalize_failed(SelectedCandidateContext.t(), map()) ::
          {:ok, map()} | {:error, map()} | {:retry, term()}
  def finalize_failed(context, %{reason: :provider_credits_policy_denied} = denial),
    do: Finalization.finalize_policy_denial(denial, context, max(System.monotonic_time(:millisecond) - denial.started, 0))

  def finalize_failed(context, %{reason: :client_disconnected} = finalization) do
    %{headers: headers, started: started} = finalization

    %{reserved: reserved, attempt: attempt, request_options: request_options, endpoint: endpoint} =
      context

    code = "client_disconnected"
    transports = resolved_transports(context)

    case AttemptSettlement.finalize_partial_stream_failure(
           reserved.request,
           attempt,
           response_usage(finalization, ""),
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
             started: started,
             before_finalize: fn ->
               SideEffects.observe_websocket_response(context, finalization)
             end
           ),
           request_options.runtime.session_owner_witness
         ) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

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
    finalization = ExpiredOwnerGenerationCleanup.strip(finalization)
    %{body: body, headers: headers, started: started} = finalization
    %{reserved: reserved, attempt: attempt, request_options: request_options} = context
    {:ok, owner_payload} = WebsocketOwnerContract.safe_error_payload(reason, nil)
    transports = resolved_transports(context)

    case AttemptSettlement.finalize_partial_stream_failure(
           reserved.request,
           attempt,
           response_usage(finalization, body),
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
             started: started,
             before_finalize: fn ->
               SideEffects.observe_websocket_response(context, finalization)
             end
           ),
           request_options.runtime.session_owner_witness
         ) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

      {:ok, _finalized} = result ->
        # A drained, lost or crashed owner interrupted the turn; a forwarding
        # refusal or a superseded downstream failed it (findings#228).
        emit_settlement_outcome(result, InterruptionOutcome.outcome_for_code(owner_payload.code), transports)

        {:error,
         error(owner_payload.status, owner_payload.code, owner_payload.message, nil, %{
           owner_error: owner_payload.metadata.owner_error
         })}

      {:error, gateway_error} = error ->
        emit_settlement_failure(error, transports)
        {:error, gateway_error}
    end
  end

  # A websocket turn with no websocket upstream path, and a public `/v1` request
  # anchored on `previous_response_id` that cannot reach the connection that
  # produced it, never dispatched: settle it once with the fixed Pooler error
  # and no usage, without retry or route-health evidence.
  def finalize_failed(
        context,
        %{reason: reason, error: %{status: status, code: code} = failure} = finalization
      )
      when reason in [:websocket_transport_required, :previous_response_connection_required] do
    %{headers: headers, started: started} = finalization
    %{reserved: reserved, attempt: attempt, request_options: request_options} = context
    transports = resolved_transports(context)

    metadata =
      headers
      |> Metadata.websocket_response_metadata(code, request_options)
      |> Map.drop(["content_type", "status_code", "upstream_transport"])

    case AttemptSettlement.finalize_partial_stream_failure(
           reserved.request,
           attempt,
           ResponseUsage.undispatched(),
           SettlementAttrs.partial_stream_failure(context, status, code, code, metadata, started: started),
           request_options.runtime.session_owner_witness
         ) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

      {:ok, _finalized} = result ->
        emit_settlement_outcome(result, "failed", transports)
        {:error, error(status, code, failure.message, Map.get(failure, :param))}

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
      |> maybe_put_native_client_retry_observation(finalization)
      |> Metadata.maybe_put_upstream_error_param(finalization)

    finalize_failed_after_health(context, finalization, code, metadata)
  end

  defp maybe_put_transport_failure_metadata(metadata, %{transport_failure: transport_failure})
       when is_map(transport_failure) and map_size(transport_failure) > 0 do
    Map.put(metadata, "transport_failure", transport_failure)
  end

  defp maybe_put_transport_failure_metadata(metadata, _finalization), do: metadata

  defp maybe_put_native_client_retry_observation(
         metadata,
         %{native_client_retry_observation: %ClientRetry.Observation{} = observation}
       ) do
    case ClientRetry.final_observation_metadata(observation) do
      {:ok, summary} -> Map.put(metadata, "native_client_retry_observation", summary)
      :ineligible -> put_native_client_retry_authority_loss(metadata, observation)
    end
  end

  defp maybe_put_native_client_retry_observation(metadata, _finalization), do: metadata

  # An ineligible observation is still evidence, just not admission evidence.
  # It keeps its own key so no resend path can mistake it for the witness, and
  # it carries only the bounded reason authority was lost.
  defp put_native_client_retry_authority_loss(metadata, observation) do
    case ClientRetry.authority_loss_metadata(observation) do
      {:ok, summary} -> Map.put(metadata, "native_client_retry_authority_loss", summary)
      :none -> metadata
    end
  end

  defp finalize_failed_after_health(
         %SelectedCandidateContext{allow_retry?: true, reserved: reserved, attempt: attempt} =
           context,
         %{body: "", reason: reason, started: started} = finalization,
         code,
         metadata
       ) do
    if RequestOptions.connection_bound_compaction?(context.request_options) or upstream_committed?(finalization) do
      finalize_failed_after_health(
        %{context | allow_retry?: false},
        finalization,
        code,
        metadata
      )
    else
      # The failed candidate's route health is recorded here as on the last
      # candidate below and on HTTP (`Finalization`'s
      # `finalize_dispatch_error_after_route_failure/5`): without it a connect
      # failure that failed over left a half-open probe this attempt claimed
      # counted in flight until the staleness self-heal, and a closed circuit
      # never counted the failure (findings#325 row 325-4).
      case AttemptSettlement.record_retryable_failure(reserved.request, attempt, %{
             usage: response_usage(finalization, ""),
             last_error_code: code,
             error_message: Metadata.safe_reason(reason),
             latency_ms: elapsed_ms(started),
             attempt_metadata: metadata,
             before_finalize: fn ->
               SideEffects.observe_websocket_response(context, finalization)
               record_failed_health(context, finalization, code)
             end
           }) do
        {:stale_generation, finalized} -> {:ok, finalized}
        {:ok, _attempt} -> {:retry, code}
        {:error, gateway_error} -> {:error, gateway_error}
      end
    end
  end

  defp finalize_failed_after_health(context, finalization, code, metadata) do
    %{body: body, reason: reason, started: started} = finalization
    %{reserved: reserved, attempt: attempt, endpoint: endpoint} = context
    transports = resolved_transports(context)
    auth_exhaustion = Map.get(finalization, :auth_exhaustion)

    case AttemptSettlement.finalize_partial_stream_failure(
           reserved.request,
           attempt,
           response_usage(finalization, body),
           SettlementAttrs.partial_stream_failure(
             context,
             failed_status(auth_exhaustion),
             code,
             failed_message(auth_exhaustion, reason),
             metadata,
             started: started
           )
           |> maybe_put_before_finalize(fn ->
             SideEffects.observe_websocket_response(context, finalization)

             record_failed_health(context, finalization, code)
           end),
           context.request_options.runtime.session_owner_witness
         ) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

      {:ok, _finalized} = result ->
        emit_settlement_outcome(result, "failed", transports)

        cond do
          native_full_history_compaction?(context.request_options) -> {:error, compact_ack_error()}
          auth_exhaustion -> {:error, error(ErrorCodes.upstream_unauthorized_status(), code, ErrorCodes.upstream_unauthorized_message())}
          true -> {:error, failed_error_response(endpoint, code, reason)}
        end

      {:error, gateway_error} = error ->
        emit_settlement_failure(error, transports)
        {:error, gateway_error}
    end
  end

  # A failure after the turn's payload reached the provider settles on its
  # account instead of failing over: the provider may already be running the
  # turn there, and another account must not run it a second time. HTTP fails
  # over only before submission (`TransportFailureReason.retry_safe_before_submission?/1`).
  # The client gets the same post-submission answer, `502
  # upstream_request_failed`, and its resend steps over the zero-output
  # predecessor (findings#325 row 325-6). A failure whose metadata does not say
  # the payload was committed keeps the failover.
  defp upstream_committed?(%{transport_failure: %{"upstream_committed" => true}}), do: true
  defp upstream_committed?(_finalization), do: false

  # Exhausted upstream auth the client was shown nothing of settles as HTTP's
  # (`HttpAuthRefresh`): `503 upstream_unauthorized`, recorded and answered,
  # with the route failure and the account's reconciliation, or a neutral
  # completion and no reconciliation for a refresh follower, whose refusal is
  # another caller's refresh in flight (findings#325 row 325-7).
  defp failed_status(nil), do: 502
  defp failed_status(_auth_exhaustion), do: ErrorCodes.upstream_unauthorized_status()

  defp failed_message(nil, reason), do: Metadata.safe_reason(reason)
  defp failed_message(_auth_exhaustion, _reason), do: ErrorCodes.upstream_unauthorized_message()

  defp record_failed_health(context, finalization, code) do
    if TransportFailureReason.peer_message_too_large?(Map.get(finalization, :transport_failure)) do
      DispatchLifecycle.neutral_completion(context)
    else
      do_record_failed_health(context, finalization.reason, code, Map.get(finalization, :auth_exhaustion))
    end
  end

  defp do_record_failed_health(context, _reason, _code, :follower), do: DispatchLifecycle.neutral_completion(context)

  defp do_record_failed_health(context, reason, code, :exhausted) do
    SideEffects.maybe_enqueue_gateway_reconciliation(context.reserved.request.pool_id, context.assignment)
    do_record_failed_health(context, reason, code)
  end

  defp do_record_failed_health(context, reason, code, nil), do: do_record_failed_health(context, reason, code)

  defp do_record_failed_health(context, :upstream_websocket_closed_before_terminal = reason, code) do
    if native_full_history_compaction?(context.request_options) do
      DispatchLifecycle.neutral_completion(context)
    else
      Streaming.record_health_failure(reason, code, context)
    end
  end

  defp do_record_failed_health(context, reason, code),
    do: Streaming.record_health_failure(reason, code, context)

  defp emit_settlement_outcome({:ok, finalized}, outcome, transports) do
    if AttemptSettlement.first_settlement?(finalized) do
      if outcome == "interrupted" do
        InterruptionOutcome.emit(
          transports.downstream_transport,
          transports.upstream_transport
        )
      else
        Streaming.emit_stream_outcome(
          outcome,
          transports.downstream_transport,
          transports.upstream_transport
        )
      end
    end
  end

  defp maybe_put_before_finalize(attrs, callback) when is_function(callback, 0) do
    if Map.get(attrs, :before_finalize),
      do: attrs,
      else: Map.put(attrs, :before_finalize, callback)
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

  defp response_usage(%{response_usage: %{status: status} = usage}, _body)
       when status in ["usage_known", "usage_unknown"],
       do: usage

  # A retained body from an older owner may have lost intermediate events.
  # It can still supply legacy usage/first-model facts, never collection provenance.
  defp response_usage(_finalization, body), do: Map.delete(ResponseUsage.from_websocket_body(body), :model_observation)

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)

  defp error(status, code, message, param \\ nil, metadata \\ %{}),
    do: Map.merge(%{status: status, code: code, message: message, param: param}, metadata)
end
