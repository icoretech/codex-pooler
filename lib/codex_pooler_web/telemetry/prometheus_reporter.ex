defmodule CodexPoolerWeb.Telemetry.PrometheusReporter do
  @moduledoc """
  Core's exporter and scalar metrics with immediately aggregated histograms.

  Core 1.2.1 retains raw distribution samples until a scrape. Keep those
  handlers out of the registry so memory depends on series and bucket count,
  rather than the number of observations between scrapes.
  """
  use Supervisor

  alias CodexPoolerWeb.Telemetry.HistogramCollector
  alias Telemetry.Metrics.Distribution
  alias TelemetryMetricsPrometheus.Core

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, :prometheus_metrics), start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, :prometheus_metrics)
    metrics = Keyword.fetch!(opts, :metrics)
    {histograms, scalars} = Enum.split_with(metrics, &match?(%Distribution{}, &1))

    children = [
      {Core, name: name, metrics: scalars, start_async: false},
      {HistogramCollector, name: name, metrics: histograms}
    ]

    # Core owns ETS. Restart both children together so attached handlers never
    # retain a table from a previous registry generation.
    Supervisor.init(children, strategy: :one_for_all)
  end

  def scrape(name \\ :prometheus_metrics) do
    %{aggregates_table_id: table} = Core.Registry.config(name)
    metrics = Core.Registry.metrics(name) ++ HistogramCollector.metrics(name)

    table
    |> Core.Aggregator.get_time_series()
    |> Core.Exporter.export(metrics)
  end
end
