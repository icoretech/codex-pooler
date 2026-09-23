defmodule CodexPooler.TestLoggerLevel do
  @moduledoc """
  Re-establishes the suite's configured Logger level at the start of every
  sync case-template test, once the `:logger` handler operations already
  requested have finished.

  ExUnit's `CaptureServer` swaps its capture handler and the console
  `:default` handler through `:logger.remove_handler/1` when the number of open
  captures goes from 0 to 1 or from 1 to 0. OTP's `logger_server` snapshots the
  primary config, level included, when a removal is requested and writes that
  snapshot back once the removal's asynchronous step has run, so a
  `Logger.configure(level: ...)` landing in between is lost. A capture that
  closes asynchronously (a capturing process killed by a test timeout or a
  linked crash, a spawned process killed inside `with_log` from an `on_exit`,
  a capture holder that expires) can therefore overwrite a test's level
  restore with the level the test had raised. Every later test would then
  capture the lines the configured level filters out (findings#206 rows
  206-160 and 206-162).

  `reset!/0` sends an empty configuration update to its own handler. The
  server runs handler additions, removals and configuration changes one at a
  time, so the reply means every removal requested before it has written its
  snapshot; the configured level set afterwards is the last write. It does not
  replace restoring a level a test raised: a test still restores it in its own
  `on_exit`, and this only stops a lost restore from reaching the next test.
  """

  @barrier_handler :codex_pooler_test_logger_level_barrier

  @doc "The level `config :logger` configures for the suite."
  @spec configured_level() :: Logger.level()
  def configured_level, do: Application.fetch_env!(:logger, :level)

  @doc """
  Waits for the handler operations already requested, then sets the
  configured level.
  """
  @spec reset!() :: :ok
  def reset! do
    :ok = barrier!()
    Logger.configure(level: configured_level())
  end

  defp barrier! do
    case :logger.update_handler_config(@barrier_handler, :config, %{}) do
      :ok ->
        :ok

      {:error, {:not_found, @barrier_handler}} ->
        # The addition queues behind the pending operations just like an update.
        case :logger.add_handler(@barrier_handler, __MODULE__, %{level: :none}) do
          :ok -> :ok
          {:error, {:already_exist, @barrier_handler}} -> barrier!()
        end
    end
  end

  @doc false
  def log(_event, _config), do: :ok
end
