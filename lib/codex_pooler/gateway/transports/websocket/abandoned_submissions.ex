defmodule CodexPooler.Gateway.Transports.Websocket.AbandonedSubmissions do
  @moduledoc false

  # Node-level record of turn submissions a proxy abandoned while no owner was
  # registered for their session on this node (findings#206 row 206-316).
  #
  # The owner remembers an abandon that finds no matching turn (row 206-307),
  # but an abandon that finds no owner at all had nowhere to go: the owner-node
  # process carrying the timed-out submission could still start or recover the
  # owner (the owner did not exist yet, or the stalled owner holding the
  # submission crashed and the submission re-submitted to its replacement) and
  # then send the turn upstream for a client that already got its error.
  #
  # Both the abandon and the submission are calls to the same node, the one the
  # session names as its owner, and a late submission can only run on the node
  # the session names (`require_local_owner_session`), so the record lives on
  # that node rather than in shared state. The key is the proxy's exact
  # per-call downstream: its response task is the `owner_turn_id`, so no later
  # turn, even on the same socket, matches it. Each record is held by a small
  # process that registers the key and leaves after `@ttl_ms` or once the
  # submission consumed it; abandons that find no owner are rare, so the
  # records stay few.
  #
  # The abandon writes the record and then looks the owner up again, and the
  # submission registers its owner and then reads the record, so one of them
  # always sees the other: either the submission finds the record and is
  # refused, or the abandon finds the owner and abandons the turn there.

  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession

  @registry __MODULE__.Registry
  @supervisor WebsocketOwnerSession.TaskSupervisor
  @ttl_ms :timer.minutes(10)

  @type key :: {binary(), pid(), term(), term(), pid()}

  @spec registry() :: atom()
  def registry, do: @registry

  @spec key(binary(), map()) :: key() | nil
  def key(codex_session_id, %{pid: pid, epoch: epoch, correlation_id: correlation_id, owner_turn_id: owner_turn_id})
      when is_binary(codex_session_id) and is_pid(pid) and is_pid(owner_turn_id),
      do: {codex_session_id, pid, epoch, correlation_id, owner_turn_id}

  def key(_codex_session_id, _downstream), do: nil

  # Returns once the key is registered, so a submission that reads the record
  # after this call returned sees it.
  @spec record(key(), keyword()) :: :ok
  def record(key, opts \\ []) when is_tuple(key) and is_list(opts) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @ttl_ms)
    caller = self()
    ref = make_ref()

    case Task.Supervisor.start_child(@supervisor, fn -> hold(key, ttl_ms, caller, ref) end) do
      {:ok, holder} ->
        monitor = Process.monitor(holder)

        receive do
          {^ref, :registered} ->
            Process.demonitor(monitor, [:flush])
            :ok

          {:DOWN, ^monitor, :process, ^holder, _reason} ->
            :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  @spec recorded?(key() | nil) :: boolean()
  def recorded?(nil), do: false
  def recorded?(key), do: Registry.lookup(@registry, key) != []

  # A submission that finds its record is refused; the record is gone when
  # this returns.
  @spec consume(key() | nil) :: boolean()
  def consume(nil), do: false

  def consume(key) do
    case Registry.lookup(@registry, key) do
      [{holder, _value} | _rest] ->
        ref = make_ref()
        monitor = Process.monitor(holder)
        send(holder, {:consume, self(), ref})

        receive do
          {^ref, :consumed} -> Process.demonitor(monitor, [:flush])
          {:DOWN, ^monitor, :process, ^holder, _reason} -> :ok
        end

        true

      [] ->
        false
    end
  end

  defp hold(key, ttl_ms, caller, ref) do
    case Registry.register(@registry, key, nil) do
      {:ok, _owner} ->
        send(caller, {ref, :registered})

        receive do
          {:consume, consumer, consume_ref} ->
            :ok = Registry.unregister(@registry, key)
            send(consumer, {consume_ref, :consumed})
        after
          ttl_ms -> :ok
        end

      {:error, {:already_registered, _holder}} ->
        send(caller, {ref, :registered})
    end
  end
end
