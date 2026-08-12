defmodule CodexPooler.Gateway.Transports.Admission do
  @moduledoc """
  Local in-node admission control for runtime and browser route classes.
  """

  use GenServer

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.RouteClass

  @route_classes RouteClass.all()

  @default_queue_timeout_ms 5_000
  @telemetry_prefix [:codex_pooler, :gateway, :admission]
  @overload_code "server_is_overloaded"
  @overload_message "gateway route class is temporarily overloaded"
  @bulkhead_reasons ~w(bulkhead_rejected bulkhead_queue_timeout)
  @class_defaults %{
    running: 0,
    queue: :queue.new(),
    leases: MapSet.new(),
    monitors: %{},
    lease_monitors: %{},
    lease_owners: %{}
  }

  defstruct classes: %{}

  @type lease :: %{
          required(:server) => GenServer.server(),
          required(:route_class) => String.t(),
          required(:ref) => reference()
        }
  @type overload_reason :: %{required(:code) => String.t(), required(:route_class) => String.t()}
  @type overload_error :: %{
          required(:status) => 503,
          required(:code) => String.t(),
          required(:message) => String.t(),
          required(:param) => nil,
          required(:route_class) => String.t(),
          optional(:internal_reason) => String.t(),
          optional(:accounting_disposition) => :zero_work
        }
  @type saturation_snapshot :: %{
          required(RouteClass.t()) => %{
            required(:running) => non_neg_integer(),
            required(:queued) => non_neg_integer()
          }
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec route_classes() :: [String.t()]
  def route_classes, do: @route_classes

  @spec saturation(GenServer.server(), timeout()) ::
          {:ok, saturation_snapshot()} | {:error, :timeout | :unavailable}
  def saturation(server \\ __MODULE__, timeout \\ 1_000) do
    {:ok, GenServer.call(server, :saturation, timeout)}
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :unavailable}
  end

  @spec acquire(String.t(), map(), map()) :: {:ok, lease()} | {:error, overload_reason()}
  def acquire(route_class, metadata \\ %{}, opts \\ %{})

  def acquire(route_class, metadata, opts) when route_class in @route_classes do
    server = Map.get(opts, :server, __MODULE__)
    settings = Map.get(opts, :settings, OperationalSettings.current())

    GenServer.call(
      server,
      {:acquire, route_class, sanitize_metadata(metadata), settings, server},
      :infinity
    )
  end

  def acquire(route_class, _metadata, _opts),
    do: {:error, %{code: "unknown_route_class", route_class: route_class}}

  @spec release(lease() | term()) :: :ok
  def release(%{server: server, route_class: route_class, ref: ref}) do
    GenServer.cast(server, {:release, route_class, ref})
  end

  def release(_lease), do: :ok

  @spec run(String.t(), map(), (-> result), keyword()) :: result | {:error, overload_error()}
        when result: term()
  def run(route_class, metadata, fun, opts \\ []) when is_function(fun, 0) do
    case acquire(route_class, metadata, Map.new(opts)) do
      {:ok, lease} ->
        try do
          fun.()
        after
          release(lease)
        end

      {:error, reason} ->
        {:error, error(reason)}
    end
  end

  @spec overload_error(overload_reason()) :: overload_error()
  def overload_error(reason), do: error(reason)

  if Mix.env() == :test do
    def reset_for_test(server \\ __MODULE__) do
      GenServer.call(server, :reset)
    end
  end

  @impl GenServer
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl GenServer
  def handle_call(:reset, _from, _state), do: {:reply, :ok, %__MODULE__{}}

  def handle_call(:saturation, _from, state), do: {:reply, saturation_snapshot(state), state}

  def handle_call({:acquire, route_class, metadata, settings, server}, from, state) do
    config = bulkhead_config(settings, route_class)
    class = class_state(state, route_class)

    cond do
      class.running < config.max_concurrency ->
        lease = lease(server, route_class)
        class = track_active_lease(class, lease, from)

        emit(:accepted, route_class, metadata, %{running: class.running})

        {:reply, {:ok, lease}, put_class(state, route_class, class)}

      :queue.len(class.queue) < config.queue_limit ->
        queued = queued_request(server, route_class, from, metadata, config.queue_timeout_ms)

        class = %{
          class
          | queue: :queue.in(queued, class.queue),
            monitors: Map.put(class.monitors, queued.monitor, queued.ref)
        }

        emit(:enqueued, route_class, metadata, %{queued: :queue.len(class.queue)})

        {:noreply, put_class(state, route_class, class)}

      true ->
        emit(
          :rejected,
          route_class,
          metadata,
          %{queued: :queue.len(class.queue)},
          "bulkhead_rejected"
        )

        {:reply, {:error, %{code: "bulkhead_rejected", route_class: route_class}}, state}
    end
  end

  @impl GenServer
  def handle_cast({:release, route_class, ref}, state) do
    class = class_state(state, route_class)
    class = release_active_lease(class, ref)

    {:noreply, dequeue_next(put_class(state, route_class, class), route_class)}
  end

  @impl GenServer
  def handle_info({:queue_timeout, route_class, ref}, state) do
    class = class_state(state, route_class)

    case pop_queued(class, ref) do
      {nil, class} ->
        {:noreply, put_class(state, route_class, class)}

      {queued, class} ->
        Process.demonitor(queued.monitor, [:flush])

        GenServer.reply(
          queued.from,
          {:error, %{code: "bulkhead_queue_timeout", route_class: route_class}}
        )

        emit(
          :timeout,
          route_class,
          queued.metadata,
          %{queued_ms: elapsed_ms(queued.enqueued_at)},
          "bulkhead_queue_timeout"
        )

        {:noreply, put_class(state, route_class, class)}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case find_active_monitor(state, monitor) do
      {nil, nil} ->
        {route_class, ref} = find_monitor(state, monitor)

        state =
          if route_class && ref do
            class = class_state(state, route_class)
            {_queued, class} = pop_queued(class, ref)
            put_class(state, route_class, class)
          else
            state
          end

        {:noreply, state}

      {route_class, ref} ->
        class =
          state
          |> class_state(route_class)
          |> release_active_lease(ref, demonitor: false)

        {:noreply, dequeue_next(put_class(state, route_class, class), route_class)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp dequeue_next(state, route_class) do
    class = class_state(state, route_class)

    case :queue.out(class.queue) do
      {{:value, queued}, queue} ->
        Process.cancel_timer(queued.timer, async: false, info: false)
        Process.demonitor(queued.monitor, [:flush])

        lease = lease(queued.server, route_class)
        class = %{class | queue: queue, monitors: Map.delete(class.monitors, queued.monitor)}
        class = track_active_lease(class, lease, queued.from)

        GenServer.reply(queued.from, {:ok, lease})

        emit(:dequeued, route_class, queued.metadata, %{queued_ms: elapsed_ms(queued.enqueued_at)})

        put_class(state, route_class, class)

      {:empty, _queue} ->
        state
    end
  end

  defp queued_request(server, route_class, from, metadata, timeout_ms) do
    ref = make_ref()
    {pid, _tag} = from

    %{
      ref: ref,
      server: server,
      from: from,
      metadata: metadata,
      enqueued_at: System.monotonic_time(:millisecond),
      timer: Process.send_after(self(), {:queue_timeout, route_class, ref}, timeout_ms),
      monitor: Process.monitor(pid)
    }
  end

  defp pop_queued(class, ref) do
    {queued, remaining} =
      class.queue
      |> :queue.to_list()
      |> Enum.split_with(&(&1.ref == ref))

    queued = List.first(queued)
    queue = Enum.reduce(remaining, :queue.new(), &:queue.in/2)

    monitors = if queued, do: Map.delete(class.monitors, queued.monitor), else: class.monitors
    {queued, %{class | queue: queue, monitors: monitors}}
  end

  defp track_active_lease(class, lease, {pid, _tag}) do
    monitor = Process.monitor(pid)

    %{
      class
      | running: class.running + 1,
        leases: MapSet.put(class.leases, lease.ref),
        lease_monitors: Map.put(class.lease_monitors, monitor, lease.ref),
        lease_owners: Map.put(class.lease_owners, lease.ref, monitor)
    }
  end

  defp release_active_lease(class, ref, opts \\ []) do
    if MapSet.member?(class.leases, ref) do
      monitor = Map.get(class.lease_owners, ref)

      if monitor && Keyword.get(opts, :demonitor, true) do
        Process.demonitor(monitor, [:flush])
      end

      %{
        class
        | running: max(class.running - 1, 0),
          leases: MapSet.delete(class.leases, ref),
          lease_owners: Map.delete(class.lease_owners, ref),
          lease_monitors: Map.delete(class.lease_monitors, monitor)
      }
    else
      class
    end
  end

  defp find_active_monitor(state, monitor) do
    Enum.find_value(state.classes, {nil, nil}, fn {route_class, class} ->
      case Map.fetch(normalize_class(class).lease_monitors, monitor) do
        {:ok, ref} -> {route_class, ref}
        :error -> nil
      end
    end)
  end

  defp find_monitor(state, monitor) do
    Enum.find_value(state.classes, {nil, nil}, fn {route_class, class} ->
      case Map.fetch(normalize_class(class).monitors, monitor) do
        {:ok, ref} -> {route_class, ref}
        :error -> nil
      end
    end)
  end

  defp class_state(state, route_class) do
    state.classes
    |> Map.get(route_class)
    |> normalize_class()
  end

  defp normalize_class(class) do
    Map.merge(@class_defaults, class || %{})
  end

  defp put_class(state, route_class, class) do
    %{state | classes: Map.put(state.classes, route_class, class)}
  end

  defp saturation_snapshot(state) do
    Map.new(@route_classes, fn route_class ->
      class = class_state(state, route_class)

      {route_class,
       %{
         running: max(class.running, 0),
         queued: max(:queue.len(class.queue), 0)
       }}
    end)
  end

  defp lease(server, route_class),
    do: %{server: server, route_class: route_class, ref: make_ref()}

  defp bulkhead_config(settings, route_class) do
    config = Map.fetch!(settings.bulkheads, route_class)

    %{
      max_concurrency: config.max_concurrency,
      queue_limit: config.queue_limit,
      queue_timeout_ms: Map.get(config, :queue_timeout_ms, @default_queue_timeout_ms)
    }
  end

  defp error(%{code: "unknown_route_class", route_class: route_class}) do
    %{
      status: 503,
      code: "unknown_route_class",
      message: "gateway route class is unknown",
      param: nil,
      route_class: route_class
    }
  end

  defp error(%{code: code, route_class: route_class}) when code in @bulkhead_reasons do
    %{
      status: 503,
      code: @overload_code,
      message: @overload_message,
      param: nil,
      route_class: route_class,
      internal_reason: code,
      accounting_disposition: :zero_work
    }
  end

  defp error(%{code: code, route_class: route_class}) do
    %{
      status: 503,
      code: code,
      message: @overload_message,
      param: nil,
      route_class: route_class
    }
  end

  defp emit(event, route_class, metadata, measurements, internal_reason \\ nil) do
    metadata =
      metadata
      |> Map.merge(%{route_class: route_class})
      |> maybe_put_internal_reason(internal_reason)

    :telemetry.execute(
      @telemetry_prefix ++ [event],
      Map.merge(%{count: 1}, measurements),
      metadata
    )
  end

  defp maybe_put_internal_reason(metadata, internal_reason)
       when internal_reason in @bulkhead_reasons,
       do: Map.put(metadata, :internal_reason, internal_reason)

  defp maybe_put_internal_reason(metadata, _internal_reason), do: metadata

  defp sanitize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.take([:request_id, :key_prefix, :endpoint, :transport, :route_class, :method, :path])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp sanitize_metadata(_metadata), do: %{}

  defp elapsed_ms(started), do: max(System.monotonic_time(:millisecond) - started, 0)
end
