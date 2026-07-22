defmodule CodexPoolerWeb.TelemetryTest do
  use ExUnit.Case, async: false

  setup do
    original_oban_mode = System.get_env("OBAN_MODE")

    on_exit(fn -> restore_env("OBAN_MODE", original_oban_mode) end)
  end

  test "starts telemetry poller with default VM measurements enabled" do
    assert {:ok, {_supervisor, children}} = CodexPoolerWeb.Telemetry.init(:ok)

    assert %{
             id: :telemetry_poller,
             start: {:telemetry_poller, :start_link, [[period: 10_000]]}
           } = Enum.find(children, &(&1.id == :telemetry_poller))
  end

  test "starts prometheus reporter for HTTP-serving roles" do
    for role <- [nil, "web", "all"] do
      set_oban_mode(role)

      assert :prometheus_metrics in telemetry_child_ids()
    end
  end

  test "skips prometheus reporter for worker and scheduler roles" do
    for role <- ~w(worker scheduler) do
      System.put_env("OBAN_MODE", role)

      child_ids = telemetry_child_ids()

      assert CodexPoolerWeb.Telemetry.MemorySampler in child_ids
      assert :telemetry_poller in child_ids
      refute :prometheus_metrics in child_ids
    end
  end

  test "exports BEAM memory category and process count Prometheus metrics" do
    metric_names =
      CodexPoolerWeb.Telemetry.prometheus_metrics()
      |> Enum.map(&metric_name/1)

    assert "vm.memory.total.bytes" in metric_names
    assert "vm.memory.processes.bytes" in metric_names
    assert "vm.memory.processes_used.bytes" in metric_names
    assert "vm.memory.binary.bytes" in metric_names
    assert "vm.memory.ets.bytes" in metric_names
    assert "vm.memory.atom.bytes" in metric_names
    assert "vm.memory.atom_used.bytes" in metric_names
    assert "vm.memory.code.bytes" in metric_names
    assert "vm.memory.system.bytes" in metric_names
    assert "vm.system_counts.process_count" in metric_names
    assert "vm.system_counts.port_count" in metric_names
    assert "vm.total_run_queue_lengths.cpu" in metric_names
    assert "vm.total_run_queue_lengths.io" in metric_names
  end

  test "exports Ecto repo query count and latency Prometheus metrics by source and command" do
    metrics = CodexPoolerWeb.Telemetry.prometheus_metrics()

    assert %Telemetry.Metrics.Counter{} =
             metric_by_name(metrics, "codex_pooler.repo.query.count")

    for name <- [
          "codex_pooler.repo.query.total_time.seconds",
          "codex_pooler.repo.query.query_time.seconds",
          "codex_pooler.repo.query.queue_time.seconds",
          "codex_pooler.repo.query.decode_time.seconds"
        ] do
      assert %Telemetry.Metrics.Distribution{
               event_name: [:codex_pooler, :repo, :query],
               tags: [:source, :command],
               reporter_options: reporter_options
             } = metric_by_name(metrics, name)

      assert Keyword.fetch!(reporter_options, :buckets) == [
               0.001,
               0.0025,
               0.005,
               0.01,
               0.025,
               0.05,
               0.1,
               0.25,
               0.5,
               1,
               2,
               5
             ]
    end
  end

  test "normalizes Ecto source tags without exposing SQL text" do
    metric =
      CodexPoolerWeb.Telemetry.prometheus_metrics()
      |> metric_by_name("codex_pooler.repo.query.count")

    assert %{source: "requests", command: "select"} =
             metric.tag_values.(%{source: "requests", query: "SELECT * FROM requests"})

    assert %{source: "requests", command: "insert"} =
             metric.tag_values.(%{query: ~s|INSERT INTO "requests" (id) VALUES ($1)|})

    assert %{source: "request_logs", command: "update"} =
             metric.tag_values.(%{query: "UPDATE request_logs SET updated_at = $1"})

    assert %{source: "unknown", command: "unknown"} = metric.tag_values.(%{})

    assert %{source: source} =
             metric.tag_values.(%{source: "SELECT * FROM requests WHERE secret = $1"})

    assert source == "unknown"
  end

  test "exports HTTP request and route counters with low-cardinality tags" do
    metrics = CodexPoolerWeb.Telemetry.prometheus_metrics()

    request_metric = metric_by_name(metrics, "codex_pooler.http.request.count")

    assert %Telemetry.Metrics.Counter{
             event_name: [:phoenix, :endpoint, :stop],
             tags: [:method, :status_class]
           } = request_metric

    assert %{method: "POST", status_class: "5xx"} =
             request_metric.tag_values.(%{conn: %{method: "POST", status: 503}})

    route_metric = metric_by_name(metrics, "codex_pooler.http.route.count")

    assert %Telemetry.Metrics.Counter{
             event_name: [:phoenix, :router_dispatch, :stop],
             tags: [:route, :method, :status_class]
           } = route_metric

    assert %{method: "GET", route: "/backend-api/codex/responses", status_class: "2xx"} =
             route_metric.tag_values.(%{
               conn: %{method: "GET", status: 200},
               route: "/backend-api/codex/responses"
             })

    assert %{method: "unknown", route: "unknown", status_class: "unknown"} =
             route_metric.tag_values.(%{conn: %{method: "unsafe method", status: nil}, route: ""})
  end

  test "exports gateway admission pressure metrics" do
    metrics = CodexPoolerWeb.Telemetry.prometheus_metrics()

    for {name, event} <- [
          {"codex_pooler.gateway.admission.accepted.count", :accepted},
          {"codex_pooler.gateway.admission.enqueued.count", :enqueued},
          {"codex_pooler.gateway.admission.dequeued.count", :dequeued},
          {"codex_pooler.gateway.admission.rejected.count", :rejected},
          {"codex_pooler.gateway.admission.timeout.count", :timeout}
        ] do
      assert %Telemetry.Metrics.Counter{
               event_name: [:codex_pooler, :gateway, :admission, ^event],
               tags: [:route_class, :transport]
             } = metric_by_name(metrics, name)
    end

    for {name, event} <- [
          {"codex_pooler.gateway.admission.dequeued_time.seconds", :dequeued},
          {"codex_pooler.gateway.admission.timeout_time.seconds", :timeout}
        ] do
      assert %Telemetry.Metrics.Distribution{
               event_name: [:codex_pooler, :gateway, :admission, ^event],
               tags: [:route_class, :transport],
               unit: :second,
               reporter_options: reporter_options
             } = metric_by_name(metrics, name)

      assert Keyword.fetch!(reporter_options, :buckets) == [
               0.005,
               0.01,
               0.025,
               0.05,
               0.1,
               0.25,
               0.5,
               1,
               2,
               5
             ]
    end

    metric = metric_by_name(metrics, "codex_pooler.gateway.admission.accepted.count")

    assert %{route_class: "runtime", transport: "http_sse"} =
             metric.tag_values.(%{route_class: "runtime", transport: "http_sse"})

    assert %{route_class: "unknown", transport: "unknown"} =
             metric.tag_values.(%{route_class: "unsafe class", transport: nil})
  end

  test "exports stream finalization and quota cycle counters with exact bounded tags" do
    metrics = CodexPoolerWeb.Telemetry.prometheus_metrics()

    assert %Telemetry.Metrics.Counter{
             event_name: [:codex_pooler, :gateway, :stream, :finalization],
             measurement: :count,
             tags: [:usage_status, :usage_source, :downstream_transport, :upstream_transport]
           } =
             stream_metric =
             metric_by_name(metrics, "codex_pooler.gateway.stream.finalization.count")

    assert %{
             usage_status: "usage_known",
             usage_source: "upstream_usage",
             downstream_transport: "http_sse",
             upstream_transport: "websocket"
           } =
             stream_metric.tag_values.(%{
               usage_status: :usage_known,
               usage_source: "upstream_usage",
               downstream_transport: :http_sse,
               upstream_transport: "websocket",
               request_id: "request-identifier",
               model: "model-identifier",
               error: "raw error"
             })

    assert %{
             usage_status: "unknown",
             usage_source: "unknown",
             downstream_transport: "unknown",
             upstream_transport: "unknown"
           } =
             stream_metric.tag_values.(%{
               usage_status: "failed",
               usage_source: "sse_usage_missing",
               downstream_transport: "/backend-api/codex/responses",
               upstream_transport: nil
             })

    assert %Telemetry.Metrics.Counter{
             event_name: [:codex_pooler, :quota, :cycle, :decision],
             measurement: :count,
             tags: [:scope, :decision, :source]
           } =
             quota_metric =
             metric_by_name(metrics, "codex_pooler.quota.cycle.decision.count")

    assert %{scope: "model", decision: "superseded_primary_rejected", source: "runtime"} =
             quota_metric.tag_values.(%{
               scope: :model,
               decision: :superseded_primary_rejected,
               source: :runtime,
               upstream_identity_id: "identity-identifier",
               assignment_id: "assignment-identifier",
               reset_at: "2026-07-28T17:09:00Z"
             })

    assert %{scope: "unknown", decision: "unknown", source: "unknown"} =
             quota_metric.tag_values.(%{
               scope: "account-id",
               decision: "candidate-123",
               source: "provider-url"
             })
  end

  test "exports admin request-log reload metrics with bounded tags" do
    metrics = CodexPoolerWeb.Telemetry.prometheus_metrics()

    admin_request_log_metric_names =
      metrics
      |> Enum.map(&metric_name/1)
      |> Enum.filter(&String.starts_with?(&1, "codex_pooler.admin.request_logs."))
      |> Enum.sort()

    assert admin_request_log_metric_names == [
             "codex_pooler.admin.request_logs.reload.count",
             "codex_pooler.admin.request_logs.reload.duration.seconds"
           ]

    assert %Telemetry.Metrics.Counter{
             event_name: [:codex_pooler, :admin, :request_logs, :reload],
             measurement: :count,
             tags: [:stage, :scope]
           } =
             reload_count_metric =
             metric_by_name(metrics, "codex_pooler.admin.request_logs.reload.count")

    assert %{stage: "initial_load", scope: "selected_pool"} =
             reload_count_metric.tag_values.(%{
               stage: :initial_load,
               scope: :selected_pool,
               pool_id: "pool-123",
               request_id: "request-123",
               model: "gpt-5.5",
               user_id: "user-123",
               path: "/admin/request-logs?status=failed",
               query: "SELECT * FROM requests",
               params: ["raw-param"]
             })

    assert %{stage: "filter_patch", scope: "all_pools"} =
             reload_count_metric.tag_values.(%{stage: "filter_patch", scope: :all_pools})

    assert %{stage: "event_refresh", scope: "all_pools"} =
             reload_count_metric.tag_values.(%{stage: :event_refresh, scope: :all_visible_pools})

    assert %{stage: "unknown", scope: "unknown"} =
             reload_count_metric.tag_values.(%{stage: "resubscribe", scope: "pool-123"})

    assert %Telemetry.Metrics.Distribution{
             event_name: [:codex_pooler, :admin, :request_logs, :reload],
             measurement: measurement,
             unit: :second,
             tags: [:stage, :scope],
             reporter_options: reporter_options
           } = metric_by_name(metrics, "codex_pooler.admin.request_logs.reload.duration.seconds")

    assert measurement.(%{duration: 1_000_000_000}) == 1.0

    assert Keyword.fetch!(reporter_options, :buckets) == [
             0.005,
             0.01,
             0.025,
             0.05,
             0.1,
             0.25,
             0.5,
             1,
             2,
             5
           ]
  end

  test "exports admin stats Prometheus metrics with exact names and bounded tags" do
    metrics = CodexPoolerWeb.Telemetry.prometheus_metrics()

    admin_metric_names =
      metrics
      |> Enum.map(&metric_name/1)
      |> Enum.filter(&String.starts_with?(&1, "codex_pooler.admin.stats."))
      |> Enum.sort()

    assert admin_metric_names == [
             "codex_pooler.admin.stats.dashboard.build.count",
             "codex_pooler.admin.stats.dashboard.build.duration.seconds",
             "codex_pooler.admin.stats.reload.count"
           ]

    assert %Telemetry.Metrics.Counter{
             event_name: [:codex_pooler, :admin, :stats_live, :reload],
             measurement: :count,
             tags: [:stage, :window, :scope]
           } = reload_metric = metric_by_name(metrics, "codex_pooler.admin.stats.reload.count")

    assert %{stage: "scheduled", window: "1h", scope: "selected_pool"} =
             reload_metric.tag_values.(%{
               stage: :scheduled,
               window: "1h",
               scope: :selected_pool,
               pid: self()
             })

    assert %Telemetry.Metrics.Counter{
             event_name: [:codex_pooler, :admin, :stats, :dashboard, :build],
             measurement: :count,
             tags: [:outcome, :window, :scope]
           } =
             build_count_metric =
             metric_by_name(metrics, "codex_pooler.admin.stats.dashboard.build.count")

    assert %{outcome: "ok", window: "7d", scope: "all_visible_pools"} =
             build_count_metric.tag_values.(%{
               outcome: :ok,
               window: "7d",
               scope: "all_visible_pools"
             })

    assert %Telemetry.Metrics.Distribution{
             event_name: [:codex_pooler, :admin, :stats, :dashboard, :build],
             measurement: measurement,
             unit: :second,
             tags: [:outcome, :window, :scope],
             reporter_options: reporter_options
           } =
             metric_by_name(metrics, "codex_pooler.admin.stats.dashboard.build.duration.seconds")

    assert measurement.(%{duration: 1_000_000_000}) == 1.0

    assert Keyword.fetch!(reporter_options, :buckets) == [
             0.005,
             0.01,
             0.025,
             0.05,
             0.1,
             0.25,
             0.5,
             1,
             2,
             5
           ]
  end

  @tag :admin_stats_invalid
  test "normalizes invalid admin stats metric tags to unknown" do
    metrics = CodexPoolerWeb.Telemetry.prometheus_metrics()
    reload_metric = metric_by_name(metrics, "codex_pooler.admin.stats.reload.count")
    build_metric = metric_by_name(metrics, "codex_pooler.admin.stats.dashboard.build.count")

    assert %{stage: "unknown", window: "unknown", scope: "unknown"} =
             reload_metric.tag_values.(%{
               stage: "reloaded",
               window: "30d",
               scope: "pool-123",
               pid: self(),
               request_id: "request-123"
             })

    assert %{outcome: "unknown", window: "unknown", scope: "unknown"} =
             build_metric.tag_values.(%{
               outcome: "timeout",
               window: nil,
               scope: "",
               error: "database timeout"
             })
  end

  defp metric_by_name(metrics, name) do
    Enum.find(metrics, &(metric_name(&1) == name))
  end

  defp metric_name(metric) do
    Enum.map_join(metric.name, ".", &to_string/1)
  end

  defp telemetry_child_ids do
    {:ok, {_supervisor, children}} = CodexPoolerWeb.Telemetry.init(:ok)

    Enum.map(children, & &1.id)
  end

  defp set_oban_mode(nil), do: System.delete_env("OBAN_MODE")
  defp set_oban_mode(role), do: System.put_env("OBAN_MODE", role)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
