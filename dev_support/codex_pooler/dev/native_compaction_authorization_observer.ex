defmodule CodexPooler.Dev.NativeCompactionAuthorizationObserver do
  @moduledoc """
  Disposable aggregate-only observer for native compaction authorization smoke tests.

  One stable node-local guardian owns the fixed telemetry handler and monitors a
  separately named armed store process. Reads never start either process. The
  module is compiled only in development and test environments and retains no
  request, session, capability, token, digest, topology, lifecycle, payload,
  frame, or persistence data.
  """

  use GenServer

  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAuthorizationObservation

  @guardian __MODULE__.Guardian
  @store __MODULE__
  @lifecycle_lock {__MODULE__, :lifecycle}
  @handler_id "codex-pooler-native-compaction-authorization-observer"
  @event [:codex_pooler, :gateway, :native_compaction, :authorization_transition]
  @break_modes [
    "none",
    "missing-compact-authorization",
    "missing-final-authorization",
    "duplicate-final-replay"
  ]

  @type state :: %{store: pid() | nil, monitor: reference() | nil, generation: reference() | nil}

  defmodule Store do
    @moduledoc false

    use GenServer

    @spec start_link(reference(), map()) :: GenServer.on_start()
    def start_link(generation, counts) do
      GenServer.start_link(
        __MODULE__,
        %{generation: generation, counts: counts, break_mode: "none"},
        name: CodexPooler.Dev.NativeCompactionAuthorizationObserver
      )
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:project, break_mode}, _from, state),
      do: {:reply, :ok, %{state | break_mode: break_mode}}

    def handle_call(:captures, _from, state) do
      counts = CodexPooler.Dev.NativeCompactionAuthorizationObserver.projected_counts(state)
      {:reply, %{"schemaVersion" => 1, "counts" => counts}, state}
    end

    @impl true
    def handle_cast({:transition, generation, transition}, %{generation: generation} = state) do
      key = Atom.to_string(transition)
      {:noreply, update_in(state, [:counts, key], fn count -> count + 1 end)}
    end

    def handle_cast({:transition, _generation, _transition}, state), do: {:noreply, state}
  end

  @spec arm() :: :ok
  def arm do
    lifecycle_transaction(fn -> call_guardian(:arm) end)
  end

  @spec disarm() :: :ok
  def disarm do
    lifecycle_transaction(&teardown/0)
  end

  @spec captures() :: %{required(String.t()) => 1 | %{required(String.t()) => non_neg_integer()}}
  def captures do
    case Process.whereis(@store) do
      nil -> empty_capture()
      store -> call_existing(store, :captures, empty_capture())
    end
  end

  @spec project(String.t()) :: :ok | {:error, :invalid_break_mode | :not_armed}
  def project(break_mode) when break_mode in @break_modes do
    case Process.whereis(@store) do
      nil -> {:error, :not_armed}
      store -> call_existing(store, {:project, break_mode}, {:error, :not_armed})
    end
  end

  def project(_break_mode), do: {:error, :invalid_break_mode}

  @spec status() :: map()
  def status do
    store_running? = not is_nil(Process.whereis(@store))

    %{
      "armed" => store_running?,
      "telemetryHandlers" => fixed_handler_count(),
      "storeRunning" => store_running?
    }
  end

  @doc false
  @spec handle_event([atom()], map(), map(), reference()) :: :ok
  def handle_event(
        @event,
        %{count: 1},
        %{transition: transition, topology: topology},
        generation
      )
      when is_reference(generation) and topology in [:direct, :forwarded] do
    if transition in NativeCompactionAuthorizationObservation.transitions() do
      case Process.whereis(@store) do
        nil -> :ok
        store -> GenServer.cast(store, {:transition, generation, transition})
      end
    end

    :ok
  end

  def handle_event(@event, _measurements, _metadata, _config), do: :ok

  @impl true
  def init(:guardian), do: {:ok, %{store: nil, monitor: nil, generation: nil}}

  @impl true
  def handle_call(:arm, _from, state) do
    _stopped_state = stop_store(state)
    :telemetry.detach(@handler_id)
    generation = make_ref()
    {:ok, store} = Store.start_link(generation, empty_counts())
    monitor = Process.monitor(store)
    Process.unlink(store)
    :ok = :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, generation)
    {:reply, :ok, %{store: store, monitor: monitor, generation: generation}}
  end

  def handle_call(:disarm, _from, state) do
    :telemetry.detach(@handler_id)
    {:stop, :normal, :ok, stop_store(state)}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, store, _reason}, %{monitor: monitor, store: store}) do
    {:noreply, %{store: nil, monitor: nil, generation: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp call_guardian(message),
    do: call_guardian_until(message, System.monotonic_time(:millisecond) + 15_000)

  defp call_guardian_until(message, deadline_ms) do
    :ok = ensure_guardian_started()

    case Process.whereis(@guardian) do
      nil ->
        call_guardian_until(message, deadline_ms)

      guardian ->
        try do
          GenServer.call(guardian, message, 15_000)
        catch
          :exit, reason ->
            if lifecycle_exit?(reason) and System.monotonic_time(:millisecond) < deadline_ms do
              call_guardian_until(message, deadline_ms)
            else
              :erlang.raise(:exit, reason, __STACKTRACE__)
            end
        end
    end
  end

  defp teardown do
    :telemetry.detach(@handler_id)
    stop_named_store()

    case Process.whereis(@guardian) do
      nil ->
        :ok

      guardian ->
        monitor = Process.monitor(guardian)
        _result = call_existing(guardian, :disarm, :ok)

        receive do
          {:DOWN, ^monitor, :process, ^guardian, _reason} -> :ok
        after
          15_000 ->
            Process.demonitor(monitor, [:flush])
            exit({:observer_guardian_teardown_timeout, guardian})
        end
    end
  end

  defp lifecycle_transaction(callback) do
    :global.trans({@lifecycle_lock, self()}, callback, [node()])
  end

  defp ensure_guardian_started do
    case Process.whereis(@guardian) do
      nil ->
        case GenServer.start(__MODULE__, :guardian, name: @guardian) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp call_existing(pid, message, absent_result) do
    try do
      GenServer.call(pid, message, 15_000)
    catch
      :exit, reason -> if lifecycle_exit?(reason), do: absent_result, else: exit(reason)
    end
  end

  defp lifecycle_exit?({reason, {GenServer, :call, _details}}), do: lifecycle_exit?(reason)
  defp lifecycle_exit?(reason) when reason in [:noproc, :normal, :shutdown], do: true
  defp lifecycle_exit?({:shutdown, _details}), do: true
  defp lifecycle_exit?({:noproc, _details}), do: true
  defp lifecycle_exit?(_reason), do: false

  defp stop_store(%{store: store, monitor: monitor} = state) do
    if is_reference(monitor), do: Process.demonitor(monitor, [:flush])

    stop_named_store(store)

    %{state | store: nil, monitor: nil, generation: nil}
  end

  defp stop_named_store(expected_store \\ nil) do
    case Process.whereis(@store) do
      store when is_pid(store) and (is_nil(expected_store) or store == expected_store) ->
        try do
          GenServer.stop(store, :normal)
        catch
          :exit, _reason -> :ok
        end

      _absent_or_replaced ->
        :ok
    end
  end

  defp fixed_handler_count do
    Enum.count(:telemetry.list_handlers(@event), &(&1.id == @handler_id))
  end

  defp empty_counts do
    Map.new(NativeCompactionAuthorizationObservation.transitions(), fn transition ->
      {Atom.to_string(transition), 0}
    end)
  end

  defp empty_capture, do: %{"schemaVersion" => 1, "counts" => empty_counts()}

  @doc false
  def projected_counts(%{counts: counts, break_mode: "none"}), do: counts

  def projected_counts(%{counts: counts, break_mode: "missing-compact-authorization"}),
    do: Map.put(counts, "compact_owner_issued", 0)

  def projected_counts(%{counts: counts, break_mode: "missing-final-authorization"}),
    do: Map.put(counts, "final_owner_issued", 0)

  def projected_counts(%{counts: counts, break_mode: "duplicate-final-replay"}),
    do: Map.update!(counts, "final_acknowledged", fn count -> count + 1 end)
end
