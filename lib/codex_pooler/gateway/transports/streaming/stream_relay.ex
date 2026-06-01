defmodule CodexPooler.Gateway.Transports.Streaming.StreamRelay do
  @moduledoc """
  Relays an async Req response into an HTTP or websocket writer.
  """

  alias CodexPooler.Gateway.Transports.Streaming.RetainedBody
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @type relay_state :: term()
  @type stream_write_result ::
          {:ok, relay_state()}
          | {:error, term()}
          | {:retry_first_event, StreamProtocol.terminal_failure()}
          | {:terminal_stream_failure, StreamProtocol.terminal_failure()}
          | {:terminal_stream_failure, relay_state(), StreamProtocol.terminal_failure()}
  @type stream_finalization_result :: {:ok, term()} | {:error, term()}
  @type first_event_retry_result :: {:ok, relay_state()} | {:error, term()}
  @type stream_relay_result :: {:ok, relay_state()} | {:error, term()}
  @type handler_map :: %{
          required(:finalize_success) => (binary() -> stream_finalization_result()),
          required(:finalize_failure) => (binary(), term() -> stream_finalization_result()),
          required(:first_event_retry) => (relay_state(),
                                           binary(),
                                           StreamProtocol.terminal_failure() ->
                                             first_event_retry_result()),
          required(:write_chunk) => (relay_state(), binary() -> stream_write_result()),
          required(:write_keepalive) => (relay_state() -> {:ok, relay_state()} | {:error, term()}),
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
    Req.cancel_async_response(response)
    {:error, state, chunks, {:chunk, reason}}
  end

  defp handle_stream_message(message, state, response, chunks, handlers) do
    case Req.parse_message(response, message) do
      {:ok, parts} -> stream_parts(state, response, chunks, parts, handlers)
      {:error, reason} -> finalize_stream_parse_error(state, chunks, reason, handlers)
      :unknown -> stream_upstream(state, response, chunks, handlers)
    end
  end

  defp finalize_stream_parse_error(state, chunks, reason, handlers) do
    stream_finalization_result(
      handlers.finalize_failure.(chunks, stream_parse_error_reason(reason)),
      state
    )
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
    Req.cancel_async_response(response)
    {:halt, {:retry_first_event, state, append_stream_chunk(chunks, data), failure}}
  end

  defp stream_write_result(
         {:terminal_stream_failure, next_state, failure},
         _state,
         chunks,
         data,
         response
       ) do
    Req.cancel_async_response(response)
    reason = {:terminal_stream_failure, failure}
    {:halt, {:error, next_state, append_stream_chunk(chunks, data), reason}}
  end

  defp stream_write_result({:terminal_stream_failure, failure}, state, chunks, data, response) do
    Req.cancel_async_response(response)
    reason = {:terminal_stream_failure, failure}
    {:halt, {:error, state, append_stream_chunk(chunks, data), reason}}
  end

  defp stream_write_result({:error, reason}, state, chunks, _data, response) do
    Req.cancel_async_response(response)
    {:halt, {:error, state, chunks, {:chunk, reason}}}
  end

  defp append_stream_chunk(chunks, ""), do: chunks
  defp append_stream_chunk(chunks, data), do: RetainedBody.append(chunks, data)

  defp finish_stream_parts({:cont, state, chunks}, response, handlers),
    do: stream_upstream(state, response, chunks, handlers)

  defp finish_stream_parts({:done, state, chunks}, _response, handlers) do
    stream_finalization_result(handlers.finalize_success.(chunks), state)
  end

  defp finish_stream_parts({:retry_first_event, state, chunks, failure}, _response, handlers) do
    handlers.first_event_retry.(state, chunks, failure)
  end

  defp finish_stream_parts({:error, state, chunks, reason}, _response, handlers) do
    stream_finalization_result(handlers.finalize_failure.(chunks, reason), state)
  end

  defp stream_finalization_result({:ok, _finalized}, state), do: {:ok, state}
  defp stream_finalization_result({:error, _gateway_error} = error, _state), do: error
end
