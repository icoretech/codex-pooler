defmodule CodexPoolerWeb.Telemetry.OperatorDashboardTest do
  # The operator dashboard JSON is a machine-readable contract that ships with the
  # docs site: operators import it and every panel queries this app's exported
  # Prometheus series. A metric renamed or removed without touching the dashboard
  # leaves a panel that renders empty forever, which reads as "this never happens"
  # rather than "this is no longer measured".
  use ExUnit.Case, async: true

  @dashboard Path.expand(
               "../../../docs-site/public/operators/monitoring/codex-pooler-runtime-triage.json",
               __DIR__
             )

  # TelemetryMetricsPrometheus.Core exports a distribution as three series.
  @distribution_suffixes ["_bucket", "_sum", "_count"]

  test "every codex_pooler metric the operator dashboard queries is still exported" do
    exported = exported_series()
    referenced = referenced_series()

    # A shrinking or empty reference set would satisfy this test without proving
    # anything, so bind the scale of the contract too.
    assert map_size(referenced) >= 20

    missing =
      referenced
      |> Enum.reject(fn {metric, _panels} -> MapSet.member?(exported, metric) end)
      |> Enum.sort()

    assert missing == [],
           "operator dashboard panels query metrics this app no longer exports: " <>
             Enum.map_join(missing, "; ", fn {metric, panels} ->
               "#{metric} (#{Enum.join(Enum.sort(panels), ", ")})"
             end)
  end

  test "dashboard panel titles are unique so divergence can be compared by title" do
    duplicates =
      @dashboard
      |> dashboard_panels()
      |> Enum.map(&Map.get(&1, "title"))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_title, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    assert duplicates == []
  end

  defp exported_series do
    CodexPoolerWeb.Telemetry.prometheus_metrics()
    |> Enum.flat_map(fn metric ->
      base = Enum.map_join(metric.name, "_", &Atom.to_string/1)
      [base | Enum.map(@distribution_suffixes, &(base <> &1))]
    end)
    |> MapSet.new()
  end

  defp referenced_series do
    @dashboard
    |> dashboard_panels()
    |> Enum.reduce(%{}, fn panel, acc ->
      title = Map.get(panel, "title", "<untitled>")

      panel
      |> Map.get("targets", [])
      |> Enum.flat_map(&Regex.scan(~r/\bcodex_pooler_[a-z0-9_]+\b/, Map.get(&1, "expr", "")))
      |> Enum.map(&hd/1)
      |> Enum.reduce(acc, fn metric, inner ->
        Map.update(inner, metric, [title], &[title | &1])
      end)
    end)
  end

  defp dashboard_panels(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("panels")
    |> Enum.flat_map(fn panel -> [panel | Map.get(panel, "panels") || []] end)
  end
end
