defmodule CodexPoolerWeb.Observatory.ComponentsTrendsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Observatory.Components.Telemetry

  test "renders success and cache trend deltas beside their values" do
    html =
      render_component(&Telemetry.telemetry/1, %{
        overview: %{
          success_rate: %{
            measure: %{value: "90.0", unit: "%"},
            trend: trend("-5.0 pp", :error, :down)
          },
          cache_rate: %{
            measure: %{value: "25.0", unit: "%"},
            trend: trend("+10.0 pp", :success, :up)
          }
        },
        models: []
      })

    fragment = LazyHTML.from_fragment(html)

    for {id, direction, label} <- [
          {"success", "down", "-5.0 pp"},
          {"cache", "up", "+10.0 pp"}
        ] do
      assert LazyHTML.query(fragment, "#observatory-#{id}-trend[data-direction='#{direction}']") !=
               []

      assert html =~ label
    end
  end

  defp trend(label, tone, direction), do: %{label: label, tone: tone, direction: direction}
end
