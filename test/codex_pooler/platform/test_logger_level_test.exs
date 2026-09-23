defmodule CodexPooler.TestLoggerLevelTest do
  use ExUnit.Case, async: false

  alias CodexPooler.TestLoggerLevel

  @slow_handler :test_logger_level_test_slow_config
  @removed_handler :test_logger_level_test_removed
  @detection_timeout_ms 5_000

  # A handler whose configuration change holds `:logger`'s one-at-a-time
  # handler-operation queue until the test releases it. It turns the narrow
  # race between a removal's stale primary write and a later level restore
  # into an ordered one, without writing the primary config itself.
  @doc false
  def log(_event, _config), do: :ok

  @doc false
  def changing_config(_set_or_update, _old_config, %{config: %{hold: pid}} = new_config) do
    send(pid, {__MODULE__, :holding, self()})

    receive do
      {__MODULE__, :release} -> {:ok, new_config}
    after
      @detection_timeout_ms -> {:ok, new_config}
    end
  end

  def changing_config(_set_or_update, _old_config, new_config), do: {:ok, new_config}

  # A removal requested while a test had raised the level to `:info` writes
  # `:info` back when it runs, after the test's restore (findings#206 rows
  # 206-160 and 206-162). The case templates call `reset!/0` before every sync
  # test, so that write lands before the next test's configured level.
  test "reset! re-applies the configured level after a queued removal's stale write" do
    configured_level = TestLoggerLevel.configured_level()
    parent = self()

    on_exit(fn ->
      _removed = :logger.remove_handler(@slow_handler)
      _removed = :logger.remove_handler(@removed_handler)
      Logger.configure(level: configured_level)
    end)

    :ok = :logger.add_handler(@slow_handler, __MODULE__, %{level: :none, config: %{}})
    :ok = :logger.add_handler(@removed_handler, __MODULE__, %{level: :none})

    spawn(fn -> :logger.update_handler_config(@slow_handler, :config, %{hold: parent}) end)
    assert_receive {__MODULE__, :holding, change_pid}, @detection_timeout_ms

    # A test raised the level; a capture closing now requests a removal that
    # snapshots `:info`, and the test's restore runs while it is queued.
    Logger.configure(level: :info)
    removal = Task.async(fn -> :logger.remove_handler(@removed_handler) end)
    await_logger_call_queued!(removal.pid)
    Logger.configure(level: configured_level)

    reset = Task.async(fn -> TestLoggerLevel.reset!() end)
    await_logger_call_queued!(reset.pid)

    send(change_pid, {__MODULE__, :release})

    assert :ok = Task.await(reset, @detection_timeout_ms)
    assert :ok = Task.await(removal, @detection_timeout_ms)
    refute @removed_handler in :logger.get_handler_ids()
    assert Logger.level() == configured_level
  end

  # `:logger` answers `:sys.get_state/1` only after the call the waiting
  # process sent before it, so the call has been accepted (and a removal has
  # taken its snapshot) when this returns. A process that already finished
  # made no call that is still queued.
  defp await_logger_call_queued!(pid) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    await_waiting!(pid, deadline)
    _state = :sys.get_state(:logger)
    :ok
  end

  defp await_waiting!(pid, deadline) do
    case Process.info(pid, [:status, :current_function]) do
      [status: :waiting, current_function: {:gen, _function, _arity}] ->
        :ok

      nil ->
        :ok

      _other ->
        if System.monotonic_time(:millisecond) >= deadline, do: flunk("the logger call was not observed waiting")
        Process.sleep(1)
        await_waiting!(pid, deadline)
    end
  end
end
