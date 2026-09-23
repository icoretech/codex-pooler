defmodule CodexPoolerWeb.Telemetry.PrometheusReporterTest do
  use ExUnit.Case, async: false

  alias CodexPoolerWeb.Telemetry.PrometheusReporter

  @detection_timeout_ms 15_000

  test "HTTP scrapes reuse the scheduled Core rendering" do
    registry = unique_name()
    event = [:codex_pooler_test, :cached, unique_event_atom()]
    metric = Telemetry.Metrics.sum(event, event_name: event, measurement: :count)

    start_supervised!({TelemetryMetricsPrometheus.Core, metrics: [metric], name: registry, start_async: false})

    reporter = unique_name()

    pid =
      start_supervised!({PrometheusReporter, name: reporter, prometheus_name: registry, interval_ms: 60_000})

    initial = PrometheusReporter.scrape(reporter)
    :telemetry.execute(event, %{count: 7}, %{})
    assert PrometheusReporter.scrape(reporter) == initial
    send(pid, :fold)
    :sys.get_state(pid)
    refute PrometheusReporter.scrape(reporter) == initial
  end

  test "fold/1 refreshes the cached rendering synchronously" do
    registry = unique_name()
    event = [:codex_pooler_test, :sync_fold, unique_event_atom()]
    metric = Telemetry.Metrics.sum(event, event_name: event, measurement: :count)

    start_supervised!({TelemetryMetricsPrometheus.Core, metrics: [metric], name: registry, start_async: false})

    reporter = unique_name()

    start_supervised!({PrometheusReporter, name: reporter, prometheus_name: registry, interval_ms: 60_000, fold_notify: self()})

    initial = PrometheusReporter.scrape(reporter)
    :telemetry.execute(event, %{count: 3}, %{})
    assert PrometheusReporter.scrape(reporter) == initial
    assert :ok = PrometheusReporter.fold(reporter)
    assert_received {:prometheus_folded, _pid}
    refute PrometheusReporter.scrape(reporter) == initial
  end

  test "bad tags are dropped on fold and cached scrapes do not repeat warnings" do
    registry = unique_name()
    event = [:codex_pooler_test, :bad_tag, unique_event_atom()]
    metric = Telemetry.Metrics.sum(event, event_name: event, measurement: :count, tags: [:kind])

    start_supervised!({TelemetryMetricsPrometheus.Core, metrics: [metric], name: registry, start_async: false})

    reporter = unique_name()

    pid =
      start_supervised!({PrometheusReporter, name: reporter, prometheus_name: registry, interval_ms: 60_000})

    :telemetry.execute(event, %{count: 1}, %{kind: %{invalid: true}})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(pid, :fold)
        :sys.get_state(pid)
      end)

    assert log =~ "bad tag value"

    refute ExUnit.CaptureLog.capture_log(fn ->
             for _ <- 1..3, do: PrometheusReporter.scrape(reporter)
             send(pid, :fold)
             :sys.get_state(pid)
           end) =~ "bad tag value"
  end

  test "periodically folds unscripted distribution samples and serializes concurrent scrapes" do
    name = unique_name()

    # A buffer label no other emitter uses, so the series below belong to this
    # test alone in the application registry.
    buffer = "prometheus-reporter-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised({PrometheusReporter, name: name, interval_ms: 10, fold_notify: self()})

    for _ <- 1..5 do
      :telemetry.execute(
        [:codex_pooler, :gateway, :stream_buffer, :oversized],
        %{bytes: 65_536, count: 1},
        %{buffer: buffer, endpoint: "test", route_class: "proxy_stream", transport: "http_sse"}
      )
    end

    # A fold may already be running when the executes finish. After dropping
    # the notices received so far, the second new notice comes from a fold that
    # started after the first one ended, so it rendered every sample above.
    flush_folds(pid)
    assert_receive {:prometheus_folded, ^pid}, @detection_timeout_ms
    assert_receive {:prometheus_folded, ^pid}, @detection_timeout_ms

    tasks = for _ <- 1..8, do: Task.async(fn -> PrometheusReporter.scrape(name) end)
    bodies = Enum.map(tasks, &Task.await(&1, @detection_timeout_ms))
    assert Enum.all?(bodies, &(is_binary(&1) and &1 =~ "codex_pooler_gateway_admission_queued"))

    # The reporter keeps folding the application registry every 10 ms, and the
    # VM poller and other emitters move unrelated series between any two
    # scrapes (findings#206 row 206-274), so only this test's series are
    # compared.
    assert [series] = bodies |> Enum.map(&owned_series(&1, buffer)) |> Enum.uniq()
    assert Enum.any?(series, &(&1 =~ ~r/^codex_pooler_gateway_stream_buffer_oversized_count\{.*\} 5$/))
    assert Enum.any?(series, &(&1 =~ ~r/^codex_pooler_gateway_stream_buffer_oversized_bytes_count\{.*\} 5$/))
    assert owned_series(PrometheusReporter.scrape(name), buffer) == series
  end

  test "scrapes an isolated real Core registry and matches its direct output" do
    registry = unique_name()
    event = [:codex_pooler_test, :isolated_distribution, unique_event_atom()]

    metric =
      Telemetry.Metrics.distribution(event,
        event_name: event,
        measurement: :value,
        tags: [:kind],
        reporter_options: [buckets: [10, 20, 50]]
      )

    start_supervised!({TelemetryMetricsPrometheus.Core, metrics: [metric], name: registry, start_async: false})

    reporter = unique_name()

    start_supervised!({PrometheusReporter, name: reporter, prometheus_name: registry, interval_ms: 60_000})

    for value <- [5, 15, 40] do
      :telemetry.execute(event, %{value: value}, %{kind: "isolated"})
    end

    %{dist_table_id: dist_table, aggregates_table_id: aggregate_table} =
      TelemetryMetricsPrometheus.Core.Registry.config(registry)

    metric_name = metric.name

    assert :ets.lookup(dist_table, metric_name) |> length() == 3

    direct = TelemetryMetricsPrometheus.Core.scrape(registry)
    assert :ets.lookup(dist_table, metric_name) == []

    assert [{{^metric_name, %{kind: "isolated"}}, {buckets, 3, 60}}] =
             :ets.lookup(aggregate_table, {metric_name, %{kind: "isolated"}})

    assert buckets == [{"10", 1}, {"20", 2}, {"50", 3}, {"+Inf", 3}]
    send(reporter, :fold)
    :sys.get_state(reporter)
    assert PrometheusReporter.scrape(reporter) == direct
    assert direct =~ "codex_pooler_test_isolated_distribution"
    assert direct =~ "kind=\"isolated\""
  end

  test "serializes interleaved batches without losing updates" do
    registry = unique_name()
    event = [:codex_pooler_test, :interleaved, unique_event_atom()]

    metric =
      Telemetry.Metrics.distribution(event,
        event_name: event,
        measurement: :value,
        tags: [:kind],
        reporter_options: [buckets: [10, 20, 50]]
      )

    start_supervised!({TelemetryMetricsPrometheus.Core, metrics: [metric], name: registry, start_async: false})

    parent = self()
    release = make_ref()
    scrape_count = :atomics.new(1, [])
    reporter = unique_name()

    start_supervised!(
      {PrometheusReporter,
       name: reporter,
       prometheus_name: registry,
       interval_ms: 60_000,
       before_scrape: fn ->
         if :atomics.add_get(scrape_count, 1, 1) == 1 do
           send(parent, {:scrape_barrier, self()})

           receive do
             {:release, ^release} -> :ok
           end
         end
       end}
    )

    for value <- [5, 15, 40], do: :telemetry.execute(event, %{value: value}, %{kind: "isolated"})
    send(reporter, :fold)
    callers = for _ <- 1..8, do: Task.async(fn -> PrometheusReporter.scrape(reporter) end)
    assert_receive {:scrape_barrier, _pid}
    for value <- [5, 15, 40], do: :telemetry.execute(event, %{value: value}, %{kind: "isolated"})
    send(reporter, {:release, release})
    bodies = Enum.map(callers, &Task.await(&1, @detection_timeout_ms))
    assert Enum.uniq(bodies) |> length() == 1
    body = hd(bodies)
    assert body =~ "_bucket{kind=\"isolated\",le=\"10\"} 2"
    assert body =~ "_bucket{kind=\"isolated\",le=\"20\"} 4"
    assert body =~ "_bucket{kind=\"isolated\",le=\"50\"} 6"
    assert body =~ "_sum{kind=\"isolated\"} 120"
    assert body =~ "_count{kind=\"isolated\"} 6"

    %{dist_table_id: dist_table} = TelemetryMetricsPrometheus.Core.Registry.config(registry)
    assert :ets.lookup(dist_table, metric.name) == []
  end

  test "an unscraped node still drains its raw samples and keeps an exact histogram count" do
    # `TelemetryMetricsPrometheus.Core` stores every distribution observation as
    # its own ETS row and folds those rows into the cumulative aggregate only
    # when something scrapes. Two shipped configurations never scrape: the
    # Compose default has no Prometheus, and a chart install has the
    # ServiceMonitor off by default. Without the periodic fold those rows grow
    # for the life of the node.
    #
    # Nothing here reads the reporter's rendering, because reading it is the
    # very thing the unscraped node never does: the drain and the count are
    # read straight out of Core's own tables.
    registry = unique_name()
    event = [:codex_pooler_test, :unscraped, unique_event_atom()]

    metric =
      Telemetry.Metrics.distribution(event,
        event_name: event,
        measurement: :value,
        tags: [:kind],
        reporter_options: [buckets: [10, 20, 50]]
      )

    start_supervised!({TelemetryMetricsPrometheus.Core, metrics: [metric], name: registry, start_async: false})

    %{dist_table_id: dist_table, aggregates_table_id: aggregates} =
      TelemetryMetricsPrometheus.Core.Registry.config(registry)

    observations = [5, 15, 40, 5, 15, 40, 60]

    start_supervised!({PrometheusReporter, name: unique_name(), prometheus_name: registry, interval_ms: 10, fold_notify: self()})

    for value <- observations,
        do: :telemetry.execute(event, %{value: value}, %{kind: "unscraped"})

    # Proof the rows really accumulate before anything folds them: without this
    # the assertion below could pass on a metric nothing ever recorded.
    assert :ets.lookup(dist_table, metric.name) != []

    assert_receive {:prometheus_folded, _pid}, @detection_timeout_ms

    # A fold may land between two of the executes above, so wait for one that
    # started after the last of them before reading the drained table.
    assert_receive {:prometheus_folded, _pid}, @detection_timeout_ms

    assert :ets.lookup(dist_table, metric.name) == [],
           "an unscraped node kept raw distribution samples, so they grow without bound"

    assert [{{_name, %{kind: "unscraped"}}, {buckets, count, sum}}] =
             :ets.lookup(aggregates, {metric.name, %{kind: "unscraped"}})

    assert count == length(observations),
           "the folded histogram count does not equal the events emitted"

    assert sum == Enum.sum(observations)
    assert buckets == [{"10", 2}, {"20", 4}, {"50", 6}, {"+Inf", 7}]
  end

  defp owned_series(body, buffer) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, ~s(buffer="#{buffer}")))
  end

  defp flush_folds(pid) do
    receive do
      {:prometheus_folded, ^pid} -> flush_folds(pid)
    after
      0 -> :ok
    end
  end

  defp unique_name, do: Module.concat(__MODULE__, "Reporter#{System.unique_integer([:positive])}")

  defp unique_event_atom, do: String.to_atom("event_#{System.unique_integer([:positive])}")
end
