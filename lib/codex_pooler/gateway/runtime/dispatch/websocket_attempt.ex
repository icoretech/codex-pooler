defmodule CodexPooler.Gateway.Runtime.Dispatch.WebsocketAttempt do
  @websocket_refresh_metadata_operation :merge_websocket_auth_refresh_metadata
  @moduledoc false

  require Logger

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.OpenAICompatibility
  alias CodexPooler.Gateway.Routing.CandidateEligibility.PoolReturn
  alias CodexPooler.Gateway.Routing.CircuitRetryAfter
  alias CodexPooler.Gateway.Runtime.Dispatch.AuthRefresh
  alias CodexPooler.Gateway.Runtime.Dispatch.ContentFilterBindingRefusal
  alias CodexPooler.Gateway.Runtime.Dispatch.PartitionFallback
  alias CodexPooler.Gateway.Runtime.Dispatch.PreparedContext
  alias CodexPooler.Gateway.Runtime.Dispatch.ResponseContext
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.Finalization.{AttemptSettlement, Metadata, ProviderUsageLimit}
  alias CodexPooler.Gateway.Runtime.Finalization.ExpiredOwnerGenerationCleanup
  alias CodexPooler.Gateway.Runtime.Finalization.SideEffects
  alias CodexPooler.Gateway.Runtime.NativeResponseSteering
  alias CodexPooler.Gateway.Runtime.Routing.DispatchLifecycle
  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl
  alias CodexPooler.Gateway.Transports.ProviderCreditsAdmission
  alias CodexPooler.Gateway.Transports.RetryAfter
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Gateway.Transports.UpstreamDispatch.Request, as: DispatchRequest
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Gateway.Websocket.DirectCleanup

  # Dialyzer cannot prove the JSON-decoded websocket terminal auth signatures that
  # UpstreamWebsocketSession classifies at runtime, so it marks this retry branch
  # unreachable even though controller tests exercise it through FakeUpstream.
  @dialyzer {:nowarn_function,
             [
               finalize_not_retryable_auth_refresh: 6,
               auth_exhaustion: 1,
               retry_after_websocket_auth_refresh: 5,
               record_auth_refresh_first_attempt_failure: 4,
               auth_refresh_failover?: 1,
               failover_after_recorded_auth_failure: 2
             ]}

  @type callbacks :: %{
          required(:register_continuity) => (term(), term(), term() -> term()),
          required(:stream_result) => (Req.Response.t(), term() -> term()),
          optional(:auth_refresh_failover?) => boolean()
        }
  @type dispatch_result :: CodexPooler.Gateway.Runtime.Dispatch.dispatch_result()

  @spec dispatch(PreparedContext.t(), DispatchRequest.t(), callbacks()) :: dispatch_result()
  def dispatch(
        %PreparedContext{} = prepared_context,
        %DispatchRequest{} = dispatch_request,
        callbacks
      ) do
    started = System.monotonic_time(:millisecond)

    case NativeResponseSteering.prepare(prepared_context.context, callbacks) do
      {:error, reason} ->
        Finalization.finalize_failed_websocket_response(%{prepared_context.context | allow_retry?: false}, %{reason: reason, body: "", headers: [], started: started})

      lane ->
        try do
          dispatch_result(prepared_context, %{dispatch_request | native_response_steering: lane}, callbacks, started)
        after
          context = prepared_context.context
          NativeResponseSteering.dispatch_complete(lane, {context.reserved.request.id, context.attempt.id})
        end
    end
  end

  defp dispatch_result(prepared_context, dispatch_request, callbacks, started) do
    context = prepared_context.context

    case dispatch_websocket_request_with_owner_recovery(prepared_context, dispatch_request) do
      {:error, %{reason: {:quota_exhausted_first_event, failure}} = response} ->
        handle_quota_exhausted_first_event(context, dispatch_request, response, failure)

      {:error, %{reason: {:assignment_model_unavailable_first_event, failure}} = response} ->
        handle_assignment_model_unavailable_first_event(
          context,
          dispatch_request,
          response,
          failure,
          started
        )

      result ->
        handle_dispatch_result(result, prepared_context, dispatch_request, callbacks, started)
    end
  end

  # A usage limit before any output completes the refusing candidate's circuit
  # admission as its HTTP `429` twin does, whether the turn fails over, hops
  # to a held-back partition or settles here: neutral when the frame's headers
  # exclude the account, the `429` route failure otherwise. The failover and
  # the hop used to record no health, so a half-open probe the attempt claimed
  # stayed counted in flight until the staleness self-heal (findings#325 row
  # 325-5).
  defp handle_quota_exhausted_first_event(context, dispatch_request, response, failure) do
    SideEffects.observe_websocket_response(context, response)

    retry_reason = quota_first_event_retry_reason(context)
    route_health = fn -> Finalization.record_websocket_usage_limit_route_health(context, Map.get(response, :websocket_frame_headers, %{}), failure.code) end

    if retry_reason do
      response_context = retryable_websocket_response_context(context, response)

      case Finalization.record_retryable_first_event_stream_failure(
             Map.get(response, :body, ""),
             failure,
             response_context,
             route_health: route_health
           ) do
        {:stale_generation, finalized} -> {:ok, finalized}
        {:ok, _recorded_failure} -> {:retry, retry_reason}
        {:error, _reason} = error -> error
      end
    else
      finalize_retryable_first_websocket_event(context, dispatch_request, response, failure, route_health: route_health)
    end
  end

  defp quota_first_event_retry_reason(context) do
    cond do
      not (first_event_retry_policy(context) == :same_assignment and context.request_options.payload_context.portable_full_history?) -> nil
      context.allow_retry? -> :upstream_quota_exhausted
      # The selected partition's last candidate: the turn moves to a held-back
      # partition once (findings#206 row 206-586).
      PartitionFallback.available?(context) -> :partition_fallback
      true -> nil
    end
  end

  defp handle_dispatch_result(result, prepared_context, dispatch_request, callbacks, started) do
    context = prepared_context.context

    case result do
      {:ok, %{native_response_steering_finalized: finalized}} ->
        finalized

      {:error, %{native_response_steering_finalized: finalized}} ->
        finalized

      {:error, %{reason: {:auth_refresh_first_event, failure}} = response} ->
        handle_auth_refresh_websocket_failure(
          prepared_context,
          dispatch_request,
          callbacks,
          response,
          failure,
          started
        )

      {:error, %{reason: {:websocket_upgrade_failed, 401, headers}} = response} ->
        handle_auth_refresh_websocket_failure(
          prepared_context,
          dispatch_request,
          callbacks,
          Map.put(response, :headers, headers),
          handshake_auth_failure(headers),
          started
        )

      {:error, %{reason: {:retryable_first_event, failure}} = response} ->
        handle_retryable_first_websocket_event(
          prepared_context,
          dispatch_request,
          callbacks,
          response,
          failure
        )

      {:error, %{reason: reason} = response}
      when reason in [:upstream_websocket_closed_before_terminal, :closed, :econnreset] ->
        handle_transport_websocket_failure(
          prepared_context,
          dispatch_request,
          callbacks,
          response,
          started
        )

      {:ok, %{terminal: terminal} = response} ->
        finalize_terminal_dispatch(context, dispatch_request, callbacks, response, terminal, started)

      {:error, response} ->
        # A connect-phase failure keeps HEAD's policy: candidate failover while
        # the route plan has another candidate, otherwise a single finalized
        # attempt. It never takes the same-assignment retry (findings#208).
        Finalization.finalize_failed_websocket_response(
          context,
          Map.put(response, :started, started)
        )
    end
  end

  defp finalize_terminal_dispatch(context, dispatch_request, callbacks, response, terminal, started) do
    finalization =
      response
      |> Map.put(:started, started)
      |> maybe_put_websocket_callbacks(callbacks)

    outcome = websocket_terminal_outcome(terminal, Map.get(response, :body, ""))

    result =
      case outcome do
        {:ok, %{kind: kind}} when kind in [:completed, :incomplete] ->
          Finalization.finalize_completed_websocket_response(context, finalization)

        _outcome ->
          Finalization.finalize_terminal_websocket_response(context, finalization)
      end

    NativeResponseSteering.original_result(dispatch_request.native_response_steering, {context.reserved.request.id, context.attempt.id}, result)
    result
  end

  defp handle_auth_refresh_websocket_failure(
         %PreparedContext{context: %{auth_refresh_retry_attempted?: attempted?} = context} =
           prepared_context,
         dispatch_request,
         callbacks,
         response,
         failure,
         started
       ) do
    if attempted? == true or retry_suppressed?(context) do
      # A second rejection after the refreshed retry is exhausted auth; a
      # suppressed refresh (bound reset probe, connection-bound compaction,
      # client retry dispatch) never tried one.
      kind = if attempted? == true, do: :exhausted, else: :suppressed

      finish_auth_refresh_failure(context, dispatch_request, callbacks, response, failure, started, kind)
    else
      case retry_after_websocket_auth_refresh(
             prepared_context,
             dispatch_request,
             response,
             failure,
             started
           ) do
        {:stale_generation, finalized} ->
          {:ok, finalized}

        {:ok, retry_prepared_context, retry_dispatch_request} ->
          # Keep ordinary same-assignment retry suppression. Only a second
          # rejected handshake may use the original candidate failover permission.
          callbacks = Map.put(callbacks, :auth_refresh_failover?, auth_refresh_failover?(context))
          dispatch(retry_prepared_context, retry_dispatch_request, callbacks)

        {:error, _reason} = error ->
          error

        {:refresh_not_retryable, refresh_metadata} ->
          finalize_not_retryable_auth_refresh(
            context,
            refresh_metadata,
            dispatch_request,
            response,
            failure,
            started
          )
      end
    end
  end

  defp finish_auth_refresh_failure(context, dispatch_request, callbacks, response, failure, started, kind) do
    if exhausted_auth_refresh_failover?(context, response, callbacks) do
      response_context = auth_refresh_websocket_response_context(context, response)

      case record_auth_refresh_first_attempt_failure(context, response_context, failure, started) do
        {:ok, _recorded_failure} -> failover_after_recorded_auth_failure(context, %{})
        {:stale_generation, finalized} -> {:ok, finalized}
        {:error, _reason} = error -> error
      end
    else
      finalize_exhausted_auth_refresh(context, dispatch_request, response, failure, started, kind)
    end
  end

  defp exhausted_auth_refresh_failover?(%{auth_refresh_retry_attempted?: true} = context, %{reason: {:websocket_upgrade_failed, 401, _headers}, body: ""} = response, %{auth_refresh_failover?: true}) do
    not match?(%{transport_failure: %{"upstream_committed" => true}}, response) and not retry_suppressed?(context)
  end

  defp exhausted_auth_refresh_failover?(_context, _response, _callbacks), do: false

  defp retry_after_websocket_auth_refresh(
         %PreparedContext{context: context} = prepared_context,
         dispatch_request,
         response,
         failure,
         started
       ) do
    response_context = auth_refresh_websocket_response_context(context, response)

    case record_auth_refresh_first_attempt_failure(
           context,
           response_context,
           failure,
           started
         ) do
      {:stale_generation, finalized} ->
        {:stale_generation, finalized}

      {:ok, _recorded_failure} ->
        with {:ok, refresh_metadata, refreshed_identity} <-
               AuthRefresh.refresh(context, :websocket),
             {:ok, refreshed_context} <-
               AuthRefresh.record_metadata(
                 context,
                 refresh_metadata,
                 @websocket_refresh_metadata_operation
               ),
             {:ok, retry_context} <-
               create_same_assignment_retry_context(%{
                 refreshed_context
                 | identity: refreshed_identity,
                   auth_refresh_retry_attempted?: true
               }),
             {:ok, refreshed_token} <- AuthRefresh.decrypt_access_token(refreshed_identity) do
          retry_prepared_context = %{
            prepared_context
            | context: retry_context,
              token: refreshed_token
          }

          {:ok, retry_prepared_context, retry_dispatch_request(retry_prepared_context, dispatch_request)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp handle_pre_visible_transport_websocket_failure(
         %PreparedContext{context: %{retry_count: 0} = context} = prepared_context,
         dispatch_request,
         callbacks,
         response,
         started
       ) do
    if retry_suppressed?(context) do
      Finalization.finalize_failed_websocket_response(
        context,
        Map.put(response, :started, started)
      )
    else
      code = Finalization.stream_error_code(response.reason)

      case AttemptSettlement.record_retryable_failure(
             context.reserved.request,
             context.attempt,
             %{
               usage: Map.get(response, :response_usage, %{}),
               last_error_code: code,
               error_message: Metadata.safe_reason(response.reason),
               latency_ms: elapsed_ms(started),
               attempt_metadata:
                 response
                 |> pre_visible_transport_metadata(context, code)
                 |> maybe_put_transport_failure_metadata(response)
                 |> Metadata.maybe_put_upstream_error_param(response),
               retry_count: context.retry_count,
               before_finalize: fn ->
                 SideEffects.observe_websocket_response(context, response)
               end
             }
           ) do
        {:stale_generation, finalized} ->
          {:ok, finalized}

        {:ok, _recorded_failure} ->
          dispatch_same_assignment_retry(prepared_context, dispatch_request, callbacks)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp handle_pre_visible_transport_websocket_failure(
         %PreparedContext{context: context},
         _dispatch_request,
         _callbacks,
         response,
         started
       ) do
    Finalization.finalize_failed_websocket_response(context, Map.put(response, :started, started))
  end

  defp pre_visible_transport_websocket_failure?(%{body: body}) when is_binary(body),
    do: StreamProtocol.internal_control_event?(body) or body == ""

  defp handle_transport_websocket_failure(
         %PreparedContext{context: context} = prepared_context,
         dispatch_request,
         callbacks,
         response,
         started
       ) do
    if pre_visible_transport_websocket_failure?(response) and
         pre_submission_websocket_failure?(response) do
      handle_pre_visible_transport_websocket_failure(
        prepared_context,
        dispatch_request,
        callbacks,
        response,
        started
      )
    else
      Finalization.finalize_failed_websocket_response(
        context,
        Map.put(response, :started, started)
      )
    end
  end

  defp pre_submission_websocket_failure?(%{
         transport_failure: %{"phase" => "connect", "upstream_committed" => false}
       }),
       do: true

  defp pre_submission_websocket_failure?(_response), do: false

  defp handle_retryable_first_websocket_event(
         %PreparedContext{context: %{allow_retry?: true} = context} = prepared_context,
         dispatch_request,
         callbacks,
         response,
         failure
       ) do
    case first_event_retry_policy(context) do
      :connection_bound ->
        finalize_connection_bound_first_event_failure(context, response, failure)

      :bound_reset_probe ->
        finalize_retryable_first_websocket_event(context, dispatch_request, response, failure)

      :same_assignment ->
        response_context = retryable_websocket_response_context(context, response)

        case Finalization.record_retryable_first_event_stream_failure(
               Map.get(response, :body, ""),
               failure,
               response_context,
               record_health?: false
             ) do
          {:stale_generation, finalized} ->
            {:ok, finalized}

          {:ok, _recorded_failure} ->
            dispatch_same_assignment_retry(prepared_context, dispatch_request, callbacks)

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp handle_retryable_first_websocket_event(
         %PreparedContext{context: context},
         dispatch_request,
         _callbacks,
         response,
         failure
       ) do
    finalize_retryable_first_websocket_event(context, dispatch_request, response, failure)
  end

  defp finalize_connection_bound_first_event_failure(context, response, failure) do
    Finalization.finalize_terminal_websocket_response(
      context,
      response
      |> Map.put(:started, context.started)
      |> Map.put(:status, websocket_response_status(response))
      |> Map.put(:terminal, failure.event_type || failure.data_type || "error")
      |> Map.put(:upstream_error_code, failure.upstream_code || failure.code)
      |> Map.put(:upstream_error_param, Map.get(failure, :upstream_error_param))
    )
  end

  defp dispatch_same_assignment_retry(
         %PreparedContext{context: context} = prepared_context,
         dispatch_request,
         callbacks
       ) do
    with {:ok, retry_context} <- create_same_assignment_retry_context(context) do
      retry_prepared_context = %{prepared_context | context: retry_context}
      retry_dispatch_request = retry_dispatch_request(retry_prepared_context, dispatch_request)

      dispatch(retry_prepared_context, retry_dispatch_request, callbacks)
    end
  end

  defp finalize_retryable_first_websocket_event(
         context,
         dispatch_request,
         response,
         failure,
         opts \\ []
       ) do
    {answered, result_messages} = answer_retry_exhausted_websocket_failure(context, dispatch_request, response)

    answer = answered |> List.last() |> usage_limit_answer(RequestOptions.native_originator(context.request_options))
    log_usage_limit_answer(answer, dispatch_request, failure)

    response_context = context |> retryable_websocket_response_context(response) |> record_usage_limit_answer(answer)

    case Finalization.finalize_first_event_stream_failure(
           Map.get(response, :body, ""),
           failure,
           response_context,
           opts
         ) do
      {:ok, _finalized} -> {:ok, %{status: 200, headers: [], websocket_messages: if(answer, do: result_messages, else: [])}}
      {:error, _reason} = error -> error
    end
  end

  # The refused frames as the client gets them, and the messages the dispatch
  # result carries. A turn with a writer gets its frames written, and its
  # result carries none. A collected connection-bound compaction has no
  # writer: its client reads the dispatch result, which the compaction result
  # adapter turned into `502 invalid_compaction_response` when it carried
  # nothing (findings#305 row 498-5). Its refusal frame is the result's one
  # message instead (`Service.maybe_adapt_websocket_result/2` passes a single
  # error through), which the socket renders like a written one; the caller
  # keeps it only for a usage-limit answer, so every other refusal of a
  # collected compaction keeps that answer.
  defp answer_retry_exhausted_websocket_failure(context, %DispatchRequest{writer: writer} = dispatch_request, response)
       when not is_function(writer, 1) do
    if RequestOptions.connection_bound_compaction?(context.request_options) do
      frames = project_retry_exhausted_websocket_failure(dispatch_request, response, &quota_refusal_frame(&1, context))
      {frames, frames |> Enum.take(-1) |> Enum.map(&CodexPooler.JSON.decode!/1)}
    else
      {[], []}
    end
  end

  defp answer_retry_exhausted_websocket_failure(context, dispatch_request, response),
    do: {deliver_retry_exhausted_websocket_failure(dispatch_request, response, &quota_refusal_frame(&1, context)), []}

  defp handle_assignment_model_unavailable_first_event(
         %{allow_retry?: true} = context,
         _dispatch_request,
         response,
         failure,
         _started
       ) do
    case first_event_retry_policy(context) do
      :connection_bound ->
        finalize_connection_bound_first_event_failure(context, response, failure)

      :bound_reset_probe ->
        finalize_assignment_model_unavailable_first_event(
          context,
          response,
          failure
        )

      :same_assignment ->
        response_context = retryable_websocket_response_context(context, response)

        case Finalization.record_retryable_first_event_stream_failure(
               Map.get(response, :body, ""),
               failure,
               response_context
             ) do
          {:stale_generation, finalized} -> {:ok, finalized}
          {:ok, _recorded_failure} -> {:retry, :upstream_model_unavailable}
          {:error, _reason} = error -> error
        end
    end
  end

  defp handle_assignment_model_unavailable_first_event(
         context,
         dispatch_request,
         response,
         failure,
         _started
       ) do
    deliver_retry_exhausted_websocket_failure(dispatch_request, response)

    finalize_assignment_model_unavailable_first_event(context, response, failure)
  end

  defp finalize_assignment_model_unavailable_first_event(context, response, failure) do
    response_context = retryable_websocket_response_context(context, response)

    case Finalization.finalize_first_event_stream_failure(
           Map.get(response, :body, ""),
           failure,
           response_context
         ) do
      {:ok, _finalized} -> {:ok, %{status: 200, headers: [], websocket_messages: []}}
      {:error, _reason} = error -> error
    end
  end

  defp pre_visible_transport_metadata(response, context, code) do
    response
    |> Map.get(:headers, [])
    |> req_response_headers()
    |> Metadata.websocket_response_metadata(
      code,
      context.request_options,
      Map.get(response, :websocket_frame_headers, %{}),
      Map.get(response, :upstream_websocket_connection)
    )
  end

  defp maybe_put_transport_failure_metadata(metadata, %{transport_failure: transport_failure})
       when is_map(transport_failure) and map_size(transport_failure) > 0 do
    Map.put(metadata, "transport_failure", transport_failure)
  end

  defp maybe_put_transport_failure_metadata(metadata, _response), do: metadata

  defp finalize_not_retryable_auth_refresh(
         context,
         refresh_metadata,
         dispatch_request,
         response,
         failure,
         started
       ) do
    with {:ok, refreshed_context} <-
           AuthRefresh.record_metadata(
             context,
             refresh_metadata,
             @websocket_refresh_metadata_operation
           ) do
      if pre_visible_transport_websocket_failure?(response) and auth_refresh_failover?(refreshed_context) do
        failover_after_recorded_auth_failure(refreshed_context, refresh_metadata)
      else
        finalize_exhausted_auth_refresh(
          refreshed_context,
          dispatch_request,
          response,
          failure,
          started,
          auth_exhaustion(refresh_metadata)
        )
      end
    end
  end

  # Another caller's refresh in flight makes this request its follower, as on
  # HTTP (`HttpAuthRefresh.finish_refresh_follower/2`): not the account's fault.
  defp auth_exhaustion(%{"status" => "refresh_in_progress"}), do: :follower
  defp auth_exhaustion(_refresh_metadata), do: :exhausted

  # The attempt was recorded retryable before the refresh ran, and only a
  # settlement may replace that record. The failed-websocket finalization
  # records a pre-visible failure as retryable once more before failing over,
  # which raised `attempt_already_finalized` here and left the request open,
  # its reservation held, until the six-hour stale-reservation sweep
  # (findings#325). With another candidate the turn fails over as the HTTP
  # refresh does (`HttpAuthRefresh`): the failed route records the auth
  # failure, or completes neutrally while another caller's refresh runs.
  # Without one, the exhausted path settles the attempt.
  defp auth_refresh_failover?(%{allow_retry?: true, request_options: request_options}),
    do: not RequestOptions.connection_bound_compaction?(request_options)

  defp auth_refresh_failover?(_context), do: false

  defp failover_after_recorded_auth_failure(context, %{"status" => "refresh_in_progress"}) do
    with :ok <- DispatchLifecycle.neutral_completion(context), do: {:retry, "upstream_unauthorized"}
  end

  # Exhausted auth also queues the account's reconciliation, as HTTP's
  # `mark_identity_unauthorized/1` does, so the operator sees its auth state
  # (findings#325 row 325-7).
  defp failover_after_recorded_auth_failure(context, _refresh_metadata) do
    SideEffects.maybe_enqueue_gateway_reconciliation(context.reserved.request.pool_id, context.assignment)

    case DispatchLifecycle.failure(context, "upstream_unauthorized") do
      {:ok, _demotion_reason} -> {:retry, "upstream_unauthorized"}
      {:error, _gateway_error} = error -> error
    end
  end

  defp record_auth_refresh_first_attempt_failure(context, response_context, failure, started) do
    AttemptSettlement.record_retryable_failure(context.reserved.request, context.attempt, %{
      response_status_code: response_context.response.status,
      last_error_code: "upstream_unauthorized",
      error_message: "upstream websocket auth failed before visible output",
      latency_ms: elapsed_ms(started),
      attempt_metadata:
        response_context.response
        |> Metadata.first_event_stream_metadata(
          failure,
          "websocket_auth_refresh_first_event",
          context.request_options
        )
        |> Map.merge(Metadata.upstream_websocket_connection_attempt_metadata(response_context.upstream_websocket_connection))
        |> Map.put("auth_refresh_trigger", AuthRefresh.trigger_kind(:websocket)),
      retry_count: context.retry_count,
      before_finalize: fn ->
        SideEffects.observe_websocket_response(context, response_context.response)
      end
    })
  end

  defp maybe_put_websocket_callbacks(%{terminal: terminal} = finalization, callbacks) do
    case websocket_terminal_outcome(terminal, Map.get(finalization, :body, "")) do
      {:ok, %{kind: kind}} when kind in [:completed, :incomplete] ->
        Map.put(finalization, :callbacks, callbacks)

      _outcome ->
        finalization
    end
  end

  defp websocket_terminal_outcome("response.completed", _body), do: {:ok, %{kind: :completed}}
  defp websocket_terminal_outcome(_terminal, body), do: StreamProtocol.terminal_outcome(body)

  # A refusal the client was shown nothing of settles as HTTP's exhausted auth
  # (`Finalization.Websocket` reads `auth_exhaustion`): `503
  # upstream_unauthorized`, the route failure and the account's reconciliation,
  # or a neutral completion for a refresh follower (findings#325 row 325-7). A
  # suppressed refresh keeps its ordinary answer, as HTTP's ineligible 401
  # does.
  defp finalize_exhausted_auth_refresh(context, dispatch_request, response, failure, started, kind) do
    if pre_visible_transport_websocket_failure?(response) do
      Finalization.finalize_failed_websocket_response(
        context,
        response
        |> Map.put(:reason, :upstream_unauthorized)
        |> Map.put(:started, started)
        |> put_auth_exhaustion(kind)
      )
    else
      deliver_retry_exhausted_websocket_failure(dispatch_request, response)

      Finalization.finalize_terminal_websocket_response(
        context,
        response
        |> Map.put(:started, started)
        |> Map.put(:status, websocket_response_status(response))
        |> Map.put(:terminal, failure.event_type || "response.failed")
        |> Map.put(:upstream_error_code, failure.upstream_code || failure.code)
      )
    end
  end

  defp put_auth_exhaustion(finalization, kind) when kind in [:exhausted, :follower], do: Map.put(finalization, :auth_exhaustion, kind)
  defp put_auth_exhaustion(finalization, :suppressed), do: finalization

  defp auth_refresh_websocket_response_context(context, response) do
    %ResponseContext{
      context: context,
      response: %Req.Response{
        status: websocket_response_status(response),
        headers: req_response_headers(Map.get(response, :headers, []))
      },
      upstream_transport: :websocket,
      upstream_websocket_connection: Map.get(response, :upstream_websocket_connection)
    }
  end

  defp req_response_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {name, value} ->
      values = if is_list(value), do: value, else: [to_string(value)]
      {to_string(name), values}
    end)
  end

  defp req_response_headers(_headers), do: []

  defp websocket_response_status(%{reason: {:websocket_upgrade_failed, status, _headers}}),
    do: status

  defp websocket_response_status(response) do
    case Map.get(response, :status) do
      status when is_integer(status) -> status
      _status -> 200
    end
  end

  defp handshake_auth_failure(headers) do
    upstream_code = auth_header_error_code(headers) || "unauthorized"

    %{
      code: upstream_code,
      upstream_code: upstream_code,
      event_type: "websocket_upgrade_failed",
      data_type: nil
    }
  end

  # The handshake header is promoted to the failure's `code`/`upstream_code`,
  # so it takes the websocket diagnostic code bound (`DiagnosticTaxonomy`): a
  # known code or an ASCII identifier of at most 80 bytes stays cleartext,
  # anything else is fingerprinted rather than used as a code, and a blank
  # value is absent so the `unauthorized` fallback applies (findings#238).
  defp auth_header_error_code(headers) when is_list(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(to_string(name)) == "x-openai-authorization-error" do
        bounded_auth_error_code(to_string(value))
      end
    end)
  end

  defp auth_header_error_code(_headers), do: nil

  defp bounded_auth_error_code(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> DiagnosticTaxonomy.identifier(trimmed)
    end
  end

  defp create_same_assignment_retry_context(context) do
    case Accounting.create_attempt(context.reserved.request, context.assignment, %{
           admitted_attempt_bind:
             DirectCleanup.attempt_callback(
               context.request_options.runtime.direct_cleanup,
               context.reserved.request
             ),
           model: context.model,
           pricing_snapshot: Map.get(context.reserved, :pricing_snapshot),
           upstream_identity: context.identity,
           response_metadata:
             Map.merge(context.request_options.routing.routing_attempt_metadata || %{}, %{
               "pool_upstream_assignment_id" => context.assignment.id,
               "upstream_identity_id" => context.identity.id
             })
         }) do
      {:ok, attempt} ->
        {:ok,
         %{
           context
           | attempt: attempt,
             started: System.monotonic_time(:millisecond),
             retry_count: context.retry_count + 1,
             allow_retry?: false
         }}

      {:error, %{code: :request_already_finalized}} ->
        {:error,
         %{
           status: 499,
           code: "request_already_finalized",
           message: "request lifecycle completed before upstream dispatch"
         }}

      # A content-filter retry binding the retry can no longer honour
      # (`ContentFilterBindingRefusal`, findings#316).
      {:error, %{code: :invalid_content_filter_retry_binding}} ->
        ContentFilterBindingRefusal.finalize_retry(context)

      {:error, reason} ->
        FailureResponse.accounting_failure(
          :create_same_assignment_websocket_retry_attempt,
          context.reserved.request,
          context.attempt,
          reason
        )
    end
  end

  defp retryable_websocket_response_context(context, response) do
    %ResponseContext{
      context: context,
      response_usage: Map.get(response, :response_usage),
      response: %Req.Response{status: 200, headers: Map.get(response, :headers, [])},
      upstream_transport: :websocket,
      upstream_websocket_connection: Map.get(response, :upstream_websocket_connection)
    }
  end

  defp deliver_retry_exhausted_websocket_failure(dispatch_request, upstream_response, project \\ &Function.identity/1)

  # Delivers the refused turn's frames and returns them as the client got them.
  defp deliver_retry_exhausted_websocket_failure(
         %DispatchRequest{writer: writer} = dispatch_request,
         upstream_response,
         project
       )
       when is_function(writer, 1) do
    dispatch_request
    |> project_retry_exhausted_websocket_failure(upstream_response, project)
    |> Enum.map(fn projected ->
      writer.(projected)
      projected
    end)
  end

  defp deliver_retry_exhausted_websocket_failure(_dispatch_request, _upstream_response, _project), do: []

  defp project_retry_exhausted_websocket_failure(%DispatchRequest{accounting_request: %{id: request_id}}, upstream_response, project) do
    request_id
    |> WebsocketCodec.stream_messages(Map.get(upstream_response, :body, ""))
    |> Enum.map(&(&1 |> sanitize_retry_terminal() |> put_quota_retry_after(upstream_response) |> project.()))
  end

  # The codec and native controls deliberately strip provider header objects.
  # Restore only the delay already admitted at the raw frame boundary, before
  # Pool reset/circuit projection decides the authoritative advice.
  defp put_quota_retry_after(frame, %{reason: {:quota_exhausted_first_event, _failure}, websocket_frame_headers: %{"retry-after" => value}}) do
    with safe when is_binary(safe) <- RetryAfter.normalize(value),
         %{"type" => type} = decoded when type in ["error", "response.failed", "response.incomplete"] <- CodexPooler.JSON.decode!(frame) do
      decoded |> Map.update("headers", %{"retry-after" => safe}, &Map.put(&1, "retry-after", safe)) |> CodexPooler.JSON.encode!()
    else
      _other -> frame
    end
  end

  defp put_quota_retry_after(frame, _response), do: frame

  # What the socket answers a pre-output usage-limit refusal with, read the way
  # the socket projects the delivered frame (`ProviderUsageLimit.frame_projection/2`):
  # the terminal usage limit and the reset it advises, or the classified relay
  # whose Pool advice was withheld (findings#206 row 206-596), each with the
  # status the socket sends. The terminal goes out as the client's originator
  # reads it (`Contracts.native_usage_limit_answer/2`: `400` to the Codex
  # Desktop app on a native route, findings#279 point 2); the relay is `429`
  # to every client.
  defp usage_limit_answer(frame, originator) when is_binary(frame) do
    case CodexPooler.JSON.decode(frame) do
      {:ok, %{"status" => 503, "error" => %{"code" => "pinned_continuation_unavailable"}}} -> {:withheld, 503}
      {:ok, %{} = decoded} -> decoded |> ProviderUsageLimit.frame_projection() |> projected_usage_limit_answer(originator)
      _other -> nil
    end
  end

  defp usage_limit_answer(_frame, _originator), do: nil

  defp projected_usage_limit_answer({:terminal, error}, originator),
    do: {:terminal, Contracts.usage_limit_record(error), Contracts.native_usage_limit_answer(error, originator).status}

  defp projected_usage_limit_answer({:relay, _provider_error}, _originator), do: {:withheld, 429}
  defp projected_usage_limit_answer(:canonical, _originator), do: nil

  # The row records the 429 refusal, and the attempt the reset a terminal
  # answer advised, like the HTTP twin (rows 206-553, 206-596); the Codex
  # Desktop app's `400` rendering of it is recorded as the refusal too.
  defp record_usage_limit_answer(%ResponseContext{response: response} = response_context, {:terminal, record, _answered_status}),
    do: %{response_context | response: response |> Map.put(:status, 429) |> Req.Response.put_private(:usage_limit_record, record)}

  defp record_usage_limit_answer(%ResponseContext{response: response} = response_context, {:withheld, _answered_status}),
    do: %{response_context | response: %{response | status: 429}}

  defp record_usage_limit_answer(response_context, nil), do: response_context

  defp log_usage_limit_answer(nil, _dispatch_request, _failure), do: :ok

  # `status` is the refusal's, which the row records, and `answered_status`
  # the status the socket sends: `400` for the Codex Desktop app's rendering
  # of the terminal answer, `429` otherwise (findings#270 row 270-261).
  defp log_usage_limit_answer(answer, dispatch_request, failure) do
    {advice, answered_status} =
      case answer do
        {:terminal, %{"resets_at" => resets_at, "resets_in_seconds" => seconds}, answered_status} ->
          {"advice=pool resets_at=#{resets_at} resets_in_seconds=#{seconds}", answered_status}

        {:terminal, _record, answered_status} ->
          {"advice=pool", answered_status}

        {:withheld, answered_status} ->
          {"advice=withheld", answered_status}
      end

    Logger.info(
      "websocket usage limit answered request_id=#{accounting_request_id(dispatch_request)} " <>
        "status=429 error_code=#{DiagnosticTaxonomy.identifier(to_string(Map.get(failure, :code)))} " <> advice <> " answered_status=#{answered_status}"
    )
  end

  defp accounting_request_id(%DispatchRequest{accounting_request: %{id: request_id}}), do: request_id
  defp accounting_request_id(_dispatch_request), do: nil

  # The Pool a pre-output usage-limit refusal on the last candidate speaks for
  # (findings#206 rows 206-545, 206-546): the socket projects the frame without
  # route context, so the Pool's advice is written into it here.
  # The wait an open circuit of another candidate bounds, for the public
  # socket's `retry-after` when the Pool advice is withheld (row 206-593).
  defp other_candidates_circuit_seconds(%{auth: auth, model: model, route_state: route_state, assignment: assignment, route_class: route_class}) do
    others = route_state |> RouteState.route_filter_candidates() |> Enum.reject(fn {candidate, _identity} -> candidate.id == assignment.id end)
    CircuitRetryAfter.current_seconds(auth, model, others, route_class)
  end

  defp quota_refusal_frame(frame, context) do
    others = fn -> other_candidates_return(context) end
    circuit = fn -> other_candidates_circuit_seconds(context) end

    if native_connection_pinned?(context) and
         ProviderUsageLimit.frame_projection(CodexPooler.JSON.decode!(frame)) != :canonical do
      anchored_quota_refusal_frame(frame, others.(), circuit)
    else
      ProviderUsageLimit.pool_frame(frame, others, circuit)
    end
  end

  defp anchored_quota_refusal_frame(frame, :unknown, _circuit), do: ProviderUsageLimit.retryable_continuation_frame(frame)
  defp anchored_quota_refusal_frame(frame, known, circuit), do: ProviderUsageLimit.pool_frame(frame, fn -> known end, circuit)

  # A native request that cannot leave its upstream connection: a continuation
  # anchored on `previous_response_id` (findings#270) or a connection-bound
  # compaction (findings#305 row 498-5). Its usage-limit refusal speaks for the
  # Pool's capacity before the connection pin (`RouteState.usage_limit_capacity/1`,
  # every canonical partition), the capacity the client's unpinned follow-up
  # can reach: the full-history continuation, or the compaction's HTTPS
  # fallback. With a seat that can serve or has no known return the answer is
  # the retryable `503 pinned_continuation_unavailable`, otherwise the Pool's
  # terminal usage limit with the earliest return.
  defp native_connection_pinned?(%{request_options: options} = context),
    do: native_anchored_continuation?(context) or native_connection_bound_compaction?(options)

  defp native_anchored_continuation?(%{request_options: options}) do
    is_binary(options.continuity.previous_response_id) and
      not OpenAICompatibility.translated_responses_surface?(options.openai_compatibility) and
      not RequestOptions.connection_bound_compaction?(options)
  end

  defp native_connection_bound_compaction?(options),
    do: RequestOptions.connection_bound_compaction?(options) and not OpenAICompatibility.translated_responses_surface?(options.openai_compatibility)

  defp other_candidates_return(%{model: model, route_state: route_state, assignment: assignment} = context) do
    candidates = if native_connection_pinned?(context), do: RouteState.usage_limit_capacity(route_state), else: RouteState.route_filter_candidates(route_state)
    PoolReturn.others(model, candidates, assignment.id, DateTime.utc_now(), context.request_options)
  end

  defp sanitize_retry_terminal(frame) do
    with {:ok, event} <- CodexPooler.JSON.decode(frame),
         {:changed, sanitized} <- NativeCodexResponseControl.sanitize_websocket_event(event) do
      CodexPooler.JSON.encode!(sanitized)
    else
      _unchanged -> frame
    end
  end

  @spec dispatch_websocket_request_with_owner_recovery(PreparedContext.t(), DispatchRequest.t()) ::
          {:ok, map()} | {:error, map()}
  # Only a failure before anything visible is retried on a recovered owner.
  # Any other stays the error it is: an owner that could not deliver a turn's
  # terminal answers with it as the body (findings#270 row 270-293), and the
  # bare map this branch used to return crashed the task.
  defp dispatch_websocket_request_with_owner_recovery(prepared_context, dispatch_request) do
    case UpstreamDispatch.websocket_request(dispatch_request) do
      {:error, %{reason: :owner_unavailable} = error} ->
        if pre_visible_transport_websocket_failure?(error) and
             not ExpiredOwnerGenerationCleanup.retry_blocked?(error, dispatch_request.accounting_request, dispatch_request.accounting_attempt) do
          retry_owner_websocket_request(prepared_context, dispatch_request, error)
        else
          {:error, error}
        end

      result ->
        result
    end
  end

  defp retry_owner_websocket_request(prepared_context, dispatch_request, original_error) do
    request_options = prepared_context.context.request_options

    if owner_forwarded_websocket_request?(request_options) and
         not retry_suppressed?(prepared_context.context) do
      case Websocket.recover_websocket_owner_response_options(request_options) do
        {:ok, recovered_options} ->
          recovered_context = %{prepared_context.context | request_options: recovered_options}
          recovered_prepared_context = %{prepared_context | context: recovered_context}

          recovered_prepared_context
          |> retry_dispatch_request(dispatch_request)
          |> UpstreamDispatch.websocket_request()

        {:error, _reason} ->
          {:error, original_error}
      end
    else
      {:error, original_error}
    end
  end

  defp retry_dispatch_request(
         %PreparedContext{context: context} = prepared_context,
         %DispatchRequest{} = dispatch_request
       ) do
    %{
      dispatch_request
      | url: prepared_context.url,
        token: prepared_context.token,
        upstream_payload: prepared_context.upstream_payload,
        original_payload: context.payload,
        identity: context.identity,
        provider_credits_context: ProviderCreditsAdmission.from_selected(context),
        accounting_attempt: context.attempt,
        request_options: context.request_options
    }
  end

  defp owner_forwarded_websocket_request?(%{transport: transport}) do
    owner = transport.websocket_owner

    owner.enabled? == true and
      not is_nil(owner.session) and
      is_binary(owner.lease_token) and
      is_map(owner.downstream)
  end

  defp bound_reset_probe?(context), do: AuthRefresh.bound_reset_probe?(context)

  defp first_event_retry_policy(context) do
    cond do
      RequestOptions.connection_bound_compaction?(context.request_options) ->
        :connection_bound

      bound_reset_probe?(context) ->
        :bound_reset_probe

      true ->
        :same_assignment
    end
  end

  defp retry_suppressed?(context), do: AuthRefresh.retry_suppressed?(context)

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)
end
