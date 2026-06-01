defmodule CodexPoolerWeb.TelemetryTest do
  use ExUnit.Case, async: true

  test "starts telemetry poller with default VM measurements enabled" do
    assert {:ok, {_supervisor, children}} = CodexPoolerWeb.Telemetry.init(:ok)

    assert %{
             id: :telemetry_poller,
             start: {:telemetry_poller, :start_link, [[period: 10_000]]}
           } = Enum.find(children, &(&1.id == :telemetry_poller))
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
    assert "vm.memory.code.bytes" in metric_names
    assert "vm.system_counts.process_count" in metric_names
    assert "vm.system_counts.port_count" in metric_names
  end

  test "exports Ecto repo query count and latency Prometheus metrics by source" do
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
               tags: [:source],
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

    assert %{source: "requests"} = metric.tag_values.(%{source: "requests"})
    assert %{source: "unknown"} = metric.tag_values.(%{})

    assert %{source: source} =
             metric.tag_values.(%{source: "SELECT * FROM requests WHERE secret = $1"})

    assert source == "unknown"
  end

  defp metric_by_name(metrics, name) do
    Enum.find(metrics, &(metric_name(&1) == name))
  end

  defp metric_name(metric) do
    Enum.map_join(metric.name, ".", &to_string/1)
  end
end
