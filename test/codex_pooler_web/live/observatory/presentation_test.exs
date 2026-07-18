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
    assert model.overview.throughput.p50_label == "126 tok/s"
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

    # Token columns broken down by model (top models plus a folded "Other" so
    # each stack sums to the bucket's total tokens) with a cost line.
    assert chart_series == [
             %{"name" => "model-1", "type" => "column", "data" => [50, 20]},
             %{"name" => "model-2", "type" => "column", "data" => [30, 10]},
             %{"name" => "model-3", "type" => "column", "data" => [5, 0]},
             %{"name" => "Other", "type" => "column", "data" => [5, 10]},
             %{"name" => "Cost", "type" => "line", "data" => [1.0, 0.5]}
           ]

    assert Jason.decode!(chart.units) == ["tokens", "tokens", "tokens", "tokens", "USD"]

    assert Jason.decode!(chart.value_kinds) ==
             ["tokens", "tokens", "tokens", "tokens", "usd"]

    assert Jason.decode!(chart.yaxis) == [
             %{
               "seriesName" => ["model-1", "model-2", "model-3", "Other"],
               "title" => "tokens",
               "valueKind" => "tokens"
             },
             %{
               "seriesName" => "Cost",
               "title" => "cost",
               "opposite" => true,
               "valueKind" => "usd"
             }
           ]

    assert Jason.decode!(chart.colors) == [
             "var(--color-primary)",
             "var(--color-info)",
             "var(--color-warning)",
             "color-mix(in oklab, var(--color-base-content) 40%, transparent)",
             "var(--color-success)"
           ]

    assert model.traffic.total_label == "130 tokens · $1.50"
    assert model.traffic.fallback.total_label == "130 tokens · $1.50"
    assert model.traffic.total_label == model.traffic.fallback.total_label

    assert model.traffic.fallback.rows == [
             %{
               label: "07-17 11:00",
               total: 90,
               total_label: "90",
               cost_micros: 1_000_000,
               cost_usd: 1.0,
               cost_label: "$1.00"
             },
             %{
               label: "07-17 12:00",
               total: 40,
               total_label: "40",
               cost_micros: 500_000,
               cost_usd: 0.5,
               cost_label: "$0.50"
             }
           ]

    fallback_rows = model.traffic.fallback.rows

    token_series = Enum.reject(chart_series, &(&1["name"] == "Cost"))
    cost_series = Enum.find(chart_series, &(&1["name"] == "Cost"))

    # Each bucket's stacked token columns sum to the total-token bucket value,
    # so the bar height is the total-token universe, never input-only.
    column_bucket_totals =
      token_series
      |> Enum.map(& &1["data"])
      |> Enum.zip_with(&Enum.sum/1)

    assert column_bucket_totals == Enum.map(fallback_rows, & &1.total)
    assert Enum.sum(column_bucket_totals) == 130
    assert cost_series["data"] == Enum.map(fallback_rows, & &1.cost_usd)
    assert Enum.sum(Enum.map(fallback_rows, & &1.total)) == 130

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
        bucket(~U[2026-07-17 11:00:00Z], 60, 15, 90, 6, 1_000_000),
        bucket(~U[2026-07-17 12:00:00Z], 20, 5, 40, 4, 500_000)
      ],
      models:
        Enum.map(1..13, &%{label: "model-#{&1}", request_count: &1, total_tokens: 130 - &1}),
      model_buckets: [
        %{bucket_index: 0, label: "model-1", total_tokens: 50},
        %{bucket_index: 1, label: "model-1", total_tokens: 20},
        %{bucket_index: 0, label: "model-2", total_tokens: 30},
        %{bucket_index: 1, label: "model-2", total_tokens: 10},
        %{bucket_index: 0, label: "model-3", total_tokens: 5}
      ],
      outcomes: Enum.map(1..13, &outcome(&1))
    }
  end

  defp zero_projection do
    %{totals: %{requests: %{total: 0}}, accounting: %{status: "missing"}, outcomes: []}
  end

  defp bucket(started_at, input, cached, total, requests, settled_micros) do
    %{
      started_at: started_at,
      ended_at: DateTime.add(started_at, 300, :second),
      requests: %{total: requests},
      tokens: %{input: input, cached_input: cached, total: total},
      cost: %{
        settled: %{status: "settled", micros: settled_micros},
        estimated: %{status: "unavailable", micros: 0}
      }
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
