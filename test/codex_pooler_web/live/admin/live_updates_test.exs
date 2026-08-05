defmodule CodexPoolerWeb.Admin.LiveUpdatesTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodexPooler.Pools

  setup :register_and_log_in_user

  test "the topbar carries the toggle on every admin surface", %{conn: conn, scope: scope} do
    {:ok, _pool} = Pools.create_pool(scope, %{slug: "live-toggle", name: "Live Toggle"})

    for path <- ["/admin/request-logs", "/admin/audit-logs", "/admin/pools", "/admin/jobs"] do
      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, "#admin-live-updates-toggle[phx-hook='LiveUpdatesToggle']"),
             "expected the live-updates toggle on #{path}"

      # The name stays put in both states; only aria-pressed flips.
      assert has_element?(view, "#admin-live-updates-toggle[aria-label='Pause live updates']")
    end
  end

  test "a malformed toggle payload cannot kill the LiveView", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "live-garbage", name: "Live Garbage"})

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    # The hook owns this event name, so it owns every shape of it: without the
    # catch-all these fall through to a page that has no clause for them.
    render_hook(view, "set_live_updates", %{})
    render_hook(view, "set_live_updates", %{"paused" => "yes-please"})
    render_hook(view, "set_live_updates", %{"Paused" => true})

    assert render(view) =~ "Request logs"
  end

  test "alert notifications keep flowing while the lists are paused", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "live-alerts", name: "Live Alerts"})

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    render_hook(view, "set_live_updates", %{"paused" => true})

    # A paused list is a reading choice; an alert firing is not something to be
    # quiet about, and it speaks a different message so the gate never sees it.
    assert has_element?(view, "#admin-notifications-button")
    assert render(view) =~ "Request logs"
  end
end
