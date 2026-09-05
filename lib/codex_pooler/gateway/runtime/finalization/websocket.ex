defmodule CodexPooler.Gateway.Runtime.Finalization.Websocket do
  @moduledoc false

  alias CodexPooler.Accounting.ClientRetry
  alias CodexPooler.Gateway.Payloads.{CompactionTrigger, NativeCodexTurnMetadata, RequestOptions}
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Routing.DispatchLifecycle
  alias CodexPooler.Gateway.Runtime.Streaming.CompactionResultCollector

  alias CodexPooler.Gateway.Runtime.Finalization.{
    AttemptSettlement,
    Metadata,
    ResponseUsage,
    SettlementAttrs,
    SideEffects,
    Streaming
  }

  alias CodexPooler.Gateway.Transports.MisalignmentPolicyViolation
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Gateway.Transports.Websocket.OrdinarySuccessResult

  alias CodexPooler.Gateway.Transports.Websocket.{
    NativeCompactionAdmission,
    UpstreamWebsocketSession,
    WebsocketOwnerAdmissionControlV1,
    WebsocketOwnerContract,
    WebsocketOwnerForwarder
  }

  @compact_reservation_ttl_ms 60_000

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

      case CompactionResultCollector.collect_websocket_body(body, item_mode) do
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
             started: started,
             before_finalize: fn ->
               SideEffects.observe_websocket_response(context, finalization)
               SideEffects.before_finalize_success(context, request_options)
             end
           )
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

    if native_full_history_compaction?(context.request_options) do
      finalize_invalid_compaction(context, finalization, compact_ack_error())
    else
      finalize_terminal_failure(context, finalization)
    end
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
        |> collected_compaction_diagnostics(finalization),
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

    case AttemptSettlement.finalize_failure(reserved.request, attempt, attrs) do
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
    |> Map.put("upstream_error_code", failure.upstream_code)
    |> Map.put("stream_terminal_type", failure.event_type)
    |> Metadata.maybe_put_upstream_error_param(failure)
  end

  defp collected_compaction_diagnostics(metadata, _finalization), do: metadata

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
             NativeCompactionAdmission.FirstCompactResult.model_digest(
               context.model.upstream_model_id
             ),
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
           NativeCompactionAdmission.FirstCompactResult.model_digest(
             context.model.upstream_model_id
           ) do
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
         true <- receipt.item_digest == NativeCodexTurnMetadata.compaction_item_digest(item),
         {:ok, provenance} <- authorize_collected_first(owner, binding, receipt) do
      options
      |> RequestOptions.put_first_compact_collection(provenance)
      |> acknowledge_native_compact_success(finalization)
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
    digest = NativeCodexTurnMetadata.compaction_item_digest(item)

    binding = %NativeCompactionAdmission.Binding{
      semantic_turn_key: metadata.semantic_turn_key,
      window_digest: metadata.window_id_digest,
      context_digest: metadata.context_window_id_digest,
      window_number: metadata.window_number,
      compaction_item_digest: digest,
      previous_response_digest: previous_response_digest(request_options),
      serving_mode: serving_mode(request_options),
      topology: compact_confirmation_topology(request_options),
      lifecycle_id: compact_confirmation_lifecycle(request_options).lifecycle_id,
      generation: compact_confirmation_lifecycle(request_options).generation
    }

    case RequestOptions.acknowledge_native_compact_finalization(
           request_options,
           digest,
           binding,
           System.system_time(:millisecond) + @compact_reservation_ttl_ms
         ) do
      :ok -> :ok
      {:error, _reason} -> {:error, compact_ack_error()}
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

  defp compact_confirmation_lifecycle(%RequestOptions{} = request_options) do
    case RequestOptions.native_compaction_admission(request_options) do
      {:ok, _capability, _owner, lifecycle} -> lifecycle
      :none -> request_options.first_compact_collection.binding
    end
  end

  defp compact_confirmation_topology(%RequestOptions{} = request_options) do
    case RequestOptions.native_compaction_admission(request_options) do
      {:ok, capability, _owner, _lifecycle} -> capability.binding.topology
      :none -> request_options.first_compact_collection.binding.topology
    end
  end

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

    {:ok, topology,
     {:forwarded, owner.session, owner.lease_token, downstream, owner.forwarder_opts}}
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
      System.system_time(:millisecond) + @compact_reservation_ttl_ms,
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
             expires_at_ms: System.system_time(:millisecond) + @compact_reservation_ttl_ms,
             now_ms: nil
           }) do
      WebsocketOwnerForwarder.admission_control(session, lease_token, control, opts)
    end
  end

  @spec finalize_terminal(SelectedCandidateContext.t(), map()) :: {:ok, map()} | {:error, map()}
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
         request_options:
           %RequestOptions{payload_context: %{compaction_result_mode: mode}} = request_options
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
      if Streaming.health_neutral_terminal_failure?(upstream_code, headers) do
        upstream_code
      else
        StreamProtocol.terminal_error_code(body, terminal)
      end

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

    settle_terminal_failure(
      context,
      finalization,
      body,
      code,
      attempt_metadata,
      health_code,
      metadata_headers
    )
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
    |> terminal_failure_attempt_metadata(code)
    |> maybe_put_terminal_transport_failure(continuation_guard)
  end

  defp terminal_failure_attempt_metadata(metadata, code) do
    if code == MisalignmentPolicyViolation.code(),
      do: Map.delete(metadata, "upstream_error_param"),
      else: metadata
  end

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
         body,
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
           ResponseUsage.from_websocket_body(body),
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

               Streaming.record_terminal_health_failure(
                 upstream_code,
                 metadata_headers,
                 context
               )
             end
           )
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

  defp websocket_terminal_outcome("response.completed", _body), do: {:ok, %{kind: :completed}}
  defp websocket_terminal_outcome(_terminal, body), do: StreamProtocol.terminal_outcome(body)

  defp terminal_accounting_message(code) do
    if code == MisalignmentPolicyViolation.code(),
      do: MisalignmentPolicyViolation.fallback_message(),
      else: code
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
             started: started,
             before_finalize: fn ->
               SideEffects.observe_websocket_response(context, finalization)
             end
           )
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
             started: started,
             before_finalize: fn ->
               SideEffects.observe_websocket_response(context, finalization)
             end
           )
         ) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

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
      :ineligible -> metadata
    end
  end

  defp maybe_put_native_client_retry_observation(metadata, _finalization), do: metadata

  defp finalize_failed_after_health(
         %SelectedCandidateContext{allow_retry?: true, reserved: reserved, attempt: attempt} =
           context,
         %{body: "", reason: reason, started: started} = finalization,
         code,
         metadata
       ) do
    if RequestOptions.connection_bound_compaction?(context.request_options) do
      finalize_failed_after_health(
        %{context | allow_retry?: false},
        %{body: "", reason: reason, started: started},
        code,
        metadata
      )
    else
      case AttemptSettlement.record_retryable_failure(reserved.request, attempt, %{
             last_error_code: code,
             error_message: Metadata.safe_reason(reason),
             latency_ms: elapsed_ms(started),
             attempt_metadata: metadata,
             before_finalize: fn ->
               SideEffects.observe_websocket_response(context, finalization)
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
           |> maybe_put_before_finalize(fn ->
             SideEffects.observe_websocket_response(context, finalization)

             record_failed_health(context, reason, code)
           end)
         ) do
      {:stale_generation, finalized} ->
        {:ok, finalized}

      {:ok, _finalized} = result ->
        emit_settlement_outcome(result, "failed", transports)

        if native_full_history_compaction?(context.request_options) do
          {:error, compact_ack_error()}
        else
          {:error, failed_error_response(endpoint, code, reason)}
        end

      {:error, gateway_error} = error ->
        emit_settlement_failure(error, transports)
        {:error, gateway_error}
    end
  end

  defp record_failed_health(context, :upstream_websocket_closed_before_terminal = reason, code) do
    if native_full_history_compaction?(context.request_options) do
      DispatchLifecycle.neutral_completion(context)
    else
      Streaming.record_health_failure(reason, code, context)
    end
  end

  defp record_failed_health(context, reason, code),
    do: Streaming.record_health_failure(reason, code, context)

  defp emit_settlement_outcome({:ok, finalized}, outcome, transports) do
    if AttemptSettlement.first_settlement?(finalized) do
      Streaming.emit_stream_outcome(
        outcome,
        transports.downstream_transport,
        transports.upstream_transport
      )
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

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)

  defp error(status, code, message, param \\ nil, metadata \\ %{}),
    do: Map.merge(%{status: status, code: code, message: message, param: param}, metadata)
end
