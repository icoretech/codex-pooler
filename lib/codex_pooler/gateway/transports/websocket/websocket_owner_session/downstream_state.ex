defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.DownstreamState do
  @moduledoc false

  @spec downstream_status(map() | nil, map()) :: :active | {:error, atom()}
  def downstream_status(nil, _downstream), do: {:error, :stale_downstream}

  def downstream_status(
        %{pid: pid, epoch: epoch, correlation_id: correlation_id},
        %{pid: pid, epoch: epoch, correlation_id: correlation_id}
      ),
      do: :active

  def downstream_status(%{epoch: current_epoch}, %{epoch: epoch})
      when is_integer(epoch) and epoch < current_epoch,
      do: {:error, :duplicate_downstream}

  def downstream_status(_current, _downstream), do: {:error, :stale_downstream}

  @spec active_turn_downstream(map()) :: map() | nil
  def active_turn_downstream(%{active_turn: %{downstream: downstream}}) when is_map(downstream),
    do: downstream

  def active_turn_downstream(state), do: state.downstream

  @spec effective_active_turn_result(map(), term()) :: term()
  def effective_active_turn_result(%{canceled_result: canceled_result}, _result),
    do: canceled_result

  def effective_active_turn_result(_active_turn, result), do: result

  @spec clear_active_turn_monitors(map() | nil) :: :ok
  def clear_active_turn_monitors(active_turn) when is_map(active_turn) do
    active_turn
    |> Map.take([:task_ref, :submitter_monitor])
    |> Map.values()
    |> Enum.each(fn
      ref when is_reference(ref) -> Process.demonitor(ref, [:flush])
      _value -> :ok
    end)

    :ok
  end

  def clear_active_turn_monitors(_active_turn), do: :ok

  @spec put_active_turn_downstream(map(), map()) :: map()
  def put_active_turn_downstream(%{active_turn: active_turn} = state, downstream)
      when is_map(active_turn) and is_map(downstream) do
    if Map.has_key?(active_turn, :canceled_result) do
      state
    else
      %{state | active_turn: %{active_turn | downstream: downstream}}
    end
  end

  def put_active_turn_downstream(state, _downstream), do: state

  @spec cancel_active_turn_downstream(map(), map()) :: map()
  def cancel_active_turn_downstream(%{active_turn: active_turn} = state, downstream)
      when is_map(active_turn) and is_map(downstream) do
    case downstream_status(Map.get(active_turn, :downstream), downstream) do
      :active ->
        cancel_active_turn_task(active_turn)

        %{
          state
          | active_turn:
              active_turn
              |> Map.put(:canceled_result, {:error, :client_disconnected})
              |> Map.put(:downstream, nil)
        }

      {:error, _reason} ->
        state
    end
  end

  def cancel_active_turn_downstream(state, _downstream), do: state

  @spec cancel_active_turn_task(map()) :: :ok
  def cancel_active_turn_task(%{task_pid: task_pid}) when is_pid(task_pid) do
    if Process.alive?(task_pid) do
      Process.exit(task_pid, :shutdown)
    end

    :ok
  end

  def cancel_active_turn_task(_active_turn), do: :ok

  @spec stale_or_busy(map() | nil, map()) :: {:error, atom()}
  def stale_or_busy(current_downstream, downstream) do
    case downstream_status(current_downstream, downstream) do
      :active -> {:error, :owner_busy}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec active_turn?(map()) :: boolean()
  def active_turn?(%{active_turn: active_turn}), do: is_map(active_turn)

  @spec next_downstream_epoch(map() | nil) :: pos_integer()
  def next_downstream_epoch(nil), do: 1
  def next_downstream_epoch(%{epoch: epoch}), do: epoch + 1

  @spec demonitor_downstream(map()) :: map()
  def demonitor_downstream(%{downstream_monitor: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | downstream_monitor: nil}
  end

  def demonitor_downstream(state), do: state

  @spec maybe_schedule_idle_shutdown(map()) :: map()
  def maybe_schedule_idle_shutdown(%{downstream: nil, active_turn: nil} = state),
    do: schedule_idle_shutdown(state)

  def maybe_schedule_idle_shutdown(state), do: state

  @spec schedule_idle_shutdown(map()) :: map()
  def schedule_idle_shutdown(%{idle_shutdown_ref: ref} = state) when is_reference(ref), do: state

  def schedule_idle_shutdown(%{idle_shutdown_ms: timeout} = state)
      when is_integer(timeout) and timeout >= 0 do
    %{state | idle_shutdown_ref: Process.send_after(self(), :idle_shutdown, timeout)}
  end

  def schedule_idle_shutdown(state), do: state

  @spec cancel_idle_shutdown(map()) :: map()
  def cancel_idle_shutdown(%{idle_shutdown_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | idle_shutdown_ref: nil}
  end

  def cancel_idle_shutdown(state), do: state
end
