defmodule CodexPooler.Dev.NativeCompactionTrace do
  @moduledoc """
  Run-scoped native-compaction debugger.

  Safe mode retains a bounded sanitized projection. Full mode is compiled only
  in development/test builds and streams secret-redacted operational terms to
  a private JSONL file while retaining a small safe projection for status.
  """

  use GenServer

  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionTrace, as: TraceEvent
  alias CodexPooler.Dev.NativeCompactionTrace.SensitivityRestorer

  @name __MODULE__
  @handler_id "codex-pooler-native-compaction-run-trace"
  @trace_event [:codex_pooler, :gateway, :native_compaction, :trace]
  @trace_control_event [:codex_pooler, :gateway, :native_compaction, :trace_control]
  @default_limit 512
  @default_full_max_events 2_000_000
  @default_full_max_bytes 512 * 1024 * 1024
  @truncation_reserve_bytes 2_048
  @sensitivity_fail_safe_ms 1_000
  @roles [:socket, :response_task, :owner_session, :upstream_session]
  @full_beam_flags [:call, :procs, :send, :receive, :set_on_spawn, :monotonic_timestamp]
  @safe_beam_flags [:call, :procs, :send, :receive, :set_on_spawn, :monotonic_timestamp]
  @safe_call_patterns [
    {CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission, :ordinary_success, 1},
    {CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission, :arm_compact, 2},
    {CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission, :reserve, 5},
    {CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission, :mark_accounting_started,
     3},
    {CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission, :consume, 3},
    {CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission, :cancel, 4},
    {CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission,
     :record_compact_collected, 1},
    {CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission, :confirm_compact, 4},
    {CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission, :clear_consumed, 1},
    {CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission, :clear, 1}
  ]
  @critical_modules [
    CodexPoolerWeb.CodexResponsesSocket,
    CodexPooler.Gateway.Websocket.ResponseTask,
    CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession,
    CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.DownstreamState,
    CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Persistence,
    CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession,
    CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ConnectionUpgrade,
    CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.EventTaxonomy,
    CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ReceiveState,
    CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ReceiveState.Delivery,
    CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request,
    CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator,
    CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission,
    CodexPooler.Gateway.Payloads.RequestOptions.NativeCompactionAdmission,
    CodexPooler.Gateway.Transports.Streaming.WebsocketCodec,
    CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame,
    CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame.Capability,
    CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof,
    CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerAdmissionControlV1,
    CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest,
    CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV3,
    CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder,
    CodexPooler.Gateway.Transports.Websocket.ForwardedOwnerRequestHandoff,
    CodexPooler.Gateway.Transports.Websocket.ForwardedSendWitnessV1,
    CodexPooler.Gateway.Runtime.Service,
    CodexPooler.Gateway.Runtime.Dispatch.PreDispatch,
    CodexPooler.Gateway.Runtime.Dispatch.WebsocketAttempt,
    CodexPooler.Gateway.Runtime.Dispatch.WebsocketBridge,
    CodexPooler.Gateway.Runtime.Finalization,
    CodexPooler.Gateway.Runtime.Finalization.Websocket,
    CodexPooler.Gateway.Runtime.Streaming.CompactionResultCollector
  ]
  @secret_key ~r/(authorization|api.?key|(^|[_-])token($|[_-])|access.?token|refresh.?token|bearer|cookie|credential|secret|password|private.?key|encryption.?key|auth.?json)/i
  @credential_value ~r/^(bearer\s+|sk-[A-Za-z0-9_-]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)/i

  @type mode :: :safe | :full
  @type start_option ::
          {:limit, pos_integer()}
          | {:pids, [{atom(), pid()}]}
          | {:mode, mode()}
          | {:root, Path.t()}
          | {:include_modules, [module() | String.t()]}
          | {:exclude_modules, [module() | String.t()]}
          | {:max_events, pos_integer()}
          | {:max_bytes, pos_integer()}

  @spec start_scope(term(), [start_option()]) :: {:ok, map()} | {:error, term()}
  def start_scope(run_label, opts \\ []) do
    case stop_scope() do
      :ok -> do_start_scope(run_label, opts)
      {:error, reason} -> {:error, {:previous_scope_restore_failed, reason}}
    end
  end

  defp do_start_scope(run_label, opts) do
    mode = Keyword.get(opts, :mode, :safe)
    limit = opts |> Keyword.get(:limit, configured_limit()) |> normalize_limit()
    generation = make_ref()
    sensitivity_authorization = make_ref()

    result =
      with :ok <- validate_requested_mode(mode),
           {:ok, trace_plan} <- build_trace_plan(mode, opts),
           {:ok, restorer} <-
             maybe_start_sensitivity_restorer(mode, generation, sensitivity_authorization),
           :ok <- TraceEvent.activate_mode(mode),
           {:ok, pid} <-
             GenServer.start(
               __MODULE__,
               {run_label, generation, sensitivity_authorization, restorer, limit, mode,
                trace_plan, opts},
               name: @name
             ),
           :ok <-
             maybe_activate_sensitivity_control(
               mode,
               generation,
               sensitivity_authorization,
               restorer,
               pid
             ),
           :ok <-
             maybe_bind_sensitivity_restorer(
               mode,
               restorer,
               pid,
               generation,
               sensitivity_authorization
             ),
           :ok <- maybe_configure_restorer(mode, trace_plan),
           {:ok, pattern_report} <- attach(generation, trace_plan),
           :ok <- GenServer.call(pid, {:pattern_report, pattern_report}),
           :ok <- enroll_initial_pids(Keyword.get(opts, :pids, [])) do
        {:ok, GenServer.call(pid, :status)}
      end

    case result do
      {:ok, _status} = success ->
        success

      {:error, reason} ->
        cleanup_result = cleanup_failed_start()
        if cleanup_result == :ok, do: {:error, reason}, else: {:error, {reason, cleanup_result}}
    end
  rescue
    exception ->
      _cleanup = cleanup_failed_start()
      {:error, {:trace_start_exception, exception}}
  end

  defp enroll_initial_pids(pids) do
    Enum.reduce_while(pids, :ok, fn {role, pid}, :ok ->
      case track_pid(role, pid) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:pid_enrollment_failed, role, pid, reason}}}
      end
    end)
  end

  @spec validate_requested_mode(atom(), boolean()) :: :ok | {:error, term()}
  def validate_requested_mode(mode, full_allowed? \\ TraceEvent.full_allowed?())
  def validate_requested_mode(:safe, _full_allowed?), do: :ok
  def validate_requested_mode(:full, true), do: :ok
  def validate_requested_mode(:full, false), do: {:error, :full_trace_unavailable}
  def validate_requested_mode(_mode, _full_allowed?), do: {:error, :invalid_trace_mode}

  @spec reset_scope(term(), [start_option()]) :: {:ok, map()} | {:error, term()}
  def reset_scope(run_label, opts \\ []), do: start_scope(run_label, opts)

  @spec flush() :: :ok | {:error, :not_started | :trace_truncated}
  def flush, do: call_if_started(:flush_barrier, {:error, :not_started})

  @spec stop_scope() :: :ok | {:error, term()}
  def stop_scope do
    :telemetry.detach(@handler_id)

    result =
      case Process.whereis(@name) do
        nil -> restore_without_collector()
        pid -> GenServer.call(pid, :stop_scope, 15_000)
      end

    case result do
      :ok ->
        TraceEvent.deactivate_mode()
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @spec track_pid(atom(), pid()) :: :ok | {:error, atom()}
  def track_pid(role, pid) when role in @roles and is_pid(pid),
    do: call_if_started({:track_pid, role, pid}, {:error, :not_started})

  def track_pid(role, _pid) when role not in @roles, do: {:error, :invalid_role}
  def track_pid(_role, _pid), do: {:error, :invalid_pid}

  @spec export() :: map()
  def export, do: call_if_started(:export, empty_export())

  @spec status() :: map()
  def status,
    do: call_if_started(:status, %{"running" => false, "eventCount" => 0, "tracedPids" => 0})

  @doc false
  def handle_event(@trace_event, %{count: 1}, %{event: event, fields: fields}, generation) do
    cast_if_started({:pooler_event, generation, event, fields})
    :ok
  end

  def handle_event(
        @trace_control_event,
        %{count: 1},
        %{action: :enroll, role: role, pid: pid},
        generation
      ) do
    call_enroll_if_started(generation, role, pid)
    :ok
  end

  def handle_event(_event, _measurements, _metadata, _generation), do: :ok

  @impl true
  def init(
        {run_label, generation, sensitivity_authorization, restorer, limit, mode, trace_plan,
         opts}
      ) do
    with {:ok, file} <- open_output(mode, run_label, Keyword.get(opts, :root)) do
      now_system = System.system_time(:microsecond)
      now_mono = System.monotonic_time(:microsecond)

      state = %{
        run_label: to_string(run_label),
        run_fingerprint: TraceEvent.fingerprint(run_label),
        generation: generation,
        sensitivity_authorization: sensitivity_authorization,
        sensitivity_restorer: restorer,
        sensitivity_restorer_monitor: if(restorer, do: Process.monitor(restorer), else: nil),
        sensitivity_restorer_failed: false,
        mode: mode,
        limit: limit,
        sequence: 0,
        events: :queue.new(),
        event_count: 0,
        traced: %{},
        calls: %{},
        file: file,
        file_bytes: 0,
        written_events: 0,
        max_events: normalize_max_events(mode, Keyword.get(opts, :max_events)),
        max_bytes: normalize_max_bytes(mode, Keyword.get(opts, :max_bytes)),
        truncated: false,
        truncation_reason: nil,
        trace_plan: trace_plan,
        pattern_report: [],
        sensitivity_status: %{},
        flush_waiters: %{},
        started_system_us: now_system,
        started_monotonic_us: now_mono
      }

      state = maybe_write_control(state, :trace_started, %{mode: mode, path: file_path(file)})
      {:ok, state}
    end
  end

  @impl true
  def handle_call({:track_pid, role, pid}, _from, state) do
    {result, state} = track_pid_now(state, role, pid, nil)
    {:reply, result, state}
  end

  def handle_call({:track_pid, generation, role, pid}, _from, %{generation: generation} = state)
      when role in @roles and is_pid(pid) do
    {_result, state} = track_pid_now(state, role, pid, nil)
    {:reply, :ok, state}
  end

  def handle_call({:track_pid, _generation, _role, _pid}, _from, state),
    do: {:reply, :ok, state}

  def handle_call(:export, _from, state), do: {:reply, export_state(state), state}
  def handle_call(:status, _from, state), do: {:reply, status_state(state), state}

  def handle_call({:pattern_report, report}, _from, state),
    do: {:reply, :ok, %{state | pattern_report: report}}

  def handle_call(:stop_scope, _from, state) do
    case restore_sensitivity(state) do
      {:ok, sensitivity_status} ->
        state =
          Enum.reduce(sensitivity_status, %{state | sensitivity_status: sensitivity_status}, fn
            {pid, %{state: :dead, reason: :sensitivity_restore_unresponsive, role: role}}, acc ->
              append(
                acc,
                :trace_process_forced_termination,
                %{pid: pid, pid_role: role, reason: :sensitivity_restore_unresponsive},
                :control
              )

            {_pid, _status}, acc ->
              acc
          end)

        {:stop, :normal, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:flush, _from, state) do
    {:reply, flush_result(state), sync_file(state)}
  end

  def handle_call(:flush_barrier, from, state) do
    barriers =
      state.traced
      |> Map.keys()
      |> Enum.filter(&Process.alive?/1)
      |> Map.new(fn pid -> {:erlang.trace_delivered(pid), pid} end)

    if map_size(barriers) == 0 do
      {:reply, flush_result(state), sync_file(state)}
    else
      {:noreply, %{state | flush_waiters: Map.put(state.flush_waiters, from, barriers)}}
    end
  end

  @impl true
  def handle_cast({:pooler_event, generation, event, fields}, %{generation: generation} = state),
    do: {:noreply, append(state, event, fields, :pooler)}

  def handle_cast({:pooler_event, _generation, _event, _fields}, state), do: {:noreply, state}

  def handle_cast({:track_pid, generation, role, pid}, %{generation: generation} = state)
      when role in @roles and is_pid(pid) do
    {_result, state} = track_pid_now(state, role, pid, nil)
    {:noreply, state}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info({:trace_ts, pid, :call, {module, function, args}, timestamp}, state) do
    mfa = {module, function, length(args)}
    started_us = monotonic_us(timestamp)
    key = {pid, mfa}
    calls = Map.update(state.calls, key, [started_us], &[started_us | &1])
    fields = beam_fields(state, pid, %{mfa: mfa_string(mfa), arguments: args})
    {:noreply, append(%{state | calls: calls}, :beam_call, fields, :beam, started_us)}
  end

  def handle_info({:trace_ts, pid, :return_from, mfa, value, timestamp}, state) do
    {state, duration} = pop_call(state, pid, mfa, timestamp)

    fields =
      beam_fields(state, pid, %{mfa: mfa_string(mfa), return: value, duration_us: duration})

    {:noreply, append(state, :beam_return, fields, :beam, monotonic_us(timestamp))}
  end

  def handle_info({:trace_ts, pid, :exception_from, mfa, {class, value}, timestamp}, state) do
    {state, duration} = pop_call(state, pid, mfa, timestamp)

    fields =
      beam_fields(state, pid, %{
        mfa: mfa_string(mfa),
        exception_class: class,
        exception: value,
        duration_us: duration
      })

    {:noreply, append(state, :beam_exception, fields, :beam, monotonic_us(timestamp))}
  end

  def handle_info({:trace_ts, pid, :spawn, child, mfa, timestamp}, state) do
    fields = beam_fields(state, pid, %{child_pid: child, mfa: mfa_string(mfa)})
    state = append(state, :beam_spawn, fields, :beam, monotonic_us(timestamp))
    {_result, state} = track_pid_now(state, role_for(state, pid), child, pid)
    {:noreply, state}
  end

  def handle_info({:trace_ts, pid, :exit, reason, timestamp}, state),
    do:
      {:noreply,
       append(
         state,
         :beam_exit,
         beam_fields(state, pid, %{reason: reason}),
         :beam,
         monotonic_us(timestamp)
       )}

  def handle_info({:trace_ts, pid, :send, message, recipient, timestamp}, state),
    do:
      {:noreply,
       append(
         state,
         :beam_send,
         beam_fields(state, pid, %{message: message, recipient: recipient}),
         :beam,
         monotonic_us(timestamp)
       )}

  def handle_info({:trace_ts, pid, :receive, message, timestamp}, state),
    do:
      {:noreply,
       append(
         state,
         :beam_receive,
         beam_fields(state, pid, %{message: message}),
         :beam,
         monotonic_us(timestamp)
       )}

  def handle_info({:trace_ts, pid, action, peer, timestamp}, state)
      when action in [:link, :unlink, :getting_linked, :getting_unlinked],
      do:
        {:noreply,
         append(
           state,
           String.to_atom("beam_#{action}"),
           beam_fields(state, pid, %{peer: peer}),
           :beam,
           monotonic_us(timestamp)
         )}

  def handle_info({:trace_ts, pid, action, registered_name, timestamp}, state)
      when action in [:register, :unregister],
      do:
        {:noreply,
         append(
           state,
           String.to_atom("beam_#{action}"),
           beam_fields(state, pid, %{registered_name: registered_name}),
           :beam,
           monotonic_us(timestamp)
         )}

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    cond do
      state.sensitivity_restorer == pid and state.sensitivity_restorer_monitor == monitor ->
        :ok = TraceEvent.deactivate_sensitivity_control()

        Enum.each(state.traced, fn {target, %{role: role}} ->
          if Process.alive?(target) and
               role in [:response_task, :owner_session, :upstream_session] do
            send(
              target,
              {:native_compaction_trace_sensitivity, :restore, state.generation,
               state.sensitivity_authorization, pid}
            )
          end
        end)

        Process.send_after(self(), :sensitivity_fail_safe, @sensitivity_fail_safe_ms)

        {:noreply,
         %{
           state
           | sensitivity_restorer: nil,
             sensitivity_restorer_monitor: nil,
             sensitivity_restorer_failed: true
         }}

      true ->
        case state.traced do
          %{^pid => %{monitor: ^monitor, role: role}} ->
            status = Map.put(state.sensitivity_status, inspect(pid), %{role: role, state: :dead})
            next = %{state | traced: Map.delete(state.traced, pid), sensitivity_status: status}

            {:noreply,
             append(next, :beam_process_down, %{pid: pid, pid_role: role, reason: reason}, :beam)}

          _unknown ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:trace_delivered, pid, reference}, state) do
    waiters =
      Enum.reduce(state.flush_waiters, %{}, fn {from, barriers}, acc ->
        next =
          case barriers do
            %{^reference => ^pid} -> Map.delete(barriers, reference)
            _other -> barriers
          end

        if map_size(next) == 0 do
          GenServer.reply(from, flush_result(state))
          acc
        else
          Map.put(acc, from, next)
        end
      end)

    state = %{state | flush_waiters: waiters}
    {:noreply, if(map_size(waiters) == 0, do: sync_file(state), else: state)}
  end

  def handle_info(
        {:native_compaction_trace_sensitivity_restored, generation, pid},
        %{generation: generation} = state
      ) do
    status = Map.put(state.sensitivity_status, inspect(pid), %{state: :restored})
    {:noreply, %{state | sensitivity_status: status}}
  end

  def handle_info(:sensitivity_fail_safe, state) do
    state =
      Enum.reduce(state.traced, state, fn {pid, %{role: role}}, acc ->
        restored? = get_in(acc.sensitivity_status, [inspect(pid), :state]) in [:restored, :dead]

        if Process.alive?(pid) and role in [:response_task, :owner_session, :upstream_session] and
             not restored? do
          Process.exit(pid, :kill)

          acc
          |> append(
            :trace_process_forced_termination,
            %{pid: pid, pid_role: role, reason: :sensitivity_restorer_down},
            :control
          )
        else
          acc
        end
      end)

    {:noreply, state}
  end

  def handle_info(
        {:native_compaction_trace_forced_termination, generation, pid, role, reason},
        %{generation: generation} = state
      ) do
    status =
      Map.put(state.sensitivity_status, inspect(pid), %{
        role: role,
        state: :forced_termination,
        reason: reason
      })

    {:noreply,
     state
     |> Map.put(:sensitivity_status, status)
     |> append(
       :trace_process_forced_termination,
       %{pid: pid, pid_role: role, reason: reason},
       :control
     )}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    state = maybe_write_control(state, :trace_stopped, %{reason: reason})

    Enum.each(state.traced, fn {pid, %{monitor: monitor}} ->
      if Process.alive?(pid), do: :erlang.trace(pid, false, trace_flags(state.mode))
      Process.demonitor(monitor, [:flush])
    end)

    disable_call_patterns(state.trace_plan.patterns)

    if state.file do
      :file.sync(state.file.io)
      :file.close(state.file.io)
    end

    :ok
  end

  defp attach(generation, trace_plan) do
    :telemetry.detach(@handler_id)

    match_spec = [{:_, [], [{:return_trace}, {:exception_trace}]}]

    report =
      Enum.map(trace_plan.patterns, fn pattern ->
        matched = :erlang.trace_pattern(pattern, match_spec, [:local])
        %{pattern: pattern_string(pattern), matched_functions: matched}
      end)

    case :telemetry.attach_many(
           @handler_id,
           [TraceEvent.event(), TraceEvent.control_event()],
           &__MODULE__.handle_event/4,
           generation
         ) do
      :ok -> {:ok, report}
      {:error, reason} -> {:error, reason}
    end
  end

  defp disable_call_patterns(patterns),
    do: Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local]))

  defp append(state, event, fields, source, monotonic_us \\ System.monotonic_time(:microsecond)) do
    fields = enrich_event_fields(state, fields, source)
    sequence = state.sequence + 1
    system_us = state.started_system_us + monotonic_us - state.started_monotonic_us

    full_entry = %{
      "schemaVersion" => 2,
      "run" => state.run_label,
      "sequence" => sequence,
      "source" => to_string(source),
      "event" => to_string(event),
      "systemTimeUs" => system_us,
      "monotonicTimeUs" => monotonic_us,
      "fields" => encode_term(redact_secrets(fields))
    }

    state = maybe_write_full_entry(state, full_entry)

    safe_entry = %{
      "sequence" => sequence,
      "source" => to_string(source),
      "event" => to_string(event),
      "systemTimeUs" => system_us,
      "monotonicTimeUs" => monotonic_us,
      "fields" => safe_fields(fields, source, state.mode)
    }

    queue = :queue.in(safe_entry, state.events)

    queue =
      if :queue.len(queue) > state.limit do
        {{:value, _dropped}, queue} = :queue.out(queue)
        queue
      else
        queue
      end

    %{state | sequence: sequence, events: queue, event_count: state.event_count + 1}
  end

  defp maybe_write_full_entry(%{file: nil} = state, _entry), do: state
  defp maybe_write_full_entry(%{truncated: true} = state, _entry), do: state

  defp maybe_write_full_entry(state, entry) do
    encoded = [Jason.encode!(entry), "\n"]
    bytes = IO.iodata_length(encoded)

    cond do
      state.written_events + 1 > state.max_events ->
        write_truncation(state, :max_events)

      state.file_bytes + bytes + @truncation_reserve_bytes > state.max_bytes ->
        write_truncation(state, :max_bytes)

      true ->
        :ok = IO.binwrite(state.file.io, encoded)

        %{
          state
          | file_bytes: state.file_bytes + bytes,
            written_events: state.written_events + 1
        }
    end
  end

  defp write_truncation(state, reason) do
    entry = %{
      "schemaVersion" => 2,
      "run" => state.run_label,
      "sequence" => state.sequence + 1,
      "source" => "control",
      "event" => "trace_truncated",
      "systemTimeUs" => System.system_time(:microsecond),
      "monotonicTimeUs" => System.monotonic_time(:microsecond),
      "fields" => %{
        "reason" => to_string(reason),
        "maxEvents" => state.max_events,
        "maxBytes" => state.max_bytes,
        "writtenEvents" => state.written_events,
        "writtenBytes" => state.file_bytes
      }
    }

    encoded = [Jason.encode!(entry), "\n"]
    :ok = IO.binwrite(state.file.io, encoded)

    %{
      state
      | file_bytes: state.file_bytes + IO.iodata_length(encoded),
        truncated: true,
        truncation_reason: reason
    }
  end

  defp track_pid_now(state, role, pid, parent) do
    cond do
      not Process.alive?(pid) ->
        {{:error, :invalid_pid}, state}

      Map.has_key?(state.traced, pid) ->
        current = Map.fetch!(state.traced, pid)

        if current.role == role do
          {:ok, state}
        else
          updated = %{current | role: role}
          state = put_in(state, [:traced, pid], updated)

          {:ok,
           append(
             state,
             :beam_pid_role_updated,
             %{pid: pid, previous_role: current.role, pid_role: role},
             :beam
           )}
        end

      true ->
        monitor = Process.monitor(pid)

        with :ok <- maybe_make_existing_process_observable(state, role, pid),
             1 <- enable_pid_trace(pid, state.mode) do
          info = process_identity(pid, role, parent, monitor)
          state = %{state | traced: Map.put(state.traced, pid, info)}
          {:ok, append(state, :beam_pid_enrolled, Map.delete(info, :monitor), :beam)}
        else
          {:error, reason} ->
            Process.demonitor(monitor, [:flush])
            {{:error, {:sensitivity_control_failed, reason}}, state}

          0 ->
            Process.demonitor(monitor, [:flush])
            {{:error, :invalid_pid}, state}
        end
    end
  end

  defp trace_flags(:full), do: @full_beam_flags
  defp trace_flags(:safe), do: @safe_beam_flags

  defp enable_pid_trace(pid, mode) do
    :erlang.trace(pid, true, trace_flags(mode) ++ [{:tracer, self()}])
  catch
    :error, :badarg -> 0
  end

  defp process_identity(pid, role, parent, monitor) do
    info =
      Process.info(pid, [
        :registered_name,
        :initial_call,
        :current_function,
        :links,
        :monitors,
        :monitored_by
      ])
      |> Map.new()

    %{
      pid: pid,
      role: role,
      parent_pid: parent,
      registered_name: info[:registered_name],
      initial_call: info[:initial_call],
      current_function: info[:current_function],
      links: info[:links],
      monitors: info[:monitors],
      monitored_by: info[:monitored_by],
      node: node(pid),
      monitor: monitor
    }
  end

  defp beam_fields(state, pid, fields),
    do:
      Map.merge(
        %{pid: pid, pid_role: role_for(state, pid), process: process_snapshot(pid)},
        fields
      )

  defp process_snapshot(pid) do
    case Process.info(pid, [
           :registered_name,
           :current_function,
           :message_queue_len,
           :links,
           :monitors,
           :monitored_by
         ]) do
      nil -> %{pid: pid, alive: false}
      info -> info |> Map.new() |> Map.put(:pid, pid) |> Map.put(:alive, true)
    end
  end

  defp role_for(state, pid), do: get_in(state.traced, [pid, :role]) || :spawned_child

  defp maybe_make_existing_process_observable(%{mode: :safe}, _role, _pid), do: :ok

  defp maybe_make_existing_process_observable(state, role, pid)
       when role in [:owner_session, :upstream_session] do
    if cooperative_genserver?(pid) do
      GenServer.call(
        pid,
        {:native_compaction_trace_sensitivity, :observe, state.generation,
         state.sensitivity_authorization, state.sensitivity_restorer},
        5_000
      )
    else
      :ok
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp maybe_make_existing_process_observable(_state, _role, _pid), do: :ok

  defp cooperative_genserver?(pid) do
    GenServer.call(pid, :native_compaction_trace_cooperative?, 100) == true
  catch
    :exit, _reason -> false
  end

  defp pop_call(state, pid, mfa, timestamp) do
    key = {pid, mfa}
    now = monotonic_us(timestamp)

    case Map.get(state.calls, key, []) do
      [started | rest] ->
        calls =
          if rest == [], do: Map.delete(state.calls, key), else: Map.put(state.calls, key, rest)

        {%{state | calls: calls}, max(now - started, 0)}

      [] ->
        {state, nil}
    end
  end

  defp monotonic_us(timestamp), do: System.convert_time_unit(timestamp, :native, :microsecond)

  defp mfa_string({module, function, arity}) when is_atom(function) and is_integer(arity),
    do: "#{inspect(module)}.#{function}/#{arity}"

  defp mfa_string(term), do: inspect(term)
  defp pattern_string({module, :_, :_}), do: "#{inspect(module)}.*/*"
  defp pattern_string(pattern), do: mfa_string(pattern)

  defp build_trace_plan(:safe, _opts) do
    with :ok <- ensure_pattern_modules(@safe_call_patterns) do
      {:ok,
       %{
         mode: :safe,
         modules: Enum.uniq(Enum.map(@safe_call_patterns, &elem(&1, 0))),
         patterns: @safe_call_patterns,
         excluded_modules: [],
         unavailable_modules: []
       }}
    end
  end

  defp build_trace_plan(:full, opts) do
    include = Keyword.get(opts, :include_modules, [])
    exclude = Keyword.get(opts, :exclude_modules, [])

    with {:ok, include_modules} <- normalize_module_filter(include),
         {:ok, exclude_modules} <- normalize_module_filter(exclude) do
      requested = if include_modules == [], do: @critical_modules, else: include_modules

      modules =
        requested
        |> Enum.reject(&(&1 in exclude_modules))
        |> Enum.uniq()

      {loaded, unavailable} = load_modules(modules)

      if unavailable == [] do
        {:ok,
         %{
           mode: :full,
           modules: loaded,
           patterns: Enum.map(loaded, &{&1, :_, :_}),
           excluded_modules: exclude_modules,
           unavailable_modules: []
         }}
      else
        {:error, {:trace_modules_unavailable, unavailable}}
      end
    end
  end

  defp ensure_pattern_modules(patterns) do
    patterns
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> load_modules()
    |> case do
      {_loaded, []} -> :ok
      {_loaded, unavailable} -> {:error, {:trace_modules_unavailable, unavailable}}
    end
  end

  defp load_modules(modules) do
    Enum.reduce(modules, {[], []}, fn module, {loaded, unavailable} ->
      case Code.ensure_loaded(module) do
        {:module, ^module} ->
          {[module | loaded], unavailable}

        {:error, reason} ->
          {loaded, [%{module: inspect(module), reason: inspect(reason)} | unavailable]}
      end
    end)
    |> then(fn {loaded, unavailable} -> {Enum.reverse(loaded), Enum.reverse(unavailable)} end)
  end

  defp normalize_module_filter(modules) when is_list(modules) do
    modules
    |> Enum.reduce_while({:ok, []}, fn
      module, {:ok, acc} when is_atom(module) ->
        {:cont, {:ok, [module | acc]}}

      "Elixir." <> _rest = name, {:ok, acc} ->
        try do
          {:cont, {:ok, [String.to_existing_atom(name) | acc]}}
        rescue
          ArgumentError -> {:halt, {:error, {:unknown_trace_module, name}}}
        end

      name, {:ok, acc} when is_binary(name) ->
        normalize_module_filter(["Elixir." <> name])
        |> case do
          {:ok, [module]} -> {:cont, {:ok, [module | acc]}}
          error -> {:halt, error}
        end

      value, _acc ->
        {:halt, {:error, {:invalid_trace_module, inspect(value)}}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp normalize_module_filter(_modules), do: {:error, :invalid_trace_module_filter}

  defp safe_fields(fields, source, :safe) when source in [:pooler, :beam] do
    fields = if source == :pooler, do: Map.new(fields), else: safe_beam_fields(fields)

    fields
    |> Map.new(fn {key, value} -> {to_string(key), encode_term(value)} end)
  end

  defp safe_fields(fields, _source, _mode) do
    sanitized = TraceEvent.sanitize(fields)

    extras =
      fields
      |> Enum.reduce(%{}, fn
        {:message, message}, acc -> Map.put(acc, :message_class, message_class(message))
        {:mfa, mfa}, acc -> Map.put(acc, :message_class, TraceEvent.fingerprint(mfa))
        {:reason, reason}, acc -> Map.put(acc, :reason, reason_class(reason))
        {_key, _value}, acc -> acc
      end)

    sanitized
    |> Map.merge(extras)
    |> Map.new(fn {key, value} -> {to_string(key), encode_term(value)} end)
  end

  defp safe_beam_fields(fields) do
    Enum.reduce(fields, %{}, fn
      {:message, message}, acc -> Map.put(acc, :message_class, message_class(message))
      {:mfa, mfa}, acc -> Map.put(acc, :message_class, TraceEvent.fingerprint(mfa))
      {:reason, reason}, acc -> Map.put(acc, :reason, reason_class(reason))
      {:pid_role, role}, acc -> Map.put(acc, :pid_role, role)
      {_key, _value}, acc -> acc
    end)
  end

  defp message_class(message) when is_atom(message), do: Atom.to_string(message)

  defp message_class(message) when is_tuple(message) and tuple_size(message) > 0 do
    case elem(message, 0) do
      head when is_atom(head) -> Atom.to_string(head)
      _head -> "tuple"
    end
  end

  defp message_class(message) when is_map(message), do: "map"
  defp message_class(message) when is_list(message), do: "list"
  defp message_class(message) when is_binary(message), do: "binary"
  defp message_class(_message), do: "other"

  defp reason_class(reason) when reason in [:normal, :shutdown, :killed, :noproc],
    do: Atom.to_string(reason)

  defp reason_class({:shutdown, _detail}), do: "shutdown"
  defp reason_class(_reason), do: "other"

  @doc false
  @spec redact_secrets(term()) :: term()
  def redact_secrets(term), do: redact(term)

  defp redact(%{__struct__: _module} = struct), do: struct |> Map.from_struct() |> redact()

  defp redact(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      cond do
        secret_key?(key) -> {key, "[REDACTED_SECRET]"}
        textual_frame_key?(key) and is_binary(value) -> {key, redact_frame_text(value)}
        true -> {key, redact(value)}
      end
    end)
  end

  defp redact([]), do: []
  defp redact([head | tail]), do: [redact(head) | redact(tail)]

  defp redact(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&redact/1) |> List.to_tuple()

  defp redact(value) when is_binary(value),
    do: if(Regex.match?(@credential_value, value), do: "[REDACTED_SECRET]", else: value)

  defp redact(value), do: value

  defp secret_key?(key) when is_atom(key) or is_binary(key),
    do: Regex.match?(@secret_key, to_string(key))

  defp secret_key?(_key), do: false

  defp textual_frame_key?(key) when is_atom(key) or is_binary(key),
    do: to_string(key) in ["frame_text", "raw_frame_text", "mapped_frame_text"]

  defp textual_frame_key?(_key), do: false

  defp redact_frame_text(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> Jason.encode!(redact(decoded))
      {:error, _reason} -> redact_non_json_text(value)
    end
  end

  defp redact_non_json_text(value) do
    value
    |> String.replace(
      ~r/(?i)(authorization\s*[:=]\s*)Bearer\s+[A-Za-z0-9._~+\/-]+/,
      "\\1Bearer [REDACTED_SECRET]"
    )
    |> String.replace(
      ~r/(?i)(authorization|cookie|set-cookie|x-api-key|api[_-]?key|access[_-]?token|refresh[_-]?token)\s*[:=]\s*([^\s,;]+)/,
      "\\1=[REDACTED_SECRET]"
    )
    |> String.replace(~r/(?i)Bearer\s+[A-Za-z0-9._~+\/-]+/, "Bearer [REDACTED_SECRET]")
    |> String.replace(
      ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/s,
      "[REDACTED_SECRET]"
    )
  end

  defp encode_term(%{__struct__: _module} = struct),
    do: struct |> Map.from_struct() |> encode_term()

  defp encode_term(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {encode_map_key(key), encode_term(item)} end)

  defp encode_term([]), do: []

  defp encode_term([_head | _tail] = value) do
    case split_list(value, []) do
      {:proper, items} ->
        Enum.map(items, &encode_term/1)

      {:improper, items, tail} ->
        %{"improperList" => Enum.map(items, &encode_term/1), "tail" => encode_term(tail)}
    end
  end

  defp encode_term(value) when is_tuple(value),
    do: %{"tuple" => value |> Tuple.to_list() |> Enum.map(&encode_term/1)}

  defp encode_term(value)
       when is_pid(value) or is_reference(value) or is_port(value) or is_function(value),
       do: inspect(value)

  defp encode_term(value) when is_boolean(value) or is_nil(value), do: value
  defp encode_term(value) when is_atom(value), do: Atom.to_string(value)

  defp encode_term(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      %{"binaryHex" => Base.encode16(value, case: :lower), "bytes" => byte_size(value)}
    end
  end

  defp encode_term(value) when is_number(value), do: value
  defp encode_term(value), do: inspect(value)

  defp encode_map_key(key) when is_atom(key) or is_binary(key) or is_number(key),
    do: to_string(key)

  defp encode_map_key(key), do: inspect(key)

  defp split_list([], acc), do: {:proper, Enum.reverse(acc)}
  defp split_list([head | tail], acc), do: split_list(tail, [head | acc])
  defp split_list(tail, acc), do: {:improper, Enum.reverse(acc), tail}

  defp open_output(:safe, _run_label, _root), do: {:ok, nil}

  defp open_output(:full, run_label, root) do
    root = root || Path.join(System.tmp_dir!(), "codex-pooler-native-compaction-traces")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    label =
      run_label
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
      |> String.slice(0, 80)

    path =
      Path.join(
        root,
        "#{System.system_time(:millisecond)}-#{label}-#{System.unique_integer([:positive])}.jsonl"
      )

    with {:ok, io} <- File.open(path, [:write, :binary, :exclusive]) do
      File.chmod!(path, 0o600)
      {:ok, %{io: io, path: path}}
    end
  end

  defp file_path(nil), do: nil
  defp file_path(file), do: file.path

  defp maybe_write_control(%{file: nil} = state, _event, _fields), do: state
  defp maybe_write_control(%{truncated: true} = state, _event, _fields), do: state

  defp maybe_write_control(state, event, fields) do
    monotonic_us = System.monotonic_time(:microsecond)
    sequence = state.sequence + 1
    system_us = state.started_system_us + monotonic_us - state.started_monotonic_us

    entry = %{
      "schemaVersion" => 2,
      "run" => state.run_label,
      "sequence" => sequence,
      "source" => "control",
      "event" => to_string(event),
      "systemTimeUs" => system_us,
      "monotonicTimeUs" => monotonic_us,
      "fields" => encode_term(redact_secrets(fields))
    }

    encoded = [Jason.encode!(entry), "\n"]
    :ok = IO.binwrite(state.file.io, encoded)

    %{
      state
      | sequence: sequence,
        file_bytes: state.file_bytes + IO.iodata_length(encoded),
        written_events: state.written_events + 1
    }
  end

  defp export_state(state),
    do: %{
      "schemaVersion" => 2,
      "mode" => to_string(state.mode),
      "runFingerprint" => state.run_fingerprint,
      "limit" => state.limit,
      "eventCount" => :queue.len(state.events),
      "retainedCount" => :queue.len(state.events),
      "path" => file_path(state.file),
      "truncated" => state.truncated,
      "truncationReason" => encode_optional(state.truncation_reason),
      "events" => :queue.to_list(state.events)
    }

  defp status_state(state),
    do: %{
      "running" => true,
      "mode" => to_string(state.mode),
      "runFingerprint" => state.run_fingerprint,
      "eventCount" => state.event_count,
      "tracedPids" => map_size(state.traced),
      "path" => file_path(state.file),
      "writtenEvents" => state.written_events,
      "writtenBytes" => state.file_bytes,
      "maxEvents" => state.max_events,
      "maxBytes" => state.max_bytes,
      "truncated" => state.truncated,
      "truncationReason" => encode_optional(state.truncation_reason),
      "traceModules" => Enum.map(state.trace_plan.modules, &inspect/1),
      "excludedModules" => Enum.map(state.trace_plan.excluded_modules, &inspect/1),
      "unavailableModules" => state.trace_plan.unavailable_modules,
      "processSensitivity" => sensitivity_status(state),
      "tracePatterns" => state.pattern_report
    }

  defp empty_export,
    do: %{
      "schemaVersion" => 2,
      "mode" => "off",
      "runFingerprint" => nil,
      "limit" => 0,
      "eventCount" => 0,
      "retainedCount" => 0,
      "path" => nil,
      "truncated" => false,
      "truncationReason" => nil,
      "traceModules" => [],
      "tracePatterns" => [],
      "events" => []
    }

  defp call_if_started(message, absent) do
    case Process.whereis(@name) do
      nil -> absent
      pid -> GenServer.call(pid, message, 15_000)
    end
  end

  defp flush_result(%{truncated: true}), do: {:error, :trace_truncated}
  defp flush_result(_state), do: :ok

  defp sync_file(state) do
    if state.file, do: :file.sync(state.file.io)
    state
  end

  defp cast_if_started(message) do
    if pid = Process.whereis(@name), do: GenServer.cast(pid, message)
  end

  defp call_enroll_if_started(generation, role, traced_pid) do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> GenServer.call(pid, {:track_pid, generation, role, traced_pid}, 15_000)
    end
  catch
    :exit, _reason -> :ok
  end

  defp configured_limit,
    do: Application.get_env(:codex_pooler, __MODULE__, []) |> Keyword.get(:limit, @default_limit)

  defp normalize_limit(limit) when is_integer(limit) and limit > 0 and limit <= 10_000, do: limit
  defp normalize_limit(_limit), do: @default_limit

  defp normalize_max_events(:safe, _value), do: @default_limit

  defp normalize_max_events(:full, value) when is_integer(value) and value > 0,
    do: value

  defp normalize_max_events(:full, _value), do: @default_full_max_events

  defp normalize_max_bytes(:safe, _value), do: 0

  defp normalize_max_bytes(:full, value)
       when is_integer(value) and value > @truncation_reserve_bytes,
       do: value

  defp normalize_max_bytes(:full, _value), do: @default_full_max_bytes

  defp encode_optional(nil), do: nil
  defp encode_optional(value), do: to_string(value)

  defp maybe_start_sensitivity_restorer(:safe, _generation, _authorization), do: {:ok, nil}

  defp maybe_start_sensitivity_restorer(:full, generation, authorization),
    do: SensitivityRestorer.start(generation, authorization)

  defp maybe_activate_sensitivity_control(
         :safe,
         _generation,
         _authorization,
         _restorer,
         _collector
       ),
       do: :ok

  defp maybe_activate_sensitivity_control(
         :full,
         generation,
         authorization,
         restorer,
         collector
       ),
       do:
         TraceEvent.activate_sensitivity_control(
           generation,
           authorization,
           restorer,
           collector
         )

  defp maybe_bind_sensitivity_restorer(:safe, _restorer, _collector, _generation, _authorization),
    do: :ok

  defp maybe_bind_sensitivity_restorer(
         :full,
         _restorer,
         collector,
         generation,
         authorization
       ) do
    SensitivityRestorer.bind_collector(collector, generation, authorization)
  end

  defp maybe_configure_restorer(:safe, _trace_plan), do: :ok

  defp maybe_configure_restorer(:full, trace_plan),
    do: SensitivityRestorer.configure_cleanup(trace_plan.patterns, trace_flags(:full))

  defp restore_sensitivity(%{mode: :safe}), do: {:ok, %{}}

  defp restore_sensitivity(%{sensitivity_restorer: nil} = state) do
    pending =
      state.traced
      |> Enum.filter(fn {pid, %{role: role}} ->
        Process.alive?(pid) and role in [:owner_session, :upstream_session, :response_task] and
          get_in(state.sensitivity_status, [inspect(pid), :state]) not in [:restored, :dead]
      end)
      |> Enum.map(fn {pid, %{role: role}} -> %{pid: inspect(pid), role: role} end)

    if pending == [],
      do: {:ok, state.sensitivity_status},
      else: {:error, {:sensitivity_restorer_unavailable, pending}}
  end

  defp restore_sensitivity(state),
    do:
      SensitivityRestorer.stop_and_restore(
        state.generation,
        state.sensitivity_authorization
      )

  defp sensitivity_status(%{mode: :safe}), do: %{}

  defp sensitivity_status(state) do
    case Process.whereis(SensitivityRestorer) do
      nil -> state.sensitivity_status
      _pid -> SensitivityRestorer.status()
    end
  end

  defp enrich_event_fields(state, fields, :pooler) do
    fields = Map.new(fields)
    pid = Map.get(fields, :emitter_pid) || Map.get(fields, :pid) || self()

    fields
    |> Map.put_new(:pid, pid)
    |> Map.put_new(:pid_role, semantic_event_role(state, fields, pid))
  end

  defp enrich_event_fields(state, fields, :beam) do
    fields = Map.new(fields)
    pid = Map.get(fields, :pid)

    Map.put_new(
      fields,
      :pid_role,
      Map.get(fields, :role) || if(is_pid(pid), do: role_for(state, pid), else: :unknown)
    )
  end

  defp enrich_event_fields(_state, fields, _source), do: fields

  defp semantic_event_role(state, fields, pid) do
    cond do
      is_pid(Map.get(fields, :response_task_pid)) -> :response_task
      is_pid(Map.get(fields, :owner_pid)) -> :owner_session
      is_pid(Map.get(fields, :upstream_pid)) -> :upstream_session
      is_pid(Map.get(fields, :socket_pid)) -> :socket
      true -> role_for(state, pid)
    end
  end

  defp cleanup_failed_start do
    result = stop_scope()

    case Process.whereis(SensitivityRestorer) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end

    :telemetry.detach(@handler_id)
    disable_call_patterns(@safe_call_patterns)
    disable_call_patterns(Enum.map(@critical_modules, &{&1, :_, :_}))
    TraceEvent.deactivate_mode()
    result
  catch
    :exit, _reason ->
      TraceEvent.deactivate_mode()
      :ok
  end

  defp restore_without_collector do
    result =
      case TraceEvent.sensitivity_control() do
        {generation, authorization, _restorer, _collector} ->
          SensitivityRestorer.stop_and_restore(generation, authorization)

        :inactive ->
          {:ok, %{}}
      end

    disable_call_patterns(@safe_call_patterns)
    disable_call_patterns(Enum.map(@critical_modules, &{&1, :_, :_}))

    case result do
      {:ok, _status} -> :ok
      {:error, _reason} = error -> error
    end
  end
end
