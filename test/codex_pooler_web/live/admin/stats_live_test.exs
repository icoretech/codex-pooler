defmodule CodexPoolerWeb.Admin.StatsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.DailyRollup
  alias CodexPooler.Accounts
  alias CodexPooler.Audit
  alias CodexPooler.Events
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Jobs
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @reload_telemetry_event [:codex_pooler, :admin, :stats_live, :reload]
  @dashboard_build_telemetry_event [:codex_pooler, :admin, :stats, :dashboard, :build]
  @telemetry_windows ~w(1h 5h 24h 7d unknown)
  @telemetry_scopes ~w(selected_pool all_visible_pools unknown)

  test "redirects unauthenticated operators to login" do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/admin/stats")
  end

  describe "authenticated stats dashboard" do
    setup :register_and_log_in_user

    setup do
      test_pid = self()
      handler_id = {__MODULE__, test_pid, make_ref()}

      :ok =
        :telemetry.attach_many(
          handler_id,
          [@reload_telemetry_event, @dashboard_build_telemetry_event],
          fn
            @reload_telemetry_event, measurements, metadata, _config ->
              send(test_pid, {:admin_stats_live_reload, measurements, metadata})

            @dashboard_build_telemetry_event, measurements, metadata, _config ->
              send(test_pid, {:admin_stats_dashboard_build, measurements, metadata})
          end,
          nil
        )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)
    end

    test "renders required selectors and fixture-derived KPI table and chart values", %{
      conn: conn,
      scope: scope
    } do
      {:ok, pool} = Pools.create_pool(scope, %{slug: "stats-live", name: "Stats Live"})

      {:ok, other_pool} =
        Pools.create_pool(scope, %{slug: "stats-live-other", name: "Stats Other"})

      assert {:ok, _settings} =
               Pools.update_routing_settings(scope, pool, %{"routing_strategy" => "quota_first"})

      assert {:ok, _settings} =
               Pools.update_routing_settings(scope, other_pool, %{
                 "routing_strategy" => "least_recent_success"
               })

      sensitive_marker = "stats-secret-do-not-render"
      setup = stats_dashboard_fixture(pool, sensitive_marker)

      other_setup =
        stats_usage_fixture(other_pool, %{total_tokens: 33, correlation_id: "stats-other"})

      {:ok, view, _html} = live(conn, ~p"/admin/stats?pool_id=#{pool.id}&window=24h")

      for selector <- required_selectors() do
        assert has_element?(view, selector)
      end

      assert has_element?(view, "#admin-nav-stats[aria-current='page']")
      assert has_element?(view, "#stats-page-header", "Usage")
      assert has_element?(view, "#stats-page-header", "Usage, cost, latency, sessions, and quota")
      assert has_element?(view, "#stats-pool-filter[type='hidden'][value='#{pool.id}']")
      assert has_element?(view, "#stats-pool-filter-control")

      assert has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-trigger']",
               "Stats Live"
             )

      assert has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-trigger']",
               "Quota first"
             )

      assert has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-trigger'] [data-role='pool-filter-icon'].text-success"
             )

      assert has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-menu'] button[data-pool-id='']",
               "All Pools"
             )

      assert has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-menu'] button[data-pool-id='#{other_pool.id}']",
               "Stats Other"
             )

      assert has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-menu'] button[data-pool-id='#{pool.id}']",
               "Quota first"
             )

      assert has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-menu'] button[data-pool-id='#{other_pool.id}']",
               "Least recent success"
             )

      assert has_element?(view, "#stats-pool-filter-control [aria-label='Scope']")
      assert has_element?(view, "#stats-time-filter-control [aria-label='Range']")
      refute has_element?(view, "#stats-filter-submit")
      refute has_element?(view, "#stats-filter-reset")
      refute has_element?(view, "#stats-selected-scope")
      refute has_element?(view, "#stats-selected-window")
      refute has_element?(view, "#stats-usage-source")
      assert has_element?(view, "#stats-time-filter[type='hidden'][value='24h']")
      assert has_element?(view, "#stats-time-filter-control")

      assert has_element?(
               view,
               "#stats-time-filter-control [data-role='window-filter-trigger']",
               "Last 24 hours"
             )

      assert has_element?(
               view,
               "#stats-time-filter-control [data-role='window-filter-menu'] button[data-window='1h']",
               "Last 1 hour"
             )

      assert has_element?(
               view,
               "#stats-time-filter-control [data-role='window-filter-menu'] button[data-window='7d']",
               "Last 7 days"
             )

      assert has_element?(view, "#stats-kpis")
      assert has_element?(view, "#stats-kpis article[data-density='compact']")
      assert has_element?(view, "#stats-kpi-requests [data-role='metric-card-value'].text-lg")
      assert has_element?(view, "#stats-kpi-requests", "2")
      assert has_element?(view, "#stats-kpi-requests", "1 succeeded")
      assert has_element?(view, "#stats-kpi-requests", "1 failed")
      assert has_element?(view, "#stats-kpi-success-rate", "50.0%")
      assert has_element?(view, "#stats-kpi-success-rate", "Completed")
      assert has_element?(view, "#stats-kpi-tokens", "100")
      assert has_element?(view, "#stats-kpi-tokens", "60 input")
      assert has_element?(view, "#stats-kpi-tokens", "10 cached")
      assert has_element?(view, "#stats-kpi-tokens-per-sec", "50.0")
      assert has_element?(view, "#stats-kpi-tokens-per-sec", "Throughput")
      assert has_element?(view, "#stats-kpi-cost", "$1.500000")
      assert has_element?(view, "#stats-kpi-avg-latency", "1000 ms")
      assert has_element?(view, "#stats-kpi-avg-latency", "Mean response time")
      assert has_element?(view, "#stats-kpi-active-sessions", "1")
      assert has_element?(view, "#stats-kpi-active-sessions", "1 turns")
      assert has_element?(view, "#stats-kpi-quota-health", "Available")
      assert has_element?(view, "#stats-traffic-chart-plot[phx-hook='ApexTimeSeriesChart']")
      assert has_element?(view, "#stats-traffic-chart-plot[phx-update='ignore']")
      assert has_element?(view, "#stats-traffic-chart-plot[data-chart-unit='tokens']")
      assert has_element?(view, "#stats-traffic-chart-plot[data-chart-units]")
      assert has_element?(view, "#stats-traffic-chart-plot[data-chart-yaxis]")
      assert has_element?(view, "#stats-traffic-chart", "Traffic over time")
      assert has_element?(view, "#stats-traffic-chart", "100 tokens / 2 requests")
      refute has_element?(view, "#stats-traffic-chart-plot svg")
      refute has_element?(view, "#stats-token-chart")
      assert has_element?(view, "#stats-api-key-table", "Stats UI key")
      assert has_element?(view, "#stats-api-key-table", "$1.500000")
      assert has_element?(view, "#stats-upstream-table", "Stats assignment")
      assert has_element?(view, "#stats-upstream-table thead th", "Upstream")
      assert has_element?(view, "#stats-upstream-table thead th", "Status")
      refute has_element?(view, "#stats-upstream-table thead th", "Quota")
      assert has_element?(view, "#stats-upstream-table thead th", "Requests")
      assert has_element?(view, "#stats-upstream-table thead th", "Tokens")
      assert has_element?(view, "#stats-upstream-row-0 td:nth-child(3)", "1")
      assert has_element?(view, "#stats-upstream-row-0 td:nth-child(4)", "100")
      refute has_element?(view, "#stats-upstream-row-0 td:nth-child(5)")
      refute has_element?(view, "#stats-recent-activity")
      refute has_element?(view, "#stats-quota-table")

      refute has_element?(view, "#stats-api-key-table", other_setup.api_key.display_name)
      refute has_element?(view, "#stats-traffic-chart", "33 tokens")

      traffic_chart_html = view |> element("#stats-traffic-chart-plot") |> render()

      assert traffic_chart_html =~ "ApexTimeSeriesChart"
      assert traffic_chart_html =~ "Tokens"
      assert traffic_chart_html =~ "Requests"

      html = render(view)
      refute html =~ sensitive_marker
      refute html =~ setup.raw_key
      refute html =~ "Bearer #{sensitive_marker}"
      refute html =~ "raw prompt #{sensitive_marker}"
    end

    test "filter form patches deterministic params and re-renders selected Pool values", %{
      conn: conn,
      scope: scope
    } do
      {:ok, first_pool} =
        Pools.create_pool(scope, %{slug: "stats-filter-first", name: "Stats Filter First"})

      {:ok, second_pool} =
        Pools.create_pool(scope, %{slug: "stats-filter-second", name: "Stats Filter Second"})

      first = stats_usage_fixture(first_pool, %{total_tokens: 11, correlation_id: "stats-first"})

      second =
        stats_usage_fixture(second_pool, %{total_tokens: 27, correlation_id: "stats-second"})

      {:ok, view, _html} = live(conn, ~p"/admin/stats?pool_id=#{first_pool.id}&window=24h")

      assert has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-trigger']",
               "Stats Filter First"
             )

      assert has_element?(view, "#stats-kpi-tokens", "11")
      refute has_element?(view, "#stats-traffic-chart", "27 tokens")

      view
      |> element("#stats-pool-filter-control button[data-pool-id='#{second_pool.id}']")
      |> render_click()

      assert_patch(view, ~p"/admin/stats?pool_id=#{second_pool.id}&window=24h")
      assert has_element?(view, "#stats-pool-filter[value='#{second_pool.id}']")

      assert has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-trigger']",
               "Stats Filter Second"
             )

      view
      |> element("#stats-time-filter-control button[data-window='1h']")
      |> render_click()

      assert_patch(view, ~p"/admin/stats?pool_id=#{second_pool.id}&window=1h")
      assert has_element?(view, "#stats-time-filter[value='1h']")

      assert has_element?(
               view,
               "#stats-time-filter-control [data-role='window-filter-trigger']",
               "Last 1 hour"
             )

      view
      |> element("#stats-filter-form")
      |> render_submit(%{"filters" => %{"pool_id" => second_pool.id, "window" => "1h"}})

      assert_patch(view, ~p"/admin/stats?pool_id=#{second_pool.id}&window=1h")

      assert has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-trigger']",
               "Stats Filter Second"
             )

      assert has_element?(view, "#stats-time-filter[value='1h']")
      assert has_element?(view, "#stats-kpi-tokens", "27")
      assert has_element?(view, "#stats-traffic-chart", "27 tokens")
      refute has_element?(view, "#stats-traffic-chart", "11 tokens")
      refute render(view) =~ first.raw_key
      refute render(view) =~ second.raw_key
    end

    test "assigned admin sees aggregate and filters only assigned pools", %{
      conn: conn,
      scope: scope
    } do
      {:ok, pool_a} = Pools.create_pool(scope, %{slug: "stats-scope-a", name: "Stats Scope A"})
      {:ok, pool_b} = Pools.create_pool(scope, %{slug: "stats-scope-b", name: "Stats Scope B"})
      {:ok, pool_c} = Pools.create_pool(scope, %{slug: "stats-scope-c", name: "Stats Scope C"})

      assigned_a =
        stats_usage_fixture(pool_a, %{
          total_tokens: 10,
          correlation_id: "stats-scope-a",
          api_key_display_name: "Scoped A key"
        })

      assigned_b =
        stats_usage_fixture(pool_b, %{
          total_tokens: 20,
          correlation_id: "stats-scope-b",
          api_key_display_name: "Scoped B key"
        })

      hidden_c =
        stats_usage_fixture(pool_c, %{
          total_tokens: 30,
          correlation_id: "stats-scope-c",
          api_key_display_name: "Hidden C key"
        })

      admin_conn = log_in_scoped_admin(conn, scope, [pool_a, pool_b])

      {:ok, view, _html} = live(admin_conn, ~p"/admin/stats?window=24h")

      assert has_element?(view, "#stats-pool-filter[type='hidden'][value='']")
      assert has_element?(view, "#stats-pool-filter-control", "All Pools")
      assert has_element?(view, "#stats-pool-filter-control button[data-pool-id='#{pool_a.id}']")
      assert has_element?(view, "#stats-pool-filter-control button[data-pool-id='#{pool_b.id}']")
      refute has_element?(view, "#stats-pool-filter-control button[data-pool-id='#{pool_c.id}']")
      refute has_element?(view, "#stats-pool-filter-control", "Stats Scope C")

      assert has_element?(view, "#stats-kpi-requests", "2")
      assert has_element?(view, "#stats-kpi-tokens", "30")
      assert has_element?(view, "#stats-traffic-chart", "30 tokens")
      assert has_element?(view, "#stats-api-key-table", "Scoped A key")
      assert has_element?(view, "#stats-api-key-table", "Scoped B key")
      refute has_element?(view, "#stats-api-key-table", "Hidden C key")

      view
      |> element("#stats-pool-filter-control button[data-pool-id='#{pool_b.id}']")
      |> render_click()

      assert_patch(view, ~p"/admin/stats?pool_id=#{pool_b.id}&window=24h")
      assert has_element?(view, "#stats-pool-filter[value='#{pool_b.id}']")
      assert has_element?(view, "#stats-kpi-tokens", "20")
      assert has_element?(view, "#stats-api-key-table", "Scoped B key")
      refute has_element?(view, "#stats-api-key-table", "Scoped A key")
      refute has_element?(view, "#stats-api-key-table", "Hidden C key")
      refute render(view) =~ assigned_a.raw_key
      refute render(view) =~ assigned_b.raw_key
      refute render(view) =~ hidden_c.raw_key

      {:ok, blocked_view, _html} =
        live(admin_conn, ~p"/admin/stats?pool_id=#{pool_c.id}&window=24h")

      assert has_element?(blocked_view, "#stats-filter-error", "pool filter is not available")
      refute has_element?(blocked_view, "#stats-kpis")
      refute has_element?(blocked_view, "#stats-pool-filter-control", "Stats Scope C")
      refute has_element?(blocked_view, "#stats-api-key-table", "Hidden C key")
      refute render(blocked_view) =~ hidden_c.raw_key
    end

    test "renders monthly-only primary quota evidence as available", %{
      conn: conn,
      scope: scope
    } do
      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "stats-monthly-ui", name: "Stats Monthly UI"})

      %{identity: identity} = upstream_assignment_fixture(pool)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   window_kind: "primary",
                   window_minutes: 43_200,
                   used_percent: Decimal.new("42.5"),
                   reset_at: DateTime.add(now, 30, :day),
                   source: "codex_usage",
                   source_precision: "authoritative",
                   quota_scope: "account",
                   quota_family: "account"
                 }
               ])

      {:ok, view, _html} = live(conn, ~p"/admin/stats?pool_id=#{pool.id}&window=5h")

      assert has_element?(view, "#stats-kpi-quota-health", "Available")
      assert has_element?(view, "#stats-kpi-quota-health", "1 usable")
      assert has_element?(view, "#stats-kpi-quota-health", "0 missing quota")
      refute has_element?(view, "#stats-kpi-quota-health", "Missing evidence")
    end

    test "unassigned admin sees empty scoped stats with no pool subscriptions", %{
      conn: conn,
      scope: scope
    } do
      {:ok, hidden_pool} =
        Pools.create_pool(scope, %{slug: "stats-unassigned-live", name: "Stats Unassigned Live"})

      hidden =
        stats_usage_fixture(hidden_pool, %{
          total_tokens: 44,
          correlation_id: "stats-unassigned-live",
          api_key_display_name: "Unassigned hidden key"
        })

      admin_conn = log_in_scoped_admin(conn, scope, [])

      {:ok, view, _html} = live(admin_conn, ~p"/admin/stats?window=24h")

      assert has_element?(view, "#stats-pool-filter[type='hidden'][value='']")

      assert has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-trigger']",
               "No assigned Pools"
             )

      refute has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-menu'] button"
             )

      refute has_element?(view, "#stats-pool-filter-control", "All Pools")
      refute has_element?(view, "#stats-pool-filter-control", "Stats Unassigned Live")

      assert has_element?(view, "#stats-kpi-requests", "0")
      assert has_element?(view, "#stats-kpi-tokens", "0")
      assert has_element?(view, "#stats-traffic-chart", "0 tokens / 0 requests")
      refute has_element?(view, "#stats-api-key-table", "Unassigned hidden key")

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.subscribed_pool_ids == MapSet.new()
      assert state.socket.assigns.dashboard.filters.pool_options == []
      assert state.socket.assigns.dashboard.charts.requests == []
      assert state.socket.assigns.dashboard.charts.tokens == []
      assert [%{code: :no_reporting_pools}] = state.socket.assigns.dashboard.empty_states

      chart_html = view |> element("#stats-traffic-chart-plot") |> render()
      assert chart_html =~ "data-chart-categories=\"[]\""
      refute render(view) =~ hidden.raw_key
    end

    test "dashboard build telemetry records success and sanitized error outcomes", %{
      conn: conn,
      scope: scope
    } do
      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "stats-build-telemetry", name: "Stats Build Telemetry"})

      {:ok, _view, _html} = live(conn, ~p"/admin/stats?window=7d")

      assert_build_telemetry(:ok, window: "7d", scope: "all_visible_pools")
      drain_build_telemetry()

      admin_conn = log_in_scoped_admin(conn, scope, [])

      {:ok, blocked_view, _html} =
        live(admin_conn, ~p"/admin/stats?pool_id=#{pool.id}&window=5h")

      error_metadata =
        assert_build_telemetry(:error,
          window: "5h",
          scope: "selected_pool",
          error_code: :pool_not_found
        )

      assert Map.keys(error_metadata) |> Enum.sort() == [:error_code, :outcome, :scope, :window]
      refute Map.has_key?(error_metadata, :message)
      refute Map.has_key?(error_metadata, :error)
      refute inspect(error_metadata) =~ "pool filter is not available"

      state = :sys.get_state(blocked_view.pid)
      assert state.socket.assigns.dashboard == nil

      assert %{code: :pool_not_found, message: "pool filter is not available"} =
               state.socket.assigns.filter_error

      assert state.socket.assigns.pool_filter_options == []
      assert state.socket.assigns.current_params == %{"pool_id" => pool.id, "window" => "5h"}
      assert has_element?(blocked_view, "#stats-filter-error", "pool filter is not available")
      refute has_element?(blocked_view, "#stats-kpis")
    end

    test "selected Pool usage event reloads stats after the debounce", %{
      conn: conn,
      scope: scope
    } do
      {:ok, pool} =
        Pools.create_pool(scope, %{
          slug: "stats-realtime-selected",
          name: "Stats Realtime Selected"
        })

      {:ok, view, _html} = live(conn, ~p"/admin/stats?pool_id=#{pool.id}&window=24h")

      assert has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-trigger']",
               "Stats Realtime Selected"
             )

      assert has_element?(view, "#stats-kpi-tokens", "0")

      stats_usage_fixture(pool, %{total_tokens: 42, correlation_id: "stats-selected-realtime"})
      assert {:ok, _event} = Events.broadcast_usage(pool.id, "usage_updated", %{rows: 1})

      assert_reload_telemetry(:scheduled, window: "24h", scope: "selected_pool")
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#stats-kpi-tokens", "0")
      refute has_element?(view, "#stats-traffic-chart", "42 tokens")

      execute_scheduled_reload(view)
      assert_reload_telemetry(:executed, window: "24h", scope: "selected_pool")
      assert has_element?(view, "#stats-kpi-tokens", "42")
      assert has_element?(view, "#stats-traffic-chart", "42 tokens")
      assert has_element?(view, "#stats-api-key-table", "Stats usage key")
    end

    test "events for non-selected Pools do not update the selected dashboard", %{
      conn: conn,
      scope: scope
    } do
      {:ok, selected_pool} =
        Pools.create_pool(scope, %{slug: "stats-ignore-selected", name: "Stats Ignore Selected"})

      {:ok, other_pool} =
        Pools.create_pool(scope, %{slug: "stats-ignore-other", name: "Stats Ignore Other"})

      selected =
        stats_usage_fixture(selected_pool, %{
          total_tokens: 11,
          correlation_id: "stats-ignore-selected"
        })

      {:ok, view, _html} = live(conn, ~p"/admin/stats?pool_id=#{selected_pool.id}&window=24h")

      assert has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-trigger']",
               "Stats Ignore Selected"
             )

      assert has_element?(view, "#stats-kpi-tokens", "11")

      other =
        stats_usage_fixture(other_pool, %{
          total_tokens: 77,
          correlation_id: "stats-ignore-other",
          api_key_display_name: "Other realtime key"
        })

      assert {:ok, _event} = Events.broadcast_usage(other_pool.id, "usage_updated", %{rows: 1})
      _ = :sys.get_state(view.pid)
      refute_reload_telemetry(:scheduled)
      assert has_element?(view, "#stats-kpi-tokens", "11")
      refute has_element?(view, "#stats-traffic-chart", "77 tokens")
      refute has_element?(view, "#stats-api-key-table", other.api_key.display_name)
      refute render(view) =~ selected.raw_key
      refute render(view) =~ other.raw_key
    end

    test "rapid events coalesce into one debounced reload", %{conn: conn, scope: scope} do
      {:ok, pool} = Pools.create_pool(scope, %{slug: "stats-realtime-burst", name: "Stats Burst"})

      {:ok, view, _html} = live(conn, ~p"/admin/stats?pool_id=#{pool.id}&window=24h")

      assert has_element?(view, "#stats-kpi-tokens", "0")

      stats_usage_fixture(pool, %{total_tokens: 64, correlation_id: "stats-burst"})

      for reason <- ["usage_updated", "request_finalized", "model_sync_completed"] do
        assert {:ok, _event} = Events.broadcast_usage(pool.id, reason, %{rows: 1})
      end

      assert_reload_telemetry(:scheduled, window: "24h", scope: "selected_pool")
      assert_reload_telemetry(:coalesced, window: "24h", scope: "selected_pool")
      assert_reload_telemetry(:coalesced, window: "24h", scope: "selected_pool")
      _ = :sys.get_state(view.pid)
      refute_reload_telemetry(:scheduled)
      refute_reload_telemetry(:coalesced)
      assert has_element?(view, "#stats-kpi-tokens", "0")

      execute_scheduled_reload(view)
      assert_reload_telemetry(:executed, window: "24h", scope: "selected_pool")
      _ = :sys.get_state(view.pid)
      refute_reload_telemetry(:executed)
      assert has_element?(view, "#stats-kpi-tokens", "64")
      assert has_element?(view, "#stats-traffic-chart", "64 tokens")
    end

    test "filter changes replace the selected Pool subscription", %{conn: conn, scope: scope} do
      {:ok, first_pool} =
        Pools.create_pool(scope, %{slug: "stats-sub-first", name: "Stats Sub First"})

      {:ok, second_pool} =
        Pools.create_pool(scope, %{slug: "stats-sub-second", name: "Stats Sub Second"})

      stats_usage_fixture(first_pool, %{total_tokens: 12, correlation_id: "stats-sub-first"})
      stats_usage_fixture(second_pool, %{total_tokens: 21, correlation_id: "stats-sub-second"})

      {:ok, view, _html} = live(conn, ~p"/admin/stats?pool_id=#{first_pool.id}&window=24h")

      assert has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-trigger']",
               "Stats Sub First"
             )

      assert has_element?(view, "#stats-kpi-tokens", "12")

      view
      |> element("#stats-filter-form")
      |> render_submit(%{"filters" => %{"pool_id" => second_pool.id, "window" => "24h"}})

      assert_patch(view, ~p"/admin/stats?pool_id=#{second_pool.id}&window=24h")

      assert has_element?(
               view,
               "#stats-pool-filter-control [data-role='pool-filter-trigger']",
               "Stats Sub Second"
             )

      assert has_element?(view, "#stats-kpi-tokens", "21")

      stats_usage_fixture(first_pool, %{total_tokens: 88, correlation_id: "stats-sub-first-late"})
      assert {:ok, _event} = Events.broadcast_usage(first_pool.id, "usage_updated", %{rows: 1})
      _ = :sys.get_state(view.pid)
      refute_reload_telemetry(:scheduled)
      refute has_element?(view, "#stats-traffic-chart", "100 tokens")

      stats_usage_fixture(second_pool, %{total_tokens: 9, correlation_id: "stats-sub-second-late"})

      assert {:ok, _event} = Events.broadcast_usage(second_pool.id, "usage_updated", %{rows: 1})
      assert_reload_telemetry(:scheduled, window: "24h", scope: "selected_pool")

      execute_scheduled_reload(view)
      assert_reload_telemetry(:executed, window: "24h", scope: "selected_pool")
      assert has_element?(view, "#stats-kpi-tokens", "30")
      assert has_element?(view, "#stats-traffic-chart", "30 tokens")
    end

    test "stale timer after filter patch reloads the latest selected scope", %{
      conn: conn,
      scope: scope
    } do
      {:ok, first_pool} =
        Pools.create_pool(scope, %{slug: "stats-stale-first", name: "Stats Stale First"})

      {:ok, second_pool} =
        Pools.create_pool(scope, %{slug: "stats-stale-second", name: "Stats Stale Second"})

      stats_usage_fixture(first_pool, %{total_tokens: 12, correlation_id: "stats-stale-first"})
      stats_usage_fixture(second_pool, %{total_tokens: 21, correlation_id: "stats-stale-second"})

      {:ok, view, _html} = live(conn, ~p"/admin/stats?pool_id=#{first_pool.id}&window=24h")

      assert has_element?(view, "#stats-kpi-tokens", "12")

      stats_usage_fixture(first_pool, %{
        total_tokens: 88,
        correlation_id: "stats-stale-first-late"
      })

      assert {:ok, _event} = Events.broadcast_usage(first_pool.id, "usage_updated", %{rows: 1})
      assert_reload_telemetry(:scheduled, window: "24h", scope: "selected_pool")

      view
      |> element("#stats-filter-form")
      |> render_submit(%{"filters" => %{"pool_id" => second_pool.id, "window" => "1h"}})

      assert_patch(view, ~p"/admin/stats?pool_id=#{second_pool.id}&window=1h")
      assert_reload_telemetry(:cancelled, window: "1h", scope: "selected_pool")
      assert has_element?(view, "#stats-pool-filter[value='#{second_pool.id}']")
      assert has_element?(view, "#stats-time-filter[value='1h']")
      assert has_element?(view, "#stats-kpi-tokens", "21")

      send(view.pid, :reload_stats_dashboard)
      assert_reload_telemetry(:executed, window: "1h", scope: "selected_pool")
      assert has_element?(view, "#stats-pool-filter[value='#{second_pool.id}']")
      assert has_element?(view, "#stats-time-filter[value='1h']")
      assert has_element?(view, "#stats-kpi-tokens", "21")
      refute has_element?(view, "#stats-traffic-chart", "100 tokens")
    end

    test "empty selected period shows operational no-data copy without fake trends", %{
      conn: conn,
      scope: scope
    } do
      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "stats-empty-live", name: "Stats Empty Live"})

      upstream_assignment_fixture(pool)

      {:ok, view, _html} = live(conn, ~p"/admin/stats?pool_id=#{pool.id}&window=1h")

      refute has_element?(view, "#stats-empty-states")
      assert has_element?(view, "#stats-kpi-requests", "0")
      assert has_element?(view, "#stats-kpi-success-rate", "not available")
      assert has_element?(view, "#stats-kpi-cost", "unavailable")
      assert has_element?(view, "#stats-traffic-chart", "0 requests")
      assert has_element?(view, "#stats-traffic-chart", "0 tokens")
    end

    test "free plan weekly-only quota is not rendered as consumed or exhausted", %{
      conn: conn,
      scope: scope
    } do
      {:ok, pool} = Pools.create_pool(scope, %{slug: "stats-free-live", name: "Stats Free Live"})
      %{identity: identity} = upstream_assignment_fixture(pool, %{plan_family: "free"})
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   active_limit: 100,
                   used_percent: Decimal.new(25),
                   reset_at: DateTime.add(now, 7, :day),
                   source: "codex_usage",
                   source_precision: "authoritative",
                   quota_scope: "account",
                   quota_family: "account"
                 }
               ])

      {:ok, view, _html} = live(conn, ~p"/admin/stats?pool_id=#{pool.id}&window=5h")

      assert has_element?(view, "#stats-kpi-quota-health", "Weekly evidence only")
      assert has_element?(view, "#stats-kpi-quota-health", "1 account with weekly evidence only")
      refute has_element?(view, "#stats-quota-table")
      refute has_element?(view, "#stats-quota-table", "Exhausted")
      refute has_element?(view, "#stats-kpi-quota-health", "0")
    end
  end

  defp assert_reload_telemetry(stage, expected) do
    assert_receive {:admin_stats_live_reload, %{count: 1}, metadata}
    assert metadata.stage == stage
    assert metadata.window in @telemetry_windows
    assert metadata.scope in @telemetry_scopes
    refute Map.has_key?(metadata, :pid)

    Enum.each(expected, fn {key, value} ->
      assert Map.fetch!(metadata, key) == value
    end)

    metadata
  end

  defp refute_reload_telemetry(stage) do
    refute_received {:admin_stats_live_reload, %{count: 1}, %{stage: ^stage}}
  end

  defp assert_build_telemetry(outcome, expected) do
    assert_receive {:admin_stats_dashboard_build, %{count: 1, duration: duration}, metadata}
    assert is_integer(duration)
    assert duration >= 0
    assert metadata.outcome == outcome
    assert metadata.window in @telemetry_windows
    assert metadata.scope in @telemetry_scopes

    Enum.each(expected, fn {key, value} ->
      assert Map.fetch!(metadata, key) == value
    end)

    if outcome == :ok do
      refute Map.has_key?(metadata, :error_code)
    end

    metadata
  end

  defp drain_build_telemetry do
    receive do
      {:admin_stats_dashboard_build, _measurements, _metadata} -> drain_build_telemetry()
    after
      0 -> :ok
    end
  end

  defp execute_scheduled_reload(view) do
    state = :sys.get_state(view.pid)
    timer = state.socket.assigns[:stats_reload_timer]

    if is_reference(timer) do
      Process.cancel_timer(timer, async: false, info: false)
    end

    send(view.pid, :reload_stats_dashboard)
  end

  defp required_selectors do
    ~w(
      #stats-pool-filter
      #stats-pool-filter-control
      #stats-time-filter
      #stats-time-filter-control
      #stats-kpi-requests
      #stats-kpi-success-rate
      #stats-kpi-tokens
      #stats-kpi-tokens-per-sec
      #stats-kpi-cost
      #stats-kpi-avg-latency
      #stats-kpi-active-sessions
      #stats-kpi-quota-health
      #stats-traffic-chart
    )
  end

  defp log_in_scoped_admin(conn, scope, assigned_pools) do
    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => unique_user_email(),
        "password_change_required" => "false"
      })

    Enum.each(assigned_pools, fn pool ->
      operator_pool_assignment_fixture(admin, pool, created_by_user_id: scope.user.id)
    end)

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    log_in_user(conn, admin, token)
  end

  defp stats_dashboard_fixture(pool, sensitive_marker) do
    %{api_key: api_key, raw_key: raw_key} =
      active_api_key_fixture(pool, %{display_name: "Stats UI key"})

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Stats upstream",
        assignment_label: "Stats assignment"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-stats-ui",
        correlation_id: "stats-live-success",
        request_metadata: %{
          "prompt" => "raw prompt #{sensitive_marker}",
          "authorization" => "Bearer #{sensitive_marker}",
          "safe_request" => "stats-safe"
        }
      })

    attempt =
      request
      |> attempt_fixture(assignment)
      |> Ecto.Changeset.change(%{latency_ms: 500})
      |> Repo.update!()

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      input_tokens: 60,
      output_tokens: 30,
      total_tokens: 100,
      estimated_cost_micros: 1_500_000,
      settled_cost_micros: 1_500_000,
      details: %{"body" => sensitive_marker}
    })
    |> Ecto.Changeset.change(%{cached_input_tokens: 10, reasoning_tokens: 10})
    |> Repo.update!()

    failed_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-stats-ui",
        status: "failed",
        correlation_id: "stats-live-failed",
        response_status_code: 429,
        last_error_code: "upstream_rate_limited"
      })

    failed_request
    |> attempt_fixture(assignment, %{status: "failed"})
    |> Ecto.Changeset.change(%{latency_ms: 1500})
    |> Repo.update!()

    session = insert_active_session!(pool, api_key, now)
    insert_turn!(session, request, now, %{status: "succeeded"})
    insert_daily_rollup!(pool, api_key, now)
    upsert_primary_5h!(identity, now)

    assert {:ok, _audit_event} =
             Audit.record_system_event(%{
               pool_id: pool.id,
               action: "operator.update",
               target_type: "pool",
               target_id: pool.id,
               outcome: "success",
               occurred_at: now,
               details: %{"authorization" => "Bearer #{sensitive_marker}"}
             })

    assert {:ok, _job} = Jobs.enqueue_account_reconciliation(pool, assignment)

    %{api_key: api_key, raw_key: raw_key, identity: identity, assignment: assignment}
  end

  defp stats_usage_fixture(pool, attrs) do
    %{api_key: api_key, raw_key: raw_key} =
      active_api_key_fixture(pool, %{
        display_name: Map.get(attrs, :api_key_display_name, "Stats usage key")
      })

    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        correlation_id: Map.get(attrs, :correlation_id, "stats-usage"),
        requested_model: "gpt-stats-filter"
      })

    attempt =
      request
      |> attempt_fixture(assignment)
      |> Ecto.Changeset.change(%{latency_ms: 100})
      |> Repo.update!()

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      total_tokens: Map.fetch!(attrs, :total_tokens),
      input_tokens: Map.fetch!(attrs, :total_tokens),
      output_tokens: 0,
      estimated_cost_micros: Map.get(attrs, :estimated_cost_micros, 0)
    })

    %{api_key: api_key, raw_key: raw_key, identity: identity, assignment: assignment}
  end

  defp insert_active_session!(pool, api_key, now) do
    %CodexSession{
      pool_id: pool.id,
      api_key_id: api_key.id,
      session_key: "stats-live-session-#{System.unique_integer([:positive])}",
      status: "active",
      owner_instance_id: "test-instance",
      owner_lease_token: Ecto.UUID.generate(),
      owner_lease_expires_at: DateTime.add(now, 60, :second),
      last_heartbeat_at: now,
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp insert_turn!(session, request, now, attrs) do
    %CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: Map.get(attrs, :turn_sequence, 1),
      transport_kind: request.transport,
      status: Map.get(attrs, :status, "in_progress"),
      started_at: now,
      completed_at: Map.get(attrs, :completed_at, now),
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp insert_daily_rollup!(pool, api_key, now) do
    %DailyRollup{
      rollup_date: DateTime.to_date(now),
      dimension_kind: "api_key",
      pool_id: pool.id,
      api_key_id: api_key.id,
      request_count: 1,
      success_count: 1,
      failure_count: 0,
      retry_count: 0,
      input_tokens: 60,
      cached_input_tokens: 10,
      output_tokens: 30,
      reasoning_tokens: 10,
      total_tokens: 100,
      estimated_cost_micros: Decimal.new(1_500_000),
      settled_cost_micros: Decimal.new(1_500_000),
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp upsert_primary_5h!(identity, now) do
    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 window_kind: "primary",
                 window_minutes: 300,
                 active_limit: 100,
                 used_percent: Decimal.new(10),
                 reset_at: DateTime.add(now, 5, :hour),
                 source: "codex_rate_limits",
                 source_precision: "authoritative",
                 quota_scope: "account",
                 quota_family: "account"
               }
             ])
  end
end
