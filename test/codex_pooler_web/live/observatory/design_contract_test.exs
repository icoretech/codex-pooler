defmodule CodexPoolerWeb.Observatory.DesignContractTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Observatory.Components.Telemetry

  test "telemetry facts keep definition terms and descriptions in direct groups" do
    html = render_component(&Telemetry.telemetry/1, %{overview: %{}, models: []})
    fragment = LazyHTML.from_fragment(html)

    for {id, descriptions} <- [
          {"observatory-fact-cost", 2},
          {"observatory-fact-tokens", 2}
        ] do
      assert LazyHTML.query(fragment, "##{id} > *") |> Enum.flat_map(&LazyHTML.tag/1) ==
               ["dt" | List.duplicate("dd", descriptions)]

      assert LazyHTML.query(fragment, "##{id} dd dd") |> Enum.empty?()
    end
  end
end
