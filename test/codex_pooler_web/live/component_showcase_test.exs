defmodule CodexPoolerWeb.Dev.ComponentShowcaseTest do
  use CodexPoolerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Dev.ComponentShowcaseLive

  @dev_routes Application.compile_env(:codex_pooler, :dev_routes, false)
  @showcase_route "/dev/component-showcase/:theme"
  @states ~w(loading empty stale error)

  test "isolated showcase renders real primitives and required states in both themes" do
    for theme <- ~w(light dark) do
      {:ok, view, html} = mount_showcase(theme)

      assert has_element?(view, "#component-showcase[data-theme='#{theme}']")
      assert has_element?(view, "#showcase-admin-primitives")
      assert has_element?(view, "#showcase-observatory-primitives")

      for tone <- ~w(neutral primary success warning error) do
        assert has_element?(view, "#showcase-metric-#{tone}")
      end

      for id <- ~w(active paused failed pending unknown) do
        assert has_element?(view, "#showcase-status-#{id}")
      end

      for id <- ~w(free pro team enterprise generated unknown) do
        assert has_element?(view, "#showcase-plan-#{id}")
      end

      for id <- ~w(ok warning error redacted) do
        assert has_element?(view, "#showcase-redacted-#{id}")
      end

      for id <- ~w(primary secondary danger ghost disabled) do
        assert has_element?(view, "#showcase-button-#{id}")
      end

      for id <- ~w(info success warning error) do
        assert has_element?(view, "#showcase-notice-#{id}")
      end

      for id <- ~w(secondary warning positive danger) do
        assert has_element?(view, "#showcase-dropdown-#{id}")
      end

      for state <- @states do
        assert has_element?(view, "#observatory-state-#{state}[role='status']")
      end

      assert has_element?(view, "#showcase-native-state-notes")

      assert has_element?(
               view,
               "#showcase-theme-toggle.card.relative.flex.flex-row.rounded-full > div.absolute"
             )

      assert has_element?(view, "#showcase-theme-toggle.h-10.w-40")

      assert unique_ids?(html)
    end
  end

  test "showcase cumulative control dispatches through the real chart hook boundary" do
    {:ok, view, _html} = mount_showcase("dark")

    assert has_element?(view, "#observatory-pause")
    assert has_element?(view, "#observatory-traffic-mode-interval[aria-pressed='true']")
    refute has_element?(view, "#showcase-traffic-interval")
    refute has_element?(view, "#showcase-traffic-cumulative")

    [click_command] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#observatory-traffic-mode-cumulative")
      |> LazyHTML.attribute("phx-click")

    assert [["dispatch", dispatch]] = Jason.decode!(click_command)
    assert dispatch["event"] == "chart:set-mode"
    assert dispatch["to"] == "#observatory-traffic-plot"
    assert dispatch["detail"] == %{"mode" => "cumulative"}

    [series_json] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#observatory-traffic-plot")
      |> LazyHTML.attribute("data-chart-series")

    assert series_json
           |> Jason.decode!()
           |> Enum.any?(fn %{"data" => [first, second | _rest]} -> second < first end)

    view |> element("#showcase-toggle-paused") |> render_click()
    assert has_element?(view, "#observatory-resume")
    assert has_element?(view, "#observatory-freshness.is-paused")
  end

  test "flash, request drawer, and policy dialog have deterministic visible review states" do
    for {trigger, review_state, selectors} <- [
          {"#showcase-show-flash", "flash", ["#flash-info[role='alert']:not([hidden])"]},
          {"#showcase-open-request-drawer", "request-drawer",
           [
             "#component-showcase.drawer-open",
             "#request-log-detail-drawer[checked]",
             "[data-role='request-log-detail-drawer-side']"
           ]},
          {"#showcase-open-policy-editor", "policy-dialog", ["#showcase-policy-editor[open]"]}
        ] do
      {:ok, view, _html} = mount_showcase("dark")
      view |> element(trigger) |> render_click()

      assert has_element?(view, "#component-showcase[data-review-state='#{review_state}']")

      for selector <- selectors do
        assert has_element?(view, selector)
      end
    end
  end

  test "the real flash group inherits the selected showcase theme boundary" do
    for theme <- ~w(light dark) do
      {:ok, view, _html} = mount_showcase(theme)
      view |> element("#showcase-show-flash") |> render_click()

      assert has_element?(view, "#showcase-theme-boundary[data-theme='#{theme}']")

      assert has_element?(
               view,
               "#showcase-theme-boundary[data-theme='#{theme}'] #flash-info[role='alert']:not([hidden])"
             )

      refute has_element?(view, "#component-showcase #flash-info")

      [classes] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#showcase-theme-boundary[data-theme='#{theme}'] #flash-info .alert")
        |> LazyHTML.attribute("class")

      assert "bg-success/10" in String.split(classes)
      assert "text-base-content" in String.split(classes)
    end
  end

  test "production-shaped route table excludes the showcase and returns 404", %{conn: conn} do
    routes = Phoenix.Router.routes(CodexPoolerWeb.Router)

    refute @dev_routes
    refute File.read!("config/prod.exs") =~ "dev_routes: true"
    refute Enum.any?(routes, &(&1.path == @showcase_route))
    assert html_response(get(conn, "/dev/component-showcase/dark"), 404) =~ "Not Found"
  end

  defp mount_showcase(theme, review_state \\ "catalog") do
    live_isolated(build_conn(), ComponentShowcaseLive,
      session: %{"theme" => theme, "review_state" => review_state}
    )
  end

  defp unique_ids?(html) do
    ids = Regex.scan(~r/\sid="([^"]+)"/, html, capture: :all_but_first) |> List.flatten()
    length(ids) == length(Enum.uniq(ids))
  end
end
