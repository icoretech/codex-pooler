defmodule CodexPoolerWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  @type metric :: Telemetry.Metrics.t()
  @type repo_query_tags :: %{source: String.t(), command: String.t()}
  @type http_tags :: %{method: String.t(), status_class: String.t()}
  @type http_route_tags :: %{method: String.t(), route: String.t(), status_class: String.t()}
  @type admission_tags :: %{route_class: String.t(), transport: String.t()}
  @type admin_stats_reload_tags :: %{stage: String.t(), window: String.t(), scope: String.t()}
  @type admin_stats_build_tags :: %{outcome: String.t(), window: String.t(), scope: String.t()}
  @type request_logs_reload_tags :: %{stage: String.t(), scope: String.t()}
  @type stream_finalization_tags :: %{
          usage_status: String.t(),
          usage_source: String.t(),
          downstream_transport: String.t(),
          upstream_transport: String.t()
        }
  @type quota_cycle_decision_tags :: %{
          scope: String.t(),
          decision: String.t(),
          source: String.t()
        }

  @repo_query_buckets [0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5]
  @admission_queue_buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5]
  @admin_stats_duration_buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5]
  @admin_stats_windows ~w(1h 5h 24h 7d)
  @admin_stats_scopes ~w(selected_pool all_visible_pools)
  @admin_stats_reload_stages ~w(scheduled coalesced cancelled executed)
  @admin_stats_build_outcomes ~w(ok error)
  @request_logs_reload_stages ~w(initial_load filter_patch event_refresh)
  @request_logs_reload_scopes ~w(selected_pool all_pools)
  @stream_usage_statuses ~w(usage_known usage_unknown)
  @stream_usage_sources ~w(upstream_usage websocket_upstream_usage unknown)
  @stream_downstream_transports ~w(http_sse websocket unknown)
  @stream_upstream_transports ~w(http_sse websocket unknown)
  @quota_cycle_scopes ~w(account model)
  @quota_cycle_decisions ~w(
    same_cycle_refreshed
    anchored_confirmed
    floating_confirmed
    candidate
    rejected
    superseded_primary_rejected
  )
  @quota_cycle_sources ~w(provider_usage runtime unknown)
  @prometheus_reporter_disabled_oban_modes ~w(worker scheduler)
  @repo_source_pattern ~r/\A[a-zA-Z0-9_.-]+\z/
  @safe_route_pattern ~r/\A[a-zA-Z0-9_.*:\/{}-]+\z/
  @safe_tag_pattern ~r/\A[a-zA-Z0-9_.:-]+\z/
  @repo_source_query_patterns [
    ~r/\bfrom\s+"?([a-zA-Z0-9_.-]+)"?/i,
    ~r/\bjoin\s+"?([a-zA-Z0-9_.-]+)"?/i,
    ~r/\binsert\s+into\s+"?([a-zA-Z0-9_.-]+)"?/i,
    ~r/\bupdate\s+"?([a-zA-Z0-9_.-]+)"?/i,
    ~r/\bdelete\s+from\s+"?([a-zA-Z0-9_.-]+)"?/i,
    ~r/\btruncate\s+(?:table\s+)?"?([a-zA-Z0-9_.-]+)"?/i
  ]

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
        prometheus_reporter_child()
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
      counter("codex_pooler.http.request.count",
        event_name: [:phoenix, :endpoint, :stop],
        tags: [:method, :status_class],
        tag_values: &http_request_tag_values/1,
        description: "Total HTTP requests by method and status class."
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
      counter("codex_pooler.http.route.count",
        event_name: [:phoenix, :router_dispatch, :stop],
        tags: [:route, :method, :status_class],
        tag_values: &http_route_tag_values/1,
        description: "Total routed HTTP requests by route, method, and status class."
      ),
      counter("codex_pooler.repo.query.count",
        event_name: [:codex_pooler, :repo, :query],
        measurement: :total_time,
        tags: [:source, :command],
        tag_values: &repo_query_tag_values/1,
        description: "Total Ecto repository queries by source and SQL command."
      ),
      counter("codex_pooler.admin.stats.reload.count",
        event_name: [:codex_pooler, :admin, :stats_live, :reload],
        measurement: :count,
        tags: [:stage, :window, :scope],
        tag_values: &admin_stats_reload_tag_values/1,
        description: "Total admin stats dashboard reload events by stage, window, and scope."
      ),
      counter("codex_pooler.admin.request_logs.reload.count",
        event_name: [:codex_pooler, :admin, :request_logs, :reload],
        measurement: :count,
        tags: [:stage, :scope],
        tag_values: &request_logs_reload_tag_values/1,
        description: "Total admin request-log reloads by stage and scope."
      ),
      distribution("codex_pooler.admin.request_logs.reload.duration.seconds",
        event_name: [:codex_pooler, :admin, :request_logs, :reload],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:stage, :scope],
        tag_values: &request_logs_reload_tag_values/1,
        description: "Admin request-log reload duration by stage and scope.",
        reporter_options: [buckets: @admin_stats_duration_buckets]
      ),
      counter("codex_pooler.admin.stats.dashboard.build.count",
        event_name: [:codex_pooler, :admin, :stats, :dashboard, :build],
        measurement: :count,
        tags: [:outcome, :window, :scope],
        tag_values: &admin_stats_build_tag_values/1,
        description: "Total admin stats dashboard builds by outcome, window, and scope."
      ),
      distribution("codex_pooler.admin.stats.dashboard.build.duration.seconds",
        event_name: [:codex_pooler, :admin, :stats, :dashboard, :build],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:outcome, :window, :scope],
        tag_values: &admin_stats_build_tag_values/1,
        description: "Admin stats dashboard build duration by outcome, window, and scope.",
        reporter_options: [buckets: @admin_stats_duration_buckets]
      ),
      distribution("codex_pooler.repo.query.total_time.seconds",
        event_name: [:codex_pooler, :repo, :query],
        measurement: :total_time,
        unit: {:native, :second},
        tags: [:source, :command],
        tag_values: &repo_query_tag_values/1,
        description: "Total Ecto repository query time by source and SQL command.",
        reporter_options: [buckets: @repo_query_buckets]
      ),
      distribution("codex_pooler.repo.query.query_time.seconds",
        event_name: [:codex_pooler, :repo, :query],
        measurement: :query_time,
        unit: {:native, :second},
        tags: [:source, :command],
        tag_values: &repo_query_tag_values/1,
        description: "Ecto repository database execution time by source and SQL command.",
        reporter_options: [buckets: @repo_query_buckets]
      ),
      distribution("codex_pooler.repo.query.queue_time.seconds",
        event_name: [:codex_pooler, :repo, :query],
        measurement: :queue_time,
        unit: {:native, :second},
        tags: [:source, :command],
        tag_values: &repo_query_tag_values/1,
        description: "Ecto repository connection checkout queue time by source and SQL command.",
        reporter_options: [buckets: @repo_query_buckets]
      ),
      distribution("codex_pooler.repo.query.decode_time.seconds",
        event_name: [:codex_pooler, :repo, :query],
        measurement: :decode_time,
        unit: {:native, :second},
        tags: [:source, :command],
        tag_values: &repo_query_tag_values/1,
        description: "Ecto repository decode time by source and SQL command.",
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
      last_value("vm.memory.atom_used.bytes",
        event_name: [:vm, :memory],
        measurement: :atom_used,
        unit: :byte,
        description: "BEAM atom table memory used in bytes."
      ),
      last_value("vm.memory.code.bytes",
        event_name: [:vm, :memory],
        measurement: :code,
        unit: :byte,
        description: "BEAM loaded code memory in bytes."
      ),
      last_value("vm.memory.system.bytes",
        event_name: [:vm, :memory],
        measurement: :system,
        unit: :byte,
        description: "BEAM system memory in bytes."
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
      last_value("vm.total_run_queue_lengths.cpu",
        event_name: [:vm, :total_run_queue_lengths],
        measurement: :cpu,
        description: "CPU scheduler run queue length."
      ),
      last_value("vm.total_run_queue_lengths.io",
        event_name: [:vm, :total_run_queue_lengths],
        measurement: :io,
        description: "IO scheduler run queue length."
      ),
      counter("codex_pooler.gateway.admission.accepted.count",
        event_name: [:codex_pooler, :gateway, :admission, :accepted],
        tags: [:route_class, :transport],
        tag_values: &admission_tag_values/1,
        description: "Gateway admission requests accepted immediately."
      ),
      counter("codex_pooler.gateway.admission.enqueued.count",
        event_name: [:codex_pooler, :gateway, :admission, :enqueued],
        tags: [:route_class, :transport],
        tag_values: &admission_tag_values/1,
        description: "Gateway admission requests queued by the local bulkhead."
      ),
      counter("codex_pooler.gateway.admission.dequeued.count",
        event_name: [:codex_pooler, :gateway, :admission, :dequeued],
        tags: [:route_class, :transport],
        tag_values: &admission_tag_values/1,
        description: "Gateway admission requests dequeued into execution."
      ),
      counter("codex_pooler.gateway.admission.rejected.count",
        event_name: [:codex_pooler, :gateway, :admission, :rejected],
        tags: [:route_class, :transport],
        tag_values: &admission_tag_values/1,
        description: "Gateway admission requests rejected by the local bulkhead."
      ),
      counter("codex_pooler.gateway.admission.timeout.count",
        event_name: [:codex_pooler, :gateway, :admission, :timeout],
        tags: [:route_class, :transport],
        tag_values: &admission_tag_values/1,
        description: "Gateway admission requests that timed out while queued."
      ),
      distribution("codex_pooler.gateway.admission.dequeued_time.seconds",
        event_name: [:codex_pooler, :gateway, :admission, :dequeued],
        measurement: :queued_ms,
        unit: {:millisecond, :second},
        tags: [:route_class, :transport],
        tag_values: &admission_tag_values/1,
        description: "Gateway admission queue time for dequeued requests.",
        reporter_options: [buckets: @admission_queue_buckets]
      ),
      distribution("codex_pooler.gateway.admission.timeout_time.seconds",
        event_name: [:codex_pooler, :gateway, :admission, :timeout],
        measurement: :queued_ms,
        unit: {:millisecond, :second},
        tags: [:route_class, :transport],
        tag_values: &admission_tag_values/1,
        description: "Gateway admission queue time for timed-out requests.",
        reporter_options: [buckets: @admission_queue_buckets]
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
      ),
      counter("codex_pooler.gateway.stream.finalization.count",
        event_name: [:codex_pooler, :gateway, :stream, :finalization],
        measurement: :count,
        tags: [:usage_status, :usage_source, :downstream_transport, :upstream_transport],
        tag_values: &stream_finalization_tag_values/1,
        description: "Finalized gateway streams by bounded usage and transport metadata."
      ),
      counter("codex_pooler.quota.cycle.decision.count",
        event_name: [:codex_pooler, :quota, :cycle, :decision],
        measurement: :count,
        tags: [:scope, :decision, :source],
        tag_values: &quota_cycle_decision_tag_values/1,
        description: "Quota cycle decisions by bounded scope, decision, and source class."
      )
    ]
  end

  defp perf_probe_child do
    CodexPooler.Dev.gateway_perf_probe_child()
  end

  @spec prometheus_reporter_child() :: {module(), keyword()} | nil
  defp prometheus_reporter_child do
    if prometheus_reporter_enabled?() do
      {TelemetryMetricsPrometheus.Core, metrics: prometheus_metrics()}
    end
  end

  @spec prometheus_reporter_enabled?() :: boolean()
  defp prometheus_reporter_enabled? do
    System.get_env("OBAN_MODE") not in @prometheus_reporter_disabled_oban_modes
  end

  @spec repo_query_tag_values(map()) :: repo_query_tags()
  defp repo_query_tag_values(metadata) do
    %{source: repo_query_source(metadata), command: repo_query_command(metadata[:query])}
  end

  @spec repo_query_source(map()) :: String.t()
  defp repo_query_source(metadata) do
    repo_query_source_value(metadata[:source]) ||
      repo_query_source_from_query(metadata[:query]) ||
      "unknown"
  end

  @spec repo_query_source_value(term()) :: String.t() | nil
  defp repo_query_source_value(nil), do: nil

  defp repo_query_source_value(source) when is_atom(source) do
    source
    |> Atom.to_string()
    |> repo_query_source_value()
  end

  defp repo_query_source_value(source) when is_binary(source) do
    source = String.trim(source)

    if String.length(source) <= 80 and Regex.match?(@repo_source_pattern, source) do
      source
    else
      nil
    end
  end

  defp repo_query_source_value(_source), do: nil

  @spec repo_query_source_from_query(term()) :: String.t() | nil
  defp repo_query_source_from_query(query) when is_binary(query) do
    Enum.find_value(@repo_source_query_patterns, fn pattern ->
      case Regex.run(pattern, query, capture: :all_but_first) do
        [source] -> repo_query_source_value(source)
        _other -> nil
      end
    end)
  end

  defp repo_query_source_from_query(_query), do: nil

  @spec repo_query_command(term()) :: String.t()
  defp repo_query_command(query) when is_binary(query) do
    case Regex.run(~r/\A\s*(?:--[^\n]*\n\s*)*([a-zA-Z]+)/, query, capture: :all_but_first) do
      [command] -> normalize_repo_command(command)
      _other -> "unknown"
    end
  end

  defp repo_query_command(_query), do: "unknown"

  @spec normalize_repo_command(String.t()) :: String.t()
  defp normalize_repo_command(command) do
    command =
      command
      |> String.downcase()
      |> String.trim()

    cond do
      command in ~w(select insert update delete begin commit rollback truncate) ->
        command

      Regex.match?(~r/\A[a-z]+\z/, command) ->
        "other"

      true ->
        "unknown"
    end
  end

  @spec http_request_tag_values(map()) :: http_tags()
  defp http_request_tag_values(metadata) do
    conn = metadata[:conn]

    %{
      method: safe_tag_value(conn_value(conn, :method), "unknown"),
      status_class: status_class(conn_value(conn, :status))
    }
  end

  @spec http_route_tag_values(map()) :: http_route_tags()
  defp http_route_tag_values(metadata) do
    metadata
    |> http_request_tag_values()
    |> Map.put(:route, safe_route(metadata[:route]))
  end

  @spec admission_tag_values(map()) :: admission_tags()
  defp admission_tag_values(metadata) do
    %{
      route_class: safe_tag_value(metadata[:route_class], "unknown"),
      transport: safe_tag_value(metadata[:transport], "unknown")
    }
  end

  @spec admin_stats_reload_tag_values(map()) :: admin_stats_reload_tags()
  defp admin_stats_reload_tag_values(metadata) do
    %{
      stage: admin_stats_reload_stage(metadata[:stage]),
      window: admin_stats_window(metadata[:window]),
      scope: admin_stats_scope(metadata[:scope])
    }
  end

  @spec request_logs_reload_tag_values(map()) :: request_logs_reload_tags()
  defp request_logs_reload_tag_values(metadata) do
    %{
      stage: request_logs_reload_stage(metadata[:stage]),
      scope: request_logs_reload_scope(metadata[:scope])
    }
  end

  @spec admin_stats_build_tag_values(map()) :: admin_stats_build_tags()
  defp admin_stats_build_tag_values(metadata) do
    %{
      outcome: admin_stats_build_outcome(metadata[:outcome]),
      window: admin_stats_window(metadata[:window]),
      scope: admin_stats_scope(metadata[:scope])
    }
  end

  @spec admin_stats_window(term()) :: String.t()
  defp admin_stats_window(value), do: admin_stats_enum_value(value, @admin_stats_windows)

  @spec admin_stats_scope(term()) :: String.t()
  defp admin_stats_scope(value), do: admin_stats_enum_value(value, @admin_stats_scopes)

  @spec admin_stats_reload_stage(term()) :: String.t()
  defp admin_stats_reload_stage(value),
    do: admin_stats_enum_value(value, @admin_stats_reload_stages)

  @spec admin_stats_build_outcome(term()) :: String.t()
  defp admin_stats_build_outcome(value),
    do: admin_stats_enum_value(value, @admin_stats_build_outcomes)

  @spec request_logs_reload_stage(term()) :: String.t()
  defp request_logs_reload_stage(value),
    do: admin_stats_enum_value(value, @request_logs_reload_stages)

  @spec request_logs_reload_scope(term()) :: String.t()
  defp request_logs_reload_scope(:all_visible_pools), do: "all_pools"
  defp request_logs_reload_scope("all_visible_pools"), do: "all_pools"

  defp request_logs_reload_scope(value),
    do: admin_stats_enum_value(value, @request_logs_reload_scopes)

  @spec stream_finalization_tag_values(map()) :: stream_finalization_tags()
  defp stream_finalization_tag_values(metadata) do
    %{
      usage_status: admin_stats_enum_value(metadata[:usage_status], @stream_usage_statuses),
      usage_source: admin_stats_enum_value(metadata[:usage_source], @stream_usage_sources),
      downstream_transport:
        admin_stats_enum_value(metadata[:downstream_transport], @stream_downstream_transports),
      upstream_transport:
        admin_stats_enum_value(metadata[:upstream_transport], @stream_upstream_transports)
    }
  end

  @spec quota_cycle_decision_tag_values(map()) :: quota_cycle_decision_tags()
  defp quota_cycle_decision_tag_values(metadata) do
    %{
      scope: admin_stats_enum_value(metadata[:scope], @quota_cycle_scopes),
      decision: admin_stats_enum_value(metadata[:decision], @quota_cycle_decisions),
      source: admin_stats_enum_value(metadata[:source], @quota_cycle_sources)
    }
  end

  @spec admin_stats_enum_value(term(), [String.t()]) :: String.t()
  defp admin_stats_enum_value(value, allowed_values) when is_atom(value) do
    value
    |> Atom.to_string()
    |> admin_stats_enum_value(allowed_values)
  end

  defp admin_stats_enum_value(value, allowed_values) when is_binary(value) do
    value = String.trim(value)

    if value in allowed_values do
      value
    else
      "unknown"
    end
  end

  defp admin_stats_enum_value(_value, _allowed_values), do: "unknown"

  @spec conn_value(term(), atom()) :: term()
  defp conn_value(%{method: method}, :method), do: method
  defp conn_value(%{status: status}, :status), do: status
  defp conn_value(_conn, _key), do: nil

  @spec status_class(term()) :: String.t()
  defp status_class(status) when is_integer(status) and status >= 100 and status <= 599 do
    "#{div(status, 100)}xx"
  end

  defp status_class(_status), do: "unknown"

  @spec safe_route(term()) :: String.t()
  defp safe_route(route) when is_binary(route) do
    route = String.trim(route)

    if route != "" and String.length(route) <= 120 and Regex.match?(@safe_route_pattern, route) do
      route
    else
      "unknown"
    end
  end

  defp safe_route(_route), do: "unknown"

  @spec safe_tag_value(term(), String.t()) :: String.t()
  defp safe_tag_value(nil, fallback), do: fallback

  defp safe_tag_value(value, fallback) when is_atom(value) do
    value
    |> Atom.to_string()
    |> safe_tag_value(fallback)
  end

  defp safe_tag_value(value, fallback) when is_binary(value) do
    value = String.trim(value)

    if value != "" and String.length(value) <= 80 and Regex.match?(@safe_tag_pattern, value) do
      value
    else
      fallback
    end
  end

  defp safe_tag_value(_value, fallback), do: fallback
end
