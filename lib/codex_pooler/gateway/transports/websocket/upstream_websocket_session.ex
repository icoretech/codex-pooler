defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession do
  @moduledoc false

  use GenServer

  require Logger

  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl
  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl.TurnSnapshot
  alias CodexPooler.Gateway.Transports.Streaming.RetainedBody
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.UpstreamErrorParam
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Gateway.Transports.Websocket.ForwardedOwnerRequestHandoff
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Binding
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Capability
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Confirmation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.FirstCompactCollection
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Topology.Direct
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAuthorizationObservation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionTrace
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ConnectionUpgrade
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ReceiveState
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ReceiveState.Delivery
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketFrameWriter

  @default_keepalive_interval_ms 25_000
  @connection_lifecycle_keys [:lifecycle_id, :generation]
  @five_seconds_ms :timer.seconds(5)
  @thirty_seconds_ms :timer.seconds(30)
  @one_minute_ms :timer.minutes(1)
  @two_minutes_ms :timer.minutes(2)
  @five_minutes_ms :timer.minutes(5)
  @ten_minutes_ms :timer.minutes(10)
  @fifteen_minutes_ms :timer.minutes(15)
  @thirty_minutes_ms :timer.minutes(30)
  @type response_headers :: [{binary(), binary()}]
  @type decoded_frame :: map() | :non_object_json | :undecodable
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
          optional(:response_id) => String.t(),
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
  @type invalidation_result :: :ok | {:error, :upstream_websocket_not_connected}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    case GenServer.start_link(__MODULE__, :new) do
      {:ok, pid} = result ->
        _trace = NativeCompactionTrace.enroll(:upstream_session, pid)
        result

      other ->
        other
    end
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

  @spec connection_lifecycle_snapshot(pid()) ::
          connection_lifecycle_state() | {:error, :unavailable}
  def connection_lifecycle_snapshot(pid) when is_pid(pid) do
    GenServer.call(pid, :connection_lifecycle_snapshot, 1_000)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def connection_lifecycle_snapshot(_pid), do: {:error, :invalid_input}

  @spec arm_compact(pid(), Binding.t(), non_neg_integer()) :: :ok | {:error, atom()}
  def arm_compact(pid, %Binding{} = binding, expires_at_ms) when is_pid(pid) do
    admission_call(pid, {:arm_compact, binding, expires_at_ms})
  end

  def arm_compact(_pid, _binding, _expires_at_ms), do: {:error, :invalid_input}

  @spec authorize_first_compact_collection(pid(), Binding.t(), reference()) ::
          {:ok, FirstCompactCollection.t()} | {:error, atom()}
  def authorize_first_compact_collection(pid, %Binding{} = binding, control_ref)
      when is_pid(pid) and is_reference(control_ref) do
    admission_call(pid, {:authorize_first_compact_collection, binding, control_ref})
  end

  def authorize_first_compact_collection(_pid, _binding, _control_ref),
    do: {:error, :invalid_input}

  @spec record_first_compact_collected(pid(), FirstCompactCollection.t()) ::
          :ok | {:error, atom()}
  def record_first_compact_collected(pid, %FirstCompactCollection{} = provenance)
      when is_pid(pid) do
    admission_call(pid, {:record_first_compact_collected, provenance})
  end

  def record_first_compact_collected(_pid, _provenance), do: {:error, :invalid_input}

  @spec reserve_compaction(
          pid(),
          :compact | :final,
          Binding.t(),
          reference(),
          non_neg_integer()
        ) :: {:ok, Capability.t()} | {:error, atom()}
  def reserve_compaction(pid, phase, %Binding{} = binding, control_ref, now_ms)
      when is_pid(pid) and phase in [:compact, :final] and is_reference(control_ref) and
             is_integer(now_ms) and now_ms >= 0 do
    admission_call(pid, {:reserve_compaction, phase, binding, control_ref, now_ms})
  end

  def reserve_compaction(_pid, _phase, _binding, _control_ref, _now_ms),
    do: {:error, :invalid_input}

  @spec mark_compaction_accounting_started(pid(), Capability.t(), non_neg_integer()) ::
          :ok | {:error, atom()}
  def mark_compaction_accounting_started(pid, %Capability{} = capability, now_ms)
      when is_pid(pid) and is_integer(now_ms) and now_ms >= 0 do
    admission_call(pid, {:mark_compaction_accounting_started, capability, now_ms})
  end

  def mark_compaction_accounting_started(_pid, _capability, _now_ms),
    do: {:error, :invalid_input}

  @spec cancel_compaction_reservation(pid(), Capability.t(), non_neg_integer()) ::
          :ok | {:error, atom()}
  def cancel_compaction_reservation(pid, %Capability{} = capability, now_ms)
      when is_pid(pid) and is_integer(now_ms) and now_ms >= 0 do
    admission_call(pid, {:cancel_compaction_reservation, capability, now_ms})
  end

  def cancel_compaction_reservation(_pid, _capability, _now_ms),
    do: {:error, :invalid_input}

  @spec acknowledge_compact_finalization(
          pid(),
          {:success, <<_::256>>, Confirmation.t(), non_neg_integer()} | :failure
        ) :: :ok | {:error, atom()}
  def acknowledge_compact_finalization(pid, acknowledgement) when is_pid(pid) do
    admission_call(pid, {:acknowledge_compact_finalization, acknowledgement})
  end

  def acknowledge_compact_finalization(_pid, _acknowledgement),
    do: {:error, :invalid_input}

  @spec acknowledge_final_response(pid(), :success | :failure) :: :ok | {:error, atom()}
  def acknowledge_final_response(pid, acknowledgement)
      when is_pid(pid) and acknowledgement in [:success, :failure] do
    admission_call(pid, {:acknowledge_final_response, acknowledgement})
  end

  def acknowledge_final_response(_pid, _acknowledgement), do: {:error, :invalid_input}

  @spec clear_compaction_admission(pid()) :: :ok | {:error, :unavailable}
  def clear_compaction_admission(pid) when is_pid(pid) do
    admission_call(pid, :clear_compaction_admission)
  end

  def clear_compaction_admission(_pid), do: {:error, :invalid_input}

  @spec compaction_admission_phase(pid()) ::
          NativeCompactionAdmission.phase() | {:error, :unavailable}
  def compaction_admission_phase(pid) when is_pid(pid) do
    admission_call(pid, :compaction_admission_phase)
  end

  def compaction_admission_phase(_pid), do: {:error, :invalid_input}

  defp admission_call(pid, message) do
    GenServer.call(pid, message, 1_000)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec invalidate_connection(pid()) :: invalidation_result()
  def invalidate_connection(pid) when is_pid(pid) do
    GenServer.call(pid, :invalidate_connection, 1_000)
  catch
    :exit, _reason -> {:error, :upstream_websocket_not_connected}
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
  def init(:new) do
    sensitivity = NativeCompactionTrace.configure_process_sensitivity(:upstream_session)

    {:ok, put_trace_sensitivity(new_connection_lifecycle_state(), sensitivity)}
  end

  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {:reason, reason} -> {:reason, status_reason_class(reason)}
      {:message, message} -> {:message, status_message_class(message)}
      {:state, state} -> {:state, status_state(state)}
      {:log, _log} -> {:log, []}
    end)
  end

  @doc false
  @spec connection_lifecycle_state(map()) :: connection_lifecycle_state()
  def connection_lifecycle_state(state), do: Map.take(state, @connection_lifecycle_keys)

  @spec new_connection_lifecycle_state() :: connection_lifecycle_state()
  defp new_connection_lifecycle_state do
    %{lifecycle_id: Ecto.UUID.generate(), generation: 0}
  end

  @impl GenServer
  def handle_call(:native_compaction_trace_cooperative?, _from, state),
    do: {:reply, true, state}

  def handle_call(
        {:native_compaction_trace_sensitivity, :observe, generation, authorization, restorer},
        _from,
        state
      ) do
    case apply(NativeCompactionTrace, :configure_existing_process_sensitivity, [
           :upstream_session,
           generation,
           authorization,
           restorer
         ]) do
      {:ok, sensitivity} ->
        {:reply, :ok, Map.put(state, :native_compaction_trace_sensitivity, sensitivity)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:request, %Request{} = request}, {caller_pid, _tag}, state)
      when is_pid(caller_pid) do
    key = request_key(request)
    caller_monitor = Process.monitor(caller_pid)

    try do
      case request_on_connection(state, key, request, {caller_pid, caller_monitor}) do
        {:ok, result, state} ->
          {:reply, result, maybe_schedule_keepalive(state)}

        {:retry, state, previous_connection} ->
          {:ok, result, state} =
            state
            |> close_state()
            |> request_on_reconnected(
              key,
              request,
              previous_connection,
              {caller_pid, caller_monitor}
            )

          {:reply, result, maybe_schedule_keepalive(state)}
      end
    after
      Process.demonitor(caller_monitor, [:flush])
    end
  end

  def handle_call(:connection_lifecycle_snapshot, _from, state) do
    {:reply, connection_lifecycle_state(state), state}
  end

  def handle_call({:arm_compact, %Binding{} = binding, expires_at_ms}, _from, state) do
    result =
      with :ok <- validate_direct_binding(state, binding),
           {:ok, admission} <- NativeCompactionAdmission.ordinary_success(binding),
           do: NativeCompactionAdmission.arm_compact(admission, expires_at_ms)

    reply_with_admission(result, state)
  end

  def handle_call(
        {:authorize_first_compact_collection, %Binding{} = binding, control_ref},
        _from,
        state
      ) do
    result =
      with :ok <- validate_direct_binding(state, binding),
           {:ok, admission} <- NativeCompactionAdmission.ordinary_success(binding),
           do:
             NativeCompactionAdmission.authorize_first_compact_collection(
               admission,
               control_ref
             )

    case result do
      {:ok, admission, provenance} ->
        {:reply, {:ok, provenance}, Map.put(state, :native_compaction_admission, admission)}

      {:error, reason} ->
        {:reply, {:error, reason}, clear_admission(state)}
    end
  end

  def handle_call({:record_first_compact_collected, provenance}, _from, state) do
    admission = admission_state(state)

    case NativeCompactionAdmission.record_first_compact_collected(admission, provenance) do
      {:ok, admission} ->
        {:reply, :ok, Map.put(state, :native_compaction_admission, admission)}

      {:error, reason} ->
        {:reply, {:error, reason}, clear_admission(state)}

      {:error, reason, admission} ->
        {:reply, {:error, reason}, Map.put(state, :native_compaction_admission, admission)}
    end
  end

  def handle_call({:reserve_compaction, phase, binding, control_ref, now_ms}, _from, state) do
    with :ok <- validate_direct_binding(state, binding),
         {:ok, admission, capability} <-
           NativeCompactionAdmission.reserve(
             admission_state(state),
             phase,
             binding,
             control_ref,
             now_ms
           ) do
      :ok = emit_reservation_observations(capability)
      {:reply, {:ok, capability}, Map.put(state, :native_compaction_admission, admission)}
    else
      {:error, reason} -> {:reply, {:error, reason}, clear_admission(state)}
    end
  end

  def handle_call({:mark_compaction_accounting_started, capability, now_ms}, _from, state) do
    case NativeCompactionAdmission.mark_accounting_started(
           admission_state(state),
           capability,
           now_ms
         ) do
      {:ok, admission} ->
        :ok =
          NativeCompactionAuthorizationObservation.emit_capability(
            capability,
            :accounting_started
          )

        _trace =
          NativeCompactionTrace.emit_capability(:accounting_started, capability, %{
            pid_role: :upstream_session,
            upstream_pid: self()
          })

        {:reply, :ok, Map.put(state, :native_compaction_admission, admission)}

      {:error, reason} ->
        {:reply, {:error, reason}, clear_admission(state)}
    end
  end

  def handle_call({:cancel_compaction_reservation, capability, now_ms}, _from, state) do
    case NativeCompactionAdmission.cancel(
           admission_state(state),
           capability,
           :pre_accounting,
           now_ms
         ) do
      {:ok, admission} ->
        {:reply, :ok, Map.put(state, :native_compaction_admission, admission)}

      {:error, :committed, admission} ->
        {:reply, {:error, :committed}, Map.put(state, :native_compaction_admission, admission)}

      {:error, reason} ->
        {:reply, {:error, reason}, clear_admission(state)}
    end
  end

  def handle_call({:acknowledge_compact_finalization, :failure}, _from, state),
    do: {:reply, :ok, clear_admission(state)}

  def handle_call(
        {:acknowledge_compact_finalization,
         {:success, digest, %Confirmation{} = confirmation, expires_at_ms}},
        _from,
        state
      ) do
    compact_capability = admission_state(state).capability

    case NativeCompactionAdmission.confirm_compact(
           admission_state(state),
           digest,
           confirmation,
           expires_at_ms
         ) do
      {:ok, admission} ->
        :ok =
          NativeCompactionAuthorizationObservation.emit_capability(
            compact_capability,
            :acknowledged
          )

        _trace =
          NativeCompactionTrace.emit_capability(:capability_acknowledged, compact_capability, %{
            pid_role: :upstream_session,
            upstream_pid: self()
          })

        {:reply, :ok, Map.put(state, :native_compaction_admission, admission)}

      {:error, reason} ->
        {:reply, {:error, reason}, clear_admission(state)}

      {:error, reason, admission} ->
        {:reply, {:error, reason}, Map.put(state, :native_compaction_admission, admission)}
    end
  end

  def handle_call({:acknowledge_compact_finalization, _invalid}, _from, state),
    do: {:reply, {:error, :invalid_input}, clear_admission(state)}

  def handle_call({:acknowledge_final_response, :success}, _from, state) do
    case NativeCompactionAdmission.clear_consumed(admission_state(state)) do
      {:ok, _admission} -> {:reply, :ok, clear_admission(state)}
      {:error, reason} -> {:reply, {:error, reason}, clear_admission(state)}
    end
  end

  def handle_call({:acknowledge_final_response, :failure}, _from, state),
    do: {:reply, :ok, clear_admission(state)}

  def handle_call(:clear_compaction_admission, _from, state),
    do: {:reply, :ok, clear_admission(state)}

  def handle_call(:compaction_admission_phase, _from, state),
    do: {:reply, NativeCompactionAdmission.phase(admission_state(state)), state}

  def handle_call({:send_text, payload}, _from, %{conn: _conn} = state) do
    case send_text(state, payload) do
      {:ok, state} -> {:reply, {:ok, :sent}, maybe_schedule_keepalive(state)}
      {:error, reason, state} -> {:reply, {:error, reason}, close_state(state)}
    end
  end

  def handle_call({:send_text, _payload}, _from, state),
    do: {:reply, {:error, :upstream_websocket_not_connected}, state}

  def handle_call(:invalidate_connection, _from, %{conn: _conn} = state) do
    {:reply, :ok, invalidate_state(state)}
  end

  def handle_call(:invalidate_connection, _from, state),
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

  def handle_info(
        {:native_compaction_trace_sensitivity, :restore, generation, authorization, restorer},
        state
      ) do
    sensitivity = Map.get(state, :native_compaction_trace_sensitivity, :sensitive)

    if NativeCompactionTrace.authorized_restore?(
         sensitivity,
         generation,
         authorization,
         restorer
       ) do
      :ok = NativeCompactionTrace.restore_process_sensitivity(sensitivity)
      {:noreply, Map.put(state, :native_compaction_trace_sensitivity, :sensitive)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, restorer, _reason}, state) do
    sensitivity = Map.get(state, :native_compaction_trace_sensitivity, :sensitive)

    case NativeCompactionTrace.restore_on_restorer_down(sensitivity, monitor, restorer) do
      :restored ->
        {:noreply, Map.put(state, :native_compaction_trace_sensitivity, :sensitive)}

      :unchanged ->
        {:noreply, state}
    end
  end

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

  defp ensure_connection(
         %{key: key, conn: _conn} = state,
         key,
         _url,
         _headers,
         _timeouts,
         _request_caller
       ),
       do: {:ok, state}

  defp ensure_connection(state, key, url, headers, timeouts, request_caller) do
    state = close_state(state)

    ConnectionUpgrade.connect_state(state, key, url, headers, timeouts, request_caller)
  end

  defp request_key(%Request{} = request), do: {request.url, request.headers}

  defp request_on_connection(state, key, %Request{} = request, request_caller) do
    reused_connection? = reusable_connection?(state, key)
    reconnect_pending? = Map.get(state, :reconnect_pending?, false)
    connection_usage = %{reused: reused_connection?, reconnected: reconnect_pending?}

    case request_once_on_connection(state, key, request, connection_usage, request_caller) do
      {:ok, result, state} ->
        if reconnect_reused_connection?(reused_connection?, request, result) do
          {:retry, state, result_connection_metadata(result)}
        else
          {:ok, result, state}
        end

      {:error, reason, state} ->
        if reconnect_reused_connection?(reused_connection?, request, reason) do
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

  defp collect_compaction?(%Request{websocket_delivery_mode: :collect_compaction}), do: true
  defp collect_compaction?(%Request{}), do: false

  defp reconnect_reused_connection?(false, %Request{}, _result_or_reason), do: false

  defp reconnect_reused_connection?(true, %Request{} = request, result_or_reason) do
    not reset_probe?(request) and not collect_compaction?(request) and
      pre_response_reconnectable?(result_or_reason)
  end

  defp reusable_connection?(%{key: key, conn: _conn}, key), do: true
  defp reusable_connection?(_state, _key), do: false

  defp request_on_reconnected(
         state,
         key,
         %Request{} = request,
         previous_connection,
         request_caller
       ) do
    connection_usage = %{reused: false, reconnected: true}

    case request_once_on_connection(state, key, request, connection_usage, request_caller) do
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

  defp request_once_on_connection(
         state,
         key,
         %Request{} = request,
         connection_usage,
         request_caller \\ nil
       ) do
    {request_caller_pid, request_caller_monitor} = request_caller || {nil, nil}

    receive_state = %ReceiveState{
      writer: request.writer,
      timeouts: request.timeouts,
      message_mapper: request.message_mapper,
      frame_observer: request.frame_observer,
      native_codex_response_control: Map.get(request, :native_codex_response_control),
      delivery: %Delivery{
        mode: request.websocket_delivery_mode,
        effective_serving_mode: request.effective_serving_mode
      },
      request_caller_pid: request_caller_pid,
      request_caller_monitor: request_caller_monitor,
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
      request,
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
         request,
         receive_state,
         connection_usage
       ) do
    if collect_compaction?(request) and
         not collect_connection_eligible?(state, key, request, connection_usage) do
      guard_connection_bound_continuation(state, receive_state, connection_usage)
    else
      connect_and_send_eligible_request(
        state,
        key,
        url,
        headers,
        timeouts,
        request,
        receive_state,
        connection_usage
      )
    end
  end

  defp connect_and_send_eligible_request(
         state,
         key,
         url,
         headers,
         timeouts,
         request,
         receive_state,
         connection_usage
       ) do
    case ensure_connection(state, key, url, headers, timeouts, request_caller(receive_state)) do
      {:ok, state} ->
        connection_use = connection_use(connection_usage)

        if Map.get(request, :connection_bound_continuation?, false) and
             connection_use != :reused do
          guard_connection_bound_continuation(state, receive_state, connection_usage)
        else
          send_request_payload(state, request, receive_state, connection_usage)
        end

      {:error, :client_disconnected, state} ->
        result = request_caller_down_result(state, receive_state)
        state = invalidate_state(state)
        {:ok, put_result_connection_metadata(result, state, connection_usage), state}

      {:error, reason, state} ->
        state =
          state
          |> Map.put(:transport_failure_phase, :connect)
          |> Map.put(:transport_failure_source, :connection_establish_error)

        {:error, reason, state}
    end
  end

  defp collect_connection_eligible?(state, key, request, connection_usage) do
    connection_use(connection_usage) == :reused and reusable_connection?(state, key) and
      Map.get(state, :last_successful_effective_serving_mode) == request.effective_serving_mode and
      request.effective_serving_mode in ["full", "lite"]
  end

  defp request_caller(%ReceiveState{
         request_caller_pid: request_caller_pid,
         request_caller_monitor: request_caller_monitor
       })
       when is_pid(request_caller_pid) and is_reference(request_caller_monitor),
       do: {request_caller_pid, request_caller_monitor}

  defp request_caller(%ReceiveState{}), do: nil

  defp guard_connection_bound_continuation(state, receive_state, connection_usage) do
    terminal =
      StreamProtocol.canonicalize_native_codex_responses_json_message(
        ~s({"type":"error","error":{"code":"previous_response_not_found"}})
      )

    decoded = decode_text_frame(terminal)

    {:halt, {:terminal, state, receive_state, "error"}} =
      handle_text_frame(state, receive_state, terminal, decoded, terminal, decoded)

    {{:ok, result}, state} =
      finish_receive_result({:terminal, state, receive_state, "error"})

    result =
      result
      |> Map.put(:upstream_error_param, "previous_response_id")
      |> Map.put(
        :transport_failure,
        TransportFailureReason.transport_failure_metadata(
          :previous_response_generation_mismatch,
          %{connection_use: connection_use(connection_usage)}
        )
      )

    {:ok, put_result_connection_metadata({:ok, result}, state, connection_usage), state}
  end

  defp send_request_payload(state, %Request{} = request, receive_state, connection_usage) do
    {state, receive_state} =
      begin_connection_request(state, receive_state, connection_usage)

    if request_caller_down?(receive_state) do
      result = request_caller_down_result(state, receive_state)
      state = state |> invalidate_state() |> complete_connection_request()
      {:ok, put_result_connection_metadata(result, state, connection_usage), state}
    else
      send_authorized_request_payload(state, request, receive_state, connection_usage)
    end
  end

  defp send_authorized_request_payload(state, request, receive_state, connection_usage) do
    with {:ok, state, consumed_phase} <- consume_request_capability(state, request),
         :ok <- trace_physical_send(:physical_send_started, request, :started),
         {:ok, state} <- send_text(state, request.payload),
         :ok <- trace_physical_send(:physical_send_finished, request, :ok) do
      {:ok, result, state} = await_sent_request(state, receive_state)

      state =
        state
        |> finalize_consumed_request(result, consumed_phase, request)
        |> maybe_record_successful_serving_mode(result, receive_state)
        |> complete_connection_request()

      {:ok, put_result_connection_metadata(result, state, connection_usage), state}
    else
      {:error, state} ->
        :ok =
          trace_physical_send(:physical_send_finished, request, {:error, :capability_rejected})

        {:error, :native_compaction_capability_rejected, state}

      {:error, reason, state} ->
        :ok = trace_physical_send(:physical_send_finished, request, {:error, reason})

        state =
          state
          |> clear_admission()
          |> Map.put(:transport_failure_phase, :send_payload)
          |> Map.put(:transport_failure_source, :payload_send_error)

        {:error, reason, state}
    end
  end

  @type consumed_admission_phase ::
          :compact | :final | {:first_full_history_compact, FirstCompactCollection.t()} | nil

  @spec consume_request_capability(map(), Request.t()) ::
          {:ok, map(), consumed_admission_phase()} | {:error, map()}
  defp consume_request_capability(
         state,
         %Request{
           native_compaction_capability: %Capability{} = capability,
           expected_connection_lifecycle: expected_lifecycle,
           forwarded_owner_send_handoff: nil
         }
       ) do
    now_ms = System.system_time(:millisecond)

    with true <- expected_lifecycle == connection_lifecycle_state(state),
         {:ok, admission} <-
           NativeCompactionAdmission.consume(admission_state(state), capability, now_ms) do
      :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :consumed)

      :ok =
        trace_capability(:capability_consumed, capability, %{
          pid_role: :upstream_session,
          upstream_pid: self()
        })

      {:ok, Map.put(state, :native_compaction_admission, admission), capability.phase}
    else
      _rejected -> {:error, clear_admission(state)}
    end
  end

  defp consume_request_capability(
         state,
         %Request{
           native_compaction_capability: nil,
           first_compact_collection: %FirstCompactCollection{} = provenance,
           expected_connection_lifecycle: expected_lifecycle,
           forwarded_owner_send_handoff: nil
         }
       ) do
    if expected_lifecycle == connection_lifecycle_state(state) and
         FirstCompactCollection.valid?(provenance) do
      {:ok, state, {:first_full_history_compact, provenance}}
    else
      {:error, clear_admission(state)}
    end
  end

  defp consume_request_capability(
         state,
         %Request{
           native_compaction_capability: nil,
           expected_connection_lifecycle: nil,
           forwarded_owner_send_handoff: %ForwardedOwnerRequestHandoff{} = handoff,
           effective_serving_mode: effective_serving_mode
         }
       ) do
    with {:ok, serving_mode} <- normalized_forwarded_serving_mode(effective_serving_mode),
         :ok <-
           ForwardedOwnerRequestHandoff.redeem(
             handoff,
             connection_lifecycle_state(state),
             serving_mode
           ) do
      {:ok, state, nil}
    else
      _rejected -> {:error, clear_admission(state)}
    end
  end

  defp consume_request_capability(
         state,
         %Request{
           native_compaction_capability: nil,
           expected_connection_lifecycle: nil,
           forwarded_owner_send_handoff: nil
         }
       ),
       do: {:ok, state, nil}

  defp consume_request_capability(state, %Request{}), do: {:error, clear_admission(state)}

  defp normalized_forwarded_serving_mode("full"), do: {:ok, :full}
  defp normalized_forwarded_serving_mode("lite"), do: {:ok, :lite}
  defp normalized_forwarded_serving_mode(:full), do: {:ok, :full}
  defp normalized_forwarded_serving_mode(:lite), do: {:ok, :lite}
  defp normalized_forwarded_serving_mode(_mode), do: {:error, :invalid_serving_mode}

  defp finalize_consumed_request(state, {:ok, _result}, :compact, _request) do
    case NativeCompactionAdmission.record_compact_collected(admission_state(state)) do
      {:ok, admission} -> Map.put(state, :native_compaction_admission, admission)
      {:error, _reason} -> clear_admission(state)
    end
  end

  defp finalize_consumed_request(
         state,
         {:ok, _result},
         :final,
         %Request{native_compaction_capability: %Capability{} = capability}
       ) do
    :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :acknowledged)
    :ok = trace_capability(:capability_acknowledged, capability, %{pid_role: :upstream_session})
    state
  end

  defp finalize_consumed_request(
         state,
         {:ok, _result},
         {:first_full_history_compact, %FirstCompactCollection{} = provenance},
         _request
       ) do
    case NativeCompactionAdmission.record_first_compact_collected(
           admission_state(state),
           provenance
         ) do
      {:ok, admission} -> Map.put(state, :native_compaction_admission, admission)
      {:error, _reason} -> clear_admission(state)
      {:error, _reason, admission} -> Map.put(state, :native_compaction_admission, admission)
    end
  end

  defp finalize_consumed_request(state, {:error, _result}, phase, _request)
       when phase in [:compact, :final],
       do: clear_admission(state)

  defp finalize_consumed_request(
         state,
         {:error, _result},
         {:first_full_history_compact, %FirstCompactCollection{}},
         _request
       ),
       do: clear_admission(state)

  defp finalize_consumed_request(state, _result, nil, _request), do: state

  defp maybe_record_successful_serving_mode(
         %{conn: _conn} = state,
         {:ok, %{terminal: terminal}},
         %ReceiveState{delivery: %Delivery{effective_serving_mode: mode}}
       )
       when terminal in ["response.completed", "response.done"] and mode in ["full", "lite"] do
    Map.put(state, :last_successful_effective_serving_mode, mode)
  end

  defp maybe_record_successful_serving_mode(state, _result, %ReceiveState{}), do: state

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
    attrs =
      %{
        phase: Map.get(state, :transport_failure_phase, :request),
        termination_source:
          Map.get(state, :transport_failure_source) || request_failure_source(reason),
        pre_visible_output: true,
        terminal_seen: false,
        text_frame_count: 0
      }
      |> Map.merge(Map.get(state, :current_request_diagnostics, %{}))

    TransportFailureReason.transport_failure_metadata(reason, attrs)
  end

  defp request_failure_source(:upstream_websocket_session_unavailable), do: :session_unavailable
  defp request_failure_source(_reason), do: nil

  defp begin_connection_request(state, %ReceiveState{} = receive_state, connection_usage) do
    now = System.monotonic_time(:millisecond)
    request_ordinal = Map.get(state, :connection_request_count, 0) + 1
    connection_started_at = Map.get(state, :connection_started_at_monotonic_ms, now)
    last_request_completed_at = Map.get(state, :last_request_completed_at_monotonic_ms)

    diagnostics = %{
      connection_use: connection_use(connection_usage),
      connection_request_bucket: connection_request_bucket(request_ordinal),
      connection_age_bucket: connection_age_bucket(now - connection_started_at),
      connection_idle_bucket: connection_idle_bucket(last_request_completed_at, now)
    }

    state =
      state
      |> Map.put(:connection_request_count, request_ordinal)
      |> Map.put(:current_request_diagnostics, diagnostics)

    receive_state =
      struct!(receive_state, %{
        connection_use: diagnostics.connection_use,
        connection_request_bucket: diagnostics.connection_request_bucket,
        connection_age_bucket: diagnostics.connection_age_bucket,
        connection_idle_bucket: diagnostics.connection_idle_bucket
      })

    {state, receive_state}
  end

  defp complete_connection_request(%{conn: _conn} = state) do
    state
    |> Map.put(:last_request_completed_at_monotonic_ms, System.monotonic_time(:millisecond))
    |> clear_current_request_diagnostics()
  end

  defp complete_connection_request(state), do: clear_current_request_diagnostics(state)

  defp clear_current_request_diagnostics(state) do
    state
    |> Map.delete(:current_request_diagnostics)
    |> Map.delete(:transport_failure_phase)
    |> Map.delete(:transport_failure_source)
  end

  defp connection_use(%{reconnected: true}), do: :reconnected
  defp connection_use(%{reused: true}), do: :reused
  defp connection_use(_connection_usage), do: :fresh

  defp connection_request_bucket(1), do: :first
  defp connection_request_bucket(value) when value in 2..5, do: :requests_2_5
  defp connection_request_bucket(value) when value in 6..20, do: :requests_6_20
  defp connection_request_bucket(value) when value in 21..50, do: :requests_21_50
  defp connection_request_bucket(_value), do: :requests_51_plus

  defp connection_age_bucket(value) when value < @one_minute_ms, do: :under_1m
  defp connection_age_bucket(value) when value < @five_minutes_ms, do: :minutes_1_5
  defp connection_age_bucket(value) when value < @fifteen_minutes_ms, do: :minutes_5_15
  defp connection_age_bucket(value) when value < @thirty_minutes_ms, do: :minutes_15_30
  defp connection_age_bucket(_value), do: :minutes_30_plus

  defp connection_idle_bucket(nil, _now), do: :first_request

  defp connection_idle_bucket(last_request_completed_at, now) do
    case max(now - last_request_completed_at, 0) do
      value when value < @five_seconds_ms -> :under_5s
      value when value < @thirty_seconds_ms -> :seconds_5_30
      value when value < @two_minutes_ms -> :seconds_30_to_2m
      value when value < @ten_minutes_ms -> :minutes_2_10
      value when value < @thirty_minutes_ms -> :minutes_10_30
      _value -> :minutes_30_plus
    end
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
    _trace =
      NativeCompactionTrace.emit_full(:upstream_websocket_frame_sent, %{
        direction: :pooler_to_upstream,
        upstream_pid: self(),
        frame_json: decode_text_frame(text),
        frame_text: text
      })

    case Mint.WebSocket.encode(websocket, {:text, text}) do
      {:ok, websocket, data} ->
        stream_request_body(%{state | websocket: websocket}, conn, ref, data)

      {:error, websocket, reason} ->
        _trace =
          NativeCompactionTrace.emit_full(:upstream_websocket_frame_send_failed, %{
            direction: :pooler_to_upstream,
            upstream_pid: self(),
            reason: reason
          })

        {:error, reason, %{state | websocket: websocket}}
    end
  end

  defp trace_physical_send(
         event,
         %Request{native_compaction_capability: %Capability{} = capability},
         outcome
       ),
       do:
         trace_capability(event, capability, %{
           pid_role: :upstream_session,
           upstream_pid: self(),
           outcome: trace_send_outcome(outcome),
           reason: trace_send_reason(outcome)
         })

  defp trace_physical_send(_event, _request, _outcome), do: :ok

  defp trace_send_outcome({:error, _reason}), do: :error
  defp trace_send_outcome(outcome), do: outcome
  defp trace_send_reason({:error, reason}), do: reason
  defp trace_send_reason(_outcome), do: nil

  defp trace_capability(event, capability, metadata) do
    case NativeCompactionTrace.emit_capability(event, capability, metadata) do
      :ignored -> :ok
      :ok -> :ok
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
    request_caller_pid = receive_state.request_caller_pid
    request_caller_monitor = receive_state.request_caller_monitor

    receive do
      {:DOWN, ^request_caller_monitor, :process, ^request_caller_pid, _reason}
      when is_reference(request_caller_monitor) and is_pid(request_caller_pid) ->
        {request_caller_down_result(state, receive_state), invalidate_state(state)}

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
        result =
          {:error,
           %{
             body: receive_body(receive_state),
             reason: :upstream_websocket_receive_timeout,
             headers: state.headers,
             upstream_error_param: receive_state.terminal_upstream_error_param,
             websocket_frame_headers: receive_state.websocket_frame_headers,
             transport_failure:
               transport_failure_metadata(
                 :upstream_websocket_receive_timeout,
                 state,
                 receive_state,
                 phase: :receive_timeout,
                 termination_source: :pooler_receive_timeout
               )
           }}

        {result, invalidate_state(state)}
    end
  end

  defp request_caller_down?(%ReceiveState{
         request_caller_pid: request_caller_pid,
         request_caller_monitor: request_caller_monitor
       })
       when is_pid(request_caller_pid) and is_reference(request_caller_monitor) do
    receive do
      {:DOWN, ^request_caller_monitor, :process, ^request_caller_pid, _reason} -> true
    after
      0 -> false
    end
  end

  defp request_caller_down?(%ReceiveState{}), do: false

  defp request_caller_down_result(state, %ReceiveState{} = receive_state) do
    {:error,
     %{
       body: receive_body(receive_state),
       reason: :client_disconnected,
       headers: Map.get(state, :headers, []),
       upstream_error_param: receive_state.terminal_upstream_error_param,
       websocket_frame_headers: receive_state.websocket_frame_headers,
       transport_failure:
         transport_failure_metadata(:client_disconnected, state, receive_state,
           phase: :receive,
           termination_source: :request_caller_down
         )
     }}
  end

  defp handle_event_message(
         %{conn: conn} = state,
         %ReceiveState{} = receive_state,
         message
       ) do
    receive_state = %{receive_state | transport_signal: transport_signal(message)}

    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        handle_parts(state, responses, receive_state)

      {:error, conn, reason, responses} ->
        handle_transport_error_parts(%{state | conn: conn}, responses, receive_state, reason)

      :unknown ->
        receive_events(state, %{receive_state | transport_signal: nil})
    end
  end

  # Mint can hand back responses that were fully parsed before the transport
  # error surfaced (mint_web_socket returns the pending data batch when
  # re-arming the socket fails because the peer already closed). A terminal in
  # that batch is a completed upstream turn; anything short of a halting
  # outcome still fails with the original reason over the updated state.
  defp handle_transport_error_parts(state, responses, %ReceiveState{} = receive_state, reason) do
    responses
    |> Enum.reduce_while({:continue, state, receive_state}, &handle_part/2)
    |> case do
      {:continue, state, receive_state} ->
        {transport_error_result(state, receive_state, reason), state}

      halted ->
        {result, state} = finish_receive_result(halted)
        {result, close_state(state)}
    end
  end

  defp transport_error_result(state, %ReceiveState{} = receive_state, reason) do
    {:error,
     %{
       body: receive_body(receive_state),
       reason: reason,
       headers: state.headers,
       upstream_error_param: receive_state.terminal_upstream_error_param,
       websocket_frame_headers: receive_state.websocket_frame_headers,
       transport_failure:
         transport_failure_metadata(reason, state, receive_state,
           phase: :receive,
           termination_source: :mint_transport_error
         )
     }}
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
           transport_failure_metadata(
             :upstream_websocket_pong_deadline,
             state,
             receive_state,
             phase: :receive,
             termination_source: :pooler_pong_deadline
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
    receive_state = %{receive_state | termination_source: :mint_stream_done}
    {:halt, {:failure, state, receive_state, :upstream_websocket_closed_before_terminal}}
  end

  defp handle_part(_part, result), do: {:cont, result}

  defp finish_receive_result(result) do
    case result do
      {:continue, state, receive_state} ->
        receive_events(state, %{receive_state | transport_signal: nil})

      {:terminal, state, receive_state, terminal} ->
        result =
          %{
            body: receive_body(receive_state),
            terminal: terminal,
            status: 200,
            headers: Map.get(state, :headers, []),
            upstream_error_code: receive_state.terminal_upstream_error_code,
            upstream_error_param: receive_state.terminal_upstream_error_param,
            websocket_frame_headers: receive_state.websocket_frame_headers
          }
          |> maybe_put_success_response_id(terminal, receive_state.response_id)

        {{:ok, result}, state}

      {:failure, state, receive_state, reason} ->
        {{:error,
          %{
            body: receive_body(receive_state),
            reason: reason,
            headers: Map.get(state, :headers, []),
            upstream_error_param: receive_state.terminal_upstream_error_param,
            websocket_frame_headers: receive_state.websocket_frame_headers,
            transport_failure:
              transport_failure_metadata(reason, state, receive_state,
                phase: failure_phase(reason)
              )
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

        receive_state = %{receive_state | termination_source: :websocket_decode_error}
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

      {:error, _reason}, state ->
        {:halt, close_state(state)}
    end)
  end

  defp handle_frames(state, frames, %ReceiveState{} = receive_state) do
    Enum.reduce_while(frames, {:continue, state, receive_state}, fn
      {:text, raw_text}, {:continue, state, receive_state} ->
        raw_decoded = decode_text_frame(raw_text)

        {mapped_text, mapped_decoded} =
          map_message(raw_text, raw_decoded, receive_state.message_mapper)

        handle_text_frame(
          state,
          receive_state,
          raw_text,
          raw_decoded,
          mapped_text,
          mapped_decoded
        )

      {:ping, payload}, {:continue, state, receive_state} ->
        case send_frame(state, {:pong, payload}) do
          {:ok, state} ->
            {:cont, {:continue, state, receive_state}}

          {:error, reason, state} ->
            receive_state = %{
              receive_state
              | termination_source: :websocket_control_send_error
            }

            {:halt, {:failure, state, receive_state, {:websocket_control_send_failed, reason}}}
        end

      {:pong, payload}, {:continue, state, receive_state} ->
        {:cont, {:continue, clear_matching_pong(state, payload), receive_state}}

      {:close, code, reason}, {:continue, state, receive_state} ->
        receive_state = %{
          receive_state
          | peer_close_metadata: TransportFailureReason.peer_close_metadata(code, reason),
            termination_source: :peer_close_frame
        }

        {:halt, {:failure, state, receive_state, :upstream_websocket_closed_before_terminal}}

      {:binary, _data}, {:continue, state, receive_state} ->
        receive_state = %{receive_state | termination_source: :unexpected_binary_frame}
        {:halt, {:failure, state, receive_state, :unexpected_upstream_websocket_binary}}
    end)
  end

  defp append_receive_body(%ReceiveState{body: body} = receive_state, text) do
    %{receive_state | body: RetainedBody.append(body, ["data: ", text, "\n\n"])}
  end

  defp handle_text_frame(
         state,
         %ReceiveState{} = receive_state,
         raw_text,
         raw_decoded,
         mapped_text,
         mapped_decoded
       ) do
    _trace =
      NativeCompactionTrace.emit_full(:upstream_websocket_frame_received, %{
        direction: :upstream_to_pooler,
        upstream_pid: self(),
        raw_frame_json: raw_decoded,
        raw_frame_text: raw_text,
        mapped_frame_json: mapped_decoded,
        mapped_frame_text: mapped_text
      })

    terminal_discriminator = TerminalDiscriminator.classify(mapped_decoded)

    receive_state =
      raw_decoded
      |> maybe_put_terminal_upstream_error(receive_state)
      |> maybe_put_response_id(raw_decoded)
      |> put_websocket_frame_headers(raw_decoded)
      |> increment_text_frame_count()
      |> append_receive_body(mapped_text)
      |> put_terminal_discriminator(terminal_discriminator)

    case retryable_first_text_frame(raw_decoded, receive_state) do
      {:ok, reason} ->
        receive_state = %{receive_state | termination_source: :upstream_terminal_event}
        {:halt, {:failure, state, receive_state, reason}}

      :error ->
        receive_state = maybe_mark_downstream_output_started(receive_state, raw_decoded)
        observe_frame(receive_state, raw_text, raw_decoded)
        receive_state = maybe_write_native_metadata(state, receive_state)

        {text, _decoded} =
          sanitize_downstream_text(
            {mapped_text, mapped_decoded},
            receive_state.native_codex_response_control
          )

        write_frame(receive_state.writer, text, terminal_discriminator)

        case terminal_discriminator.terminal do
          nil -> {:cont, {:continue, state, receive_state}}
          terminal -> {:halt, {:terminal, state, mark_terminal_seen(receive_state), terminal}}
        end
    end
  end

  defp transport_failure_metadata(
         reason,
         state,
         %ReceiveState{} = receive_state,
         attrs
       ) do
    TransportFailureReason.transport_failure_metadata(
      reason,
      Map.merge(
        %{
          termination_source: receive_state.termination_source,
          transport_signal: receive_state.transport_signal,
          connection_use: receive_state.connection_use,
          connection_request_bucket: receive_state.connection_request_bucket,
          connection_age_bucket: receive_state.connection_age_bucket,
          connection_idle_bucket: receive_state.connection_idle_bucket,
          pre_visible_output: not receive_state.downstream_output_started?,
          upstream_committed: true,
          terminal_seen: receive_state.terminal_seen?,
          last_upstream_event_type: receive_state.last_upstream_event_type,
          last_upstream_event_class: receive_state.last_upstream_event_class,
          terminal_candidate_seen: receive_state.terminal_candidate_seen?,
          terminal_candidate_type: receive_state.terminal_candidate_type,
          terminal_candidate_class: receive_state.terminal_candidate_class,
          terminal_candidate_rejection: receive_state.terminal_candidate_rejection,
          text_frame_count: receive_state.text_frame_count
        },
        state
        |> websocket_decoder_metadata()
        |> Map.merge(receive_state.peer_close_metadata)
        |> Map.merge(Map.new(attrs))
      )
    )
  end

  defp failure_phase({:websocket_decode_failed, _reason}), do: :decode
  defp failure_phase({:websocket_control_send_failed, _reason}), do: :send_control
  defp failure_phase(:upstream_websocket_closed_before_terminal), do: :upstream_close
  defp failure_phase(:unexpected_upstream_websocket_binary), do: :unexpected_frame
  defp failure_phase(_reason), do: :receive

  defp transport_signal({:tcp, _socket, _data}), do: :tcp_data
  defp transport_signal({:ssl, _socket, _data}), do: :ssl_data
  defp transport_signal({:tcp_closed, _socket}), do: :tcp_closed
  defp transport_signal({:ssl_closed, _socket}), do: :ssl_closed
  defp transport_signal({:tcp_error, _socket, _reason}), do: :tcp_error
  defp transport_signal({:ssl_error, _socket, _reason}), do: :ssl_error

  defp websocket_decoder_metadata(%{websocket: websocket}) when is_map(websocket) do
    # Mint.WebSocket.t/0 is opaque. These defensive projections retain only
    # bounded state and disappear safely if a future dependency removes a field.
    %{
      websocket_buffer_bucket: websocket_buffer_bucket(Map.get(websocket, :buffer)),
      websocket_fragment_open:
        if(Map.has_key?(websocket, :fragment),
          do: not is_nil(Map.get(websocket, :fragment)),
          else: nil
        )
    }
  end

  defp websocket_decoder_metadata(_state), do: %{}

  defp websocket_buffer_bucket(buffer) when is_binary(buffer) do
    case byte_size(buffer) do
      0 -> :empty
      value when value <= 125 -> :bytes_1_125
      value when value <= 1_024 -> :bytes_126_1024
      _value -> :bytes_1025_plus
    end
  end

  defp websocket_buffer_bucket(_buffer), do: nil

  defp retryable_first_text_frame(
         %{} = decoded,
         %ReceiveState{downstream_output_started?: false} = receive_state
       ) do
    decoded
    |> StreamProtocol.event_summary()
    |> retryable_pre_visible_terminal_event(receive_state)
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

  defp maybe_mark_downstream_output_started(
         %ReceiveState{delivery: %Delivery{mode: :collect_compaction}} = receive_state,
         _decoded
       ),
       do: receive_state

  defp maybe_mark_downstream_output_started(%ReceiveState{} = receive_state, decoded) do
    if StreamProtocol.internal_control_event?(decoded) do
      receive_state
    else
      %{receive_state | downstream_output_started?: true}
    end
  end

  defp increment_text_frame_count(%ReceiveState{text_frame_count: count} = receive_state) do
    %{receive_state | text_frame_count: count + 1}
  end

  defp put_terminal_discriminator(
         %ReceiveState{} = receive_state,
         %TerminalDiscriminator{} = terminal_discriminator
       ) do
    receive_state = %{
      receive_state
      | last_upstream_event_type: terminal_discriminator.last_upstream_event_type,
        last_upstream_event_class: terminal_discriminator.last_upstream_event_class
    }

    if terminal_discriminator.terminal_candidate? do
      %{
        receive_state
        | terminal_candidate_seen?: true,
          terminal_candidate_type: terminal_discriminator.terminal_candidate_type,
          terminal_candidate_class: terminal_discriminator.terminal_candidate_class,
          terminal_candidate_rejection: terminal_discriminator.terminal_candidate_rejection
      }
    else
      receive_state
    end
  end

  defp mark_terminal_seen(%ReceiveState{} = receive_state),
    do: %{receive_state | terminal_seen?: true}

  defp maybe_put_terminal_upstream_error(%{} = decoded, %ReceiveState{} = receive_state) do
    case Map.get(decoded, "type") do
      type when type in ["response.failed", "response.incomplete", "error"] ->
        %{
          receive_state
          | terminal_upstream_error_code:
              receive_state.terminal_upstream_error_code ||
                StreamProtocol.upstream_error_code(decoded),
            terminal_upstream_error_param:
              receive_state.terminal_upstream_error_param || UpstreamErrorParam.extract(decoded)
        }

      _other ->
        receive_state
    end
  end

  defp maybe_put_terminal_upstream_error(_decoded, %ReceiveState{} = receive_state),
    do: receive_state

  defp maybe_put_success_response_id(result, terminal, response_id)
       when terminal in ["response.completed", "response.done"] and is_binary(response_id),
       do: Map.put(result, :response_id, response_id)

  defp maybe_put_success_response_id(result, _terminal, _response_id), do: result

  @response_identity_event_types [
    "response.created",
    "response.in_progress",
    "response.queued",
    "response.completed",
    "response.done"
  ]
  @max_response_id_bytes 1_024

  defp maybe_put_response_id(%ReceiveState{response_id: nil} = receive_state, %{} = decoded) do
    response_id =
      case Map.fetch(decoded, "type") do
        {:ok, type} when type in @response_identity_event_types ->
          get_in(decoded, ["response", "id"])

        :error ->
          Map.get(decoded, "id")

        _typed_or_invalid ->
          nil
      end

    case bounded_response_id(response_id) do
      nil -> receive_state
      response_id -> %{receive_state | response_id: response_id}
    end
  end

  defp maybe_put_response_id(%ReceiveState{} = receive_state, _decoded), do: receive_state

  defp bounded_response_id(response_id) when is_binary(response_id) do
    response_id = String.trim(response_id)

    if response_id != "" and byte_size(response_id) <= @max_response_id_bytes,
      do: response_id
  end

  defp bounded_response_id(_response_id), do: nil

  defp put_websocket_frame_headers(%ReceiveState{} = receive_state, decoded) do
    case StreamProtocol.websocket_error_frame_headers(decoded) do
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

  defp observe_frame(%ReceiveState{frame_observer: observer}, text, decoded) do
    case observer_arity(observer) do
      2 -> observe_frame_observer(fn -> observer.(text, decoded) end)
      1 -> observe_frame_observer(fn -> observer.(text) end)
      nil -> :ok
    end
  end

  defp observer_arity(observer) when is_function(observer, 2), do: 2
  defp observer_arity(observer) when is_function(observer, 1), do: 1
  defp observer_arity(_observer), do: nil

  defp observe_frame_observer(observer) do
    observer.()
  rescue
    exception -> report_frame_observer_failure(:error, exception.__struct__)
  catch
    kind, _reason when kind in [:throw, :exit] -> report_frame_observer_failure(kind, nil)
  end

  defp report_frame_observer_failure(failure_kind, exception_class) do
    Logger.warning(
      "upstream websocket frame observer failed operation=observe_frame " <>
        "failure_kind=#{failure_kind} exception_class=#{exception_class || "none"}"
    )
  end

  defp maybe_write_native_metadata(
         state,
         %ReceiveState{
           native_codex_response_control: %TurnSnapshot{models_etag: models_etag},
           native_metadata_emitted?: false
         } = receive_state
       ) do
    metadata = NativeCodexResponseControl.pooler_metadata_event(models_etag, state.headers)
    write_frame(receive_state.writer, Jason.encode!(metadata), %TerminalDiscriminator{})
    %{receive_state | native_metadata_emitted?: true}
  end

  defp maybe_write_native_metadata(_state, %ReceiveState{} = receive_state), do: receive_state

  defp write_frame(writer, text, terminal_discriminator) when is_function(writer, 2),
    do: writer.(text, terminal_discriminator)

  defp write_frame(writer, text, _terminal_discriminator) when is_function(writer, 1),
    do: writer.(text)

  defp write_frame(nil, _text, _terminal_discriminator), do: :ok

  defp map_message(text, %{} = decoded, mapper) when is_function(mapper, 1) do
    cond do
      mapper == (&StreamProtocol.normalize_public_openai_responses_json_message/1) ->
        StreamProtocol.normalize_public_openai_responses_json_message(text, decoded)

      mapper == (&StreamProtocol.canonicalize_native_codex_responses_json_message/1) ->
        StreamProtocol.canonicalize_native_codex_responses_json_message(text, decoded)

      mapper == (&StreamProtocol.canonicalize_codex_responses_json_message/1) ->
        StreamProtocol.canonicalize_codex_responses_json_message(text, decoded)

      true ->
        mapped = mapper.(text)
        {mapped, if(mapped == text, do: decoded, else: decode_text_frame(mapped))}
    end
  end

  defp map_message(text, decoded, mapper) when is_function(mapper, 1) do
    mapped = mapper.(text)
    {mapped, if(mapped == text, do: decoded, else: decode_text_frame(mapped))}
  end

  defp map_message(text, decoded, _mapper), do: {text, decoded}

  defp sanitize_downstream_text({text, %{} = decoded}, %TurnSnapshot{}) when is_binary(text) do
    case NativeCodexResponseControl.sanitize_websocket_event(decoded) do
      :unchanged -> {text, decoded}
      {:changed, sanitized} -> {Jason.encode!(sanitized), sanitized}
      {:error, :invalid_event} -> {text, decoded}
    end
  end

  defp sanitize_downstream_text({text, %{} = decoded}, _native_snapshot) when is_binary(text) do
    case Map.get(decoded, "type") do
      type
      when type in ["response.completed", "response.failed", "response.incomplete", "error"] ->
        sanitized = Map.drop(decoded, ["headers"])
        {Jason.encode!(sanitized), sanitized}

      _other ->
        {text, decoded}
    end
  end

  defp sanitize_downstream_text({text, decoded}, _native_snapshot), do: {text, decoded}

  defp decode_text_frame(text) do
    case Jason.decode(text) do
      {:ok, %{} = decoded} -> decoded
      {:ok, _decoded} -> :non_object_json
      {:error, _reason} -> :undecodable
    end
  end

  defp send_frame(state, frame), do: WebsocketFrameWriter.send_frame(state, frame)

  defp websocket_body(body), do: RetainedBody.read(body)

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
    {:ok, _conn} = Mint.HTTP.close(conn)

    state
    |> cancel_keepalive()
    |> cancel_pong_deadline()
    |> clear_admission()
    |> disconnected_state()
  end

  defp close_state(state) do
    state
    |> cancel_keepalive()
    |> cancel_pong_deadline()
    |> clear_admission()
    |> disconnected_state()
  end

  defp invalidate_state(state) do
    state
    |> close_state()
    |> Map.put(:reconnect_pending?, true)
  end

  defp disconnected_state(state) do
    lifecycle =
      state
      |> connection_lifecycle_state()
      |> preserve_trace_sensitivity(state)

    if Map.get(state, :reconnect_pending?, false) do
      Map.put(lifecycle, :reconnect_pending?, true)
    else
      lifecycle
    end
  end

  defp admission_state(state) do
    Map.get(state, :native_compaction_admission, %NativeCompactionAdmission{phase: :cleared})
  end

  defp clear_admission(state), do: Map.delete(state, :native_compaction_admission)

  defp put_trace_sensitivity(state, sensitivity) do
    if sensitivity == :sensitive,
      do: state,
      else: Map.put(state, :native_compaction_trace_sensitivity, sensitivity)
  end

  defp preserve_trace_sensitivity(lifecycle, state) do
    case Map.fetch(state, :native_compaction_trace_sensitivity) do
      {:ok, sensitivity} -> Map.put(lifecycle, :native_compaction_trace_sensitivity, sensitivity)
      :error -> lifecycle
    end
  end

  defp emit_reservation_observations(%Capability{} = capability) do
    # One successful owner reserve operation proves both issuance and the
    # immediately stored reserved state. Neither fact is emitted on failure.
    :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :owner_issued)
    :ok = NativeCompactionAuthorizationObservation.emit_capability(capability, :reserved)

    _trace =
      NativeCompactionTrace.emit_capability(:capability_reserved, capability, %{
        pid_role: :upstream_session,
        upstream_pid: self(),
        branch: :direct_owner
      })

    :ok
  end

  defp validate_direct_binding(state, %Binding{topology: %Direct{}} = binding) do
    if binding.lifecycle_id == state.lifecycle_id and binding.generation == state.generation and
         state.generation > 0 do
      :ok
    else
      {:error, :binding_mismatch}
    end
  end

  defp validate_direct_binding(_state, %Binding{}), do: {:error, :binding_mismatch}

  defp reply_with_admission({:ok, admission}, state) do
    {:reply, :ok, Map.put(state, :native_compaction_admission, admission)}
  end

  defp reply_with_admission({:error, reason}, state) do
    {:reply, {:error, reason}, clear_admission(state)}
  end

  defp status_reason_class(%module{}) when is_atom(module), do: {:exception, module}
  defp status_reason_class(reason) when is_atom(reason), do: {:reason, reason}
  defp status_reason_class({reason, _detail}) when is_atom(reason), do: {:reason, reason}
  defp status_reason_class(_reason), do: :unknown

  defp status_message_class({:request, %Request{}}), do: :request
  defp status_message_class({:send_text, _payload}), do: :send_text
  defp status_message_class(:invalidate_connection), do: :invalidate_connection
  defp status_message_class(:connection_lifecycle_snapshot), do: :lifecycle_snapshot
  defp status_message_class(:compaction_admission_phase), do: :admission_phase
  defp status_message_class(:clear_compaction_admission), do: :admission_clear

  defp status_message_class({operation, _arg})
       when operation in [
              :record_first_compact_collected,
              :acknowledge_compact_finalization,
              :acknowledge_final_response
            ],
       do: operation

  defp status_message_class({operation, _arg1, _arg2})
       when operation in [
              :arm_compact,
              :authorize_first_compact_collection,
              :mark_compaction_accounting_started,
              :cancel_compaction_reservation
            ],
       do: operation

  defp status_message_class({:reserve_compaction, _phase, _binding, _control_ref, _now_ms}),
    do: :reserve_compaction

  defp status_message_class({:upstream_websocket_keepalive, _token}),
    do: :keepalive

  defp status_message_class({:upstream_websocket_pong_deadline, _token}),
    do: :pong_deadline

  defp status_message_class(_message), do: :transport_message

  defp status_state(state) do
    lifecycle = connection_lifecycle_state(state)

    Map.merge(lifecycle, %{
      connected?: Map.has_key?(state, :conn),
      reconnect_pending?: Map.get(state, :reconnect_pending?, false) == true,
      request_active?: Map.has_key?(state, :current_request_diagnostics),
      keepalive_pending?: Map.has_key?(state, :keepalive_ref),
      pong_pending?: Map.has_key?(state, :keepalive_pong_ref),
      admission_phase: NativeCompactionAdmission.phase(admission_state(state))
    })
  end
end
