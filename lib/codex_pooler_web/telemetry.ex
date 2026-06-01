defmodule CodexPoolerWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  alias CodexPooler.Dev.GatewayPerfProbe

  @type metric :: Telemetry.Metrics.t()

  @repo_query_buckets [0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5]
  @repo_source_pattern ~r/\A[a-zA-Z0-9_.-]+\z/

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    CodexPoolerWeb.RequestLogger.attach()

    children =
      [
        perf_probe_child(),
        CodexPoolerWeb.Telemetry.MemorySampler,
        {:telemetry_poller, period: 10_000},
        {TelemetryMetricsPrometheus.Core, metrics: prometheus_metrics()}
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("codex_pooler.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("codex_pooler.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("codex_pooler.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("codex_pooler.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("codex_pooler.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  @spec prometheus_metrics() :: [metric()]
  def prometheus_metrics do
    [
      counter("phoenix.endpoint.stop.count",
        event_name: [:phoenix, :endpoint, :stop],
        measurement: :duration,
        description: "Total Phoenix endpoint requests."
      ),
      distribution("phoenix.endpoint.stop.duration.seconds",
        event_name: [:phoenix, :endpoint, :stop],
        measurement: :duration,
        unit: {:native, :second},
        description: "Phoenix endpoint request duration.",
        reporter_options: [buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5]]
      ),
      distribution("phoenix.router_dispatch.stop.duration.seconds",
        event_name: [:phoenix, :router_dispatch, :stop],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:route],
        description: "Phoenix router dispatch duration by route.",
        reporter_options: [buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5]]
      ),
      counter("codex_pooler.repo.query.count",
        event_name: [:codex_pooler, :repo, :query],
        measurement: :total_time,
        tags: [:source],
        tag_values: &repo_query_tag_values/1,
        description: "Total Ecto repository queries by source."
      ),
      distribution("codex_pooler.repo.query.total_time.seconds",
        event_name: [:codex_pooler, :repo, :query],
        measurement: :total_time,
        unit: {:native, :second},
        tags: [:source],
        tag_values: &repo_query_tag_values/1,
        description: "Total Ecto repository query time by source.",
        reporter_options: [buckets: @repo_query_buckets]
      ),
      distribution("codex_pooler.repo.query.query_time.seconds",
        event_name: [:codex_pooler, :repo, :query],
        measurement: :query_time,
        unit: {:native, :second},
        tags: [:source],
        tag_values: &repo_query_tag_values/1,
        description: "Ecto repository database execution time by source.",
        reporter_options: [buckets: @repo_query_buckets]
      ),
      distribution("codex_pooler.repo.query.queue_time.seconds",
        event_name: [:codex_pooler, :repo, :query],
        measurement: :queue_time,
        unit: {:native, :second},
        tags: [:source],
        tag_values: &repo_query_tag_values/1,
        description: "Ecto repository connection checkout queue time by source.",
        reporter_options: [buckets: @repo_query_buckets]
      ),
      distribution("codex_pooler.repo.query.decode_time.seconds",
        event_name: [:codex_pooler, :repo, :query],
        measurement: :decode_time,
        unit: {:native, :second},
        tags: [:source],
        tag_values: &repo_query_tag_values/1,
        description: "Ecto repository decode time by source.",
        reporter_options: [buckets: @repo_query_buckets]
      ),
      last_value("vm.memory.total.bytes",
        event_name: [:vm, :memory],
        measurement: :total,
        unit: :byte,
        description: "Total BEAM memory in bytes."
      ),
      last_value("vm.memory.processes.bytes",
        event_name: [:vm, :memory],
        measurement: :processes,
        unit: :byte,
        description: "BEAM process memory in bytes."
      ),
      last_value("vm.memory.processes_used.bytes",
        event_name: [:vm, :memory],
        measurement: :processes_used,
        unit: :byte,
        description: "BEAM process memory actively used in bytes."
      ),
      last_value("vm.memory.binary.bytes",
        event_name: [:vm, :memory],
        measurement: :binary,
        unit: :byte,
        description: "BEAM binary memory in bytes."
      ),
      last_value("vm.memory.ets.bytes",
        event_name: [:vm, :memory],
        measurement: :ets,
        unit: :byte,
        description: "BEAM ETS memory in bytes."
      ),
      last_value("vm.memory.atom.bytes",
        event_name: [:vm, :memory],
        measurement: :atom,
        unit: :byte,
        description: "BEAM atom table memory in bytes."
      ),
      last_value("vm.memory.code.bytes",
        event_name: [:vm, :memory],
        measurement: :code,
        unit: :byte,
        description: "BEAM loaded code memory in bytes."
      ),
      last_value("vm.system_counts.process_count",
        event_name: [:vm, :system_counts],
        measurement: :process_count,
        description: "Current BEAM process count."
      ),
      last_value("vm.system_counts.port_count",
        event_name: [:vm, :system_counts],
        measurement: :port_count,
        description: "Current BEAM port count."
      ),
      last_value("vm.total_run_queue_lengths.total",
        event_name: [:vm, :total_run_queue_lengths],
        measurement: :total,
        description: "Total BEAM scheduler run queue length."
      ),
      counter("codex_pooler.gateway.stream_buffer.oversized.count",
        event_name: [:codex_pooler, :gateway, :stream_buffer, :oversized],
        measurement: :count,
        tags: [:buffer, :transport, :route_class, :endpoint],
        description: "Oversized incomplete stream buffers released without retention."
      ),
      distribution("codex_pooler.gateway.stream_buffer.oversized.bytes",
        event_name: [:codex_pooler, :gateway, :stream_buffer, :oversized],
        measurement: :bytes,
        tags: [:buffer, :transport, :route_class, :endpoint],
        unit: :byte,
        description: "Size of oversized incomplete stream buffers.",
        reporter_options: [buckets: [65_536, 131_072, 262_144, 524_288, 1_048_576, 2_097_152]]
      ),
      counter("codex_pooler.gateway.stream_buffer.truncated.count",
        event_name: [:codex_pooler, :gateway, :stream_buffer, :truncated],
        measurement: :count,
        tags: [:buffer, :transport, :route_class, :endpoint],
        description: "Retained stream bodies truncated to their bounded suffix."
      ),
      distribution("codex_pooler.gateway.stream_buffer.truncated.bytes",
        event_name: [:codex_pooler, :gateway, :stream_buffer, :truncated],
        measurement: :bytes,
        tags: [:buffer, :transport, :route_class, :endpoint],
        unit: :byte,
        description: "Pre-truncation retained stream body sizes.",
        reporter_options: [buckets: [65_536, 131_072, 262_144, 524_288, 1_048_576, 2_097_152]]
      )
    ]
  end

  defp perf_probe_child do
    if GatewayPerfProbe.enabled?(), do: GatewayPerfProbe
  end

  defp repo_query_tag_values(metadata) do
    %{source: repo_query_source(metadata[:source])}
  end

  defp repo_query_source(nil), do: "unknown"

  defp repo_query_source(source) when is_atom(source) do
    source
    |> Atom.to_string()
    |> repo_query_source()
  end

  defp repo_query_source(source) when is_binary(source) do
    source = String.trim(source)

    if String.length(source) <= 80 and Regex.match?(@repo_source_pattern, source) do
      source
    else
      "unknown"
    end
  end

  defp repo_query_source(_source), do: "unknown"
end
