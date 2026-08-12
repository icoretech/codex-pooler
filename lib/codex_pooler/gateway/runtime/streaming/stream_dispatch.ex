defmodule CodexPooler.Gateway.Runtime.Streaming.StreamDispatch do
  @moduledoc """
  Builds and runs downstream stream relays for gateway runtime dispatch.
  """

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Facade.TurnState
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Gateway.Runtime.Dispatch.ResponseContext
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Runtime.Streaming.DownstreamStream
  alias CodexPooler.Gateway.Runtime.Streaming.OpenAIStreamCollector
  alias CodexPooler.Gateway.Runtime.Streaming.StreamAttempt
  alias CodexPooler.Gateway.Runtime.Streaming.StreamLifecycle
  alias CodexPooler.Gateway.Runtime.Streaming.StreamUsageObserver
  alias CodexPooler.Gateway.Runtime.Streaming.Types, as: StreamTypes
  alias CodexPooler.Gateway.Transports.ModelUnavailability
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Streaming.StreamRelay
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketBridgeStream
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec

  @sse_keepalive_frame ": keepalive\n\n"
  @backend_turn_state_relay_endpoints [
    "/backend-api/codex/responses",
    "/backend-api/codex/responses/compact"
  ]

  @type callbacks :: %{
          required(:finalization_callbacks) => StreamLifecycle.finalization_callbacks(),
          optional(:http_first_event_retry) => StreamLifecycle.http_first_event_retry()
        }
  @type stream_dispatch_result :: StreamTypes.stream_dispatch_result()

  @spec streaming_result(Req.Response.t(), SelectedCandidateContext.t(), callbacks()) ::
          stream_dispatch_result()
  def streaming_result(response, %SelectedCandidateContext{} = context, callbacks) do
    finalization_callbacks = Map.fetch!(callbacks, :finalization_callbacks)

    cond do
      OpenAIStreamCollector.collect_image?(context.request_options) ->
        OpenAIStreamCollector.collect_image(response, context, finalization_callbacks)

      OpenAIStreamCollector.collect_response?(context.request_options) ->
        OpenAIStreamCollector.collect_response(response, context, finalization_callbacks)

      true ->
        relay_streaming_result(response, context, callbacks)
    end
  end

  defp relay_streaming_result(response, %SelectedCandidateContext{} = context, callbacks) do
    result = %{
      status: response.status,
      headers: stream_headers(response, context)
    }

    case context.request_options.transport.websocket_writer do
      writer when is_function(writer, 1) ->
        Map.put(
          result,
          :websocket_stream,
          websocket_stream_result(response, writer, context, callbacks)
        )

      _writer ->
        Map.put(result, :stream, stream_result(response, context, callbacks))
    end
  end

  defp stream_result(response, %SelectedCandidateContext{} = context, callbacks) do
    fn conn ->
      response_context = %ResponseContext{context: context, response: response}

      StreamRelay.run(
        stream_relay_state(conn, context.request_options, response),
        response,
        stream_relay_handlers(response_context, response, :http_conn, callbacks)
      )
      |> http_stream_result()
    end
  end

  defp websocket_stream_result(response, writer, %SelectedCandidateContext{} = context, callbacks) do
    fn ->
      response_context = %ResponseContext{context: context, response: response}

      relay_result =
        StreamRelay.run(
          stream_relay_state(:websocket, context.request_options, response),
          response,
          stream_relay_handlers(response_context, response, {:websocket, writer}, callbacks)
        )

      relay_result
      |> case do
        {:ok, %{websocket_sse_buffer: buffer}} ->
          if WebsocketCodec.failed_stream_buffer?(buffer) do
            {:error,
             %{
               status: 502,
               code: "upstream_stream_error",
               message: "websocket stream failed"
             }}
          else
            :ok
          end

        {:ok, _state} ->
          :ok

        {:error, _gateway_error} = error ->
          error
      end
    end
  end

  defp stream_relay_handlers(
         %ResponseContext{} = response_context,
         _response,
         :http_conn,
         callbacks
       ) do
    response_context
    |> StreamLifecycle.lifecycle_handlers(callbacks,
      first_event_retry: http_first_event_retry(response_context, callbacks)
    )
    |> Map.merge(%{
      write_chunk: http_stream_writer(response_context),
      write_keepalive: http_sse_keepalive_writer(response_context),
      before_finalize_failure: http_stream_terminal_failure_writer(response_context),
      before_finalize_success: http_stream_terminal_success_hook(response_context),
      keepalive_interval_ms: sse_keepalive_interval_ms(response_context)
    })
  end

  defp stream_relay_handlers(
         %ResponseContext{} = response_context,
         _response,
         {:websocket, writer},
         callbacks
       ) do
    response_context
    |> StreamLifecycle.lifecycle_handlers(callbacks,
      first_event_retry: StreamLifecycle.fail_first_event_handler(response_context)
    )
    # D7 surface isolation: absence of `before_finalize_failure` and
    # `before_finalize_success` keys prevents the HTTP synthetic terminal from
    # leaking onto the GET /v1/responses websocket. Do not add either key here.
    |> Map.merge(%{
      keepalive_interval_ms: 0,
      write_keepalive: fn state -> {:ok, state} end,
      write_chunk: websocket_stream_writer(response_context, writer)
    })
  end

  defp http_stream_result({:ok, %{target: _target} = state}), do: {:ok, relay_target(state)}
  defp http_stream_result({:ok, _finalized} = result), do: result
  defp http_stream_result({:error, _gateway_error} = error), do: error

  defp websocket_stream_writer(%ResponseContext{context: context} = response_context, writer) do
    request = context.reserved.request

    fn state, data ->
      {data, state} =
        normalize_stream_data(response_context, state, data, &visible_websocket_data?/1)

      case DownstreamStream.terminal_outcome(state) do
        {:failed, %{code: code} = failure}
        when code in ["upstream_stream_invalid", "upstream_stream_too_large"] ->
          {messages, failed_buffer} =
            WebsocketCodec.stream_messages(request, "", websocket_sse_buffer(state))

          Enum.each(messages, writer)

          settlement_failure = %{
            failure
            | code: "upstream_stream_error",
              upstream_code: nil,
              upstream_error_param: nil
          }

          {:terminal_stream_failure, put_websocket_sse_buffer(state, failed_buffer),
           settlement_failure}

        nil when data == "" ->
          # A valid SSE record may span several upstream chunks. The native
          # projector retains that residue in `state` and deliberately emits
          # no bytes until the record is complete; an empty normalized chunk
          # is therefore not itself malformed websocket data.
          {:ok, state}

        _outcome ->
          {messages, websocket_sse_buffer} =
            WebsocketCodec.stream_messages(request, data, websocket_sse_buffer(state))

          Enum.each(messages, writer)

          if WebsocketCodec.failed_stream_buffer?(websocket_sse_buffer) do
            {:error, {:upstream_stream_interrupted, :invalid_websocket_stream_data}}
          else
            {:ok, put_websocket_sse_buffer(state, websocket_sse_buffer)}
          end
      end
    end
  end

  defp mark_visible_output(request) do
    SessionContinuity.mark_codex_turn_visible(request)
  end

  defp visible_websocket_data?(data), do: is_binary(data) and data != ""

  defp stream_relay_state(:websocket = target, %RequestOptions{} = opts, response) do
    target
    |> base_stream_relay_state(opts, response)
    |> put_first_event_state(StreamAttempt.first_event_state())
    |> put_rate_limit_state(RateLimitObserver.event_state())
    |> put_usage_state(StreamUsageObserver.new())
    |> Map.put(:websocket_sse_buffer, "")
  end

  defp stream_relay_state(target, %RequestOptions{} = opts, response) do
    target
    |> base_stream_relay_state(opts, response)
    |> put_first_event_state(StreamAttempt.first_event_state())
    |> put_rate_limit_state(RateLimitObserver.event_state())
    |> put_usage_state(StreamUsageObserver.new())
  end

  defp base_stream_relay_state(target, %RequestOptions{} = opts, response) do
    DownstreamStream.initial_state(target, opts, stream_source(response))
  end

  @spec stream_source(Req.Response.t()) :: DownstreamStream.source()
  defp stream_source(%Req.Response{body: %WebsocketBridgeStream{}}), do: :websocket_bridge
  defp stream_source(%Req.Response{}), do: :http

  defp relay_target(%{target: target}), do: target

  defp first_event_state(%{first_event: %{} = state}), do: state

  defp put_first_event_state(%{} = state, %{} = first_event_state),
    do: Map.put(state, :first_event, first_event_state)

  defp rate_limit_state(%{rate_limit: %{buffer: buffer}}) when is_binary(buffer),
    do: %{buffer: buffer}

  defp put_rate_limit_state(%{} = state, %{buffer: buffer}) when is_binary(buffer),
    do: Map.put(state, :rate_limit, %{buffer: buffer})

  defp usage_state(%{usage_observer: %{} = usage_state}), do: usage_state
  defp usage_state(_state), do: StreamUsageObserver.new()

  defp put_usage_state(%{} = state, %{} = usage_state),
    do: Map.put(state, :usage_observer, usage_state)

  defp websocket_sse_buffer(%{websocket_sse_buffer: buffer}) when is_binary(buffer), do: buffer

  defp put_websocket_sse_buffer(%{} = state, buffer) when is_binary(buffer),
    do: Map.put(state, :websocket_sse_buffer, buffer)

  defp update_relay_target(%{target: target} = state, fun) when is_function(fun, 1) do
    case fun.(target) do
      {:ok, target} -> {:ok, %{state | target: target}}
      {:error, _reason} = error -> error
    end
  end

  # Compact streams classify like every other SSE stream — a compact terminal
  # failure must finalize as a failure, never as a relayed success. Compactness
  # only changes what happens on a retryable first event, and that decision
  # lives in StreamLifecycle.first_event_retry_handler (compact model misses
  # finalize without retry or health mutation).
  defp http_stream_writer(%ResponseContext{response: response} = response_context) do
    if transformed_facade_stream?(response_context.context.request_options) do
      transformed_facade_http_stream_writer(response_context)
    else
      standard_http_stream_writer(response_context, response)
    end
  end

  defp standard_http_stream_writer(response_context, response) do
    sse_response? = sse_response?(response)

    assignment_source? =
      sse_response? and
        ModelMetadata.assignment_source?(
          response_context.context.model,
          response_context.context.assignment.id
        )

    fn conn, data ->
      if sse_response? do
        previous_state = first_event_state(conn)

        {classification, first_event_state} =
          StreamAttempt.classify_first_event(
            data,
            previous_state,
            assignment_source?
          )

        conn = put_first_event_state(conn, first_event_state)

        classification
        |> attach_withheld_body(previous_state, data)
        |> handle_classified_stream_data(response_context, conn, data)
      else
        write_stream_data(response_context, conn, data)
      end
    end
  end

  defp transformed_facade_http_stream_writer(
         %ResponseContext{context: context} = response_context
       ) do
    assignment_advertised? =
      ModelMetadata.assignment_source?(context.model, context.assignment.id)

    fn state, data ->
      visible_before? = transformed_facade_visible_seen?(state, context.request_options)

      {downstream_data, next_state} =
        observe_and_normalize_stream_data(response_context, state, data)

      visible_after? = transformed_facade_visible_seen?(next_state, context.request_options)

      case DownstreamStream.terminal_outcome(next_state) do
        {:failed, failure}
        when not visible_after? and not visible_before? ->
          if retryable_transformed_first_failure?(failure, assignment_advertised?) do
            {:retry_first_event, failure}
          else
            write_transformed_terminal_failure(
              response_context,
              next_state,
              downstream_data,
              failure,
              visible_before?,
              visible_after?
            )
          end

        {:failed, failure} ->
          write_transformed_terminal_failure(
            response_context,
            next_state,
            downstream_data,
            failure,
            visible_before?,
            visible_after?
          )

        _outcome ->
          write_transformed_data(
            response_context,
            next_state,
            downstream_data,
            visible_before?,
            visible_after?
          )
      end
    end
  end

  defp write_transformed_terminal_failure(
         response_context,
         state,
         data,
         failure,
         visible_before?,
         visible_after?
       ) do
    case write_transformed_data(
           response_context,
           state,
           data,
           visible_before?,
           visible_after?
         ) do
      {:ok, state} -> {:terminal_stream_failure, state, failure}
      {:error, _reason} = error -> error
    end
  end

  defp write_transformed_data(
         %ResponseContext{context: context},
         state,
         data,
         visible_before?,
         visible_after?
       ) do
    case write_normalized_stream_data(context.request_options, state, data) do
      {:ok, state} ->
        state =
          if not visible_before? and visible_after? do
            mark_visible_output(context.reserved.request)
            Map.put(state, :visible_output_marked?, true)
          else
            state
          end

        {:ok, state}

      {:error, _reason} = error ->
        error
    end
  end

  defp retryable_transformed_first_failure?(failure, assignment_advertised?) do
    not ErrorCodes.previous_response_miss_code?(Map.get(failure, :upstream_code)) and
      (ErrorCodes.retryable_first_event_code?(Map.get(failure, :code)) or
         ModelUnavailability.terminal_failure?(failure, assignment_advertised?))
  end

  defp transformed_facade_stream?(request_options) do
    DownstreamStream.public_ollama_stream?(request_options) or
      DownstreamStream.public_anthropic_stream?(request_options)
  end

  defp transformed_facade_visible_seen?(state, request_options) do
    cond do
      DownstreamStream.public_ollama_stream?(request_options) ->
        DownstreamStream.public_ollama_visible_seen?(state)

      DownstreamStream.public_anthropic_stream?(request_options) ->
        DownstreamStream.public_anthropic_visible_seen?(state)

      true ->
        false
    end
  end

  # The relay retains every streamed part — including non-visible blocks that
  # were already written downstream — so the exhaustion path must not replay
  # the whole retained body. The classifier's buffer plus the intercepted chunk
  # is exactly the content the client has not received yet; carry it on the
  # failure so final delivery writes only that.
  defp attach_withheld_body({:retry, failure}, %{buffer: buffer}, data),
    do: {:retry, Map.put(failure, :withheld_body, buffer <> data)}

  defp attach_withheld_body(classification, _previous_state, _data), do: classification

  # The first-event classifier can hold a large first event until the stream
  # ends, so both finalize hooks must flush the held bytes through the normal
  # write path first — a structurally complete trailing terminal without a
  # final separator is only recoverable from that buffer.
  defp http_stream_terminal_failure_writer(%ResponseContext{} = response_context) do
    fn state, reason ->
      case flush_buffered_first_event(response_context, state) do
        {:ok, state} -> finalize_http_stream_failure(state, reason)
        {:chunk_error, state, _chunk_reason} -> finalize_http_stream_failure(state, reason)
      end
    end
  end

  defp finalize_http_stream_failure(state, reason) do
    case {DownstreamStream.terminal_outcome(state), reason} do
      {terminal, _reason} when terminal in [:completed, :incomplete] ->
        {:success, state, ""}

      {{:failed, _failure}, {:terminal_stream_failure, _existing_failure}} ->
        {:failure, state, "", reason}

      {{:failed, %{} = failure}, _reason} ->
        {:failure, state, "", {:terminal_stream_failure, failure}}

      {{:failed, _failure}, _reason} ->
        {:failure, state, "", reason}

      {_missing_terminal, _reason} ->
        http_stream_missing_terminal_failure_result(state, reason)
    end
  end

  defp http_stream_missing_terminal_failure_result(state, reason) do
    tagged_reason = DownstreamStream.terminal_missing_interruption_reason(state, reason)

    case write_public_openai_responses_terminal_failure(state, reason) do
      {:ok, state, ""} when is_tuple(tagged_reason) -> {:failure, state, "", tagged_reason}
      {:ok, state, ""} -> {:ok, state, ""}
      {:ok, state, data} -> {:failure, state, data, tagged_reason}
      {:error, _reason} = error -> error
    end
  end

  defp http_stream_terminal_success_hook(%ResponseContext{} = response_context) do
    fn state ->
      case flush_buffered_first_event(response_context, state) do
        {:ok, state} -> finalize_http_stream_success(state)
        {:chunk_error, state, reason} -> finalize_flushed_chunk_error(state, reason)
      end
    end
  end

  defp finalize_http_stream_success(state) do
    case DownstreamStream.terminal_outcome(state) do
      {:failed, %{} = failure} ->
        {:failure, state, "", {:terminal_stream_failure, failure}}

      {:failed, _failure} ->
        {:failure, state, "", :upstream_stream_interrupted}

      terminal when terminal in [:completed, :incomplete] ->
        {:ok, state, ""}

      _missing_terminal ->
        missing_public_openai_responses_terminal_result(state)
    end
  end

  defp missing_public_openai_responses_terminal_result(state) do
    case write_public_openai_responses_terminal_failure(state, :upstream_stream_interrupted) do
      {:ok, state, ""} -> {:ok, state, ""}
      {:ok, state, data} -> {:failure, state, data, :upstream_stream_interrupted}
      {:error, _reason} -> {:failure, state, "", :upstream_stream_interrupted}
    end
  end

  defp write_public_openai_responses_terminal_failure(state, reason) do
    case DownstreamStream.synthetic_terminal_failure(state, reason) do
      {nil, state} ->
        {:ok, state, ""}

      {data, state} ->
        # D6 hazard 2: Synthetic bytes must go straight to Plug.Conn.chunk/2,
        # never through normalize_block/2, because their own server_error frame
        # would canonicalize back to response.failed.
        case update_relay_target(state, &Plug.Conn.chunk(&1, data)) do
          {:ok, state} -> {:ok, state, data}
          {:error, _reason} = error -> error
        end
    end
  end

  # A flush-time chunk error must keep both the advanced parser/usage state
  # and the original write reason: `{:chunk, reason}` is the canonical
  # downstream-write failure shape the finalization layer classifies (for
  # example `{:chunk, :closed}` becomes client_disconnected).
  defp flush_buffered_first_event(%ResponseContext{} = response_context, state) do
    case first_event_state(state) do
      %{buffer: ""} ->
        {:ok, state}

      %{buffer: buffer} = first_event ->
        state = put_first_event_state(state, %{first_event | buffer: ""})
        write_flushed_first_event(response_context, state, buffer)
    end
  end

  defp write_flushed_first_event(%ResponseContext{} = response_context, state, buffer) do
    {downstream_data, state} =
      normalize_stream_data(
        response_context,
        state,
        buffer,
        &StreamProtocol.stream_data_visible?/1
      )

    if downstream_data == "" do
      {:ok, state}
    else
      case update_relay_target(state, &Plug.Conn.chunk(&1, downstream_data)) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:chunk_error, state, reason}
      end
    end
  end

  # Mirrors finalize_http_stream_failure precedence for a flush that parsed
  # data but could not write it: an upstream terminal decoded from the flushed
  # buffer still settles the turn, and only a terminal-less flush classifies as
  # the downstream write failure. No synthetic terminal is attempted because
  # the downstream connection is already gone.
  defp finalize_flushed_chunk_error(state, reason) do
    case DownstreamStream.terminal_outcome(state) do
      terminal when terminal in [:completed, :incomplete] ->
        {:ok, state, ""}

      {:failed, %{} = failure} ->
        {:failure, state, "", {:terminal_stream_failure, failure}}

      _other ->
        {:failure, state, "", {:chunk, reason}}
    end
  end

  defp http_sse_keepalive_writer(%ResponseContext{} = response_context) do
    if not transformed_facade_stream?(response_context.context.request_options) and
         sse_response?(response_context.response) do
      &write_sse_keepalive/1
    else
      fn conn -> {:ok, conn} end
    end
  end

  defp write_sse_keepalive(conn) do
    if keepalive_allowed?(conn) do
      update_relay_target(conn, &Plug.Conn.chunk(&1, @sse_keepalive_frame))
    else
      {:ok, conn}
    end
  end

  defp keepalive_allowed?(state) do
    first_event_state(state).buffer == "" and DownstreamStream.keepalive_allowed?(state)
  end

  defp sse_keepalive_interval_ms(%ResponseContext{} = response_context) do
    if not transformed_facade_stream?(response_context.context.request_options) and
         sse_response?(response_context.response),
       do: OperationalSettings.current().sse_keepalive_interval_ms,
       else: 0
  end

  defp handle_classified_stream_data(
         {:retry, failure},
         _response_context,
         _conn,
         _data
       ),
       do: {:retry_first_event, failure}

  defp handle_classified_stream_data(
         {:write, data},
         response_context,
         conn,
         _input
       ),
       do: write_stream_data(response_context, conn, data)

  defp handle_classified_stream_data(
         {:write_terminal_failure, data, failure},
         response_context,
         conn,
         _input
       ) do
    case write_stream_data(response_context, conn, data) do
      {:ok, conn} -> {:terminal_stream_failure, conn, failure}
      {:error, _reason} = error -> error
    end
  end

  defp handle_classified_stream_data(
         :buffered,
         _response_context,
         conn,
         _data
       ),
       do: {:ok, conn}

  defp sse_response?(response) do
    response
    |> header("content-type")
    |> Kernel.||("text/event-stream")
    |> String.contains?("text/event-stream")
  end

  defp write_stream_data(%ResponseContext{} = response_context, conn, data) do
    {downstream_data, conn} =
      normalize_stream_data(response_context, conn, data, &StreamProtocol.stream_data_visible?/1)

    write_normalized_stream_data(
      response_context.context.request_options,
      conn,
      downstream_data
    )
  end

  defp write_normalized_stream_data(_request_options, state, ""), do: {:ok, state}

  defp write_normalized_stream_data(request_options, state, data) do
    if DownstreamStream.public_ollama_stream?(request_options) do
      write_ndjson_lines(state, data)
    else
      update_relay_target(state, &Plug.Conn.chunk(&1, data))
    end
  end

  defp write_ndjson_lines(state, data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, state}, fn line, {:ok, state} ->
      case update_relay_target(state, &Plug.Conn.chunk(&1, line <> "\n")) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reset_first_event_retry_state(conn) do
    conn
    |> put_first_event_state(StreamAttempt.first_event_state())
    |> put_rate_limit_state(RateLimitObserver.event_state())
    |> put_usage_state(StreamUsageObserver.new())
  end

  defp http_first_event_retry(%ResponseContext{} = response_context, callbacks) do
    callbacks
    |> Map.fetch!(:http_first_event_retry)
    |> then(fn retry ->
      retry.(response_context,
        reset_state: &reset_first_event_retry_state/1,
        write_final_event: &write_final_first_event(response_context, &1, &2),
        stream_candidate: &stream_candidate_result/2
      )
    end)
  end

  defp write_final_first_event(response_context, conn, data) do
    case write_stream_data(response_context, conn, data) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} = error -> error
    end
  end

  defp stream_candidate_result({:retry, nil}, conn), do: {:ok, conn}
  defp stream_candidate_result({:retry, reason}, _conn), do: {:error, reason}

  defp stream_candidate_result({:ok, %{stream: stream}}, conn) do
    case stream.(relay_target(conn)) do
      {:ok, %Plug.Conn{} = target} -> {:ok, %{conn | target: target}}
      {:ok, _finalized} -> {:ok, conn}
      {:error, _gateway_error} = error -> error
    end
  end

  defp stream_candidate_result({:ok, %{websocket_stream: stream}}, conn) do
    case stream.() do
      :ok -> {:ok, conn}
      {:error, _gateway_error} = error -> error
    end
  end

  defp stream_candidate_result({:ok, %{raw_body: body}}, conn) when is_binary(body),
    do: update_relay_target(conn, &Plug.Conn.chunk(&1, body))

  defp stream_candidate_result({:ok, %{body: body}}, conn) when is_map(body),
    do: update_relay_target(conn, &Plug.Conn.chunk(&1, Jason.encode!(body)))

  defp stream_candidate_result({:ok, _result}, conn), do: {:ok, conn}
  defp stream_candidate_result({:error, reason}, _conn), do: {:error, reason}

  defp normalize_stream_data(
         %ResponseContext{context: context} = response_context,
         state,
         data,
         visible_data?
       )
       when is_function(visible_data?, 1) do
    %{reserved: reserved} = context

    {downstream_data, state} =
      observe_and_normalize_stream_data(response_context, state, data)

    state = maybe_mark_visible_output(state, reserved.request, downstream_data, visible_data?)

    {downstream_data, state}
  end

  defp observe_and_normalize_stream_data(
         %ResponseContext{context: context},
         state,
         data
       ) do
    %{identity: identity, payload: payload, request_options: opts} = context

    {:ok, rate_limit_state} =
      RateLimitObserver.record_events(identity, data, rate_limit_state(state))

    state = put_rate_limit_state(state, rate_limit_state)

    state = put_usage_state(state, StreamUsageObserver.observe(usage_state(state), data))

    DownstreamStream.normalize_data(
      data,
      DownstreamStream.endpoint(payload, opts),
      opts,
      state
    )
  end

  defp maybe_mark_visible_output(
         %{visible_output_marked?: true} = state,
         _request,
         _data,
         _visible_data?
       ),
       do: state

  defp maybe_mark_visible_output(state, request, data, visible_data?) do
    if visible_data?.(data) do
      mark_visible_output(request)
      Map.put(state, :visible_output_marked?, true)
    else
      state
    end
  end

  defp stream_headers(response, %SelectedCandidateContext{} = context) do
    content_type =
      cond do
        DownstreamStream.public_ollama_stream?(context.request_options) ->
          "application/x-ndjson"

        DownstreamStream.public_anthropic_stream?(context.request_options) ->
          "text/event-stream"

        true ->
          header(response, "content-type") || "text/event-stream"
      end

    [{"cache-control", "no-cache"}, {"content-type", content_type}]
    |> maybe_put_backend_turn_state_response_header(response, context)
    |> maybe_put_backend_models_etag(context)
  end

  defp maybe_put_backend_models_etag(
         headers,
         %SelectedCandidateContext{
           route_state: %RouteState{} = route_state,
           request_options: %RequestOptions{
             transport: %{
               transport: "http_sse",
               upstream_endpoint: "/backend-api/codex/responses",
               websocket_writer: nil
             },
             openai_compatibility: %{source_endpoint: nil, openai_chat_payload: nil}
           }
         }
       ) do
    case RouteState.codex_models_etag(route_state) do
      etag when is_binary(etag) -> [{"x-models-etag", etag} | headers]
      _etag -> headers
    end
  end

  defp maybe_put_backend_models_etag(headers, _context), do: headers

  defp maybe_put_backend_turn_state_response_header(
         headers,
         response,
         %SelectedCandidateContext{
           request_options: %RequestOptions{
             transport: %{upstream_endpoint: endpoint},
             openai_compatibility: %{source_endpoint: nil, openai_chat_payload: nil}
           }
         } = context
       )
       when endpoint in @backend_turn_state_relay_endpoints do
    case header(response, "x-codex-turn-state") do
      value when is_binary(value) ->
        case TurnState.mint_for_context(value, context) do
          {:ok, public} -> [{"x-codex-turn-state", public} | headers]
          {:error, :invalid} -> headers
        end

      _value ->
        headers
    end
  end

  defp maybe_put_backend_turn_state_response_header(headers, _response, _request_options) do
    headers
  end

  defp header(%Req.Response{headers: headers}, key) do
    headers
    |> Enum.find_value(fn {name, values} ->
      if String.downcase(name) == key, do: List.first(values)
    end)
  end

  defp header(headers, key) when is_list(headers) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == key, do: to_string(value)
    end)
  end
end
