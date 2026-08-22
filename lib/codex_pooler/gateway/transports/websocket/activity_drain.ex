defmodule CodexPooler.Gateway.Transports.Websocket.ActivityDrain do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry

  @poll_interval_ms 200

  @type outcome :: :completed | :aborted | :failed
  @type policy :: %{
          required(:now_ms) => (-> integer()),
          required(:schedule_wait) => (pid(), reference(), non_neg_integer() -> term()),
          required(:cancel_wait) => (term(), reference() -> :ok),
          required(:owner_post_deadline_call_budget_ms) => pos_integer()
        }

  @spec drain(ActivityRegistry.drain_entry(), integer(), policy(), GenServer.server()) ::
          outcome()
  def drain(%{status: {:finished, outcome}}, _deadline, _policy, _registry), do: outcome

  def drain(%{token: token, pid: pid}, deadline_ms, policy, registry) do
    monitor = Process.monitor(pid)

    outcome =
      case ActivityRegistry.status(token, name: registry) do
        {:finished, outcome} -> outcome
        {:active, _status} -> await(token, monitor, deadline_ms, policy, registry)
        :unknown -> :failed
      end

    Process.demonitor(monitor, [:flush])
    outcome
  end

  defp await(token, monitor, deadline_ms, policy, registry) do
    remaining_ms = max(0, deadline_ms - policy.now_ms.())

    if remaining_ms == 0 do
      cancel(token, monitor, policy, registry)
    else
      case wait_or_down(monitor, policy, min(@poll_interval_ms, remaining_ms)) do
        :process_down -> activity_outcome(token, registry)
        :elapsed -> await(token, monitor, deadline_ms, policy, registry)
        :wait_failed -> :failed
      end
    end
  end

  defp cancel(token, monitor, policy, registry) do
    :ok = ActivityRegistry.cancel(token, :owner_drained, name: registry)

    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} -> activity_outcome(token, registry)
    after
      policy.owner_post_deadline_call_budget_ms ->
        force_cancel(token, registry)
    end
  end

  defp force_cancel(token, registry) do
    case ActivityRegistry.activities(name: registry) |> Enum.find(&(&1.token == token)) do
      %{pid: pid} when is_pid(pid) -> Process.exit(pid, :kill)
      _finished -> :ok
    end

    activity_outcome(token, registry)
  end

  defp activity_outcome(token, registry) do
    case ActivityRegistry.status(token, name: registry) do
      {:finished, outcome} -> outcome
      {:active, :cancelling} -> :aborted
      {:active, _status} -> :failed
      :unknown -> :failed
    end
  end

  defp wait_or_down(monitor, policy, wait_ms) do
    wait_token = make_ref()

    try do
      wait_ref = policy.schedule_wait.(self(), wait_token, wait_ms)

      receive do
        {:DOWN, ^monitor, :process, _pid, _reason} ->
          :ok = policy.cancel_wait.(wait_ref, wait_token)
          :process_down

        {:rollout_drain_wait_elapsed, ^wait_token} ->
          :elapsed
      end
    catch
      _kind, _reason -> :wait_failed
    end
  end
end
