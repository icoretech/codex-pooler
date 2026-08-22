defmodule CodexPoolerWeb.Admin.ModelInfoPopoverTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Admin.Components

  test "summarizes account-scoped context differences without internal terminology" do
    html =
      render_component(&Components.model_info_popover/1, %{
        id: "model-info-test",
        model_id: "gpt-example",
        info: %{
          description: "Synthetic model.",
          description_state: :available,
          minimal_client_versions: ["0.142.2", "0.144.0"],
          catalog_updated_at: ~U[2026-08-22 01:00:00Z],
          context_profiles: [
            %{raw_window: 272_000, raw_max_window: 272_000},
            %{raw_window: 272_000, raw_max_window: 872_000}
          ]
        }
      })

    fragment = LazyHTML.from_fragment(html)
    context = LazyHTML.query(fragment, "[data-role='model-info-context']")

    assert LazyHTML.text(context) =~ "Context"
    assert LazyHTML.text(context) =~ "272k default · up to 872k · varies by upstream"

    assert LazyHTML.query(fragment, "[data-role='model-info-title']") |> LazyHTML.text() =~
             "Model info"

    assert LazyHTML.query(fragment, "[data-role='model-info-title'].font-mono") != []

    assert LazyHTML.query(fragment, "[data-role='model-info-model-id']") |> LazyHTML.text() =~
             "gpt-example"

    assert LazyHTML.query(context, "dd.font-mono") |> Enum.empty?()
    assert LazyHTML.query(context, ".border-t") |> Enum.empty?()
    assert LazyHTML.query(fragment, "[data-role='model-info-facts'].border-t") |> Enum.empty?()
    refute html =~ "Usable share"
    refute html =~ "Source default"
    refute html =~ "Source maximum"
    assert html =~ "Min Codex 0.142.2-0.144.0 · varies by upstream"
    assert html =~ "Catalog checked"
    assert html =~ "ago"
    assert html =~ ~s(title="Catalog checked 2026-08-22 01:00 UTC")
  end
end
