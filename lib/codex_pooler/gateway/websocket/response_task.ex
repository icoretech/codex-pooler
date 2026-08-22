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
    watcher = start_cancellation_watcher(parent, coordinator, token, cancel_callback)
    :ok = ActivityRegistry.set_cancel_recipient(token, watcher, name: registry)

    {outcome, result} = run_callback_result(run_callback, coordinator)
    stop_cancellation_watcher(watcher, token)
    :ok = ActivityRegistry.set_cancel_recipient(token, coordinator, name: registry)
    send(parent, {:websocket_response_activity, coordinator, token})
    send(parent, {:codex_response_done, coordinator, result})
    await_delivery(parent, token, registry, cancel_callback, outcome)
  end

  defp run_callback_result(run_callback, coordinator) do
    {:completed, run_callback.(coordinator)}
  rescue
    _exception -> {:failed, {:error, :websocket_response_task_failed}}
  catch
    _kind, _reason -> {:failed, {:error, :websocket_response_task_failed}}
  end

  defp start_cancellation_watcher(parent, coordinator, token, cancel_callback) do
    spawn(fn ->
      monitor = Process.monitor(coordinator)

      receive do
        {:websocket_activity_cancel, ^token, :owner_drained} ->
          _cancel_result = cancel_callback.(coordinator, :owner_drained)

          send(
            parent,
            {:websocket_response_activity_cancelled, coordinator, token, :owner_drained}
          )

          Process.demonitor(monitor, [:flush])

        {:websocket_response_cancel_watcher_stop, ^token} ->
          Process.demonitor(monitor, [:flush])

        {:DOWN, ^monitor, :process, ^coordinator, _reason} ->
          :ok
      end
    end)
  end

  defp stop_cancellation_watcher(watcher, token) do
    send(watcher, {:websocket_response_cancel_watcher_stop, token})
    :ok
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
end
