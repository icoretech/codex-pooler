defmodule CodexPooler.Gateway.Transports.Streaming.DeferredStreamDrain do
  @moduledoc """
  Drains one registered deferred HTTP SSE stream during rollout drain.

  The drain never finalizes another process's request. It signals the stream
  process, which consumes the signal inside its own relay loop and runs the
  ordinary interrupted-stream finalization that owns its `Plug.Conn`, its
  writer, and its request/attempt settlement. This module only waits for that
  to happen, bounded by the shared drain deadline.

  A stream that does not settle within the budget is reported as `:aborted` and
  the drain proceeds. Its process is not killed: the endpoint's own shutdown
  owns connection lifetime, and the stale-reservation sweep remains the
  backstop for anything that never settles.
  """

  alias CodexPooler.Gateway.Transports.Streaming.DeferredStreamRegistry

  @poll_interval_ms 200

  @type outcome :: :completed | :aborted | :failed
  @type policy :: %{
          required(:now_ms) => (-> integer()),
          required(:schedule_wait) => (pid(), reference(), non_neg_integer() -> term()),
          required(:cancel_wait) => (term(), reference() -> :ok)
        }

  @spec drain(DeferredStreamRegistry.drain_entry(), integer(), policy(), GenServer.server()) ::
          outcome()
  def drain(%{status: {:finished, outcome}}, _deadline_ms, _policy, _registry), do: outcome

  def drain(%{token: token, pid: pid}, deadline_ms, policy, registry) do
    monitor = Process.monitor(pid)
    :ok = DeferredStreamRegistry.interrupt(token, :owner_drained, name: registry)

    outcome =
      case DeferredStreamRegistry.status(token, name: registry) do
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
      stream_outcome(token, registry, :aborted)
    else
      case wait_or_down(monitor, policy, min(@poll_interval_ms, remaining_ms)) do
        :process_down -> stream_outcome(token, registry, :failed)
        :elapsed -> await(token, monitor, deadline_ms, policy, registry)
        :wait_failed -> :failed
      end
    end
  end

  defp stream_outcome(token, registry, unsettled_outcome) do
    case DeferredStreamRegistry.status(token, name: registry) do
      {:finished, outcome} -> outcome
      {:active, _status} -> unsettled_outcome
      :unknown -> unsettled_outcome
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
