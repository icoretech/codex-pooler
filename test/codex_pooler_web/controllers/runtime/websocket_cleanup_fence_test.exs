defmodule CodexPoolerWeb.Runtime.WebsocketCleanupFenceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence
  alias CodexPoolerWeb.WebsocketControlPath

  @slow_handler :websocket_cleanup_fence_test_slow_config
  # Long enough to outlast the fence's release under load; on_exit time is
  # outside the duration guard.
  @slow_change_ms 250
  @detection_timeout_ms 5_000
  @session_cleanup_timeout_ms 15_000

  # A handler whose configuration change is still running when the fence
  # releases. `:logger` runs handler additions, removals and configuration
  # changes one at a time, so the capture handler swap the fence's holder
  # makes on release queues behind this change. A removal snapshots the
  # primary config (global level included) when it is requested and writes
  # that snapshot back when it runs; the queue turns the narrow race between
  # that write and a later level restore into an ordered one. A handler
  # configuration change never writes the primary config itself.
  @doc false
  def log(_event, _config), do: :ok

  @doc false
  def changing_config(_set_or_update, _old_config, %{config: %{notify: pid} = config} = new_config) do
    send(pid, {__MODULE__, :change_started})
    Process.sleep(@slow_change_ms)
    {:ok, %{new_config | config: %{config | phase: :changed}}}
  end

  # A test that raises the global level and restores it in an `on_exit`
  # registered before the fence was left at `:info` when that restore ran
  # while the holder's capture handler swap was still pending: the swap wrote
  # back the level it had snapshotted before the restore (gate wave3h,
  # findings#206 row 206-160). The fence now returns only once its holder has
  # closed both captures, so the swap is over and the console handler is back
  # when the next callback runs, and the restore is the last level write.
  test "the fence release finishes its capture handler swap before earlier on_exit callbacks run" do
    configured_level = Logger.level()

    # Registered first, so it runs last.
    on_exit(fn ->
      settled? = await_handlers_settled(System.monotonic_time(:millisecond) + @detection_timeout_ms)
      level = Logger.level()
      _removed = :logger.remove_handler(@slow_handler)
      Logger.configure(level: configured_level)
      assert settled?, "the logger handler swap did not settle"
      assert level == configured_level
    end)

    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: configured_level) end)

    # Runs right after the fence's release.
    on_exit(fn -> assert :default in :logger.get_handler_ids() end)

    :ok = WebsocketCleanupFence.install!()

    # Registered after the fence, so it runs before the fence's release.
    on_exit(fn -> occupy_handler_queue!() end)
  end

  # `DataCase.stop_sandbox/2` calls it before the owner stops, in every test: a
  # session cleanup deferred past `terminate/2` that outlived its test failed
  # on a sandbox `OwnershipError` and lost its writes (findings#206 row 206-405).
  test "await_session_cleanups!/0 returns only once an in-flight session cleanup has finished" do
    test_pid = self()

    log =
      capture_log(fn ->
        :ok =
          WebsocketControlPath.cleanup(fn ->
            send(test_pid, {:cleanup_started, self()})

            receive do
              :release -> :ok
            end
          end)
      end)

    assert log =~ "phase=terminate reason=cleanup_deferred"
    assert_receive {:cleanup_started, cleanup}, @session_cleanup_timeout_ms
    on_exit(fn -> send(cleanup, :release) end)

    waiter = Task.async(fn -> WebsocketCleanupFence.await_session_cleanups!() end)

    # It found the held cleanup once it monitors it; it must still be waiting.
    assert await_monitored_by(cleanup, waiter.pid, System.monotonic_time(:millisecond) + @session_cleanup_timeout_ms)
    assert Task.yield(waiter, 0) == nil

    send(cleanup, :release)
    assert Task.await(waiter, @session_cleanup_timeout_ms) == :ok
    refute Process.alive?(cleanup)
  end

  defp await_monitored_by(pid, monitor_pid, deadline) do
    monitored_by =
      case Process.info(pid, :monitored_by) do
        {:monitored_by, pids} -> pids
        nil -> []
      end

    cond do
      monitor_pid in monitored_by ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          1 -> await_monitored_by(pid, monitor_pid, deadline)
        end
    end
  end

  defp occupy_handler_queue! do
    notify = self()
    :ok = :logger.add_handler(@slow_handler, __MODULE__, %{config: %{notify: notify, phase: :added}})
    _changer = spawn(fn -> :logger.update_handler_config(@slow_handler, :config, %{notify: notify, phase: :changing}) end)

    receive do
      {__MODULE__, :change_started} -> :ok
    after
      @detection_timeout_ms -> flunk("the slow handler configuration change did not start")
    end
  end

  defp await_handlers_settled(deadline) do
    changed? = match?({:ok, %{config: %{phase: :changed}}}, :logger.get_handler_config(@slow_handler))

    cond do
      changed? and :default in :logger.get_handler_ids() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          10 -> await_handlers_settled(deadline)
        end
    end
  end
end
