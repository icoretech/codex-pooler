defmodule CodexPooler.Gateway.Transports.Streaming.StreamRelay do
  @moduledoc """
  Relays an async Req response into an HTTP or websocket writer.
  """

  alias CodexPooler.Gateway.Transports.Streaming.RetainedBody
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketBridgeStream

  @type relay_state :: term()
  @type stream_write_result ::
          {:ok, relay_state()}
          | {:error, term()}
          | {:retry_first_event, StreamProtocol.terminal_failure()}
          | {:terminal_stream_failure, StreamProtocol.terminal_failure()}
          | {:terminal_stream_failure, relay_state(), StreamProtocol.terminal_failure()}
  @type stream_finalization_result :: {:ok, term()} | {:error, term()}
  @type before_finalize_failure_result ::
          {:ok, relay_state(), iodata()}
          | {:success, relay_state(), iodata()}
          | {:failure, relay_state(), iodata(), term()}
          | {:error, term()}
  @type before_finalize_success_result ::
          {:ok, relay_state(), iodata()} | {:failure, relay_state(), iodata(), term()}
  @type first_event_retry_result :: {:ok, relay_state()} | {:error, term()}
  @type stream_relay_result :: {:ok, relay_state()} | {:error, term()}
  @type finalize_success :: (binary() -> stream_finalization_result())
  @type finalize_success_with_state :: (binary(), relay_state() -> stream_finalization_result())
  @type finalize_failure :: (binary(), term() -> stream_finalization_result())
  @type finalize_failure_with_state ::
          (binary(), term(), relay_state() -> stream_finalization_result())
  @type handler_map :: %{
          required(:finalize_success) => finalize_success() | finalize_success_with_state(),
          required(:finalize_failure) => finalize_failure() | finalize_failure_with_state(),
          required(:first_event_retry) => (relay_state(),
                                           binary(),
                                           StreamProtocol.terminal_failure() ->
                                             first_event_retry_result()),
          required(:write_chunk) => (relay_state(), binary() -> stream_write_result()),
          required(:write_keepalive) => (relay_state() -> {:ok, relay_state()} | {:error, term()}),
          optional(:before_finalize_failure) => (relay_state(), term() ->
                                                   before_finalize_failure_result()),
          optional(:before_finalize_success) => (relay_state() ->
                                                   before_finalize_success_result()),
          optional(:keepalive_interval_ms) => non_neg_integer()
        }

  @spec run(relay_state(), Req.Response.t(), handler_map()) :: stream_relay_result()
  def run(state, response, handlers) do
    handlers = validate_handlers!(handlers)
    stream_upstream(state, response, RetainedBody.empty(), handlers)
  end

  defp validate_handlers!(%{first_event_retry: callback} = handlers)
       when is_function(callback, 3),
       do: handlers

  defp validate_handlers!(_handlers) do
    raise ArgumentError, "StreamRelay requires a :first_event_retry handler"
  end

  defp stream_upstream(state, response, chunks, handlers) do
    ref = response.body.ref

    case Map.get(handlers, :keepalive_interval_ms, 0) do
      interval_ms when is_integer(interval_ms) and interval_ms > 0 ->
        receive do
          {^ref, _part} = message ->
            handle_stream_message(message, state, response, chunks, handlers)
        after
          interval_ms -> handle_stream_keepalive(state, response, chunks, handlers)
        end

      _disabled ->
        receive do
          {^ref, _part} = message ->
            handle_stream_message(message, state, response, chunks, handlers)
        end
    end
  end

  defp handle_stream_keepalive(state, response, chunks, handlers) do
    state
    |> handlers.write_keepalive.()
    |> stream_keepalive_result(state, chunks, response)
    |> finish_stream_parts(response, handlers)
  end

  defp stream_keepalive_result({:ok, state}, _previous_state, chunks, _response),
    do: {:cont, state, chunks}

  defp stream_keepalive_result({:error, reason}, state, chunks, response) do
    source_cancel(response)
    {:error, state, chunks, {:chunk, reason}}
  end

  defp handle_stream_message(message, state, response, chunks, handlers) do
    case source_parse(response, message) do
      {:ok, parts} -> stream_parts(state, response, chunks, parts, handlers)
      {:error, reason} -> finalize_stream_parse_error(state, chunks, reason, handlers)
      :unknown -> stream_upstream(state, response, chunks, handlers)
    end
  end

  defp finalize_stream_parse_error(state, chunks, reason, handlers) do
    reason = stream_parse_error_reason(reason)

    case run_before_finalize_failure_hook(state, chunks, reason, handlers) do
      {:success, state, chunks} ->
        stream_finalization_result(finalize_success(handlers, chunks, state), state)

      {:failure, state, chunks, reason} ->
        stream_finalization_result(finalize_failure(handlers, chunks, reason, state), state)
    end
  end

  defp stream_parse_error_reason(%Req.TransportError{reason: :timeout} = reason),
    do: {:upstream_idle_timeout, reason}

  defp stream_parse_error_reason(%Finch.TransportError{reason: :timeout} = reason),
    do: {:upstream_idle_timeout, reason}

  defp stream_parse_error_reason(
         %Finch.TransportError{
           source: %Mint.TransportError{reason: :timeout}
         } = reason
       ),
       do: {:upstream_idle_timeout, reason}

  defp stream_parse_error_reason(%Mint.TransportError{reason: :timeout} = reason),
    do: {:upstream_idle_timeout, reason}

  defp stream_parse_error_reason(reason), do: reason

  defp stream_parts(state, response, chunks, parts, handlers) do
    parts
    |> Enum.reduce_while({:cont, state, chunks}, &reduce_stream_part(&1, &2, response, handlers))
    |> finish_stream_parts(response, handlers)
  end

  defp reduce_stream_part({:data, data}, {:cont, state, chunks}, response, handlers) do
    state
    |> handlers.write_chunk.(data)
    |> stream_write_result(state, chunks, data, response)
  end

  defp reduce_stream_part({:trailers, _trailers}, {:cont, state, chunks}, _response, _handlers),
    do: {:cont, {:cont, state, chunks}}

  defp reduce_stream_part(:done, {:cont, state, chunks}, _response, _handlers),
    do: {:halt, {:done, state, chunks}}

  defp stream_write_result({:ok, state}, _previous_state, chunks, data, _response),
    do: {:cont, {:cont, state, append_stream_chunk(chunks, data)}}

  defp stream_write_result({:retry_first_event, failure}, state, chunks, data, response) do
    source_cancel(response)
    {:halt, {:retry_first_event, state, append_stream_chunk(chunks, data), failure}}
  end

  defp stream_write_result(
         {:terminal_stream_failure, next_state, failure},
         _state,
         chunks,
         data,
         response
       ) do
    source_cancel(response)
    reason = {:terminal_stream_failure, failure}
    {:halt, {:error, next_state, append_stream_chunk(chunks, data), reason}}
  end

  defp stream_write_result({:terminal_stream_failure, failure}, state, chunks, data, response) do
    source_cancel(response)
    reason = {:terminal_stream_failure, failure}
    {:halt, {:error, state, append_stream_chunk(chunks, data), reason}}
  end

  defp stream_write_result({:error, reason}, state, chunks, _data, response) do
    source_cancel(response)
    {:halt, {:error, state, chunks, {:chunk, reason}}}
  end

  defp append_stream_chunk(chunks, ""), do: chunks
  defp append_stream_chunk(chunks, data), do: RetainedBody.append(chunks, data)

  defp finish_stream_parts({:cont, state, chunks}, response, handlers),
    do: stream_upstream(state, response, chunks, handlers)

  defp finish_stream_parts({:done, state, chunks}, _response, handlers) do
    case run_before_finalize_success_hook(state, chunks, handlers) do
      {:ok, state, chunks} ->
        stream_finalization_result(finalize_success(handlers, chunks, state), state)

      {:failure, state, chunks, reason} ->
        stream_finalization_result(finalize_failure(handlers, chunks, reason, state), state)
    end
  end

  defp finish_stream_parts({:retry_first_event, state, chunks, failure}, _response, handlers) do
    handlers.first_event_retry.(state, chunks, failure)
  end

  defp finish_stream_parts({:error, state, chunks, reason}, _response, handlers) do
    case run_before_finalize_failure_hook(state, chunks, reason, handlers) do
      {:success, state, chunks} ->
        stream_finalization_result(finalize_success(handlers, chunks, state), state)

      {:failure, state, chunks, reason} ->
        stream_finalization_result(finalize_failure(handlers, chunks, reason, state), state)
    end
  end

  defp run_before_finalize_success_hook(state, chunks, handlers) do
    case Map.get(handlers, :before_finalize_success) do
      callback when is_function(callback, 1) ->
        case callback.(state) do
          {:ok, state, data} ->
            {:ok, state, append_stream_chunk(chunks, data)}

          {:failure, state, data, reason} ->
            {:failure, state, append_stream_chunk(chunks, data), reason}

          _other ->
            {:ok, state, chunks}
        end

      _callback ->
        {:ok, state, chunks}
    end
  end

  defp run_before_finalize_failure_hook(state, chunks, reason, handlers) do
    case Map.get(handlers, :before_finalize_failure) do
      callback when is_function(callback, 2) ->
        case callback.(state, reason) do
          {:success, state, data} ->
            {:success, state, append_stream_chunk(chunks, data)}

          {:failure, state, data, reason} ->
            {:failure, state, append_stream_chunk(chunks, data), reason}

          {:ok, state, data} ->
            {:failure, state, append_stream_chunk(chunks, data), reason}

          {:error, _write_reason} ->
            {:failure, state, chunks, reason}

          _other ->
            {:failure, state, chunks, reason}
        end

      _callback ->
        {:failure, state, chunks, reason}
    end
  end

  defp finalize_success(%{finalize_success: callback}, chunks, state)
       when is_function(callback, 2),
       do: callback.(chunks, state)

  defp finalize_success(%{finalize_success: callback}, chunks, _state)
       when is_function(callback, 1),
       do: callback.(chunks)

  defp finalize_failure(%{finalize_failure: callback}, chunks, reason, state)
       when is_function(callback, 3),
       do: callback.(chunks, reason, state)

  defp finalize_failure(%{finalize_failure: callback}, chunks, reason, _state)
       when is_function(callback, 2),
       do: callback.(chunks, reason)

  defp stream_finalization_result({:ok, _finalized}, state), do: {:ok, state}
  defp stream_finalization_result({:error, _gateway_error} = error, _state), do: error

  # The relay consumes exactly one message shape: `{response.body.ref, part}`.
  # A fabricated response whose body is a WebsocketBridgeStream keeps that
  # shape while sourcing parts from an upstream websocket turn instead of Req.
  defp source_parse(%Req.Response{body: %WebsocketBridgeStream{} = stream}, message),
    do: WebsocketBridgeStream.parse_message(stream, message)

  defp source_parse(response, message), do: Req.parse_message(response, message)

  defp source_cancel(%Req.Response{body: %WebsocketBridgeStream{} = stream}),
    do: WebsocketBridgeStream.cancel(stream)

  defp source_cancel(response), do: Req.cancel_async_response(response)
end
