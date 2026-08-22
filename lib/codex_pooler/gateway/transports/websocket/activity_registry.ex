defmodule CodexPooler.Gateway.Transports.Websocket.ActivityRegistry do
  @moduledoc false

  use GenServer

  @type activity_kind :: :direct | :proxy
  @type outcome :: :completed | :aborted | :failed
  @type token :: reference()
  @type entry :: %{
          required(:token) => token(),
          required(:kind) => activity_kind(),
          required(:pid) => pid(),
          required(:status) => :registered | :admitted | :cancelling
        }
  @type drain_entry :: %{
          required(:token) => token(),
          required(:kind) => activity_kind(),
          required(:pid) => pid(),
          required(:status) => :active | {:finished, outcome()}
        }

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
    GenServer.call(server(opts), {:register, kind, pid})
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

  @spec set_cancel_recipient(token(), pid(), keyword()) :: :ok | {:error, :unknown_activity}
  def set_cancel_recipient(token, pid, opts \\ []) when is_reference(token) and is_pid(pid) do
    GenServer.call(server(opts), {:set_cancel_recipient, token, pid})
  end

  @spec begin_drain(keyword()) :: {reference(), [drain_entry()]}
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

  @spec activities(keyword()) :: [entry()]
  def activities(opts \\ []), do: GenServer.call(server(opts), :activities)

  @spec draining?(keyword()) :: boolean()
  def draining?(opts \\ []), do: GenServer.call(server(opts), :draining?)

  @impl GenServer
  def init(:ok) do
    {:ok, %{activities: %{}, monitors: %{}, draining?: false, drain: nil}}
  end

  @impl GenServer
  def handle_call({:register, kind, pid}, _from, state) do
    token = make_ref()
    monitor = Process.monitor(pid)
    entry = %{token: token, kind: kind, pid: pid, monitor: monitor, status: :registered}

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

  def handle_call({:set_cancel_recipient, token, pid}, _from, state) do
    case Map.fetch(state.activities, token) do
      {:ok, entry} ->
        activities = Map.put(state.activities, token, Map.put(entry, :cancel_pid, pid))
        {:reply, :ok, %{state | activities: activities}}

      :error ->
        {:reply, {:error, :unknown_activity}, state}
    end
  end

  def handle_call(:begin_drain, _from, %{drain: nil} = state) do
    epoch = make_ref()
    tokens = state.activities |> Map.keys() |> MapSet.new()
    drain = %{epoch: epoch, tokens: tokens, outcomes: %{}}
    state = %{state | draining?: true, drain: drain}
    {:reply, {epoch, drain_entries(state)}, state}
  end

  def handle_call(:begin_drain, _from, state) do
    {:reply, {state.drain.epoch, drain_entries(state)}, state}
  end

  def handle_call({:complete_drain, epoch}, _from, %{drain: %{epoch: epoch}} = state) do
    {:reply, :ok, %{state | drain: nil}}
  end

  def handle_call({:complete_drain, _epoch}, _from, state), do: {:reply, :ok, state}

  def handle_call({:cancel, token, reason}, _from, state) do
    case Map.get(state.activities, token) do
      %{status: status} = entry when status in [:registered, :admitted] ->
        send(Map.get(entry, :cancel_pid, entry.pid), {:websocket_activity_cancel, token, reason})
        activities = Map.put(state.activities, token, %{entry | status: :cancelling})
        {:reply, :ok, %{state | activities: activities}}

      _finished_unknown_or_cancelling ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:status, token}, _from, state) do
    reply =
      case Map.get(state.activities, token) do
        %{status: status} -> {:active, status}
        nil -> drain_outcome(state.drain, token)
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
        {:noreply, state}

      {token, monitors} ->
        state = %{state | monitors: monitors}
        {:noreply, finish_activity(state, token, :failed, false)}
    end
  end

  defp finish_activity(state, token, outcome, demonitor? \\ true) do
    case Map.pop(state.activities, token) do
      {nil, _activities} ->
        state

      {entry, activities} ->
        if demonitor?, do: Process.demonitor(entry.monitor, [:flush])
        monitors = Map.delete(state.monitors, entry.monitor)
        outcome = if entry.status == :cancelling, do: :aborted, else: outcome

        state = %{state | activities: activities, monitors: monitors}

        if drain_member?(state.drain, token) do
          put_in(state.drain.outcomes[token], %{entry: entry, outcome: outcome})
        else
          state
        end
    end
  end

  defp drain_entries(%{drain: drain, activities: activities}) do
    Enum.map(drain.tokens, fn token ->
      case Map.get(activities, token) do
        nil ->
          %{entry: entry, outcome: outcome} = Map.fetch!(drain.outcomes, token)
          %{token: token, kind: entry.kind, pid: entry.pid, status: {:finished, outcome}}

        entry ->
          %{token: token, kind: entry.kind, pid: entry.pid, status: :active}
      end
    end)
  end

  defp drain_member?(nil, _token), do: false
  defp drain_member?(drain, token), do: MapSet.member?(drain.tokens, token)

  defp drain_outcome(nil, _token), do: :unknown

  defp drain_outcome(drain, token) do
    case Map.get(drain.outcomes, token) do
      %{outcome: outcome} -> {:finished, outcome}
      nil -> :unknown
    end
  end

  defp server(opts), do: Keyword.get(opts, :name, __MODULE__)
end
