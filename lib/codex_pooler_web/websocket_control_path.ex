defmodule CodexPoolerWeb.WebsocketControlPath do
  @moduledoc false

  require Logger

  @supervisor CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.TaskSupervisor
  @cleanup_wait_ms 100

  @spec run(:init | :serve | :terminate, (-> result)) :: {:ok, result} | {:error, atom()}
        when result: term()
  def run(phase, operation) when phase in [:init, :serve, :terminate] do
    {:ok, operation.()}
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      failure(phase, :database_error)
      {:error, :database_error}

    _error ->
      failure(phase, :exception)
      {:error, :exception}
  catch
    :exit, _reason ->
      failure(phase, :process_exit)
      {:error, :process_exit}
  end

  # A cleanup that outlives the wait logs its own duration when it finishes,
  # under the socket's request id: the released client retries a failed stream
  # on a new connection about 200 ms after the failure and again about 400 ms
  # later, and what that retry meets depends on this detach (findings#206 row
  # 206-436). `cleanup_deferred` only says the wait ran out.
  @spec cleanup((-> term())) :: :ok
  def cleanup(operation) do
    caller = self()
    metadata = Logger.metadata()

    task =
      Task.Supervisor.async_nolink(@supervisor, fn ->
        started = System.monotonic_time()
        result = run(:terminate, operation)

        :telemetry.execute(
          [:codex_pooler, :gateway, :websocket_control, :cleanup_finished],
          %{count: 1},
          %{caller: caller}
        )

        log_late_cleanup(metadata, System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond))
        result
      end)

    case Task.yield(task, @cleanup_wait_ms) do
      nil ->
        # The supervised task keeps the exact downstream/lease witness. Do not
        # kill and retry it: the database operation may already have committed.
        Task.ignore(task)
        failure(:terminate, :cleanup_deferred)

      {:exit, _reason} ->
        failure(:terminate, :process_exit)

      {:ok, _result} ->
        :ok
    end

    :ok
  catch
    :exit, _reason ->
      failure(:terminate, :process_exit)
      :ok
  end

  defp log_late_cleanup(metadata, elapsed_ms) when elapsed_ms >= @cleanup_wait_ms do
    Logger.metadata(metadata)
    Logger.info("websocket control path deferred cleanup finished elapsed_ms=#{elapsed_ms}")
  end

  defp log_late_cleanup(_metadata, _elapsed_ms), do: :ok

  defp failure(phase, reason) do
    Logger.warning("websocket control path failed phase=#{phase} reason=#{reason}")

    :telemetry.execute(
      [:codex_pooler, :gateway, :websocket_control, :failure],
      %{count: 1},
      %{phase: phase, reason: reason}
    )
  end
end
