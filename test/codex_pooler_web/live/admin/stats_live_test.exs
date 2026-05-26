defmodule CodexPoolerWeb.Admin.StatsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.DailyRollup
  alias CodexPooler.Audit
  alias CodexPooler.Events
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Jobs
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  test "redirects unauthenticated operators to login" do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/admin/stats")
  end

  describe "authenticated stats dashboard" do
    setup :register_and_log_in_user

    setup do
      test_pid = self()
      handler_id = {__MODULE__, test_pid, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:codex_pooler, :admin, :stats_live, :reload],
          fn _event, _measurements, metadata, _config ->
            send(test_pid, {:admin_stats_live, metadata.stage, metadata.pid})
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
      assert has_element?(view, "#stats-selected-scope", "Stats Live (stats-live)")
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
      assert has_element?(view, "#stats-upstream-table", "Available")
      refute has_element?(view, "#stats-recent-activity")
      assert has_element?(view, "#stats-quota-table", "10.0% used")
      assert has_element?(view, "#stats-quota-table", "routing usable")

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

      assert has_element?(view, "#stats-selected-scope", "Stats Filter First")
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
      assert has_element?(view, "#stats-selected-scope", "Stats Filter Second")
      assert has_element?(view, "#stats-time-filter[value='1h']")
      assert has_element?(view, "#stats-kpi-tokens", "27")
      assert has_element?(view, "#stats-traffic-chart", "27 tokens")
      refute has_element?(view, "#stats-traffic-chart", "11 tokens")
      refute render(view) =~ first.raw_key
      refute render(view) =~ second.raw_key
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

      assert has_element?(view, "#stats-selected-scope", "Stats Realtime Selected")
      assert has_element?(view, "#stats-kpi-tokens", "0")

      stats_usage_fixture(pool, %{total_tokens: 42, correlation_id: "stats-selected-realtime"})
      assert {:ok, _event} = Events.broadcast_usage(pool.id, "usage_updated", %{rows: 1})

      assert_receive {:admin_stats_live, :scheduled, _pid}
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#stats-kpi-tokens", "0")
      refute has_element?(view, "#stats-traffic-chart", "42 tokens")

      send(view.pid, :reload_stats_dashboard)
      assert_receive {:admin_stats_live, :reloaded, _pid}
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

      assert has_element?(view, "#stats-selected-scope", "Stats Ignore Selected")
      assert has_element?(view, "#stats-kpi-tokens", "11")

      other =
        stats_usage_fixture(other_pool, %{
          total_tokens: 77,
          correlation_id: "stats-ignore-other",
          api_key_display_name: "Other realtime key"
        })

      assert {:ok, _event} = Events.broadcast_usage(other_pool.id, "usage_updated", %{rows: 1})
      _ = :sys.get_state(view.pid)
      refute_received {:admin_stats_live, :scheduled, _pid}
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

      assert_receive {:admin_stats_live, :scheduled, _pid}
      _ = :sys.get_state(view.pid)
      refute_received {:admin_stats_live, :scheduled, _pid}
      assert has_element?(view, "#stats-kpi-tokens", "0")

      send(view.pid, :reload_stats_dashboard)
      assert_receive {:admin_stats_live, :reloaded, _pid}
      _ = :sys.get_state(view.pid)
      refute_received {:admin_stats_live, :reloaded, _pid}
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
      assert has_element?(view, "#stats-selected-scope", "Stats Sub First")
      assert has_element?(view, "#stats-kpi-tokens", "12")

      view
      |> element("#stats-filter-form")
      |> render_submit(%{"filters" => %{"pool_id" => second_pool.id, "window" => "24h"}})

      assert_patch(view, ~p"/admin/stats?pool_id=#{second_pool.id}&window=24h")
      assert has_element?(view, "#stats-selected-scope", "Stats Sub Second")
      assert has_element?(view, "#stats-kpi-tokens", "21")

      stats_usage_fixture(first_pool, %{total_tokens: 88, correlation_id: "stats-sub-first-late"})
      assert {:ok, _event} = Events.broadcast_usage(first_pool.id, "usage_updated", %{rows: 1})
      _ = :sys.get_state(view.pid)
      refute_received {:admin_stats_live, :scheduled, _pid}
      refute has_element?(view, "#stats-traffic-chart", "100 tokens")

      stats_usage_fixture(second_pool, %{total_tokens: 9, correlation_id: "stats-sub-second-late"})

      assert {:ok, _event} = Events.broadcast_usage(second_pool.id, "usage_updated", %{rows: 1})
      assert_receive {:admin_stats_live, :scheduled, _pid}

      send(view.pid, :reload_stats_dashboard)
      assert_receive {:admin_stats_live, :reloaded, _pid}
      assert has_element?(view, "#stats-kpi-tokens", "30")
      assert has_element?(view, "#stats-traffic-chart", "30 tokens")
    end

    test "empty selected period shows operational no-data copy without fake trends", %{
      conn: conn,
      scope: scope
    } do
      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "stats-empty-live", name: "Stats Empty Live"})

      upstream_assignment_fixture(pool)

      {:ok, view, _html} = live(conn, ~p"/admin/stats?pool_id=#{pool.id}&window=1h")

      assert has_element?(view, "#stats-empty-states", "No usage in this range")
      assert has_element?(view, "#stats-empty-states", "No requests in this range")

      assert has_element?(
               view,
               "#stats-empty-states",
               "No settled usage in this range"
             )

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
      assert has_element?(view, "#stats-quota-table", "Free")
      assert has_element?(view, "#stats-quota-table", "Weekly evidence only")
      assert has_element?(view, "#stats-quota-table", "5h quota not reported")
      assert has_element?(view, "#stats-quota-table", "25.0% used")
      refute has_element?(view, "#stats-quota-table", "0/5h")
      refute has_element?(view, "#stats-quota-table", "Not available on this plan")
      quota_html = view |> element("#stats-quota-table") |> render()
      refute quota_html =~ ~r/(^|[^0-9.])0%([^0-9]|$)/
      refute has_element?(view, "#stats-quota-table", "Exhausted")
      refute has_element?(view, "#stats-kpi-quota-health", "0")
    end
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
      #stats-quota-table
    )
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
