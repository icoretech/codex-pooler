defmodule CodexPoolerWeb.Observatory.PresentationTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Observatory.Presentation

  @windows [{"1h", "1h"}, {"5h", "5h"}, {"24h", "24h"}, {"7d", "7d"}]

  test "builds a bounded safe render model and exact Apex chart contract" do
    model = Presentation.build(complete_projection())

    assert Presentation.window_options() == @windows

    assert Enum.all?(@windows, fn {key, label} ->
             Presentation.valid_window?(key) and key == label
           end)

    refute Presentation.valid_window?("30m")

    assert model.window.key == "24h"
    assert model.state == :ready

    assert model.overview.success_rate == %{
             percent: 90.0,
             label: "90.0%",
             detail: "9 succeeded · 1 failed",
             minibar: 90.0,
             trend: %{label: "not available", tone: :neutral, direction: :unavailable}
           }

    assert model.overview.cache_rate.detail == "20 of 80 input tokens served from cache"
    assert model.overview.cost.settled.label == "$1.25"
    assert model.overview.cost.estimated.label == "$0.30"
    assert model.overview.cost.detail == "+ $0.30 estimated, awaiting settlement"
    assert model.overview.cost.confidence == "estimated"
    assert model.overview.throughput.p50_label == "125.5 tok/s"
    assert model.overview.latency.p95_label == "200 ms"
    assert model.overview.latency.detail == "Mean 160 ms · slowest settled 240 ms"

    assert length(model.models) == 12
    assert hd(model.models).bar_percent == 100.0

    assert Enum.map(model.models, & &1.tone) ==
             [
               :primary,
               :info,
               :success,
               :neutral,
               :primary,
               :info,
               :success,
               :neutral,
               :primary,
               :info,
               :success,
               :neutral
             ]

    chart = model.traffic.chart
    assert Jason.decode!(chart.categories) == ["07-17 11:00", "07-17 12:00"]

    chart_series = Jason.decode!(chart.series)

    assert chart_series == [
             %{"name" => "Fresh input", "type" => "column", "data" => [45, 15]},
             %{"name" => "Cached input", "type" => "column", "data" => [15, 5]}
           ]

    assert Jason.decode!(chart.units) == ["tokens", "tokens"]
    assert Jason.decode!(chart.value_kinds) == ["tokens", "tokens"]

    assert Jason.decode!(chart.yaxis) == [
             %{
               "seriesName" => ["Fresh input", "Cached input"],
               "title" => "tokens",
               "valueKind" => "tokens"
             }
           ]

    assert Jason.decode!(chart.colors) == ["var(--color-primary)", "var(--color-info)"]
    assert model.traffic.total_label == "80 tokens · 10 requests"
    assert model.traffic.fallback.total_label == "80 tokens · 10 requests"
    assert model.traffic.total_label == model.traffic.fallback.total_label

    assert model.traffic.fallback.rows == [
             %{
               label: "07-17 11:00",
               fresh: 45,
               fresh_label: "45",
               cached: 15,
               cached_label: "15",
               total: 60,
               total_label: "60",
               requests: 6,
               requests_label: "6"
             },
             %{
               label: "07-17 12:00",
               fresh: 15,
               fresh_label: "15",
               cached: 5,
               cached_label: "5",
               total: 20,
               total_label: "20",
               requests: 4,
               requests_label: "4"
             }
           ]

    fallback_rows = model.traffic.fallback.rows

    assert Enum.map(chart_series, & &1["data"]) == [
             Enum.map(fallback_rows, & &1.fresh),
             Enum.map(fallback_rows, & &1.cached)
           ]

    chart_row_totals =
      chart_series
      |> Enum.map(& &1["data"])
      |> Enum.zip()
      |> Enum.map(fn {fresh, cached} -> fresh + cached end)

    fallback_row_totals = Enum.map(fallback_rows, &(&1.fresh + &1.cached))
    assert chart_row_totals == fallback_row_totals
    assert Enum.sum(chart_row_totals) == Enum.sum(Enum.map(fallback_rows, & &1.total))
    assert Enum.sum(chart_row_totals) == 80

    assert Enum.sum(Enum.map(fallback_rows, & &1.fresh)) == 60
    assert Enum.sum(Enum.map(fallback_rows, & &1.cached)) == 20
    assert Enum.sum(Enum.map(fallback_rows, & &1.total)) == 80
    assert Enum.sum(Enum.map(fallback_rows, & &1.requests)) == 10

    assert length(model.outcomes) == 12
    assert Enum.all?(model.outcomes, &(&1.status.data_status in ["ok", "warn", "err", "neutral"]))

    assert Enum.all?(
             model.outcomes,
             &(&1.status.tone in [:success, :warning, :error, :neutral, :info])
           )

    assert Enum.all?(
             model.outcomes,
             &(Map.keys(&1.status) |> Enum.sort() == [:data_status, :label, :tone])
           )

    assert Enum.all?(
             model.outcomes,
             &(Map.keys(&1) |> Enum.sort() == [
                 :code,
                 :cost,
                 :endpoint,
                 :latency,
                 :model,
                 :status,
                 :timestamp,
                 :tokens
               ])
           )

    assert Enum.at(model.outcomes, 1).code == "rate_limited"
    assert Enum.at(model.outcomes, 1).status.label == "Failed · Rate limited"
    refute inspect(model) =~ "raw-outcome-metadata"
    refute inspect(model) =~ ~r/\b(?:Pool|upstream|operator)\b/i
  end

  test "maps outcome statuses to finite labels and retains safe codes" do
    cases = [
      {"succeeded", "ok", :success, "Succeeded", nil},
      {"failed", "err", :error, "Failed · Rate limited", "rate_limited"},
      {"in_progress", "warn", :warning, "In progress", nil},
      {"cancelled", "neutral", :neutral, "Cancelled", nil},
      {"unexpected", "neutral", :neutral, "Unknown", nil}
    ]

    outcomes =
      cases
      |> Enum.with_index(1)
      |> Enum.map(fn {{status, _data_status, _tone, _label, code}, _index} ->
        %{
          timestamp: ~U[2026-07-17 11:59:00Z],
          model: "safe-model",
          endpoint_class: "responses",
          status: status,
          code: code,
          metadata: %{"raw" => "raw-outcome-metadata"}
        }
      end)

    model = Presentation.build(%{zero_projection() | outcomes: outcomes})

    Enum.zip(model.outcomes, cases)
    |> Enum.each(fn {outcome, {_status, data_status, tone, label, code}} ->
      assert outcome.status == %{data_status: data_status, tone: tone, label: label}
      assert outcome.code == code
    end)

    refute inspect(model) =~ "raw-outcome-metadata"
  end

  test "keeps bounded scalar labels without sentinel-specific filtering" do
    long_model = String.duplicate("model", 30)

    projection =
      Map.merge(zero_projection(), %{
        models: [%{label: " redaction-probe\n", total_tokens: 1}],
        outcomes: [
          %{
            model: " #{long_model} ",
            endpoint_class: "responses",
            status: "failed",
            code: " canonical-marker\t",
            metadata: %{"raw" => "raw-outcome-metadata"}
          }
        ]
      })

    model = Presentation.build(projection)

    assert hd(model.models).label == "redaction-probe"
    assert hd(model.outcomes).code == "request_failed"
    assert hd(model.outcomes).status.label == "Failed · Request failed"
    assert hd(model.outcomes).model == String.slice(long_model, 0, 80)
    refute inspect(model) =~ "raw-outcome-metadata"
  end

  defp complete_projection do
    %{
      window: %{
        key: "24h",
        started_at: ~U[2026-07-17 10:00:00Z],
        ended_at: ~U[2026-07-17 12:00:00Z]
      },
      totals: %{
        requests: %{total: 10, succeeded: 9, failed: 1, in_progress: 0},
        tokens: %{input: 80, cached_input: 20, output: 40, reasoning: 10, total: 130},
        cache_rate_percent: 25.0,
        cost: %{
          settled: %{status: "settled", micros: 1_250_000},
          estimated: %{status: "estimated", micros: 300_000},
          unavailable_requests: 0,
          confidence: "estimated"
        }
      },
      performance: %{
        latency_ms: %{mean: 160, p50: 120, p95: 200, max: 240},
        throughput_tokens_per_second: %{p50: 125.5, p95: 140.0}
      },
      accounting: %{status: "complete"},
      buckets: [
        bucket(~U[2026-07-17 11:00:00Z], 60, 15, 90, 6),
        bucket(~U[2026-07-17 12:00:00Z], 20, 5, 40, 4)
      ],
      models:
        Enum.map(1..13, &%{label: "model-#{&1}", request_count: &1, total_tokens: 130 - &1}),
      outcomes: Enum.map(1..13, &outcome(&1))
    }
  end

  defp zero_projection do
    %{totals: %{requests: %{total: 0}}, accounting: %{status: "missing"}, outcomes: []}
  end

  defp bucket(started_at, input, cached, total, requests) do
    %{
      started_at: started_at,
      ended_at: DateTime.add(started_at, 300, :second),
      requests: %{total: requests},
      tokens: %{input: input, cached_input: cached, total: total},
      cost: %{}
    }
  end

  defp outcome(1),
    do: %{
      timestamp: ~U[2026-07-17 11:59:00Z],
      model: "model-1",
      endpoint_class: "responses",
      status: "succeeded",
      response_status_code: 200,
      code: nil,
      latency_ms: 120,
      total_tokens: 10,
      cost: %{status: "settled", micros: 20_000}
    }

  defp outcome(index),
    do: %{
      timestamp: DateTime.add(~U[2026-07-17 11:59:00Z], -index, :second),
      model: "model-#{index}",
      endpoint_class: "responses",
      status: if(index == 2, do: "failed", else: "cancelled"),
      response_status_code: if(index == 2, do: 429, else: nil),
      code: if(index == 2, do: "rate_limited", else: nil),
      metadata: if(index == 2, do: %{"raw" => "raw-outcome-metadata"}, else: nil),
      latency_ms: index * 10,
      total_tokens: index,
      cost: %{status: "unavailable", micros: 0}
    }
end
