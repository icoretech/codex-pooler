defmodule CodexPoolerWeb.Observatory.PresentationTrendsTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Observatory.Presentation

  test "renders finite deltas with holder-facing tone and direction" do
    model =
      Presentation.build(%{
        totals: %{
          requests: %{total: 4, succeeded: 3, failed: 1},
          tokens: %{input: 100, cached_input: 30, total: 180}
        },
        performance: %{throughput_tokens_per_second: %{p50: 20.0}},
        accounting: %{status: "complete"},
        trends: %{
          success_rate: %{delta: -75.0},
          cache_rate: %{delta: 30.0},
          throughput: %{delta: -20.0}
        }
      })

    assert model.overview.success_rate.trend == %{
             label: "-75.0 pp",
             tone: :error,
             direction: :down
           }

    assert model.overview.cache_rate.trend == %{
             label: "+30.0 pp",
             tone: :success,
             direction: :up
           }

    assert model.overview.throughput.trend == %{
             label: "-20.0%",
             tone: :error,
             direction: :down
           }

    assert model.overview.throughput.p50_label == "20.0 tok/s"
  end

  test "renders missing trend data as neutral and finite" do
    model =
      Presentation.build(%{totals: %{requests: %{total: 0}}, accounting: %{status: "missing"}})

    assert model.overview.success_rate.trend == %{
             label: "not available",
             tone: :neutral,
             direction: :unavailable
           }

    refute inspect(model) =~ ~r/(NaN|Infinity)/
  end
end
