defmodule CodexPoolerWeb.Observatory.PresentationResilienceTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Observatory.Presentation

  test "marks empty and partial projections without dividing by zero" do
    empty = Presentation.build(zero_projection())
    partial = Presentation.build(partial_projection())

    assert empty.state == :empty
    assert empty.overview.success_rate.label == "not available"
    assert empty.overview.success_rate.minibar == 0.0
    assert empty.overview.cache_rate.label == "not available"
    assert empty.overview.cost.confidence == "unavailable"
    assert empty.overview.throughput.p50_label == "not available"
    assert empty.overview.latency.p50_label == "not available"
    assert empty.overview.latency.p95_label == "not available"
    assert empty.traffic.total_label == "0 tokens · 0 requests"
    assert partial.state == :partial
  end

  test "accepts nil fields and keeps render output finite and metadata-only" do
    model =
      Presentation.build(%{
        window: %{key: "1h", started_at: nil, ended_at: nil},
        totals: nil,
        performance: nil,
        accounting: nil,
        buckets: nil,
        models: [%{label: "safe-model", total_tokens: nil}],
        outcomes: [
          %{
            model: nil,
            endpoint_class: nil,
            status: nil,
            code: %{raw: "not-a-scalar"},
            metadata: %{"raw" => "raw-outcome-metadata"},
            timestamp: nil
          }
        ]
      })

    assert model.window.key == "1h"
    assert model.traffic.categories == []
    assert hd(model.models).token_label == "0"
    assert hd(model.outcomes).model == "Unknown model"
    assert hd(model.outcomes).endpoint == "other"
    assert hd(model.outcomes).code == nil
    assert hd(model.outcomes).status.data_status == "neutral"
    assert hd(model.outcomes).status.label == "Unknown"
    assert hd(model.outcomes).cost.label == "—"
    refute inspect(model) =~ "raw-outcome-metadata"
  end

  test "formats compact token and grouped request labels without changing arithmetic" do
    model =
      Presentation.build(%{
        totals: %{
          requests: %{total: 4_286, succeeded: 4_200, failed: 86},
          tokens: %{input: 80_300_000, cached_input: 80_300_000, total: 398_107_399}
        },
        accounting: %{status: "complete"},
        buckets: [
          %{
            started_at: ~U[2026-07-17 11:00:00Z],
            requests: %{total: 4_286},
            tokens: %{input: 138_200_000, cached_input: 80_300_000}
          }
        ],
        models:
          Enum.map(
            [
              999,
              1_000,
              1_050,
              999_949,
              999_950,
              1_250_000,
              999_949_999,
              999_950_000,
              1_250_000_000,
              80_300_000
            ],
            &%{label: "model-#{&1}", total_tokens: &1}
          )
      })

    assert model.overview.success_rate.detail == "4,200 succeeded · 86 failed"
    assert model.overview.cache_rate.detail == "80.3M of 80.3M input tokens served from cache"
    assert model.traffic.total_label == "80.3M tokens · 4,286 requests"
    assert model.traffic.fallback.total_label == "80.3M tokens · 4,286 requests"
    assert model.traffic.total_label == model.traffic.fallback.total_label

    assert Enum.map(model.models, & &1.token_label) == [
             "999",
             "1.0K",
             "1.1K",
             "999.9K",
             "1.0M",
             "1.3M",
             "999.9M",
             "1.0B",
             "1.3B",
             "80.3M"
           ]

    [row] = model.traffic.fallback.rows
    chart_series = Jason.decode!(model.traffic.chart.series)

    assert row.fresh == 57_900_000
    assert row.cached == 80_300_000
    assert row.total == 138_200_000
    assert row.requests == 4_286
    assert row.fresh_label == "57.9M"
    assert row.cached_label == "80.3M"
    assert row.total_label == "138.2M"
    assert row.requests_label == "4,286"
    assert Enum.map(chart_series, & &1["data"]) == [[57_900_000], [80_300_000]]

    assert Enum.map(chart_series, & &1["data"]) == [
             Enum.map(model.traffic.fallback.rows, & &1.fresh),
             Enum.map(model.traffic.fallback.rows, & &1.cached)
           ]
  end

  test "uses singular request wording" do
    model =
      Presentation.build(%{
        totals: %{requests: %{total: 1}, tokens: %{input: 1_000, total: 1_000}},
        accounting: %{status: "complete"}
      })

    assert model.traffic.total_label == "1.0K tokens · 1 request"
  end

  defp zero_projection do
    %{totals: %{requests: %{total: 0}}, accounting: %{status: "missing"}}
  end

  defp partial_projection do
    %{totals: %{requests: %{total: 1}}, accounting: %{status: "partial"}}
  end
end
