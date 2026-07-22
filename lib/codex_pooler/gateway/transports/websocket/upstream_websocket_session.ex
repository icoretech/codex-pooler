defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession do
  @moduledoc false

  use GenServer

  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Transports.Streaming.RetainedBody
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.UpstreamErrorParam
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ConnectionUpgrade
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ReceiveState
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketFrameWriter

  @default_keepalive_interval_ms 25_000
  @connection_lifecycle_keys [:lifecycle_id, :generation]
  @type response_headers :: [{binary(), binary()}]
  @type message_mapper :: (binary() -> binary()) | nil
  @type connection_lifecycle_state :: %{
          required(:lifecycle_id) => Ecto.UUID.t(),
          required(:generation) => non_neg_integer()
        }
  @type connection_usage :: %{
          required(:reused) => boolean(),
          required(:reconnected) => boolean()
        }
  @type upstream_websocket_connection :: %{
          required(:lifecycle_id) => Ecto.UUID.t(),
          required(:generation) => pos_integer(),
          required(:reused) => boolean(),
          required(:reconnected) => boolean()
        }
  @type request_success :: %{
          required(:body) => binary(),
          required(:terminal) => binary(),
          required(:status) => 200,
          required(:headers) => response_headers(),
          optional(:upstream_websocket_connection) => upstream_websocket_connection(),
          optional(:websocket_frame_headers) => map(),
          optional(:upstream_error_param) => String.t()
        }
  @type request_failure :: %{
          required(:body) => binary(),
          required(:reason) => term(),
          required(:headers) => response_headers(),
          optional(:upstream_websocket_connection) => upstream_websocket_connection(),
          optional(:websocket_frame_headers) => map(),
          optional(:upstream_error_param) => String.t(),
          optional(:transport_failure) => TransportFailureReason.transport_failure_metadata()
        }
  @type request_result :: {:ok, request_success()} | {:error, request_failure()}
  @type send_result :: {:ok, :sent} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :new)
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
    state = new_connection_lifecycle_state()

    case request_once_on_connection(state, key, request, %{
           reused: false,
           reconnected: false
         }) do
      {:ok, result, state} ->
        close_state(state)
        result

      {:error, reason, state} ->
        error = request_error(reason, state)
        close_state(state)
        error
    end
  end

  @spec close(pid()) :: :ok
  def close(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(:new), do: {:ok, new_connection_lifecycle_state()}

  @doc false
  @spec connection_lifecycle_state(connection_lifecycle_state()) :: connection_lifecycle_state()
  def connection_lifecycle_state(state), do: Map.take(state, @connection_lifecycle_keys)

  @spec new_connection_lifecycle_state() :: connection_lifecycle_state()
  defp new_connection_lifecycle_state do
    %{lifecycle_id: Ecto.UUID.generate(), generation: 0}
  end

  @impl GenServer
  def handle_call({:request, %Request{} = request}, _from, state) do
    key = request_key(request)

    case request_on_connection(state, key, request) do
      {:ok, result, state} ->
        {:reply, result, maybe_schedule_keepalive(state)}

      {:retry, state, previous_connection} ->
        {:ok, result, state} =
          state
          |> close_state()
          |> request_on_reconnected(key, request, previous_connection)

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
  def handle_info(
        {:upstream_websocket_keepalive, token},
        %{keepalive_token: token, keepalive_pong_token: _pong_token} = state
      ) do
    {:noreply, schedule_keepalive(state)}
  end

  def handle_info({:upstream_websocket_keepalive, token}, %{keepalive_token: token} = state) do
    payload = unique_keepalive_payload()

    state =
      case send_frame(state, {:ping, payload}) do
        {:ok, state} ->
          state
          |> schedule_pong_deadline(payload)
          |> schedule_keepalive()

        {:error, _reason, state} ->
          close_state(state)
      end

    {:noreply, state}
  end

  def handle_info({:upstream_websocket_keepalive, _token}, state), do: {:noreply, state}

  def handle_info(
        {:upstream_websocket_pong_deadline, token},
        %{keepalive_pong_token: token} = state
      ) do
    {:noreply, close_state(state)}
  end

  def handle_info({:upstream_websocket_pong_deadline, _token}, state), do: {:noreply, state}

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
    connection_usage = %{reused: reused_connection?, reconnected: false}

    case request_once_on_connection(state, key, request, connection_usage) do
      {:ok, result, state} ->
        if reused_connection? and not reset_probe?(request) and
             pre_response_reconnectable?(result) do
          {:retry, state, result_connection_metadata(result)}
        else
          {:ok, result, state}
        end

      {:error, reason, state} ->
        if reused_connection? and not reset_probe?(request) and
             pre_response_reconnectable?(reason) do
          {:retry, state, nil}
        else
          result = request_error(reason, state)
          state = close_state(state)
          {:ok, result, state}
        end
    end
  end

  defp reset_probe?(%Request{reset_probe: %ResetProbe{} = probe}), do: ResetProbe.bound?(probe)
  defp reset_probe?(%Request{}), do: false

  defp reusable_connection?(%{key: key, conn: _conn}, key), do: true
  defp reusable_connection?(_state, _key), do: false

  defp request_on_reconnected(state, key, %Request{} = request, previous_connection) do
    connection_usage = %{reused: false, reconnected: true}

    case request_once_on_connection(state, key, request, connection_usage) do
      {:ok, result, state} ->
        {:ok, result, state}

      {:error, reason, state} ->
        result =
          reason
          |> request_error(state)
          |> maybe_put_result_connection_metadata(previous_connection)

        state = close_state(state)
        {:ok, result, state}
    end
  end

  defp request_once_on_connection(state, key, %Request{} = request, connection_usage) do
    receive_state = %ReceiveState{
      writer: request.writer,
      timeouts: request.timeouts,
      message_mapper: request.message_mapper,
      frame_observer: request.frame_observer,
      # Tolerant access: during a rolling deploy an owner-forwarded request may
      # have been built by a replica that predates this field. nil keeps the
      # pre-provenance classification semantics for that request instead of
      # crashing the session.
      assignment_advertised?: Map.get(request, :assignment_advertised?)
    }

    connect_and_send_request(
      state,
      key,
      request.url,
      request.headers,
      request.timeouts,
      request.payload,
      receive_state,
      connection_usage
    )
  end

  defp connect_and_send_request(
         state,
         key,
         url,
         headers,
         timeouts,
         payload,
         receive_state,
         connection_usage
       ) do
    case ensure_connection(state, key, url, headers, timeouts) do
      {:ok, state} ->
        send_request_payload(state, payload, receive_state, connection_usage)

      {:error, reason, state} ->
        {:error, reason, Map.put(state, :transport_failure_phase, :connect)}
    end
  end

  defp send_request_payload(state, payload, receive_state, connection_usage) do
    case send_text(state, payload) do
      {:ok, state} ->
        {:ok, result, state} = await_sent_request(state, receive_state)
        {:ok, put_result_connection_metadata(result, state, connection_usage), state}

      {:error, reason, state} ->
        {:error, reason, Map.put(state, :transport_failure_phase, :send_payload)}
    end
  end

  defp await_sent_request(state, receive_state) do
    :erlang.garbage_collect(self())
    {result, state} = receive_events(state, receive_state)
    {:ok, result, state}
  end

  defp request_error(reason, state) do
    {:error,
     %{
       body: "",
       reason: reason,
       headers: Map.get(state, :headers, []),
       websocket_frame_headers: %{},
       transport_failure: request_error_transport_failure(reason, state)
     }}
  end

  defp put_result_connection_metadata({status, result}, state, connection_usage)
       when status in [:ok, :error] do
    {status,
     Map.put(
       result,
       :upstream_websocket_connection,
       upstream_websocket_connection(state, connection_usage)
     )}
  end

  defp maybe_put_result_connection_metadata({status, result}, connection)
       when status in [:ok, :error] and is_map(connection) do
    {status, Map.put(result, :upstream_websocket_connection, connection)}
  end

  defp maybe_put_result_connection_metadata(result, _connection), do: result

  defp result_connection_metadata({_status, result}),
    do: Map.get(result, :upstream_websocket_connection)

  @spec upstream_websocket_connection(map(), connection_usage()) ::
          upstream_websocket_connection()
  defp upstream_websocket_connection(
         %{lifecycle_id: lifecycle_id, generation: generation},
         %{reused: reused, reconnected: reconnected}
       ) do
    %{
      lifecycle_id: lifecycle_id,
      generation: generation,
      reused: reused,
      reconnected: reconnected
    }
  end

  defp request_error_transport_failure(reason, state) do
    TransportFailureReason.transport_failure_metadata(reason, %{
      phase: Map.get(state, :transport_failure_phase, :request),
      pre_visible_output: true,
      terminal_seen: false,
      text_frame_count: 0
    })
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

      {:upstream_websocket_pong_deadline, token} ->
        handle_pong_deadline_message(state, receive_state, token)
    after
      receive_state.timeouts.receive_timeout_ms ->
        {{:error,
          %{
            body: receive_body(receive_state),
            reason: :upstream_websocket_receive_timeout,
            headers: state.headers,
            upstream_error_param: receive_state.terminal_upstream_error_param,
            websocket_frame_headers: receive_state.websocket_frame_headers,
            transport_failure:
              transport_failure_metadata(:upstream_websocket_receive_timeout, receive_state,
                phase: :receive_timeout
              )
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
            upstream_error_param: receive_state.terminal_upstream_error_param,
            websocket_frame_headers: receive_state.websocket_frame_headers,
            transport_failure: transport_failure_metadata(reason, receive_state, phase: :receive)
          }}, %{state | conn: conn}}

      :unknown ->
        receive_events(state, receive_state)
    end
  end

  defp handle_pong_deadline_message(
         %{keepalive_pong_token: token} = state,
         %ReceiveState{} = receive_state,
         token
       ) do
    result =
      {:error,
       %{
         body: receive_body(receive_state),
         reason: :upstream_websocket_pong_deadline,
         headers: state.headers,
         upstream_error_param: receive_state.terminal_upstream_error_param,
         websocket_frame_headers: receive_state.websocket_frame_headers,
         transport_failure:
           transport_failure_metadata(:upstream_websocket_pong_deadline, receive_state,
             phase: :receive
           )
       }}

    {result, close_state(state)}
  end

  defp handle_pong_deadline_message(state, %ReceiveState{} = receive_state, _token) do
    receive_events(state, receive_state)
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
            upstream_error_param: receive_state.terminal_upstream_error_param,
            websocket_frame_headers: receive_state.websocket_frame_headers
          }}, state}

      {:failure, state, receive_state, reason} ->
        {{:error,
          %{
            body: receive_body(receive_state),
            reason: reason,
            headers: state.headers,
            upstream_error_param: receive_state.terminal_upstream_error_param,
            websocket_frame_headers: receive_state.websocket_frame_headers,
            transport_failure:
              transport_failure_metadata(reason, receive_state, phase: failure_phase(reason))
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
        {:failure, state, receive_state, {:websocket_decode_failed, reason}}
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

      {:pong, payload}, state ->
        {:cont, clear_matching_pong(state, payload)}

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
          {:ok, state} ->
            {:cont, {:continue, state, receive_state}}

          {:error, reason, state} ->
            {:halt, {:failure, state, receive_state, {:websocket_control_send_failed, reason}}}
        end

      {:pong, payload}, {:continue, state, receive_state} ->
        {:cont, {:continue, clear_matching_pong(state, payload), receive_state}}

      {:close, code, reason}, {:continue, state, receive_state} ->
        receive_state = %{
          receive_state
          | peer_close_metadata: TransportFailureReason.peer_close_metadata(code, reason)
        }

        {:halt, {:failure, state, receive_state, :upstream_websocket_closed_before_terminal}}

      {:binary, _data}, {:continue, state, receive_state} ->
        {:halt, {:failure, state, receive_state, :unexpected_upstream_websocket_binary}}
    end)
  end

  defp append_receive_body(%ReceiveState{body: body} = receive_state, text) do
    %{receive_state | body: RetainedBody.append(body, ["data: ", text, "\n\n"])}
  end

  defp handle_text_frame(state, %ReceiveState{} = receive_state, raw_text, text) do
    receive_state =
      raw_text
      |> maybe_put_terminal_upstream_error(receive_state)
      |> put_websocket_frame_headers(raw_text)
      |> increment_text_frame_count()
      |> append_receive_body(text)

    case retryable_first_text_frame(raw_text, receive_state) do
      {:ok, reason} ->
        {:halt, {:failure, state, receive_state, reason}}

      :error ->
        observe_frame(receive_state, text)
        receive_state.writer.(text)

        receive_state = maybe_mark_downstream_output_started(receive_state, raw_text)

        case terminal_type(text) do
          nil -> {:cont, {:continue, state, receive_state}}
          terminal -> {:halt, {:terminal, state, mark_terminal_seen(receive_state), terminal}}
        end
    end
  end

  defp transport_failure_metadata(reason, %ReceiveState{} = receive_state, attrs) do
    TransportFailureReason.transport_failure_metadata(
      reason,
      Map.merge(
        %{
          pre_visible_output: not receive_state.downstream_output_started?,
          terminal_seen: receive_state.terminal_seen?,
          text_frame_count: receive_state.text_frame_count
        },
        receive_state.peer_close_metadata
        |> Map.merge(Map.new(attrs))
      )
    )
  end

  defp failure_phase({:websocket_decode_failed, _reason}), do: :decode
  defp failure_phase({:websocket_control_send_failed, _reason}), do: :send_control
  defp failure_phase(:upstream_websocket_closed_before_terminal), do: :upstream_close
  defp failure_phase(:unexpected_upstream_websocket_binary), do: :unexpected_frame
  defp failure_phase(_reason), do: :receive

  defp retryable_first_text_frame(
         raw_text,
         %ReceiveState{downstream_output_started?: false} = receive_state
       ) do
    case StreamProtocol.first_complete_event(raw_text) do
      {:ok, event} -> retryable_pre_visible_terminal_event(event, receive_state)
      :incomplete -> :error
    end
  end

  defp retryable_first_text_frame(_raw_text, %ReceiveState{}), do: :error

  defp retryable_pre_visible_terminal_event(event, receive_state) do
    case StreamProtocol.auth_refresh_first_terminal_failure(event) do
      {:ok, failure} -> {:ok, {:auth_refresh_first_event, failure}}
      :error -> retryable_assignment_model_unavailable_event(event, receive_state)
    end
  end

  defp retryable_assignment_model_unavailable_event(event, receive_state) do
    case StreamProtocol.retryable_first_terminal_failure(
           event,
           receive_state.assignment_advertised?
         ) do
      {:ok, %{code: code} = failure}
      when code in ["model_not_found", "invalid_request_error"] ->
        {:ok, {:assignment_model_unavailable_first_event, failure}}

      _other ->
        retryable_connection_limit_event(event)
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

  defp increment_text_frame_count(%ReceiveState{text_frame_count: count} = receive_state) do
    %{receive_state | text_frame_count: count + 1}
  end

  defp mark_terminal_seen(%ReceiveState{} = receive_state),
    do: %{receive_state | terminal_seen?: true}

  defp maybe_put_terminal_upstream_error(raw_text, %ReceiveState{} = receive_state) do
    with {:ok, %{} = decoded} <- Jason.decode(raw_text),
         type when type in ["response.failed", "response.incomplete", "error"] <-
           Map.get(decoded, "type") do
      %{
        receive_state
        | terminal_upstream_error_code:
            receive_state.terminal_upstream_error_code ||
              StreamProtocol.upstream_error_code(decoded),
          terminal_upstream_error_param:
            receive_state.terminal_upstream_error_param || UpstreamErrorParam.extract(decoded)
      }
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

  defp observe_frame(%ReceiveState{frame_observer: observer}, text)
       when is_function(observer, 1) do
    observer.(text)
  end

  defp observe_frame(%ReceiveState{}, _text), do: :ok

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

  defp send_frame(state, frame), do: WebsocketFrameWriter.send_frame(state, frame)

  defp terminal_type(text) do
    case Jason.decode(text) do
      {:ok, %{} = decoded} ->
        case StreamProtocol.terminal_outcome(nil, decoded) do
          {:ok, %{kind: :completed}} ->
            "response.completed"

          {:ok, %{event_type: type}}
          when type in ["response.failed", "response.incomplete", "error"] ->
            type

          _outcome ->
            nil
        end

      _decoded ->
        nil
    end
  end

  defp websocket_body(body) when is_binary(body), do: body

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

  @spec unique_keepalive_payload() :: binary()
  defp unique_keepalive_payload do
    "codex-pooler:" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  @spec schedule_pong_deadline(map(), binary()) :: map()
  defp schedule_pong_deadline(state, payload) when is_binary(payload) do
    state = cancel_pong_deadline(state)
    token = make_ref()

    ref =
      Process.send_after(
        self(),
        {:upstream_websocket_pong_deadline, token},
        keepalive_pong_timeout_ms()
      )

    state
    |> Map.put(:keepalive_pong_ref, ref)
    |> Map.put(:keepalive_pong_token, token)
    |> Map.put(:keepalive_pong_payload, payload)
  end

  @spec cancel_pong_deadline(map()) :: map()
  defp cancel_pong_deadline(%{keepalive_pong_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)

    state
    |> Map.delete(:keepalive_pong_ref)
    |> Map.delete(:keepalive_pong_token)
    |> Map.delete(:keepalive_pong_payload)
  end

  defp cancel_pong_deadline(state), do: state

  @spec clear_matching_pong(map(), binary()) :: map()
  defp clear_matching_pong(%{keepalive_pong_payload: payload} = state, payload),
    do: cancel_pong_deadline(state)

  defp clear_matching_pong(state, _payload), do: state

  defp keepalive_interval_ms do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:keepalive_interval_ms, @default_keepalive_interval_ms)
    |> case do
      interval when is_integer(interval) and interval > 0 -> interval
      _interval -> @default_keepalive_interval_ms
    end
  end

  @spec keepalive_pong_timeout_ms() :: pos_integer()
  defp keepalive_pong_timeout_ms do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:keepalive_pong_timeout_ms, keepalive_interval_ms())
    |> case do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _timeout -> keepalive_interval_ms()
    end
  end

  defp close_state(%{conn: conn} = state) do
    Mint.HTTP.close(conn)

    state
    |> cancel_keepalive()
    |> cancel_pong_deadline()
    |> connection_lifecycle_state()
  end

  defp close_state(state) do
    state
    |> cancel_keepalive()
    |> cancel_pong_deadline()
    |> connection_lifecycle_state()
  end
end
