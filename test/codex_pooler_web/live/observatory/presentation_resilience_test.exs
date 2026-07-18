defmodule CodexPoolerWeb.Observatory.PresentationResilienceTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Observatory.Presentation

  test "marks empty and partial projections without dividing by zero" do
    empty = Presentation.build(zero_projection())
    partial = Presentation.build(partial_projection())

    assert empty.state == :empty
    assert empty.overview.success_rate.measure == %{value: "not available", unit: nil}
    assert empty.overview.success_rate.minibar == 0.0
    assert empty.overview.cache_rate.measure == %{value: "not available", unit: nil}
    assert empty.overview.cost.confidence == "unavailable"
    assert empty.overview.tokens == %{value: "0", detail: "0 requests"}
    assert empty.traffic.total_label == "0 tokens · $0.00"
    assert partial.state == :partial
  end

  test "drops models with no token usage from the distribution" do
    model =
      Presentation.build(%{
        totals: %{requests: %{total: 5}, tokens: %{total: 100}},
        accounting: %{status: "complete"},
        models: [
          %{
            label: "used",
            request_count: 5,
            total_tokens: 100,
            share_percent: 100.0,
            cost_micros: 0
          },
          %{label: "ghost", request_count: 3, total_tokens: 0, share_percent: 0.0, cost_micros: 0}
        ]
      })

    assert Enum.map(model.models, & &1.label) == ["used"]
    assert hd(model.models).requests_label == "5 reqs"
    assert hd(model.models).token_label == "100"
  end

  test "accepts nil fields and keeps render output finite and metadata-only" do
    model =
      Presentation.build(%{
        window: %{key: "1h", started_at: nil, ended_at: nil},
        totals: nil,
        performance: nil,
        accounting: nil,
        buckets: nil,
        models: [%{label: "safe-model", total_tokens: 5}],
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
    assert hd(model.models).token_label == "5"
    assert hd(model.models).requests_label == "0 reqs"
    assert hd(model.models).share_label == "—"
    assert hd(model.models).cost_label == "0.00"
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
            tokens: %{input: 138_200_000, cached_input: 80_300_000, total: 138_200_000}
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
    assert model.traffic.total_label == "398.1M tokens · $0.00"
    assert model.traffic.fallback.total_label == "398.1M tokens · $0.00"
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

    assert row.total == 138_200_000
    assert row.total_label == "138.2M"
    assert row.cost_usd == 0.0
    assert row.cost_label == "$0.00"

    token_series = Enum.reject(chart_series, &(&1["name"] == "Cost"))
    cost_series = Enum.find(chart_series, &(&1["name"] == "Cost"))

    assert Enum.map(token_series, & &1["data"]) == [[138_200_000]]
    assert cost_series["data"] == [0.0]
  end

  test "formats the traffic header as total tokens and cost" do
    model =
      Presentation.build(%{
        totals: %{requests: %{total: 1}, tokens: %{input: 1_000, total: 1_000}},
        accounting: %{status: "complete"}
      })

    assert model.traffic.total_label == "1.0K tokens · $0.00"
  end

  defp zero_projection do
    %{totals: %{requests: %{total: 0}}, accounting: %{status: "missing"}}
  end

  defp partial_projection do
    %{totals: %{requests: %{total: 1}}, accounting: %{status: "partial"}}
  end
end
