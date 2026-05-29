defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession do
  @moduledoc false

  use GenServer

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession.ConnectionUpgrade
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession.ReceiveState
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession.Request
  alias CodexPooler.Gateway.Transports.Websocket.WebSocketFrameWriter

  @default_keepalive_interval_ms 25_000
  @type response_headers :: [{binary(), binary()}]
  @type message_mapper :: (binary() -> binary()) | nil
  @type request_success :: %{
          required(:body) => binary(),
          required(:terminal) => binary(),
          required(:status) => 200,
          required(:headers) => response_headers(),
          optional(:websocket_frame_headers) => map()
        }
  @type request_failure :: %{
          required(:body) => binary(),
          required(:reason) => term(),
          required(:headers) => response_headers(),
          optional(:websocket_frame_headers) => map()
        }
  @type request_result :: {:ok, request_success()} | {:error, request_failure()}
  @type send_result :: {:ok, :sent} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{})
  end

  @spec request(pid(), Request.t()) :: request_result()
  def request(pid, %Request{} = request) do
    GenServer.call(pid, {:request, request}, :infinity)
  catch
    :exit, _reason ->
      request_error(:upstream_websocket_session_unavailable, %{})
  end

  @spec send_request_frame(pid(), binary()) :: send_result()
  def send_request_frame(pid, payload) when is_pid(pid) and is_binary(payload) do
    GenServer.call(pid, {:send_text, payload}, 1_000)
  catch
    :exit, _reason -> {:error, :upstream_websocket_session_unavailable}
  end

  @spec request_once(Request.t()) :: request_result()
  def request_once(%Request{} = request) do
    key = request_key(request)

    case request_once_on_connection(%{}, key, request) do
      {:ok, result, state} ->
        close_state(state)
        result

      {:error, reason, state} ->
        close_state(state)
        request_error(reason, state)
    end
  end

  @spec close(pid()) :: :ok
  def close(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:request, %Request{} = request}, _from, state) do
    key = request_key(request)

    case request_on_connection(state, key, request) do
      {:ok, result, state} ->
        {:reply, result, maybe_schedule_keepalive(state)}

      {:retry, state} ->
        {:ok, result, state} =
          state
          |> close_state()
          |> request_on_reconnected(key, request)

        {:reply, result, maybe_schedule_keepalive(state)}
    end
  end

  def handle_call({:send_text, payload}, _from, %{conn: _conn} = state) do
    case send_text(state, payload) do
      {:ok, state} -> {:reply, {:ok, :sent}, maybe_schedule_keepalive(state)}
      {:error, reason, state} -> {:reply, {:error, reason}, close_state(state)}
    end
  end

  def handle_call({:send_text, _payload}, _from, state),
    do: {:reply, {:error, :upstream_websocket_not_connected}, state}

  @impl GenServer
  def handle_info({:upstream_websocket_keepalive, token}, %{keepalive_token: token} = state) do
    state =
      case send_frame(state, {:ping, "codex-pooler"}) do
        {:ok, state} -> schedule_keepalive(state)
        {:error, _reason, state} -> close_state(state)
      end

    {:noreply, state}
  end

  def handle_info({:upstream_websocket_keepalive, _token}, state), do: {:noreply, state}

  def handle_info(message, %{conn: conn} = state) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        {:noreply, handle_async_parts(state, responses)}

      {:error, conn, _reason, _responses} ->
        {:noreply, close_state(%{state | conn: conn})}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    close_state(state)
    :ok
  end

  defp ensure_connection(%{key: key, conn: _conn} = state, key, _url, _headers, _timeouts),
    do: {:ok, state}

  defp ensure_connection(state, key, url, headers, timeouts) do
    state = close_state(state)

    ConnectionUpgrade.connect_state(state, key, url, headers, timeouts)
  end

  defp request_key(%Request{} = request), do: {request.url, request.headers}

  defp request_on_connection(state, key, %Request{} = request) do
    reused_connection? = reusable_connection?(state, key)

    case request_once_on_connection(state, key, request) do
      {:ok, result, state} ->
        if reused_connection? and pre_response_reconnectable?(result) do
          {:retry, state}
        else
          {:ok, result, state}
        end

      {:error, reason, state} ->
        if reused_connection? and pre_response_reconnectable?(reason) do
          {:retry, state}
        else
          state = close_state(state)
          {:ok, request_error(reason, state), state}
        end
    end
  end

  defp reusable_connection?(%{key: key, conn: _conn}, key), do: true
  defp reusable_connection?(_state, _key), do: false

  defp request_on_reconnected(state, key, %Request{} = request) do
    case request_once_on_connection(state, key, request) do
      {:ok, result, state} ->
        {:ok, result, state}

      {:error, reason, state} ->
        state = close_state(state)
        {:ok, request_error(reason, state), state}
    end
  end

  defp request_once_on_connection(state, key, %Request{} = request) do
    receive_state = %ReceiveState{
      writer: request.writer,
      timeouts: request.timeouts,
      message_mapper: request.message_mapper
    }

    with {:ok, state} <-
           ensure_connection(state, key, request.url, request.headers, request.timeouts),
         {:ok, state} <- send_text(state, request.payload),
         {result, state} <-
           receive_events(state, receive_state) do
      {:ok, result, state}
    end
  end

  defp request_error(reason, state) do
    {:error,
     %{
       body: "",
       reason: reason,
       headers: Map.get(state, :headers, []),
       websocket_frame_headers: %{}
     }}
  end

  defp pre_response_reconnectable?({:error, %{body: "", reason: reason}}),
    do: pre_response_reconnectable?(reason)

  defp pre_response_reconnectable?(:upstream_websocket_closed_before_terminal), do: true
  defp pre_response_reconnectable?(:closed), do: true
  defp pre_response_reconnectable?(:econnreset), do: true

  defp pre_response_reconnectable?(%Mint.TransportError{reason: reason}),
    do: pre_response_reconnectable?(reason)

  defp pre_response_reconnectable?(_reason), do: false

  defp send_text(%{conn: conn, ref: ref, websocket: websocket} = state, text) do
    case Mint.WebSocket.encode(websocket, {:text, text}) do
      {:ok, websocket, data} ->
        stream_request_body(%{state | websocket: websocket}, conn, ref, data)

      {:error, websocket, reason} ->
        {:error, reason, %{state | websocket: websocket}}
    end
  end

  defp stream_request_body(state, conn, ref, data) do
    case Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, conn} -> {:ok, %{state | conn: conn}}
      {:error, conn, reason} -> {:error, reason, %{state | conn: conn}}
    end
  end

  defp receive_events(%{conn: conn} = state, %ReceiveState{} = receive_state) do
    socket = mint_socket(conn)

    receive do
      {:tcp, ^socket, _data} = message ->
        handle_event_message(state, receive_state, message)

      {:ssl, ^socket, _data} = message ->
        handle_event_message(state, receive_state, message)

      {:tcp_closed, ^socket} = message ->
        handle_event_message(state, receive_state, message)

      {:ssl_closed, ^socket} = message ->
        handle_event_message(state, receive_state, message)

      {:tcp_error, ^socket, _reason} = message ->
        handle_event_message(state, receive_state, message)

      {:ssl_error, ^socket, _reason} = message ->
        handle_event_message(state, receive_state, message)
    after
      receive_state.timeouts.receive_timeout_ms ->
        {{:error,
          %{
            body: receive_body(receive_state),
            reason: :upstream_websocket_receive_timeout,
            headers: state.headers,
            websocket_frame_headers: receive_state.websocket_frame_headers
          }}, state}
    end
  end

  defp handle_event_message(
         %{conn: conn} = state,
         %ReceiveState{} = receive_state,
         message
       ) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        handle_parts(state, responses, receive_state)

      {:error, conn, reason, _responses} ->
        {{:error,
          %{
            body: receive_body(receive_state),
            reason: reason,
            headers: state.headers,
            websocket_frame_headers: receive_state.websocket_frame_headers
          }}, %{state | conn: conn}}

      :unknown ->
        receive_events(state, receive_state)
    end
  end

  defp handle_parts(state, responses, %ReceiveState{} = receive_state) do
    responses
    |> Enum.reduce_while({:continue, state, receive_state}, &handle_part/2)
    |> finish_receive_result()
  end

  defp handle_part({:data, ref, data}, {:continue, %{ref: ref} = state, receive_state}) do
    state
    |> handle_data(data, receive_state)
    |> reduce_receive_result()
  end

  defp handle_part({:done, _ref}, {:continue, state, receive_state}) do
    {:halt, {:failure, state, receive_state, :upstream_websocket_closed_before_terminal}}
  end

  defp handle_part(_part, result), do: {:cont, result}

  defp finish_receive_result(result) do
    case result do
      {:continue, state, receive_state} ->
        receive_events(state, receive_state)

      {:terminal, state, receive_state, terminal} ->
        {{:ok,
          %{
            body: receive_body(receive_state),
            terminal: terminal,
            status: 200,
            headers: state.headers,
            upstream_error_code: receive_state.terminal_upstream_error_code,
            websocket_frame_headers: receive_state.websocket_frame_headers
          }}, state}

      {:failure, state, receive_state, reason} ->
        {{:error,
          %{
            body: receive_body(receive_state),
            reason: reason,
            headers: state.headers,
            websocket_frame_headers: receive_state.websocket_frame_headers
          }}, state}
    end
  end

  defp reduce_receive_result({:continue, _state, _receive_state} = result), do: {:cont, result}

  defp reduce_receive_result({:terminal, _state, _receive_state, _terminal} = result),
    do: {:halt, result}

  defp reduce_receive_result({:failure, _state, _receive_state, _reason} = result),
    do: {:halt, result}

  defp handle_data(state, data, %ReceiveState{} = receive_state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        handle_frames(state, frames, receive_state)

      {:error, websocket, reason} ->
        state = %{state | websocket: websocket}
        {:failure, state, receive_state, reason}
    end
  end

  defp handle_async_parts(state, responses) do
    Enum.reduce_while(responses, state, fn
      {:data, ref, data}, %{ref: ref, websocket: websocket} = state ->
        case Mint.WebSocket.decode(websocket, data) do
          {:ok, websocket, frames} ->
            state = %{state | websocket: websocket}
            {:cont, handle_async_frames(state, frames)}

          {:error, _websocket, _reason} ->
            {:halt, close_state(state)}
        end

      {:done, _ref}, state ->
        {:halt, close_state(state)}

      _part, state ->
        {:cont, state}
    end)
  end

  defp handle_async_frames(state, frames) do
    Enum.reduce_while(frames, state, fn
      {:ping, payload}, state ->
        case send_frame(state, {:pong, payload}) do
          {:ok, state} -> {:cont, state}
          {:error, _reason, state} -> {:halt, close_state(state)}
        end

      {:pong, _payload}, state ->
        {:cont, state}

      {:close, _code, _reason}, state ->
        {:halt, close_state(state)}

      {:text, _text}, state ->
        {:cont, state}

      {:binary, _data}, state ->
        {:cont, state}
    end)
  end

  defp handle_frames(state, frames, %ReceiveState{} = receive_state) do
    Enum.reduce_while(frames, {:continue, state, receive_state}, fn
      {:text, raw_text}, {:continue, state, receive_state} ->
        text =
          raw_text
          |> map_message(receive_state.message_mapper)
          |> sanitize_downstream_text()

        handle_text_frame(state, receive_state, raw_text, text)

      {:ping, payload}, {:continue, state, receive_state} ->
        case send_frame(state, {:pong, payload}) do
          {:ok, state} -> {:cont, {:continue, state, receive_state}}
          {:error, reason, state} -> {:halt, {:failure, state, receive_state, reason}}
        end

      {:pong, _payload}, acc ->
        {:cont, acc}

      {:close, _code, _reason}, {:continue, state, receive_state} ->
        {:halt, {:failure, state, receive_state, :upstream_websocket_closed_before_terminal}}

      {:binary, _data}, {:continue, state, receive_state} ->
        {:halt, {:failure, state, receive_state, :unexpected_upstream_websocket_binary}}
    end)
  end

  defp prepend_receive_body(%ReceiveState{body: body} = receive_state, text),
    do: %{receive_state | body: [["data: ", text, "\n\n"] | body]}

  defp handle_text_frame(state, %ReceiveState{} = receive_state, raw_text, text) do
    receive_state =
      raw_text
      |> maybe_put_terminal_upstream_error_code(receive_state)
      |> put_websocket_frame_headers(raw_text)
      |> prepend_receive_body(text)

    case retryable_first_text_frame(raw_text, receive_state) do
      {:ok, reason} ->
        {:halt, {:failure, state, receive_state, reason}}

      :error ->
        receive_state.writer.(text)

        receive_state = maybe_mark_downstream_output_started(receive_state, raw_text)

        case terminal_type(text) do
          nil -> {:cont, {:continue, state, receive_state}}
          terminal -> {:halt, {:terminal, state, receive_state, terminal}}
        end
    end
  end

  defp retryable_first_text_frame(raw_text, %ReceiveState{downstream_output_started?: false}) do
    case StreamProtocol.first_complete_event(raw_text) do
      {:ok, event} -> retryable_pre_visible_terminal_event(event)
      :incomplete -> :error
    end
  end

  defp retryable_first_text_frame(_raw_text, %ReceiveState{}), do: :error

  defp retryable_pre_visible_terminal_event(event) do
    case StreamProtocol.auth_refresh_first_terminal_failure(event) do
      {:ok, failure} -> {:ok, {:auth_refresh_first_event, failure}}
      :error -> retryable_connection_limit_event(event)
    end
  end

  defp retryable_connection_limit_event(event) do
    case StreamProtocol.retryable_first_terminal_failure(event) do
      {:ok, %{code: "websocket_connection_limit_reached"} = failure} ->
        {:ok, {:retryable_first_event, failure}}

      _other ->
        :error
    end
  end

  defp maybe_mark_downstream_output_started(%ReceiveState{} = receive_state, raw_text) do
    if StreamProtocol.internal_rate_limit_event?(raw_text) do
      receive_state
    else
      %{receive_state | downstream_output_started?: true}
    end
  end

  defp maybe_put_terminal_upstream_error_code(raw_text, %ReceiveState{} = receive_state) do
    with nil <- receive_state.terminal_upstream_error_code,
         {:ok, %{} = decoded} <- Jason.decode(raw_text),
         type when type in ["response.failed", "response.incomplete", "error"] <-
           Map.get(decoded, "type"),
         code when is_binary(code) <- StreamProtocol.upstream_error_code(decoded) do
      %{receive_state | terminal_upstream_error_code: code}
    else
      _other -> receive_state
    end
  end

  defp put_websocket_frame_headers(%ReceiveState{} = receive_state, raw_text) do
    case StreamProtocol.websocket_error_frame_headers(raw_text) do
      headers when map_size(headers) > 0 ->
        %{
          receive_state
          | websocket_frame_headers: Map.merge(receive_state.websocket_frame_headers, headers)
        }

      _headers ->
        receive_state
    end
  end

  defp receive_body(%ReceiveState{body: body}), do: websocket_body(body)

  defp map_message(text, mapper) when is_function(mapper, 1), do: mapper.(text)
  defp map_message(text, _mapper), do: text

  defp sanitize_downstream_text(text) when is_binary(text) do
    with {:ok, %{} = decoded} <- Jason.decode(text),
         type
         when type in ["response.completed", "response.failed", "response.incomplete", "error"] <-
           Map.get(decoded, "type") do
      decoded
      |> Map.drop(["headers"])
      |> Jason.encode!()
    else
      _other -> text
    end
  end

  defp send_frame(state, frame), do: WebSocketFrameWriter.send_frame(state, frame)

  defp terminal_type(text) do
    case Jason.decode(text) do
      {:ok, %{"type" => type}}
      when type in ["response.completed", "response.failed", "response.incomplete", "error"] ->
        type

      {:ok, %{"id" => id} = decoded} when is_binary(id) ->
        if Map.has_key?(decoded, "type"), do: nil, else: "response.completed"

      _decoded ->
        nil
    end
  end

  defp websocket_body(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp mint_socket(conn), do: Mint.HTTP.get_socket(conn)

  defp maybe_schedule_keepalive(%{conn: _conn} = state), do: schedule_keepalive(state)
  defp maybe_schedule_keepalive(state), do: state

  defp schedule_keepalive(state) do
    state = cancel_keepalive(state)
    token = make_ref()

    ref =
      Process.send_after(
        self(),
        {:upstream_websocket_keepalive, token},
        keepalive_interval_ms()
      )

    state
    |> Map.put(:keepalive_ref, ref)
    |> Map.put(:keepalive_token, token)
  end

  defp cancel_keepalive(%{keepalive_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)

    state
    |> Map.delete(:keepalive_ref)
    |> Map.delete(:keepalive_token)
  end

  defp cancel_keepalive(state), do: state

  defp keepalive_interval_ms do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:keepalive_interval_ms, @default_keepalive_interval_ms)
    |> case do
      interval when is_integer(interval) and interval > 0 -> interval
      _interval -> @default_keepalive_interval_ms
    end
  end

  defp close_state(%{conn: conn} = state) do
    Mint.HTTP.close(conn)
    state |> cancel_keepalive() |> Map.take([])
  end

  defp close_state(state), do: state |> cancel_keepalive() |> Map.take([])
end
