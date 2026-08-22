defmodule CodexPooler.Gateway.Websocket.ResponseTask do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry

  @type activity_kind :: :direct | :proxy | :local_owner
  @type run_callback :: (pid() -> term())
  @type cancel_callback :: (pid(), :owner_drained -> term())
  @type activity_token :: reference()

  @spec start(pid(), activity_kind(), run_callback(), cancel_callback(), keyword()) ::
          {:ok, pid()}
  def start(parent, kind, run_callback, cancel_callback, opts \\ [])
      when is_pid(parent) and kind in [:direct, :proxy, :local_owner] and
             is_function(run_callback, 1) and is_function(cancel_callback, 2) do
    Task.start(fn ->
      Process.flag(:sensitive, true)

      case kind do
        :local_owner ->
          send(parent, {:codex_response_done, self(), run_callback.(self())})

        tracked_kind ->
          run_tracked(parent, tracked_kind, run_callback, cancel_callback, opts)
      end
    end)
  end

  @spec acknowledge_delivery(pid(), activity_token()) :: :ok
  def acknowledge_delivery(task_pid, token) when is_pid(task_pid) and is_reference(token) do
    send(task_pid, {:websocket_response_delivery_ack, token})
    :ok
  end

  defp run_tracked(parent, kind, run_callback, cancel_callback, opts) do
    registry = Keyword.get(opts, :activity_registry, ActivityRegistry)

    with {:ok, token} <- ActivityRegistry.register(kind, self(), name: registry) do
      case ActivityRegistry.admit(token, name: registry) do
        :ok ->
          run_admitted(parent, token, registry, run_callback, cancel_callback)

        {:error, :owner_drained} ->
          :ok = ActivityRegistry.unregister(token, :aborted, name: registry)
          send(parent, {:codex_response_done, self(), {:error, :owner_drained}})
      end
    end
  end

  defp run_admitted(parent, token, registry, run_callback, cancel_callback) do
    coordinator = self()
    worker_ref = make_ref()

    {worker, monitor} =
      spawn_monitor(fn -> send(coordinator, {worker_ref, run_callback.(coordinator)}) end)

    receive do
      {^worker_ref, result} ->
        Process.demonitor(monitor, [:flush])
        send(parent, {:websocket_response_activity, coordinator, token})
        send(parent, {:codex_response_done, coordinator, result})
        await_delivery(parent, token, registry, cancel_callback, :completed)

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        result = {:error, :websocket_response_task_failed}
        send(parent, {:websocket_response_activity, coordinator, token})
        send(parent, {:codex_response_done, coordinator, result})
        await_delivery(parent, token, registry, cancel_callback, :failed)

      {:websocket_activity_cancel, ^token, :owner_drained} ->
        cancel_result = cancel_callback.(coordinator, :owner_drained)
        settle_cancelled_worker(cancel_result, worker_ref, monitor, worker)
        :ok = ActivityRegistry.unregister(token, :aborted, name: registry)
        send(parent, {:codex_response_done, coordinator, {:error, :owner_drained}})
    end
  end

  defp await_delivery(parent, token, registry, cancel_callback, outcome) do
    receive do
      {:websocket_response_delivery_ack, ^token} ->
        :ok = ActivityRegistry.unregister(token, outcome, name: registry)

      {:websocket_activity_cancel, ^token, :owner_drained} ->
        _cancel_result = cancel_callback.(self(), :owner_drained)
        send(parent, {:websocket_response_activity_cancelled, self(), token, :owner_drained})
        await_delivery(parent, token, registry, cancel_callback, :aborted)
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
