defmodule CodexPooler.Gateway.Websocket.ResponseTask do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionTrace

  @type activity_kind :: :direct | :proxy | :local_owner
  @type run_callback :: (pid() -> term())
  @type cancel_callback :: (pid(), :owner_drained -> term())
  @type activity_token :: reference()

  @spec start(pid(), activity_kind(), run_callback(), cancel_callback(), keyword()) ::
          {:ok, pid()}
  def start(parent, kind, run_callback, cancel_callback, opts \\ [])
      when is_pid(parent) and kind in [:direct, :proxy, :local_owner] and
             is_function(run_callback, 1) and is_function(cancel_callback, 2) do
    opts = Keyword.put(opts, :direct_cleanup_starter, self())

    result =
      Task.start(fn ->
        sensitivity = NativeCompactionTrace.configure_process_sensitivity(:response_task)
        _trace = NativeCompactionTrace.enroll(:response_task, self())

        try do
          case kind do
            :local_owner ->
              run_local_owner(parent, run_callback, opts)

            tracked_kind ->
              run_tracked(parent, tracked_kind, run_callback, cancel_callback, opts)
          end
        after
          NativeCompactionTrace.restore_process_sensitivity(sensitivity)
        end
      end)

    await_direct_registration(result, kind, Keyword.get(opts, :direct_cleanup_ref))
  end

  defp await_direct_registration({:ok, pid} = result, kind, ref)
       when kind in [:direct, :local_owner] and is_reference(ref) do
    monitor = Process.monitor(pid)

    receive do
      {:direct_cleanup_registered, ^pid, ^ref} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        result
    after
      15_000 ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :kill)
        result
    end
  end

  defp await_direct_registration(result, _kind, _ref), do: result

  defp run_local_owner(parent, run_callback, opts) do
    registry = Keyword.get(opts, :activity_registry, ActivityRegistry)

    {:ok, token} =
      ActivityRegistry.register(:local_owner, self(),
        name: registry,
        direct_cleanup_ref: Keyword.get(opts, :direct_cleanup_ref),
        direct_cleanup_parent: parent
      )

    if ref = Keyword.get(opts, :direct_cleanup_ref),
      do:
        send(
          Keyword.fetch!(opts, :direct_cleanup_starter),
          {:direct_cleanup_registered, self(), ref}
        )

    result =
      try do
        case ActivityRegistry.admit(token, name: registry) do
          :ok -> run_callback.(self())
          {:error, :owner_drained} -> {:error, :owner_drained}
        end
      after
        ActivityRegistry.unregister(token, :completed, name: registry)
      end

    run_before_local_completion_handoff(Keyword.get(opts, :before_local_completion_handoff))
    complete_local_owner(parent, result)
  end

  @spec acknowledge_delivery(pid(), activity_token()) :: :ok
  def acknowledge_delivery(task_pid, token) when is_pid(task_pid) and is_reference(token) do
    send(task_pid, {:websocket_response_delivery_ack, token})
    :ok
  end

  @spec acknowledge_delivery(pid(), activity_token(), :completed | :aborted) :: :ok
  def acknowledge_delivery(task_pid, token, outcome)
      when is_pid(task_pid) and is_reference(token) and outcome in [:completed, :aborted] do
    send(task_pid, {:websocket_response_delivery_ack, token, outcome})
    :ok
  end

  defp run_tracked(parent, kind, run_callback, cancel_callback, opts) do
    registry = Keyword.get(opts, :activity_registry, ActivityRegistry)

    registration = [
      name: registry,
      direct_cleanup_ref: Keyword.get(opts, :direct_cleanup_ref),
      direct_cleanup_parent: parent
    ]

    with {:ok, token} <- ActivityRegistry.register(kind, self(), registration) do
      if kind == :direct and is_reference(Keyword.get(opts, :direct_cleanup_ref)),
        do:
          send(
            Keyword.fetch!(opts, :direct_cleanup_starter),
            {:direct_cleanup_registered, self(), Keyword.fetch!(opts, :direct_cleanup_ref)}
          )

      case ActivityRegistry.admit(token, name: registry) do
        :ok ->
          run_admitted(parent, token, registry, run_callback, cancel_callback, opts)

        {:error, :owner_drained} ->
          :ok = ActivityRegistry.unregister(token, :aborted, name: registry)
          send(parent, {:codex_response_done, self(), {:error, :owner_drained}})
      end
    end
  end

  defp run_admitted(parent, token, registry, run_callback, cancel_callback, opts) do
    coordinator = self()

    run_before_cancel_recipient_handoff(
      Keyword.get(opts, :before_cancel_recipient_handoff),
      token
    )

    watcher =
      start_cancellation_watcher(
        parent,
        coordinator,
        token,
        registry,
        cancel_callback,
        Keyword.get(opts, :before_cancelled_coordinator_termination)
      )

    :ok = ActivityRegistry.set_cancel_recipient(token, watcher, name: registry)

    case settle_admission_cancellation(token, registry, watcher) do
      :active ->
        run_callback_and_await_delivery(
          parent,
          coordinator,
          token,
          watcher,
          registry,
          run_callback,
          cancel_callback,
          opts
        )

      :cancelled ->
        :ok
    end
  end

  defp run_callback_and_await_delivery(
         parent,
         coordinator,
         token,
         watcher,
         registry,
         run_callback,
         cancel_callback,
         opts
       ) do
    {outcome, result} = run_callback_result(run_callback, coordinator)
    run_before_completion_handoff(Keyword.get(opts, :before_completion_handoff), token, watcher)

    case ActivityRegistry.handoff_cancel_recipient(
           token,
           watcher,
           coordinator,
           name: registry
         ) do
      :ok ->
        stop_cancellation_watcher(watcher, token)
        send(parent, {:websocket_response_activity, coordinator, token})
        send(parent, {:codex_response_done, coordinator, result})
        await_delivery(parent, token, registry, cancel_callback, outcome)

      {:cancelled, :owner_drained, ^watcher} ->
        receive do
          {:websocket_response_cancellation_settled, ^token} -> :ok
        end
    end
  end

  defp settle_admission_cancellation(token, registry, watcher) do
    case ActivityRegistry.status(token, name: registry) do
      {:active, :cancelling} ->
        forward_queued_admission_cancellation(token, watcher)

        receive do
          {:websocket_response_cancellation_settled, ^token} -> :cancelled
        end

      {:active, _status} ->
        :active

      {:finished, _outcome} ->
        :cancelled

      :unknown ->
        :cancelled
    end
  end

  defp forward_queued_admission_cancellation(token, watcher) do
    receive do
      {:websocket_activity_cancel, ^token, :owner_drained} ->
        send(watcher, {:websocket_activity_cancel, token, :owner_drained, :pre_dispatch})
    after
      0 -> :ok
    end
  end

  defp run_before_cancel_recipient_handoff(callback, token) when is_function(callback, 1),
    do: callback.(token)

  defp run_before_cancel_recipient_handoff(_callback, _token), do: :ok

  defp run_before_completion_handoff(callback, token, watcher) when is_function(callback, 2),
    do: callback.(token, watcher)

  defp run_before_completion_handoff(_callback, _token, _watcher), do: :ok

  defp run_before_local_completion_handoff(callback) when is_function(callback, 0),
    do: callback.()

  defp run_before_local_completion_handoff(_callback), do: :ok

  defp complete_local_owner(
         parent,
         {:socket_response_result, :owner_completion_pending, :ok} = result
       ) do
    token = make_ref()
    # No registry entry tracks this task, so a socket that dies without
    # acknowledging would otherwise leave it parked forever.
    parent_monitor = Process.monitor(parent)
    send(parent, {:websocket_response_activity, self(), token})
    send(parent, {:codex_response_done, self(), result})

    receive do
      {:websocket_response_delivery_ack, ^token, outcome}
      when outcome in [:completed, :aborted] ->
        Process.demonitor(parent_monitor, [:flush])
        :ok

      {:websocket_response_delivery_ack, ^token} ->
        Process.demonitor(parent_monitor, [:flush])
        :ok

      {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
        :ok
    end
  end

  defp complete_local_owner(parent, result),
    do: send(parent, {:codex_response_done, self(), result})

  defp run_callback_result(run_callback, coordinator) do
    {:completed, run_callback.(coordinator)}
  rescue
    _exception -> {:failed, {:error, :websocket_response_task_failed}}
  catch
    _kind, _reason -> {:failed, {:error, :websocket_response_task_failed}}
  end

  defp start_cancellation_watcher(
         parent,
         coordinator,
         token,
         registry,
         cancel_callback,
         before_cancelled_coordinator_termination
       ) do
    spawn(fn ->
      monitor = Process.monitor(coordinator)

      receive do
        {:websocket_activity_cancel, ^token, :owner_drained, :pre_dispatch} ->
          settle_cancellation(
            parent,
            coordinator,
            token,
            registry,
            cancel_callback,
            false,
            before_cancelled_coordinator_termination
          )

        {:websocket_activity_cancel, ^token, :owner_drained} ->
          settle_cancellation(
            parent,
            coordinator,
            token,
            registry,
            cancel_callback,
            true,
            before_cancelled_coordinator_termination
          )

        {:websocket_response_cancel_watcher_stop, ^token} ->
          Process.demonitor(monitor, [:flush])

        {:DOWN, ^monitor, :process, ^coordinator, _reason} ->
          :ok
      end
    end)
  end

  defp settle_cancellation(
         parent,
         coordinator,
         token,
         registry,
         cancel_callback,
         kill_coordinator?,
         before_cancelled_coordinator_termination
       ) do
    _cancel_result = cancel_callback.(coordinator, :owner_drained)
    send(parent, {:websocket_response_activity, coordinator, token})

    send(
      parent,
      {:websocket_response_activity_cancelled, coordinator, token, self(), :owner_drained}
    )

    # A socket that dies without running its acknowledging callback or
    # terminate/2 never delivers the owner_drained terminal, so its death
    # settles the cancellation as undelivered instead of parking this watcher.
    parent_monitor = Process.monitor(parent)

    delivery =
      receive do
        {:websocket_response_delivery_ack, ^token, :completed} -> :completed
        {:websocket_response_delivery_ack, ^token, :aborted} -> :aborted
        {:websocket_response_delivery_ack, ^token} -> :aborted
        {:DOWN, ^parent_monitor, :process, ^parent, _reason} -> :aborted
      end

    Process.demonitor(parent_monitor, [:flush])

    case delivery do
      :completed ->
        :ok = ActivityRegistry.complete(token, :completed, name: registry)
        send(coordinator, {:websocket_response_cancellation_settled, token})

      :aborted ->
        settle_aborted_cancellation(
          parent,
          coordinator,
          token,
          registry,
          kill_coordinator?,
          before_cancelled_coordinator_termination
        )
    end
  end

  defp settle_aborted_cancellation(
         parent,
         coordinator,
         token,
         registry,
         kill_coordinator?,
         before_termination
       ) do
    :ok = ActivityRegistry.complete(token, :aborted, name: registry)
    send(parent, {:codex_response_done, coordinator, {:error, :owner_drained}})

    if kill_coordinator? do
      run_before_cancelled_coordinator_termination(before_termination, token, coordinator)
      Process.exit(coordinator, :kill)
    else
      send(coordinator, {:websocket_response_cancellation_settled, token})
    end
  end

  defp run_before_cancelled_coordinator_termination(callback, token, coordinator)
       when is_function(callback, 2),
       do: callback.(token, coordinator)

  defp run_before_cancelled_coordinator_termination(_callback, _token, _coordinator), do: :ok

  defp stop_cancellation_watcher(watcher, token) do
    send(watcher, {:websocket_response_cancel_watcher_stop, token})
    :ok
  end

  # The socket acknowledges delivery from its callback loop or terminate/2. A
  # socket that dies without running either (a handler crash or a brutal
  # shutdown kill) would leave this task parked with its activity still live,
  # so the socket's death settles the activity as undelivered and the task
  # exits. An acknowledgement sent before that death is received first.
  defp await_delivery(parent, token, registry, cancel_callback, outcome) do
    parent_monitor = Process.monitor(parent)
    :ok = await_delivery(parent, parent_monitor, token, registry, cancel_callback, outcome)
    Process.demonitor(parent_monitor, [:flush])
    :ok
  end

  defp await_delivery(parent, parent_monitor, token, registry, cancel_callback, outcome) do
    receive do
      {:websocket_response_delivery_ack, ^token, :completed} ->
        ActivityRegistry.complete(token, :completed, name: registry)

      {:websocket_response_delivery_ack, ^token, :aborted} ->
        ActivityRegistry.complete(token, :aborted, name: registry)

      {:websocket_response_delivery_ack, ^token} ->
        ActivityRegistry.unregister(token, outcome, name: registry)

      {:websocket_activity_cancel, ^token, :owner_drained} ->
        _cancel_result = cancel_callback.(self(), :owner_drained)
        send(parent, {:websocket_response_activity_cancelled, self(), token, :owner_drained})
        await_delivery(parent, parent_monitor, token, registry, cancel_callback, :aborted)

      {:DOWN, ^parent_monitor, :process, ^parent, _reason} ->
        ActivityRegistry.complete(token, :aborted, name: registry)
    end
  end
end
