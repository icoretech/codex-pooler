defmodule CodexPooler.Gateway.Websocket.ResponseTask do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry

  @type activity_kind :: :direct | :proxy | :local_owner
  @type run_callback :: (pid() -> term())
  @type cancel_callback :: (pid(), :owner_drained -> term())

  @spec start(pid(), activity_kind(), run_callback(), cancel_callback(), keyword()) ::
          {:ok, pid()}
  def start(parent, kind, run_callback, cancel_callback, opts \\ [])
      when is_pid(parent) and kind in [:direct, :proxy, :local_owner] and
             is_function(run_callback, 1) and is_function(cancel_callback, 2) do
    Task.start(fn ->
      Process.flag(:sensitive, true)
      result = run(kind, run_callback, cancel_callback, opts)
      send(parent, {:codex_response_done, self(), result})
    end)
  end

  defp run(:local_owner, run_callback, _cancel_callback, _opts), do: run_callback.(self())

  defp run(kind, run_callback, cancel_callback, opts) do
    registry = Keyword.get(opts, :activity_registry, ActivityRegistry)

    with {:ok, token} <- ActivityRegistry.register(kind, self(), name: registry) do
      case ActivityRegistry.admit(token, name: registry) do
        :ok ->
          run_admitted(token, registry, run_callback, cancel_callback)

        {:error, :owner_drained} ->
          :ok = ActivityRegistry.unregister(token, :aborted, name: registry)
          {:error, :owner_drained}
      end
    end
  end

  defp run_admitted(token, registry, run_callback, cancel_callback) do
    coordinator = self()
    worker_ref = make_ref()

    {worker, monitor} =
      spawn_monitor(fn -> send(coordinator, {worker_ref, run_callback.(coordinator)}) end)

    receive do
      {^worker_ref, result} ->
        Process.demonitor(monitor, [:flush])
        :ok = ActivityRegistry.unregister(token, :completed, name: registry)
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        :ok = ActivityRegistry.unregister(token, :failed, name: registry)
        {:error, :websocket_response_task_failed}

      {:websocket_activity_cancel, ^token, :owner_drained} ->
        cancel_result = cancel_callback.(coordinator, :owner_drained)
        settle_cancelled_worker(cancel_result, worker_ref, monitor, worker)
        :ok = ActivityRegistry.unregister(token, :aborted, name: registry)
        {:error, :owner_drained}
    end
  end

  defp await_worker_down(monitor, worker) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp settle_cancelled_worker(:await_worker, worker_ref, monitor, worker) do
    receive do
      {^worker_ref, _result} -> Process.demonitor(monitor, [:flush])
      {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
    end
  end

  defp settle_cancelled_worker(_cancel_result, _worker_ref, monitor, worker) do
    Process.exit(worker, :kill)
    await_worker_down(monitor, worker)
  end
end
