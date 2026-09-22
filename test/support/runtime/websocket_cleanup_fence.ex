defmodule CodexPoolerWeb.Runtime.WebsocketCleanupFence do
  @moduledoc """
  Holds a test's teardown until every websocket termination cleanup it caused
  has finished.

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

  The wait runs inside a log capture. A `cleanup_deferred` warning and info
  lines emitted while it runs are expected teardown output (the fence has just
  proven that cleanup finished under a live sandbox); every other captured line
  is written through unchanged, so teardown warnings stay as visible as before.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @installed_key {__MODULE__, :installed}
  @budget_ms 15_000
  @poll_ms 10
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
    {:ok, fence} = Agent.start(fn -> %{servers: [], sockets: MapSet.new(), deferred: MapSet.new(), finished: MapSet.new()} end)
    handler_id = "websocket-cleanup-fence-#{System.unique_integer([:positive])}"

    try do
      # Registered before attachment so a failure below still detaches and stops.
      ExUnit.Callbacks.on_exit(fn -> await_and_release(fence, handler_id) end)
      attach_fence!(fence, handler_id)
    rescue
      ArgumentError ->
        Agent.stop(fence)
        :not_a_test_process
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

    {result, log} = ExUnit.CaptureLog.with_log([level: :info], fn -> await(fence, deadline) end)

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
end
