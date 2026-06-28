defmodule CodexPooler.Gateway.Runtime.Streaming.StreamDispatch do
  @moduledoc """
  Builds and runs downstream stream relays for gateway runtime dispatch.
  """

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.ResponseContext
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Runtime.Streaming.DownstreamStream
  alias CodexPooler.Gateway.Runtime.Streaming.OpenAIStreamCollector
  alias CodexPooler.Gateway.Runtime.Streaming.StreamAttempt
  alias CodexPooler.Gateway.Runtime.Streaming.StreamLifecycle
  alias CodexPooler.Gateway.Runtime.Streaming.Types, as: StreamTypes
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamRelay
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
      headers: stream_headers(response, context.request_options)
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
        stream_relay_state(conn, context.request_options),
        response,
        stream_relay_handlers(response_context, response, :http_conn, callbacks)
      )
      |> http_stream_result()
    end
  end

  defp websocket_stream_result(response, writer, %SelectedCandidateContext{} = context, callbacks) do
    fn ->
      response_context = %ResponseContext{context: context, response: response}

      StreamRelay.run(
        stream_relay_state(:websocket, context.request_options),
        response,
        stream_relay_handlers(response_context, response, {:websocket, writer}, callbacks)
      )
      |> case do
        {:ok, _state} -> :ok
        {:error, _gateway_error} = error -> error
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
      write_keepalive: http_sse_keepalive_writer(response_context.response),
      before_finalize_failure: http_stream_terminal_failure_writer(),
      before_finalize_success: http_stream_terminal_success_hook(),
      keepalive_interval_ms: sse_keepalive_interval_ms(response_context.response)
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

      {messages, websocket_sse_buffer} =
        WebsocketCodec.stream_messages(request, data, websocket_sse_buffer(state))

      Enum.each(messages, writer)

      {:ok, put_websocket_sse_buffer(state, websocket_sse_buffer)}
    end
  end

  defp mark_visible_output(request) do
    SessionContinuity.mark_codex_turn_visible(request)
  end

  defp visible_websocket_data?(data), do: is_binary(data) and data != ""

  defp stream_relay_state(:websocket = target, %RequestOptions{} = opts) do
    target
    |> base_stream_relay_state(opts)
    |> put_first_event_state(StreamAttempt.first_event_state())
    |> put_rate_limit_state(RateLimitObserver.event_state())
    |> Map.put(:websocket_sse_buffer, "")
  end

  defp stream_relay_state(target, %RequestOptions{} = opts) do
    target
    |> base_stream_relay_state(opts)
    |> put_first_event_state(StreamAttempt.first_event_state())
    |> put_rate_limit_state(RateLimitObserver.event_state())
  end

  defp base_stream_relay_state(target, %RequestOptions{} = opts) do
    DownstreamStream.initial_state(target, opts)
  end

  defp relay_target(%{target: target}), do: target

  defp first_event_state(%{first_event: %{} = state}), do: state

  defp put_first_event_state(%{} = state, %{} = first_event_state),
    do: Map.put(state, :first_event, first_event_state)

  defp rate_limit_state(%{rate_limit: %{buffer: buffer}}) when is_binary(buffer),
    do: %{buffer: buffer}

  defp put_rate_limit_state(%{} = state, %{buffer: buffer}) when is_binary(buffer),
    do: Map.put(state, :rate_limit, %{buffer: buffer})

  defp websocket_sse_buffer(%{websocket_sse_buffer: buffer}) when is_binary(buffer), do: buffer

  defp put_websocket_sse_buffer(%{} = state, buffer) when is_binary(buffer),
    do: Map.put(state, :websocket_sse_buffer, buffer)

  defp update_relay_target(%{target: target} = state, fun) when is_function(fun, 1) do
    case fun.(target) do
      {:ok, target} -> {:ok, %{state | target: target}}
      {:error, _reason} = error -> error
    end
  end

  defp http_stream_writer(%ResponseContext{response: response} = response_context) do
    fn conn, data ->
      if sse_response?(response) do
        {classification, first_event_state} =
          StreamAttempt.classify_first_event(data, first_event_state(conn))

        conn = put_first_event_state(conn, first_event_state)

        handle_classified_stream_data(classification, response_context, conn, data)
      else
        write_stream_data(response_context, conn, data)
      end
    end
  end

  defp http_stream_terminal_failure_writer do
    fn state, reason ->
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
  end

  defp http_stream_missing_terminal_failure_result(state, reason) do
    tagged_reason = DownstreamStream.terminal_missing_interruption_reason(state, reason)

    case write_public_openai_responses_terminal_failure(state, reason) do
      {:ok, state, ""} -> {:ok, state, ""}
      {:ok, state, data} -> {:failure, state, data, tagged_reason}
      {:error, _reason} = error -> error
    end
  end

  defp http_stream_terminal_success_hook do
    fn state ->
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
        case update_relay_target(state, &Plug.Conn.chunk(&1, data)) do
          {:ok, state} -> {:ok, state, data}
          {:error, _reason} = error -> error
        end
    end
  end

  defp http_sse_keepalive_writer(response) do
    if sse_response?(response) do
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

  defp sse_keepalive_interval_ms(response) do
    if sse_response?(response),
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

    if downstream_data == "" do
      {:ok, conn}
    else
      update_relay_target(conn, &Plug.Conn.chunk(&1, downstream_data))
    end
  end

  defp reset_first_event_retry_state(conn) do
    conn
    |> put_first_event_state(StreamAttempt.first_event_state())
    |> put_rate_limit_state(RateLimitObserver.event_state())
  end

  defp http_first_event_retry(%ResponseContext{} = response_context, callbacks) do
    callbacks
    |> Map.fetch!(:http_first_event_retry)
    |> then(fn retry ->
      retry.(response_context,
        reset_state: &reset_first_event_retry_state/1,
        stream_candidate: &stream_candidate_result/2
      )
    end)
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

  defp stream_candidate_result({:ok, _result}, conn), do: {:ok, conn}
  defp stream_candidate_result({:error, reason}, _conn), do: {:error, reason}

  defp normalize_stream_data(
         %ResponseContext{context: context},
         state,
         data,
         visible_data?
       )
       when is_function(visible_data?, 1) do
    %{reserved: reserved, identity: identity, payload: payload, request_options: opts} = context

    {:ok, rate_limit_state} =
      RateLimitObserver.record_events(identity, data, rate_limit_state(state))

    state = put_rate_limit_state(state, rate_limit_state)

    state = maybe_mark_visible_output(state, reserved.request, visible_data?.(data))

    DownstreamStream.normalize_data(
      data,
      DownstreamStream.endpoint(payload, opts),
      opts,
      state
    )
  end

  defp maybe_mark_visible_output(%{visible_output_marked?: true} = state, _request, _visible?),
    do: state

  defp maybe_mark_visible_output(state, request, true) do
    mark_visible_output(request)
    Map.put(state, :visible_output_marked?, true)
  end

  defp maybe_mark_visible_output(state, _request, _visible?), do: state

  defp stream_headers(response, request_options) do
    content_type = header(response, "content-type") || "text/event-stream"

    [{"cache-control", "no-cache"}, {"content-type", content_type}]
    |> maybe_put_backend_turn_state_response_header(response, request_options)
  end

  defp maybe_put_backend_turn_state_response_header(
         headers,
         response,
         %RequestOptions{
           transport: %{upstream_endpoint: endpoint},
           openai_compatibility: %{source_endpoint: nil, openai_chat_payload: nil}
         }
       )
       when endpoint in @backend_turn_state_relay_endpoints do
    case header(response, "x-codex-turn-state") do
      value when is_binary(value) -> [{"x-codex-turn-state", value} | headers]
      _value -> headers
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
