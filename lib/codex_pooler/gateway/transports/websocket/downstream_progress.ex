defmodule CodexPooler.Gateway.Transports.Websocket.DownstreamProgress do
  @moduledoc false

  # A remote owner relays a turn's frames straight to the proxy's socket while
  # the proxy's response task waits for the owner's reply to the submission, so
  # only the socket sees the turn progress. At every keepalive tick the socket
  # tells each owner-forwarded task whose turn delivered client-visible frames
  # since the previous tick, and the task's wait counts its idle budget from the
  # latest notice (findings#302). The notice is a plain message between two
  # processes of the proxy node: the owner node takes no part, so an owner of
  # any release keeps working.

  @notice {__MODULE__, :frames_delivered}

  @doc "Tells `task` that its turn delivered frames since the socket's previous tick."
  @spec notify(pid()) :: :ok
  def notify(task) when is_pid(task) do
    send(task, @notice)
    :ok
  end

  @doc "Records a written compaction wait control with a finite remaining authority."
  @spec notify_pending(pid(), pos_integer()) :: :ok
  def notify_pending(task, remaining_ms) when is_pid(task) and is_integer(remaining_ms) and remaining_ms > 0 do
    send(task, {__MODULE__, :pending_delivered, System.monotonic_time(:millisecond) + remaining_ms})
    :ok
  end

  @doc "Consumes progress and returns its bounded wait budget, if still valid."
  @spec drain_budget(pos_integer()) :: pos_integer() | nil
  def drain_budget(idle_timeout), do: drain_budget(idle_timeout, nil)

  defp drain_budget(idle_timeout, budget) do
    receive do
      @notice ->
        drain_budget(idle_timeout, idle_timeout)

      {__MODULE__, :pending_delivered, deadline} when is_integer(deadline) ->
        remaining = min(idle_timeout, deadline - System.monotonic_time(:millisecond))
        drain_budget(idle_timeout, if(remaining > 0, do: max(budget || 0, remaining), else: budget))
    after
      0 -> budget
    end
  end

  @doc "Takes every pending notice out of the caller's mailbox; `true` when there was one."
  @spec drain() :: boolean()
  def drain, do: drain(false)

  defp drain(seen?) do
    receive do
      @notice -> drain(true)
    after
      0 -> seen?
    end
  end
end
