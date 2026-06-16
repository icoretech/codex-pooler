defmodule CodexPoolerWeb.Admin.PoolsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounts
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{OperatorPoolAssignment, Pool}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel

  setup :register_and_log_in_user

  test "renders empty pools guidance without a duplicate reset action", %{conn: conn} do
    Repo.delete_all(Pool)

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    assert has_element?(view, "#pool-empty-state", "No Pools Found")

    assert has_element?(
             view,
             "#pool-empty-state",
             "Create the first Pool before connecting upstreams or issuing API keys."
           )

    refute has_element?(view, "#pool-empty-reset-filters")
    assert has_element?(view, "#pool-empty-create-action", "Create Pool")
  end

  test "does not expose create-pool upstream options without pool management", %{scope: scope} do
    active_identity_fixture(%{account_label: "Pool create hidden account"})

    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "pool-create-denied@example.com",
        "password_change_required" => "false"
      })

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    log =
      capture_log(fn ->
        admin_conn = log_in_user(build_conn(), admin, token)
        {:ok, view, html} = live(admin_conn, ~p"/admin/pools")

        refute html =~ "Pool create hidden account"
        refute has_element?(view, "#pools-page-create-action")
        refute has_element?(view, "#pool-create-dialog")

        state = :sys.get_state(view.pid)
        refute state.socket.assigns.can_manage_pools?
        assert state.socket.assigns.upstream_identity_options == []

        html = render_click(view, "open_create_pool")

        assert html =~ "Pool management is not available for this session"
        refute has_element?(view, "#pool-create-dialog")
        refute render(view) =~ "Pool create hidden account"
      end)

    refute log =~ "admin option loader unavailable"
    refute log =~ "capability_denied"
  end

  test "assigned admin sees only assigned pools without owner pool controls", %{scope: scope} do
    {:ok, assigned_pool} =
      Pools.create_pool(scope, %{slug: "browser-assigned", name: "Browser Assigned"})

    {:ok, hidden_pool} =
      Pools.create_pool(scope, %{slug: "browser-hidden", name: "Browser Hidden"})

    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "browser-assigned-admin@example.com",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: scope.user.id)

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, view, html} = live(admin_conn, ~p"/admin/pools")

    assert has_element?(view, "#pool-row-#{assigned_pool.id}")
    refute html =~ hidden_pool.name
    refute html =~ hidden_pool.slug
    refute has_element?(view, "#pool-row-#{hidden_pool.id}")
    refute has_element?(view, "#pools-page-create-action")
    refute has_element?(view, "#pool-create-dialog")

    state = :sys.get_state(view.pid)
    refute state.socket.assigns.can_manage_pools?
    assert Enum.map(state.socket.assigns.pools, & &1.pool.id) == [assigned_pool.id]
  end

  test "unassigned admin sees explicit assigned-pool empty state without owner controls", %{
    scope: scope
  } do
    {:ok, hidden_pool} =
      Pools.create_pool(scope, %{slug: "browser-unassigned-hidden", name: "Browser Hidden"})

    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "browser-unassigned-admin@example.com",
        "password_change_required" => "false"
      })

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, view, html} = live(admin_conn, ~p"/admin/pools")

    assert has_element?(view, "#pool-empty-state", "No assigned Pools")

    assert has_element?(
             view,
             "#pool-empty-state",
             "Ask an instance owner to assign you to a Pool before managing Pool-scoped resources."
           )

    refute html =~ hidden_pool.name
    refute has_element?(view, "#pools-page-create-action")
    refute has_element?(view, "#pool-empty-create-action")
  end

  test "loads row summary data for pools without extra per-row queries", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "summary-pool", name: "Summary Pool"})
    {:ok, other_pool} = Pools.create_pool(scope, %{slug: "empty-pool", name: "Empty Pool"})

    {:ok, _} =
      Pools.update_routing_settings(scope, pool, %{
        "routing_strategy" => "deterministic_rotation",
        "bridge_ring_size" => 5,
        "sticky_websocket_sessions" => false,
        "sticky_http_sessions" => true
      })

    %{api_key: _api_key} = api_key_fixture(pool)
    %{api_key: paused_api_key} = api_key_fixture(pool)
    %{api_key: _hidden_api_key} = api_key_fixture(other_pool)
    assert {:ok, _paused_api_key} = Access.pause_api_key(scope, paused_api_key)
    assert {:ok, other_pool} = Pools.change_pool_status(scope, other_pool, "disabled")
    %{assignment: _assignment} = upstream_assignment_fixture(pool)

    upstream_assignment_fixture(pool, %{
      account_label: "Deleted summary upstream",
      assignment_status: "deleted"
    })

    upstream_assignment_fixture(other_pool, %{
      account_label: "Deleted only upstream",
      assignment_status: "deleted"
    })

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    state = :sys.get_state(view.pid)
    pool_id = pool.id
    other_pool_id = other_pool.id

    assert %{
             pool: %Pool{id: ^pool_id},
             api_key_count: 2,
             upstream_count: 1,
             request_count: 0,
             tokens_per_second: nil,
             settled_cost_micros: 0,
             traffic_window: "24h",
             traffic_window_label: "24h",
             routing_strategy: "deterministic_rotation"
           } = Enum.find(state.socket.assigns.pools, &(&1.pool.id == pool_id))

    assert %{
             pool: %Pool{id: ^other_pool_id},
             api_key_count: 0,
             upstream_count: 0,
             request_count: 0,
             tokens_per_second: nil,
             settled_cost_micros: 0,
             traffic_window: "24h",
             traffic_window_label: "24h",
             routing_strategy: "bridge_ring"
           } = Enum.find(state.socket.assigns.pools, &(&1.pool.id == other_pool_id))

    assert has_element?(view, "#pool-row-#{pool.id}-upstream-account-count", "1")
    assert has_element?(view, "#pool-row-#{pool.id}-api-key-count", "2")
    assert has_element?(view, "#pool-row-#{pool.id}-request-throughput", "0 / 0")
    assert has_element?(view, "#pool-row-#{pool.id}-request-count", "0")
    assert has_element?(view, "#pool-row-#{pool.id}-tokens-per-sec", "0")
    assert has_element?(view, "#pool-row-#{pool.id}-settled-cost", "$0.00")
    assert has_element?(view, "#pool-row-#{pool.id}-routing-strategy", "Deterministic rotation")

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-title-line #pool-row-#{pool.id}-routing-strategy"
           )

    assert render(view) =~
             ~r/id="pool-row-#{pool.id}-routing-strategy"[^>]*class="badge badge-ghost badge-sm shrink-0 max-w-48 truncate text-\[0\.65rem\] text-base-content\/50"/

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-actions #pool-row-#{pool.id}-status",
             "active"
           )

    refute has_element?(view, "#pool-row-#{pool.id}-id")

    assert has_element?(
             view,
             "#copy-pool-id-#{pool.id}[phx-hook='ClipboardCopy'][data-copy-text='#{pool.id}']",
             "Copy Pool ID"
           )

    assert has_element?(view, "#pool-row-#{pool.id}-activity[data-role='pool-activity-panel']")

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-traffic-histogram [data-role='pool-traffic-empty-state']"
           )

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-traffic-histogram [data-role='pool-traffic-empty-state']",
             "No traffic in the last 24h"
           )

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-traffic-histogram [data-role='pool-traffic-empty-icon']"
           )

    assert has_element?(view, "#pool-row-#{pool.id} > footer.pool-card-metrics.border-t")

    metric_links = [
      {"pool-upstream-count-cell", "pool-row-#{pool.id}-upstream-account-count",
       "/admin/upstreams?pool_id=#{pool.id}", "Upstreams", "1"},
      {"pool-api-key-count-cell", "pool-row-#{pool.id}-api-key-count",
       "/admin/api-keys?pool_id=#{pool.id}", "API keys", "2"},
      {"pool-request-count-cell", "pool-row-#{pool.id}-request-throughput",
       "/admin/request-logs?pool_id=#{pool.id}", "Req/TPS 24h", "0 / 0"}
    ]

    for {role, value_id, href, label, value} <- metric_links do
      assert has_element?(
               view,
               "#pool-row-#{pool.id} > footer [data-role='#{role}'] dt a[href='#{href}'].hover\\:text-primary",
               label
             )

      assert has_element?(view, "##{value_id}", value)
      refute has_element?(view, "##{value_id} a")
    end

    for {role, _value_id, _href, _label, _value} <- metric_links do
      assert has_element?(
               view,
               "#pool-row-#{pool.id} > footer [data-role='#{role}']"
             )
    end

    assert has_element?(
             view,
             "#pool-row-#{pool.id} > footer [data-role='pool-api-key-count-cell'].pl-3.sm\\:px-3"
           )

    assert has_element?(
             view,
             "#pool-row-#{pool.id} > footer [data-role='pool-request-count-cell'].pr-3.sm\\:px-3"
           )

    assert has_element?(view, "#pool-row-#{pool.id} > footer [data-role='pool-cost-cell']")

    assert has_element?(
             view,
             "#pool-row-#{pool.id} > footer [data-role='pool-cost-cell'] dt",
             "Cost 24h"
           )

    assert has_element?(view, "#pool-metric-requests", "0")
    refute has_element?(view, "#pool-metric-requests", "Last 5h requests")
    assert has_element?(view, "#pool-metric-tokens-per-sec", "0")
    assert has_element?(view, "#pool-metric-tokens-per-sec", "TPS 24h")

    refute has_element?(
             view,
             "#pool-metric-tokens-per-sec",
             "5h settled tokens / upstream latency"
           )

    assert has_element?(view, "#pool-row-#{pool.id}-traffic-histogram")
    refute has_element?(view, "#pool-row-#{pool.id}-quota-remaining")
    refute has_element?(view, "#pool-row-#{pool.id}", "5h quota")
    refute has_element?(view, "#pool-row-#{pool.id}", "Weekly quota")
    refute has_element?(view, "#pool-row-#{pool.id} [data-role='pool-quota-donut']")
    refute has_element?(view, "#pool-row-#{pool.id}-quota-remaining", "Pool quota")
    refute has_element?(view, "#pool-row-#{pool.id}-quota-capacity")
    refute has_element?(view, "#pool-row-#{pool.id}-compatibility-mode")

    assert has_element?(view, "#pool-row-#{other_pool.id}-upstream-account-count", "0")
    assert has_element?(view, "#pool-row-#{other_pool.id}-api-key-count", "0")
    assert has_element?(view, "#pool-row-#{other_pool.id}-request-throughput", "0 / 0")
    assert has_element?(view, "#pool-row-#{other_pool.id}-request-count", "0")
    assert has_element?(view, "#pool-row-#{other_pool.id}-tokens-per-sec", "0")
    assert has_element?(view, "#pool-row-#{other_pool.id}-settled-cost", "$0.00")
    assert has_element?(view, "#pool-row-#{other_pool.id}-routing-strategy", "Bridge ring")
    assert has_element?(view, "#pool-row-#{other_pool.id}-status", "disabled")
    assert has_element?(view, "#pool-row-#{other_pool.id}-activity")
    refute has_element?(view, "#pool-row-#{other_pool.id}-quota-remaining")

    refute has_element?(view, "#pool-row-#{other_pool.id}-quota-capacity")
    refute has_element?(view, "#pool-row-#{other_pool.id}-compatibility-mode")
  end

  test "does not render pool quota pressure cards from upstream quota evidence", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "quota-card-pool", name: "Quota Card Pool"})
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)
    weekly_reset_at = DateTime.add(DateTime.utc_now(), 7, :day) |> DateTime.truncate(:second)

    %{identity: team_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Sample Team Account",
        assignment_label: "Sample Team Account"
      })

    %{identity: pro_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Sample Pro Account",
        assignment_label: "Sample Pro Account"
      })

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(team_identity, [
               quota_window_attrs("primary", 300, 1000, "25", reset_at),
               quota_window_attrs("secondary", 10_080, 2000, "10", weekly_reset_at)
             ])

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(pro_identity, [
               quota_window_attrs("primary", 300, 500, "90", reset_at)
             ])

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    assert has_element?(view, "#pool-row-#{pool.id}-activity")
    assert has_element?(view, "#pool-row-#{pool.id}-traffic-histogram")
    refute has_element?(view, "#pool-row-#{pool.id}-quota-remaining")
    refute has_element?(view, "#pool-row-#{pool.id}-quota-primary-5h")
    refute has_element?(view, "#pool-row-#{pool.id}-quota-weekly")
    refute has_element?(view, "#pool-row-#{pool.id}", "5h quota")
    refute has_element?(view, "#pool-row-#{pool.id}", "Weekly quota")
    refute has_element?(view, "#pool-row-#{pool.id}", "reporting")
    refute has_element?(view, "#pool-row-#{pool.id}", "remaining")
    refute has_element?(view, "#pool-row-#{pool.id} [phx-hook='QuotaPressureChart']")
  end

  test "renders default-window pool usage KPIs from settled usage", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "usage-kpi-pool", name: "Usage KPI Pool"})
    %{api_key: api_key} = api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    request = request_fixture(%{pool: pool, api_key: api_key})

    attempt =
      request
      |> attempt_fixture(assignment)
      |> Ecto.Changeset.change(%{latency_ms: 2_000})
      |> Repo.update!()

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      total_tokens: 100,
      input_tokens: 60,
      cached_input_tokens: 20,
      output_tokens: 40,
      estimated_cost_micros: 1_234_567,
      settled_cost_micros: 654_321
    })

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    assert has_element?(view, "#pool-metric-requests", "1")
    refute has_element?(view, "#pool-metric-requests", "Last 5h requests")
    assert has_element?(view, "#pool-metric-tokens-per-sec", "50")
    assert has_element?(view, "#pool-metric-tokens-per-sec", "TPS 24h")

    refute has_element?(
             view,
             "#pool-metric-tokens-per-sec",
             "5h settled tokens / upstream latency"
           )

    assert has_element?(view, "#pool-row-#{pool.id}-request-throughput", "1 / 50")
    assert has_element?(view, "#pool-row-#{pool.id}-request-count", "1")
    assert has_element?(view, "#pool-row-#{pool.id}-tokens-per-sec", "50")
    assert has_element?(view, "#pool-row-#{pool.id}-settled-cost", "$0.65")
    assert has_element?(view, "#pool-row-#{pool.id}-traffic-histogram", "Traffic 24h")

    refute has_element?(
             view,
             "#pool-row-#{pool.id}-traffic-histogram",
             "Tokens and requests by hour"
           )

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-traffic-histogram-total.pool-token-histogram-total"
           )

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-traffic-histogram h3 .pool-token-histogram-label",
             "Traffic"
           )

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-traffic-histogram-total .pool-token-histogram-label",
             "tokens"
           )

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-traffic-histogram-total .pool-token-histogram-label",
             "request"
           )

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-traffic-histogram-total .pool-token-histogram-value",
             "100"
           )

    assert has_element?(view, "#pool-row-#{pool.id}-traffic-histogram", "100 tokens")
    assert has_element?(view, "#pool-row-#{pool.id}-traffic-histogram", "1 request")

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-traffic-histogram-plot[phx-hook='ApexTimeSeriesChart'][phx-update='ignore']"
           )

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-traffic-histogram-plot[data-chart-units='[\"tokens\",\"requests\"]']"
           )

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-traffic-histogram-plot[data-chart-legend='false']"
           )

    assert has_element?(view, "#pool-row-#{pool.id}-activity")
    refute has_element?(view, "#pool-row-#{pool.id}-quota-remaining")
    refute has_element?(view, "#pool-row-#{pool.id}", "5h quota")
    refute has_element?(view, "#pool-row-#{pool.id}", "Weekly quota")
  end

  test "traffic window selector updates throughput cost and chart metrics", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "usage-window-pool", name: "Usage Window Pool"})

    %{api_key: api_key} = api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    recent_at =
      DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:microsecond)

    old_at = DateTime.add(recent_at, -5, :day)

    insert_timed_usage!(pool, api_key, assignment, recent_at, 100, 1_000_000, 2_000)
    insert_timed_usage!(pool, api_key, assignment, old_at, 25, 500_000, 500)

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    assert has_element?(view, "#pool-metric-requests", "1")
    assert has_element?(view, "#pool-metric-requests", "Requests 24h")
    assert has_element?(view, "#pool-metric-tokens-per-sec", "50")
    assert has_element?(view, "#pool-metric-tokens-per-sec", "TPS 24h")
    assert has_element?(view, "#pool-row-#{pool.id}-request-throughput", "1 / 50")

    assert has_element?(
             view,
             "#pool-row-#{pool.id} [data-role='pool-request-count-cell']",
             "Req/TPS 24h"
           )

    assert has_element?(view, "#pool-row-#{pool.id}-settled-cost", "$1.00")
    assert has_element?(view, "#pool-row-#{pool.id} [data-role='pool-cost-cell']", "Cost 24h")
    assert has_element?(view, "#pool-row-#{pool.id}-traffic-histogram", "Traffic 24h")
    assert has_element?(view, "#pool-row-#{pool.id}-traffic-histogram", "100 tokens")
    assert has_element?(view, "#pool-row-#{pool.id}-traffic-histogram", "1 request")

    view
    |> element("#pool-traffic-window-filter [data-window='7d']")
    |> render_click()

    assert has_element?(
             view,
             "#pool-traffic-window-filter [data-role='traffic-window-filter-trigger']",
             "Traffic: Last 7 days"
           )

    assert has_element?(view, "#pool-metric-requests", "2")
    assert has_element?(view, "#pool-metric-requests", "Requests 7d")
    assert has_element?(view, "#pool-metric-tokens-per-sec", "50")
    assert has_element?(view, "#pool-metric-tokens-per-sec", "TPS 7d")
    assert has_element?(view, "#pool-row-#{pool.id}-request-throughput", "2 / 50")

    assert has_element?(
             view,
             "#pool-row-#{pool.id} [data-role='pool-request-count-cell']",
             "Req/TPS 7d"
           )

    assert has_element?(view, "#pool-row-#{pool.id}-settled-cost", "$1.50")
    assert has_element?(view, "#pool-row-#{pool.id} [data-role='pool-cost-cell']", "Cost 7d")
    assert has_element?(view, "#pool-row-#{pool.id}-traffic-histogram", "Traffic 7d")
    assert has_element?(view, "#pool-row-#{pool.id}-traffic-histogram", "125 tokens")
    assert has_element?(view, "#pool-row-#{pool.id}-traffic-histogram", "2 requests")
  end

  test "renders the pools shell and protected controls for authenticated admins", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "admin-pools", name: "Admin Pools"})
    expected_pool_total = Repo.aggregate(Pool, :count, :id) |> Integer.to_string()

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    assert has_element?(view, "#admin-pools-live")
    assert has_element?(view, "#pool-metrics")
    assert has_element?(view, "#pool-metric-total", expected_pool_total)
    assert has_element?(view, "#pool-metric-total[data-density='compact']")
    assert has_element?(view, "#pool-metric-upstreams", "0")
    assert has_element?(view, "#pool-metric-upstreams .hero-cloud-arrow-up")
    assert has_element?(view, "#pool-metric-api-keys", "0")
    assert has_element?(view, "#pool-metric-requests", "0")
    assert has_element?(view, "#pool-metric-tokens-per-sec", "0")
    refute has_element?(view, "#pool-metric-active")
    refute has_element?(view, "#pool-metric-archived")
    refute has_element?(view, "#pool-metric-disabled")
    assert has_element?(view, "#pool-inventory-surface")
    assert has_element?(view, "#pool-filter-form")
    assert has_element?(view, "#pool-filter-form[phx-change='filter_pools']")
    refute has_element?(view, "#pool-filter-submit")
    refute has_element?(view, "#pool-filter-reset")

    assert has_element?(
             view,
             "#pool-status-filter [data-role='status-filter-trigger']",
             "Status: All"
           )

    assert has_element?(
             view,
             "#pool-traffic-window-filter [data-role='traffic-window-filter-trigger']",
             "Traffic: Last 24 hours"
           )

    assert has_element?(
             view,
             "#pool-traffic-window-filter [data-role='traffic-window-filter-option'][data-window='7d']",
             "Traffic: Last 7 days"
           )

    refute has_element?(view, "#pool-inventory-surface > header", "1 Pools")
    refute has_element?(view, "#pool-inventory-surface > footer")
    refute has_element?(view, "#pools-count")
    assert has_element?(view, "#pools-page-create-action")
    refute has_element?(view, "#pool-details-drawer-root")
    refute has_element?(view, "#pool-details-drawer")
    refute has_element?(view, "#pool-inspector")
    assert has_element?(view, "#pools-grid")
    refute has_element?(view, "#pools-table-scroll-region")
    refute has_element?(view, "#pools-table")
    assert has_element?(view, "article#pool-row-#{pool.id}.pool-card", "Admin Pools")
    assert has_element?(view, "#pool-row-#{pool.id}-name", "Admin Pools")
    refute has_element?(view, "#inspect-pool-#{pool.id}")
    refute has_element?(view, "#pool-row-#{pool.id}", "admin-pools")
    refute has_element?(view, "article#pool-row-#{pool.id}", "Created")

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-actions #pool-row-#{pool.id}-status",
             "active"
           )

    assert has_element?(view, "#pool-row-#{pool.id}-upstream-account-count")
    assert has_element?(view, "#pool-row-#{pool.id}-api-key-count")
    assert has_element?(view, "#pool-row-#{pool.id}-request-throughput")
    assert has_element?(view, "#pool-row-#{pool.id}-request-count")
    assert has_element?(view, "#pool-row-#{pool.id}-tokens-per-sec")
    assert has_element?(view, "#pool-row-#{pool.id}-settled-cost")

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-title-line #pool-row-#{pool.id}-routing-strategy"
           )

    assert has_element?(view, "#pool-row-#{pool.id}-activity")
    refute has_element?(view, "#pool-row-#{pool.id}-quota-remaining")
    refute has_element?(view, "#pool-row-#{pool.id}-quota-capacity")
    assert has_element?(view, "#pool-actions-menu-#{pool.id}")

    assert has_element?(
             view,
             "#copy-pool-id-#{pool.id}[data-copy-text='#{pool.id}']",
             "Copy Pool ID"
           )

    refute has_element?(view, "#pool-status-form-#{pool.id}")
    refute has_element?(view, "#archive-pool-#{pool.id}")
    refute has_element?(view, "#pool-row-#{pool.id}-compatibility-mode")
    refute has_element?(view, "#pool-api-keys-link-#{pool.id}")
    refute has_element?(view, "#pool-upstreams-link-#{pool.id}")
    refute has_element?(view, "#pool-request-logs-link-#{pool.id}")
    refute has_element?(view, "#pool-audit-logs-link-#{pool.id}")
    refute has_element?(view, "#archive-pool-form-#{pool.id}")
    assert has_element?(view, "#edit-pool-#{pool.id}")
    assert has_element?(view, "#delete-pool-#{pool.id}[disabled]")

    open_create_dialog(view)

    assert has_element?(view, "#pool-create-dialog[open]")
    assert has_element?(view, "#pool-create-form")
    assert has_element?(view, "#pool-create-dialog-header", "Pool configuration")
    refute has_element?(view, "#pool-create-dialog-header", "Pool lifecycle")
    assert_policy_editor_docs_link(view, "pool-create-dialog")
    assert has_element?(view, "#pool-create-dialog-tabs[role='tablist']")
    assert has_element?(view, "#pool-create-dialog-tab-details[aria-selected='true']")
    assert has_element?(view, "#pool-create-dialog-tab-routing[role='tab']")

    assert has_element?(
             view,
             "#pool-create-dialog-tab-routing [data-role='policy-editor-step-marker']"
           )

    assert has_element?(view, "#pool-create-dialog-tab-upstreams[role='tab']")
    assert has_element?(view, "#pool-create-dialog-tab-api-keys[role='tab']")
    assert has_element?(view, "#pool-create-dialog-section-details[role='tabpanel']")
    assert has_element?(view, "#pool-create-dialog-section-routing[role='tabpanel']")
    assert has_element?(view, "#pool-create-dialog-section-upstreams[role='tabpanel']")
    assert has_element?(view, "#pool-create-dialog-section-api-keys[role='tabpanel']")
    assert has_element?(view, "#pool-create-dialog-step-details-panel")
    assert has_element?(view, "#pool_name")

    view |> element("#pool-create-dialog-tab-routing") |> render_click()

    assert has_element?(view, "#pool-create-dialog-tab-routing[aria-selected='true']")
    assert has_element?(view, "#pool-create-dialog-step-routing-panel")
    assert has_element?(view, "#pool-create-routing-controls")
    assert has_element?(view, "#pool-create-routing-controls #pool_routing_strategy")
    assert has_element?(view, "#pool-create-routing-controls #pool_bridge_ring_size")
    assert has_element?(view, "#pool-create-routing-controls #pool_sticky_websocket_sessions")
    assert has_element?(view, "#pool-create-routing-controls #pool_sticky_http_sessions")
    assert has_element?(view, "#pool-create-routing-controls #pool_prompt_cache_affinity_enabled")
    assert has_element?(view, "#pool-create-routing-controls #pool_v1_compatibility_enabled")
    assert has_element?(view, "#pool-create-routing-controls #pool_request_compression_enabled")
    assert has_element?(view, "#pool_routing_strategy")
    assert has_element?(view, "#pool_bridge_ring_size")
    assert has_element?(view, "#pool_sticky_websocket_sessions")
    assert has_element?(view, "#pool_sticky_http_sessions")
    assert has_element?(view, "#pool_prompt_cache_affinity_enabled[checked]")
    assert has_element?(view, "#pool_v1_compatibility_enabled")
    refute has_element?(view, "#pool_request_compression_enabled[checked]")

    assert has_element?(
             view,
             "#pool-create-routing-controls",
             "Strategy and fan-out size used for runtime requests."
           )

    assert has_element?(
             view,
             "#pool-create-routing-controls",
             "Identity-aware routing behavior."
           )

    assert has_element?(
             view,
             "#pool-create-routing-controls",
             "Keep related prompt-cache-key requests near the same upstream for routing locality only."
           )

    assert has_element?(
             view,
             "#pool-create-routing-controls",
             "Codex Pooler does not store prompts or responses for this control."
           )

    assert has_element?(
             view,
             "#pool-create-routing-controls",
             "Optional client and analytics surfaces."
           )

    assert has_element?(
             view,
             "#pool-create-routing-controls",
             "Forward sanitized OpenAI control-plane analytics."
           )

    assert has_element?(
             view,
             "#pool-create-routing-controls",
             "Allow /v1 compatibility"
           )

    assert has_element?(
             view,
             "#pool-create-routing-controls",
             "Shrinks eligible Responses tool outputs before upstream dispatch."
           )

    assert has_element?(view, "#pool_routing_strategy option", "Bridge ring")
    assert has_element?(view, "#pool_routing_strategy option", "Deterministic rotation")
    assert has_element?(view, "#pool_routing_strategy option", "Least recent success")
    assert has_element?(view, "#pool_routing_strategy option", "Quota first")
    view |> element("#pool-create-dialog-tab-upstreams") |> render_click()

    assert has_element?(view, "#pool-create-dialog-tab-upstreams[aria-selected='true']")

    assert has_element?(
             view,
             "#pool-create-dialog-step-upstreams-panel",
             "Pool upstream assignments"
           )

    assert has_element?(view, "#pool-create-upstream-identity-options")

    refute has_element?(
             view,
             "#pool-create-upstream-identity-options",
             "Pool upstream assignments"
           )

    view |> element("#pool-create-dialog-tab-api-keys") |> render_click()

    assert has_element?(view, "#pool-create-dialog-tab-api-keys[aria-selected='true']")
    assert has_element?(view, "#pool-create-dialog-step-api-keys-panel", "API Keys")
    assert has_element?(view, "#pool-create-api-key-options")
    assert has_element?(view, "#pool-create-api-key-options [data-assignment-scroll]")

    refute has_element?(view, "#pool_slug")
  end

  test "filters the pool inventory from the toolbar", %{conn: conn, scope: scope} do
    {:ok, active_pool} =
      Pools.create_pool(scope, %{slug: "filter-active", name: "Filter Active"})

    {:ok, disabled_pool} =
      Pools.create_pool(scope, %{slug: "filter-disabled", name: "Filter Disabled"})

    assert {:ok, _pool} = Pools.change_pool_status(scope, disabled_pool, "disabled")

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    assert has_element?(view, "#pool-row-#{active_pool.id}", "Filter Active")
    assert has_element?(view, "#pool-row-#{disabled_pool.id}", "Filter Disabled")

    view
    |> element("#pool-status-filter [data-status='disabled']")
    |> render_click()

    refute has_element?(view, "#pool-row-#{active_pool.id}")
    assert has_element?(view, "#pool-row-#{disabled_pool.id}", "Filter Disabled")

    view
    |> element("#pool-status-filter [data-status='all']")
    |> render_click()

    assert has_element?(view, "#pool-row-#{active_pool.id}", "Filter Active")
    assert has_element?(view, "#pool-row-#{disabled_pool.id}", "Filter Disabled")

    view
    |> element("#pool-filter-form")
    |> render_change(%{
      "pool_filters" => %{"query" => "disabled", "status" => "disabled"}
    })

    refute has_element?(view, "#pool-row-#{active_pool.id}")
    assert has_element?(view, "#pool-row-#{disabled_pool.id}", "Filter Disabled")
    refute has_element?(view, "#pool-details-drawer")
    refute has_element?(view, "#pool-inspector")

    view
    |> element("#pool-filter-form")
    |> render_change(%{
      "pool_filters" => %{"query" => "active", "status" => "disabled"}
    })

    refute has_element?(view, "#pool-row-#{active_pool.id}")
    refute has_element?(view, "#pool-row-#{disabled_pool.id}")

    view |> element("#pool-filter-query-clear") |> render_click()

    refute has_element?(view, "#pool-row-#{active_pool.id}")
    assert has_element?(view, "#pool-row-#{disabled_pool.id}", "Filter Disabled")
    assert has_element?(view, "#pool-row-#{disabled_pool.id}-name", "Filter Disabled")
    refute has_element?(view, "#inspect-pool-#{disabled_pool.id}")
  end

  @tag feature_pool_control_plane_analytics: true
  test "creates pools from names with generated slugs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    open_create_dialog(view)

    view
    |> element("#pool-create-form")
    |> render_submit(%{"pool" => %{"name" => "Generated Slug Pool"}})

    created_pool = Repo.get_by!(Pool, slug: "generated-slug-pool")
    settings = Pools.get_routing_settings(created_pool)

    assert created_pool.name == "Generated Slug Pool"
    assert settings.prompt_cache_affinity_enabled == true
    assert settings.control_plane_analytics_forwarding_enabled == true
    assert settings.v1_compatibility_enabled == true
    assert settings.request_compression_enabled == false
    assert has_element?(view, "#pool-row-#{created_pool.id}", "Generated Slug Pool")
    refute has_element?(view, "#pool-row-#{created_pool.id}", "generated-slug-pool")
    refute has_element?(view, "#pool-create-dialog")
  end

  @tag feature_pool_control_plane_analytics: true
  test "creates pools with routing strategy, analytics forwarding toggle, compatibility toggle, and selected upstream identities",
       %{conn: conn} do
    first_identity =
      active_identity_fixture(account_label: "First create account", plan_label: "pro")

    second_identity = active_identity_fixture(account_label: "Second create account")

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    open_create_dialog(view)

    refute has_element?(view, "#pool_slug")
    assert has_element?(view, "#pool-create-upstream-identity-options", "First create account")
    assert has_element?(view, "#pool-create-upstream-identity-options", "Second create account")
    assert has_element?(view, "#pool-create-upstream-identity-options-card-#{first_identity.id}")
    assert has_element?(view, "#pool-create-upstream-identity-options-card-#{second_identity.id}")

    assert has_element?(
             view,
             "#pool-create-upstream-identity-options-plan-badge-#{first_identity.id}[data-role='plan-badge']",
             "Pro"
           )

    assert has_element?(
             view,
             "#pool-create-upstream-identity-options-plan-badge-#{first_identity.id}.border-primary\\/20.bg-primary\\/10.text-primary"
           )

    view
    |> element("#pool-create-form")
    |> render_submit(%{
      "pool" => %{
        "name" => "Routed Create Pool",
        "routing_strategy" => "least_recent_success",
        "prompt_cache_affinity_enabled" => "false",
        "control_plane_analytics_forwarding_enabled" => "false",
        "v1_compatibility_enabled" => "false",
        "request_compression_enabled" => "true",
        "upstream_identity_ids" => [first_identity.id, second_identity.id]
      }
    })

    created_pool = Repo.get_by!(Pool, slug: "routed-create-pool")
    settings = Pools.get_routing_settings(created_pool)
    assignments = Upstreams.list_pool_assignments(created_pool)

    assert created_pool.name == "Routed Create Pool"
    assert settings.routing_strategy == "least_recent_success"
    assert settings.prompt_cache_affinity_enabled == false
    assert settings.control_plane_analytics_forwarding_enabled == false
    assert settings.v1_compatibility_enabled == false
    assert settings.request_compression_enabled == true

    assert Enum.map(assignments, & &1.upstream_identity_id) |> Enum.sort() ==
             [first_identity.id, second_identity.id] |> Enum.sort()

    assert Enum.all?(assignments, &(&1.status == "active"))
    refute has_element?(view, "#pool-create-dialog")
  end

  test "rejects duplicate generated slugs and keeps the create dialog open", %{
    conn: conn,
    scope: scope
  } do
    {:ok, existing_pool} =
      Pools.create_pool(scope, %{slug: "duplicate-pool", name: "Duplicate Pool"})

    initial_pool_count = Repo.aggregate(Pool, :count, :id)

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    open_create_dialog(view)

    view
    |> element("#pool-create-form")
    |> render_submit(%{"pool" => %{"name" => "Duplicate Pool!!!"}})

    assert has_element?(view, "#pool-create-dialog[open]")
    assert Repo.aggregate(Pool, :count, :id) == initial_pool_count
    assert has_element?(view, "#pool-row-#{existing_pool.id}", "Duplicate Pool")
  end

  @tag feature_pool_control_plane_analytics: true
  test "create validation keeps selected routing and upstream values", %{conn: conn, scope: scope} do
    {:ok, _existing_pool} =
      Pools.create_pool(scope, %{slug: "duplicate-routed-pool", name: "Duplicate Routed Pool"})

    initial_pool_count = Repo.aggregate(Pool, :count, :id)

    identity = active_identity_fixture(account_label: "Preserved create account")

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    open_create_dialog(view)

    view
    |> element("#pool-create-form")
    |> render_submit(%{
      "pool" => %{
        "name" => "Duplicate Routed Pool!!!",
        "routing_strategy" => "quota_first",
        "prompt_cache_affinity_enabled" => "false",
        "control_plane_analytics_forwarding_enabled" => "false",
        "v1_compatibility_enabled" => "false",
        "request_compression_enabled" => "true",
        "upstream_identity_ids" => [identity.id]
      }
    })

    assert has_element?(view, "#pool-create-dialog[open]")
    assert has_element?(view, "#pool_routing_strategy option[selected][value='quota_first']")

    assert has_element?(
             view,
             "#pool-create-upstream-identity-options input[checked][value='#{identity.id}']"
           )

    refute has_element?(view, "#pool_prompt_cache_affinity_enabled[checked]")
    refute has_element?(view, "#pool_control_plane_analytics_forwarding_enabled[checked]")
    refute has_element?(view, "#pool_v1_compatibility_enabled[checked]")
    assert has_element?(view, "#pool_request_compression_enabled[checked]")

    assert Repo.aggregate(Pool, :count, :id) == initial_pool_count
  end

  test "edits pool name and status while keeping the slug readonly", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "editable-pool", name: "Editable Pool"})

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    view |> element("#edit-pool-#{pool.id}") |> render_click()

    assert has_element?(view, "#pool-edit-dialog[open]")
    assert has_element?(view, "#pool-edit-form")
    assert_policy_editor_docs_link(view, "pool-edit-dialog")
    assert has_element?(view, "#pool-edit-dialog-tabs[role='tablist']")
    assert has_element?(view, "#pool-edit-dialog-tab-details[aria-selected='true']")
    assert has_element?(view, "#pool-edit-dialog-tab-routing[role='tab']")
    assert has_element?(view, "#pool-edit-dialog-tab-upstreams[role='tab']")
    assert has_element?(view, "#pool-edit-dialog-tab-api-keys[role='tab']")
    assert has_element?(view, "#pool-edit-dialog-section-details[role='tabpanel']")
    assert has_element?(view, "#pool-edit-dialog-step-details-panel")
    assert has_element?(view, "#pool_edit_name")
    assert has_element?(view, "#pool_edit_status")
    refute has_element?(view, "#pool-edit-readonly-slug")

    view
    |> element("#pool-edit-form")
    |> render_submit(%{
      "pool_edit" => %{
        "id" => pool.id,
        "name" => "Renamed Pool",
        "status" => "disabled",
        "slug" => "changed-slug"
      }
    })

    updated_pool = Repo.get!(Pool, pool.id)

    assert updated_pool.name == "Renamed Pool"
    assert updated_pool.status == "disabled"
    assert updated_pool.slug == "editable-pool"
    assert has_element?(view, "#pool-row-#{pool.id}", "Renamed Pool")
    assert has_element?(view, "#pool-row-#{pool.id}-status", "disabled")
    refute has_element?(view, "#pool-row-#{pool.id}", "editable-pool")
  end

  @tag feature_pool_control_plane_analytics: true
  test "edits routing strategy and selected upstream identity rows", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "editable-routing", name: "Editable Routing"})

    {:ok, other_pool} =
      Pools.create_pool(scope, %{slug: "api-key-source", name: "API Key Source"})

    %{api_key: linked_api_key} =
      api_key_fixture(pool, %{display_name: "Keep linked key", scope: scope})

    %{api_key: moved_api_key} =
      api_key_fixture(other_pool, %{display_name: "Move linked key", scope: scope})

    %{assignment: removed_assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Remove me",
        assignment_label: "Remove me",
        plan_label: "Pro",
        identity_status: "active"
      })

    %{assignment: kept_assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Keep me",
        assignment_label: "Keep me",
        plan_label: "Free",
        identity_status: "refresh_due"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    view |> element("#edit-pool-#{pool.id}") |> render_click()

    assert has_element?(view, "#pool-edit-dialog-header", "Pool configuration")
    refute has_element?(view, "#pool-edit-dialog-header", "Pool lifecycle")

    view |> element("#pool-edit-dialog-tab-routing") |> render_click()

    assert has_element?(view, "#pool-edit-dialog-tab-routing[aria-selected='true']")
    assert has_element?(view, "#pool-edit-dialog-section-routing[role='tabpanel']")
    assert has_element?(view, "#pool-edit-dialog-step-routing-panel")
    assert has_element?(view, "#pool-edit-routing-controls")
    assert has_element?(view, "#pool-edit-routing-controls #pool_edit_routing_strategy")
    assert has_element?(view, "#pool-edit-routing-controls #pool_edit_bridge_ring_size")
    assert has_element?(view, "#pool-edit-routing-controls #pool_edit_sticky_websocket_sessions")
    assert has_element?(view, "#pool-edit-routing-controls #pool_edit_sticky_http_sessions")

    assert has_element?(
             view,
             "#pool-edit-routing-controls #pool_edit_prompt_cache_affinity_enabled"
           )

    assert has_element?(
             view,
             "#pool-edit-routing-controls #pool_edit_control_plane_analytics_forwarding_enabled"
           )

    assert has_element?(view, "#pool-edit-routing-controls #pool_edit_v1_compatibility_enabled")

    assert has_element?(
             view,
             "#pool-edit-routing-controls #pool_edit_request_compression_enabled"
           )

    assert has_element?(view, "#pool_edit_routing_strategy")
    assert has_element?(view, "#pool_edit_bridge_ring_size")
    assert has_element?(view, "#pool_edit_sticky_websocket_sessions")
    assert has_element?(view, "#pool_edit_sticky_http_sessions")
    assert has_element?(view, "#pool_edit_prompt_cache_affinity_enabled[checked]")
    assert has_element?(view, "#pool_edit_control_plane_analytics_forwarding_enabled")
    assert has_element?(view, "#pool_edit_v1_compatibility_enabled")
    refute has_element?(view, "#pool_edit_request_compression_enabled[checked]")

    assert has_element?(
             view,
             "#pool-edit-routing-controls",
             "Strategy and fan-out size used for runtime requests."
           )

    assert has_element?(
             view,
             "#pool-edit-routing-controls",
             "Identity-aware routing behavior."
           )

    assert has_element?(
             view,
             "#pool-edit-routing-controls",
             "Keep related prompt-cache-key requests near the same upstream for routing locality only."
           )

    assert has_element?(
             view,
             "#pool-edit-routing-controls",
             "Codex Pooler does not store prompts or responses for this control."
           )

    assert has_element?(
             view,
             "#pool-edit-routing-controls",
             "Optional client and analytics surfaces."
           )

    assert has_element?(
             view,
             "#pool-edit-routing-controls",
             "Forward analytics"
           )

    assert has_element?(
             view,
             "#pool-edit-routing-controls",
             "Forward sanitized OpenAI control-plane analytics."
           )

    assert has_element?(
             view,
             "#pool-edit-routing-controls",
             "Allow /v1 compatibility"
           )

    assert has_element?(
             view,
             "#pool-edit-routing-controls",
             "Shrinks eligible Responses tool outputs before upstream dispatch."
           )

    view |> element("#pool-edit-dialog-tab-upstreams") |> render_click()

    assert has_element?(view, "#pool-edit-dialog-tab-upstreams[aria-selected='true']")
    assert has_element?(view, "#pool-edit-dialog-section-upstreams[role='tabpanel']")

    assert has_element?(
             view,
             "#pool-edit-dialog-step-upstreams-panel",
             "Pool upstream assignments"
           )

    assert has_element?(view, "#pool-edit-dialog-step-upstreams-panel-header")
    assert has_element?(view, "#pool-edit-upstream-assignment-count", "2 available")

    assert has_element?(
             view,
             "#pool-edit-dialog-step-upstreams-panel-header #pool-edit-upstream-assignment-count"
           )

    assert has_element?(view, "#pool-edit-upstream-assignment-options")
    assert has_element?(view, "#pool-edit-upstream-assignment-options [data-assignment-scroll]")

    refute has_element?(
             view,
             "#pool-edit-upstream-assignment-options",
             "Pool upstream assignments"
           )

    assert has_element?(view, "#pool-edit-upstream-assignment-options", "Remove me")
    assert has_element?(view, "#pool-edit-upstream-assignment-options", "Keep me")
    assert has_element?(view, "#pool-edit-upstream-assignment-options", "Pro")
    assert has_element?(view, "#pool-edit-upstream-assignment-options", "Free")
    assert has_element?(view, "#pool-edit-upstream-assignment-options", "active")
    assert has_element?(view, "#pool-edit-upstream-assignment-options", "refresh_due")
    refute has_element?(view, "#pool-edit-upstream-assignment-options", kept_assignment.id)

    assert has_element?(
             view,
             "#pool-edit-upstream-assignment-options input[value='#{kept_assignment.upstream_identity_id}']"
           )

    refute has_element?(
             view,
             "#pool-edit-upstream-assignment-options input[value='#{kept_assignment.id}']"
           )

    view |> element("#pool-edit-dialog-tab-api-keys") |> render_click()

    assert has_element?(view, "#pool-edit-dialog-tab-api-keys[aria-selected='true']")
    assert has_element?(view, "#pool-edit-dialog-section-api-keys[role='tabpanel']")
    assert has_element?(view, "#pool-edit-dialog-step-api-keys-panel", "API Keys")
    assert has_element?(view, "#pool-edit-dialog-step-api-keys-panel-header")
    assert has_element?(view, "#pool-edit-api-key-count", "2 available")

    assert has_element?(
             view,
             "#pool-edit-dialog-step-api-keys-panel-header #pool-edit-api-key-count"
           )

    assert has_element?(view, "#pool-edit-api-key-options")
    assert has_element?(view, "#pool-edit-api-key-options [data-assignment-scroll]")
    assert has_element?(view, "#pool-edit-api-key-options", "Keep linked key")
    assert has_element?(view, "#pool-edit-api-key-options", "Move linked key")
    assert has_element?(view, "#pool-edit-api-key-options", "Editable Routing")
    assert has_element?(view, "#pool-edit-api-key-options", "API Key Source")

    assert has_element?(
             view,
             "#pool-edit-api-key-options input[checked][value='#{linked_api_key.id}']"
           )

    refute has_element?(
             view,
             "#pool-edit-api-key-options input[checked][value='#{moved_api_key.id}']"
           )

    view
    |> element("#pool-edit-form")
    |> render_submit(%{
      "pool_edit" => %{
        "id" => pool.id,
        "name" => "Editable Routing",
        "status" => "active",
        "routing_strategy" => "quota_first",
        "bridge_ring_size" => "5",
        "sticky_websocket_sessions" => "false",
        "sticky_http_sessions" => "true",
        "prompt_cache_affinity_enabled" => "false",
        "control_plane_analytics_forwarding_enabled" => "false",
        "v1_compatibility_enabled" => "false",
        "request_compression_enabled" => "true",
        "upstream_identity_ids" => [kept_assignment.upstream_identity_id],
        "api_key_ids" => [linked_api_key.id, moved_api_key.id]
      }
    })

    settings = Pools.get_routing_settings(pool)
    assert settings.routing_strategy == "quota_first"
    assert settings.bridge_ring_size == 5
    assert settings.sticky_websocket_sessions == false
    assert settings.sticky_http_sessions == true
    assert settings.prompt_cache_affinity_enabled == false
    assert settings.control_plane_analytics_forwarding_enabled == false
    assert settings.v1_compatibility_enabled == false
    assert settings.request_compression_enabled == true
    assert Repo.get!(PoolUpstreamAssignment, removed_assignment.id).status == "deleted"
    assert Repo.get!(PoolUpstreamAssignment, kept_assignment.id).status == "active"
    assert Repo.get!(APIKey, linked_api_key.id).pool_id == pool.id
    assert Repo.get!(APIKey, moved_api_key.id).pool_id == pool.id
    refute has_element?(view, "#pool-edit-dialog")
  end

  test "edit upstream step exposes identities assigned to other pools", %{
    conn: conn,
    scope: scope
  } do
    {:ok, target_pool} =
      Pools.create_pool(scope, %{slug: "identity-target", name: "Identity Target"})

    {:ok, source_pool} =
      Pools.create_pool(scope, %{slug: "identity-source", name: "Identity Source"})

    %{assignment: target_assignment} =
      upstream_assignment_fixture(target_pool, %{
        account_label: "Already target account",
        assignment_label: "Already target account"
      })

    %{assignment: source_assignment} =
      upstream_assignment_fixture(source_pool, %{
        account_label: "Attachable source account",
        assignment_label: "Attachable source account"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    view |> element("#edit-pool-#{target_pool.id}") |> render_click()
    view |> element("#pool-edit-dialog-tab-upstreams") |> render_click()

    assert has_element?(view, "#pool-edit-upstream-assignment-count", "2 available")
    assert has_element?(view, "#pool-edit-upstream-assignment-options", "Already target account")

    assert has_element?(
             view,
             "#pool-edit-upstream-assignment-options",
             "Attachable source account"
           )

    assert has_element?(
             view,
             "#pool-edit-upstream-assignment-options input[checked][value='#{target_assignment.upstream_identity_id}']"
           )

    refute has_element?(
             view,
             "#pool-edit-upstream-assignment-options input[checked][value='#{source_assignment.upstream_identity_id}']"
           )
  end

  test "edit can attach another pool identity without detaching it from the source pool", %{
    conn: conn,
    scope: scope
  } do
    {:ok, target_pool} =
      Pools.create_pool(scope, %{slug: "identity-attach-target", name: "Identity Attach Target"})

    {:ok, source_pool} =
      Pools.create_pool(scope, %{slug: "identity-attach-source", name: "Identity Attach Source"})

    %{assignment: source_assignment} =
      upstream_assignment_fixture(source_pool, %{
        account_label: "Shared attach account",
        assignment_label: "Shared attach account"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    assert has_element?(view, "#pool-row-#{target_pool.id}-upstream-account-count", "0")
    assert has_element?(view, "#pool-row-#{source_pool.id}-upstream-account-count", "1")

    view |> element("#edit-pool-#{target_pool.id}") |> render_click()

    view
    |> element("#pool-edit-form")
    |> render_submit(%{
      "pool_edit" => %{
        "id" => target_pool.id,
        "name" => target_pool.name,
        "status" => "active",
        "routing_strategy" => "bridge_ring",
        "upstream_identity_ids" => [source_assignment.upstream_identity_id],
        "api_key_ids" => []
      }
    })

    target_assignments = Upstreams.list_pool_assignments(target_pool)
    source_assignments = Upstreams.list_pool_assignments(source_pool)

    assert [%{status: "active", upstream_identity_id: source_identity_id}] = target_assignments
    assert source_identity_id == source_assignment.upstream_identity_id
    assert [%{status: "active", upstream_identity_id: ^source_identity_id}] = source_assignments
    assert has_element?(view, "#pool-row-#{target_pool.id}-upstream-account-count", "1")
    assert has_element?(view, "#pool-row-#{source_pool.id}-upstream-account-count", "1")
  end

  test "edit can remove a shared identity from one pool while upstream read model keeps the other assignment",
       %{conn: conn, scope: scope} do
    {:ok, target_pool} =
      Pools.create_pool(scope, %{slug: "identity-remove-target", name: "Identity Remove Target"})

    {:ok, source_pool} =
      Pools.create_pool(scope, %{slug: "identity-remove-source", name: "Identity Remove Source"})

    identity = active_identity_fixture(account_label: "Shared remove account")

    assert :ok =
             Upstreams.sync_pool_assignments_for_pool_edit(target_pool, [identity.id],
               select_by: :upstream_identity_id,
               skip_quota_priming: true
             )

    assert :ok =
             Upstreams.sync_pool_assignments_for_pool_edit(source_pool, [identity.id],
               select_by: :upstream_identity_id,
               skip_quota_priming: true
             )

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    view |> element("#edit-pool-#{target_pool.id}") |> render_click()

    view
    |> element("#pool-edit-form")
    |> render_submit(%{
      "pool_edit" => %{
        "id" => target_pool.id,
        "name" => target_pool.name,
        "status" => "active",
        "routing_strategy" => "bridge_ring",
        "upstream_identity_ids" => [],
        "api_key_ids" => []
      }
    })

    _ = :sys.get_state(view.pid)

    assignments_by_pool =
      identity
      |> Upstreams.list_pool_assignments_for_identity()
      |> Map.new(&{&1.pool_id, &1})

    assert %{status: "deleted"} = Map.fetch!(assignments_by_pool, target_pool.id)
    assert %{status: "active"} = Map.fetch!(assignments_by_pool, source_pool.id)

    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [target_pool, source_pool])

    assert account.identity.id == identity.id
    assert [%{pool_id: source_pool_id, pool_label: source_pool_label}] = account.assignments
    assert source_pool_id == source_pool.id
    assert source_pool_label =~ source_pool.name
  end

  test "refreshes pool rows when routing settings change from another process", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "refresh-routing", name: "Refresh Routing"})

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    assert has_element?(view, "#pool-row-#{pool.id}-routing-strategy", "Bridge ring")
    refute has_element?(view, "#pool-inspector")

    assert {:ok, _settings} =
             Pools.update_routing_settings(scope, pool, %{
               "routing_strategy" => "deterministic_rotation"
             })

    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#pool-row-#{pool.id}-routing-strategy", "Deterministic rotation")
    refute has_element?(view, "#pool-inspector")
  end

  test "refreshes pool counts and usage metrics when events arrive", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "refresh-counts", name: "Refresh Counts"})

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    assert has_element?(view, "#pool-row-#{pool.id}-api-key-count", "0")
    assert has_element?(view, "#pool-row-#{pool.id}-upstream-account-count", "0")
    assert has_element?(view, "#pool-row-#{pool.id}-request-throughput", "0 / 0")
    assert has_element?(view, "#pool-row-#{pool.id}-request-count", "0")
    assert has_element?(view, "#pool-row-#{pool.id}-tokens-per-sec", "0")
    assert has_element?(view, "#pool-row-#{pool.id}-settled-cost", "$0.00")

    %{api_key: api_key} = api_key_fixture(pool, %{scope: scope})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#pool-row-#{pool.id}-api-key-count", "1")

    %{assignment: assignment} = upstream_assignment_fixture(pool)

    assert {:ok, _event} =
             Events.broadcast_upstreams(pool.id, "upstream_assignment_created", %{})

    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#pool-row-#{pool.id}-upstream-account-count", "1")

    request = request_fixture(%{pool: pool, api_key: api_key})

    attempt =
      request
      |> attempt_fixture(assignment)
      |> Ecto.Changeset.change(%{latency_ms: 2_000})
      |> Repo.update!()

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      total_tokens: 100,
      input_tokens: 60,
      output_tokens: 40,
      estimated_cost_micros: 2_500_000,
      settled_cost_micros: 1_250_000
    })

    assert {:ok, _event} = Events.broadcast_usage(pool.id, "usage_updated", %{})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#pool-row-#{pool.id}-request-throughput", "1 / 50")
    assert has_element?(view, "#pool-row-#{pool.id}-request-count", "1")
    assert has_element?(view, "#pool-row-#{pool.id}-tokens-per-sec", "50")
    assert has_element?(view, "#pool-row-#{pool.id}-settled-cost", "$1.25")
    assert has_element?(view, "#pool-metric-requests", "1")
    assert has_element?(view, "#pool-metric-tokens-per-sec", "50")
    assert has_element?(view, "#pool-row-#{pool.id}-traffic-histogram", "100 tokens")
    assert has_element?(view, "#pool-row-#{pool.id}-traffic-histogram", "1 request")
    refute has_element?(view, "#pool-row-#{pool.id}-quota-remaining")
  end

  @tag feature_pool_control_plane_analytics: true
  test "preserves supporting routing settings when editing from pools dialog", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "preserve-routing", name: "Preserve Routing"})

    {:ok, _settings} =
      Pools.update_routing_settings(scope, pool, %{
        "routing_strategy" => "deterministic_rotation",
        "bridge_ring_size" => 7,
        "sticky_websocket_sessions" => false,
        "sticky_http_sessions" => true,
        "prompt_cache_affinity_enabled" => false,
        "control_plane_analytics_forwarding_enabled" => true,
        "request_compression_enabled" => true
      })

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    view |> element("#edit-pool-#{pool.id}") |> render_click()

    refute has_element?(view, "#pool_edit_prompt_cache_affinity_enabled[checked]")
    assert has_element?(view, "#pool_edit_request_compression_enabled[checked]")

    view
    |> element("#pool-edit-form")
    |> render_submit(%{
      "pool_edit" => %{
        "id" => pool.id,
        "name" => "Preserved Routing",
        "status" => "active",
        "routing_strategy" => "quota_first",
        "prompt_cache_affinity_enabled" => "false",
        "control_plane_analytics_forwarding_enabled" => "false",
        "v1_compatibility_enabled" => "false",
        "request_compression_enabled" => "false",
        "upstream_identity_ids" => []
      }
    })

    settings = pool |> Pools.get_routing_settings() |> Repo.reload!()

    assert settings.routing_strategy == "quota_first"
    assert settings.bridge_ring_size == 7
    assert settings.sticky_websocket_sessions == false
    assert settings.sticky_http_sessions == true
    assert settings.prompt_cache_affinity_enabled == false
    assert settings.control_plane_analytics_forwarding_enabled == false
    assert settings.v1_compatibility_enabled == false
    assert settings.request_compression_enabled == false
    assert Repo.get!(Pool, pool.id).name == "Preserved Routing"
    refute has_element?(view, "#pool-edit-dialog")
  end

  test "edit failure rolls back pool and routing changes", %{conn: conn, scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "rollback-routing", name: "Rollback Routing"})

    {:ok, _settings} =
      Pools.update_routing_settings(scope, pool, %{
        "routing_strategy" => "deterministic_rotation",
        "bridge_ring_size" => 5,
        "sticky_websocket_sessions" => false,
        "sticky_http_sessions" => true
      })

    %{assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Rollback account",
        assignment_label: "Rollback account"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    view |> element("#edit-pool-#{pool.id}") |> render_click()

    view
    |> element("#pool-edit-form")
    |> render_submit(%{
      "pool_edit" => %{
        "id" => pool.id,
        "name" => "Partially Updated Pool",
        "status" => "active",
        "routing_strategy" => "quota_first",
        "upstream_identity_ids" => [assignment.upstream_identity_id, Ecto.UUID.generate()]
      }
    })

    settings = pool |> Pools.get_routing_settings() |> Repo.reload!()

    assert has_element?(view, "#pool-edit-dialog[open]")
    assert Repo.get!(Pool, pool.id).name == "Rollback Routing"
    assert settings.routing_strategy == "deterministic_rotation"
    assert settings.bridge_ring_size == 5
    assert settings.sticky_websocket_sessions == false
    assert settings.sticky_http_sessions == true
    assert Repo.get!(PoolUpstreamAssignment, assignment.id).status == "active"
  end

  @tag feature_pool_control_plane_analytics: true
  test "edit validation keeps selected routing and upstream identity values", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "validation-routing", name: "Validation Routing"})

    %{assignment: first_assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "First edit account",
        assignment_label: "First edit account"
      })

    %{assignment: second_assignment} =
      upstream_assignment_fixture(pool, %{
        account_label: "Second edit account",
        assignment_label: "Second edit account"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    view |> element("#edit-pool-#{pool.id}") |> render_click()

    view
    |> element("#pool-edit-form")
    |> render_submit(%{
      "pool_edit" => %{
        "id" => pool.id,
        "name" => "",
        "status" => "active",
        "routing_strategy" => "deterministic_rotation",
        "prompt_cache_affinity_enabled" => "false",
        "control_plane_analytics_forwarding_enabled" => "false",
        "v1_compatibility_enabled" => "false",
        "request_compression_enabled" => "true",
        "upstream_identity_ids" => [second_assignment.upstream_identity_id]
      }
    })

    assert has_element?(view, "#pool-edit-dialog[open]")

    assert has_element?(
             view,
             "#pool_edit_routing_strategy option[selected][value='deterministic_rotation']"
           )

    assert has_element?(
             view,
             "#pool-edit-upstream-assignment-options input[checked][value='#{second_assignment.upstream_identity_id}']"
           )

    refute has_element?(view, "#pool_edit_prompt_cache_affinity_enabled[checked]")
    refute has_element?(view, "#pool_edit_control_plane_analytics_forwarding_enabled[checked]")
    refute has_element?(view, "#pool_edit_v1_compatibility_enabled[checked]")
    assert has_element?(view, "#pool_edit_request_compression_enabled[checked]")

    refute has_element?(
             view,
             "#pool-edit-upstream-assignment-options input[checked][value='#{first_assignment.upstream_identity_id}']"
           )

    assert Repo.get!(PoolUpstreamAssignment, first_assignment.id).status == "active"
    assert Repo.get!(PoolUpstreamAssignment, second_assignment.id).status == "active"
  end

  test "archives a pool before hard delete and requires exact slug confirmation", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "deletable-pool", name: "Deletable Pool"})

    %{user: admin} =
      operator_fixture(scope, %{
        "email" => "pool-archive-assigned-admin@example.com",
        "password_change_required" => "false"
      })

    operator_assignment =
      operator_pool_assignment_fixture(admin, pool, created_by_user_id: scope.user.id)

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    assert has_element?(view, "#delete-pool-#{pool.id}[disabled]")

    assert {:error, %{code: :pool_not_archived, message: "pool must be archived before deletion"}} =
             Pools.delete_archived_pool(scope, pool, pool.slug)

    assert Repo.get!(Pool, pool.id).status == "active"

    view |> element("#edit-pool-#{pool.id}") |> render_click()

    view
    |> element("#pool-edit-form")
    |> render_submit(%{
      "pool_edit" => %{
        "id" => pool.id,
        "name" => "Deletable Pool",
        "status" => "archived",
        "routing_strategy" => "bridge_ring",
        "upstream_identity_ids" => []
      }
    })

    archived_pool = Repo.get!(Pool, pool.id)

    assert archived_pool.status == "archived"

    revoked_assignment = Repo.get!(OperatorPoolAssignment, operator_assignment.id)
    assert revoked_assignment.status == "revoked"
    assert revoked_assignment.revoked_at

    assert has_element?(view, "#pool-row-#{pool.id}-status", "archived")
    refute has_element?(view, "#delete-pool-#{pool.id}[disabled]")

    view |> element("#delete-pool-#{pool.id}") |> render_click()

    assert has_element?(view, "#pool-delete-dialog[open]")
    assert has_element?(view, "#pool-delete-form")
    assert has_element?(view, "[id^=\"pool_delete_confirmation_slug_\"]")

    view
    |> element("#pool-delete-form")
    |> render_submit(%{
      "pool_delete" => %{"id" => pool.id, "confirmation_slug" => "wrong-slug"}
    })

    assert has_element?(view, "#pool-delete-dialog[open]")
    assert has_element?(view, "[id^=\"pool_delete_confirmation_slug_\"][value='']")
    assert Repo.get(Pool, pool.id)

    view
    |> element("#pool-delete-form")
    |> render_submit(%{
      "pool_delete" => %{"id" => pool.id, "confirmation_slug" => pool.slug}
    })

    refute Repo.get(Pool, pool.id)
    refute Repo.get(OperatorPoolAssignment, operator_assignment.id)
    refute has_element?(view, "#pool-row-#{pool.id}")
    refute has_element?(view, "#pool-delete-dialog")
  end

  test "rejects missing-scope pool mutations", %{scope: scope} do
    pool = pool_fixture(%{slug: "scope-check", name: "Scope Check"})

    assert {:error, %{code: :invalid_request, message: "user scope is required"}} =
             Pools.create_pool(nil, %{slug: "missing-scope", name: "Missing Scope"})

    assert {:error, %{code: :invalid_request, message: "user scope is required"}} =
             Pools.update_pool(nil, pool, %{name: "No Scope"})

    assert {:error, %{code: :invalid_request, message: "user scope is required"}} =
             Pools.delete_archived_pool(nil, pool, pool.slug)

    assert Pools.can_manage_pools?(scope)
  end

  defp open_create_dialog(view) do
    view |> element("#pools-page-create-action") |> render_click()
  end

  defp assert_policy_editor_docs_link(view, dialog_id) do
    assert has_element?(
             view,
             "##{dialog_id}-footer [data-role='policy-editor-docs-link'][href='https://docs.codex-pooler.com/operators/pools/'][target='_blank'][rel='noopener noreferrer'].text-xs",
             "Docs"
           )

    assert has_element?(
             view,
             "##{dialog_id}-docs-link [data-role='policy-editor-docs-icon']"
           )
  end

  defp quota_window_attrs(window_kind, window_minutes, active_limit, used_percent, reset_at) do
    %{
      quota_key: "account",
      window_kind: window_kind,
      window_minutes: window_minutes,
      active_limit: active_limit,
      used_percent: Decimal.new(used_percent),
      reset_at: reset_at,
      source: "codex_response_headers",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh"
    }
  end

  defp insert_timed_usage!(pool, api_key, assignment, timestamp, tokens, cost_micros, latency_ms) do
    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        correlation_id: "pool-window-#{System.unique_integer([:positive])}"
      })
      |> set_request_time!(timestamp)

    attempt =
      request
      |> attempt_fixture(assignment)
      |> set_attempt_time!(timestamp, %{latency_ms: latency_ms})

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      total_tokens: tokens,
      input_tokens: tokens,
      output_tokens: 0,
      estimated_cost_micros: cost_micros,
      settled_cost_micros: cost_micros
    })
    |> set_ledger_time!(timestamp)

    request
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

  defp set_ledger_time!(ledger_entry, timestamp) do
    ledger_entry
    |> Ecto.Changeset.change(%{occurred_at: timestamp, created_at: timestamp})
    |> Repo.update!()
  end

  defp active_identity_fixture(attrs) do
    attrs = Map.new(attrs)

    defaults = %{
      chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
      account_label: "Pool form upstream",
      onboarding_method: "import",
      metadata: %{}
    }

    assert {:ok, identity} =
             IdentityLifecycle.create_upstream_identity(Map.merge(defaults, attrs))

    plan_attrs = Map.take(attrs, [:plan_family, :plan_label])

    assert {:ok, identity} =
             IdentityLifecycle.activate_upstream_identity_with_plan(identity, plan_attrs)

    identity
  end
end
