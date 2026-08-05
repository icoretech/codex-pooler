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
  alias CodexPoolerWeb.Admin.StatsPresentation
  alias CodexPoolerWeb.Admin.StatsPresentation.Charts, as: StatsCharts

  @reload_telemetry_event [:codex_pooler, :admin, :stats_live, :reload]
  @dashboard_build_telemetry_event [:codex_pooler, :admin, :stats, :dashboard, :build]
  @telemetry_windows ~w(1h 5h 24h 7d unknown)
  @telemetry_scopes ~w(selected_pool all_visible_pools unknown)

  test "leaderboard renders at most ten ranked API keys" do
    # Given
    rows =
      for index <- 1..11 do
        %{
          api_key_id: "api-key-#{index}",
          display_name: "Leaderboard key #{index}",
          pool_name: "Leaderboard pool",
          requests: index,
          total_tokens: index * 100,
          settled_cost_micros: index * 1_000
        }
      end

    # When
    html =
      render_component(&StatsPresentation.top_api_keys_table/1, %{
        rows: rows,
        sort: :tokens,
        window_label: "Last 24 hours"
      })

    fragment = LazyHTML.from_fragment(html)

    # Then
    assert fragment
           |> LazyHTML.query("[data-role='leaderboard-podium-place']")
           |> Enum.count() == 3

    assert fragment
           |> LazyHTML.query("[data-role='leaderboard-runner-row']")
           |> Enum.count() == 7

    assert html =~ "Leaderboard key 2"
    refute html =~ "Leaderboard key 1<"
  end

  test "redirects unauthenticated operators to login" do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/admin/stats")
  end

  test "traffic chart presentation merges model columns with the requests line" do
    # Given
    buckets = [
      "2026-01-10T12:00:00Z",
      "2026-01-10T13:00:00Z",
      "2026-01-10T14:00:00Z"
    ]

    assigns = %{
      requests: Enum.map(buckets, &%{bucket: &1, requests: 1}),
      tokens:
        Enum.map(buckets, fn bucket ->
          %{
            bucket: bucket,
            uncached_input_tokens: 7,
            cached_input_tokens: 1,
            output_tokens: 3,
            reasoning_tokens: 2,
            total_tokens: 13
          }
        end),
      costs: Enum.map(buckets, &%{bucket: &1, settled_cost_micros: 0}),
      model_usage: [
        %{bucket: Enum.at(buckets, 0), model_code: "model-a", total_tokens: 5},
        %{bucket: Enum.at(buckets, 1), model_code: "model-a", total_tokens: 7},
        %{bucket: Enum.at(buckets, 2), model_code: "model-a", total_tokens: 9},
        %{bucket: Enum.at(buckets, 0), model_code: "model-b", total_tokens: 0},
        %{bucket: Enum.at(buckets, 1), model_code: "model-b", total_tokens: 15},
        %{bucket: Enum.at(buckets, 2), model_code: "model-b", total_tokens: 0},
        %{bucket: Enum.at(buckets, 0), model_code: "Other", total_tokens: 0},
        %{bucket: Enum.at(buckets, 1), model_code: "Other", total_tokens: 0},
        %{bucket: Enum.at(buckets, 2), model_code: "Other", total_tokens: 24}
      ]
    }

    # When
    html = render_component(&StatsCharts.traffic_charts/1, assigns)

    # Then
    traffic_series =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#stats-traffic-chart-plot")
      |> LazyHTML.attribute("data-chart-series")
      |> List.first()
      |> Jason.decode!()

    assert Enum.map(traffic_series, & &1["name"]) == [
             "model-a",
             "model-b",
             "Other",
             "Requests"
           ]

    assert Enum.map(traffic_series, & &1["data"]) == [
             [5, 7, 9],
             [0, 15, 0],
             [0, 0, 24],
             [1, 1, 1]
           ]

    assert Enum.map(traffic_series, & &1["type"]) == ["column", "column", "column", "line"]
    assert html =~ "60 tokens / 3 requests"
    refute html =~ "39 tokens / 3 requests"

    assert component_chart_json_attribute(html, "data-chart-units") == [
             "tokens",
             "tokens",
             "tokens",
             "requests"
           ]

    assert component_chart_json_attribute(html, "data-chart-yaxis") == [
             %{
               "seriesName" => ["model-a", "model-b", "Other"],
               "title" => "tokens",
               "valueKind" => "tokens"
             },
             %{
               "seriesName" => "Requests",
               "title" => "requests",
               "opposite" => true,
               "valueKind" => "integer"
             }
           ]

    fragment = LazyHTML.from_fragment(html)

    assert fragment
           |> LazyHTML.query("#stats-traffic-charts > section")
           |> Enum.count() == 2

    assert fragment
           |> LazyHTML.query(
             "#stats-traffic-chart-plot[data-chart-stacked='true'][data-chart-bar-radius='0'][data-chart-zoom='false'][data-chart-legend='always'][data-chart-safe-tooltip='true']"
           )
           |> Enum.count() == 1

    assert fragment
           |> LazyHTML.query(
             "#stats-token-cost-chart-plot[data-chart-bar-radius='0'][data-chart-zoom='false']"
           )
           |> Enum.count() == 1

    for selector <- [
          "#stats-traffic-chart [data-role='chart-heading-group'] > #stats-traffic-chart-heading + #stats-traffic-chart-total",
          "#stats-token-cost-chart [data-role='chart-heading-group'] > #stats-token-cost-chart-heading + #stats-token-cost-chart-total",
          "#stats-traffic-chart header > [data-role='chart-heading-group'] + #stats-traffic-chart-mode-control:last-child",
          "#stats-token-cost-chart header > [data-role='chart-heading-group'] + #stats-token-cost-chart-mode-control:last-child",
          "#stats-traffic-chart-mode-control[role='group'][aria-label='Traffic chart mode']",
          "#stats-token-cost-chart-mode-control[role='group'][aria-label='Tokens vs cost chart mode']",
          "#stats-traffic-chart-mode-interval[aria-controls='stats-traffic-chart-plot'][aria-pressed='true']",
          "#stats-traffic-chart-mode-cumulative[aria-controls='stats-traffic-chart-plot'][aria-pressed='false']",
          "#stats-token-cost-chart-mode-interval[aria-controls='stats-token-cost-chart-plot'][aria-pressed='true']",
          "#stats-token-cost-chart-mode-cumulative[aria-controls='stats-token-cost-chart-plot'][aria-pressed='false']",
          "#stats-traffic-chart-plot[aria-describedby~='stats-traffic-chart-mode-description']",
          "#stats-token-cost-chart-plot[aria-describedby~='stats-token-cost-chart-mode-description']",
          "#stats-traffic-chart-interval-values[data-chart-source='interval']",
          "#stats-token-cost-chart-interval-values[data-chart-source='interval']"
        ] do
      assert fragment |> LazyHTML.query(selector) |> Enum.count() == 1
    end

    assert fragment
           |> LazyHTML.query("[id^='stats-model-usage-chart']")
           |> Enum.empty?()

    assert [click_command] =
             fragment
             |> LazyHTML.query("#stats-traffic-chart-mode-cumulative")
             |> LazyHTML.attribute("phx-click")

    assert click_command =~ "dispatch"
    refute click_command =~ "push"
  end

  test "traffic chart presentation falls back to settlement tokens for all-zero model data" do
    # Given
    bucket = "2026-01-10T12:00:00Z"

    assigns = %{
      requests: [%{bucket: bucket, requests: 2}],
      tokens: [
        %{
          bucket: bucket,
          uncached_input_tokens: 7,
          cached_input_tokens: 1,
          output_tokens: 3,
          reasoning_tokens: 2,
          total_tokens: 13
        }
      ],
      costs: [%{bucket: bucket, settled_cost_micros: 0}],
      model_usage: [%{bucket: bucket, model_code: "gpt-zero", total_tokens: 0}]
    }

    # When
    html = render_component(&StatsCharts.traffic_charts/1, assigns)

    # Then
    traffic_series = component_chart_json_attribute(html, "data-chart-series")

    assert Enum.map(traffic_series, & &1["name"]) == ["Tokens", "Requests"]
    assert Enum.map(traffic_series, & &1["data"]) == [[13], [2]]
    refute html =~ "gpt-zero"
  end

  test "traffic chart presentation keeps an empty fallback payload composed" do
    # Given
    assigns = %{requests: [], tokens: [], costs: [], model_usage: []}

    # When
    html = render_component(&StatsCharts.traffic_charts/1, assigns)

    # Then
    traffic_series = component_chart_json_attribute(html, "data-chart-series")

    assert traffic_series == [
             %{"name" => "Tokens", "type" => "column", "data" => []},
             %{"name" => "Requests", "type" => "line", "data" => []}
           ]

    refute html =~ "stats-model-usage-chart"
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

      {:ok, view, _html} = live_stats(conn, ~p"/admin/stats?pool_id=#{pool.id}&window=24h")

      for selector <- required_selectors() do
        assert has_element?(view, selector)
      end

      assert has_element?(view, "#admin-nav-stats[aria-current='page']")
      assert has_element?(view, "#stats-page-header", "Usage")

      assert has_element?(
               view,
               "#stats-page-header",
               "Tokens, spend, latency, and cache activity"
             )

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
      assert has_element?(view, "#stats-filter-form[phx-hook='AdminFilterDropdowns']")
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
      assert has_element?(view, "#stats-kpi-tokens", "Input and output combined")
      refute has_element?(view, "#stats-kpi-tokens [data-role='token-summary']")

      assert has_element?(view, "#stats-kpi-tokens-per-sec", "50.0")
      assert has_element?(view, "#stats-kpi-tokens-per-sec", "Throughput")
      assert has_element?(view, "#stats-kpi-cost", "$0.75")
      assert has_element?(view, "#stats-kpi-avg-latency", "1000 ms")
      assert has_element?(view, "#stats-kpi-avg-latency", "Mean response time")
      assert has_element?(view, "#stats-kpi-active-sessions", "1")
      assert has_element?(view, "#stats-kpi-active-sessions", "1 turns")
      assert has_element?(view, "#stats-kpi-cache-rate", "Cache rate")
      assert has_element?(view, "#stats-kpi-cache-rate", "16.7%")
      assert has_element?(view, "#stats-kpi-cache-rate", "10 of 60 input cached")
      refute has_element?(view, "#stats-kpi-quota-health")
      assert has_element?(view, "#stats-traffic-chart-scroll[data-role='chart-scroll-region']")
      assert has_element?(view, "#stats-traffic-chart-scroll.overflow-x-auto")
      assert has_element?(view, "#stats-traffic-chart-plot.admin-chart-mobile-wide")
      assert has_element?(view, "#stats-traffic-chart-plot[phx-hook='ApexTimeSeriesChart']")
      assert has_element?(view, "#stats-traffic-chart-plot[phx-update='ignore']")
      assert has_element?(view, "#stats-traffic-chart-plot[data-chart-unit='tokens']")
      assert has_element?(view, "#stats-traffic-chart-plot[data-chart-units]")
      assert has_element?(view, "#stats-traffic-chart-plot[data-chart-yaxis]")

      assert has_element?(
               view,
               "#stats-traffic-chart-plot[data-chart-legend='always'][data-chart-safe-tooltip='true'][data-chart-stacked='true'][data-chart-bar-radius='0'][data-chart-zoom='false']"
             )

      assert has_element?(view, "#stats-traffic-chart", "Traffic over time")
      assert has_element?(view, "#stats-traffic-chart", "100 tokens / 2 requests")
      assert has_element?(view, "#stats-traffic-chart-mode-control[role='group']")

      assert has_element?(
               view,
               "#stats-traffic-chart-interval-values[data-chart-source='interval']"
             )

      refute has_element?(view, "#stats-traffic-chart-summary")
      refute has_element?(view, "#stats-traffic-chart-total.font-mono")
      refute has_element?(view, "#stats-traffic-chart-plot svg")
      assert has_element?(view, "#stats-token-cost-chart", "Tokens vs cost")
      assert has_element?(view, "#stats-token-cost-chart", "100 tokens / $0.75")
      assert has_element?(view, "#stats-token-cost-chart-scroll[data-role='chart-scroll-region']")
      assert has_element?(view, "#stats-token-cost-chart-scroll.overflow-x-auto")
      assert has_element?(view, "#stats-token-cost-chart-plot.admin-chart-mobile-wide")
      assert has_element?(view, "#stats-token-cost-chart-plot[phx-hook='ApexTimeSeriesChart']")
      assert has_element?(view, "#stats-token-cost-chart-plot[phx-update='ignore']")
      assert has_element?(view, "#stats-token-cost-chart-plot[data-chart-stacked='true']")
      assert has_element?(view, "#stats-token-cost-chart-plot[data-chart-legend='true']")
      assert has_element?(view, "#stats-token-cost-chart-plot[data-chart-bar-radius='0']")
      assert has_element?(view, "#stats-token-cost-chart-plot[data-chart-value-kinds]")
      assert has_element?(view, "#stats-token-cost-chart-plot[data-chart-yaxis]")
      assert has_element?(view, "#stats-token-cost-chart-plot[data-chart-zoom='false']")
      assert has_element?(view, "#stats-token-cost-chart-mode-control[role='group']")

      assert has_element?(
               view,
               "#stats-token-cost-chart-interval-values[data-chart-source='interval']"
             )

      refute has_element?(view, "#stats-token-chart")
      refute has_element?(view, "[id^='stats-model-usage-chart']")

      assert has_element?(
               view,
               "#stats-api-key-surface > header p",
               "Top API keys by token usage"
             )

      refute has_element?(view, "#stats-api-key-surface > header > span")
      assert has_element?(view, "#stats-api-key-surface", "Leaderboard")
      assert has_element?(view, "#stats-api-key-podium-1", "Stats UI key")
      assert has_element?(view, "#stats-api-key-podium-1", "Stats Live")
      refute has_element?(view, "#stats-api-key-podium-1", "stats-live")
      assert has_element?(view, "#stats-api-key-podium-1", "$0.75")
      assert has_element?(view, "#stats-api-key-podium-1 .hero-trophy")
      refute has_element?(view, "#stats-api-key-podium-2")
      refute has_element?(view, "#stats-api-key-runners")
      assert has_element?(view, "#stats-api-key-sort-tokens[aria-pressed='true']")
      refute has_element?(view, "#stats-api-key-sort-cost[aria-pressed='true']")

      view |> element("#stats-api-key-sort-cost") |> render_click()

      assert has_element?(
               view,
               "#stats-api-key-surface > header p",
               "Top API keys by settled cost"
             )

      assert has_element?(view, "#stats-api-key-sort-cost[aria-pressed='true']")
      refute has_element?(view, "#stats-api-key-sort-tokens[aria-pressed='true']")
      assert has_element?(view, "#stats-api-key-podium-1", "$0.75")

      view |> element("#stats-api-key-sort-tokens") |> render_click()

      assert has_element?(
               view,
               "#stats-api-key-surface > header p",
               "Top API keys by token usage"
             )

      assert has_element?(view, "#stats-upstream-surface", "Traffic distribution")

      assert has_element?(
               view,
               "#stats-upstream-surface > header p",
               "Share of accounted requests across Stats Live in the last 24 hours."
             )

      refute has_element?(view, "#stats-upstream-surface > header > span")

      upstream_surface_html = view |> element("#stats-upstream-surface") |> render()
      upstream_surface = LazyHTML.from_fragment(upstream_surface_html)

      assert upstream_surface |> LazyHTML.query("ol#stats-upstream-lanes") |> Enum.count() == 1

      assert upstream_surface
             |> LazyHTML.query("[data-role='upstream-traffic-lane']")
             |> Enum.count() == 1

      assert has_element?(
               view,
               "#stats-upstream-lane-1[data-role='upstream-traffic-lane'][data-leader='true']",
               "Stats assignment"
             )

      assert has_element?(
               view,
               "#stats-upstream-lane-1 [data-role='upstream-traffic-share']",
               "100.0%"
             )

      assert has_element?(
               view,
               "#stats-upstream-rail-1[data-role='upstream-traffic-rail'][max='100'][value='100.0'][aria-label='Stats assignment traffic share']"
             )

      assert has_element?(view, "#stats-upstream-lane-1 [data-role='upstream-requests']", "1")
      assert has_element?(view, "#stats-upstream-lane-1 [data-role='upstream-tokens']", "100")

      assert has_element?(
               view,
               "#stats-upstream-lane-1 [data-role='upstream-settled-cost']",
               "$0.75"
             )

      refute has_element?(view, "#stats-upstream-surface table")
      refute has_element?(view, "#stats-upstream-surface article")
      refute has_element?(view, "#stats-upstream-surface .badge")
      refute has_element?(view, "#stats-upstream-surface .overflow-x-auto")
      refute has_element?(view, "[id^='stats-upstream-card-']")
      refute has_element?(view, "[id^='stats-upstream-row-']")
      refute has_element?(view, "#stats-upstream-surface", "active")
      refute has_element?(view, "#stats-upstream-surface", "Quota")
      refute has_element?(view, "#stats-recent-activity")
      refute has_element?(view, "#stats-quota-table")

      refute has_element?(view, "#stats-api-key-surface", other_setup.api_key.display_name)
      refute has_element?(view, "#stats-traffic-chart", "33 tokens")

      traffic_chart_html = view |> element("#stats-traffic-chart-plot") |> render()
      traffic_series = chart_json_attribute(traffic_chart_html, "data-chart-series")

      assert traffic_chart_html =~ "ApexTimeSeriesChart"
      assert Enum.map(traffic_series, & &1["name"]) == ["Tokens", "Requests"]
      assert Enum.map(traffic_series, & &1["type"]) == ["column", "line"]

      assert chart_json_attribute(traffic_chart_html, "data-chart-units") == [
               "tokens",
               "requests"
             ]

      assert chart_json_attribute(traffic_chart_html, "data-chart-yaxis") == [
               %{"seriesName" => "Tokens", "title" => "tokens", "valueKind" => "tokens"},
               %{
                 "seriesName" => "Requests",
                 "title" => "requests",
                 "opposite" => true,
                 "valueKind" => "integer"
               }
             ]

      token_cost_chart_html = view |> element("#stats-token-cost-chart-plot") |> render()

      assert token_cost_chart_html =~ "Cached input"
      assert token_cost_chart_html =~ "Cost"
      assert token_cost_chart_html =~ "data-chart-stacked=\"true\""
      assert token_cost_chart_html =~ "&quot;usd&quot;"

      html = render(view)
      refute html =~ sensitive_marker
      refute html =~ setup.raw_key
      refute html =~ "Bearer #{sensitive_marker}"
      refute html =~ "raw prompt #{sensitive_marker}"
    end

    test "merges model usage into traffic with independent accessible chart controls", %{
      conn: conn,
      scope: scope
    } do
      # Given
      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "stats-chart-baseline", name: "Stats Chart Baseline"})

      model =
        model_fixture(pool, %{
          exposed_model_id: "gpt-chart-baseline",
          display_name: "Chart Baseline Model"
        })

      as_of = ~U[2026-01-10 12:00:00.000000Z]

      stats_model_usage_fixture(pool, model, %{
        sensitive_marker: "chart-baseline-secret-do-not-render",
        as_of: as_of,
        total_tokens: 13,
        input_tokens: 8,
        cached_input_tokens: 1,
        output_tokens: 3,
        reasoning_tokens: 2
      })

      # When
      {:ok, view, _html} =
        live_stats(
          conn,
          ~p"/admin/stats?pool_id=#{pool.id}&window=1h&as_of=#{DateTime.to_iso8601(as_of)}"
        )

      # Then
      traffic_series =
        view
        |> element("#stats-traffic-chart-plot")
        |> render()
        |> chart_json_attribute("data-chart-series")

      assert Enum.map(traffic_series, & &1["name"]) == ["gpt-chart-baseline", "Requests"]
      assert Enum.map(traffic_series, & &1["type"]) == ["column", "line"]
      assert traffic_series |> hd() |> Map.fetch!("data") |> Enum.sum() == 13
      assert traffic_series |> List.last() |> Map.fetch!("data") |> Enum.sum() == 1

      assert has_element?(
               view,
               "#stats-traffic-chart-plot[data-chart-stacked='true'][data-chart-legend='always'][data-chart-safe-tooltip='true'][data-chart-zoom='false'][data-chart-bar-radius='0']"
             )

      assert has_element?(
               view,
               "#stats-token-cost-chart-plot[data-chart-zoom='false'][data-chart-bar-radius='0']"
             )

      assert has_element?(
               view,
               "#stats-traffic-chart [data-role='chart-heading-group'] > #stats-traffic-chart-heading + #stats-traffic-chart-total",
               "13 tokens / 1 requests"
             )

      assert has_element?(
               view,
               "#stats-token-cost-chart [data-role='chart-heading-group'] > #stats-token-cost-chart-heading + #stats-token-cost-chart-total"
             )

      assert has_element?(
               view,
               "#stats-traffic-chart-mode-control[role='group'][aria-label='Traffic chart mode']"
             )

      assert has_element?(
               view,
               "#stats-traffic-chart-mode-interval[type='button'][phx-click][data-chart-mode='interval'][aria-controls='stats-traffic-chart-plot'][aria-pressed='true']:not([phx-keydown])"
             )

      assert has_element?(
               view,
               "#stats-traffic-chart-mode-cumulative[type='button'][phx-click][data-chart-mode='cumulative'][aria-controls='stats-traffic-chart-plot'][aria-pressed='false']:not([phx-keydown])"
             )

      assert has_element?(
               view,
               "#stats-token-cost-chart-mode-control[role='group'][aria-label='Tokens vs cost chart mode']"
             )

      assert has_element?(
               view,
               "#stats-token-cost-chart-mode-interval[type='button'][phx-click][data-chart-mode='interval'][aria-controls='stats-token-cost-chart-plot'][aria-pressed='true']:not([phx-keydown])"
             )

      assert has_element?(
               view,
               "#stats-token-cost-chart-mode-cumulative[type='button'][phx-click][data-chart-mode='cumulative'][aria-controls='stats-token-cost-chart-plot'][aria-pressed='false']:not([phx-keydown])"
             )

      assert has_element?(
               view,
               "#stats-traffic-chart header > [data-role='chart-heading-group'] + #stats-traffic-chart-mode-control:last-child"
             )

      assert has_element?(
               view,
               "#stats-token-cost-chart header > [data-role='chart-heading-group'] + #stats-token-cost-chart-mode-control:last-child"
             )

      assert has_element?(view, "#stats-traffic-chart-mode-description", "interval")
      assert has_element?(view, "#stats-token-cost-chart-mode-description", "interval")

      assert has_element?(
               view,
               "#stats-traffic-chart-interval-values[data-chart-source='interval']"
             )

      assert has_element?(
               view,
               "#stats-token-cost-chart-interval-values[data-chart-source='interval']"
             )

      refute has_element?(view, "[id^='stats-model-usage-chart']")
    end

    test "renders ranked model traffic in the merged sanitized hook payload", %{
      conn: conn,
      scope: scope
    } do
      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "stats-model-usage-live", name: "Stats Model Usage"})

      sensitive_marker = "model-usage-secret-do-not-render"

      safe_model =
        model_fixture(pool, %{
          exposed_model_id: "gpt-5.5",
          display_name: "Model Usage Display Name #{sensitive_marker}"
        })

      unsafe_model_code = "gpt-<img src=x onerror=alert(1)>"
      escaped_unsafe_model_code = "gpt-&lt;img src=x onerror=alert(1)&gt;"

      unsafe_model =
        model_fixture(pool, %{
          exposed_model_id: unsafe_model_code,
          display_name: "Unsafe Model Usage Display Name #{sensitive_marker}"
        })

      as_of = ~U[2026-01-10 12:00:00.000000Z]
      as_of_iso = DateTime.to_iso8601(as_of)

      setup =
        stats_model_usage_fixture(pool, safe_model, %{
          sensitive_marker: sensitive_marker,
          as_of: as_of,
          total_tokens: 123,
          input_tokens: 80,
          cached_input_tokens: 10,
          output_tokens: 30,
          reasoning_tokens: 13
        })

      stats_model_usage_fixture(pool, unsafe_model, %{
        sensitive_marker: sensitive_marker,
        as_of: as_of,
        correlation_id: "stats-model-usage-live-unsafe",
        total_tokens: 110,
        input_tokens: 70,
        cached_input_tokens: 10,
        output_tokens: 20,
        reasoning_tokens: 20
      })

      for {model_code, total_tokens} <- [
            {"gpt-ranked-3", 100},
            {"gpt-ranked-4", 90},
            {"gpt-ranked-5", 80},
            {"gpt-ranked-6", 70},
            {"gpt-ranked-7", 60}
          ] do
        model =
          model_fixture(pool, %{
            exposed_model_id: model_code,
            display_name: "Ranked Model Display Name #{sensitive_marker}"
          })

        insert_hourly_model_usage_rollup!(pool, model, truncate_to_hour(as_of), %{
          total_tokens: total_tokens,
          input_tokens: total_tokens,
          cached_input_tokens: 0,
          output_tokens: 0,
          reasoning_tokens: 0
        })
      end

      {:ok, view, _html} =
        live_stats(conn, ~p"/admin/stats?pool_id=#{pool.id}&window=1h&as_of=#{as_of_iso}")

      assert has_element?(
               view,
               "#stats-traffic-chart-plot[data-chart-legend='always'][data-chart-safe-tooltip='true'][data-chart-stacked='true'][data-chart-bar-radius='0']"
             )

      assert has_element?(view, "#stats-traffic-chart", "633 tokens / 2 requests")
      refute has_element?(view, "[id^='stats-model-usage-chart']")

      chart_html = view |> element("#stats-traffic-chart-plot") |> render()
      series = chart_json_attribute(chart_html, "data-chart-series")
      units = chart_json_attribute(chart_html, "data-chart-units")
      value_kinds = chart_json_attribute(chart_html, "data-chart-value-kinds")
      yaxis = chart_json_attribute(chart_html, "data-chart-yaxis")
      series_names = Enum.map(series, & &1["name"])
      model_series_names = Enum.drop(series_names, -1)

      assert series_names == [
               "gpt-5.5",
               escaped_unsafe_model_code,
               "gpt-ranked-3",
               "gpt-ranked-4",
               "gpt-ranked-5",
               "Other",
               "Requests"
             ]

      assert Enum.map(series, & &1["type"]) ==
               List.duplicate("column", 6) ++ ["line"]

      assert units == List.duplicate("tokens", 6) ++ ["requests"]
      assert value_kinds == List.duplicate("tokens", 6) ++ ["integer"]
      assert series |> Enum.at(5) |> Map.fetch!("data") |> Enum.sum() == 130
      assert series |> List.last() |> Map.fetch!("data") |> Enum.sum() == 2

      assert [
               %{
                 "seriesName" => ^model_series_names,
                 "title" => "tokens",
                 "valueKind" => "tokens"
               },
               %{
                 "seriesName" => "Requests",
                 "title" => "requests",
                 "opposite" => true,
                 "valueKind" => "integer"
               }
             ] = yaxis

      refute unsafe_model_code in series_names
      assert chart_html =~ "gpt-5.5"
      assert chart_html =~ "&amp;lt;img src=x onerror=alert(1)&amp;gt;"
      refute chart_html =~ "<img src=x onerror=alert(1)>"
      refute chart_html =~ "Model Usage Display Name"
      refute chart_html =~ "Unsafe Model Usage Display Name"
      refute chart_html =~ "Ranked Model Display Name"
      refute chart_html =~ sensitive_marker

      html = render(view)
      refute html =~ unsafe_model_code
      refute html =~ "<img src=x onerror=alert(1)>"
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

      {:ok, view, _html} =
        live_stats(conn, ~p"/admin/stats?pool_id=#{first_pool.id}&window=24h")

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

      _ =
        await_stats_dashboard_params(view, %{
          "pool_id" => second_pool.id,
          "window" => "24h"
        })

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

      _ =
        await_stats_dashboard_params(view, %{
          "pool_id" => second_pool.id,
          "window" => "1h"
        })

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

      {:ok, view, _html} = live_stats(admin_conn, ~p"/admin/stats?window=24h")

      assert has_element?(view, "#stats-pool-filter[type='hidden'][value='']")
      assert has_element?(view, "#stats-pool-filter-control", "All Pools")
      assert has_element?(view, "#stats-pool-filter-control button[data-pool-id='#{pool_a.id}']")
      assert has_element?(view, "#stats-pool-filter-control button[data-pool-id='#{pool_b.id}']")
      refute has_element?(view, "#stats-pool-filter-control button[data-pool-id='#{pool_c.id}']")
      refute has_element?(view, "#stats-pool-filter-control", "Stats Scope C")

      assert has_element?(view, "#stats-kpi-requests", "2")
      assert has_element?(view, "#stats-kpi-tokens", "30")
      assert has_element?(view, "#stats-kpi-cache-rate", "0.0%")
      assert has_element?(view, "#stats-kpi-cache-rate", "No cached input")
      assert has_element?(view, "#stats-traffic-chart", "30 tokens")
      assert has_element?(view, "#stats-api-key-surface", "Scoped A key")
      assert has_element?(view, "#stats-api-key-surface", "Scoped B key")
      refute has_element?(view, "#stats-api-key-surface", "Hidden C key")

      assert has_element?(
               view,
               "#stats-upstream-surface > header p",
               "Share of accounted requests across all visible pools in the last 24 hours."
             )

      all_pool_surface =
        view
        |> element("#stats-upstream-surface")
        |> render()
        |> LazyHTML.from_fragment()

      assert all_pool_surface
             |> LazyHTML.query("#stats-upstream-lanes")
             |> Enum.count() == 1

      assert all_pool_surface
             |> LazyHTML.query("[data-role='upstream-traffic-lane']")
             |> Enum.count() == 2

      assert has_element?(
               view,
               "#stats-upstream-lane-1[data-leader='true'] [data-role='upstream-traffic-share']",
               "50.0%"
             )

      assert has_element?(view, "#stats-upstream-lane-1 [data-role='upstream-tokens']", "20")

      assert has_element?(
               view,
               "#stats-upstream-lane-2 [data-role='upstream-traffic-share']",
               "50.0%"
             )

      assert has_element?(view, "#stats-upstream-lane-2 [data-role='upstream-tokens']", "10")
      refute has_element?(view, "#stats-upstream-lane-2[data-leader='true']")

      view
      |> element("#stats-pool-filter-control button[data-pool-id='#{pool_b.id}']")
      |> render_click()

      assert_patch(view, ~p"/admin/stats?pool_id=#{pool_b.id}&window=24h")

      _ =
        await_stats_dashboard_params(view, %{"pool_id" => pool_b.id, "window" => "24h"})

      assert has_element?(view, "#stats-pool-filter[value='#{pool_b.id}']")
      assert has_element?(view, "#stats-kpi-tokens", "20")
      assert has_element?(view, "#stats-kpi-cache-rate", "0.0%")
      assert has_element?(view, "#stats-kpi-cache-rate", "No cached input")
      assert has_element?(view, "#stats-api-key-surface", "Scoped B key")
      refute has_element?(view, "#stats-api-key-surface", "Scoped A key")
      refute has_element?(view, "#stats-api-key-surface", "Hidden C key")

      assert has_element?(
               view,
               "#stats-upstream-surface > header p",
               "Share of accounted requests across Stats Scope B in the last 24 hours."
             )

      selected_pool_surface =
        view
        |> element("#stats-upstream-surface")
        |> render()
        |> LazyHTML.from_fragment()

      assert selected_pool_surface
             |> LazyHTML.query("[data-role='upstream-traffic-lane']")
             |> Enum.count() == 1

      assert has_element?(
               view,
               "#stats-upstream-lane-1[data-leader='true'] [data-role='upstream-traffic-share']",
               "100.0%"
             )

      assert has_element?(view, "#stats-upstream-lane-1 [data-role='upstream-tokens']", "20")
      refute render(view) =~ assigned_a.raw_key
      refute render(view) =~ assigned_b.raw_key
      refute render(view) =~ hidden_c.raw_key

      {:ok, blocked_view, _html} =
        live_stats(admin_conn, ~p"/admin/stats?pool_id=#{pool_c.id}&window=24h")

      assert has_element?(blocked_view, "#stats-filter-error", "pool filter is not available")
      refute has_element?(blocked_view, "#stats-kpis")
      refute has_element?(blocked_view, "#stats-pool-filter-control", "Stats Scope C")
      refute has_element?(blocked_view, "#stats-api-key-surface", "Hidden C key")
      refute render(blocked_view) =~ hidden_c.raw_key
    end

    test "monthly quota evidence stays out of the neutral cache-rate KPI", %{
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

      {:ok, view, _html} = live_stats(conn, ~p"/admin/stats?pool_id=#{pool.id}&window=5h")

      assert has_element?(view, "#stats-kpi-cache-rate", "not available")
      assert has_element?(view, "#stats-kpi-cache-rate", "No input tokens")
      refute has_element?(view, "#stats-kpi-quota-health")
      refute has_element?(view, "#stats-kpis", "Missing evidence")
      refute has_element?(view, "#stats-kpis", "1 usable")
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

      {:ok, view, _html} = live_stats(admin_conn, ~p"/admin/stats?window=24h")

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
      assert has_element?(view, "#stats-kpi-cache-rate", "not available")
      assert has_element?(view, "#stats-kpi-cache-rate", "No input tokens")
      assert has_element?(view, "#stats-traffic-chart", "0 tokens / 0 requests")
      assert has_element?(view, "#stats-token-cost-chart", "0 tokens / $0.00")
      refute has_element?(view, "#stats-api-key-surface", "Unassigned hidden key")
      assert has_element?(view, "#stats-upstream-empty-state", "No upstream identities")
      refute has_element?(view, "#stats-upstream-lanes")
      refute has_element?(view, "[data-role='upstream-traffic-lane']")

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

      {:ok, _view, _html} = live_stats(conn, ~p"/admin/stats?window=7d")

      assert_build_telemetry(:ok, window: "7d", scope: "all_visible_pools")
      drain_build_telemetry()

      admin_conn = log_in_scoped_admin(conn, scope, [])

      {:ok, blocked_view, _html} =
        live_stats(admin_conn, ~p"/admin/stats?pool_id=#{pool.id}&window=5h")

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

    test "filter generation replaces a blocked event reload without querying on the LiveView", %{
      conn: conn,
      scope: scope
    } do
      {:ok, first_pool} =
        Pools.create_pool(scope, %{slug: "stats-async-first", name: "Stats Async First"})

      {:ok, second_pool} =
        Pools.create_pool(scope, %{slug: "stats-async-second", name: "Stats Async Second"})

      stats_usage_fixture(first_pool, %{total_tokens: 12, correlation_id: "stats-async-first"})
      stats_usage_fixture(second_pool, %{total_tokens: 21, correlation_id: "stats-async-second"})

      {:ok, view, _html} =
        live_stats(conn, ~p"/admin/stats?pool_id=#{first_pool.id}&window=24h")

      stats_usage_fixture(first_pool, %{
        total_tokens: 88,
        correlation_id: "stats-async-first-late"
      })

      handler_id = {__MODULE__, :blocked_stats_query, make_ref()}
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:codex_pooler, :repo, :query],
          fn _event, _measurements, metadata, _config ->
            if metadata[:repo] == Repo and self() != view.pid and
                 normalize_repo_query_value(metadata[:source]) == "requests" do
              send(test_pid, {handler_id, self()})

              receive do
                {^handler_id, :release} -> :ok
              after
                5_000 -> :ok
              end
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _event} = Events.broadcast_usage(first_pool.id, "usage_updated", %{rows: 1})
      execute_scheduled_reload(view, await?: false)

      assert_receive {^handler_id, dashboard_task_pid}

      view
      |> element("#stats-filter-form")
      |> render_submit(%{"filters" => %{"pool_id" => second_pool.id, "window" => "1h"}})

      assert_patch(view, ~p"/admin/stats?pool_id=#{second_pool.id}&window=1h")
      send(dashboard_task_pid, {handler_id, :release})
      assert_receive {^handler_id, replacement_task_pid}
      refute replacement_task_pid == dashboard_task_pid
      send(replacement_task_pid, {handler_id, :release})
      _ = await_stats_dashboard(view)

      assert has_element?(view, "#stats-pool-filter[value='#{second_pool.id}']")
      assert has_element?(view, "#stats-time-filter[value='1h']")
      assert has_element?(view, "#stats-kpi-tokens", "21")
      refute has_element?(view, "#stats-traffic-chart", "100 tokens")
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

      {:ok, view, _html} = live_stats(conn, ~p"/admin/stats?pool_id=#{pool.id}&window=24h")

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
      assert has_element?(view, "#stats-api-key-surface", "Stats usage key")
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

      {:ok, view, _html} =
        live_stats(conn, ~p"/admin/stats?pool_id=#{selected_pool.id}&window=24h")

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
      refute has_element?(view, "#stats-api-key-surface", other.api_key.display_name)
      refute render(view) =~ selected.raw_key
      refute render(view) =~ other.raw_key
    end

    test "rapid events coalesce into one debounced reload", %{conn: conn, scope: scope} do
      {:ok, pool} = Pools.create_pool(scope, %{slug: "stats-realtime-burst", name: "Stats Burst"})

      {:ok, view, _html} = live_stats(conn, ~p"/admin/stats?pool_id=#{pool.id}&window=24h")

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

      {:ok, view, _html} =
        live_stats(conn, ~p"/admin/stats?pool_id=#{first_pool.id}&window=24h")

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

      _ =
        await_stats_dashboard_params(view, %{
          "pool_id" => second_pool.id,
          "window" => "24h"
        })

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

      {:ok, view, _html} =
        live_stats(conn, ~p"/admin/stats?pool_id=#{first_pool.id}&window=24h")

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

      _ =
        await_stats_dashboard_params(view, %{
          "pool_id" => second_pool.id,
          "window" => "1h"
        })

      assert_reload_telemetry(:cancelled, window: "1h", scope: "selected_pool")
      assert has_element?(view, "#stats-pool-filter[value='#{second_pool.id}']")
      assert has_element?(view, "#stats-time-filter[value='1h']")
      assert has_element?(view, "#stats-kpi-tokens", "21")

      send(view.pid, :reload_stats_dashboard)
      _ = await_stats_dashboard(view)
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

      {:ok, view, _html} = live_stats(conn, ~p"/admin/stats?pool_id=#{pool.id}&window=1h")

      refute has_element?(view, "#stats-empty-states")
      assert has_element?(view, "#stats-kpi-requests", "0")
      assert has_element?(view, "#stats-kpi-success-rate", "not available")
      assert has_element?(view, "#stats-kpi-cost", "unavailable")

      [stats_kpi_classes] =
        view
        |> element("#stats-kpis")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#stats-kpis")
        |> LazyHTML.attribute("class")

      stats_kpi_classes = String.split(stats_kpi_classes)

      assert "max-sm:[&_[data-role=metric-card-value]]:text-xs" in stats_kpi_classes

      assert "max-sm:[&_[data-role=metric-card-value]]:whitespace-nowrap" in stats_kpi_classes

      assert has_element?(view, "#stats-kpi-cache-rate", "not available")
      assert has_element?(view, "#stats-kpi-cache-rate", "No input tokens")
      assert has_element?(view, "#stats-traffic-chart", "0 requests")
      assert has_element?(view, "#stats-traffic-chart", "0 tokens")
      assert has_element?(view, "#stats-token-cost-chart", "$0.00")
      refute has_element?(view, "[id^='stats-model-usage-chart']")

      assert has_element?(
               view,
               "#stats-upstream-surface > header p",
               "Share of accounted requests across Stats Empty Live in the last 1 hour."
             )

      assert has_element?(view, "#stats-upstream-lanes")

      all_zero_surface_html = view |> element("#stats-upstream-surface") |> render()
      refute all_zero_surface_html =~ "bg-primary/5"
      refute all_zero_surface_html =~ "text-primary"
      refute all_zero_surface_html =~ "progress-primary"

      assert has_element?(
               view,
               "#stats-upstream-lane-1:not([data-leader='true']) [data-role='upstream-traffic-share']",
               "0.0%"
             )

      assert has_element?(
               view,
               "#stats-upstream-rail-1[max='100'][value='0.0']"
             )

      refute has_element?(view, "#stats-upstream-lanes [data-leader='true']")
      refute has_element?(view, "#stats-upstream-empty-state")

      traffic_chart_html = view |> element("#stats-traffic-chart-plot") |> render()
      traffic_series = chart_json_attribute(traffic_chart_html, "data-chart-series")

      assert Enum.map(traffic_series, & &1["name"]) == ["Tokens", "Requests"]
      assert Enum.all?(traffic_series, fn series -> Enum.all?(series["data"], &(&1 == 0)) end)

      assert chart_json_attribute(traffic_chart_html, "data-chart-units") == [
               "tokens",
               "requests"
             ]

      assert chart_json_attribute(traffic_chart_html, "data-chart-value-kinds") == [
               "tokens",
               "integer"
             ]
    end

    test "weekly-only quota evidence does not leak into traffic or cache usage", %{
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

      {:ok, view, _html} = live_stats(conn, ~p"/admin/stats?pool_id=#{pool.id}&window=5h")

      assert has_element?(view, "#stats-kpi-cache-rate", "not available")
      assert has_element?(view, "#stats-kpi-cache-rate", "No input tokens")
      refute has_element?(view, "#stats-kpi-quota-health")
      refute has_element?(view, "#stats-kpis", "Weekly evidence only")
      refute has_element?(view, "#stats-upstream-surface", "weekly")
      refute has_element?(view, "#stats-upstream-surface", "active")
      refute has_element?(view, "#stats-quota-table")
      refute has_element?(view, "#stats-quota-table", "Exhausted")
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

  defp execute_scheduled_reload(view, opts \\ []) do
    state = :sys.get_state(view.pid)
    timer = state.socket.assigns[:stats_reload_timer]

    if is_reference(timer) do
      Process.cancel_timer(timer, async: false, info: false)
    end

    send(view.pid, :reload_stats_dashboard)
    _ = :sys.get_state(view.pid)

    if Keyword.get(opts, :await?, true) do
      await_stats_dashboard(view)
    end
  end

  defp live_stats(conn, path) do
    with {:ok, view, html} <- live(conn, path) do
      _ = await_stats_dashboard(view)
      {:ok, view, html}
    end
  end

  defp await_stats_dashboard(view, attempts \\ 100)

  defp await_stats_dashboard(view, attempts) when attempts > 0 do
    _ = render_async(view)
    state = :sys.get_state(view.pid)

    if Map.get(state.socket.assigns, :dashboard_loading?, false) or
         Map.get(state.socket.assigns, :stats_dashboard_running?, false) do
      receive do
      after
        1 -> await_stats_dashboard(view, attempts - 1)
      end
    else
      state
    end
  end

  defp await_stats_dashboard(view, 0) do
    flunk("stats dashboard did not finish loading: #{inspect(:sys.get_state(view.pid))}")
  end

  defp await_stats_dashboard_params(view, expected_params, attempts \\ 100)

  defp await_stats_dashboard_params(view, expected_params, attempts) when attempts > 0 do
    state = :sys.get_state(view.pid)
    assigns = state.socket.assigns

    if assigns.current_params == expected_params and not assigns.dashboard_loading? and
         not assigns.stats_dashboard_running? do
      state
    else
      _ = render_async(view)

      receive do
      after
        1 -> await_stats_dashboard_params(view, expected_params, attempts - 1)
      end
    end
  end

  defp await_stats_dashboard_params(view, expected_params, 0) do
    flunk(
      "stats dashboard did not load params #{inspect(expected_params)}: #{inspect(:sys.get_state(view.pid))}"
    )
  end

  defp normalize_repo_query_value(value) when is_binary(value), do: value
  defp normalize_repo_query_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_repo_query_value(value), do: to_string(value)

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
      #stats-kpi-cache-rate
      #stats-traffic-chart
      #stats-token-cost-chart
    )
  end

  defp chart_json_attribute(html, attribute) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(attribute)
    |> case do
      [value] -> Jason.decode!(value)
      [] -> flunk("missing #{attribute} in chart HTML")
    end
  end

  defp component_chart_json_attribute(html, attribute) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#stats-traffic-chart-plot")
    |> LazyHTML.attribute(attribute)
    |> case do
      [value] -> Jason.decode!(value)
      [] -> flunk("missing #{attribute} in Traffic chart HTML")
    end
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
      settled_cost_micros: 750_000,
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
      estimated_cost_micros: Map.get(attrs, :estimated_cost_micros, 0),
      settled_cost_micros:
        Map.get(attrs, :settled_cost_micros, Map.get(attrs, :estimated_cost_micros, 0))
    })

    %{api_key: api_key, raw_key: raw_key, identity: identity, assignment: assignment}
  end

  defp stats_model_usage_fixture(pool, model, attrs) do
    sensitive_marker = Map.fetch!(attrs, :sensitive_marker)

    %{api_key: api_key, raw_key: raw_key} =
      active_api_key_fixture(pool, %{
        display_name: "Stats model usage key"
      })

    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)

    bucket = attrs |> Map.fetch!(:as_of) |> truncate_to_hour()

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        model_id: model.id,
        requested_model: "requested-#{model.exposed_model_id}",
        correlation_id: Map.get(attrs, :correlation_id, "stats-model-usage-live"),
        request_metadata: %{
          "prompt" => "raw prompt #{sensitive_marker}",
          "authorization" => "Bearer #{sensitive_marker}"
        }
      })
      |> set_request_time!(bucket)

    attempt =
      request
      |> attempt_fixture(assignment)
      |> set_attempt_time!(bucket, %{latency_ms: 100})

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      total_tokens: Map.fetch!(attrs, :total_tokens),
      input_tokens: Map.fetch!(attrs, :input_tokens),
      cached_input_tokens: Map.fetch!(attrs, :cached_input_tokens),
      output_tokens: Map.fetch!(attrs, :output_tokens),
      reasoning_tokens: Map.fetch!(attrs, :reasoning_tokens),
      estimated_cost_micros: 0,
      details: %{"body" => sensitive_marker}
    })
    |> Ecto.Changeset.change(%{model_id: model.id, occurred_at: bucket, created_at: bucket})
    |> Repo.update!()

    insert_hourly_model_usage_rollup!(pool, model, bucket, attrs)

    %{api_key: api_key, raw_key: raw_key, identity: identity, assignment: assignment}
  end

  defp insert_hourly_model_usage_rollup!(pool, model, bucket, attrs) do
    total_tokens = Map.fetch!(attrs, :total_tokens)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("hourly_model_usage_rollups", [
      %{
        bucket_started_at: truncate_to_hour(bucket),
        pool_id: Ecto.UUID.dump!(pool.id),
        model_id: Ecto.UUID.dump!(model.id),
        model_code: model.exposed_model_id,
        request_count: 1,
        success_count: 1,
        failure_count: 0,
        retry_count: 0,
        input_tokens: Map.fetch!(attrs, :input_tokens),
        cached_input_tokens: Map.fetch!(attrs, :cached_input_tokens),
        output_tokens: Map.fetch!(attrs, :output_tokens),
        reasoning_tokens: Map.fetch!(attrs, :reasoning_tokens),
        total_tokens: total_tokens,
        estimated_cost_micros: Decimal.new(0),
        settled_cost_micros: Decimal.new(0),
        created_at: now,
        updated_at: now
      }
    ])
  end

  defp set_request_time!(request, timestamp) do
    request
    |> Ecto.Changeset.change(%{admitted_at: timestamp, completed_at: timestamp})
    |> Repo.update!()
  end

  defp set_attempt_time!(attempt, timestamp, attrs) do
    attempt
    |> Ecto.Changeset.change(Map.merge(%{started_at: timestamp, completed_at: timestamp}, attrs))
    |> Repo.update!()
  end

  defp truncate_to_hour(datetime) do
    %{datetime | minute: 0, second: 0, microsecond: {0, 6}}
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
      settled_cost_micros: Decimal.new(750_000),
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
