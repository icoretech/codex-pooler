defmodule CodexPooler.Dev.NativeCompactionTrace.SensitivityWatchdog do
  @moduledoc false

  @restore_grace_ms 3_500

  @spec start(pid(), atom(), reference(), reference(), pid(), pid()) :: {:ok, pid()}
  def start(target, role, generation, authorization, restorer, collector) do
    Task.start(fn ->
      target_monitor = Process.monitor(target)
      restorer_monitor = Process.monitor(restorer)
      collector_monitor = Process.monitor(collector)

      loop(%{
        target: target,
        role: role,
        generation: generation,
        authorization: authorization,
        restorer: restorer,
        collector: collector,
        target_monitor: target_monitor,
        restorer_monitor: restorer_monitor,
        collector_monitor: collector_monitor,
        force_timer: nil
      })
    end)
  end

  defp loop(state) do
    receive do
      {:native_compaction_trace_sensitivity_restored, pid} when pid == state.target ->
        cancel_timer(state.force_timer)
        :ok

      {:DOWN, monitor, :process, pid, _reason}
      when monitor == state.target_monitor and pid == state.target ->
        cancel_timer(state.force_timer)
        :ok

      {:DOWN, monitor, :process, pid, _reason}
      when (monitor == state.restorer_monitor and pid == state.restorer) or
             (monitor == state.collector_monitor and pid == state.collector) ->
        state = request_restore(state)
        loop(state)

      :force_terminate ->
        if Process.alive?(state.target) do
          send(state.collector, {
            :native_compaction_trace_forced_termination,
            state.generation,
            state.target,
            state.role,
            :diagnostic_helper_down
          })

          Process.exit(state.target, :kill)
          loop(%{state | force_timer: nil})
        else
          :ok
        end

      _message ->
        loop(state)
    end
  end

  defp request_restore(%{force_timer: timer} = state) when is_reference(timer), do: state

  defp request_restore(state) do
    send(
      state.target,
      {:native_compaction_trace_sensitivity, :restore, state.generation, state.authorization,
       state.restorer}
    )

    %{state | force_timer: Process.send_after(self(), :force_terminate, @restore_grace_ms)}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)
end
