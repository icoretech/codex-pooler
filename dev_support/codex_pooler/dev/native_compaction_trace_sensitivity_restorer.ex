defmodule CodexPooler.Dev.NativeCompactionTrace.SensitivityRestorer do
  @moduledoc false

  use GenServer

  @name __MODULE__
  @restore_timeout_ms 1_000
  @restore_attempts 3

  @spec start(reference(), reference()) :: {:ok, pid()} | {:error, term()}
  def start(generation, authorization) do
    GenServer.start(__MODULE__, {generation, authorization}, name: @name)
  end

  @spec stop_and_restore(reference(), reference()) :: {:ok, map()} | {:error, term()}
  def stop_and_restore(generation, authorization) do
    case Process.whereis(@name) do
      nil ->
        {:error, :sensitivity_restorer_unavailable}

      pid ->
        GenServer.call(pid, {:stop_and_restore, generation, authorization}, 10_000)
    end
  catch
    :exit, {:normal, _call} -> {:ok, %{}}
    :exit, {:noproc, _call} -> {:error, :sensitivity_restorer_unavailable}
  end

  @spec bind_collector(pid(), reference(), reference()) :: :ok | {:error, term()}
  def bind_collector(collector, generation, authorization) when is_pid(collector) do
    GenServer.call(@name, {:bind_collector, collector, generation, authorization})
  end

  @spec configure_cleanup([tuple()], [atom()]) :: :ok
  def configure_cleanup(patterns, trace_flags) when is_list(patterns) and is_list(trace_flags),
    do: GenServer.call(@name, {:configure_cleanup, patterns, trace_flags})

  @spec status() :: map()
  def status do
    case Process.whereis(@name) do
      nil -> %{}
      pid -> GenServer.call(pid, :status)
    end
  end

  @impl true
  def init({generation, authorization}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       generation: generation,
       authorization: authorization,
       collector: nil,
       collector_monitor: nil,
       patterns: [],
       trace_flags: [],
       processes: %{},
       stop_from: nil,
       stop_timer: nil,
       restore_attempt: 0,
       collector_cleanup?: false
     }}
  end

  @impl true
  def handle_call(
        {:bind_collector, collector, generation, authorization},
        _from,
        %{generation: generation, authorization: authorization, collector: nil} = state
      ) do
    {:reply, :ok, %{state | collector: collector, collector_monitor: Process.monitor(collector)}}
  end

  def handle_call({:bind_collector, _collector, _generation, _authorization}, _from, state),
    do: {:reply, {:error, :unauthorized_or_already_bound}, state}

  def handle_call({:configure_cleanup, patterns, trace_flags}, _from, state),
    do: {:reply, :ok, %{state | patterns: patterns, trace_flags: trace_flags}}

  def handle_call(
        {:register_process, generation, authorization, pid, role},
        _from,
        %{generation: generation, authorization: authorization} = state
      )
      when is_pid(pid) and is_atom(role) do
    case state.processes do
      %{^pid => _process} ->
        {:reply, :ok, state}

      _other ->
        monitor = Process.monitor(pid)
        process = %{pid: pid, role: role, monitor: monitor, state: :observable}
        {:reply, :ok, put_in(state, [:processes, pid], process)}
    end
  end

  def handle_call({:register_process, _generation, _authorization, _pid, _role}, _from, state),
    do: {:reply, {:error, :unauthorized}, state}

  def handle_call(:status, _from, state), do: {:reply, status_map(state), state}

  def handle_call(
        {:stop_and_restore, generation, authorization},
        from,
        %{generation: generation, authorization: authorization} = state
      ) do
    state = request_restore(%{state | restore_attempt: 1})

    if restore_complete?(state) do
      {:stop, :normal, {:ok, status_map(state)}, state}
    else
      timer = Process.send_after(self(), :restore_timeout, @restore_timeout_ms)
      {:noreply, %{state | stop_from: from, stop_timer: timer}}
    end
  end

  def handle_call({:stop_and_restore, _generation, _authorization}, _from, state),
    do: {:reply, {:error, :unauthorized}, state}

  @impl true
  def handle_cast(
        {:process_restored, generation, authorization, pid},
        %{generation: generation, authorization: authorization} = state
      ) do
    state = update_process_state(state, pid, :restored)
    maybe_finish_stop(state)
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    cond do
      state.collector == pid and state.collector_monitor == monitor ->
        state =
          state
          |> Map.put(:collector, nil)
          |> Map.put(:collector_monitor, nil)
          |> Map.put(:collector_cleanup?, true)
          |> cleanup_tracing()
          |> request_restore()

        timer = Process.send_after(self(), :restore_timeout, @restore_timeout_ms)
        state = %{state | stop_timer: timer, restore_attempt: 1}
        {:noreply, state}

      true ->
        state =
          case state.processes do
            %{^pid => %{monitor: ^monitor}} -> update_process_state(state, pid, :dead)
            _other -> state
          end

        maybe_finish_stop(state)
    end
  end

  def handle_info(:restore_timeout, state) do
    if state.restore_attempt < @restore_attempts do
      state = request_restore(%{state | restore_attempt: state.restore_attempt + 1})
      timer = Process.send_after(self(), :restore_timeout, @restore_timeout_ms)
      {:noreply, %{state | stop_timer: timer}}
    else
      state = force_terminate_pending(state)
      timer = Process.send_after(self(), :forced_down_timeout, @restore_timeout_ms)
      {:noreply, %{state | stop_timer: timer}}
    end
  end

  def handle_info(:forced_down_timeout, state) do
    pending = pending_processes(state)

    if state.stop_from do
      GenServer.reply(state.stop_from, {:error, {:forced_termination_timeout, pending}})
    end

    {:noreply, %{state | stop_from: nil, stop_timer: nil}}
  end

  defp request_restore(state) do
    processes =
      Map.new(state.processes, fn {pid, process} ->
        if Process.alive?(pid) and process.state in [:observable, :restore_pending] do
          send(
            pid,
            {:native_compaction_trace_sensitivity, :restore, state.generation,
             state.authorization, self()}
          )

          {pid, %{process | state: :restore_pending}}
        else
          {pid, process}
        end
      end)

    %{state | processes: processes}
  end

  defp force_terminate_pending(state) do
    processes =
      Map.new(state.processes, fn {pid, process} ->
        if Process.alive?(pid) and process.state == :restore_pending do
          Process.exit(pid, :kill)

          {pid,
           process
           |> Map.put(:state, :forced_termination)
           |> Map.put(:reason, :sensitivity_restore_unresponsive)}
        else
          {pid, process}
        end
      end)

    %{state | processes: processes}
  end

  defp cleanup_tracing(state) do
    :telemetry.detach("codex-pooler-native-compaction-run-trace")

    Enum.each(state.processes, fn {pid, _process} ->
      if Process.alive?(pid), do: :erlang.trace(pid, false, state.trace_flags)
    end)

    Enum.each(state.patterns, &:erlang.trace_pattern(&1, false, [:local]))
    CodexPooler.Gateway.Transports.Websocket.NativeCompactionTrace.deactivate_mode()
    state
  end

  defp maybe_finish_stop(%{stop_from: nil, collector_cleanup?: true} = state) do
    if restore_complete?(state), do: {:stop, :normal, state}, else: {:noreply, state}
  end

  defp maybe_finish_stop(%{stop_from: nil} = state), do: {:noreply, state}

  defp maybe_finish_stop(state) do
    if restore_complete?(state) do
      if state.stop_timer, do: Process.cancel_timer(state.stop_timer)
      GenServer.reply(state.stop_from, {:ok, status_map(state)})
      {:stop, :normal, %{state | stop_from: nil, stop_timer: nil}}
    else
      {:noreply, state}
    end
  end

  defp restore_complete?(state),
    do: Enum.all?(state.processes, fn {_pid, process} -> process.state in [:restored, :dead] end)

  defp pending_processes(state) do
    state.processes
    |> Enum.filter(fn {_pid, process} -> process.state == :restore_pending end)
    |> Enum.map(fn {pid, process} -> %{pid: inspect(pid), role: process.role} end)
  end

  defp update_process_state(state, pid, process_state) do
    case state.processes do
      %{^pid => process} -> put_in(state, [:processes, pid], %{process | state: process_state})
      _other -> state
    end
  end

  defp status_map(state) do
    Map.new(state.processes, fn {pid, process} ->
      {inspect(pid), Map.take(process, [:role, :state, :reason])}
    end)
  end
end
