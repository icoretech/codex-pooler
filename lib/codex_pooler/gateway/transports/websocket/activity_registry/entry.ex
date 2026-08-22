defmodule CodexPooler.Gateway.Transports.Websocket.ActivityRegistry.Entry do
  @moduledoc false

  @type kind :: :direct | :proxy
  @type status :: :registered | :admitted | :cancelling
  @type t :: %{
          required(:token) => reference(),
          required(:kind) => kind(),
          required(:pid) => pid(),
          required(:monitor) => reference(),
          required(:status) => status(),
          required(:cancel_pid) => pid(),
          required(:ack_pid) => pid(),
          optional(:cancel_reason) => :owner_drained
        }

  @spec new(reference(), kind(), pid(), reference()) :: t()
  def new(token, kind, pid, monitor) do
    %{
      token: token,
      kind: kind,
      pid: pid,
      monitor: monitor,
      status: :registered,
      cancel_pid: pid,
      ack_pid: pid
    }
  end

  @spec set_recipient(t(), pid()) :: t()
  def set_recipient(entry, pid) do
    entry |> Map.put(:cancel_pid, pid) |> Map.put(:ack_pid, pid)
  end

  @spec handoff(map(), pid(), pid()) :: {:ok, map()} | {:cancelled, atom(), pid()} | :stale
  def handoff(%{status: :cancelling, cancel_reason: reason, ack_pid: ack_pid}, _from, _to),
    do: {:cancelled, reason, ack_pid}

  def handoff(%{cancel_pid: from_pid} = entry, from_pid, to_pid),
    do: {:ok, set_recipient(entry, to_pid)}

  def handoff(_entry, _from_pid, _to_pid), do: :stale

  @spec cancel(map(), atom()) :: {pid(), map()}
  def cancel(entry, reason) do
    cancel_pid = Map.get(entry, :cancel_pid, entry.pid)

    {cancel_pid,
     entry
     |> Map.put(:status, :cancelling)
     |> Map.put(:cancel_reason, reason)
     |> Map.put(:ack_pid, cancel_pid)}
  end

  @spec delivery_target(map(), reference()) :: {reference(), pid(), atom()}
  def delivery_target(entry, token) do
    {token, Map.get(entry, :ack_pid, entry.pid), entry.status}
  end
end
