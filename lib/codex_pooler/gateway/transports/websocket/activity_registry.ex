defmodule CodexPooler.Gateway.Transports.Websocket.ActivityRegistry do
  @moduledoc false

  use GenServer

  alias __MODULE__.{Drain, Entry}
  alias CodexPooler.Gateway.Websocket.DirectCleanup

  @spec begin_direct_cleanup(DirectCleanup.t()) :: :ok | {:error, :cancelled}
  def begin_direct_cleanup(context),
    do: GenServer.call(context.registry, {:direct_begin, context})

  @spec bind_direct_cleanup(DirectCleanup.t(), DirectCleanup.receipt()) :: :ok
  def bind_direct_cleanup(context, receipt),
    do: GenServer.call(context.registry, {:direct_bind, context, receipt})

  @spec ready_direct_cleanup(DirectCleanup.t()) :: :ok | {:error, :cancelled}
  def ready_direct_cleanup(context),
    do: GenServer.call(context.registry, {:direct_ready, context})

  @spec await_direct_cleanup(DirectCleanup.t()) :: {:ok, DirectCleanup.receipt()} | :none
  def await_direct_cleanup(context),
    do: GenServer.call(context.registry, {:direct_await, context}, 30_000)

  @type activity_kind :: Entry.kind()
  @type outcome :: :completed | :aborted | :failed
  @type token :: reference()
  @type drain_entry :: Drain.entry()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec register(activity_kind(), pid(), keyword()) :: {:ok, token()}
  def register(kind, pid \\ self(), opts \\ [])
      when kind in [:direct, :proxy] and is_pid(pid) do
    GenServer.call(
      server(opts),
      {:register, kind, pid, Keyword.take(opts, [:direct_cleanup_ref, :direct_cleanup_parent])}
    )
  end

  @spec admit(token(), keyword()) :: :ok | {:error, :owner_drained | :unknown_activity}
  def admit(token, opts \\ []) when is_reference(token) do
    GenServer.call(server(opts), {:admit, token})
  end

  @spec unregister(token(), outcome(), keyword()) :: :ok
  def unregister(token, outcome, opts \\ [])
      when is_reference(token) and outcome in [:completed, :aborted, :failed] do
    GenServer.call(server(opts), {:unregister, token, outcome})
  end

  @spec complete(token(), outcome(), keyword()) :: :ok
  def complete(token, outcome, opts \\ [])
      when is_reference(token) and outcome in [:completed, :aborted, :failed] do
    GenServer.call(server(opts), {:complete, token, outcome})
  end

  @spec set_cancel_recipient(token(), pid(), keyword()) :: :ok | {:error, :unknown_activity}
  def set_cancel_recipient(token, pid, opts \\ []) when is_reference(token) and is_pid(pid) do
    GenServer.call(server(opts), {:set_cancel_recipient, token, pid})
  end

  @spec handoff_cancel_recipient(token(), pid(), pid(), keyword()) ::
          :ok | {:cancelled, :owner_drained, pid()} | {:error, :unknown_activity}
  def handoff_cancel_recipient(token, from_pid, to_pid, opts \\ [])
      when is_reference(token) and is_pid(from_pid) and is_pid(to_pid) do
    GenServer.call(server(opts), {:handoff_cancel_recipient, token, from_pid, to_pid})
  end

  @spec delivery_target(pid(), keyword()) ::
          {:ok, token(), pid(), :registered | :admitted | :cancelling} | :unknown
  def delivery_target(pid, opts \\ []) when is_pid(pid) do
    GenServer.call(server(opts), {:delivery_target, pid})
  end

  @spec begin_drain(keyword()) :: {reference(), [Drain.entry()]}
  def begin_drain(opts \\ []), do: GenServer.call(server(opts), :begin_drain)

  @spec complete_drain(reference(), keyword()) :: :ok
  def complete_drain(epoch, opts \\ []) when is_reference(epoch) do
    GenServer.call(server(opts), {:complete_drain, epoch})
  end

  @spec cancel(token(), :owner_drained, keyword()) :: :ok
  def cancel(token, :owner_drained = reason, opts \\ []) when is_reference(token) do
    GenServer.call(server(opts), {:cancel, token, reason})
  end

  @spec status(token(), keyword()) ::
          {:active, :registered | :admitted | :cancelling}
          | {:finished, outcome()}
          | :unknown
  def status(token, opts \\ []) when is_reference(token) do
    GenServer.call(server(opts), {:status, token})
  end

  @spec activities(keyword()) :: [Entry.t()]
  def activities(opts \\ []), do: GenServer.call(server(opts), :activities)

  @spec draining?(keyword()) :: boolean()
  def draining?(opts \\ []), do: GenServer.call(server(opts), :draining?)

  @impl GenServer
  def init(:ok) do
    {:ok, %{activities: %{}, monitors: %{}, draining?: false, drain: nil, finished_direct: %{}}}
  end

  @impl GenServer
  def handle_call({:direct_begin, context}, {caller, _}, state) do
    case direct_entry(state, context.task) do
      {token, %{kind: :direct, status: :admitted, direct_ref: ref, direct_parent: parent} = entry}
      when caller == context.task and ref == context.ref and parent == context.parent and
             not is_map_key(entry, :direct_cancelled?) and not is_map_key(entry, :direct_cleanup) ->
        cleanup = %{context: context, pending?: true, receipt: nil, waiters: []}
        {:reply, :ok, put_in(state.activities[token], Map.put(entry, :direct_cleanup, cleanup))}

      _ ->
        {:reply, {:error, :cancelled}, state}
    end
  end

  def handle_call({:direct_bind, context, receipt}, {caller, _}, state) do
    case direct_entry(state, context.task) do
      {token, %{direct_cleanup: %{context: ^context} = cleanup}} when caller == context.task ->
        send(context.parent, {:direct_request_cleanup, context.task, context.ref, receipt})

        {:reply, :ok,
         put_in(state.activities[token].direct_cleanup, %{cleanup | receipt: receipt})}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:direct_ready, context}, {caller, _}, state) do
    case direct_entry(state, context.task) do
      {token, %{direct_cleanup: %{context: ^context} = cleanup} = entry}
      when caller == context.task ->
        reply_direct_waiters(cleanup)

        result =
          if entry.status == :cancelling or cleanup.waiters != [],
            do: {:error, :cancelled},
            else: :ok

        {:reply, result,
         put_in(state.activities[token].direct_cleanup, %{cleanup | pending?: false, waiters: []})}

      _ ->
        {:reply, {:error, :cancelled}, state}
    end
  end

  def handle_call({:direct_await, context}, from, state) do
    case direct_entry(state, context.task) do
      {token, %{direct_cleanup: %{context: ^context, pending?: true} = cleanup}} ->
        {:noreply,
         put_in(state.activities[token].direct_cleanup, %{
           cleanup
           | waiters: [from | cleanup.waiters]
         })}

      {token, %{direct_cleanup: %{context: ^context} = cleanup}} ->
        {:reply, direct_receipt(cleanup),
         put_in(state.activities[token].direct_cleanup, Map.put(cleanup, :consumed?, true))}

      {token, %{direct_ref: ref, direct_parent: parent} = entry}
      when entry.pid == context.task and ref == context.ref and parent == context.parent ->
        {:reply, :none, put_in(state.activities[token], Map.put(entry, :direct_cancelled?, true))}

      _ ->
        case Map.get(state.finished_direct, context.ref) do
          %{context: ^context} = completed ->
            Process.demonitor(completed.monitor, [:flush])

            {:reply, {:ok, completed.receipt},
             %{state | finished_direct: Map.delete(state.finished_direct, context.ref)}}

          _ ->
            {:reply, :none, state}
        end
    end
  end

  def handle_call({:register, kind, pid, opts}, _from, state) do
    token = make_ref()
    monitor = Process.monitor(pid)

    entry = Entry.new(token, kind, pid, monitor)

    entry =
      case {Keyword.get(opts, :direct_cleanup_ref), Keyword.get(opts, :direct_cleanup_parent)} do
        {ref, parent} when is_reference(ref) and is_pid(parent) ->
          Map.merge(entry, %{direct_ref: ref, direct_parent: parent})

        _ ->
          entry
      end

    state = %{
      state
      | activities: Map.put(state.activities, token, entry),
        monitors: Map.put(state.monitors, monitor, token)
    }

    {:reply, {:ok, token}, state}
  end

  def handle_call({:admit, token}, _from, %{draining?: true} = state) do
    reply =
      if Map.has_key?(state.activities, token),
        do: {:error, :owner_drained},
        else: {:error, :unknown_activity}

    {:reply, reply, state}
  end

  def handle_call({:admit, token}, _from, state) do
    case Map.fetch(state.activities, token) do
      {:ok, entry} ->
        activities = Map.put(state.activities, token, %{entry | status: :admitted})
        {:reply, :ok, %{state | activities: activities}}

      :error ->
        {:reply, {:error, :unknown_activity}, state}
    end
  end

  def handle_call({:unregister, token, outcome}, _from, state) do
    {:reply, :ok, finish_activity(state, token, outcome)}
  end

  def handle_call({:complete, token, outcome}, _from, state) do
    {:reply, :ok, finish_activity(state, token, outcome, true, true)}
  end

  def handle_call({:set_cancel_recipient, token, pid}, _from, state) do
    case Map.fetch(state.activities, token) do
      {:ok, entry} ->
        entry = Entry.set_recipient(entry, pid)
        activities = Map.put(state.activities, token, entry)
        {:reply, :ok, %{state | activities: activities}}

      :error ->
        {:reply, {:error, :unknown_activity}, state}
    end
  end

  def handle_call({:handoff_cancel_recipient, token, from_pid, to_pid}, _from, state) do
    case Map.get(state.activities, token) do
      entry when is_map(entry) ->
        case Entry.handoff(entry, from_pid, to_pid) do
          {:ok, entry} ->
            {:reply, :ok, put_in(state.activities[token], entry)}

          {:cancelled, reason, ack_pid} ->
            {:reply, {:cancelled, reason, ack_pid}, state}

          :stale ->
            {:reply, {:error, :unknown_activity}, state}
        end

      nil ->
        {:reply, {:error, :unknown_activity}, state}
    end
  end

  def handle_call({:delivery_target, pid}, _from, state) do
    reply =
      Enum.find_value(state.activities, :unknown, fn {token, entry} ->
        if entry.pid == pid do
          {token, ack_pid, status} = Entry.delivery_target(entry, token)
          {:ok, token, ack_pid, status}
        end
      end)

    {:reply, reply, state}
  end

  def handle_call(:begin_drain, _from, %{drain: nil} = state) do
    {drain, epoch, entries} = Drain.begin(nil, state.activities)
    state = %{state | draining?: true, drain: drain}
    {:reply, {epoch, entries}, state}
  end

  def handle_call(:begin_drain, _from, state) do
    {drain, epoch, entries} = Drain.begin(state.drain, state.activities)
    {:reply, {epoch, entries}, %{state | drain: drain}}
  end

  def handle_call({:complete_drain, epoch}, _from, %{drain: %{epoch: epoch}} = state) do
    {:reply, :ok, %{state | drain: nil}}
  end

  def handle_call({:complete_drain, _epoch}, _from, state), do: {:reply, :ok, state}

  def handle_call({:cancel, token, reason}, _from, state) do
    case Map.get(state.activities, token) do
      %{status: status} = entry when status in [:registered, :admitted] ->
        {cancel_pid, entry} = Entry.cancel(entry, reason)
        send(cancel_pid, {:websocket_activity_cancel, token, reason})
        activities = Map.put(state.activities, token, entry)

        {:reply, :ok, %{state | activities: activities}}

      _finished_unknown_or_cancelling ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:status, token}, _from, state) do
    reply =
      case Map.get(state.activities, token) do
        %{status: status} -> {:active, status}
        nil -> Drain.outcome(state.drain, token)
      end

    {:reply, reply, state}
  end

  def handle_call(:activities, _from, state) do
    entries = Enum.map(state.activities, fn {_token, entry} -> Map.drop(entry, [:monitor]) end)
    {:reply, entries, state}
  end

  def handle_call(:draining?, _from, state), do: {:reply, state.draining?, state}

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        finished =
          Map.reject(state.finished_direct, fn {_ref, completed} ->
            completed.monitor == monitor
          end)

        {:noreply, %{state | finished_direct: finished}}

      {token, monitors} ->
        state = %{state | monitors: monitors}
        {:noreply, finish_activity(state, token, :failed, false)}
    end
  end

  defp finish_activity(
         state,
         token,
         outcome,
         demonitor? \\ true,
         honor_outcome? \\ false
       ) do
    case Map.pop(state.activities, token) do
      {nil, _activities} ->
        state

      {entry, activities} ->
        if cleanup = Map.get(entry, :direct_cleanup), do: reply_direct_waiters(cleanup)
        state = retain_direct_cleanup(state, Map.get(entry, :direct_cleanup))

        if demonitor?, do: Process.demonitor(entry.monitor, [:flush])
        monitors = Map.delete(state.monitors, entry.monitor)

        outcome =
          if not honor_outcome? and entry.status == :cancelling,
            do: :aborted,
            else: outcome

        state = %{state | activities: activities, monitors: monitors}

        %{state | drain: Drain.record_outcome(state.drain, token, entry, outcome)}
    end
  end

  defp retain_direct_cleanup(state, %{consumed?: true}), do: state

  defp retain_direct_cleanup(state, %{context: context, receipt: receipt})
       when not is_nil(receipt) do
    completed = %{context: context, receipt: receipt, monitor: Process.monitor(context.parent)}
    %{state | finished_direct: Map.put(state.finished_direct, context.ref, completed)}
  end

  defp retain_direct_cleanup(state, _cleanup), do: state

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)

  defp direct_entry(state, pid),
    do: Enum.find(state.activities, fn {_token, entry} -> entry.pid == pid end)

  defp direct_receipt(%{receipt: nil}), do: :none
  defp direct_receipt(%{receipt: receipt}), do: {:ok, receipt}

  defp reply_direct_waiters(cleanup),
    do: Enum.each(cleanup.waiters, &GenServer.reply(&1, direct_receipt(cleanup)))
end
