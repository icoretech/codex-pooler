defmodule CodexPoolerWeb.Admin.LiveUpdatesTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodexPooler.Events
  alias CodexPooler.Pools

  @reload_telemetry_event [:codex_pooler, :admin, :stats_live, :reload]

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

  test "toggling says so, and reporting the same state does not", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "live-toast", name: "Live Toast"})

    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")

    # The icon swapping on a small control is easy to miss, and a list that has
    # simply gone quiet does not explain itself. These strings live only in the
    # flash — "Live updates" alone is also the button's own label.
    assert render_hook(view, "set_live_updates", %{"paused" => true}) =~
             "Lists hold still until you resume"

    assert render_hook(view, "set_live_updates", %{"paused" => false}) =~
             "Live updates resumed."

    # The toggle also reports on mount and on reconnect, and those agree with
    # what the join already established. On a fresh view, reporting the state it
    # is already in must not put a toast on the page.
    {:ok, fresh, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{pool.id}")
    html = render_hook(fresh, "set_live_updates", %{"paused" => false})

    refute html =~ "Lists hold still until you resume"
    refute html =~ "Live updates resumed."
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

  describe "a page that held its own reload" do
    setup do
      test_pid = self()
      handler_id = {__MODULE__, test_pid, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          @reload_telemetry_event,
          fn _event, measurements, metadata, _config ->
            send(test_pid, {:stats_reload, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "is refreshed on resume even when an unrelated event replays first", %{
      conn: conn,
      scope: scope
    } do
      {:ok, pool} = Pools.create_pool(scope, %{slug: "live-hold", name: "Live Hold"})

      {:ok, view, _html} = live(conn, ~p"/admin/stats?pool_id=#{pool.id}")

      pool_id = subscribed_pool_id(view)
      assert pool_id, "the dashboard must be watching a pool for an event to reach it"

      # Arm the page's own debounce the way a Pool event does.
      send(view.pid, {Events, %{pool_id: pool_id, topics: ["usage"]}})
      assert_receive {:stats_reload, _measurements, %{stage: :scheduled}}

      render_hook(view, "set_live_updates", %{"paused" => true})

      # The armed debounce now fires: the page holds the reload rather than
      # redrawing the dashboard the operator paused to read.
      fire_stats_debounce(view)
      refute_received {:stats_reload, _measurements, %{stage: :executed}}

      # Holding must not leave the assign naming a timer that has already fired,
      # or every later debounce coalesces onto one that will never send.
      refute stats_reload_timer(view)

      # An event for a pool this dashboard is not watching. The gate holds every
      # Pool event, so this one is replayed on resume — and ignored on arrival,
      # which leaves the held reload the only thing that can redraw the page.
      send(view.pid, {Events, %{pool_id: Ecto.UUID.generate(), topics: ["usage"]}})

      render_hook(view, "set_live_updates", %{"paused" => false})

      assert_receive {:stats_reload, _measurements, %{stage: :executed}}
    end

    test "is refreshed on resume when the gate had to collapse two held events", %{
      conn: conn,
      scope: scope
    } do
      {:ok, pool} = Pools.create_pool(scope, %{slug: "live-collapse", name: "Live Collapse"})

      {:ok, view, _html} = live(conn, ~p"/admin/stats?pool_id=#{pool.id}")

      render_hook(view, "set_live_updates", %{"paused" => true})

      # Two events sharing a pool and topics collapse to one held message. Pages
      # that read further into the payload — the upstream cockpit compares an
      # identity id — lose the arrival they were waiting for that way, so a
      # collapse has to arm the page's own refresh.
      other_pool_id = Ecto.UUID.generate()
      send(view.pid, {Events, %{pool_id: other_pool_id, topics: ["usage"], payload: %{"n" => 1}}})
      send(view.pid, {Events, %{pool_id: other_pool_id, topics: ["usage"], payload: %{"n" => 2}}})

      render_hook(view, "set_live_updates", %{"paused" => false})

      # Only the second event survives the collapse, and this dashboard ignores
      # it. The refresh can only have come from the collapse being reported.
      assert_receive {:stats_reload, _measurements, %{stage: :executed}}
    end
  end

  defp fire_stats_debounce(view) do
    timer = stats_reload_timer(view)
    if is_reference(timer), do: Process.cancel_timer(timer, async: false, info: false)

    send(view.pid, :reload_stats_dashboard)
    # A synchronous call behind it, so the send above has been handled.
    :sys.get_state(view.pid)

    :ok
  end

  defp stats_reload_timer(view) do
    :sys.get_state(view.pid).socket.assigns[:stats_reload_timer]
  end

  defp subscribed_pool_id(view) do
    :sys.get_state(view.pid).socket.assigns.subscribed_pool_ids
    |> MapSet.to_list()
    |> List.first()
  end
end
