defmodule CodexPoolerWeb.Runtime.WebsocketCleanupFence do
  @moduledoc """
  Holds a test's teardown until the sockets of the listeners it registered
  have terminated and every session cleanup it saw deferred has finished.

  That is narrower than "every cleanup the test caused" (findings#206 row
  206-405). A cleanup is recorded only once its socket emits the
  `cleanup_deferred` failure while the fence's handlers are attached, and a
  socket is waited for only when a registered listener started it. The fence
  therefore does not see:

  - a socket of a listener that was never registered with `install!/1`
    (`server:`) and is still inside the 100 ms yield of `terminate/2` when the
    callback checks;
  - a cleanup deferred before `install!/1` or after the callback detached its
    handlers, such as one set off by an `on_exit` callback registered before
    the fence (those run after it);
  - a socket whose client outlives the 15 s budget, which is left to the
    listener's own shutdown.

  The handlers are global, so a cleanup another test deferred in the same
  window is recorded and waited for too.

  `await_session_cleanups!/0` is the barrier behind it: it waits for every
  session cleanup task running when it is called, whoever started it, and
  `DataCase.stop_sandbox/2` calls it in every test before the sandbox owner
  stops, so these cleanups still finish under a live owner. The fence is still needed for the order of teardown and for its log
  handling, which are described below.

  `CodexResponsesSocket.terminate/2` runs its owner or direct cleanup in a
  supervised task and waits for it only `WebsocketControlPath`'s 100 ms; a
  slower cleanup is deferred (`websocket control path failed phase=terminate
  reason=cleanup_deferred`) and finishes on its own. A socket whose client the
  test never closed terminates only when the test process exits. Either way
  the cleanup could run after the test, outside its log capture and after its
  sandbox owner stopped, and fail on a database `OwnershipError`
  (findings#206, row 206-28).

  `install!/1`, called from the test process before the first socket starts,
  records every socket of the test's own listeners (a `[:bandit, :websocket,
  :start]` process whose ancestors include a registered server), every
  deferred cleanup (the process that emitted the `cleanup_deferred` failure)
  and every finished cleanup (`[:codex_pooler, :gateway, :websocket_control,
  :cleanup_finished]`, whose `caller` is the terminating socket). Its
  `on_exit` callback, which runs before the sandbox owner stops because it is
  registered after it, waits within a bounded budget until every recorded
  socket has terminated and every deferred cleanup has finished, and fails the
  test if a deferred cleanup never finishes.

  Teardown runs inside a log capture that starts when the test process exits
  (or when the callback starts, if that comes first) and ends after the wait. A
  `cleanup_deferred` warning and info lines emitted in it are expected teardown
  output (the fence has just proven that cleanup finished under a live
  sandbox); every other captured line is written through unchanged, so teardown
  warnings stay as visible as before. Between the end of ExUnit's own capture
  of the test and that callback, the supervisor shutdown and every `on_exit`
  registered after the fence run with no capture active, so a socket they stop
  used to print its `cleanup_deferred` warning to the console (findings#254 row
  254-23). A holder process therefore keeps a discarding capture open from
  `install!/1` until the teardown capture is collected: ExUnit's console
  handler stays detached across that window, and the only lines dropped are
  those emitted between the end of the test's own capture and the test
  process's exit. The callback returns only after the holder has closed both
  captures, so the handler swap that brings the console handler back has
  finished before any `on_exit` registered before the fence runs (findings#206
  row 206-160).
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @installed_key {__MODULE__, :installed}
  @budget_ms 15_000
  @poll_ms 10
  # How long the holder keeps its captures once teardown began and nobody
  # collects them; well beyond the fence's own budget.
  @collect_timeout_ms 120_000
  @deferred_line ~r/\[warning\] websocket control path failed phase=terminate reason=cleanup_deferred/

  @doc "Installs the fence for the calling test once; registers `server` as one of its listeners."
  @spec install!(keyword()) :: :ok
  def install!(opts \\ []) do
    case Process.get(@installed_key) || start_fence() do
      :not_a_test_process ->
        :ok

      fence ->
        case Keyword.get(opts, :server) do
          server when is_pid(server) -> Agent.update(fence, &Map.update!(&1, :servers, fn servers -> [server | servers] end))
          _none -> :ok
        end
    end
  end

  # A fixture built inside a helper task (not the test process) cannot register
  # an on_exit callback; that call installs no fence and the test's own one, if
  # any, still covers it.
  defp start_fence do
    {:ok, fence} = Agent.start(fn -> %{servers: [], sockets: MapSet.new(), deferred: MapSet.new(), finished: MapSet.new(), holder: nil} end)
    handler_id = "websocket-cleanup-fence-#{System.unique_integer([:positive])}"

    try do
      # Registered before attachment so a failure below still detaches and stops.
      ExUnit.Callbacks.on_exit(fn -> await_and_release(fence, handler_id) end)
      Agent.update(fence, &Map.put(&1, :holder, start_holder!(self())))
      attach_fence!(fence, handler_id)
    rescue
      ArgumentError ->
        Agent.stop(fence)
        :not_a_test_process
    end
  end

  # Unlinked and unsupervised on purpose: it must outlive the test process and
  # the test supervisor's shutdown, which is exactly the window it covers.
  defp start_holder!(test_pid) do
    installer = self()
    holder = spawn(fn -> hold(test_pid, installer) end)
    holder_ref = Process.monitor(holder)

    receive do
      {^holder, :holding} ->
        Process.demonitor(holder_ref, [:flush])
        holder

      {:DOWN, ^holder_ref, :process, ^holder, reason} ->
        raise "websocket cleanup fence log holder failed to start: #{inspect(reason)}"
    end
  end

  # The outer capture only keeps ExUnit's console handler detached and is
  # discarded (its level lets nothing through to formatting). The teardown
  # capture starts at the test process's exit or at the callback's request.
  #
  # The collector gets its log only after both captures are closed. Closing
  # the last capture makes ExUnit swap its handler for the console one through
  # `:logger.remove_handler/1`, which snapshots the primary config, global
  # level included, and writes that snapshot back after an asynchronous step.
  # Answered before the swap, the callback went on to the `on_exit` callbacks
  # registered before the fence, and a test that restored the level there
  # (`Logger.configure(level: previous)` after raising it to `:info`) could
  # have that restore overwritten by the stale snapshot, leaving every later
  # test of the partition at `:info` (findings#206 row 206-160).
  defp hold(test_pid, installer) do
    test_ref = Process.monitor(test_pid)

    {{collector, log}, _discarded} =
      ExUnit.CaptureLog.with_log([level: :emergency], fn ->
        send(installer, {self(), :holding})

        first =
          receive do
            {:DOWN, ^test_ref, :process, ^test_pid, _reason} -> nil
            {:start_teardown, from, ref} -> {from, ref}
          end

        ExUnit.CaptureLog.with_log([level: :info], fn ->
          acknowledge_teardown(first)
          await_collect()
        end)
      end)

    case collector do
      {from, ref} -> send(from, {ref, log})
      :expired -> pass_through_unexpected(log)
    end
  end

  defp acknowledge_teardown(nil), do: :ok
  defp acknowledge_teardown({from, ref}), do: send(from, {ref, :capturing})

  defp await_collect do
    receive do
      {:start_teardown, from, ref} ->
        acknowledge_teardown({from, ref})
        await_collect()

      {:collect, from, ref} ->
        {from, ref}
    after
      @collect_timeout_ms -> :expired
    end
  end

  defp holder_call(holder, message) do
    ref = Process.monitor(holder)
    send(holder, {message, self(), ref})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, :process, ^holder, reason} ->
        flunk("websocket cleanup fence log holder exited: #{inspect(reason)}")
    after
      @collect_timeout_ms -> flunk("websocket cleanup fence log holder did not answer #{inspect(message)}")
    end
  end

  defp attach_fence!(fence, handler_id) do
    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:bandit, :websocket, :start],
          [:codex_pooler, :gateway, :websocket_control, :failure],
          [:codex_pooler, :gateway, :websocket_control, :cleanup_finished]
        ],
        &__MODULE__.handle_event/4,
        fence
      )

    Process.put(@installed_key, fence)
    fence
  end

  @doc false
  def handle_event([:bandit, :websocket, :start], _measurements, _metadata, fence) do
    socket = self()
    ancestors = Process.get(:"$ancestors", [])

    Agent.cast(fence, fn state ->
      if Enum.any?(state.servers, &(&1 in ancestors)),
        do: %{state | sockets: MapSet.put(state.sockets, socket)},
        else: state
    end)
  end

  def handle_event([:codex_pooler, :gateway, :websocket_control, :failure], _measurements, %{phase: :terminate, reason: :cleanup_deferred}, fence) do
    caller = self()
    Agent.cast(fence, &%{&1 | deferred: MapSet.put(&1.deferred, caller)})
  end

  def handle_event([:codex_pooler, :gateway, :websocket_control, :cleanup_finished], _measurements, %{caller: caller}, fence) do
    Agent.cast(fence, &%{&1 | finished: MapSet.put(&1.finished, caller)})
  end

  def handle_event(_event, _measurements, _metadata, _fence), do: :ok

  defp await_and_release(fence, handler_id) do
    deadline = System.monotonic_time(:millisecond) + @budget_ms

    {result, log} =
      case Agent.get(fence, & &1.holder) do
        nil ->
          ExUnit.CaptureLog.with_log([level: :info], fn -> await(fence, deadline) end)

        holder ->
          :capturing = holder_call(holder, :start_teardown)
          result = await(fence, deadline)
          {result, holder_call(holder, :collect)}
      end

    :telemetry.detach(handler_id)
    Agent.stop(fence)
    pass_through_unexpected(log)

    case result do
      :ok -> :ok
      {:unfinished, count} -> flunk("#{count} deferred websocket termination cleanup(s) did not finish within #{@budget_ms} ms")
    end
  end

  defp await(fence, deadline) do
    state = Agent.get(fence, & &1)
    live_sockets = Enum.filter(state.sockets, &Process.alive?/1)
    unfinished = MapSet.difference(state.deferred, state.finished)

    cond do
      live_sockets == [] and MapSet.size(unfinished) == 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        # A socket whose client outlives the test is left to the listener's
        # own shutdown; a cleanup that was deferred and never finished is not.
        if MapSet.size(unfinished) == 0, do: :ok, else: {:unfinished, MapSet.size(unfinished)}

      true ->
        receive do
        after
          @poll_ms -> await(fence, deadline)
        end
    end
  end

  defp pass_through_unexpected(log) do
    log
    |> String.split("\n", trim: true)
    |> Enum.chunk_while([], &chunk_log_line/2, &flush_chunk/1)
    |> Enum.reject(&expected_teardown_entry?/1)
    |> Enum.each(&IO.puts/1)
  end

  # A log entry starts with its timestamp; continuation lines (stack traces)
  # belong to the entry above them.
  defp chunk_log_line(line, []), do: {:cont, [line]}

  defp chunk_log_line(line, acc) do
    if Regex.match?(~r/^\d{2}:\d{2}:\d{2}\.\d{3} \[/, line),
      do: {:cont, acc |> Enum.reverse() |> Enum.join("\n"), [line]},
      else: {:cont, [line | acc]}
  end

  defp flush_chunk([]), do: {:cont, []}
  defp flush_chunk(acc), do: {:cont, acc |> Enum.reverse() |> Enum.join("\n"), []}

  defp expected_teardown_entry?(entry),
    do: Regex.match?(@deferred_line, entry) or String.contains?(entry, "[info]") or String.contains?(entry, "[debug]")

  @doc """
  Calls `CodexResponsesSocket.terminate/2` from the calling process and returns
  its result only once that call's session cleanup has finished, so rows,
  owner state and log lines the cleanup writes can be read next (findings#206
  rows 206-341/206-345). A cleanup slower than the 100 ms yield is deferred and
  keeps running after `terminate/2` returns; this waits for its
  `cleanup_finished` event (`caller` is the calling process) within the
  detection budget. Call it inside a log capture to capture the cleanup's lines.
  """
  @spec terminate_and_await!(term(), map()) :: :ok
  def terminate_and_await!(reason, state) do
    caller = self()
    tag = make_ref()
    handler_id = {__MODULE__, :terminate_and_await, tag}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :websocket_control, :cleanup_finished],
        fn _event, _measurements, metadata, _config ->
          if metadata.caller == caller, do: send(caller, {tag, :cleanup_finished})
        end,
        nil
      )

    try do
      result = CodexPoolerWeb.CodexResponsesSocket.terminate(reason, state)

      receive do
        {^tag, :cleanup_finished} -> result
      after
        @budget_ms -> flunk("websocket session cleanup did not finish within #{@budget_ms} ms of terminate/2")
      end
    after
      :telemetry.detach(handler_id)
    end
  end

  @doc """
  Counts the sockets of the calling test's registered listeners whose session
  cleanup has finished (`cleanup_finished` with the socket as `caller`).

  A wire socket's cleanup runs in its own process, after the client closed
  it; read this before the socket that is about to close was opened, and wait
  for one more with `await_listener_socket_cleanups!/1` (findings#206 row
  206-425).
  """
  @spec listener_socket_cleanups() :: non_neg_integer()
  def listener_socket_cleanups do
    state = Agent.get(installed_fence!(), & &1)
    state.sockets |> MapSet.intersection(state.finished) |> MapSet.size()
  end

  @doc """
  Waits, within the detection budget, until at least `count` sockets of the
  calling test's registered listeners have finished their session cleanup,
  deferred or not, and fails the test otherwise.
  """
  @spec await_listener_socket_cleanups!(non_neg_integer()) :: :ok
  def await_listener_socket_cleanups!(count) when is_integer(count) and count >= 0 do
    await_listener_socket_cleanups(count, System.monotonic_time(:millisecond) + @budget_ms)
  end

  defp await_listener_socket_cleanups(count, deadline) do
    cond do
      listener_socket_cleanups() >= count ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("#{count - listener_socket_cleanups()} listener socket cleanup(s) did not finish within #{@budget_ms} ms")

      true ->
        receive do
        after
          @poll_ms -> await_listener_socket_cleanups(count, deadline)
        end
    end
  end

  defp installed_fence! do
    case Process.get(@installed_key) do
      fence when is_pid(fence) -> fence
      nil -> flunk("the websocket cleanup fence is not installed in this process; start the listener with start_public_endpoint_with_server!/0")
    end
  end

  @doc """
  Waits until no websocket session cleanup task is in flight, within the
  detection budget, and fails the caller if one is still running then.

  `DataCase.stop_sandbox/2` calls it before it stops the sandbox owner, so it
  applies to every test, not only to those that `install!/1` the fence: a
  cleanup deferred past the 100 ms yield of `terminate/2`, whose socket or
  test did not wait for it, used to reach its first query after the owner
  stopped, fail on a sandbox `OwnershipError` (`websocket control path failed
  phase=terminate reason=exception`) and lose its writes (findings#206 row
  206-405). A cleanup task is a child of the websocket task supervisor that
  `WebsocketControlPath.cleanup/1` started; the set is read again after each
  wait, so a socket still terminating while this runs is covered once its
  cleanup started. Lines logged during the wait are handled like the fence's
  teardown capture: the `cleanup_deferred` warning and info lines are
  dropped, every other line is written through.
  """
  @spec await_session_cleanups!() :: :ok
  def await_session_cleanups! do
    case session_cleanup_tasks() do
      [] ->
        :ok

      tasks ->
        deadline = System.monotonic_time(:millisecond) + @budget_ms
        {result, log} = ExUnit.CaptureLog.with_log([level: :info], fn -> await_session_cleanups(tasks, deadline) end)
        pass_through_unexpected(log)

        case result do
          :ok -> :ok
          {:unfinished, count} -> flunk("#{count} websocket session cleanup(s) still running #{@budget_ms} ms before the sandbox owner stops")
        end
    end
  end

  defp await_session_cleanups([], deadline) do
    case session_cleanup_tasks() do
      [] -> :ok
      tasks -> await_session_cleanups(tasks, deadline)
    end
  end

  defp await_session_cleanups([task | rest] = tasks, deadline) do
    monitor = Process.monitor(task)

    receive do
      {:DOWN, ^monitor, :process, ^task, _reason} -> await_session_cleanups(rest, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Process.demonitor(monitor, [:flush])
        {:unfinished, length(tasks)}
    end
  end

  # `WebsocketControlPath.cleanup/1` runs its operation in a task of this
  # supervisor; the task's initial call is the anonymous function of that
  # module (`run/2`, the module's other entry point, runs in the caller).
  defp session_cleanup_tasks do
    supervisor = CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.TaskSupervisor

    if Process.whereis(supervisor) do
      supervisor
      |> Task.Supervisor.children()
      |> Enum.filter(&session_cleanup_task?/1)
    else
      []
    end
  end

  defp session_cleanup_task?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> match?({CodexPoolerWeb.WebsocketControlPath, _function, _arity}, Keyword.get(dictionary, :"$initial_call"))
      nil -> false
    end
  end

  @doc """
  Removes the `cleanup_deferred` warning from captured logs. That line records
  only that the session cleanup outlasted the 100 ms yield, which scheduling
  alone decides; a test asserting that a path stays quiet asserts on the rest,
  after awaiting the cleanup with `terminate_and_await!/2`.
  """
  @spec without_deferred_cleanup(String.t()) :: String.t()
  def without_deferred_cleanup(logs) when is_binary(logs) do
    logs
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(@deferred_line, &1))
    |> Enum.join("\n")
  end
end
