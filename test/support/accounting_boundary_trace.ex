defmodule CodexPooler.AccountingBoundaryTrace do
  @moduledoc false

  # Failure-detection budget for the forwarded trace of the boundary call: the
  # call happened inside the callback, so a green run returns on its message and
  # only a missing call spends the budget.
  @detection_timeout_ms 15_000

  @type trace_mfa :: {module(), atom(), non_neg_integer()}

  @spec capture_call(trace_mfa(), (-> result)) :: {result, [term()]} when result: term()
  def capture_call({module, function, arity} = mfa, callback)
      when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0 and
             is_function(callback, 0) do
    caller = self()
    trace_ref = make_ref()
    tracer = spawn_link(fn -> forward_traces(caller, trace_ref) end)

    cleanup = fn ->
      disable_process_trace(caller)
      :erlang.trace_pattern(mfa, false, [:local])
      stop_tracer(tracer)
    end

    ExUnit.Callbacks.on_exit({__MODULE__, trace_ref}, cleanup)

    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(caller, true, [:call, {:tracer, tracer}])

    try do
      result = callback.()
      {result, await_call!(trace_ref, caller, module, function, arity)}
    after
      cleanup.()
    end
  end

  defp forward_traces(parent, trace_ref) do
    receive do
      :stop ->
        :ok

      message ->
        send(parent, {trace_ref, message})
        forward_traces(parent, trace_ref)
    end
  end

  defp disable_process_trace(caller) do
    :erlang.trace(caller, false, [:call])
  rescue
    ArgumentError -> 0
  end

  defp await_call!(trace_ref, caller, module, function, arity) do
    receive do
      {^trace_ref, {:trace, ^caller, :call, {^module, ^function, args}}}
      when length(args) == arity ->
        args

      {^trace_ref, _other_trace} ->
        await_call!(trace_ref, caller, module, function, arity)
    after
      @detection_timeout_ms ->
        raise "expected #{inspect(module)}.#{function}/#{arity} accounting boundary call"
    end
  end

  defp stop_tracer(tracer) do
    monitor = Process.monitor(tracer)
    send(tracer, :stop)

    receive do
      {:DOWN, ^monitor, :process, ^tracer, _reason} -> :ok
    after
      1_000 ->
        Process.exit(tracer, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^tracer, _reason} -> :ok
        end
    end
  end
end
