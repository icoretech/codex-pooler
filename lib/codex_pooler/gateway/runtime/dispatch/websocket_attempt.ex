defmodule CodexPooler.Gateway.Runtime.Dispatch.WebsocketAttempt do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Gateway.Runtime.Dispatch.PreparedContext
  alias CodexPooler.Gateway.Runtime.Dispatch.ResponseContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Runtime.Finalization.{AttemptSettlement, Metadata}
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Gateway.Transports.UpstreamDispatch.Request, as: DispatchRequest
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Upstreams.Auth.TokenRefresh
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Secrets

  @access_token_secret_kind "access_token"
  @auth_refresh_trigger_kind "websocket_terminal_auth_failure"

  # Dialyzer cannot prove the JSON-decoded websocket terminal auth signatures that
  # UpstreamWebsocketSession classifies at runtime, so it marks this retry branch
  # unreachable even though controller tests exercise it through FakeUpstream.
  @dialyzer {:nowarn_function,
             [
               finalize_not_retryable_auth_refresh: 6,
               retry_after_websocket_auth_refresh: 5,
               record_auth_refresh_first_attempt_failure: 4,
               refresh_websocket_auth: 1,
               record_auth_refresh_metadata: 2,
               refresh_in_progress_metadata: 1,
               maybe_put_safe_metadata: 3,
               safe_refresh_reason: 1
             ]}

  @type callbacks :: %{
          required(:register_continuity) => (term(), term(), term() -> term()),
          required(:stream_result) => (Req.Response.t(), term() -> term())
        }
  @type dispatch_result :: CodexPooler.Gateway.Runtime.Dispatch.dispatch_result()

  @spec dispatch(PreparedContext.t(), DispatchRequest.t(), callbacks()) :: dispatch_result()
  def dispatch(
        %PreparedContext{} = prepared_context,
        %DispatchRequest{} = dispatch_request,
        callbacks
      ) do
    started = System.monotonic_time(:millisecond)
    dispatch_result(prepared_context, dispatch_request, callbacks, started)
  end

  defp dispatch_result(prepared_context, dispatch_request, callbacks, started) do
    context = prepared_context.context

    case dispatch_websocket_request_with_owner_recovery(prepared_context, dispatch_request) do
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

  defp handle_dispatch_result(result, prepared_context, dispatch_request, callbacks, started) do
    context = prepared_context.context

    case result do
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

      {:error, %{body: "", reason: reason} = response}
      when reason in [:upstream_websocket_closed_before_terminal, :closed, :econnreset] ->
        handle_pre_visible_transport_websocket_failure(
          prepared_context,
          dispatch_request,
          callbacks,
          response,
          started
        )

      {:ok, %{terminal: terminal} = response} ->
        finalization =
          response
          |> Map.put(:started, started)
          |> maybe_put_websocket_callbacks(callbacks)

        case websocket_terminal_outcome(terminal, Map.get(response, :body, "")) do
          {:ok, %{kind: kind}} when kind in [:completed, :incomplete] ->
            Finalization.finalize_completed_websocket_response(context, finalization)

          _outcome ->
            Finalization.finalize_terminal_websocket_response(context, finalization)
        end

      {:error, response} ->
        Finalization.finalize_failed_websocket_response(
          context,
          Map.put(response, :started, started)
        )
    end
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
    if attempted? do
      finalize_exhausted_auth_refresh(context, dispatch_request, response, failure, started)
    else
      case retry_after_websocket_auth_refresh(
             prepared_context,
             dispatch_request,
             response,
             failure,
             started
           ) do
        {:ok, retry_prepared_context, retry_dispatch_request} ->
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

  defp retry_after_websocket_auth_refresh(
         %PreparedContext{context: context} = prepared_context,
         dispatch_request,
         response,
         failure,
         started
       ) do
    response_context = auth_refresh_websocket_response_context(context, response)

    with {:ok, _recorded_failure} <-
           record_auth_refresh_first_attempt_failure(
             context,
             response_context,
             failure,
             started
           ),
         {:ok, refresh_metadata, refreshed_identity} <- refresh_websocket_auth(context),
         {:ok, refreshed_context} <- record_auth_refresh_metadata(context, refresh_metadata),
         {:ok, retry_context} <-
           create_same_assignment_retry_context(%{
             refreshed_context
             | identity: refreshed_identity,
               auth_refresh_retry_attempted?: true
           }),
         {:ok, refreshed_token} <-
           Secrets.decrypt_active_secret(refreshed_identity, @access_token_secret_kind) do
      retry_prepared_context = %{
        prepared_context
        | context: retry_context,
          token: refreshed_token
      }

      {:ok, retry_prepared_context,
       retry_dispatch_request(retry_prepared_context, dispatch_request)}
    end
  end

  defp handle_pre_visible_transport_websocket_failure(
         %PreparedContext{context: %{retry_count: 0} = context} = prepared_context,
         dispatch_request,
         callbacks,
         response,
         started
       ) do
    code = Finalization.stream_error_code(response.reason)

    with {:ok, _recorded_failure} <-
           AttemptSettlement.record_retryable_failure(
             context.reserved.request,
             context.attempt,
             %{
               last_error_code: code,
               error_message: Metadata.safe_reason(response.reason),
               latency_ms: elapsed_ms(started),
               attempt_metadata:
                 response
                 |> pre_visible_transport_metadata(context, code)
                 |> maybe_put_transport_failure_metadata(response)
                 |> Metadata.maybe_put_upstream_error_param(response),
               retry_count: context.retry_count
             }
           ),
         {:ok, retry_context} <- create_same_assignment_retry_context(context) do
      retry_prepared_context = %{prepared_context | context: retry_context}
      retry_dispatch_request = retry_dispatch_request(retry_prepared_context, dispatch_request)

      dispatch(retry_prepared_context, retry_dispatch_request, callbacks)
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

  defp handle_retryable_first_websocket_event(
         %PreparedContext{context: %{allow_retry?: true} = context} = prepared_context,
         dispatch_request,
         callbacks,
         response,
         failure
       ) do
    response_context = retryable_websocket_response_context(context, response)

    with {:ok, _recorded_failure} <-
           Finalization.record_retryable_first_event_stream_failure(
             Map.get(response, :body, ""),
             failure,
             response_context,
             record_health?: false
           ),
         {:ok, retry_context} <- create_same_assignment_retry_context(context) do
      retry_prepared_context = %{prepared_context | context: retry_context}
      retry_dispatch_request = retry_dispatch_request(retry_prepared_context, dispatch_request)

      dispatch(retry_prepared_context, retry_dispatch_request, callbacks)
    end
  end

  defp handle_retryable_first_websocket_event(
         %PreparedContext{context: context},
         dispatch_request,
         _callbacks,
         response,
         failure
       ) do
    deliver_retry_exhausted_websocket_failure(dispatch_request, response)

    response_context = retryable_websocket_response_context(context, response)

    Finalization.finalize_first_event_stream_failure(
      Map.get(response, :body, ""),
      failure,
      response_context
    )
  end

  defp handle_assignment_model_unavailable_first_event(
         %{allow_retry?: true} = context,
         _dispatch_request,
         response,
         failure,
         _started
       ) do
    response_context = retryable_websocket_response_context(context, response)

    case Finalization.record_retryable_first_event_stream_failure(
           Map.get(response, :body, ""),
           failure,
           response_context
         ) do
      {:ok, _recorded_failure} -> {:retry, :upstream_model_unavailable}
      {:error, _reason} = error -> error
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
    with {:ok, refreshed_context} <- record_auth_refresh_metadata(context, refresh_metadata) do
      finalize_exhausted_auth_refresh(
        refreshed_context,
        dispatch_request,
        response,
        failure,
        started
      )
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
        |> Map.merge(
          Metadata.upstream_websocket_connection_attempt_metadata(
            response_context.upstream_websocket_connection
          )
        )
        |> Map.put("auth_refresh_trigger", @auth_refresh_trigger_kind),
      retry_count: context.retry_count
    })
  end

  # The 401 was produced by the credentials this dispatch connected with:
  # carrying their epoch lets a late follower skip the provider refresh when
  # another caller already rotated, and retry with the returned identity.
  # At token expiry every in-flight request on the identity fails auth at
  # once, so this is the highest-frequency duplicate-refresh source.
  defp refresh_websocket_auth(context) do
    case TokenRefresh.refresh_access_token(context.identity,
           trigger_kind: @auth_refresh_trigger_kind,
           expected_credential_epoch: CredentialFencing.credential_epoch(context.identity)
         ) do
      {:ok, %{status: :active, identity: refreshed_identity}} ->
        {:ok, %{"status" => "succeeded", "trigger_kind" => @auth_refresh_trigger_kind},
         refreshed_identity}

      {:ok, result} ->
        {:refresh_not_retryable,
         %{
           "status" => to_string(result.status),
           "trigger_kind" => @auth_refresh_trigger_kind
         }}

      {:error, :refresh_in_progress, metadata} ->
        {:refresh_not_retryable,
         metadata
         |> refresh_in_progress_metadata()
         |> Map.put("trigger_kind", @auth_refresh_trigger_kind)}

      {:error, reason} ->
        {:refresh_not_retryable,
         %{
           "status" => "failed",
           "trigger_kind" => @auth_refresh_trigger_kind,
           "reason" => safe_refresh_reason(reason)
         }}
    end
  end

  defp record_auth_refresh_metadata(context, metadata) do
    case Accounting.merge_request_metadata(context.reserved.request, %{"auth_refresh" => metadata}) do
      {:ok, request} ->
        {:ok, %{context | reserved: %{context.reserved | request: request}}}

      {:error, reason} ->
        FailureResponse.accounting_failure(
          :merge_websocket_auth_refresh_metadata,
          context.reserved.request,
          context.attempt,
          reason
        )
    end
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

  defp finalize_exhausted_auth_refresh(context, dispatch_request, response, failure, started) do
    case Map.get(response, :body, "") do
      "" ->
        Finalization.finalize_failed_websocket_response(
          context,
          response
          |> Map.put(:reason, :upstream_unauthorized)
          |> Map.put(:started, started)
        )

      _body ->
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

  defp auth_refresh_websocket_response_context(context, response) do
    %ResponseContext{
      context: context,
      response: %Req.Response{
        status: websocket_response_status(response),
        headers: req_response_headers(Map.get(response, :headers, []))
      },
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

  defp auth_header_error_code(headers) when is_list(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(to_string(name)) == "x-openai-authorization-error" do
        to_string(value)
      end
    end)
  end

  defp auth_header_error_code(_headers), do: nil

  defp refresh_in_progress_metadata(metadata) when is_map(metadata) do
    %{"status" => "refresh_in_progress"}
    |> maybe_put_safe_metadata("attempt_id", metadata[:attempt_id])
    |> maybe_put_safe_metadata("generation", metadata[:generation])
    |> maybe_put_safe_metadata("started_at", metadata[:started_at])
    |> maybe_put_safe_metadata("stale_after_ms", metadata[:stale_after_ms])
  end

  defp maybe_put_safe_metadata(attrs, key, value) when is_binary(value) or is_integer(value),
    do: Map.put(attrs, key, value)

  defp maybe_put_safe_metadata(attrs, _key, _value), do: attrs

  defp safe_refresh_reason(%{code: code}), do: to_string(code)
  defp safe_refresh_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_refresh_reason(_reason), do: "token_refresh_failed"

  defp create_same_assignment_retry_context(context) do
    case Accounting.create_attempt(context.reserved.request, context.assignment, %{
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
      response: %Req.Response{status: 200, headers: Map.get(response, :headers, [])},
      upstream_websocket_connection: Map.get(response, :upstream_websocket_connection)
    }
  end

  defp deliver_retry_exhausted_websocket_failure(
         %DispatchRequest{accounting_request: %{id: request_id}, writer: writer},
         upstream_response
       )
       when is_function(writer, 1) do
    request_id
    |> WebsocketCodec.stream_messages(Map.get(upstream_response, :body, ""))
    |> Enum.each(writer)
  end

  defp deliver_retry_exhausted_websocket_failure(_dispatch_request, _upstream_response), do: :ok

  @spec dispatch_websocket_request_with_owner_recovery(PreparedContext.t(), DispatchRequest.t()) ::
          {:ok, map()} | {:error, map()}
  defp dispatch_websocket_request_with_owner_recovery(prepared_context, dispatch_request) do
    case UpstreamDispatch.websocket_request(dispatch_request) do
      {:error, %{body: "", reason: :owner_unavailable}} = error ->
        retry_owner_websocket_request(prepared_context, dispatch_request, error)

      result ->
        result
    end
  end

  defp retry_owner_websocket_request(prepared_context, dispatch_request, original_error) do
    request_options = prepared_context.context.request_options

    if owner_forwarded_websocket_request?(request_options) do
      case Websocket.recover_websocket_owner_response_options(request_options) do
        {:ok, recovered_options} ->
          recovered_context = %{prepared_context.context | request_options: recovered_options}
          recovered_prepared_context = %{prepared_context | context: recovered_context}

          recovered_prepared_context
          |> retry_dispatch_request(dispatch_request)
          |> UpstreamDispatch.websocket_request()

        {:error, _reason} ->
          original_error
      end
    else
      original_error
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

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)
end
