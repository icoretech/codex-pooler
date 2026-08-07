defmodule CodexPoolerWeb.CodexResponsesSocket do
  @moduledoc false

  @behaviour WebSock

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Gateway.Websocket.Adapter
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Cache, as: InstanceSettingsCache
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Firewall
  alias CodexPoolerWeb.WebsocketConnectionLogger

  require Logger

  @pre_cleanup_response_task_drain_ms 250
  @post_cleanup_owner_response_task_drain_ms 1_000
  @post_cleanup_response_task_drain_ms 5_000
  @firewall_close_detail {1008, "client IP is no longer allowed"}

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
        |> initialize_firewall_state()

      {:ok, %{codex_session: session, upstream_websocket_session: upstream_websocket_session}} ->
        state
        |> put_socket_lifecycle_state()
        |> put_response_task_state()
        |> Map.put(:codex_session, session)
        |> Map.put(:upstream_websocket_session, upstream_websocket_session)
        |> initialize_firewall_state()

      {:error, reason} ->
        init_error(reason, state, started_at)
    end
  end

  @impl WebSock
  def handle_in({_payload, [opcode: opcode]}, %{firewall_revoked?: true} = state)
      when opcode in [:text, :binary] do
    {:ok, state}
  end

  def handle_in({payload, [opcode: :text]}, state) when is_binary(payload) do
    {:ok, start_or_queue_response_task(payload, state)}
  end

  def handle_in({_payload, [opcode: :binary]}, state) do
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
        state = mark_native_turn_output_pushed(state, task_pid)
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

  def handle_info({:codex_response_done, pid, result}, state) when is_pid(pid) do
    result =
      cond do
        active_public_turn?(state, pid) ->
          handle_public_response_done(pid, result, state)

        Adapter.public_responses_stream?(state) and not tracked_response_task?(state, pid) ->
          {:ok, state}

        true ->
          handle_non_public_response_done(pid, result, state)
      end

    close_if_revoked_idle(result)
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

  @impl WebSock
  def terminate(reason, state) do
    log_closed_before_request_reservation(reason, state)

    remaining_tasks =
      state
      |> Map.get(:tasks, MapSet.new())
      |> await_response_tasks(@pre_cleanup_response_task_drain_ms)

    unless owner_forwarded_socket?(state) do
      cancel_response_tasks(remaining_tasks, :websocket_terminated)
    end

    cleanup_websocket_session(reason, state)

    close_upstream_websocket_session(state)

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
    |> Map.put(:public_responses_websocket_state, nil)
    |> Map.put(:public_turn_task_done?, false)
    |> Map.put(:public_turn_owner_complete?, false)
    |> Map.put(:public_turn_aborted?, false)
    |> Map.put(:public_turn_output_committed?, false)
    |> Map.put(:native_turn_output_task_pids, MapSet.new())
  end

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

  defp handle_firewall_applied(applied_version, state) do
    if applied_version <= Map.get(state, :firewall_applied_version, 0) do
      {:ok, state}
    else
      settings = InstanceSettings.current()

      cond do
        settings.source == :fallback_defaults ->
          settings
          |> evaluate_firewall(state)
          |> close_if_revoked_idle()

        settings.lock_version >= applied_version ->
          settings
          |> evaluate_firewall(state)
          |> close_if_revoked_idle()

        true ->
          {:ok, state}
      end
    end
  end

  defp evaluate_firewall(settings, state) do
    operational_settings = OperationalSettings.from_instance_settings(settings)
    client_ip = firewall_client_ip(state)

    case Firewall.evaluate_client_ip(client_ip, operational_settings) do
      %{outcome: :allow} ->
        {:ok, Map.put(state, :firewall_applied_version, settings.lock_version)}

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
    |> Map.put(:firewall_applied_version, applied_version)
    |> Map.put(:firewall_revoked?, true)
    |> Map.put(:queued_response_payloads, :queue.new())
  end

  defp close_if_revoked_idle({:ok, state}) do
    if close_revoked_socket?(state) do
      {:stop, :normal, @firewall_close_detail, mark_firewall_closed(state)}
    else
      {:ok, state}
    end
  end

  defp close_if_revoked_idle({:push, messages, state}) do
    if close_revoked_socket?(state) do
      {:stop, :normal, @firewall_close_detail, List.wrap(messages), mark_firewall_closed(state)}
    else
      {:push, messages, state}
    end
  end

  defp close_if_revoked_idle({:stop, reason, close_detail, state}) do
    if close_revoked_socket?(state) do
      {:stop, :normal, @firewall_close_detail, mark_firewall_closed(state)}
    else
      {:stop, reason, close_detail, state}
    end
  end

  defp close_revoked_socket?(state) do
    Map.get(state, :firewall_revoked?, false) and
      not Map.get(state, :firewall_close_sent?, false) and
      not revocation_drain_active?(state)
  end

  defp revocation_drain_active?(state) do
    active_response_task?(state) or public_turn_open?(state)
  end

  defp mark_firewall_closed(state), do: Map.put(state, :firewall_close_sent?, true)

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

    state =
      state
      |> Map.put(:websocket_owner_drain_observed?, true)
      |> abort_public_turn(:owner_drained)

    {:push, {:text, Jason.encode!(Adapter.websocket_error(payload))}, state}
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
      {:push, {:text, Jason.encode!(Adapter.websocket_error(payload))}, state}
    end
  end

  defp handle_public_owner_payload({:error, _reason, payload}, state) do
    {:push, {:text, Jason.encode!(Adapter.websocket_error(payload))}, state}
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
    state = mark_active_native_owner_turn_output(state)
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

    {:push, {:text, Jason.encode!(Adapter.websocket_error(payload))}, state}
  end

  defp handle_non_public_owner_payload({:error, _reason, payload}, state) do
    {:push, {:text, Jason.encode!(Adapter.websocket_error(payload))}, state}
  end

  defp handle_non_public_owner_payload(:complete, state) do
    state =
      state
      |> Map.put(:websocket_owner_active_turn_reconnect?, false)
      |> reset_owner_turn_output()

    {:ok, state}
  end

  defp public_chunk_result(data, state) do
    turn_state =
      Map.get(state, :public_responses_websocket_state) ||
        Adapter.public_responses_turn_state()

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

        {:push, {:text, Jason.encode!(Adapter.websocket_error(reason))}, state}
    end
  end

  defp put_public_turn_state(state, turn_state) do
    Map.put(state, :public_responses_websocket_state, turn_state)
  end

  defp handle_public_response_done(pid, result, state) do
    state = remove_tracked_response_task(state, pid)

    cond do
      public_turn_aborted?(state) ->
        {:ok, state}

      owner_forwarded_socket?(state) ->
        handle_public_owner_response_done(result, state)

      match?({:response_task_failure, {:error, _reason}}, result) ->
        {:response_task_failure, {:error, reason}} = result
        state = finish_public_turn(state)
        {:push, {:text, Jason.encode!(Adapter.websocket_error(reason))}, state}

      match?({:response_task_result, {:error, _reason}, _visible_output?}, result) ->
        {:response_task_result, {:error, reason}, visible_output?} = result
        log_failed_native_websocket_turn(state, pid, reason, visible_output?)
        state = finish_public_turn(state)
        {:push, {:text, Jason.encode!(Adapter.websocket_error(reason))}, state}

      match?({:error, _reason}, result) ->
        {:error, reason} = result
        log_failed_native_websocket_turn(state, pid, reason, false)
        state = finish_public_turn(state)
        {:push, {:text, Jason.encode!(Adapter.websocket_error(reason))}, state}

      true ->
        {:ok, finish_public_turn(state)}
    end
  end

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
    state
    |> Map.put(:public_response_task_pid, nil)
    |> Map.put(:public_responses_websocket_state, nil)
    |> Map.put(:public_turn_task_done?, false)
    |> Map.put(:public_turn_owner_complete?, false)
    |> Map.put(:public_turn_aborted?, false)
    |> Map.put(:public_turn_output_committed?, false)
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
    log_init_failed_before_request_reservation(reason, state, started_at)

    if Adapter.owner_error?(reason) do
      {:stop, :normal, Adapter.close_detail(reason), state}
    else
      {:stop, reason, state}
    end
  end

  defp log_init_failed_before_request_reservation(reason, state, started_at) do
    state
    |> Adapter.init_failure_metadata(started_at)
    |> WebsocketConnectionLogger.log_init_failed_before_request_reservation(reason)
  end

  defp start_response_task(parent, payload, state) do
    Task.start(fn ->
      Process.flag(:sensitive, true)
      send(parent, {:codex_response_done, self(), safe_run_response(parent, payload, state)})
    end)
  end

  defp start_or_queue_response_task(_payload, %{firewall_revoked?: true} = state), do: state

  defp start_or_queue_response_task(payload, state) do
    cond do
      public_response_payload?(payload, state) and public_turn_open?(state) ->
        queue_response_payload(state, payload)

      owner_forwarded_socket?(state) and active_response_task?(state) ->
        queue_response_payload(state, payload)

      active_response_task?(state) and Adapter.continuity_ordered_payload?(payload) ->
        queue_response_payload(state, payload)

      suppress_owner_reconnect_replay?(payload, state) ->
        state

      true ->
        start_tracked_response_task(payload, state)
    end
  end

  defp maybe_start_queued_response_task(state) do
    if Map.get(state, :firewall_revoked?, false) or active_response_task?(state) or
         public_turn_open?(state) do
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
    case Adapter.maybe_retarget_before_start(payload, state) do
      {:ok, state} ->
        state = maybe_mark_request_response_work_started(state, payload)

        parent = self()
        {:ok, pid} = start_response_task(parent, payload, state)
        monitor = Process.monitor(pid)

        state
        |> track_response_task(pid, monitor)
        |> maybe_open_public_turn(payload, pid)

      {:error, reason} ->
        start_owner_retarget_error_task(reason, state)
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

  defp start_owner_retarget_error_task(reason, state) do
    parent = self()
    {:ok, pid} = start_response_task(parent, {:owner_retarget_error, reason}, state)
    monitor = Process.monitor(pid)

    track_response_task(state, pid, monitor)
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

  defp maybe_open_public_turn(state, payload, pid) do
    if public_response_payload?(payload, state) do
      state
      |> Map.put(:public_response_task_pid, pid)
      |> Map.put(:public_responses_websocket_state, Adapter.public_responses_turn_state())
      |> Map.put(:public_turn_task_done?, false)
      |> Map.put(:public_turn_owner_complete?, false)
      |> Map.put(:public_turn_aborted?, false)
      |> Map.put(:public_turn_output_committed?, false)
    else
      state
    end
  end

  defp handle_output_commit_probe(message, state) do
    with false <- public_turn_aborted?(state),
         false <- Map.get(state, :public_turn_owner_complete?, false),
         %{epoch: epoch, correlation_id: correlation_id} <-
           Map.get(state, :websocket_owner_downstream),
         owner_turn_id when is_pid(owner_turn_id) <- Map.get(state, :public_response_task_pid),
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
         active_turn_ref, probe_ref, Map.get(state, :public_turn_output_committed?, false)}
      )
    end

    {:ok, state}
  end

  defp maybe_mark_public_turn_output_committed(state, data) do
    if codex_rate_limits_frame?(data) do
      state
    else
      Map.put(state, :public_turn_output_committed?, true)
    end
  end

  defp codex_rate_limits_frame?(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"type" => "codex.rate_limits"}} -> true
      _other -> false
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

  defp safe_run_response(_parent, {:owner_retarget_error, reason}, _state) do
    Adapter.retarget_error_payload(reason)
  end

  defp safe_run_response(parent, payload, state) do
    task_pid = self()
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
    Websocket.run_websocket_response(auth, payload, opts, fn data ->
      Process.put(:response_task_visible_output?, true)

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
      ] ++ safe_payload_metadata(payload)

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
