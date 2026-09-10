defmodule CodexPoolerWeb.HistogramCollectorTest do
  use ExUnit.Case, async: false

  alias CodexPoolerWeb.Telemetry.HistogramCollector
  alias CodexPoolerWeb.Telemetry.PrometheusReporter
  alias TelemetryMetricsPrometheus.Core

  @reporter :bounded_histogram_test
  @event [:bounded_histogram_test, :sample]
  @metric [:bounded_histogram_test, :duration, :seconds]
  @tags %{source: "fixture"}
  @key {@metric, @tags}

  setup do
    metric =
      Telemetry.Metrics.distribution(@metric,
        event_name: @event,
        measurement: :duration,
        tags: [:source],
        tag_values: &Map.take(&1, [:source]),
        keep: &(!Map.get(&1, :skip, false)),
        unit: {:millisecond, :second},
        reporter_options: [buckets: [0, 0.125, 0.25, 1]]
      )

    supervisor = start_supervised!({PrometheusReporter, name: @reporter, metrics: [metric]})
    %{aggregates_table_id: table, dist_table_id: raw} = Core.Registry.config(@reporter)
    %{table: table, raw: raw, supervisor: supervisor, metric: metric}
  end

  test "a million observations without scraping retain one fixed-size aggregate", context do
    emit(125)
    warm_memory = :ets.info(context.table, :memory)

    for _ <- 1..99_999, do: emit(125)

    assert aggregate(context.table) ==
             {[
                {"0", 0},
                {"0.125", 100_000},
                {"0.25", 100_000},
                {"1", 100_000},
                {"+Inf", 100_000}
              ], 100_000, 12_500.0}

    memory_100k = :ets.info(context.table, :memory)

    1..8
    |> Task.async_stream(fn _ -> for _ <- 1..112_500, do: emit(125) end,
      max_concurrency: 8,
      timeout: 120_000,
      ordered: false
    )
    |> Enum.each(fn result -> assert match?({:ok, _}, result) end)

    {buckets, count, sum} = aggregate(context.table)
    assert count == 1_000_000
    assert sum == 125_000.0
    assert List.last(buckets) == {"+Inf", count}
    assert :ets.info(context.table, :size) == 1
    assert :ets.info(context.raw, :size) == 0
    assert memory_100k <= warm_memory + 1024
    assert :ets.info(context.table, :memory) <= memory_100k + 1024

    IO.puts(
      "histogram no-scrape 100k/1m: one aggregate, zero raw samples, memory words #{memory_100k}/#{:ets.info(context.table, :memory)}"
    )
  end

  test "exact inclusive boundaries, fractional sums and repeated scrapes preserve exposition",
       context do
    for value <- [0, 125, 250, 1000, 1250], do: emit(value)

    assert aggregate(context.table) == {
             [{"0", 1}, {"0.125", 2}, {"0.25", 3}, {"1", 4}, {"+Inf", 5}],
             5,
             2.625
           }

    first = PrometheusReporter.scrape(@reporter)
    assert first == PrometheusReporter.scrape(@reporter)

    assert first =~
             ~s(bounded_histogram_test_duration_seconds_bucket{source="fixture",le="0.125"} 2)

    assert first =~ ~s(bounded_histogram_test_duration_seconds_sum{source="fixture"} 2.625)
    assert first =~ ~s(bounded_histogram_test_duration_seconds_count{source="fixture"} 5)
    assert :ets.info(context.raw, :size) == 0
  end

  test "concurrent first writes and scrapes cannot lose increments", context do
    writers = for _ <- 1..8, do: Task.async(fn -> for _ <- 1..1000, do: emit(125) end)
    for _ <- 1..50, do: assert(PrometheusReporter.scrape(@reporter) |> is_binary())
    Enum.each(writers, &Task.await(&1, 30_000))
    {buckets, count, sum} = aggregate(context.table)
    assert count == 8000
    assert sum == 1000.0
    assert List.last(buckets) == {"+Inf", 8000}
  end

  test "keep, transformed tags, malformed measurements and missing labels are respected",
       context do
    :telemetry.execute(@event, %{duration: 125}, %{source: "fixture", skip: true})
    :telemetry.execute(@event, %{}, @tags)
    :telemetry.execute(@event, %{duration: nil}, @tags)
    :telemetry.execute(@event, %{duration: "bad"}, @tags)
    :telemetry.execute(@event, %{duration: 125}, %{})
    assert :ets.info(context.table, :size) == 0
    emit(125)
    assert {_, 1, 0.125} = aggregate(context.table)
  end

  test "registry restart replaces table and handlers before collecting again", context do
    emit(125)
    old_table = :ets.whereis(context.table)
    old_registry = Process.whereis(@reporter)
    Process.exit(old_registry, :kill)

    eventually(fn ->
      current = Process.whereis(@reporter)

      current != nil and current != old_registry and :ets.whereis(context.table) != old_table and
        length(:telemetry.list_handlers(@event)) == 1
    end)

    assert :ets.info(old_table) == :undefined
    # Wait for the collector child to finish synchronous registration too.
    eventually(fn ->
      Enum.any?(Supervisor.which_children(context.supervisor), fn
        {HistogramCollector, pid, _, _} -> is_pid(pid)
        _ -> false
      end)
    end)

    emit(250)
    assert {_, 1, 0.25} = aggregate(context.table)
    assert :ets.info(context.raw, :size) == 0
    assert length(:telemetry.list_handlers(@event)) == 1
  end

  test "collector kill replaces its handler without leaving duplicates", context do
    emit(125)

    {HistogramCollector, old, _, _} =
      Enum.find(
        Supervisor.which_children(context.supervisor),
        &(elem(&1, 0) == HistogramCollector)
      )

    old_table = :ets.whereis(context.table)
    Process.exit(old, :kill)

    eventually(fn ->
      Enum.any?(Supervisor.which_children(context.supervisor), fn
        {HistogramCollector, pid, _, _} -> is_pid(pid) and pid != old
        _ -> false
      end)
    end)

    assert :ets.whereis(context.table) != old_table
    assert length(:telemetry.list_handlers(@event)) == 1
    emit(125)
    assert {_, 1, 0.125} = aggregate(context.table)
  end

  test "literal match-variable labels do not corrupt or stall other series", context do
    emit(125)

    for label <- [:"$1", :_, :"$_"] do
      for _ <- 1..2, do: :telemetry.execute(@event, %{duration: 250}, %{source: label})

      assert [{{@metric, %{source: ^label}}, {_, 2, 0.5}}] =
               :ets.lookup(context.table, {@metric, %{source: label}})
    end

    assert {_, 1, 0.125} = aggregate(context.table)
  end

  test "updates remain efficient with 500 existing series", context do
    for id <- 1..500 do
      :telemetry.execute(@event, %{duration: 125}, %{source: "fixture-#{id}"})
    end

    {elapsed, _} = :timer.tc(fn -> for _ <- 1..10_000, do: emit(125) end)
    assert :ets.info(context.table, :size) == 501
    assert {_, 10_000, 1250.0} = aggregate(context.table)
    assert elapsed < 10_000_000
    IO.puts("histogram 500-series 10k updates: #{elapsed}us")
  end

  test "stopping reporter detaches handlers", context do
    assert length(:telemetry.list_handlers(@event)) == 1
    Supervisor.stop(context.supervisor)
    assert :telemetry.list_handlers(@event) == []
  end

  defp emit(milliseconds), do: :telemetry.execute(@event, %{duration: milliseconds}, @tags)
  defp aggregate(table), do: table |> :ets.lookup(@key) |> hd() |> elem(1)

  defp eventually(check, remaining \\ 200)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, remaining) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(check, remaining - 1)
        )
  end
end
