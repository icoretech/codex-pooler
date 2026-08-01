defmodule CodexPoolerWeb.Telemetry.AdmissionSampler do
  @moduledoc false

  use GenServer

  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.Telemetry

  @event [:codex_pooler, :gateway, :admission, :saturation]
  @default_interval_ms 10_000
  @default_timeout_ms 1_000

  @type snapshot :: %{
          required(RouteClass.t()) => %{
            required(:running) => non_neg_integer(),
            required(:queued) => non_neg_integer()
          }
        }

  @type state :: %{
          admission_server: GenServer.server(),
          interval_ms: pos_integer(),
          last_snapshot: snapshot(),
          snapshot_reader: (-> {:ok, snapshot()} | {:error, :timeout | :unavailable}),
          timeout_ms: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    if Keyword.get(opts, :enabled?, Telemetry.prometheus_reporter_enabled?()) do
      state = %{
        admission_server: Keyword.get(opts, :admission_server, Admission),
        interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
        last_snapshot: zero_snapshot(),
        snapshot_reader: snapshot_reader(opts),
        timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      }

      send(self(), :sample)
      {:ok, state}
    else
      :ignore
    end
  end

  @impl GenServer
  def handle_info(:sample, state) do
    state =
      try do
        state
        |> next_snapshot()
        |> publish(state)
      catch
        _kind, _reason -> publish(state.last_snapshot, state)
      after
        Process.send_after(self(), :sample, state.interval_ms)
      end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp publish(snapshot, state) do
    Enum.each(RouteClass.all(), fn route_class ->
      %{running: running, queued: queued} = Map.fetch!(snapshot, route_class)
      :telemetry.execute(@event, %{running: running, queued: queued}, %{route_class: route_class})
    end)

    %{state | last_snapshot: snapshot}
  end

  defp zero_snapshot do
    Map.new(RouteClass.all(), &{&1, %{running: 0, queued: 0}})
  end

  defp normalize_snapshot(snapshot) when is_map(snapshot) do
    Map.new(RouteClass.all(), fn route_class ->
      values = Map.get(snapshot, route_class, %{})

      {route_class,
       %{
         running: non_negative(Map.get(values, :running)),
         queued: non_negative(Map.get(values, :queued))
       }}
    end)
  end

  defp normalize_snapshot(_snapshot), do: zero_snapshot()

  defp non_negative(value) when is_integer(value), do: max(value, 0)
  defp non_negative(_value), do: 0

  defp next_snapshot(state) do
    case state.snapshot_reader.() do
      {:ok, snapshot} -> normalize_snapshot(snapshot)
      {:error, _reason} -> state.last_snapshot
    end
  end

  defp snapshot_reader(opts) do
    case Keyword.fetch(opts, :snapshot_reader) do
      {:ok, reader} when is_function(reader, 0) ->
        reader

      _missing ->
        fn ->
          Admission.saturation(
            Keyword.get(opts, :admission_server, Admission),
            Keyword.get(opts, :timeout_ms, @default_timeout_ms)
          )
        end
    end
  end
end
