defmodule CodexPoolerWeb.CodexResponsesSocket do
  @moduledoc false

  @behaviour WebSock

  alias CodexPooler.Access
  alias CodexPooler.Events
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.Websocket.{ActivityRegistry, WebsocketOwnerContract}
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Gateway.Websocket.Adapter
  alias CodexPooler.Gateway.Websocket.ResponseTask
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Cache, as: InstanceSettingsCache
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Firewall
  alias CodexPoolerWeb.WebsocketConnectionLogger
  alias CodexPoolerWeb.WebsocketResponseTaskFailureDiagnostics

  require Logger

  @pre_cleanup_response_task_drain_ms 250
  @post_cleanup_owner_response_task_drain_ms 1_000
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
    {:ok, start_or_queue_response_task(payload, state)}
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
    cond do
      active_public_turn?(state, task_pid) and not public_turn_aborted?(state) ->
        public_chunk_result(data, state)

      tracked_response_task?(state, task_pid) and
          not Adapter.public_responses_stream?(state) ->
        state = maybe_mark_native_turn_output_pushed(state, task_pid, data)
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
    {:ok, put_response_task_activity(state, pid, token)}
  end

  def handle_info({:codex_response_done, pid, result}, state) when is_pid(pid) do
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
    state = maybe_abort_public_owner_turn(state, :owner_monitor_down)

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
    state = clear_public_response_context(state)
    log_closed_before_request_reservation(reason, state)

    remaining_tasks =
      state
      |> Map.get(:tasks, MapSet.new())
      |> await_response_tasks(@pre_cleanup_response_task_drain_ms)

    cleanup_websocket_session(reason, state)

    close_upstream_websocket_session(state)

    acknowledge_response_task_cleanup(state)

    unless owner_forwarded_socket?(state) do
      remaining_tasks
      |> Enum.reject(&authoritative_response_task_activity?(state, &1))
      |> cancel_response_tasks(:websocket_terminated)
    end

    _remaining_tasks = remaining_response_tasks_after_cleanup(state, remaining_tasks)

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
    |> Map.put(:native_owner_terminal_delivered?, false)
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
    case Adapter.accept_downstream_message(message, state) do
      {:ok, payload} -> handle_accepted_owner_payload(payload, state)
      :drop -> {:ok, state}
      {:error, _reason} -> {:ok, state}
    end
  end

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
    state = maybe_mark_active_native_owner_turn_output(state, data)
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
      |> schedule_active_response_task_delivery()

    {:ok, state}
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
    ResponseTask.start(
      parent,
      response_task_activity_kind(payload, state),
      fn task_pid -> safe_run_response(parent, payload, state, task_pid) end,
      fn task_pid, reason -> cancel_response_task_activity(state, task_pid, reason) end
    )
  end

  defp start_or_queue_response_task(_payload, %{firewall_revoked?: true} = state), do: state

  defp start_or_queue_response_task(payload, state) do
    cond do
      response_payload_requires_queue?(payload, state) ->
        queue_response_payload(state, payload)

      suppress_owner_reconnect_replay?(payload, state) ->
        state

      true ->
        start_tracked_response_task(payload, state)
    end
  end

  defp response_payload_requires_queue?(payload, state) do
    public_response_start_error_pending?(state) or
      (public_response_payload?(payload, state) and public_turn_open?(state)) or
      (owner_forwarded_socket?(state) and active_response_task?(state)) or
      (active_response_task?(state) and Adapter.continuity_ordered_payload?(payload))
  end

  defp maybe_start_queued_response_task(state) do
    if Map.get(state, :firewall_revoked?, false) or active_response_task?(state) or
         public_turn_open?(state) or public_response_start_error_pending?(state) do
      state
    else
      case Map.get(state, :queued_response_payloads, :queue.new()) |> :queue.out() do
        {{:value, payload}, queue} ->
          state = Map.put(state, :queued_response_payloads, queue)
          start_tracked_response_task(payload, state)

        {:empty, _queue} ->
          state
      end
    end
  end

  defp start_tracked_response_task(payload, state) do
    case prepare_public_response_payload(payload, state) do
      {:ok, payload, state} ->
        case Adapter.maybe_retarget_before_start(payload, state) do
          {:ok, state} ->
            state =
              state
              |> maybe_mark_request_response_work_started(payload)
              |> reset_native_owner_terminal_delivery()

            parent = self()
            {:ok, pid} = start_response_task(parent, payload, state)
            monitor = Process.monitor(pid)

            state
            |> track_response_task(pid, monitor)
            |> maybe_open_public_turn(payload, pid)

          {:error, reason} ->
            start_owner_retarget_error_task(reason, payload, state)
        end

      {:error, reason, state} ->
        schedule_public_response_start_error(reason, state)
    end
  end

  defp queue_response_payload(state, payload) do
    Map.update(
      state,
      :queued_response_payloads,
      :queue.from_list([payload]),
      &:queue.in(payload, &1)
    )
  end

  defp start_owner_retarget_error_task(reason, payload, state) do
    parent = self()
    {:ok, pid} = start_response_task(parent, {:owner_retarget_error, reason}, state)
    monitor = Process.monitor(pid)

    state
    |> track_response_task(pid, monitor)
    |> maybe_open_public_turn(payload, pid)
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
    if Adapter.request_row_producing_response_payload?(payload) do
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
    if owner_forwarded_socket?(state) and not Adapter.public_responses_stream?(state) do
      case Map.get(state, :tasks, MapSet.new()) |> MapSet.to_list() do
        [pid] when is_pid(pid) -> pid
        _tasks -> nil
      end
    end
  end

  defp public_response_payload?(payload, state) do
    Adapter.public_responses_stream?(state) and
      Adapter.request_row_producing_response_payload?(payload)
  end

  defp public_turn_open?(state), do: is_pid(Map.get(state, :public_response_task_pid))

  defp public_response_start_error_pending?(state) do
    is_reference(Map.get(state, :public_response_start_error_ref))
  end

  defp suppress_owner_reconnect_replay?(payload, state) do
    owner_forwarded_socket?(state) and
      Map.get(state, :websocket_owner_active_turn_reconnect?) == true and
      Adapter.request_row_producing_response_payload?(payload)
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

  defp maybe_schedule_response_delivery({:stop, detail, state}, pid) do
    {:stop, detail, complete_response_task_delivery_for_pid(state, pid)}
  end

  defp maybe_schedule_response_delivery(result, pid) do
    map_socket_result_state(result, fn state ->
      if response_delivery_safe?(result, state, pid) do
        schedule_response_task_delivery(state, pid)
      else
        state
      end
    end)
  end

  defp response_delivery_safe?(_result, state, pid) do
    cond do
      not owner_forwarded_socket?(state) -> true
      Adapter.public_responses_stream?(state) -> Map.get(state, :public_response_task_pid) != pid
      true -> Map.get(state, :native_owner_terminal_delivered?, false)
    end
  end

  defp map_socket_result_state({:ok, state}, fun), do: {:ok, fun.(state)}
  defp map_socket_result_state({:push, frame, state}, fun), do: {:push, frame, fun.(state)}

  defp schedule_active_response_task_delivery(state) do
    state
    |> Map.get(:response_task_activities, %{})
    |> Map.keys()
    |> Enum.find(&tracked_response_task?(state, &1))
    |> then(&schedule_response_task_delivery(state, &1))
  end

  defp schedule_response_task_delivery(state, pid) when is_pid(pid) do
    activities = Map.get(state, :response_task_activities, %{})
    scheduled = Map.get(state, :response_task_delivery_scheduled, MapSet.new())

    case Map.get(activities, pid) do
      token when is_reference(token) ->
        if MapSet.member?(scheduled, token) do
          state
        else
          send(self(), {:websocket_response_delivery_complete, pid, token})
          Map.put(state, :response_task_delivery_scheduled, MapSet.put(scheduled, token))
        end

      _unknown ->
        state
    end
  end

  defp schedule_response_task_delivery(state, _pid), do: state

  defp complete_response_task_delivery(state, pid, token) do
    case Map.get(Map.get(state, :response_task_activities, %{}), pid) do
      ^token ->
        ack_pid = Map.get(Map.get(state, :response_task_delivery_recipients, %{}), pid, pid)
        :ok = ResponseTask.acknowledge_delivery(ack_pid, token)

        state
        |> Map.update(:response_task_activities, %{}, &Map.delete(&1, pid))
        |> Map.update(
          :response_task_delivery_scheduled,
          MapSet.new(),
          &MapSet.delete(&1, token)
        )
        |> Map.update(:response_task_delivery_recipients, %{}, &Map.delete(&1, pid))
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
        {:ok, token, ack_pid} -> ResponseTask.acknowledge_delivery(ack_pid, token)
        :unknown -> :ok
      end
    end)

    :ok
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
        {:ok, payload} = WebsocketOwnerContract.safe_error_payload(:owner_drained, nil)

        state =
          Map.update(
            state,
            :response_task_delivery_recipients,
            %{pid => ack_pid},
            &Map.put(&1, pid, ack_pid)
          )

        if Adapter.public_responses_stream?(state) do
          state =
            state
            |> Map.put(:websocket_owner_drain_observed?, true)
            |> abort_public_turn(:owner_drained)
            |> schedule_response_task_delivery(pid)

          {:push, {:text, encode_public_error(payload, state)}, state}
        else
          state =
            state
            |> Map.put(:websocket_owner_drain_observed?, true)
            |> reset_owner_turn_output()
            |> schedule_response_task_delivery(pid)

          {:push, {:text, Jason.encode!(Adapter.websocket_error(payload))}, state}
        end

      _stale ->
        {:ok, state}
    end
  end

  defp reset_native_owner_terminal_delivery(state) do
    if owner_forwarded_socket?(state) and not Adapter.public_responses_stream?(state) do
      Map.put(state, :native_owner_terminal_delivered?, false)
    else
      state
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

  defp schedule_public_response_start_error(reason, state) do
    ref = make_ref()
    send(self(), {:public_response_start_error, ref, reason})
    Map.put(state, :public_response_start_error_ref, ref)
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
    {monitor, state} = pop_task_monitor(state, pid)

    if monitor do
      Process.demonitor(monitor, [:flush])
    end

    state
    |> Map.update(:tasks, MapSet.new(), &MapSet.delete(&1, pid))
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

  defp safe_run_response(parent, payload, state, task_pid) do
    opts = response_task_opts(state, task_pid)

    try do
      case run_response(parent, task_pid, state.auth, payload, opts) do
        {:error, _reason} = result ->
          {:response_task_result, result, response_task_visible_output?()}

        result ->
          result
      end
    rescue
      exception ->
        log_response_task_failure(:error, exception, __STACKTRACE__, payload, state, opts)
        {:response_task_failure, response_task_failure()}
    catch
      kind, reason ->
        if owner_drained_response_task_exit?(kind, reason, state) do
          Adapter.retarget_error_payload(:owner_drained)
        else
          log_response_task_failure(kind, reason, __STACKTRACE__, payload, state, opts)
          {:response_task_failure, response_task_failure()}
        end
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
      opts =
        state
        |> response_task_opts(task_pid)
        |> CodexPooler.Gateway.Payloads.RequestOptions.put_runtime_context(
          interrupt_reason: "owner_drained"
        )

      _result = Websocket.interrupt_codex_turn(Map.get(state, :codex_session), opts)
      :ok = Websocket.close_websocket_session(Map.get(state, :upstream_websocket_session))
      :kill_worker
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
    state
    |> Map.get(:codex_session)
    |> Websocket.interrupt_codex_session(state.opts)
    |> log_interrupt_failure(state)
  end

  defp run_response(parent, task_pid, auth, payload, opts) do
    run_websocket_response(auth, payload, opts, fn data ->
      unless StreamProtocol.internal_control_event?(data) do
        Process.put(:response_task_visible_output?, true)
      end

      send(parent, {:codex_response_chunk, task_pid, data})
    end)
  end

  defp run_websocket_response(
         auth,
         payload,
         %{openai_compatibility: %{public_openai_responses_stream: true}} = opts,
         push_frame
       ) do
    Websocket.run_websocket_response_for_socket(auth, payload, opts, push_frame)
  end

  defp run_websocket_response(auth, payload, opts, push_frame) do
    Websocket.run_websocket_response(auth, payload, opts, push_frame)
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
        {:codex_response_done, pid, _result} ->
          do_await_response_tasks(remove_response_task(tasks, monitors, pid), monitors, deadline)

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

  defp close_upstream_websocket_session(state) do
    state
    |> Map.get(:upstream_websocket_session)
    |> Websocket.close_websocket_session()
  end
end
