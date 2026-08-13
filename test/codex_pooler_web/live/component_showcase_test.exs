defmodule CodexPoolerWeb.Dev.ComponentShowcaseTest do
  use CodexPoolerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodexPoolerWeb.Dev.{ComponentShowcaseDialogs, ComponentShowcaseLive}

  @dev_routes Application.compile_env(:codex_pooler, :dev_routes, false)
  @showcase_route "/dev/component-showcase/:theme"
  @states ~w(loading empty stale error)
  @oauth_browser_authorization_url "https://auth.example.com/oauth/authorize?client_id=dev-component-showcase&response_type=code&state=synthetic-review-state"

  @tag :saved_reset_redemption_cause
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
               "#showcase-saved-reset-request-cause",
               "Last automatic redemption · Request · weekly exhausted"
             )

      assert has_element?(
               view,
               "#showcase-saved-reset-scheduled-cause",
               "Last automatic redemption · Scheduled · last call"
             )

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

  test "browser OAuth review state renders the real pending link dialog with synthetic data" do
    {:ok, view, html} = mount_showcase("light", "oauth-browser-dialog")

    assert has_element?(view, "#showcase-oauth-browser-dialog-fixture")
    # The title carries the destination Pool, so it survives the whole flow.
    assert has_element?(view, "#oauth-link-dialog[open]", "Link an account to Design review Pool")

    # A pending browser flow must never read as a finished one. It also carries
    # no status line of its own: nothing is running on this route — the pooler is
    # waiting for the operator — and the empty field and its help text already
    # say so. The device route keeps its status line, because a poll really is
    # running there and the operator has no other signal for it.
    refute has_element?(view, "#oauth-link-dialog .alert-success")
    refute has_element?(view, "#oauth-link-dialog [data-role='oauth-pending-status']")

    assert has_element?(view, "#oauth-link-authorization-step", "Authorization page")
    assert has_element?(view, "#oauth-link-callback-step", "Callback URL")
    assert has_element?(view, "#oauth-link-callback-form")
    assert has_element?(view, "#oauth-link-callback-url[required][aria-describedby]")
    # The completing action lives in the dialog footer, beside Cancel, and is the
    # dialog's only filled orange: the URL row's Open and Copy are peers below it.
    assert has_element?(
             view,
             "#oauth-link-dialog-footer #oauth-link-submit-callback.btn-primary",
             "Complete link"
           )

    assert has_element?(view, "#oauth-link-cancel.btn-ghost", "Cancel")

    # The URL is a readonly field rather than a bare link, so it can be read and
    # selected as well as opened; the Open action carries the same href.
    assert has_element?(
             view,
             ~s(#oauth-link-authorization-url[readonly][value="#{@oauth_browser_authorization_url}"])
           )

    assert has_element?(
             view,
             ~s(#oauth-link-authorization-open[href="#{@oauth_browser_authorization_url}"][target="_blank"]),
             "Open"
           )

    assert has_element?(
             view,
             ~s(#oauth-link-authorization-url-copy[phx-hook="ClipboardCopy"][phx-update="ignore"][data-copy-text="#{@oauth_browser_authorization_url}"]),
             "Copy link"
           )

    assert unique_ids?(html)
  end

  test "a finished OAuth link states the outcome and offers the cockpit" do
    {:ok, view, _html} = mount_showcase("light", "oauth-browser-dialog", "completed")

    # Declarative once the flow is done: an imperative title over a success
    # banner reads as a step still owed.
    assert has_element?(view, "#oauth-link-dialog h2", "Added to Design review Pool")
    assert has_element?(view, "#oauth-link-status.alert-success", "OpenAI account linked")
    refute render(view) =~ "Choose a Pool, then approve the account."

    # Nothing left to submit, and one place left to go.
    refute has_element?(view, "#oauth-link-submit-callback")

    assert has_element?(
             view,
             "#oauth-link-dialog-footer #oauth-link-open-cockpit.btn-primary",
             "Open cockpit"
           )
  end

  test "every dialog in the gallery renders through its real component" do
    # The gallery exists because dialog chrome is shared: the shell, the footer,
    # the touch-target floor. This pins that each case still reaches a real
    # `<dialog>` with the footer marker, so a fixture that drifts out of shape
    # with its component fails here rather than silently rendering nothing.
    for {id, _label} <- ComponentShowcaseDialogs.dialogs() do
      {:ok, view, html} = mount_showcase("light", "dialogs", nil, id)

      assert has_element?(view, "#showcase-dialog-gallery")
      assert has_element?(view, ~s(#showcase-dialog-#{id}[aria-current="page"]))

      assert has_element?(view, "dialog[open].modal-bottom"),
             "#{id} did not render an open bottom-sheet dialog"

      assert has_element?(view, ~s(dialog[open] [data-role="admin-dialog-footer"])),
             "#{id} rendered without the shared dialog footer"

      assert unique_ids?(html), "#{id} rendered duplicate DOM ids"
    end
  end

  test "dialog footers carry the marker the touch-target floor is keyed to" do
    # `app.css` raises every footer control to 44px at touch widths through
    # `[data-role="admin-dialog-footer"]`. Dropping the attribute would leave
    # 28px targets on every dialog with nothing failing to say so.
    {:ok, view, _html} = mount_showcase("light", "oauth-browser-dialog")

    assert has_element?(
             view,
             ~s(footer#oauth-link-dialog-footer[data-role="admin-dialog-footer"])
           )

    {:ok, policy_view, _html} = mount_showcase("dark", "policy-dialog")

    assert has_element?(policy_view, ~s(footer[data-role="admin-dialog-footer"]))
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
    refute Enum.any?(routes, &(&1.path == @showcase_route))
    assert html_response(get(conn, "/dev/component-showcase/dark"), 404) =~ "Not Found"
  end

  defp mount_showcase(theme, review_state \\ "catalog", oauth_case \\ nil, dialog_case \\ nil) do
    session =
      %{"theme" => theme, "review_state" => review_state}
      |> then(&if oauth_case, do: Map.put(&1, "oauth_case", oauth_case), else: &1)
      |> then(&if dialog_case, do: Map.put(&1, "dialog_case", dialog_case), else: &1)

    live_isolated(build_conn(), ComponentShowcaseLive, session: session)
  end

  defp unique_ids?(html) do
    ids = Regex.scan(~r/\sid="([^"]+)"/, html, capture: :all_but_first) |> List.flatten()
    length(ids) == length(Enum.uniq(ids))
  end
end
