defmodule CodexPoolerWeb.CodexResponsesSocket do
  @moduledoc false

  @behaviour WebSock

  alias CodexPooler.Access
  alias CodexPooler.Events
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.{CompactionTrigger, NativeCodexTurnMetadata}
  alias CodexPooler.Gateway.Payloads.PayloadNormalizer
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.Websocket.{ActivityRegistry, WebsocketOwnerContract}
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionTrace
  alias CodexPooler.Gateway.Transports.Websocket.RemoteReconnectControlV2
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerAdmissionControlV1
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Gateway.Websocket.Adapter
  alias CodexPooler.Gateway.Websocket.DirectCleanup
  alias CodexPooler.Gateway.Websocket.DownstreamSession
  alias CodexPooler.Gateway.Websocket.ResponseTask
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Cache, as: InstanceSettingsCache
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Firewall
  alias CodexPoolerWeb.WebsocketConnectionLogger
  alias CodexPoolerWeb.WebsocketResponseTaskFailureDiagnostics

  require Logger

  @pre_cleanup_response_task_drain_ms 250
  @post_cleanup_owner_response_task_drain_ms 15_000
  @post_cleanup_response_task_drain_ms 5_000
  @firewall_close_detail {1008, "client IP is no longer allowed"}
  @api_key_close_detail {1008, "api key is no longer active"}
  @api_key_disabling_statuses ["paused", "revoked"]

  @impl WebSock
  def init(state) do
    started_at = System.monotonic_time(:millisecond)

    case Websocket.prepare_websocket_session(state.auth, state.opts) do
      {:ok,
       %{
         codex_session: _session,
         websocket_owner_lease_token: _owner_lease_token,
         websocket_owner_downstream: _downstream
       } = runtime} ->
        state
        |> put_socket_lifecycle_state()
        |> put_response_task_state()
        |> Adapter.put_runtime(runtime)
        |> initialize_revocation_state()

      {:ok, %{codex_session: session, upstream_websocket_session: upstream_websocket_session}} ->
        state
        |> put_socket_lifecycle_state()
        |> put_response_task_state()
        |> Map.put(:codex_session, session)
        |> Map.put(:upstream_websocket_session, upstream_websocket_session)
        |> initialize_revocation_state()

      {:error, reason} ->
        init_error(reason, state, started_at)
    end
  end

  @impl WebSock
  def handle_in({_payload, [opcode: opcode]} = frame, state) when opcode in [:text, :binary] do
    if socket_revoked?(state) do
      {:ok, state}
    else
      handle_authorized_in(frame, state)
    end
  end

  defp handle_authorized_in({_payload, [opcode: opcode]} = frame, state)
       when opcode in [:text, :binary] do
    case refresh_api_key_authorization(state) do
      {:authorized, state} -> handle_unrevoked_in(frame, state)
      {:revoked, state} -> close_if_revoked_idle({:ok, state})
    end
  end

  defp handle_unrevoked_in({payload, [opcode: :text]}, state) when is_binary(payload) do
    _trace =
      NativeCompactionTrace.emit_full(:downstream_websocket_frame_received, %{
        direction: :downstream_to_pooler,
        opcode: :text,
        socket_pid: self(),
        frame_json: decode_trace_frame(payload),
        frame_text: payload
      })

    prepare_and_dispatch_response(payload, state)
  end

  defp handle_unrevoked_in({_payload, [opcode: :binary]}, state) do
    {:stop, :unsupported_binary_frame, {1003, "binary frames are not supported"}, state}
  end

  @impl WebSock
  def handle_info(
        {InstanceSettingsCache, {:applied, applied_version}},
        state
      )
      when is_integer(applied_version) do
    handle_firewall_applied(applied_version, state)
  end

  def handle_info(
        {Events, %Events.Event{pool_id: pool_id, topics: topics, payload: payload}},
        state
      )
      when is_list(topics) and is_map(payload) do
    if "pools" in topics and Map.get(state, :api_key_pool_id) == pool_id do
      payload
      |> handle_api_key_event(state)
      |> close_if_revoked_idle()
    else
      {:ok, state}
    end
  end

  # Chunks are attributed to their producing turn by pid. A chunk from a task the
  # socket no longer tracks belongs to a turn that already settled, so it is
  # dropped rather than injected into whatever turn is running now.
  def handle_info({:codex_response_chunk, task_pid, data}, state)
      when is_pid(task_pid) and is_binary(data) do
    _trace =
      NativeCompactionTrace.emit_full(:downstream_websocket_frame_sent, %{
        direction: :pooler_to_downstream,
        response_task_pid: task_pid,
        socket_pid: self(),
        frame_json: decode_trace_frame(data),
        frame_text: data
      })

    cond do
      active_public_turn?(state, task_pid) and not public_turn_aborted?(state) ->
        public_chunk_result(data, state)

      tracked_response_task?(state, task_pid) and
          not Adapter.public_responses_stream?(state) ->
        state =
          state
          |> maybe_mark_native_turn_output_pushed(task_pid, data)
          |> maybe_accept_response_task_terminal(task_pid, data)
          |> maybe_schedule_accepted_response_task_delivery(task_pid)

        {:push, {:text, Adapter.downstream_response_chunk(data)}, state}

      true ->
        {:ok, state}
    end
  end

  def handle_info({:websocket_owner_runtime_recovered, _, _, _} = message, state) do
    case Adapter.accept_recovered_runtime(message, state) do
      {:ok, state} -> {:ok, reset_owner_turn_output(state)}
      :drop -> {:ok, state}
    end
  end

  def handle_info(
        {:websocket_owner_handoff_ready, _correlation_id, _epoch, _owner_turn_id, _downstream_pid,
         _control_ref} = message,
        state
      ) do
    handle_owner_handoff_message(message, state)
  end

  def handle_info(
        {:websocket_owner_handoff_failed, _correlation_id, _epoch, _owner_turn_id,
         _downstream_pid, _control_ref, _reason} = message,
        state
      ) do
    handle_owner_handoff_message(message, state)
  end

  def handle_info(
        {:websocket_owner_cleanup_witness, _correlation, _epoch, _task, _witness} = message,
        state
      ) do
    {:ok, DownstreamSession.accept_cleanup_witness(message, state)}
  end

  def handle_info(
        {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id, _payload} = message,
        state
      ) do
    message
    |> handle_owner_frame(state)
    |> close_if_revoked_idle()
  end

  def handle_info(
        {:websocket_owner_output_commit_probe, _correlation_id, _epoch, _owner_turn_id,
         _active_turn_ref, _owner_pid, _probe_ref} = message,
        state
      ) do
    handle_output_commit_probe(message, state)
  end

  def handle_info({:websocket_owner_frame, _correlation_id, _epoch, _payload} = message, state) do
    message
    |> handle_owner_frame(state)
    |> close_if_revoked_idle()
  end

  def handle_info({:websocket_response_activity, pid, token}, state)
      when is_pid(pid) and is_reference(token) do
    _trace =
      NativeCompactionTrace.emit(:response_task_started, %{
        pid_role: :response_task,
        response_task_pid: pid,
        activity_token: token
      })

    state =
      state
      |> put_response_task_activity(pid, token)
      |> maybe_schedule_accepted_response_task_delivery(pid)

    {:ok, state}
  end

  def handle_info({:direct_request_cleanup, pid, ref, receipt}, state) do
    {:ok, accept_direct_cleanup(state, pid, ref, receipt)}
  end

  def handle_info({:codex_response_done, pid, result}, state) when is_pid(pid) do
    _trace =
      NativeCompactionTrace.emit(:finalization_finished, %{
        pid_role: :response_task,
        response_task_pid: pid,
        activity_token: get_in(state, [:response_task_activities, pid]),
        outcome: response_result_outcome(result)
      })

    state =
      state
      |> mark_response_task_result_ready(pid)
      |> put_response_task_cleanup_result(pid, result)

    result =
      pid
      |> handle_response_done(result, state)
      |> maybe_schedule_response_delivery(pid)

    close_if_revoked_idle(result)
  end

  def handle_info({:websocket_response_delivery_complete, pid, token}, state)
      when is_pid(pid) and is_reference(token) do
    state = complete_response_task_delivery(state, pid, token)
    close_if_revoked_idle({:ok, state})
  end

  def handle_info(
        {:websocket_response_activity_cancelled, pid, token, ack_pid, :owner_drained},
        state
      )
      when is_pid(pid) and is_reference(token) and is_pid(ack_pid) do
    handle_cancelled_response_activity(state, pid, token, ack_pid)
    |> close_if_revoked_idle()
  end

  def handle_info({:websocket_response_activity_cancelled, pid, token, :owner_drained}, state)
      when is_pid(pid) and is_reference(token) do
    handle_cancelled_response_activity(state, pid, token, pid)
    |> close_if_revoked_idle()
  end

  def handle_info({:public_response_start_error, ref, reason}, state)
      when is_reference(ref) do
    if Map.get(state, :public_response_start_error_ref) == ref do
      payload = encode_public_error(reason, state)

      state =
        state
        |> Map.put(:public_response_start_error_ref, nil)
        |> maybe_start_queued_response_task()

      close_if_revoked_idle({:push, {:text, payload}, state})
    else
      {:ok, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{websocket_owner_monitor: ref} = state) do
    state =
      state
      |> clear_pending_owner_handoff(owner_monitor_handoff_outcome(reason), cancel?: false)
      |> maybe_abort_public_owner_turn(:owner_monitor_down)

    case Adapter.handle_monitor_down(state, pid, reason) do
      {:ok, state} ->
        close_if_revoked_idle({:ok, state})

      {:stop, close_detail, state} ->
        close_if_revoked_idle({:stop, :normal, close_detail, state})
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    result =
      cond do
        active_public_task_monitor?(state, pid, ref) and public_turn_aborted?(state) ->
          {:ok, remove_tracked_response_task(state, pid, ref)}

        active_public_task_monitor?(state, pid, ref) and
            not Map.get(state, :public_turn_task_done?, false) ->
          state =
            state
            |> remove_tracked_response_task(pid, ref)
            |> abort_public_turn(:response_task_down)

          {:stop, :normal, {1011, "websocket response task failed"}, state}

        true ->
          state =
            state
            |> remove_tracked_response_task(pid, ref)
            |> remove_native_turn_output(pid)
            |> maybe_start_queued_response_task()

          {:ok, state}
      end

    close_if_revoked_idle(result)
  end

  def handle_info(_message, state), do: {:ok, state}

  defp handle_response_done(pid, result, state) do
    case api_key_revocation_disposition(result) do
      {:revoked, disabling_epoch} ->
        state =
          state
          |> remove_tracked_response_task(pid)
          |> remove_native_turn_output(pid)
          |> finish_revoked_public_turn(pid)
          |> revoke_api_key(disabling_epoch)

        {:ok, state}

      :other ->
        cond do
          active_public_turn?(state, pid) ->
            handle_public_response_done(pid, result, state)

          Adapter.public_responses_stream?(state) and not tracked_response_task?(state, pid) ->
            {:ok, state}

          true ->
            handle_non_public_response_done(pid, result, state)
        end
    end
  end

  defp finish_revoked_public_turn(state, pid) do
    if active_public_turn?(state, pid), do: finish_public_turn(state), else: state
  end

  defp api_key_revocation_disposition({:socket_response_result, _source, result}),
    do: api_key_revocation_disposition(result)

  defp api_key_revocation_disposition({:response_task_result, result, _visible_output?}),
    do: api_key_revocation_disposition(result)

  defp api_key_revocation_disposition({:response_task_failure, result}),
    do: api_key_revocation_disposition(result)

  defp api_key_revocation_disposition({:error, %{code: code, disabling_epoch: disabling_epoch}})
       when code in [
              :api_key_paused,
              :api_key_revoked,
              :api_key_inactive,
              :api_key_runtime_epoch_stale
            ] and is_integer(disabling_epoch),
       do: {:revoked, disabling_epoch}

  defp api_key_revocation_disposition(_result), do: :other

  @impl WebSock
  def terminate(reason, state) do
    _trace =
      NativeCompactionTrace.emit(:cleanup_finished, %{pid_role: :socket, outcome: :finished})

    state =
      state
      |> clear_pending_owner_handoff(:socket_closed)
      |> clear_public_response_context()

    log_closed_before_request_reservation(reason, state)

    {remaining_tasks, state} = await_response_task_cleanup_results(state)

    cleanup_websocket_session(reason, state)

    cancel_abandoned_response_tasks(state, remaining_tasks)

    close_upstream_websocket_session(state)

    acknowledge_response_task_cleanup(state)

    remaining_tasks = remaining_response_tasks_after_cleanup(state, remaining_tasks)

    cancel_response_tasks(remaining_tasks, :websocket_terminated)
    remaining_tasks = await_response_tasks(remaining_tasks, @post_cleanup_response_task_drain_ms)

    Enum.each(remaining_tasks, &Process.exit(&1, :kill))
    remaining_tasks = await_response_tasks(remaining_tasks, @post_cleanup_response_task_drain_ms)

    await_response_task_registry_cleanup(
      state,
      Map.get(state, :tasks, MapSet.new()),
      remaining_tasks
    )

    :ok
  end

  defp cancel_abandoned_response_tasks(state, remaining_tasks) do
    unless owner_forwarded_socket?(state) do
      remaining_tasks
      |> Enum.reject(&authoritative_response_task_activity?(state, &1))
      |> cancel_response_tasks(:websocket_terminated)
    end

    :ok
  end

  defp remaining_response_tasks_after_cleanup(state, remaining_tasks) do
    if owner_forwarded_socket?(state) do
      await_response_tasks(remaining_tasks, @post_cleanup_owner_response_task_drain_ms)
    else
      await_response_tasks(remaining_tasks, @post_cleanup_response_task_drain_ms)
    end
  end

  defp log_closed_before_request_reservation(
         reason,
         %{request_response_work_started?: false} = state
       ) do
    unless clean_pre_request_close_reason?(reason) do
      state
      |> Adapter.terminate_close_metadata()
      |> WebsocketConnectionLogger.log_closed_before_request_reservation(reason)
    end

    :ok
  end

  defp log_closed_before_request_reservation(_reason, _state), do: :ok

  defp clean_pre_request_close_reason?(:normal), do: true
  defp clean_pre_request_close_reason?(:shutdown), do: true
  defp clean_pre_request_close_reason?({:shutdown, _reason}), do: true
  defp clean_pre_request_close_reason?(_reason), do: false

  defp log_interrupt_failure({:ok, _result}, _state), do: :ok
  defp log_interrupt_failure(:ok, _state), do: :ok

  defp log_interrupt_failure({:error, reason}, state) do
    Logger.warning(
      "websocket interrupt cleanup failed " <>
        "codex_session_id=#{codex_session_id(state)} " <>
        "failure_reason=#{failure_reason(reason)}"
    )

    :ok
  end

  defp codex_session_id(%{codex_session: %{id: id}}) when is_binary(id), do: id
  defp codex_session_id(_state), do: "none"

  defp failure_reason({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(%module{}), do: inspect(module)
  defp failure_reason(_reason), do: "unknown"

  defp put_socket_lifecycle_state(state) do
    state
    |> Map.put(:connection_started_at_monotonic_ms, System.monotonic_time(:millisecond))
    |> Map.put(:request_response_work_started?, false)
  end

  defp put_response_task_state(state) do
    state
    |> Map.put(:tasks, MapSet.new())
    |> Map.put(:task_monitors, %{})
    |> Map.put(:direct_cleanup_contexts, %{})
    |> Map.put(:direct_cleanup_receipts, %{})
    |> Map.put(:queued_response_payloads, :queue.new())
    |> Map.put(:public_response_task_pid, nil)
    |> Map.put(:public_response_stream_id, nil)
    |> Map.put(:public_response_start_error_ref, nil)
    |> Map.put(:public_responses_websocket_state, nil)
    |> Map.put(:public_turn_task_done?, false)
    |> Map.put(:public_turn_owner_complete?, false)
    |> Map.put(:public_owner_retarget_error?, false)
    |> Map.put(:public_turn_aborted?, false)
    |> Map.put(:public_turn_output_committed?, false)
    |> Map.put(:native_turn_output_task_pids, MapSet.new())
    |> Map.put(:response_task_activities, %{})
    |> Map.put(:response_task_delivery_scheduled, MapSet.new())
    |> Map.put(:response_task_delivery_recipients, %{})
    |> Map.put(:response_task_delivery_outcomes, %{})
    |> Map.put(:response_task_results_ready, MapSet.new())
    |> Map.put(:response_task_terminals_accepted, MapSet.new())
    |> Map.put(:response_task_completed_terminals, MapSet.new())
    |> Map.put(:response_task_cleanup_results, %{})
    |> Map.put(:native_owner_terminal_delivered?, false)
    |> Map.put(:websocket_owner_pending_handoff, nil)
  end

  defp initialize_revocation_state(state) do
    with {:ok, state} <- initialize_api_key_revocation_state(state) do
      initialize_firewall_state(state)
    end
  end

  defp initialize_api_key_revocation_state(
         %{auth: %{pool: %{id: pool_id}, api_key: %{id: api_key_id}}} = state
       )
       when is_binary(pool_id) and is_binary(api_key_id) do
    case Events.subscribe_pool(pool_id, "pools") do
      :ok ->
        {:ok,
         state
         |> Map.put(:api_key_id, api_key_id)
         |> Map.put(:api_key_pool_id, pool_id)
         |> Map.put(:api_key_runtime_epoch, captured_api_key_epoch(state))
         |> Map.put(:api_key_revoked?, false)
         |> Map.put(:api_key_close_sent?, false)}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  defp initialize_api_key_revocation_state(state), do: {:stop, :api_key_identity_required, state}

  defp captured_api_key_epoch(%{
         opts: %{runtime: %{api_key_runtime_epoch: epoch}}
       })
       when is_integer(epoch) and epoch >= 0,
       do: epoch

  defp captured_api_key_epoch(%{auth: %{api_key: %{runtime_revocation_epoch: epoch}}})
       when is_integer(epoch) and epoch >= 0,
       do: epoch

  defp captured_api_key_epoch(_state), do: 0

  defp initialize_firewall_state(state) do
    case InstanceSettingsCache.subscribe_applied() do
      :ok ->
        settings = InstanceSettings.current()

        state =
          state
          |> Map.put(:firewall_applied_version, settings.lock_version)
          |> Map.put(:firewall_revoked?, false)
          |> Map.put(:firewall_close_sent?, false)

        settings
        |> evaluate_firewall(state)
        |> close_if_revoked_idle()

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  defp handle_firewall_applied(_applied_version, %{firewall_revoked?: true} = state),
    do: {:ok, state}

  defp handle_firewall_applied(_applied_version, state) do
    InstanceSettings.current()
    |> evaluate_firewall(state)
    |> close_if_revoked_idle()
  end

  defp evaluate_firewall(settings, state) do
    operational_settings = OperationalSettings.from_instance_settings(settings)
    client_ip = firewall_client_ip(state)

    case Firewall.evaluate_client_ip(client_ip, operational_settings) do
      %{outcome: :allow} ->
        {:ok, put_firewall_watermark(state, settings.lock_version)}

      %{outcome: :deny} ->
        {:ok, revoke_firewall(state, settings.lock_version)}
    end
  end

  defp firewall_client_ip(%{firewall_client_ip: client_ip}), do: client_ip
  defp firewall_client_ip(%{opts: %{request_metadata: %{client_ip: client_ip}}}), do: client_ip
  defp firewall_client_ip(_state), do: nil

  defp revoke_firewall(%{firewall_revoked?: true} = state, _applied_version), do: state

  defp revoke_firewall(state, applied_version) do
    :ok = Firewall.observe_denial(Firewall.denied(:websocket_revoked), :runtime)

    state
    |> clear_pending_owner_handoff(:submission_expired)
    |> put_firewall_watermark(applied_version)
    |> Map.put(:firewall_revoked?, true)
    |> Map.put(:queued_response_payloads, :queue.new())
  end

  defp handle_api_key_event(_payload, %{api_key_revoked?: true} = state), do: {:ok, state}

  defp handle_api_key_event(
         %{
           "api_key_id" => api_key_id,
           "status" => status,
           "runtime_revocation_epoch" => event_epoch
         },
         %{api_key_id: api_key_id, api_key_runtime_epoch: captured_epoch} = state
       )
       when status in @api_key_disabling_statuses and is_integer(event_epoch) and
              event_epoch > captured_epoch do
    {:ok, revoke_api_key(state, event_epoch)}
  end

  defp handle_api_key_event(
         %{"api_key_id" => api_key_id, "status" => status} = payload,
         %{api_key_id: api_key_id} = state
       )
       when status in @api_key_disabling_statuses do
    if Map.has_key?(payload, "runtime_revocation_epoch") do
      {:ok, state}
    else
      case refresh_api_key_authorization(state) do
        {:authorized, state} -> {:ok, state}
        {:revoked, state} -> {:ok, state}
      end
    end
  end

  defp handle_api_key_event(_payload, state), do: {:ok, state}

  defp refresh_api_key_authorization(%{api_key_revoked?: true} = state),
    do: {:revoked, state}

  defp refresh_api_key_authorization(
         %{api_key_id: api_key_id, api_key_runtime_epoch: captured_epoch} = state
       )
       when is_binary(api_key_id) and is_integer(captured_epoch) and captured_epoch >= 0 do
    case Repo.transact(fn ->
           Access.authorize_api_key_runtime_turn(api_key_id, captured_epoch)
         end) do
      {:ok, {:ok, _authorization}} ->
        {:authorized, state}

      {:ok, {:error, %{code: code, disabling_epoch: epoch}}}
      when code in [
             :api_key_paused,
             :api_key_revoked,
             :api_key_inactive,
             :api_key_runtime_epoch_stale
           ] ->
        {:revoked, revoke_api_key(state, epoch)}

      {:error, %{code: code, disabling_epoch: epoch}}
      when code in [
             :api_key_paused,
             :api_key_revoked,
             :api_key_inactive,
             :api_key_runtime_epoch_stale
           ] ->
        {:revoked, revoke_api_key(state, epoch)}

      _unavailable_or_missing ->
        {:authorized, state}
    end
  end

  defp refresh_api_key_authorization(state), do: {:authorized, state}

  defp revoke_api_key(%{api_key_revoked?: true} = state, _disabling_epoch), do: state

  defp revoke_api_key(state, disabling_epoch) do
    state
    |> clear_pending_owner_handoff(:submission_expired)
    |> Map.put(:api_key_revoked?, true)
    |> Map.put(:api_key_disabling_epoch, disabling_epoch)
    |> Map.put(:queued_response_payloads, :queue.new())
  end

  defp put_firewall_watermark(state, current_version) do
    previous_version = Map.get(state, :firewall_applied_version, 0)
    Map.put(state, :firewall_applied_version, max(previous_version, current_version))
  end

  defp close_if_revoked_idle({:ok, state}) do
    if close_revoked_socket?(state) do
      {:stop, :normal, revocation_close_detail(state), mark_revocation_closed(state)}
    else
      {:ok, state}
    end
  end

  defp close_if_revoked_idle({:push, messages, state}) do
    if close_revoked_socket?(state) do
      {:stop, :normal, revocation_close_detail(state), List.wrap(messages),
       mark_revocation_closed(state)}
    else
      {:push, messages, state}
    end
  end

  defp close_if_revoked_idle({:stop, reason, close_detail, state}) do
    if close_revoked_socket?(state) do
      {:stop, :normal, revocation_close_detail(state), mark_revocation_closed(state)}
    else
      {:stop, reason, close_detail, state}
    end
  end

  defp close_revoked_socket?(state) do
    socket_revoked?(state) and not revocation_close_sent?(state) and
      not revocation_drain_active?(state)
  end

  defp socket_revoked?(state) do
    Map.get(state, :firewall_revoked?, false) or Map.get(state, :api_key_revoked?, false)
  end

  defp revocation_close_sent?(state) do
    (Map.get(state, :firewall_revoked?, false) and
       Map.get(state, :firewall_close_sent?, false)) or
      (Map.get(state, :api_key_revoked?, false) and
         Map.get(state, :api_key_close_sent?, false))
  end

  defp revocation_drain_active?(state) do
    active_response_task?(state) or public_turn_open?(state)
  end

  defp revocation_close_detail(%{firewall_revoked?: true}), do: @firewall_close_detail
  defp revocation_close_detail(_state), do: @api_key_close_detail

  defp mark_revocation_closed(state) do
    state
    |> maybe_mark_firewall_closed()
    |> maybe_mark_api_key_closed()
  end

  defp maybe_mark_firewall_closed(%{firewall_revoked?: true} = state),
    do: Map.put(state, :firewall_close_sent?, true)

  defp maybe_mark_firewall_closed(state), do: state

  defp maybe_mark_api_key_closed(%{api_key_revoked?: true} = state),
    do: Map.put(state, :api_key_close_sent?, true)

  defp maybe_mark_api_key_closed(state), do: state

  defp handle_owner_frame(message, state) do
    state = bind_reconnect_owner_turn(message, state)

    case Adapter.accept_downstream_message(message, state) do
      {:ok, payload} -> handle_accepted_owner_payload(payload, state)
      :drop -> {:ok, state}
      {:error, _reason} -> {:ok, state}
    end
  end

  defp bind_reconnect_owner_turn(
         {:websocket_owner_frame, correlation_id, epoch, owner_turn_id, _payload},
         %{
           websocket_owner_active_turn_reconnect?: true,
           websocket_owner_downstream: %{correlation_id: correlation_id, epoch: epoch}
         } = state
       )
       when is_pid(owner_turn_id) do
    case Map.get(state, :websocket_owner_reconnect_turn_pid) do
      nil -> Map.put(state, :websocket_owner_reconnect_turn_pid, owner_turn_id)
      ^owner_turn_id -> state
      _stale_owner_turn_id -> state
    end
  end

  defp bind_reconnect_owner_turn(_message, state), do: state

  defp handle_accepted_owner_payload(payload, state) do
    if public_owner_turn_open?(state) do
      handle_public_owner_payload(payload, state)
    else
      handle_non_public_owner_payload(payload, state)
    end
  end

  defp handle_public_owner_payload(_payload, %{public_turn_aborted?: true} = state),
    do: {:ok, state}

  defp handle_public_owner_payload({:data, _data}, %{public_turn_owner_complete?: true} = state),
    do: {:ok, state}

  defp handle_public_owner_payload({:data, data}, state), do: public_chunk_result(data, state)

  defp handle_public_owner_payload(
         {:error, _reason, _payload},
         %{public_turn_owner_complete?: true} = state
       ),
       do: {:ok, state}

  defp handle_public_owner_payload({:error, :owner_drained, payload}, state) do
    log_failed_native_websocket_turn(
      state,
      Map.fetch!(state, :public_response_task_pid),
      payload,
      active_owner_turn_visible_output?(state)
    )

    encoded = encode_public_error(payload, state)

    state =
      state
      |> Map.put(:websocket_owner_drain_observed?, true)
      |> abort_public_turn(:owner_drained)
      |> schedule_response_task_delivery(Map.get(state, :public_response_task_pid))

    {:push, {:text, encoded}, state}
  end

  defp handle_public_owner_payload({:error, :upstream_stream_error, payload}, state) do
    log_failed_native_websocket_turn(
      state,
      Map.fetch!(state, :public_response_task_pid),
      payload,
      active_owner_turn_visible_output?(state)
    )

    if match?(
         %{terminal_latched?: true},
         Map.get(state, :public_responses_websocket_state)
       ) do
      {:ok, state}
    else
      {:push, {:text, encode_public_error(payload, state)}, state}
    end
  end

  defp handle_public_owner_payload({:error, _reason, payload}, state) do
    {:push, {:text, encode_public_error(payload, state)}, state}
  end

  defp handle_public_owner_payload(:complete, %{public_turn_owner_complete?: true} = state),
    do: {:ok, state}

  defp handle_public_owner_payload(:complete, state) do
    state =
      state
      |> Map.put(:public_turn_owner_complete?, true)
      |> Map.put(:websocket_owner_active_turn_reconnect?, false)
      |> maybe_finish_public_owner_turn()

    {:ok, state}
  end

  defp handle_non_public_owner_payload({:data, data}, state) do
    state =
      case active_native_owner_turn_pid(state) do
        pid when is_pid(pid) ->
          state
          |> maybe_mark_active_native_owner_turn_output(data)
          |> maybe_accept_response_task_terminal(pid, data)
          |> maybe_schedule_accepted_response_task_delivery(pid)

        nil ->
          state
      end

    {:push, {:text, Adapter.downstream_response_chunk(data)}, state}
  end

  defp handle_non_public_owner_payload({:error, :owner_drained, payload}, state) do
    maybe_log_failed_native_websocket_turn(
      state,
      tracked_response_task_pid(state),
      payload,
      active_owner_turn_visible_output?(state)
    )

    state =
      state
      |> Map.put(:websocket_owner_drain_observed?, true)
      |> cancel_tracked_response_tasks(:owner_drained)
      |> reset_owner_turn_output()
      |> schedule_active_response_task_delivery()

    {:push, {:text, Jason.encode!(Adapter.websocket_error(payload))}, state}
  end

  defp handle_non_public_owner_payload({:error, _reason, payload}, state) do
    {:push, {:text, Jason.encode!(Adapter.websocket_error(payload))}, state}
  end

  defp handle_non_public_owner_payload(:complete, state) do
    state =
      state
      |> Map.put(:websocket_owner_active_turn_reconnect?, false)
      |> Map.put(:native_owner_terminal_delivered?, true)
      |> reset_owner_turn_output()
      |> maybe_schedule_finalized_owner_task_delivery()

    {:ok, state}
  end

  defp maybe_schedule_finalized_owner_task_delivery(state) do
    case active_native_owner_turn_pid(state) do
      pid when is_pid(pid) ->
        if response_task_result_ready?(state, pid) do
          schedule_response_task_delivery(state, pid, :completed)
        else
          state
        end

      nil ->
        state
    end
  end

  defp public_chunk_result(data, state) do
    turn_state =
      Map.get(state, :public_responses_websocket_state) ||
        Adapter.public_responses_turn_state(Map.get(state, :public_response_stream_id))

    case Adapter.downstream_response_chunk(data, turn_state) do
      {:push, normalized, turn_state} ->
        state =
          state
          |> put_public_turn_state(turn_state)
          |> maybe_mark_public_turn_output_committed(data)

        {:push, {:text, normalized}, state}

      {:drop, turn_state} ->
        {:ok, put_public_turn_state(state, turn_state)}

      {:error, reason, turn_state} ->
        state =
          state
          |> put_public_turn_state(turn_state)
          |> Map.put(:public_turn_output_committed?, true)

        {:push, {:text, encode_public_error(reason, state)}, state}
    end
  end

  defp put_public_turn_state(state, turn_state) do
    Map.put(state, :public_responses_websocket_state, turn_state)
  end

  defp handle_public_response_done(pid, result, state) do
    state = remove_tracked_response_task(state, pid)
    {completion_source, result} = socket_response_result(result)

    cond do
      public_turn_aborted?(state) ->
        {:ok, state}

      Map.get(state, :public_owner_retarget_error?, false) ->
        handle_public_retarget_error_done(pid, result, state)

      owner_completion_pending?(completion_source, state) ->
        handle_public_owner_response_done(result, state)

      match?({:response_task_failure, {:error, _reason}}, result) ->
        {:response_task_failure, {:error, reason}} = result
        payload = encode_public_error(reason, state)
        state = finish_public_turn(state)
        {:push, {:text, payload}, state}

      match?({:response_task_result, {:error, _reason}, _visible_output?}, result) ->
        {:response_task_result, {:error, reason}, visible_output?} = result
        log_failed_native_websocket_turn(state, pid, reason, visible_output?)
        payload = encode_public_error(reason, state)
        state = finish_public_turn(state)
        {:push, {:text, payload}, state}

      match?({:error, _reason}, result) ->
        {:error, reason} = result
        log_failed_native_websocket_turn(state, pid, reason, false)
        payload = encode_public_error(reason, state)
        state = finish_public_turn(state)
        {:push, {:text, payload}, state}

      true ->
        {:ok, finish_public_turn(state)}
    end
  end

  defp socket_response_result({:socket_response_result, completion_source, result})
       when completion_source in [:local_complete, :owner_completion_pending],
       do: {completion_source, result}

  defp socket_response_result(result), do: {:legacy, result}

  defp owner_completion_pending?(:owner_completion_pending, _state), do: true
  defp owner_completion_pending?(:legacy, state), do: owner_forwarded_socket?(state)
  defp owner_completion_pending?(:local_complete, _state), do: false

  defp handle_public_owner_response_done(result, state) do
    if not Map.get(state, :public_turn_owner_complete?, false) and owner_liveness_error?(result) do
      reason = owner_liveness_error(result)

      state =
        state
        |> Map.put(:queued_response_payloads, :queue.new())
        |> finish_public_turn()

      {:stop, :normal, Adapter.close_detail(reason), state}
    else
      state =
        state
        |> Map.put(:public_turn_task_done?, true)
        |> maybe_finish_public_owner_turn()

      {:ok, state}
    end
  end

  defp handle_non_public_response_done(pid, :ok, state) do
    state =
      state
      |> remove_tracked_response_task(pid)
      |> remove_native_turn_output(pid)
      |> maybe_start_queued_response_task()

    {:ok, state}
  end

  defp handle_non_public_response_done(
         pid,
         {:socket_response_result, _completion_source, result},
         state
       ) do
    handle_non_public_response_done(pid, result, state)
  end

  defp handle_non_public_response_done(
         pid,
         {:error, _reason},
         %{websocket_owner_drain_observed?: true} = state
       ) do
    state =
      state
      |> remove_tracked_response_task(pid)
      |> remove_native_turn_output(pid)
      |> maybe_start_queued_response_task()

    {:ok, state}
  end

  defp handle_non_public_response_done(pid, {:response_task_failure, {:error, reason}}, state) do
    state =
      state
      |> remove_tracked_response_task(pid)
      |> remove_native_turn_output(pid)
      |> maybe_start_queued_response_task()

    {:push, {:text, Jason.encode!(Adapter.websocket_error(reason))}, state}
  end

  defp handle_non_public_response_done(
         pid,
         {:response_task_result, {:error, reason}, visible_output?},
         state
       ) do
    log_failed_native_websocket_turn(state, pid, reason, visible_output?)

    state =
      state
      |> remove_tracked_response_task(pid)
      |> remove_native_turn_output(pid)
      |> maybe_start_queued_response_task()

    {:push, {:text, Jason.encode!(Adapter.websocket_error(reason))}, state}
  end

  defp handle_non_public_response_done(pid, {:error, reason}, state) do
    log_failed_native_websocket_turn(state, pid, reason, false)

    state =
      state
      |> remove_tracked_response_task(pid)
      |> remove_native_turn_output(pid)
      |> maybe_start_queued_response_task()

    {:push, {:text, Jason.encode!(Adapter.websocket_error(reason))}, state}
  end

  defp handle_non_public_response_done(pid, _result, state) do
    state =
      state
      |> remove_tracked_response_task(pid)
      |> remove_native_turn_output(pid)
      |> maybe_start_queued_response_task()

    {:ok, state}
  end

  defp maybe_finish_public_owner_turn(state) do
    if Map.get(state, :public_turn_task_done?, false) and
         Map.get(state, :public_turn_owner_complete?, false) and
         not public_turn_aborted?(state) do
      finish_public_turn(state)
    else
      state
    end
  end

  defp finish_public_turn(state) do
    task_pid = Map.get(state, :public_response_task_pid)

    state
    |> Map.put(:public_response_task_pid, nil)
    |> clear_public_response_context()
    |> Map.put(:public_turn_task_done?, false)
    |> Map.put(:public_turn_owner_complete?, false)
    |> Map.put(:public_owner_retarget_error?, false)
    |> Map.put(:public_turn_aborted?, false)
    |> Map.put(:public_turn_output_committed?, false)
    |> schedule_response_task_delivery(task_pid)
    |> maybe_start_queued_response_task()
  end

  defp active_public_turn?(state, pid) when is_pid(pid) do
    Adapter.public_responses_stream?(state) and Map.get(state, :public_response_task_pid) == pid
  end

  defp active_public_task_monitor?(state, pid, ref)
       when is_pid(pid) and is_reference(ref) do
    active_public_turn?(state, pid) and
      Map.get(Map.get(state, :task_monitors, %{}), pid) == ref
  end

  defp public_owner_turn_open?(state) do
    Adapter.public_responses_stream?(state) and owner_forwarded_socket?(state) and
      public_turn_open?(state)
  end

  defp public_turn_aborted?(state), do: Map.get(state, :public_turn_aborted?, false)

  defp abort_public_turn(state, reason) do
    state
    |> Map.put(:public_turn_aborted?, true)
    |> Map.put(:public_turn_output_committed?, false)
    |> Map.put(:queued_response_payloads, :queue.new())
    |> clear_public_response_context()
    |> cancel_tracked_response_tasks(reason)
  end

  defp maybe_abort_public_owner_turn(state, reason) do
    if public_owner_turn_open?(state) and not public_turn_aborted?(state) do
      abort_public_turn(state, reason)
    else
      state
    end
  end

  defp init_error(reason, state, started_at) do
    case api_key_revocation_disposition({:error, reason}) do
      {:revoked, _disabling_epoch} ->
        {:stop, :normal, @api_key_close_detail, state}

      :other ->
        log_init_failed_before_request_reservation(reason, state, started_at)

        if Adapter.owner_error?(reason) do
          {:stop, :normal, Adapter.close_detail(reason), state}
        else
          {:stop, reason, state}
        end
    end
  end

  defp log_init_failed_before_request_reservation(reason, state, started_at) do
    state
    |> Adapter.init_failure_metadata(started_at)
    |> WebsocketConnectionLogger.log_init_failed_before_request_reservation(reason)
  end

  defp start_response_task(parent, payload, state) do
    direct_ref = make_ref()

    ResponseTask.start(
      parent,
      response_task_activity_kind(payload, state),
      fn task_pid ->
        safe_run_response(
          parent,
          payload,
          put_direct_context(state, task_pid, direct_ref, parent),
          task_pid
        )
      end,
      fn task_pid, reason ->
        cancel_response_task_activity(
          put_direct_context(state, task_pid, direct_ref, parent),
          task_pid,
          reason
        )
      end,
      Keyword.put(
        Map.get(state, :response_task_start_options, []),
        :direct_cleanup_ref,
        direct_ref
      )
    )
    |> case do
      {:ok, pid} -> {:ok, pid, direct_ref}
    end
  end

  defp prepare_and_dispatch_response(_payload, %{firewall_revoked?: true} = state),
    do: {:ok, state}

  defp prepare_and_dispatch_response(payload, state) do
    _trace = NativeCompactionTrace.enroll(:socket, self())
    original_public_context = public_response_context(state)

    case prepare_response_payload(payload, state) do
      {:ok, payload, prepared_state} ->
        dispatch_prepared_payload(payload, prepared_state, original_public_context)

      {:error, reason, failed_state} ->
        reject_prepared_response(
          reason,
          restore_public_response_context(failed_state, original_public_context)
        )
    end
  end

  defp dispatch_prepared_payload(payload, prepared_state, original_public_context) do
    case prepare_dispatchable_response(payload, prepared_state) do
      {:ok, prepared} ->
        prepared = put_prepared_public_context(prepared, prepared_state)

        dispatch_prepared_response(
          prepared,
          restore_public_response_context(prepared_state, original_public_context)
        )

      {:error, reason, failed_state} ->
        reject_prepared_response(reason, failed_state)
    end
  end

  defp prepare_dispatchable_response(payload, prepared_state) do
    with {:ok, prepared} <- prepare_websocket_frame(payload, prepared_state),
         {:ok, prepared} <-
           reserve_native_compaction_admission(prepared, payload, prepared_state) do
      _trace = NativeCompactionTrace.emit(:prepared_frame, %{pid_role: :socket})
      {:ok, prepared}
    else
      {:error, reason} -> {:error, reason, prepared_state}
    end
  end

  defp prepare_websocket_frame(payload, state) do
    parent = self()

    opts =
      state
      |> Adapter.response_options(true, nil)
      |> RequestOptions.capture_api_key_runtime_epoch(Map.get(state, :auth))
      |> maybe_put_native_turn_metadata(payload)

    Websocket.prepare_websocket_response(
      payload,
      opts,
      fn data -> send(parent, {:codex_response_chunk, self(), data}) end
    )
  end

  defp maybe_put_native_turn_metadata(%RequestOptions{} = options, raw_payload) do
    with {:ok, payload} <- WebsocketCodec.decode_payload(raw_payload),
         true <- canonical_native_turn_metadata?(payload),
         {:ok, metadata} <-
           NativeCodexTurnMetadata.parse(payload, options.continuity.codex_session.id),
         true <- compaction_authority_metadata?(metadata) do
      RequestOptions.put_payload_context(options, native_codex_turn_metadata: metadata)
    else
      _missing_or_invalid -> options
    end
  end

  defp reserve_native_compaction_admission(
         %PreparedWebsocketFrame{variant: variant} = prepared,
         raw_payload,
         state
       )
       when variant in [:native_response_create, :prewarm] do
    with {:ok, payload} <- WebsocketCodec.decode_payload(raw_payload),
         true <- canonical_native_turn_metadata?(payload),
         {:ok, metadata} <-
           NativeCodexTurnMetadata.parse(
             payload,
             prepared.request_options.continuity.codex_session.id
           ) do
      case metadata.request_kind do
        :prewarm ->
          log_native_prewarm_admission(prepared)
          {:ok, prepared}

        :memory ->
          reason = native_memory_websocket_error()
          log_native_metadata_rejection(prepared, raw_payload, reason)
          {:error, reason}

        _native_turn ->
          reserve_native_compaction_phase(prepared, payload, metadata, state)
      end
    else
      false ->
        {:ok, prepared}

      {:error, %{code: _code} = reason} ->
        log_native_metadata_rejection(prepared, raw_payload, reason)
        {:error, reason}

      {:error, _owner_reason} ->
        {:ok, prepared}
    end
  end

  defp reserve_native_compaction_admission(
         %PreparedWebsocketFrame{} = prepared,
         _payload,
         _state
       ),
       do: {:ok, prepared}

  defp log_native_metadata_rejection(prepared, raw_payload, reason) do
    request_kind_class =
      case WebsocketCodec.decode_payload(raw_payload) do
        {:ok, payload} -> native_metadata_request_kind_class(payload)
        _invalid -> :missing
      end

    Logger.warning(
      "native websocket turn metadata rejected " <>
        "route_class=proxy_websocket " <>
        "frame_class=#{native_metadata_frame_class(prepared)} " <>
        "request_kind_class=#{request_kind_class} " <>
        "rejection_class=#{NativeCodexTurnMetadata.rejection_class(reason)}"
    )

    :ok
  end

  defp log_native_prewarm_admission(prepared) do
    Logger.info(
      "native websocket prewarm admitted " <>
        "route_class=proxy_websocket " <>
        "frame_class=#{native_metadata_frame_class(prepared)} " <>
        "request_kind_class=prewarm compaction_authority=absent"
    )

    :ok
  end

  defp native_metadata_frame_class(%PreparedWebsocketFrame{variant: :prewarm}), do: :prewarm

  defp native_metadata_frame_class(%PreparedWebsocketFrame{variant: :native_response_create}),
    do: :response_create

  defp native_metadata_frame_class(_prepared), do: :other

  defp native_metadata_request_kind_class(%{
         "client_metadata" => %{"x-codex-turn-metadata" => canonical}
       }) do
    with {:ok, metadata} <- decode_native_metadata_for_class(canonical),
         request_kind when request_kind in ["turn", "prewarm", "compaction", "memory"] <-
           Map.get(metadata, "request_kind") do
      String.to_existing_atom(request_kind)
    else
      _unknown -> :unsupported
    end
  end

  defp native_metadata_request_kind_class(_payload), do: :missing

  defp decode_native_metadata_for_class(value) when is_map(value), do: {:ok, value}

  defp decode_native_metadata_for_class(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      _invalid -> :error
    end
  end

  defp decode_native_metadata_for_class(_value), do: :error

  defp native_memory_websocket_error do
    %{
      status: 400,
      code: "invalid_request",
      message: "native Codex turn metadata is invalid",
      param: "client_metadata.x-codex-turn-metadata.request_kind",
      native_metadata_rejection_class: :unsupported_request_kind
    }
  end

  defp reserve_native_compaction_phase(prepared, payload, metadata, state) do
    case native_compaction_phase(metadata, payload, prepared.request_options) do
      phase when phase in [:compact, :final] ->
        reserve_known_native_compaction_phase(prepared, metadata, phase, state)

      nil ->
        {:ok, prepared}
    end
  end

  defp compaction_authority_metadata?(%NativeCodexTurnMetadata{
         window_id_digest: window_digest,
         context_window_id_digest: context_digest
       }) do
    is_binary(window_digest) and is_binary(context_digest)
  end

  defp reserve_known_native_compaction_phase(prepared, metadata, phase, state) do
    control_ref = make_ref()

    _trace =
      NativeCompactionTrace.emit(:capability_reserve_started, %{
        phase: phase,
        control_ref: control_ref,
        semantic_turn_key: metadata.semantic_turn_key,
        window_number: metadata.window_number,
        pid_role: :socket,
        socket_pid: self()
      })

    case reserve_owner_capability(prepared, metadata, phase, control_ref, state) do
      {:ok, prepared} ->
        trace_reserve_finished(metadata, phase, control_ref, :ok)
        {:ok, prepared}

      {:error, :owner_unavailable} ->
        trace_reserve_finished(metadata, phase, control_ref, :queued)
        maybe_defer_native_compaction(prepared, metadata, phase, control_ref, state)

      {:error, reason} ->
        trace_reserve_finished(metadata, phase, control_ref, {:error, reason})
        {:error, reason}
    end
  end

  defp trace_reserve_finished(metadata, phase, control_ref, result) do
    NativeCompactionTrace.emit(:capability_reserve_finished, %{
      phase: phase,
      control_ref: control_ref,
      semantic_turn_key: metadata.semantic_turn_key,
      window_number: metadata.window_number,
      pid_role: :socket,
      socket_pid: self(),
      outcome: trace_outcome(result),
      reason: trace_reason(result)
    })
  end

  defp trace_outcome({:error, _reason}), do: :error
  defp trace_outcome(outcome), do: outcome
  defp trace_reason({:error, reason}), do: reason
  defp trace_reason(_outcome), do: nil

  defp maybe_defer_native_compaction(prepared, metadata, phase, control_ref, state) do
    if active_response_task?(state) do
      {:ok, defer_native_compaction_reservation(prepared, metadata, phase, control_ref)}
    else
      {:ok, prepared}
    end
  end

  defp canonical_native_turn_metadata?(%{
         "client_metadata" => %{"x-codex-turn-metadata" => _metadata}
       }),
       do: true

  defp canonical_native_turn_metadata?(_payload), do: false

  defp native_compaction_phase(
         %NativeCodexTurnMetadata{request_kind: :compaction},
         _payload,
         %RequestOptions{payload_context: %{compaction_input_mode: :incremental}}
       ),
       do: :compact

  defp native_compaction_phase(
         %NativeCodexTurnMetadata{request_kind: :turn},
         %{"input" => input},
         %RequestOptions{}
       )
       when is_list(input) do
    if Enum.any?(
         input,
         &match?(%{"type" => type} when type in ["compaction", "compaction_summary"], &1)
       ),
       do: :final
  end

  defp native_compaction_phase(%NativeCodexTurnMetadata{}, _payload, %RequestOptions{}), do: nil

  defp reserve_owner_capability(prepared, metadata, phase, control_ref, state) do
    prepared = put_standalone_compact_authority(prepared, metadata, state)

    if owner_forwarded_socket?(state) do
      reserve_forwarded_owner_capability(prepared, metadata, phase, control_ref)
    else
      reserve_direct_owner_capability(prepared, metadata, phase, control_ref, state)
    end
  end

  defp put_standalone_compact_authority(
         prepared,
         %NativeCodexTurnMetadata{
           request_kind: :compaction,
           compaction: %NativeCodexTurnMetadata.Compaction{
             trigger: :manual,
             phase: :standalone_turn,
             implementation: :responses_compaction_v2
           }
         },
         state
       ) do
    options = prepared.request_options
    anchor = Map.get(prepared.payload, "previous_response_id")
    session = options.continuity.codex_session

    resolved =
      if is_binary(anchor),
        do:
          SessionContinuity.previous_response_session_id(
            state.auth,
            anchor,
            DateTime.utc_now()
          )

    valid =
      not is_nil(resolved) and not is_nil(session) and
        resolved == session.id

    %{
      prepared
      | request_options: %{
          options
          | extra: Map.put(options.extra, :standalone_compact_resolved_anchor?, valid)
        }
    }
  end

  defp put_standalone_compact_authority(prepared, _metadata, _state), do: prepared

  defp reserve_direct_owner_capability(prepared, metadata, phase, control_ref, state) do
    owner = Map.get(state, :upstream_websocket_session)

    with {:ok, snapshot} <- UpstreamWebsocketSession.compaction_reservation_snapshot(owner),
         lifecycle = Map.take(snapshot, [:lifecycle_id, :generation]),
         binding =
           native_compaction_binding(
             metadata,
             prepared,
             phase,
             lifecycle,
             %NativeCompactionAdmission.Topology.Direct{},
             prepared_serving_mode(prepared, snapshot.serving_mode),
             prepared_anchor_digest(prepared),
             final_compaction_item_digest(prepared.payload, phase)
           ),
         {:ok, capability} <-
           UpstreamWebsocketSession.reserve_compaction(
             owner,
             phase,
             binding,
             control_ref,
             System.system_time(:millisecond)
           ) do
      put_owner_capability(prepared, capability, {:direct, owner}, lifecycle)
    else
      _unavailable -> {:error, :owner_unavailable}
    end
  end

  defp reserve_forwarded_owner_capability(prepared, metadata, phase, control_ref) do
    owner = prepared.request_options.transport.websocket_owner
    downstream = Map.take(owner.downstream, [:pid, :epoch, :correlation_id])

    with {:ok, snapshot_control} <- owner_admission_control(:snapshot, downstream),
         {:ok, %NativeCompactionAdmission{binding: previous_binding}} <-
           WebsocketOwnerForwarder.admission_control(
             owner.session,
             owner.lease_token,
             snapshot_control,
             owner.forwarder_opts
           ),
         %NativeCompactionAdmission.Binding{} = previous_binding <- previous_binding,
         topology <-
           WebsocketOwnerAdmissionControlV1.forwarded_topology(
             owner.owner_instance_id,
             owner.lease_token,
             owner.downstream_epoch
           ),
         lifecycle = %{
           lifecycle_id: previous_binding.lifecycle_id,
           generation: previous_binding.generation
         },
         binding =
           native_compaction_binding(
             metadata,
             prepared,
             phase,
             lifecycle,
             topology,
             prepared_serving_mode(prepared, previous_binding.serving_mode),
             prepared_anchor_digest(prepared),
             final_compaction_item_digest(prepared.payload, phase)
           ),
         {:ok, reserve_control} <-
           owner_admission_control(:reserve, downstream,
             binding: binding,
             phase: phase,
             control_ref: control_ref,
             now_ms: System.system_time(:millisecond)
           ),
         {:ok, %NativeCompactionAdmission.Capability{} = capability} <-
           WebsocketOwnerForwarder.admission_control(
             owner.session,
             owner.lease_token,
             reserve_control,
             owner.forwarder_opts
           ) do
      owner_ref =
        {:forwarded, owner.session, owner.lease_token, downstream, owner.forwarder_opts}

      put_owner_capability(prepared, capability, owner_ref, lifecycle)
    else
      _unavailable -> {:error, :owner_unavailable}
    end
  end

  defp owner_admission_control(action, downstream, updates \\ []) do
    WebsocketOwnerAdmissionControlV1.new(
      %{
        version: 1,
        action: action,
        downstream: downstream,
        binding: nil,
        phase: nil,
        control_ref: nil,
        capability: nil,
        disposition: nil,
        success?: nil,
        compaction_item_digest: nil,
        confirmation: nil,
        first_compact_collection: nil,
        expires_at_ms: nil,
        now_ms: nil
      }
      |> Map.merge(Map.new(updates))
    )
  end

  defp native_compaction_binding(
         metadata,
         prepared,
         _phase,
         lifecycle,
         topology,
         serving_mode,
         previous_response_digest,
         compaction_item_digest
       ) do
    %NativeCompactionAdmission.Binding{
      semantic_turn_key: metadata.semantic_turn_key,
      window_digest: metadata.window_id_digest,
      context_digest: metadata.context_window_id_digest,
      window_number: metadata.window_number,
      compaction_item_digest: compaction_item_digest,
      previous_response_digest: previous_response_digest,
      serving_mode: serving_mode,
      topology: topology,
      lifecycle_id: lifecycle.lifecycle_id,
      generation: lifecycle.generation,
      standalone_resolved_anchor?:
        Map.get(prepared.request_options.extra, :standalone_compact_resolved_anchor?, false)
    }
  end

  defp prepared_serving_mode(prepared, pending_owner_mode) do
    case prepared.request_options.routing.model_serving_mode do
      nil -> pending_owner_mode
      "full" -> :full
      "lite" -> :lite
    end
  end

  defp final_compaction_item_digest(%{"input" => input}, :final) when is_list(input) do
    case Enum.filter(
           input,
           &match?(%{"type" => type} when type in ["compaction", "compaction_summary"], &1)
         ) do
      [%{"encrypted_content" => content} = item]
      when is_binary(content) and byte_size(content) > 0 ->
        normalized = CompactionTrigger.normalize_native_item(item)

        if String.trim(content) == "" do
          nil
        else
          NativeCodexTurnMetadata.compaction_item_digest(normalized)
        end

      _missing_multiple_or_malformed ->
        nil
    end
  end

  defp final_compaction_item_digest(_payload, _phase), do: nil

  defp prepared_anchor_digest(prepared) do
    case Map.get(prepared.payload, "previous_response_id") do
      value when is_binary(value) -> NativeCodexTurnMetadata.response_id_digest(value)
      _ -> nil
    end
  end

  defp put_owner_capability(prepared, capability, owner, lifecycle) do
    with {:ok, admission} <-
           RequestOptions.NativeCompactionAdmission.new(capability, owner, lifecycle) do
      _trace =
        NativeCompactionTrace.emit_capability(:capability_reserved, capability, %{
          pid_role: :socket,
          branch: owner_branch(owner)
        })

      WebsocketCodec.attach_native_compaction_admission(prepared, admission)
    end
  end

  defp owner_branch({:direct, _owner}), do: :direct_owner

  defp owner_branch({:forwarded, _session, _lease_token, _downstream, _opts}),
    do: :forwarded_owner

  defp decode_trace_frame(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> :not_json
    end
  end

  defp defer_native_compaction_reservation(prepared, metadata, phase, control_ref) do
    request_options = %{
      prepared.request_options
      | native_compaction_reservation: %{
          metadata: metadata,
          phase: phase,
          control_ref: control_ref
        }
    }

    %{prepared | request_options: request_options}
  end

  defp dispatch_prepared_response(%PreparedWebsocketFrame{} = prepared, state) do
    cond do
      prepared.variant == :prewarm ->
        {:ok, start_tracked_response_task(prepared, state)}

      owner_forwarded_socket?(state) and active_response_task?(state) and
          not Map.get(state, :websocket_owner_active_turn_reconnect?, false) ->
        {:ok, queue_prepared_response(state, prepared)}

      owner_forwarded_socket?(state) ->
        dispatch_owner_prepared_response(prepared, state)

      true ->
        {:ok, start_or_queue_prepared_response(prepared, state)}
    end
  end

  defp dispatch_owner_prepared_response(
         %PreparedWebsocketFrame{
           variant: :native_response_create,
           semantic_turn_key: semantic_turn_key
         } = prepared,
         state
       )
       when is_binary(semantic_turn_key) and byte_size(semantic_turn_key) == 32 do
    if WebsocketCodec.replay_eligible?(prepared) do
      case Service.prepare_replay_intent(state.auth, prepared) do
        {:ok, intent} -> dispatch_replay_intent(prepared, state, intent)
        {:error, reason} -> reject_prepared_response(reason, state)
      end
    else
      legacy_owner_preflight(prepared, state, semantic_turn_key)
    end
  end

  defp dispatch_owner_prepared_response(%PreparedWebsocketFrame{} = prepared, state) do
    if Map.get(state, :websocket_owner_active_turn_reconnect?, false) or
         is_map(Map.get(state, :websocket_owner_pending_handoff)) do
      reject_owner_preflight(:owner_busy, state)
    else
      {:ok, start_or_queue_prepared_response(prepared, state)}
    end
  end

  defp dispatch_replay_intent(prepared, state, %{intent: intent} = replay_intent) do
    control_ref = make_ref()
    downstream = Map.take(state.websocket_owner_downstream, [:pid, :epoch, :correlation_id])

    with {:ok, control} <-
           RemoteReconnectControlV2.new(%{
             version: 2,
             action: :preflight,
             intent: intent,
             codex_session_id: state.codex_session.id,
             downstream: downstream,
             semantic_turn_digest: prepared.semantic_turn_key,
             replay_claim_digest: prepared.replay_claim_digest,
             provisional_token: nil,
             replay_generation: nil,
             owner_lease_token: state.websocket_owner_lease_token,
             control_ref: control_ref,
             authorization_binding: replay_intent.authorization_binding,
             consume_binding: active_lifecycle_binding(replay_intent)
           }),
         result <- Adapter.reconnect_control_v2(state, control) do
      apply_replay_preflight_result(result, prepared, state, replay_intent, control_ref)
    else
      _invalid -> reject_owner_preflight(:owner_busy, state)
    end
  end

  defp active_lifecycle_binding(%{intent: :active_reattach, lifecycle: lifecycle}) do
    %{
      request_id: lifecycle.request_id,
      codex_turn_id: lifecycle.codex_turn_id,
      eligible_attempt_id: lifecycle.eligible_attempt_id,
      replay_attempt_id: nil,
      replay_generation: lifecycle.replay_generation,
      provisional_binding_digest: nil,
      owner_lease_digest: :crypto.hash(:sha256, "active-owner-lease")
    }
  end

  defp active_lifecycle_binding(_intent), do: nil

  defp apply_replay_preflight_result(
         {:ok, :fresh_dispatch, binding},
         prepared,
         state,
         intent,
         _ref
       ) do
    if fresh_owner_binding?(binding, state) do
      lifecycle =
        (intent.lifecycle || %{replay_generation: 0})
        |> Map.merge(%{
          owner_idle_validated?: true,
          owner_lease_token: state.websocket_owner_lease_token,
          owner_instance_id: state.codex_session.owner_instance_id
        })

      case WebsocketCodec.attach_replay_intent(
             prepared,
             intent.authorization_binding,
             lifecycle
           ) do
        {:ok, resealed} -> {:ok, start_or_queue_prepared_response(resealed, state)}
        {:error, _reason} -> reject_owner_preflight(:owner_busy, state)
      end
    else
      reject_owner_preflight(:owner_busy, state)
    end
  end

  defp apply_replay_preflight_result(
         {:ok, :same_turn_reattach, downstream},
         prepared,
         state,
         _intent,
         _ref
       ) do
    case WebsocketCodec.consume_prepared_frame(prepared) do
      {:ok, nil} ->
        log_reconnect_disposition(state, :same_turn_replay)

        state =
          state
          |> Map.put(:websocket_owner_downstream, downstream)
          |> Map.put(:websocket_owner_active_turn_reconnect?, true)

        {:ok, state}

      _invalid ->
        reject_owner_preflight(:owner_busy, state)
    end
  end

  defp apply_replay_preflight_result(
         {:ok, :provisional, token, 1, owner_process_generation, downstream},
         prepared,
         state,
         intent,
         _ref
       ) do
    consume_suspended_replay(
      prepared,
      state,
      intent,
      token,
      owner_process_generation,
      downstream
    )
  end

  defp apply_replay_preflight_result({:error, reason}, _prepared, state, _intent, _ref),
    do: reject_prepared_response(public_replay_error(reason), state)

  defp apply_replay_preflight_result(_result, _prepared, state, _intent, _ref),
    do: reject_prepared_response(public_replay_error(:owner_busy), state)

  defp fresh_owner_binding?(binding, state) when is_map(binding) do
    binding == Map.take(state.websocket_owner_downstream, [:pid, :epoch, :correlation_id]) and
      is_binary(state.codex_session.owner_instance_id) and
      state.codex_session.owner_instance_id != ""
  end

  defp fresh_owner_binding?(_binding, _state), do: false

  defp consume_suspended_replay(
         prepared,
         state,
         intent,
         token,
         owner_process_generation,
         downstream
       ) do
    with {:ok, reserve} <-
           provisional_control(
             state,
             prepared,
             intent,
             token,
             downstream,
             :provisional_reserve,
             nil
           ),
         {:ok, :consume_reserved, reserve_timeout_ms, reserve_receipt, reserve_receipt_digest} <-
           Adapter.reconnect_control_v2(state, reserve),
         consume_input = %{
           auth: state.auth,
           entitlement_id: intent.lifecycle.entitlement_id,
           request_id: intent.lifecycle.request_id,
           codex_turn_id: intent.lifecycle.codex_turn_id,
           eligible_attempt_id: intent.lifecycle.eligible_attempt_id,
           replay_generation: 1,
           provisional_token: token,
           owner_lease_token: state.websocket_owner_lease_token,
           reserve_timeout_ms: reserve_timeout_ms,
           reserve_receipt: reserve_receipt,
           reserve_receipt_digest: reserve_receipt_digest,
           owner_forwarder_opts:
             prepared.request_options.transport.websocket_owner.forwarder_opts,
           downstream_epoch: downstream.epoch,
           owner_process_generation: owner_process_generation
         },
         {:ok, consumed} <- CodexPooler.Accounting.consume_request_replay(consume_input),
         binding <- replay_binding(prepared, consumed, downstream),
         {:ok, commit} <-
           provisional_control(
             state,
             prepared,
             intent,
             token,
             downstream,
             :provisional_commit,
             consumed.consume_binding
           ),
         {:ok, :committed_not_started, consume_binding} <-
           Adapter.reconnect_control_v2(state, commit),
         true <- consume_binding == consumed.consume_binding,
         request_options <-
           RequestOptions.put_runtime_context(prepared.request_options,
             replay_authorization_binding: intent.authorization_binding,
             replay_lifecycle_binding: consumed.consume_binding,
             replay_generation: 1,
             native_replay_binding: binding,
             native_replay_proof: nil,
             replay_provisional_token: token
           ),
         {:ok, replay_prepared} <- WebsocketCodec.reseal_runtime_frame(prepared, request_options),
         {:ok, replay_prepared} <-
           WebsocketCodec.attach_native_replay_admission(replay_prepared, binding) do
      {:ok, start_or_queue_prepared_response(replay_prepared, state)}
    else
      _failure ->
        reconcile_provisional(state, prepared, token)
        reject_owner_preflight(:owner_busy, state)
    end
  end

  defp reconcile_provisional(state, prepared, token) do
    with {:ok, query} <-
           provisional_control(state, prepared, nil, token, nil, :provisional_query, nil) do
      case Adapter.reconnect_control_v2(state, query) do
        {:ok, status} when status in [:provisional, :consume_reserved] ->
          cancel_provisional(state, prepared, nil, token)

        {:ok, status} when status in [:committed_not_started, :started, :cancelled, :expired] ->
          :ok

        _uncertain ->
          :ok
      end
    end

    :ok
  end

  defp provisional_control(state, prepared, _intent, token, downstream, action, consume_binding) do
    RemoteReconnectControlV2.new(%{
      version: 2,
      action: action,
      intent: :suspended_replay,
      codex_session_id: state.codex_session.id,
      downstream: if(action in [:provisional_reserve, :provisional_commit], do: downstream),
      semantic_turn_digest: prepared.semantic_turn_key,
      replay_claim_digest: prepared.replay_claim_digest,
      provisional_token: token,
      replay_generation: 1,
      owner_lease_token: state.websocket_owner_lease_token,
      control_ref: make_ref(),
      authorization_binding: nil,
      consume_binding: consume_binding
    })
  end

  defp cancel_provisional(state, prepared, _intent, token) do
    with {:ok, control} <-
           provisional_control(state, prepared, nil, token, nil, :provisional_cancel, nil) do
      _result = Adapter.reconnect_control_v2(state, control)
    end

    :ok
  end

  defp replay_binding(prepared, consumed, downstream) do
    struct!(CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission.Binding, %{
      request_id: consumed.request.id,
      codex_turn_id: consumed.turn.id,
      eligible_attempt_id: consumed.entitlement.eligible_attempt_id,
      replay_attempt_id: consumed.attempt.id,
      replay_generation: 1,
      semantic_turn_digest: prepared.semantic_turn_key,
      replay_claim_digest: prepared.replay_claim_digest,
      provisional_binding_digest: consumed.entitlement.provisional_binding_digest,
      owner_lease_digest: consumed.entitlement.owner_lease_digest,
      downstream_epoch: downstream.epoch,
      owner_process_generation: consumed.owner_process_generation
    })
  end

  defp public_replay_error(_reason) do
    %{
      status: 409,
      code: "duplicate_turn",
      message: "duplicate Codex turn was already recorded for this session",
      param: "request_id"
    }
  end

  defp legacy_owner_preflight(prepared, state, semantic_turn_key) do
    control_ref = make_ref()

    case Adapter.preflight_reconnect(state, semantic_turn_key, control_ref) do
      {:ok, :dispatch} ->
        {:ok, start_or_queue_prepared_response(prepared, state)}

      {:ok, :same_turn_replay} ->
        log_reconnect_disposition(state, :same_turn_replay)
        {:ok, state}

      {:ok, :replacement_handoff, ^control_ref} ->
        log_reconnect_disposition(state, :replacement_handoff)

        {:ok,
         Map.put(state, :websocket_owner_pending_handoff, %{
           prepared: prepared,
           semantic_turn_key: semantic_turn_key,
           control_ref: control_ref,
           owner_turn_id: Map.get(state, :websocket_owner_reconnect_turn_pid),
           outcome_logged?: false
         })}

      {:ok, :duplicate_replacement, existing_ref} ->
        case Map.get(state, :websocket_owner_pending_handoff) do
          %{semantic_turn_key: ^semantic_turn_key, control_ref: ^existing_ref} -> {:ok, state}
          _other -> reject_owner_preflight(:owner_busy, state)
        end

      {:error, reason} ->
        reject_owner_preflight(reason, state)
    end
  end

  defp reject_owner_preflight(reason, state) do
    log_reconnect_disposition(state, :owner_busy)
    reject_prepared_response(owner_error(reason), state)
  end

  defp reject_prepared_response(reason, state) do
    :telemetry.execute([:codex_pooler, :gateway, :native_compaction, :rejection], %{count: 1}, %{
      reason: DiagnosticTaxonomy.identifier(reason)
    })

    if identity_error?(reason), do: log_reconnect_disposition(state, :identity_rejected)

    rejected_state = clear_public_response_context(state)

    _trace =
      NativeCompactionTrace.emit_full(:socket_request_rejected, %{
        pid_role: :socket,
        socket_pid: self(),
        branch: :prepared_response_rejected,
        reason: reason,
        state_before: trace_socket_state(state),
        state_after: trace_socket_state(rejected_state)
      })

    payload =
      reason
      |> Adapter.websocket_error()
      |> maybe_put_public_stream_id(Map.get(state, :public_response_stream_id))
      |> Jason.encode!()

    _trace =
      NativeCompactionTrace.emit_full(:downstream_websocket_frame_sent, %{
        direction: :pooler_to_downstream,
        socket_pid: self(),
        frame_json: decode_trace_frame(payload),
        frame_text: payload,
        outcome: :error,
        branch: :prepared_response_rejected
      })

    {:push, {:text, payload}, rejected_state}
  end

  defp trace_socket_state(state) do
    %{
      task_count: state |> Map.get(:tasks, MapSet.new()) |> MapSet.size(),
      queued_count: state |> Map.get(:queued_response_payloads, :queue.new()) |> :queue.len(),
      public_turn_active: is_pid(Map.get(state, :public_response_task_pid)),
      owner_forwarded: owner_forwarded_socket?(state),
      native_output_count:
        state |> Map.get(:native_turn_output_task_pids, MapSet.new()) |> MapSet.size()
    }
  end

  defp identity_error?(%{param: param}) when is_binary(param) do
    param in [
      "client_metadata",
      "client_metadata.turn_id",
      "client_metadata.x-codex-turn-metadata",
      "client_metadata.x-codex-turn-metadata.turn_id",
      "turn_id",
      "request_id",
      "codex_session_id"
    ]
  end

  defp identity_error?(_reason), do: false

  defp owner_error(reason) do
    case WebsocketOwnerContract.safe_error_payload(reason, nil) do
      {:ok, payload} -> payload
      {:error, _unknown} -> reason
    end
  end

  defp handle_owner_handoff_message(message, state) do
    case Adapter.accept_handoff_message(message, state) do
      {:ok, :ready} ->
        ready_pending_owner_handoff(state)

      {:ok, {:ready, owner_turn_id}} ->
        state
        |> bind_pending_owner_turn(owner_turn_id)
        |> ready_pending_owner_handoff()

      {:ok, {:failed, reason}} ->
        fail_pending_owner_handoff(state, reason)

      {:ok, {{:failed, reason}, owner_turn_id}} ->
        state
        |> bind_pending_owner_turn(owner_turn_id)
        |> fail_pending_owner_handoff(reason)

      :drop ->
        {:ok, state}
    end
  end

  defp bind_pending_owner_turn(state, owner_turn_id) when is_pid(owner_turn_id) do
    Map.update(state, :websocket_owner_pending_handoff, nil, fn pending ->
      Map.put(pending, :owner_turn_id, owner_turn_id)
    end)
  end

  defp ready_pending_owner_handoff(state) do
    case Map.get(state, :websocket_owner_pending_handoff) do
      %{prepared: prepared, owner_turn_id: owner_turn_id} when is_pid(owner_turn_id) ->
        state =
          state
          |> log_pending_handoff_outcome(:ready)
          |> Map.put(:websocket_owner_pending_handoff, nil)
          |> Map.put(:websocket_owner_active_turn_reconnect?, false)
          |> Map.put(:websocket_owner_reconnect_turn_pid, nil)
          |> reset_owner_turn_output()

        {:ok, start_tracked_response_task(prepared, state)}

      _missing ->
        {:ok, state}
    end
  end

  defp fail_pending_owner_handoff(state, reason) do
    outcome = if reason == :owner_drained, do: :owner_drained, else: :timeout

    state =
      state
      |> log_pending_handoff_outcome(outcome)
      |> Map.put(:websocket_owner_pending_handoff, nil)

    reject_prepared_response(owner_error(reason), state)
  end

  defp clear_pending_owner_handoff(state, outcome, opts \\ []) do
    case Map.get(state, :websocket_owner_pending_handoff) do
      %{semantic_turn_key: semantic_turn_key, control_ref: control_ref} ->
        if Keyword.get(opts, :cancel?, true) do
          _result = Adapter.cancel_reconnect(state, semantic_turn_key, control_ref)
        end

        state
        |> log_pending_handoff_outcome(outcome)
        |> Map.put(:websocket_owner_pending_handoff, nil)

      _missing ->
        state
    end
  end

  defp log_pending_handoff_outcome(state, outcome) do
    log_handoff_outcome(state, outcome)
    state
  end

  defp owner_monitor_handoff_outcome(reason) do
    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
      do: :owner_drained,
      else: :timeout
  end

  defp log_reconnect_disposition(state, disposition) do
    state
    |> reconnect_log_metadata()
    |> WebsocketConnectionLogger.log_reconnect_disposition(disposition)
  end

  defp log_handoff_outcome(state, outcome) do
    state
    |> reconnect_log_metadata()
    |> WebsocketConnectionLogger.log_handoff_outcome(outcome)
  end

  defp reconnect_log_metadata(state) do
    state
    |> Adapter.terminate_close_metadata()
    |> Map.put(:phase, "handoff")
  end

  defp request_row_producing_prepared?(%PreparedWebsocketFrame{variant: variant}),
    do: variant in [:native_response_create, :public_response_create, :response_processed]

  defp request_row_producing_prepared?(_prepared), do: false

  defp continuity_ordered_prepared?(%PreparedWebsocketFrame{variant: :response_processed}),
    do: true

  defp continuity_ordered_prepared?(%PreparedWebsocketFrame{
         request_options: %{payload_context: %{compaction_trigger_bridge?: true}}
       }),
       do: true

  defp continuity_ordered_prepared?(%PreparedWebsocketFrame{payload: payload}) do
    WebsocketCodec.continuity_ordered_payload?(Jason.encode!(payload))
  end

  defp start_or_queue_prepared_response(prepared, state) do
    if response_payload_requires_queue?(prepared, state) do
      queue_prepared_response(state, prepared)
    else
      start_tracked_response_task(prepared, state)
    end
  end

  defp response_payload_requires_queue?(%PreparedWebsocketFrame{} = prepared, state) do
    public_response_start_error_pending?(state) or
      (public_response_payload?(prepared, state) and public_turn_open?(state)) or
      (owner_forwarded_socket?(state) and active_response_task?(state)) or
      (active_response_task?(state) and continuity_ordered_prepared?(prepared))
  end

  defp maybe_start_queued_response_task(state) do
    if Map.get(state, :firewall_revoked?, false) or active_response_task?(state) or
         public_turn_open?(state) or public_response_start_error_pending?(state) do
      state
    else
      case Map.get(state, :queued_response_payloads, :queue.new()) |> :queue.out() do
        {{:value, prepared}, queue} ->
          state = Map.put(state, :queued_response_payloads, queue)
          start_queued_response(prepared, state)

        {:empty, _queue} ->
          state
      end
    end
  end

  defp start_deferred_or_tracked_response(
         %PreparedWebsocketFrame{
           request_options: %RequestOptions{
             native_compaction_reservation: %{
               metadata: metadata,
               phase: phase,
               control_ref: control_ref
             }
           }
         } = prepared,
         state
       ) do
    prepared = %{
      prepared
      | request_options: %{prepared.request_options | native_compaction_reservation: nil}
    }

    prepared = put_prepared_runtime_options(prepared, Adapter.response_options(state, true, nil))

    case reserve_owner_capability(prepared, metadata, phase, control_ref, state) do
      {:ok, prepared} ->
        start_tracked_response_task(prepared, state)

      {:error, reason} ->
        start_owner_retarget_error_task(owner_error(reason), prepared, state)
    end
  end

  defp start_deferred_or_tracked_response(prepared, state),
    do: start_tracked_response_task(prepared, state)

  defp start_queued_response(%PreparedWebsocketFrame{} = prepared, state),
    do: start_deferred_or_tracked_response(prepared, state)

  defp start_queued_response(payload, state) when is_binary(payload) do
    case prepare_and_dispatch_response(payload, state) do
      {:ok, state} -> state
      {:push, _frame, state} -> state
    end
  end

  defp start_tracked_response_task(%PreparedWebsocketFrame{} = prepared, state) do
    state = activate_prepared_public_context(state, prepared)

    case Adapter.maybe_retarget_before_start(Jason.encode!(prepared.payload), state) do
      {:ok, state} ->
        state =
          state
          |> maybe_mark_request_response_work_started(prepared)
          |> reset_native_owner_terminal_delivery()

        parent = self()
        {:ok, pid, direct_ref} = start_response_task(parent, prepared, state)
        _trace_enroll = NativeCompactionTrace.enroll(:response_task, pid)
        monitor = Process.monitor(pid)

        state
        |> track_response_task(pid, monitor)
        |> put_direct_context(pid, direct_ref, parent)
        |> maybe_open_public_turn(prepared, pid)

      {:error, reason} ->
        _cancelled =
          RequestOptions.cancel_native_compaction_reservation(
            prepared.request_options,
            System.system_time(:millisecond)
          )

        start_owner_retarget_error_task(reason, prepared, state)
    end
  end

  defp put_prepared_public_context(%PreparedWebsocketFrame{} = prepared, state) do
    if prepared.variant == :public_response_create do
      stream_id = Map.get(state, :public_response_stream_id)
      websocket_state = Map.get(state, :public_responses_websocket_state)

      request_options = %{
        prepared.request_options
        | extra:
            Map.merge(prepared.request_options.extra, %{
              socket_public_stream_id: stream_id,
              socket_public_websocket_state: websocket_state
            })
      }

      %{prepared | request_options: request_options}
    else
      prepared
    end
  end

  defp activate_prepared_public_context(state, %PreparedWebsocketFrame{
         variant: :public_response_create,
         request_options: %{extra: extra}
       }) do
    state
    |> Map.put(:public_response_stream_id, Map.get(extra, :socket_public_stream_id))
    |> Map.put(
      :public_responses_websocket_state,
      Map.get(extra, :socket_public_websocket_state)
    )
  end

  defp activate_prepared_public_context(state, _prepared), do: state

  defp public_response_context(state) do
    {
      Map.get(state, :public_response_stream_id),
      Map.get(state, :public_responses_websocket_state)
    }
  end

  defp restore_public_response_context(state, {stream_id, websocket_state}) do
    state
    |> Map.put(:public_response_stream_id, stream_id)
    |> Map.put(:public_responses_websocket_state, websocket_state)
  end

  defp prepare_response_payload(payload, state) do
    with {:ok, payload, state} <- prepare_backend_compaction_payload(payload, state) do
      prepare_public_response_payload(payload, state)
    end
  end

  defp prepare_backend_compaction_payload(payload, state) do
    case WebsocketCodec.decode_payload(payload) do
      {:ok, decoded_payload} ->
        case PayloadNormalizer.validate_backend_compaction_turn_state(decoded_payload) do
          :passthrough ->
            {:ok, payload, state}

          {:ok, nil} ->
            {:ok, payload, state}

          {:ok, turn_state} ->
            {:ok, put_frame_turn_state(payload, decoded_payload, turn_state),
             put_frame_turn_state_options(state, turn_state)}

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, _reason} ->
        {:ok, payload, state}
    end
  end

  defp put_frame_turn_state(payload, decoded_payload, turn_state) do
    client_metadata =
      decoded_payload
      |> Map.get("client_metadata", %{})
      |> Map.put("x-codex-turn-state", turn_state)

    decoded_payload
    |> Map.put("client_metadata", client_metadata)
    |> Jason.encode()
    |> case do
      {:ok, encoded_payload} -> encoded_payload
      {:error, _reason} -> payload
    end
  end

  defp put_frame_turn_state_options(state, turn_state) do
    opts = Map.get(state, :opts, %{})

    forwarded_headers =
      opts
      |> Map.get(:forwarded_headers, [])
      |> Enum.reject(fn
        {name, _value} when is_binary(name) -> String.downcase(name) == "x-codex-turn-state"
        _header -> false
      end)
      |> then(&[{"x-codex-turn-state", turn_state} | &1])

    Map.put(
      state,
      :opts,
      Map.merge(opts, %{accepted_turn_state: turn_state, forwarded_headers: forwarded_headers})
    )
  end

  defp queue_prepared_response(state, prepared) do
    Map.update(
      state,
      :queued_response_payloads,
      :queue.from_list([prepared]),
      &:queue.in(prepared, &1)
    )
  end

  defp start_owner_retarget_error_task(reason, prepared, state) do
    parent = self()
    {:ok, pid, _direct_ref} = start_response_task(parent, {:owner_retarget_error, reason}, state)
    monitor = Process.monitor(pid)

    state
    |> track_response_task(pid, monitor)
    |> maybe_open_public_turn(prepared, pid)
    |> Map.put(:public_owner_retarget_error?, true)
  end

  defp handle_public_retarget_error_done(pid, {:error, reason}, state) do
    log_failed_native_websocket_turn(state, pid, reason, false)
    payload = encode_public_error(reason, state)
    {:push, {:text, payload}, finish_public_turn(state)}
  end

  defp handle_public_retarget_error_done(_pid, result, state) do
    handle_public_owner_response_done(result, state)
  end

  @spec maybe_mark_request_response_work_started(map(), term()) :: map()
  defp maybe_mark_request_response_work_started(state, payload) do
    if request_row_producing_prepared?(payload) do
      Map.put(state, :request_response_work_started?, true)
    else
      state
    end
  end

  defp owner_forwarded_socket?(state), do: Adapter.owner?(state)

  defp active_response_task?(state), do: MapSet.size(Map.get(state, :tasks, MapSet.new())) > 0

  defp tracked_response_task?(state, pid) when is_pid(pid) do
    MapSet.member?(Map.get(state, :tasks, MapSet.new()), pid)
  end

  defp tracked_response_task_pid(state) do
    state
    |> Map.get(:tasks, MapSet.new())
    |> Enum.find(&is_pid/1)
  end

  defp active_native_owner_turn_pid(state) do
    if owner_forwarded_socket?(state) and not Adapter.public_responses_stream?(state),
      do: reconnect_or_tracked_owner_turn_pid(state)
  end

  defp reconnect_or_tracked_owner_turn_pid(%{websocket_owner_reconnect_turn_pid: pid})
       when is_pid(pid),
       do: pid

  defp reconnect_or_tracked_owner_turn_pid(state) do
    case Map.get(state, :tasks, MapSet.new()) |> MapSet.to_list() do
      [pid] when is_pid(pid) -> pid
      _tasks -> nil
    end
  end

  defp public_response_payload?(%PreparedWebsocketFrame{} = prepared, state) do
    Adapter.public_responses_stream?(state) and
      request_row_producing_prepared?(prepared)
  end

  defp public_response_payload?(payload, state) when is_binary(payload) do
    Adapter.public_responses_stream?(state) and
      Adapter.request_row_producing_response_payload?(payload)
  end

  defp public_turn_open?(state), do: is_pid(Map.get(state, :public_response_task_pid))

  defp public_response_start_error_pending?(state) do
    is_reference(Map.get(state, :public_response_start_error_ref))
  end

  defp track_response_task(state, pid, monitor) when is_pid(pid) and is_reference(monitor) do
    state
    |> Map.update(:tasks, MapSet.new([pid]), &MapSet.put(&1, pid))
    |> Map.update(:task_monitors, %{pid => monitor}, &Map.put(&1, pid, monitor))
  end

  defp put_response_task_activity(state, pid, token) do
    Map.update(
      state,
      :response_task_activities,
      %{pid => token},
      &Map.put(&1, pid, token)
    )
  end

  defp response_task_activity?(state, pid) when is_pid(pid) do
    Map.has_key?(Map.get(state, :response_task_activities, %{}), pid)
  end

  defp maybe_schedule_response_delivery({:stop, reason, detail, state}, pid) do
    {:stop, reason, detail, complete_response_task_delivery_for_pid(state, pid)}
  end

  defp maybe_schedule_response_delivery(result, pid) do
    map_socket_result_state(result, fn state ->
      if response_delivery_safe?(result, state, pid) do
        schedule_response_task_delivery(state, pid, :completed)
      else
        state
      end
    end)
  end

  defp response_delivery_safe?(result, state, pid) do
    cond do
      local_owner_socket?(state) and match?({:ok, _state}, result) ->
        response_task_terminal_accepted?(state, pid)

      not owner_forwarded_socket?(state) and match?({:ok, _state}, result) ->
        response_task_terminal_accepted?(state, pid)

      not owner_forwarded_socket?(state) ->
        true

      Adapter.public_responses_stream?(state) ->
        Map.get(state, :public_response_task_pid) != pid

      true ->
        Map.get(state, :native_owner_terminal_delivered?, false)
    end
  end

  defp map_socket_result_state({:ok, state}, fun), do: {:ok, fun.(state)}
  defp map_socket_result_state({:push, frame, state}, fun), do: {:push, frame, fun.(state)}

  defp schedule_active_response_task_delivery(state) do
    state
    |> Map.get(:response_task_activities, %{})
    |> Map.keys()
    |> Enum.find(&tracked_response_task?(state, &1))
    |> then(fn pid ->
      outcome = if response_task_result_ready?(state, pid), do: :completed, else: :delivered
      schedule_response_task_delivery(state, pid, outcome)
    end)
  end

  defp schedule_response_task_delivery(state, pid, outcome \\ :delivered)

  defp schedule_response_task_delivery(state, pid, outcome) when is_pid(pid) do
    activities = Map.get(state, :response_task_activities, %{})
    scheduled = Map.get(state, :response_task_delivery_scheduled, MapSet.new())

    case Map.get(activities, pid) do
      token when is_reference(token) ->
        if MapSet.member?(scheduled, token) do
          put_response_task_delivery_outcome(state, pid, outcome)
        else
          send(self(), {:websocket_response_delivery_complete, pid, token})

          state
          |> Map.put(:response_task_delivery_scheduled, MapSet.put(scheduled, token))
          |> put_response_task_delivery_outcome(pid, outcome)
        end

      _unknown ->
        state
    end
  end

  defp schedule_response_task_delivery(state, _pid, _outcome), do: state

  defp put_response_task_delivery_outcome(state, pid, outcome) do
    Map.update(state, :response_task_delivery_outcomes, %{pid => outcome}, fn outcomes ->
      Map.update(outcomes, pid, outcome, &prefer_response_task_delivery_outcome(&1, outcome))
    end)
  end

  defp prefer_response_task_delivery_outcome(:completed, _new), do: :completed
  defp prefer_response_task_delivery_outcome(:aborted, _new), do: :aborted
  defp prefer_response_task_delivery_outcome(:delivered, new), do: new

  defp complete_response_task_delivery(state, pid, token) do
    case Map.get(Map.get(state, :response_task_activities, %{}), pid) do
      ^token ->
        ack_pid = Map.get(Map.get(state, :response_task_delivery_recipients, %{}), pid, pid)
        outcome = Map.get(Map.get(state, :response_task_delivery_outcomes, %{}), pid, :delivered)

        :ok = acknowledge_response_task_delivery(ack_pid, token, outcome)

        _trace =
          NativeCompactionTrace.emit(:delivery_finished, %{
            pid_role: :response_task,
            response_task_pid: pid,
            activity_token: token,
            outcome: outcome
          })

        state
        |> Map.update(:response_task_activities, %{}, &Map.delete(&1, pid))
        |> Map.update(
          :response_task_delivery_scheduled,
          MapSet.new(),
          &MapSet.delete(&1, token)
        )
        |> Map.update(:response_task_delivery_recipients, %{}, &Map.delete(&1, pid))
        |> Map.update(:response_task_delivery_outcomes, %{}, &Map.delete(&1, pid))
        |> Map.update(:response_task_results_ready, MapSet.new(), &MapSet.delete(&1, pid))
        |> Map.update(:response_task_terminals_accepted, MapSet.new(), &MapSet.delete(&1, pid))
        |> Map.update(:response_task_completed_terminals, MapSet.new(), &MapSet.delete(&1, pid))
        |> Map.update(:response_task_cleanup_results, %{}, &Map.delete(&1, pid))
        |> do_remove_tracked_response_task(pid)
        |> remove_native_turn_output(pid)
        |> Map.put(:native_owner_terminal_delivered?, false)
        |> maybe_start_queued_response_task()

      _stale ->
        state
    end
  end

  defp complete_response_task_delivery_for_pid(state, pid) do
    case Map.get(Map.get(state, :response_task_activities, %{}), pid) do
      token when is_reference(token) -> complete_response_task_delivery(state, pid, token)
      _unknown -> state
    end
  end

  defp acknowledge_response_task_cleanup(state) do
    registry = response_task_activity_registry(state)

    state
    |> Map.get(:tasks, MapSet.new())
    |> Enum.each(fn pid ->
      case authoritative_delivery_target(state, pid, registry) do
        {:ok, token, ack_pid} ->
          outcome = response_task_cleanup_outcome(state, pid, token, ack_pid, registry)
          ResponseTask.acknowledge_delivery(ack_pid, token, outcome)

        :unknown ->
          :ok
      end
    end)

    :ok
  end

  defp response_task_cleanup_outcome(state, pid, token, pid, registry) do
    completed? =
      MapSet.member?(Map.get(state, :response_task_completed_terminals, MapSet.new()), pid)

    if completed? and Map.get(Map.get(state, :response_task_cleanup_results, %{}), pid) == :ok and
         ActivityRegistry.delivery_target(pid, name: registry) == {:ok, token, pid, :admitted},
       do: :completed,
       else: :aborted
  catch
    :exit, _reason -> :aborted
  end

  defp response_task_cleanup_outcome(_state, _pid, _token, _ack_pid, _registry), do: :aborted

  defp put_response_task_cleanup_result(state, pid, result) do
    if tracked_response_task?(state, pid) do
      outcome = response_task_cleanup_result(result)

      Map.update(
        state,
        :response_task_cleanup_results,
        %{pid => outcome},
        &Map.put(&1, pid, outcome)
      )
    else
      state
    end
  end

  defp response_task_cleanup_result(:ok), do: :ok
  defp response_task_cleanup_result({:ok, _result}), do: :ok

  defp response_task_cleanup_result({:socket_response_result, _source, result}),
    do: response_task_cleanup_result(result)

  defp response_task_cleanup_result({:response_task_result, result, _visible?}),
    do: response_task_cleanup_result(result)

  defp response_task_cleanup_result(_result), do: :error

  defp await_response_task_cleanup_results(state) do
    tasks = Map.get(state, :tasks, MapSet.new())
    monitors = Map.new(tasks, &{&1, Process.monitor(&1)})
    deadline = response_task_deadline(@pre_cleanup_response_task_drain_ms)
    await_response_task_cleanup_results(state, tasks, monitors, deadline)
  end

  defp await_response_task_cleanup_results(state, tasks, monitors, deadline) do
    if MapSet.size(tasks) == 0 do
      {tasks, state}
    else
      receive do
        {:codex_response_done, pid, result} when is_map_key(monitors, pid) ->
          state = put_response_task_cleanup_result(state, pid, result)
          await_response_task_cleanup_results(state, tasks, monitors, deadline)

        {:direct_request_cleanup, pid, ref, receipt} when is_map_key(monitors, pid) ->
          state = accept_direct_cleanup(state, pid, ref, receipt)
          await_response_task_cleanup_results(state, tasks, monitors, deadline)

        {:DOWN, ref, :process, pid, _reason}
        when is_map_key(monitors, pid) and :erlang.map_get(monitors, pid) == ref ->
          tasks = remove_response_task(tasks, monitors, pid)
          await_response_task_cleanup_results(state, tasks, monitors, deadline)
      after
        response_task_wait_timeout(deadline) ->
          demonitor_response_tasks(monitors)
          {tasks, state}
      end
    end
  end

  defp authoritative_response_task_activity?(state, pid) do
    match?(
      {:ok, _token, _ack_pid},
      authoritative_delivery_target(state, pid, response_task_activity_registry(state))
    )
  end

  defp authoritative_delivery_target(state, pid, registry) do
    case ActivityRegistry.delivery_target(pid, name: registry) do
      {:ok, token, ack_pid, _status} -> {:ok, token, ack_pid}
      :unknown -> state_delivery_target(state, pid)
    end
  catch
    :exit, _reason -> state_delivery_target(state, pid)
  end

  defp state_delivery_target(state, pid) do
    case Map.get(Map.get(state, :response_task_activities, %{}), pid) do
      token when is_reference(token) ->
        ack_pid = Map.get(Map.get(state, :response_task_delivery_recipients, %{}), pid, pid)
        {:ok, token, ack_pid}

      _unknown ->
        :unknown
    end
  end

  defp response_task_activity_registry(state) do
    Map.get(state, :response_task_activity_registry, ActivityRegistry)
  end

  defp handle_cancelled_response_activity(state, pid, token, ack_pid) do
    case Map.get(Map.get(state, :response_task_activities, %{}), pid) do
      ^token ->
        if natural_response_delivery_scheduled?(state, pid) do
          {:ok, state}
        else
          deliver_cancelled_response_activity(state, pid, ack_pid)
        end

      _stale ->
        {:ok, state}
    end
  end

  defp deliver_cancelled_response_activity(state, pid, ack_pid) do
    {:ok, payload} = WebsocketOwnerContract.safe_error_payload(:owner_drained, nil)

    state =
      state
      |> Map.update(
        :response_task_delivery_recipients,
        %{pid => ack_pid},
        &Map.put(&1, pid, ack_pid)
      )
      |> put_response_task_delivery_outcome(pid, :aborted)

    if Adapter.public_responses_stream?(state) do
      state =
        state
        |> Map.put(:websocket_owner_drain_observed?, true)
        |> abort_public_turn(:owner_drained)
        |> schedule_response_task_delivery(pid, :aborted)

      {:push, {:text, encode_public_error(payload, state)}, state}
    else
      state =
        state
        |> Map.put(:websocket_owner_drain_observed?, true)
        |> reset_owner_turn_output()
        |> schedule_response_task_delivery(pid, :aborted)

      {:push, {:text, Jason.encode!(Adapter.websocket_error(payload))}, state}
    end
  end

  defp acknowledge_response_task_delivery(ack_pid, token, outcome)
       when outcome in [:completed, :aborted],
       do: ResponseTask.acknowledge_delivery(ack_pid, token, outcome)

  defp acknowledge_response_task_delivery(ack_pid, token, _outcome),
    do: ResponseTask.acknowledge_delivery(ack_pid, token)

  defp mark_response_task_result_ready(state, pid) do
    if response_task_delivery_candidate?(state, pid) do
      Map.update(
        state,
        :response_task_results_ready,
        MapSet.new([pid]),
        &MapSet.put(&1, pid)
      )
    else
      state
    end
  end

  defp response_task_result_ready?(state, pid) when is_pid(pid) do
    MapSet.member?(Map.get(state, :response_task_results_ready, MapSet.new()), pid)
  end

  defp response_task_result_ready?(_state, _pid), do: false

  defp maybe_accept_response_task_terminal(state, pid, data) do
    if response_task_delivery_candidate?(state, pid) and
         match?({:ok, _outcome}, StreamProtocol.terminal_outcome(data)) do
      _trace =
        NativeCompactionTrace.emit(:owner_terminal, %{
          pid_role: :response_task,
          response_task_pid: pid,
          activity_token: get_in(state, [:response_task_activities, pid]),
          outcome: terminal_outcome(data)
        })

      state
      |> Map.update(:response_task_terminals_accepted, MapSet.new([pid]), &MapSet.put(&1, pid))
      |> maybe_mark_completed_response_task_terminal(pid, terminal_outcome(data))
    else
      state
    end
  end

  defp maybe_mark_completed_response_task_terminal(state, pid, :ok) do
    Map.update(state, :response_task_completed_terminals, MapSet.new([pid]), &MapSet.put(&1, pid))
  end

  defp maybe_mark_completed_response_task_terminal(state, _pid, _outcome), do: state

  defp response_task_terminal_accepted?(state, pid) when is_pid(pid) do
    MapSet.member?(Map.get(state, :response_task_terminals_accepted, MapSet.new()), pid)
  end

  defp response_task_delivery_candidate?(state, pid) when is_pid(pid) do
    tracked_response_task?(state, pid) or
      (Map.get(state, :websocket_owner_active_turn_reconnect?, false) and
         Map.get(state, :websocket_owner_reconnect_turn_pid) == pid)
  end

  defp maybe_schedule_accepted_response_task_delivery(state, pid) do
    if response_task_result_ready?(state, pid) and response_task_terminal_accepted?(state, pid) do
      schedule_response_task_delivery(state, pid, :completed)
    else
      state
    end
  end

  defp natural_response_delivery_scheduled?(state, pid) do
    Map.get(Map.get(state, :response_task_delivery_outcomes, %{}), pid) == :completed
  end

  defp reset_native_owner_terminal_delivery(state) do
    if owner_forwarded_socket?(state) and not Adapter.public_responses_stream?(state) do
      Map.put(state, :native_owner_terminal_delivered?, false)
    else
      state
    end
  end

  defp response_result_outcome({:ok, _result}), do: :ok
  defp response_result_outcome({:error, _reason}), do: :error

  defp response_result_outcome({:socket_response_result, _source, result}),
    do: response_result_outcome(result)

  defp response_result_outcome({:response_task_result, result, _visible?}),
    do: response_result_outcome(result)

  defp response_result_outcome({:response_task_failure, _result}), do: :error
  defp response_result_outcome(_result), do: :finished

  defp terminal_outcome(data) do
    case StreamProtocol.terminal_outcome(data) do
      {:ok, %{kind: :completed}} -> :ok
      {:ok, _outcome} -> :error
      _other -> :error
    end
  end

  defp maybe_open_public_turn(state, payload, pid) do
    if public_response_payload?(payload, state) do
      state
      |> Map.put(:public_response_task_pid, pid)
      |> Map.put(
        :public_responses_websocket_state,
        Adapter.public_responses_turn_state(Map.get(state, :public_response_stream_id))
      )
      |> Map.put(:public_turn_task_done?, false)
      |> Map.put(:public_turn_owner_complete?, false)
      |> Map.put(:public_owner_retarget_error?, false)
      |> Map.put(:public_turn_aborted?, false)
      |> Map.put(:public_turn_output_committed?, false)
    else
      state
    end
  end

  defp prepare_public_response_payload(payload, state) do
    if public_response_payload?(payload, state) do
      case WebsocketCodec.stream_id(payload) do
        :omitted ->
          {:ok, payload, put_public_response_context(state, nil)}

        {:ok, stream_id} ->
          {:ok, remove_stream_id(payload), put_public_response_context(state, stream_id)}

        {:error, reason} ->
          {:error, reason, clear_public_response_context(state)}
      end
    else
      {:ok, payload, state}
    end
  end

  defp remove_stream_id(payload) do
    {:ok, decoded} = WebsocketCodec.decode_payload(payload)

    decoded
    |> Map.delete("stream_id")
    |> Jason.encode!()
  end

  defp put_public_response_context(state, stream_id) do
    state
    |> Map.put(:public_response_stream_id, stream_id)
    |> Map.put(:public_responses_websocket_state, Adapter.public_responses_turn_state(stream_id))
  end

  defp clear_public_response_context(state) do
    state
    |> Map.put(:public_response_stream_id, nil)
    |> Map.put(:public_responses_websocket_state, nil)
  end

  defp encode_public_error(reason, state) do
    reason
    |> Adapter.websocket_error()
    |> maybe_put_public_stream_id(Map.get(state, :public_response_stream_id))
    |> Jason.encode!()
  end

  defp maybe_put_public_stream_id(payload, stream_id) when is_binary(stream_id) do
    Map.put(payload, "stream_id", stream_id)
  end

  defp maybe_put_public_stream_id(payload, _stream_id), do: payload

  defp handle_output_commit_probe(message, state) do
    with false <- public_turn_aborted?(state),
         false <- Map.get(state, :public_turn_owner_complete?, false),
         %{epoch: epoch, correlation_id: correlation_id} <-
           Map.get(state, :websocket_owner_downstream),
         owner_turn_id when is_pid(owner_turn_id) <- output_commit_probe_task_pid(message, state),
         {:ok, active_turn_ref, owner_pid, probe_ref} <-
           WebsocketOwnerContract.accept_output_commit_probe(
             message,
             epoch,
             correlation_id,
             owner_turn_id
           ) do
      send(
        owner_pid,
        {:websocket_owner_output_commit_ack, correlation_id, epoch, owner_turn_id,
         active_turn_ref, probe_ref, output_commit_probe_visible?(state, owner_turn_id)}
      )
    end

    {:ok, state}
  end

  defp output_commit_probe_task_pid(message, state) do
    cond do
      Adapter.public_responses_stream?(state) ->
        Map.get(state, :public_response_task_pid)

      owner_forwarded_socket?(state) ->
        tracked_native_owner_turn_pid(message, state)

      true ->
        nil
    end
  end

  defp tracked_native_owner_turn_pid(
         {:websocket_owner_output_commit_probe, _correlation_id, _epoch, owner_turn_id,
          _active_turn_ref, _owner_pid, _probe_ref},
         state
       )
       when is_pid(owner_turn_id) do
    if tracked_response_task?(state, owner_turn_id), do: owner_turn_id
  end

  defp tracked_native_owner_turn_pid(_message, _state), do: nil

  defp output_commit_probe_visible?(state, owner_turn_id) do
    if Adapter.public_responses_stream?(state) do
      Map.get(state, :public_turn_output_committed?, false)
    else
      state
      |> Map.get(:native_turn_output_task_pids, MapSet.new())
      |> MapSet.member?(owner_turn_id)
    end
  end

  defp maybe_mark_public_turn_output_committed(state, data) do
    if StreamProtocol.internal_control_event?(data) do
      state
    else
      Map.put(state, :public_turn_output_committed?, true)
    end
  end

  defp owner_liveness_error?({:response_task_result, {:error, reason}, _visible_output?})
       when reason in [
              :owner_crashed,
              :owner_unavailable,
              :owner_forward_timeout,
              :stale_owner,
              :owner_drained
            ],
       do: true

  defp owner_liveness_error?(_result), do: false

  defp owner_liveness_error({:response_task_result, {:error, reason}, _visible_output?}),
    do: reason

  defp remove_tracked_response_task(state, pid) when is_pid(pid) do
    if response_task_activity?(state, pid) do
      state
    else
      do_remove_tracked_response_task(state, pid)
    end
  end

  defp do_remove_tracked_response_task(state, pid) when is_pid(pid) do
    if context = Map.get(Map.get(state, :direct_cleanup_contexts, %{}), pid) do
      case DirectCleanup.cancel(context, "client_disconnected") do
        :none -> :ok
        result -> log_interrupt_failure(result, state)
      end
    end

    {monitor, state} = pop_task_monitor(state, pid)

    if monitor do
      Process.demonitor(monitor, [:flush])
    end

    state
    |> Map.update(:tasks, MapSet.new(), &MapSet.delete(&1, pid))
    |> clear_direct_cleanup(pid)
    |> DownstreamSession.clear_cleanup_witness(pid)
  end

  defp clear_direct_cleanup(state, pid) do
    Enum.reduce([:direct_cleanup_contexts, :direct_cleanup_receipts], state, fn key, current ->
      if Map.has_key?(current, key),
        do: Map.update!(current, key, &Map.delete(&1, pid)),
        else: current
    end)
  end

  defp remove_tracked_response_task(state, pid, monitor)
       when is_pid(pid) and is_reference(monitor) do
    case Map.get(Map.get(state, :task_monitors, %{}), pid) do
      ^monitor -> remove_tracked_response_task(state, pid)
      _unknown -> state
    end
  end

  defp cancel_tracked_response_tasks(state, reason) do
    state
    |> Map.get(:tasks, MapSet.new())
    |> Enum.reject(&response_task_activity?(state, &1))
    |> cancel_response_tasks(reason)

    state
  end

  defp cancel_response_tasks(tasks, reason) do
    tasks
    |> Enum.each(fn
      pid when is_pid(pid) -> Process.exit(pid, {:shutdown, reason})
      _value -> :ok
    end)

    :ok
  end

  defp pop_task_monitor(state, pid) do
    {monitor, task_monitors} =
      state
      |> Map.get(:task_monitors, %{})
      |> Map.pop(pid)

    {monitor, Map.put(state, :task_monitors, task_monitors)}
  end

  defp safe_run_response(_parent, {:owner_retarget_error, reason}, _state, _task_pid) do
    Adapter.retarget_error_payload(reason)
  end

  defp safe_run_response(parent, %PreparedWebsocketFrame{} = prepared, state, task_pid) do
    opts = response_task_opts(state, task_pid)

    opts =
      RequestOptions.put_runtime_context(opts,
        direct_cleanup: Map.get(Map.get(state, :direct_cleanup_contexts, %{}), task_pid)
      )

    prepared = put_prepared_runtime_options(prepared, opts)

    prepared = %{
      prepared
      | request_options:
          RequestOptions.put_runtime_context(prepared.request_options,
            direct_cleanup: opts.runtime.direct_cleanup
          )
    }

    try do
      case run_prepared_response(parent, task_pid, state.auth, prepared) do
        {:socket_response_result, completion_source, {:error, _reason} = result} ->
          {:socket_response_result, completion_source,
           {:response_task_result, result, response_task_visible_output?()}}

        result ->
          result
      end
    rescue
      exception ->
        log_response_task_failure(
          :error,
          exception,
          __STACKTRACE__,
          Jason.encode!(prepared.payload),
          state,
          opts
        )

        {:response_task_failure, response_task_failure()}
    catch
      kind, reason ->
        if owner_drained_response_task_exit?(kind, reason, state) do
          Adapter.retarget_error_payload(:owner_drained)
        else
          log_response_task_failure(
            kind,
            reason,
            __STACKTRACE__,
            Jason.encode!(prepared.payload),
            state,
            opts
          )

          {:response_task_failure, response_task_failure()}
        end
    end
  end

  defp put_prepared_runtime_options(
         %PreparedWebsocketFrame{} = prepared,
         %RequestOptions{} = opts
       ) do
    if is_nil(prepared.request_options.runtime.replay_authorization_binding) do
      prepared_options = prepared.request_options
      owner = opts.transport.websocket_owner

      opts =
        prepared_options
        |> RequestOptions.put_continuity(
          codex_session: opts.continuity.codex_session,
          semantic_turn_key: prepared.semantic_turn_key,
          turn_claim_key: prepared.turn_claim_key,
          previous_response_id: prepared_options.continuity.previous_response_id,
          accepted_turn_state: prepared_options.continuity.accepted_turn_state
        )
        |> RequestOptions.put_transport(
          websocket_owner_forwarding_enabled?: owner.enabled?,
          websocket_owner_session: owner.session,
          websocket_owner_lease_token: owner.lease_token,
          websocket_owner_downstream: owner.downstream,
          websocket_owner_downstream_epoch: owner.downstream_epoch,
          websocket_owner_proxy_instance_id: owner.proxy_instance_id,
          websocket_owner_instance_id: owner.owner_instance_id,
          websocket_owner_forwarder_opts: owner.forwarder_opts
        )

      case WebsocketCodec.reseal_runtime_frame(prepared, opts) do
        {:ok, resealed} -> resealed
        {:error, _reason} -> prepared
      end
    else
      owner = opts.transport.websocket_owner

      request_options =
        prepared.request_options
        |> RequestOptions.put_continuity(codex_session: opts.continuity.codex_session)
        |> RequestOptions.put_transport(
          websocket_owner_forwarding_enabled?: owner.enabled?,
          websocket_owner_session: owner.session,
          websocket_owner_lease_token: owner.lease_token,
          websocket_owner_downstream: owner.downstream,
          websocket_owner_downstream_epoch: owner.downstream_epoch,
          websocket_owner_proxy_instance_id: owner.proxy_instance_id,
          websocket_owner_instance_id: owner.owner_instance_id,
          websocket_owner_forwarder_opts: owner.forwarder_opts
        )

      %{prepared | request_options: request_options}
    end
  end

  defp response_task_activity_kind({:owner_retarget_error, _reason}, _state),
    do: :local_owner

  defp response_task_activity_kind(_payload, state) do
    cond do
      not owner_forwarded_socket?(state) -> :direct
      local_owner_socket?(state) -> :local_owner
      true -> :proxy
    end
  end

  defp local_owner_socket?(%{codex_session: %{owner_instance_id: owner_instance_id}})
       when is_binary(owner_instance_id),
       do: owner_instance_id == Atom.to_string(node())

  defp local_owner_socket?(_state), do: false

  defp cancel_response_task_activity(state, task_pid, :owner_drained) do
    if owner_forwarded_socket?(state) do
      :ok = Adapter.cancel_owner_turn(state, task_pid, :owner_drained)
      :await_worker
    else
      cancel_direct_response_task(state, task_pid)

      :ok = Websocket.close_websocket_session(Map.get(state, :upstream_websocket_session))
      :kill_worker
    end
  end

  defp cancel_direct_response_task(state, task_pid) do
    case Map.get(Map.get(state, :direct_cleanup_contexts, %{}), task_pid) do
      %DirectCleanup{} = context ->
        case DirectCleanup.cancel(context, "owner_drained") do
          :none -> :ok
          result -> log_interrupt_failure(result, state)
        end

      nil ->
        opts =
          state
          |> response_task_opts(task_pid)
          |> RequestOptions.put_runtime_context(interrupt_reason: "owner_drained")

        Websocket.interrupt_codex_turn(Map.get(state, :codex_session), opts)
    end
  end

  defp owner_drained_response_task_exit?(:exit, :normal, state),
    do: owner_forwarded_socket?(state)

  defp owner_drained_response_task_exit?(:exit, {:normal, _details}, state),
    do: owner_forwarded_socket?(state)

  defp owner_drained_response_task_exit?(_kind, _reason, _state), do: false

  defp response_task_opts(state, task_pid) when is_pid(task_pid) do
    Adapter.response_options(
      state,
      MapSet.size(Map.get(state, :tasks, MapSet.new())) == 0,
      task_pid
    )
  end

  defp cleanup_websocket_session(reason, %{websocket_owner_downstream: downstream} = state)
       when is_map(downstream) do
    Adapter.cleanup_owner_session(state, reason)
  end

  defp cleanup_websocket_session(_reason, state) do
    contexts = Map.get(state, :direct_cleanup_contexts, %{})

    if map_size(contexts) == 0 do
      state
      |> Map.get(:codex_session)
      |> Websocket.interrupt_codex_session(state.opts)
      |> log_interrupt_failure(state)
    else
      Enum.each(contexts, fn {pid, context} ->
        result = cleanup_direct_response(state, pid, context)
        log_interrupt_failure(result, state)
      end)
    end
  end

  defp cleanup_direct_response(state, pid, context) do
    case DirectCleanup.cancel(context, "client_disconnected") do
      :none ->
        case Map.get(Map.get(state, :direct_cleanup_receipts, %{}), pid) do
          nil -> :ok
          receipt -> DirectCleanup.interrupt(receipt, "client_disconnected")
        end

      result ->
        result
    end
  end

  defp put_direct_context(state, pid, ref, parent) do
    if not owner_forwarded_socket?(state) and
         match?(%{id: id} when is_binary(id), Map.get(state, :codex_session)) do
      context = %DirectCleanup{
        registry: response_task_activity_registry(state),
        task: pid,
        ref: ref,
        parent: parent,
        session_id: state.codex_session.id,
        before_ready:
          Keyword.get(
            Map.get(state, :response_task_start_options, []),
            :before_direct_cleanup_ready
          )
      }

      Map.update(state, :direct_cleanup_contexts, %{pid => context}, &Map.put(&1, pid, context))
    else
      state
    end
  end

  defp accept_direct_cleanup(state, pid, ref, receipt) do
    case Map.get(Map.get(state, :direct_cleanup_contexts, %{}), pid) do
      %DirectCleanup{ref: ^ref, session_id: session_id} when session_id == receipt.session_id ->
        if tracked_response_task?(state, pid),
          do:
            Map.update(
              state,
              :direct_cleanup_receipts,
              %{pid => receipt},
              &Map.put(&1, pid, receipt)
            ),
          else: state

      _ ->
        state
    end
  end

  defp run_prepared_response(parent, task_pid, auth, prepared) do
    Websocket.run_prepared_websocket_response_for_socket(auth, prepared, fn data ->
      unless StreamProtocol.internal_control_event?(data) do
        Process.put(:response_task_visible_output?, true)
      end

      send(parent, {:codex_response_chunk, task_pid, data})
    end)
  end

  defp response_task_visible_output? do
    Process.get(:response_task_visible_output?, false)
  end

  defp log_failed_native_websocket_turn(state, pid, reason, visible_output?) do
    visible_output? = direct_turn_visible_output?(state, pid, visible_output?)

    state
    |> failed_native_websocket_turn_metadata(pid, reason, visible_output?)
    |> WebsocketConnectionLogger.log_failed_native_websocket_turn(reason)
  end

  defp maybe_log_failed_native_websocket_turn(state, pid, reason, visible_output?)
       when is_pid(pid) do
    log_failed_native_websocket_turn(state, pid, reason, visible_output?)
  end

  defp maybe_log_failed_native_websocket_turn(_state, _pid, _reason, _visible_output?), do: :ok

  defp failed_native_websocket_turn_metadata(state, pid, reason, visible_output?) do
    opts = response_task_opts(state, pid)

    %{
      request_id: Adapter.request_id(opts),
      endpoint: websocket_turn_endpoint(opts),
      transport: websocket_turn_transport(opts),
      route_class: websocket_turn_route_class(opts),
      error_code: websocket_turn_error_code(reason),
      elapsed_ms: socket_elapsed_ms(Map.get(state, :connection_started_at_monotonic_ms)),
      codex_session_id: session_id(Map.get(state, :codex_session)),
      visible_output: websocket_turn_visible_output(visible_output?)
    }
  end

  defp websocket_turn_endpoint(%{transport: %{upstream_endpoint: endpoint}})
       when is_binary(endpoint),
       do: endpoint

  defp websocket_turn_endpoint(_opts), do: nil

  defp websocket_turn_transport(%{transport: %{transport: transport}}) when is_binary(transport),
    do: transport

  defp websocket_turn_transport(_opts), do: "websocket"

  defp websocket_turn_route_class(%{transport: %{route_class: route_class}})
       when is_binary(route_class),
       do: route_class

  defp websocket_turn_route_class(_opts), do: nil

  defp websocket_turn_error_code(%{code: code}) when is_atom(code), do: Atom.to_string(code)
  defp websocket_turn_error_code(%{code: code}) when is_binary(code), do: code
  defp websocket_turn_error_code(_reason), do: ErrorCodes.websocket_request_failed_code()

  defp direct_turn_visible_output?(state, pid, task_local_visible_output?) do
    if active_public_turn?(state, pid) do
      task_local_visible_output?
    else
      state
      |> Map.get(:native_turn_output_task_pids, MapSet.new())
      |> MapSet.member?(pid)
    end
  end

  defp active_owner_turn_visible_output?(state) do
    if Adapter.public_responses_stream?(state) do
      Map.get(state, :public_turn_output_committed?, false)
    else
      case active_native_owner_turn_pid(state) do
        pid when is_pid(pid) ->
          state
          |> Map.get(:native_turn_output_task_pids, MapSet.new())
          |> MapSet.member?(pid)

        nil ->
          false
      end
    end
  end

  defp mark_active_native_owner_turn_output(state) do
    case active_native_owner_turn_pid(state) do
      pid when is_pid(pid) -> mark_native_turn_output_pushed(state, pid)
      nil -> state
    end
  end

  defp maybe_mark_active_native_owner_turn_output(state, data) do
    if StreamProtocol.internal_control_event?(data) do
      state
    else
      mark_active_native_owner_turn_output(state)
    end
  end

  defp reset_owner_turn_output(state) do
    state
    |> Map.put(:native_turn_output_task_pids, MapSet.new())
    |> Map.put(:public_turn_output_committed?, false)
  end

  defp mark_native_turn_output_pushed(state, pid) when is_pid(pid) do
    Map.update(
      state,
      :native_turn_output_task_pids,
      MapSet.new([pid]),
      &MapSet.put(&1, pid)
    )
  end

  defp maybe_mark_native_turn_output_pushed(state, pid, data) when is_pid(pid) do
    if StreamProtocol.internal_control_event?(data) do
      state
    else
      mark_native_turn_output_pushed(state, pid)
    end
  end

  defp remove_native_turn_output(state, pid) when is_pid(pid) do
    case Map.fetch(state, :native_turn_output_task_pids) do
      {:ok, task_pids} ->
        Map.put(state, :native_turn_output_task_pids, MapSet.delete(task_pids, pid))

      :error ->
        state
    end
  end

  defp websocket_turn_visible_output(true), do: :after_visible_output
  defp websocket_turn_visible_output(false), do: :before_visible_output

  defp socket_elapsed_ms(started_at) when is_integer(started_at) do
    max(System.monotonic_time(:millisecond) - started_at, 0)
  end

  defp socket_elapsed_ms(_started_at), do: nil

  defp response_task_failure do
    {:error,
     %{
       status: 500,
       code: :websocket_response_task_failed,
       message: "websocket response task failed",
       param: nil
     }}
  end

  defp log_response_task_failure(kind, reason, stacktrace, payload, state, opts) do
    metadata =
      [
        failure_kind: failure_kind(kind),
        failure_reason: failure_reason(kind, reason),
        stacktrace_top: stacktrace_top(stacktrace),
        request_id: Adapter.request_id(opts),
        codex_session_id: session_id(Map.get(state, :codex_session)),
        active_task_count: MapSet.size(Map.get(state, :tasks, MapSet.new()))
      ] ++
        WebsocketResponseTaskFailureDiagnostics.metadata(reason, stacktrace) ++
        safe_payload_metadata(payload)

    Logger.error(
      "websocket response task failed #{format_log_metadata(metadata)}",
      metadata
    )

    :ok
  end

  defp format_log_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{format_log_value(value)}" end)
  end

  defp format_log_value(value) when is_binary(value), do: value
  defp format_log_value(value), do: inspect(value)

  defp failure_kind(:error), do: "exception"
  defp failure_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp failure_kind(_kind), do: "unknown"

  defp failure_reason(:error, %{__struct__: module}) when is_atom(module), do: inspect(module)
  defp failure_reason(_kind, reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(_kind, {reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(_kind, _reason), do: "non_atom_reason"

  defp stacktrace_top([{module, function, arity_or_args, location} | _stacktrace]) do
    [
      inspect(module),
      ".",
      to_string(function),
      "/",
      to_string(stacktrace_arity(arity_or_args)),
      ":",
      to_string(location[:file]),
      ":",
      to_string(location[:line])
    ]
    |> IO.iodata_to_binary()
  end

  defp stacktrace_top(_stacktrace), do: nil

  defp stacktrace_arity(arity) when is_integer(arity), do: arity
  defp stacktrace_arity(args) when is_list(args), do: length(args)

  defp session_id(%{id: id}) when is_binary(id), do: id
  defp session_id(_session), do: nil

  defp safe_payload_metadata(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = decoded} ->
        [
          payload_type: safe_payload_field(decoded, "type"),
          payload_model: safe_payload_field(decoded, "model"),
          payload_stream: Map.get(decoded, "stream"),
          payload_generate: Map.get(decoded, "generate"),
          payload_has_previous_response_id: is_binary(Map.get(decoded, "previous_response_id")),
          payload_input_count: payload_input_count(Map.get(decoded, "input"))
        ]

      _not_json ->
        [payload_type: "invalid_json"]
    end
  end

  defp safe_payload_field(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) -> String.slice(value, 0, 120)
      _value -> nil
    end
  end

  defp payload_input_count(input) when is_list(input), do: length(input)
  defp payload_input_count(nil), do: nil
  defp payload_input_count(_input), do: 1

  defp await_response_tasks(tasks, timeout_ms) do
    if MapSet.size(tasks) == 0 do
      tasks
    else
      monitors = Map.new(tasks, &{&1, Process.monitor(&1)})
      deadline = response_task_deadline(timeout_ms)

      do_await_response_tasks(tasks, monitors, deadline)
    end
  end

  defp response_task_deadline(timeout_ms) when is_integer(timeout_ms) do
    System.monotonic_time(:millisecond) + timeout_ms
  end

  defp do_await_response_tasks(tasks, monitors, deadline) do
    if MapSet.size(tasks) == 0 do
      tasks
    else
      timeout = response_task_wait_timeout(deadline)

      receive do
        {:codex_response_done, _pid, _result} ->
          do_await_response_tasks(tasks, monitors, deadline)

        {:DOWN, ref, :process, pid, _reason}
        when is_map_key(monitors, pid) and :erlang.map_get(pid, monitors) == ref ->
          do_await_response_tasks(remove_response_task(tasks, monitors, pid), monitors, deadline)
      after
        timeout ->
          demonitor_response_tasks(monitors)
          tasks
      end
    end
  end

  defp response_task_wait_timeout(deadline) when is_integer(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp remove_response_task(tasks, monitors, pid) do
    if ref = Map.get(monitors, pid) do
      Process.demonitor(ref, [:flush])
      MapSet.delete(tasks, pid)
    else
      tasks
    end
  end

  defp demonitor_response_tasks(monitors) do
    Enum.each(monitors, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)
  end

  defp await_response_task_registry_cleanup(state, owned_tasks, remaining_tasks) do
    if MapSet.size(remaining_tasks) == 0 do
      registry = response_task_activity_registry(state)
      deadline = response_task_deadline(@post_cleanup_response_task_drain_ms)
      do_await_response_task_registry_cleanup(owned_tasks, registry, deadline)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp do_await_response_task_registry_cleanup(owned_tasks, registry, deadline) do
    active =
      Enum.flat_map(owned_tasks, fn pid ->
        case ActivityRegistry.delivery_target(pid, name: registry) do
          {:ok, token, _ack_pid, _status} -> [token]
          :unknown -> []
        end
      end)

    cond do
      active == [] ->
        :ok

      response_task_wait_timeout(deadline) > 0 ->
        receive do
        after
          1 -> do_await_response_task_registry_cleanup(owned_tasks, registry, deadline)
        end

      true ->
        Enum.each(active, &ActivityRegistry.unregister(&1, :aborted, name: registry))
    end
  end

  defp close_upstream_websocket_session(state) do
    state
    |> Map.get(:upstream_websocket_session)
    |> Websocket.close_websocket_session()
  end
end
