defmodule CodexPoolerWeb.Observatory.ComponentsTrendsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Observatory.Components.Telemetry

  test "renders success, cache, and throughput trend deltas beside their values" do
    html =
      render_component(&Telemetry.telemetry/1, %{
        overview: %{
          success_rate: %{label: "90.0%", trend: trend("-5.0 pp", :error, :down)},
          cache_rate: %{label: "25.0%", trend: trend("+10.0 pp", :success, :up)},
          throughput: %{p50_label: "125.5 tok/s", trend: trend("+20.0%", :success, :up)}
        },
        models: []
      })

    fragment = LazyHTML.from_fragment(html)

    for {id, direction, label} <- [
          {"success", "down", "-5.0 pp"},
          {"cache", "up", "+10.0 pp"},
          {"throughput", "up", "+20.0%"}
        ] do
      assert LazyHTML.query(fragment, "#observatory-#{id}-trend[data-direction='#{direction}']") !=
               []

      assert html =~ label
    end

    assert html =~ "125.5 tok/s"
    assert html =~ "Median settled token rate"
  end

  defp trend(label, tone, direction), do: %{label: label, tone: tone, direction: direction}
end
