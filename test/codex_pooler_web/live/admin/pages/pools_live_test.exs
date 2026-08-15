defmodule CodexPoolerWeb.Admin.PoolsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import ExUnit.CaptureLog

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounts
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.Model, as: CatalogModel
  alias CodexPooler.Catalog.SyncRun
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{ModelServingOverride, OperatorPoolAssignment, Pool}
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPoolerWeb.Admin.PoolForm
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_and_log_in_user

  @tag :admin_pool_url_filters
  test "plain Pool route loads the default projection once per LiveView phase", %{
    conn: conn,
    scope: scope
  } do
    # Given
    {:ok, active_pool} =
      Pools.create_pool(scope, %{slug: "url-default-active", name: "URL Default Active"})

    {:ok, disabled_pool} =
      Pools.create_pool(scope, %{slug: "url-default-disabled", name: "URL Default Disabled"})

    assert {:ok, disabled_pool} = Pools.change_pool_status(scope, disabled_pool, "disabled")
    projection_ref = attach_pool_projection_telemetry()

    # When
    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view, activate_histograms?: false)
    projection_events = drain_pool_projection_telemetry(projection_ref)

    # Then
    assert has_element?(view, "#pool_filters_status[value='all']")
    assert has_element?(view, "#pool_filters_traffic_window[value='24h']")
    assert has_element?(view, "#pool-row-#{active_pool.id}")
    assert has_element?(view, "#pool-row-#{disabled_pool.id}")
    assert has_element?(view, "#pool-metric-requests", "Requests 24h")

    assert structural_projection_count(projection_events, view) == 2
    assert traffic_projection_pids(projection_events, view) |> MapSet.size() == 1
    assert traffic_projection_windows(projection_events, view) == MapSet.new([:twenty_four_hours])
  end

  @tag :admin_pool_url_filters
  test "direct non-default Pool URL owns the initial structural and traffic projection", %{
    conn: conn,
    scope: scope
  } do
    # Given
    {:ok, target_pool} =
      Pools.create_pool(scope, %{slug: "url-target-disabled", name: "URL Target Disabled"})

    assert {:ok, target_pool} = Pools.change_pool_status(scope, target_pool, "disabled")

    {:ok, other_pool} =
      Pools.create_pool(scope, %{slug: "url-other-active", name: "URL Other Active"})

    projection_ref = attach_pool_projection_telemetry()

    # When
    {:ok, view, _html} =
      live(conn, ~p"/admin/pools?query=target&status=disabled&traffic_window=7d")

    _ = await_pool_traffic(view, activate_histograms?: false)
    projection_events = drain_pool_projection_telemetry(projection_ref)

    # Then
    assert has_element?(view, "#pool_filters_query[value='target']")
    assert has_element?(view, "#pool_filters_status[value='disabled']")
    assert has_element?(view, "#pool_filters_traffic_window[value='7d']")
    assert has_element?(view, "#pool-row-#{target_pool.id}")
    refute has_element?(view, "#pool-row-#{other_pool.id}")
    assert has_element?(view, "#pool-metric-requests", "Requests 7d")

    assert structural_projection_count(projection_events, view) == 2
    assert traffic_projection_pids(projection_events, view) |> MapSet.size() == 1
    assert traffic_projection_windows(projection_events, view) == MapSet.new([:seven_days])
  end

  @tag :admin_pool_url_filters
  test "editor-only patch with the same normalized filters does not reload Pool projections", %{
    conn: conn,
    scope: scope
  } do
    # Given
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "url-editor-target", name: "URL Editor Target"})

    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    _ = await_pool_traffic(view, activate_histograms?: false)
    projection_ref = attach_pool_projection_telemetry()

    # When
    render_patch(view, ~p"/admin/pools?edit_pool_id=#{pool.id}&step=details")

    _ = :sys.get_state(view.pid)
    projection_events = drain_pool_projection_telemetry(projection_ref)

    # Then
    assert has_element?(view, "#pool-edit-dialog[open]")
    assert has_element?(view, "#pool_edit_id[value='#{pool.id}']")
    assert structural_projection_count(projection_events, view) == 0
    assert traffic_projection_pids(projection_events, view) == MapSet.new()
  end

  @tag :admin_pool_url_filters
  test "filter URL changes prune viewport payload until a fresh visibility event", %{
    conn: conn,
    scope: scope
  } do
    # Given
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "url-viewport-target", name: "URL Viewport Target"})

    %{api_key: api_key} = api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    insert_timed_usage!(pool, api_key, assignment, DateTime.utc_now(), 75, 750_000, 1_500)

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view, activate_histograms?: false)

    render_hook(view, "set_pool_traffic_visibility", %{
      "pool_id" => pool.id,
      "visible" => true
    })

    _ = await_pool_traffic(view, activate_histograms?: false)
    assert has_element?(view, "#pool-row-#{pool.id}-traffic-histogram-plot")
    projection_ref = attach_pool_projection_telemetry()

    # When
    render_patch(view, ~p"/admin/pools?query=no-match")
    _ = :sys.get_state(view.pid)

    # Then
    refute has_element?(view, "#pool-row-#{pool.id}")
    state = :sys.get_state(view.pid).socket.assigns
    refute MapSet.member?(state.pool_traffic_viewport_ids, pool.id)
    refute Map.has_key?(state.pool_traffic_usage.histogram_by_pool_id, pool.id)

    # When: browser Back is represented by the same canonical render-patch.
    render_patch(view, ~p"/admin/pools")
    _ = :sys.get_state(view.pid)
    projection_events = drain_pool_projection_telemetry(projection_ref)

    # Then: the row returns, but its chart payload does not return implicitly.
    assert has_element?(view, "#pool-row-#{pool.id}")
    refute has_element?(view, "#pool-row-#{pool.id}-traffic-histogram-plot")
    refute has_element?(view, "#pool-row-#{pool.id}-traffic-histogram [data-chart-series]")

    refute MapSet.member?(
             :sys.get_state(view.pid).socket.assigns.pool_traffic_viewport_ids,
             pool.id
           )

    assert structural_projection_count(projection_events, view) == 2
    assert traffic_projection_pids(projection_events, view) == MapSet.new()

    # When: the browser hook reports the row visible again.
    render_hook(view, "set_pool_traffic_visibility", %{
      "pool_id" => pool.id,
      "visible" => true
    })

    _ = await_pool_traffic(view, activate_histograms?: false)

    # Then
    assert has_element?(view, "#pool-row-#{pool.id}-traffic-histogram-plot")
  end

  @tag :admin_pool_url_filters
  test "permalink editor defers lifecycle PubSub and flushes once with current URL filters", %{
    conn: conn,
    scope: scope
  } do
    # Given
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "url-deferred-target", name: "URL Deferred Target"})

    {:ok, view, _html} =
      live(conn, ~p"/admin/pools?query=deferred&status=active&traffic_window=7d")

    _ = await_pool_traffic(view, activate_histograms?: false)
    view |> element("#edit-pool-#{pool.id}") |> render_click()

    assert_pool_patch_params(view, %{
      "edit_pool_id" => pool.id,
      "query" => "deferred",
      "status" => "active",
      "step" => "details",
      "traffic_window" => "7d"
    })

    assert {:ok, _event} = Events.broadcast_pools(pool.id, "pool_changed", %{})

    assert {:ok, _event} =
             Events.broadcast_upstreams(pool.id, "upstream_assignment_changed", %{})

    _ = :sys.get_state(view.pid)
    deferred_state = :sys.get_state(view.pid).socket.assigns
    assert deferred_state.pool_traffic_dirty?
    assert is_nil(deferred_state.pool_traffic_refresh_timer)

    render_patch(
      view,
      ~p"/admin/pools?query=no-match&status=active&traffic_window=7d&edit_pool_id=#{pool.id}&step=details"
    )

    assert_pool_patch_params(view, %{
      "edit_pool_id" => pool.id,
      "query" => "no-match",
      "status" => "active",
      "step" => "details",
      "traffic_window" => "7d"
    })

    assert has_element?(view, "#pool-edit-dialog[open]")
    refute has_element?(view, "#pool-row-#{pool.id}")
    projection_ref = attach_pool_projection_telemetry()

    # When
    view |> element("#pool-edit-cancel") |> render_click()

    assert_pool_patch_params(view, %{
      "query" => "no-match",
      "status" => "active",
      "traffic_window" => "7d"
    })

    _ = await_pool_traffic(view, activate_histograms?: false)
    projection_events = drain_pool_projection_telemetry(projection_ref)

    # Then
    refute has_element?(view, "#pool-edit-dialog")
    assert has_element?(view, "#pool_filters_query[value='no-match']")
    assert has_element?(view, "#pool_filters_status[value='active']")
    assert has_element?(view, "#pool_filters_traffic_window[value='7d']")
    refute has_element?(view, "#pool-row-#{pool.id}")
    assert structural_projection_count(projection_events, view) == 1
    assert traffic_projection_pids(projection_events, view) |> MapSet.size() == 1
    assert traffic_projection_windows(projection_events, view) == MapSet.new([:seven_days])
    assert_no_pending_pool_traffic_refresh(view)
  end

  @tag :admin_pool_url_filters
  test "subsequent Pool route filters reload only the projection layer they change", %{
    conn: conn,
    scope: scope
  } do
    # Given
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "url-transition-target", name: "URL Transition Target"})

    assert {:ok, pool} = Pools.change_pool_status(scope, pool, "disabled")
    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view, activate_histograms?: false)
    structural_ref = attach_pool_projection_telemetry()

    # When
    render_patch(view, ~p"/admin/pools?query=target&status=disabled")
    _ = :sys.get_state(view.pid)
    structural_events = drain_pool_projection_telemetry(structural_ref)

    # Then
    assert has_element?(view, "#pool-row-#{pool.id}")
    assert structural_projection_count(structural_events, view) == 1
    assert traffic_projection_pids(structural_events, view) == MapSet.new()

    # Given
    _ = expire_pool_traffic_cooldown(view)
    traffic_ref = attach_pool_projection_telemetry()

    # When
    render_patch(view, ~p"/admin/pools?query=target&status=disabled&traffic_window=7d")
    _ = await_pool_traffic(view, activate_histograms?: false)
    traffic_events = drain_pool_projection_telemetry(traffic_ref)

    # Then
    assert structural_projection_count(traffic_events, view) == 1
    assert traffic_projection_pids(traffic_events, view) |> MapSet.size() == 1
    assert traffic_projection_windows(traffic_events, view) == MapSet.new([:seven_days])
  end

  @tag :admin_pool_url_filters
  test "filter and editor navigation preserve the surviving canonical tuple", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "url-tuple-target", name: "URL Tuple Target"})

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view, activate_histograms?: false)

    view |> element("#edit-pool-#{pool.id}") |> render_click()

    assert_pool_patch_params(view, %{
      "edit_pool_id" => pool.id,
      "step" => "details"
    })

    view |> element("#pool-edit-dialog-tab-upstreams") |> render_click()

    assert_pool_patch_params(view, %{
      "edit_pool_id" => pool.id,
      "step" => "upstreams"
    })

    view
    |> element("#pool-filter-form")
    |> render_change(%{
      "pool_filters" => %{
        "query" => "tuple",
        "status" => "all",
        "traffic_window" => "24h"
      }
    })

    assert_pool_patch_params(view, %{
      "edit_pool_id" => pool.id,
      "query" => "tuple",
      "step" => "upstreams"
    })

    view
    |> element("#pool-status-filter [data-status='disabled']")
    |> render_click()

    assert_pool_patch_params(view, %{
      "edit_pool_id" => pool.id,
      "query" => "tuple",
      "status" => "disabled",
      "step" => "upstreams"
    })

    assert has_element?(view, "#pool-edit-dialog[open]")
    assert has_element?(view, "#pool_edit_id[value='#{pool.id}']")
    refute has_element?(view, "#pool-row-#{pool.id}")

    view
    |> element("#pool-traffic-window-filter [data-window='7d']")
    |> render_click()

    assert_pool_patch_params(view, %{
      "edit_pool_id" => pool.id,
      "query" => "tuple",
      "status" => "disabled",
      "step" => "upstreams",
      "traffic_window" => "7d"
    })

    view |> element("#pool-filter-query-clear") |> render_click()

    assert_pool_patch_params(view, %{
      "edit_pool_id" => pool.id,
      "status" => "disabled",
      "step" => "upstreams",
      "traffic_window" => "7d"
    })

    view |> element("#pool-edit-cancel") |> render_click()

    assert_pool_patch_params(view, %{
      "status" => "disabled",
      "traffic_window" => "7d"
    })

    refute has_element?(view, "#pool-edit-dialog")
  end

  @tag :admin_pool_url_filters
  test "combined filter URL opens an authorized editor hidden from the Pool cards", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "url-hidden-editor", name: "URL Hidden Editor"})

    {:ok, view, _html} =
      live(
        conn,
        ~p"/admin/pools?query=no-match&status=disabled&traffic_window=7d&edit_pool_id=#{pool.id}&step=upstreams"
      )

    assert has_element?(view, "#pool_filters_query[value='no-match']")
    assert has_element?(view, "#pool_filters_status[value='disabled']")
    assert has_element?(view, "#pool_filters_traffic_window[value='7d']")
    refute has_element?(view, "#pool-row-#{pool.id}")
    assert has_element?(view, "#pool-edit-dialog[open]")
    assert has_element?(view, "#pool_edit_id[value='#{pool.id}']")
    assert has_element?(view, "#pool-edit-dialog-tab-upstreams[aria-selected='true']")
  end

  @tag :admin_pool_url_filters
  test "valid editor with an invalid step repairs once to the normalized editor URL", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "url-invalid-step", name: "URL Invalid Step"})

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view, activate_histograms?: false)

    requested_path = "/admin/pools?edit_pool_id=#{pool.id}&step=bogus&unknown=drop"
    render_patch(view, requested_path)
    assert_patch(view, requested_path)

    assert_pool_patch_params(view, %{
      "edit_pool_id" => pool.id,
      "step" => "details"
    })

    refute_patched(view)
    assert has_element?(view, "#pool-edit-dialog[open]")
    assert has_element?(view, "#pool-edit-dialog-tab-details[aria-selected='true']")
  end

  @tag :admin_pool_url_filters
  test "malformed filters and unauthorized editor repair once without projection reload", %{
    scope: scope
  } do
    {:ok, unauthorized_pool} =
      Pools.create_pool(scope, %{slug: "url-unauthorized-editor", name: "URL Unauthorized Editor"})

    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "url-repair-admin@example.com",
        "password_change_required" => "false"
      })

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, view, _html} = live(admin_conn, ~p"/admin/pools")
    _ = await_pool_traffic(view, activate_histograms?: false)
    projection_ref = attach_pool_projection_telemetry()

    requested_path =
      "/admin/pools?status[bad]=1&traffic_window=bogus&query[]=x&edit_pool_id=#{unauthorized_pool.id}&step=bogus&unknown=drop"

    render_patch(view, requested_path)
    assert_patch(view, requested_path)

    assert_pool_patch_params(view, %{})
    refute_patched(view)
    _ = :sys.get_state(view.pid)

    projection_events = drain_pool_projection_telemetry(projection_ref)

    assert has_element?(view, "#pool_filters_query[value='']")
    assert has_element?(view, "#pool_filters_status[value='all']")
    assert has_element?(view, "#pool_filters_traffic_window[value='24h']")
    refute has_element?(view, "#pool-edit-dialog")
    assert structural_projection_count(projection_events, view) == 0
    assert traffic_projection_pids(projection_events, view) == MapSet.new()

    stable_ref = attach_pool_projection_telemetry()
    render_patch(view, ~p"/admin/pools")
    assert_patch(view, ~p"/admin/pools")
    _ = :sys.get_state(view.pid)

    stable_events = drain_pool_projection_telemetry(stable_ref)

    refute_patched(view)
    assert structural_projection_count(stable_events, view) == 0
    assert traffic_projection_pids(stable_events, view) == MapSet.new()
  end

  @tag :admin_pool_url_filters
  test "pool editor permalink opens the requested Pool on the Upstreams step and clears on cancel",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "permalink-upstreams", name: "Permalink Upstreams"})

    %{identity: identity} = upstream_assignment_fixture(pool)

    {:ok, view, _html} =
      live(conn, ~p"/admin/pools?edit_pool_id=#{pool.id}&step=upstreams")

    assert has_element?(view, "#pool-edit-dialog[open]")
    assert has_element?(view, "#pool-edit-dialog-tab-upstreams[aria-selected='true']")
    assert has_element?(view, "#pool-edit-dialog-section-upstreams[role='tabpanel']")
    assert has_element?(view, "#pool_edit_id[value='#{pool.id}']")

    assert has_element?(
             view,
             "#pool-edit-upstream-assignment-options input[value='#{identity.id}'][checked]"
           )

    view |> element("#pool-edit-cancel") |> render_click()

    assert_patch(view, ~p"/admin/pools")
    refute has_element?(view, "#pool-edit-dialog")
  end

  @tag :admin_pool_url_filters
  test "Pool edit actions and wizard steps keep the editor state in the URL", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "permalink-actions", name: "Permalink Actions"})

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    view |> element("#edit-pool-#{pool.id}") |> render_click()

    assert_patch(view, ~p"/admin/pools?edit_pool_id=#{pool.id}&step=details")
    assert has_element?(view, "#pool-edit-dialog-tab-details[aria-selected='true']")

    view |> element("#pool-edit-dialog-tab-upstreams") |> render_click()

    assert_patch(view, ~p"/admin/pools?edit_pool_id=#{pool.id}&step=upstreams")
    assert has_element?(view, "#pool-edit-dialog-tab-upstreams[aria-selected='true']")
  end

  @tag :admin_pool_url_filters
  test "Pool editor permalinks are rejected outside the management scope", %{
    scope: scope
  } do
    {:ok, assigned_pool} =
      Pools.create_pool(scope, %{slug: "permalink-assigned", name: "Permalink Assigned"})

    {:ok, hidden_pool} =
      Pools.create_pool(scope, %{slug: "permalink-hidden", name: "Permalink Hidden"})

    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "permalink-assigned-admin@example.com",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: scope.user.id)

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)

    {:ok, assigned_view, _html} =
      live(
        admin_conn,
        ~p"/admin/pools?edit_pool_id=#{assigned_pool.id}&step=upstreams"
      )

    refute has_element?(assigned_view, "#pool-edit-dialog")

    {:ok, hidden_view, _html} =
      live(admin_conn, ~p"/admin/pools?edit_pool_id=#{hidden_pool.id}&step=upstreams")

    refute has_element?(hidden_view, "#pool-edit-dialog")
  end

  test "renders empty pools guidance without a duplicate reset action", %{conn: conn} do
    Repo.delete_all(Pool)

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

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
        _ = await_pool_traffic(view)

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
    _ = await_pool_traffic(view)

    assert has_element?(view, "#pool-row-#{assigned_pool.id}")
    refute html =~ hidden_pool.name
    refute html =~ hidden_pool.slug
    refute has_element?(view, "#pool-row-#{hidden_pool.id}")
    refute has_element?(view, "#pools-page-create-action")
    refute has_element?(view, "#pool-create-dialog")
    refute has_element?(view, "#delete-pool-#{assigned_pool.id}")

    state = :sys.get_state(view.pid)
    refute state.socket.assigns.can_manage_pools?
    assert Enum.map(state.socket.assigns.pools, & &1.pool.id) == [assigned_pool.id]
  end

  test "assigned admin receives a Models-only Pool action", %{scope: scope} do
    {:ok, assigned_pool} =
      Pools.create_pool(scope, %{slug: "models-only-assigned", name: "Models Only Assigned"})

    %{assignment: assignment} = upstream_assignment_fixture(assigned_pool)

    model_fixture(assigned_pool, %{
      exposed_model_id: "gpt-models-only-assigned",
      metadata: %{"source_assignment_ids" => [assignment.id]}
    })

    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "models-only-assigned-admin@example.com",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: scope.user.id)

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, view, _html} = live(admin_conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    assert has_element?(view, "#models-pool-#{assigned_pool.id}")
    refute has_element?(view, "#edit-pool-#{assigned_pool.id}")

    view |> element("#models-pool-#{assigned_pool.id}") |> render_click()
    _ = render_async(view)

    assert has_element?(view, "#pool-model-serving-dialog[open]")
    assert has_element?(view, "#pool-model-serving-dialog-tab-models[aria-selected='true']")
    assert has_element?(view, "#pool-model-serving-form")
    refute has_element?(view, "#pool-model-serving-dialog-tab-details")
    refute has_element?(view, "#pool-edit-form")
    refute has_element?(view, "#pool_edit_name")
    refute has_element?(view, "#pool_edit_status")

    view
    |> element("#pool-model-serving-form")
    |> render_submit(%{
      "pool_model_serving" => %{
        "revision" => model_serving_revision(view),
        "rows" => %{
          "0" => %{
            "exposed_model_id" => "gpt-models-only-assigned",
            "mode" => "lite"
          }
        }
      }
    })

    _ = render_async(view)

    assert %ModelServingOverride{mode: "lite"} =
             Repo.get_by!(ModelServingOverride,
               pool_id: assigned_pool.id,
               exposed_model_id: "gpt-models-only-assigned"
             )

    assert %AuditEvent{
             actor_user_id: actor_user_id,
             pool_id: pool_id,
             action: "pool.model_serving_modes_update",
             target_id: target_id
           } =
             Repo.one!(
               from event in AuditEvent,
                 where:
                   event.action == "pool.model_serving_modes_update" and
                     event.pool_id == ^assigned_pool.id
             )

    assert actor_user_id == admin.id
    assert pool_id == assigned_pool.id
    assert target_id == assigned_pool.id

    view |> element("#pool-model-serving-cancel") |> render_click()

    html =
      render_click(view, "edit_pool", %{"id" => assigned_pool.id})

    assert html =~ "the actor role cannot perform this capability in the requested scope"
    refute has_element?(view, "#pool-edit-dialog")
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
    _ = await_pool_traffic(view)

    assert has_element?(view, "#pool-empty-state", "No assigned Pools")

    assert has_element?(
             view,
             "#pool-empty-state",
             "Ask an instance owner to assign you to a Pool before managing Pool-scoped resources."
           )

    refute html =~ hidden_pool.name
    refute has_element?(view, "#pools-page-create-action")
    refute has_element?(view, "#pool-empty-create-action")
    refute has_element?(view, "#models-pool-#{hidden_pool.id}")
  end

  test "compat flag icons disclose one inline panel and toggle image generation", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "compat-panel", name: "Compat Panel Pool"})

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    refute has_element?(view, "#pool-row-#{pool.id}-compat-panel")

    view |> element("#pool-row-#{pool.id}-compat-compression") |> render_click()

    assert has_element?(view, "#pool-row-#{pool.id}-compat-panel", "Request compression")
    assert has_element?(view, "#pool-row-#{pool.id}-compat-compression-toggle")
    refute has_element?(view, "#pool-row-#{pool.id}-compat-compression-toggle[checked]")

    html = view |> element("#pool-row-#{pool.id}-compat-compression-toggle") |> render_click()

    assert html =~ "Request compression enabled on Compat Panel Pool"
    assert PoolRouting.get_routing_settings(pool.id).request_compression_enabled
    assert has_element?(view, "#pool-row-#{pool.id}-compat-compression-toggle[checked]")
    assert has_element?(view, "#pool-row-#{pool.id}-compat-panel", "Request compression")

    view |> element("#pool-row-#{pool.id}-compat-v1") |> render_click()
    assert has_element?(view, "#pool-row-#{pool.id}-compat-panel", "/v1 compatibility")
    refute has_element?(view, ~s([data-role="pool-compat-experimental"]))

    assert has_element?(
             view,
             ~s(#pool-row-#{pool.id}-compat-v1-docs-link[href="https://docs.codex-pooler.com/operators/pools/#compatibility"])
           )

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-compat-v1 + #pool-row-#{pool.id}-compat-compression + #pool-row-#{pool.id}-compat-image-generation"
           )

    refute has_element?(view, "#pool-row-#{pool.id}-compat-ws-bridge")

    view |> element("#pool-row-#{pool.id}-compat-image-generation") |> render_click()

    assert has_element?(view, "#pool-row-#{pool.id}-compat-panel", "Allow Image Generation")
    assert has_element?(view, "#pool-row-#{pool.id}-compat-image-generation-toggle[checked]")

    html =
      view |> element("#pool-row-#{pool.id}-compat-image-generation-toggle") |> render_click()

    assert html =~ "Allow Image Generation disabled on Compat Panel Pool"
    refute PoolRouting.get_routing_settings(pool.id).allow_image_generation
    refute has_element?(view, "#pool-row-#{pool.id}-compat-image-generation-toggle[checked]")

    view |> element("#pool-row-#{pool.id}-compat-image-generation") |> render_click()
    refute has_element?(view, "#pool-row-#{pool.id}-compat-panel")
    _ = await_pool_traffic(view)
  end

  test "ignores compat toggles outside the whitelist", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "compat-guard", name: "Compat Guard Pool"})

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    html =
      render_click(view, "toggle_pool_compat_flag", %{
        "pool-id" => pool.id,
        "flag" => "sticky_http_sessions"
      })

    assert html =~ "unsupported pool option"
    assert PoolRouting.get_routing_settings(pool.id) == nil

    render_click(view, "toggle_pool_compat_panel", %{
      "pool-id" => pool.id,
      "flag" => "sticky_http_sessions"
    })

    refute has_element?(view, "#pool-row-#{pool.id}-compat-panel")
  end

  test "read-only admins see compat state without toggle controls", %{scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "compat-readonly", name: "Compat Readonly Pool"})

    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "compat-readonly-admin@example.com",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, pool, created_by_user_id: scope.user.id)

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, view, _html} = live(admin_conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    view |> element("#pool-row-#{pool.id}-compat-v1") |> render_click()

    assert has_element?(view, "#pool-row-#{pool.id}-compat-panel", "/v1 compatibility")
    assert has_element?(view, "#pool-row-#{pool.id}-compat-panel", "Enabled")
    refute has_element?(view, "#pool-row-#{pool.id}-compat-v1-toggle")

    html =
      render_click(view, "toggle_pool_compat_flag", %{
        "pool-id" => pool.id,
        "flag" => "v1_compatibility_enabled"
      })

    assert html =~ "Pool management is not available for this session"
    assert PoolRouting.get_routing_settings(pool.id) == nil
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
    _ = await_pool_traffic(view)

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
             "#pool-row-#{pool.id} p#pool-row-#{pool.id}-routing-strategy"
           )

    assert render(view) =~
             ~r/id="pool-row-#{pool.id}-routing-strategy"[^>]*class="truncate text-xs leading-4 text-base-content\/55"/

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
               "#pool-row-#{pool.id} > footer [data-role='#{role}'] dt a[href='#{href}'].hover\\:bg-primary\\/5",
               label
             )

      assert has_element?(
               view,
               "#pool-row-#{pool.id} > footer [data-role='#{role}'] dt .pointer-events-none",
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
    _ = await_pool_traffic(view)

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
    _ = await_pool_traffic(view)

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

  @tag :lazy_pool_histograms
  test "loads Pool histograms only after a card becomes eligible", %{
    scope: scope
  } do
    # Given
    {:ok, target_pool} =
      Pools.create_pool(scope, %{slug: "lazy-target", name: "Lazy Target"})

    {:ok, inactive_pool} =
      Pools.create_pool(scope, %{slug: "lazy-inactive", name: "Lazy Inactive"})

    {:ok, unassigned_pool} =
      Pools.create_pool(scope, %{slug: "lazy-unassigned", name: "Lazy Unassigned"})

    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "lazy-pool-admin@example.com",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, target_pool, created_by_user_id: scope.user.id)
    operator_pool_assignment_fixture(admin, inactive_pool, created_by_user_id: scope.user.id)

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)

    %{api_key: api_key} = api_key_fixture(target_pool)
    %{assignment: assignment} = upstream_assignment_fixture(target_pool)
    %{api_key: inactive_api_key} = api_key_fixture(inactive_pool)
    %{assignment: inactive_assignment} = upstream_assignment_fixture(inactive_pool)

    insert_timed_usage!(
      target_pool,
      api_key,
      assignment,
      DateTime.utc_now(),
      100,
      1_000_000,
      2_000
    )

    insert_timed_usage!(
      inactive_pool,
      inactive_api_key,
      inactive_assignment,
      DateTime.utc_now(),
      50,
      500_000,
      1_000
    )

    {:ok, view, _html} = live(admin_conn, ~p"/admin/pools")
    _ = await_pool_traffic(view, activate_histograms?: false)

    # Then: the initial summary read leaves both cards inactive and ships no chart payload.
    for pool <- [target_pool, inactive_pool] do
      assert has_element?(
               view,
               "#pool-row-#{pool.id}-activity[phx-hook='PoolTrafficVisibility'][data-pool-id='#{pool.id}']"
             )

      assert has_element?(
               view,
               "#pool-row-#{pool.id}-traffic-histogram[data-role='pool-traffic-histogram'].pool-token-histogram > .pool-token-histogram-header"
             )

      assert has_element?(
               view,
               "#pool-row-#{pool.id}-traffic-histogram > .pool-token-histogram-header #pool-row-#{pool.id}-traffic-histogram-total.pool-token-histogram-total"
             )

      refute has_element?(view, "#pool-row-#{pool.id}-traffic-histogram-plot")
      refute has_element?(view, "#pool-row-#{pool.id}-traffic-histogram [data-chart-series]")
      refute has_element?(view, "#pool-row-#{pool.id}-traffic-histogram details")
      refute has_element?(view, "#pool-row-#{pool.id}-traffic-histogram summary")

      refute has_element?(
               view,
               "#pool-row-#{pool.id}-traffic-histogram [data-role='pool-traffic-disclosure-cue']"
             )

      refute render(view) =~ "Open to load"
    end

    render_hook(view, "set_pool_traffic_visibility", %{
      "pool_id" => unassigned_pool.id,
      "visible" => true
    })

    refute MapSet.member?(
             :sys.get_state(view.pid).socket.assigns.pool_traffic_viewport_ids,
             unassigned_pool.id
           )

    refute has_element?(view, "#pool-row-#{unassigned_pool.id}")

    render_hook(view, "set_pool_traffic_visibility", %{
      "pool_id" => target_pool.id,
      "reason" => "disclosure",
      "visible" => true
    })

    refute MapSet.member?(
             :sys.get_state(view.pid).socket.assigns.pool_traffic_viewport_ids,
             target_pool.id
           )

    # When
    render_hook(view, "set_pool_traffic_visibility", %{
      "pool_id" => target_pool.id,
      "visible" => true
    })

    _ = await_pool_traffic(view, activate_histograms?: false)

    # Then
    assert has_element?(
             view,
             "#pool-row-#{target_pool.id}-traffic-histogram[data-role='pool-traffic-histogram'].pool-token-histogram > .pool-token-histogram-header #pool-row-#{target_pool.id}-traffic-histogram-total"
           )

    assert has_element?(
             view,
             "#pool-row-#{target_pool.id}-traffic-histogram-plot[phx-hook='ApexTimeSeriesChart'][phx-update='ignore'][data-chart-series]"
           )

    refute has_element?(view, "#pool-row-#{inactive_pool.id}-traffic-histogram-plot")

    refute has_element?(
             view,
             "#pool-row-#{inactive_pool.id}-traffic-histogram [data-chart-series]"
           )

    # When: a ready card leaves the viewport.
    render_hook(view, "set_pool_traffic_visibility", %{
      "pool_id" => target_pool.id,
      "visible" => false
    })

    # Then: its payload is pruned before the follow-up read completes.
    refute has_element?(view, "#pool-row-#{target_pool.id}-traffic-histogram-plot")
    refute has_element?(view, "#pool-row-#{target_pool.id}-traffic-histogram [data-chart-series]")

    _ = await_pool_traffic(view, activate_histograms?: false)
    state = :sys.get_state(view.pid)
    refute MapSet.member?(state.socket.assigns.pool_traffic_viewport_ids, target_pool.id)

    refute Map.has_key?(
             state.socket.assigns.pool_traffic_usage.histogram_by_pool_id,
             target_pool.id
           )

    render_hook(view, "set_pool_traffic_visibility", %{
      "pool_id" => target_pool.id,
      "visible" => true
    })

    _ = await_pool_traffic(view, activate_histograms?: false)

    # When: another active card is later hidden by the structural filter.
    render_hook(view, "set_pool_traffic_visibility", %{
      "pool_id" => inactive_pool.id,
      "visible" => true
    })

    _ = await_pool_traffic(view, activate_histograms?: false)

    view
    |> element("#pool-filter-form")
    |> render_change(%{
      "pool_filters" => %{"query" => "Lazy Target", "status" => "all"}
    })

    # Then: rendering state is pruned synchronously, but both authorized summaries
    # still contribute to the top strip.
    state = :sys.get_state(view.pid)
    refute MapSet.member?(state.socket.assigns.pool_traffic_viewport_ids, inactive_pool.id)
    refute has_element?(view, "#pool-row-#{inactive_pool.id}")
    assert has_element?(view, "#pool-metric-requests", "2")
  end

  @tag :lazy_pool_histograms
  @tag :admin_pool_url_filters
  test "viewport leave prunes payload and rapid eligibility changes coalesce", %{
    conn: conn,
    scope: scope
  } do
    # Given
    {:ok, pool} = Pools.create_pool(scope, %{slug: "lazy-collapse", name: "Lazy Collapse"})
    %{api_key: api_key} = api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    insert_timed_usage!(pool, api_key, assignment, DateTime.utc_now(), 75, 750_000, 1_500)

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view, activate_histograms?: false)
    _initial_cooldown_token = expire_pool_traffic_cooldown(view)

    holder_ref = make_ref()
    advisory_holder = hold_pool_traffic_advisory_lock(scope.user.id, holder_ref)
    assert_receive {^holder_ref, :lock_held, holder_pid}, 1_000

    # When: another PostgreSQL session owns the operator gate while viewport
    # eligibility changes.
    render_hook(view, "set_pool_traffic_visibility", %{
      "pool_id" => pool.id,
      "visible" => true
    })

    _ = render_async(view, 2_000)

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-traffic-histogram [data-role='pool-traffic-loading-placeholder'][role='status']",
             "Loading traffic"
           )

    assert has_element?(
             view,
             "#pool-row-#{pool.id}-traffic-histogram [data-role='pool-traffic-loading-icon'] .admin-loading-icon"
           )

    render_hook(view, "set_pool_traffic_visibility", %{
      "pool_id" => pool.id,
      "visible" => false
    })

    state = :sys.get_state(view.pid)

    # Then: the existing lane represents every extra request with one rerun flag.
    refute state.socket.assigns.pool_traffic_running?
    assert state.socket.assigns.pool_traffic_rerun?
    assert is_reference(state.socket.assigns.pool_traffic_cooldown_timer)

    send(holder_pid, {holder_ref, :release})
    assert :ok = Task.await(advisory_holder, 2_000)

    _ = await_pool_traffic(view, activate_histograms?: false)

    refute has_element?(view, "#pool-row-#{pool.id}-traffic-histogram-plot")
    refute has_element?(view, "#pool-row-#{pool.id}-traffic-histogram [data-chart-series]")

    # When: the card re-enters the viewport.
    render_hook(view, "set_pool_traffic_visibility", %{
      "pool_id" => pool.id,
      "visible" => true
    })

    _ = await_pool_traffic(view, activate_histograms?: false)

    # Then
    assert has_element?(
             view,
             "#pool-row-#{pool.id}-traffic-histogram-plot[phx-hook='ApexTimeSeriesChart'][phx-update='ignore']"
           )
  end

  @tag :lazy_pool_histograms
  test "completed visibility loads observe a server cooldown and coalesce the latest eligible set",
       %{
         conn: conn,
         scope: scope
       } do
    # Given
    {:ok, first_pool} =
      Pools.create_pool(scope, %{slug: "cooldown-first", name: "Cooldown First"})

    {:ok, second_pool} =
      Pools.create_pool(scope, %{slug: "cooldown-second", name: "Cooldown Second"})

    %{api_key: first_api_key} = api_key_fixture(first_pool)
    %{assignment: first_assignment} = upstream_assignment_fixture(first_pool)
    %{api_key: second_api_key} = api_key_fixture(second_pool)
    %{assignment: second_assignment} = upstream_assignment_fixture(second_pool)

    insert_timed_usage!(
      first_pool,
      first_api_key,
      first_assignment,
      DateTime.utc_now(),
      75,
      750_000,
      1_500
    )

    insert_timed_usage!(
      second_pool,
      second_api_key,
      second_assignment,
      DateTime.utc_now(),
      50,
      500_000,
      1_000
    )

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view, activate_histograms?: false)
    _initial_cooldown_token = expire_pool_traffic_cooldown(view)

    test_pid = self()
    handler_id = {__MODULE__, :pool_traffic_cooldown, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if pool_traffic_projection_query?(metadata) and self() != view.pid do
            send(test_pid, {handler_id, :query, self()})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    render_hook(view, "set_pool_traffic_visibility", %{
      "pool_id" => first_pool.id,
      "visible" => true
    })

    _ = await_pool_traffic(view, activate_histograms?: false)
    first_query_pids = drain_lazy_query_pids(handler_id, MapSet.new())
    assert MapSet.size(first_query_pids) == 1

    assert has_element?(view, "#pool-row-#{first_pool.id}-traffic-histogram-plot")

    completed_state = :sys.get_state(view.pid).socket.assigns
    refute completed_state.pool_traffic_running?
    assert is_reference(completed_state.pool_traffic_cooldown_timer)
    completed_cooldown_token = completed_state.pool_traffic_cooldown_token

    # When: valid visibility hints alternate after the completed query while
    # the server-side cooldown is active. The final viewport state keeps only
    # the second Pool eligible.
    for visible <- [false, true, false, true, false] do
      render_hook(view, "set_pool_traffic_visibility", %{
        "pool_id" => first_pool.id,
        "visible" => visible
      })
    end

    for visible <- [true, false, true] do
      render_hook(view, "set_pool_traffic_visibility", %{
        "pool_id" => second_pool.id,
        "visible" => visible
      })
    end

    # Then: pruning is immediate, no query starts inside the cooldown, and all
    # hints collapse into one pending reload of the latest eligible set.
    refute has_element?(view, "#pool-row-#{first_pool.id}-traffic-histogram-plot")
    refute has_element?(view, "#pool-row-#{first_pool.id}-traffic-histogram [data-chart-series]")

    cooldown_state = :sys.get_state(view.pid).socket.assigns
    refute cooldown_state.pool_traffic_running?
    assert cooldown_state.pool_traffic_rerun?
    assert cooldown_state.pool_traffic_viewport_ids == MapSet.new([second_pool.id])
    assert drain_lazy_query_pids(handler_id, first_query_pids) == first_query_pids
    refute_receive {^handler_id, :query, _query_pid}, 0

    assert completed_cooldown_token == expire_pool_traffic_cooldown(view)
    assert_receive {^handler_id, :query, followup_query_pid}, 1_000
    _ = await_pool_traffic(view, activate_histograms?: false)

    completed_query_pids =
      drain_lazy_query_pids(handler_id, MapSet.put(first_query_pids, followup_query_pid))

    assert MapSet.size(completed_query_pids) == 2

    assert completed_query_pids
           |> MapSet.difference(first_query_pids)
           |> MapSet.size() == 1

    assert has_element?(view, "#pool-row-#{second_pool.id}-traffic-histogram-plot")
    refute has_element?(view, "#pool-row-#{first_pool.id}-traffic-histogram-plot")

    # A stale, already-consumed token cannot interrupt the next cooldown or
    # launch another query.
    next_cooldown_state = :sys.get_state(view.pid).socket.assigns
    next_cooldown_token = next_cooldown_state.pool_traffic_cooldown_token
    assert next_cooldown_token != completed_cooldown_token

    send(view.pid, {:pool_traffic_cooldown_elapsed, completed_cooldown_token})
    stale_token_state = :sys.get_state(view.pid).socket.assigns

    assert stale_token_state.pool_traffic_cooldown_token == next_cooldown_token
    refute stale_token_state.pool_traffic_running?
    refute stale_token_state.pool_traffic_rerun?
    assert drain_lazy_query_pids(handler_id, completed_query_pids) == completed_query_pids
  end

  @tag :shared_pool_traffic_gate
  @tag :admin_pool_url_filters
  test "same operator sessions share one Pool traffic projection lane", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    # Given: two authenticated LiveViews for the same operator have completed
    # their initial structural traffic load.
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "shared-gate-pool", name: "Shared Gate Pool"})

    %{api_key: api_key} = api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    insert_timed_usage!(pool, api_key, assignment, DateTime.utc_now(), 75, 750_000, 1_500)

    second_conn = log_in_user(build_conn(), user, get_session(conn, :user_token))

    {:ok, first_view, _html} = live(conn, ~p"/admin/pools")
    {:ok, second_view, _html} = live(second_conn, ~p"/admin/pools")

    _ = await_pool_traffic(first_view, activate_histograms?: false)
    _ = await_pool_traffic(second_view, activate_histograms?: false)
    _ = expire_pool_traffic_cooldown(first_view)
    _ = expire_pool_traffic_cooldown(second_view)

    test_pid = self()
    handler_id = {__MODULE__, :shared_pool_traffic_gate, System.unique_integer([:positive])}
    first_projection = :atomics.new(1, signed: false)

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if pool_traffic_projection_query?(metadata) and
               self() not in [first_view.pid, second_view.pid] do
            send(test_pid, {handler_id, :query, self()})

            if :atomics.compare_exchange(first_projection, 1, 0, 1) == 0 do
              receive do
                {^handler_id, :release} -> :ok
              after
                2_000 -> :ok
              end
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # When: the first session holds the expensive projection and the second
    # session requests the same operator-scoped projection.
    render_hook(first_view, "set_pool_traffic_visibility", %{
      "pool_id" => pool.id,
      "visible" => true
    })

    assert_receive {^handler_id, :query, first_query_pid}, 1_000

    render_hook(second_view, "set_pool_traffic_visibility", %{
      "pool_id" => pool.id,
      "visible" => true
    })

    _ = render_async(second_view, 2_000)

    # Then: only the first session reaches the expensive Repo boundary. The
    # denied session settles through the shared gate without entering it.
    query_pids = drain_lazy_query_pids(handler_id, MapSet.new([first_query_pid]))
    assert query_pids == MapSet.new([first_query_pid])

    :ok = :telemetry.detach(handler_id)
    send(first_query_pid, {handler_id, :release})
    _ = await_pool_traffic(first_view, activate_histograms?: false)
    _ = expire_pool_traffic_cooldown(second_view)
    _ = await_pool_traffic(second_view, activate_histograms?: false)
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
    _ = await_pool_traffic(view)

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

    _ = await_pool_traffic(view)

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

  test "paints structural rows instantly and fills traffic metrics asynchronously", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "async-traffic", name: "Async Traffic Pool"})
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
      output_tokens: 40,
      estimated_cost_micros: 1_000_000,
      settled_cost_micros: 500_000
    })

    {:ok, view, html} = live(conn, ~p"/admin/pools")

    assert html =~ "Async Traffic Pool"

    [_, requests_card] = String.split(html, ~s(id="pool-metric-requests"), parts: 2)

    [requests_card | _] =
      String.split(requests_card, ~s(id="pool-metric-tokens-per-sec"), parts: 2)

    assert requests_card =~ "…"

    _ = await_pool_traffic(view)

    assert has_element?(view, "#pool-metric-requests", "1")
    assert has_element?(view, "#pool-metric-tokens-per-sec", "50")
    assert has_element?(view, "#pool-row-#{pool.id}-request-throughput", "1 / 50")
    refute has_element?(view, "#pool-metric-requests", "…")
  end

  test "async traffic merges leave an open dialog and its form intact", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/pools")

    open_create_dialog(view)
    assert has_element?(view, "#pool-create-dialog[open]")

    late_identity = active_identity_fixture(account_label: "Mid-merge account")

    _ = await_pool_traffic(view)

    assert has_element?(view, "#pool-create-dialog[open]")
    assert has_element?(view, "#pool-create-form")

    refute has_element?(
             view,
             "#pool-create-upstream-identity-options-card-#{late_identity.id}"
           )

    refute :sys.get_state(view.pid).socket.assigns.pool_traffic_loading?

    view |> element("#pool-create-cancel") |> render_click()
    refute has_element?(view, "#pool-create-dialog")
    _ = await_pool_traffic(view)
  end

  @tag :admin_pool_url_filters
  test "rapid traffic window URL changes reject a stale completion and settle on 24h", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "window-race", name: "Window Race Pool"})
    %{api_key: api_key} = api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    recent_at =
      DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:microsecond)

    insert_timed_usage!(pool, api_key, assignment, recent_at, 100, 1_000_000, 2_000)

    insert_timed_usage!(
      pool,
      api_key,
      assignment,
      DateTime.add(recent_at, -5, :day),
      25,
      500_000,
      500
    )

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)
    _ = expire_pool_traffic_cooldown(view)

    test_pid = self()
    projection_ref = make_ref()
    handler_id = {__MODULE__, :stale_pool_window, projection_ref}
    first_seven_day_projection = :atomics.new(1, signed: false)

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            query_pid = self()
            send(test_pid, {projection_ref, query_pid, metadata})

            if traffic_projection_window(metadata) == :seven_days and
                 :atomics.compare_exchange(first_seven_day_projection, 1, 0, 1) == :ok do
              send(test_pid, {handler_id, :held, query_pid})

              receive do
                {^handler_id, :release} -> :ok
              after
                5_000 -> flunk("timed out waiting to release stale seven-day projection")
              end
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    render_patch(view, ~p"/admin/pools?traffic_window=7d")
    assert_receive {^handler_id, :held, seven_day_query_pid}, 2_000

    {_proxy_ref, _proxy_topic, proxy_pid} = view.proxy
    view_pid = view.pid
    :erlang.trace(proxy_pid, true, [:send])

    patch_task =
      Task.async(fn ->
        render_patch(view, ~p"/admin/pools")
      end)

    assert_receive {:trace, ^proxy_pid, :send,
                    %Phoenix.Socket.Message{
                      event: "live_patch",
                      payload: %{"url" => "http://www.example.com/admin/pools"}
                    }, ^view_pid},
                   2_000

    :erlang.trace(proxy_pid, false, [:send])
    seven_day_monitor = Process.monitor(seven_day_query_pid)
    send(seven_day_query_pid, {handler_id, :release})
    _ = Task.await(patch_task, 2_000)
    assert_receive {:DOWN, ^seven_day_monitor, :process, ^seven_day_query_pid, :normal}, 2_000

    _ = render_async(view, 2_000)

    stale_completion_state = :sys.get_state(view.pid).socket.assigns
    assert stale_completion_state.pool_filters["traffic_window"] == "24h"
    refute stale_completion_state.pool_traffic_running?
    assert stale_completion_state.pool_traffic_rerun?
    assert is_reference(stale_completion_state.pool_traffic_cooldown_timer)
    assert is_nil(stale_completion_state.pool_traffic_usage)
    assert has_element?(view, "#pool-metric-requests", "Requests 24h")
    assert has_element?(view, "#pool-metric-requests", "…")

    _ = await_pool_traffic(view)
    projection_events = drain_pool_projection_telemetry(projection_ref)

    assert has_element?(view, "#pool-metric-requests", "Requests 24h")
    assert has_element?(view, "#pool-metric-requests", "1")
    assert has_element?(view, "#pool-row-#{pool.id}-request-throughput", "1 / 50")
    refute has_element?(view, "#pool-metric-requests", "…")

    assert traffic_projection_windows(projection_events, view) ==
             MapSet.new([:twenty_four_hours, :seven_days])
  end

  test "renders the pools shell and protected controls for authenticated admins", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "admin-pools", name: "Admin Pools"})
    expected_pool_total = Repo.aggregate(Pool, :count, :id) |> Integer.to_string()

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

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
             "#pool-row-#{pool.id} p#pool-row-#{pool.id}-routing-strategy"
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
    assert has_element?(view, "#pool-create-dialog-header", "Create Pool")
    refute has_element?(view, "#pool-create-dialog-header", "Pool lifecycle")
    assert_policy_editor_docs_link(view, "pool-create-dialog")
    assert has_element?(view, "#pool-create-dialog-tabs[role='tablist']")
    assert has_element?(view, "#pool-create-dialog-tab-details[aria-selected='true']")
    assert has_element?(view, "#pool-create-dialog-tab-routing[role='tab']")
    refute has_element?(view, "#pool-create-dialog-tab-models")
    refute has_element?(view, "#pool-create-dialog-section-models")
    refute has_element?(view, "#pool-model-serving-form")

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

    render_click(view, "pool_wizard_step", %{"step" => "models"})
    assert has_element?(view, "#pool-create-dialog-tab-details[aria-selected='true']")

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
             "Strategy and fan-out size used for runtime requests"
           )

    assert has_element?(
             view,
             "#pool-create-routing-controls",
             "Identity-aware routing behavior"
           )

    assert has_element?(
             view,
             "#pool-create-routing-controls",
             "Sends requests that share a prompt cache to the same upstream."
           )

    assert has_element?(
             view,
             "#pool-create-routing-controls",
             "Sends requests that share a prompt cache to the same upstream."
           )

    assert has_element?(
             view,
             "#pool-create-routing-controls",
             "Optional client surfaces"
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

    assert has_element?(view, "#pool_routing_strategy", "Bridge ring")

    assert has_element?(
             view,
             "#pool-create-routing-controls",
             "Stable rendezvous ordering, within continuity and quota."
           )

    refute has_element?(
             view,
             "#pool-create-routing-controls",
             "Balances upstreams by continuity, cache locality, and quota evidence."
           )

    assert has_element?(
             view,
             "#pool_routing_strategy[role='radiogroup'][aria-label='Routing strategy']"
           )

    assert has_element?(
             view,
             "#pool_routing_strategy_bridge_ring.strategy-radio.strategy-bridge[type='radio'][value='bridge_ring'][checked]"
           )

    assert has_element?(
             view,
             "#pool_routing_strategy_deterministic_rotation.strategy-radio[type='radio'][value='deterministic_rotation']"
           )

    assert has_element?(
             view,
             "#pool_routing_strategy_least_recent_success.strategy-radio[type='radio'][value='least_recent_success']"
           )

    assert has_element?(
             view,
             "#pool_routing_strategy_quota_first.strategy-radio[type='radio'][value='quota_first']"
           )

    assert has_element?(view, "#pool_bridge_ring_size[type='number'][value='3']")
    assert has_element?(view, "#pool_routing_strategy", "Deterministic rotation")
    assert has_element?(view, "#pool_routing_strategy", "Least recent success")
    assert has_element?(view, "#pool_routing_strategy", "Quota first")
    view |> element("#pool-create-dialog-tab-upstreams") |> render_click()

    assert has_element?(view, "#pool-create-dialog-tab-upstreams[aria-selected='true']")

    refute has_element?(view, "#pool-create-upstream-identity-options-filter")
    refute has_element?(view, "#pool-create-upstream-identity-options-select-all")

    assert has_element?(
             view,
             "#pool-create-dialog-header",
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
    assert has_element?(view, "#pool-create-dialog-header", "API Keys")
    assert has_element?(view, "#pool-create-api-key-options")
    assert has_element?(view, "#pool-create-api-key-options [data-assignment-scroll]")

    refute has_element?(view, "#pool_slug")
  end

  @tag :admin_pool_url_filters
  test "filters the pool inventory from the toolbar", %{conn: conn, scope: scope} do
    {:ok, active_pool} =
      Pools.create_pool(scope, %{slug: "filter-active", name: "Filter Active"})

    {:ok, disabled_pool} =
      Pools.create_pool(scope, %{slug: "filter-disabled", name: "Filter Disabled"})

    assert {:ok, _pool} = Pools.change_pool_status(scope, disabled_pool, "disabled")

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

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

  test "creates pools from names with generated slugs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    open_create_dialog(view)

    view
    |> element("#pool-create-form")
    |> render_submit(%{"pool" => %{"name" => "Generated Slug Pool"}})

    created_pool = Repo.get_by!(Pool, slug: "generated-slug-pool")
    settings = Pools.get_routing_settings(created_pool)

    assert created_pool.name == "Generated Slug Pool"
    assert settings.prompt_cache_affinity_enabled == true
    assert settings.v1_compatibility_enabled == true
    assert settings.request_compression_enabled == false
    assert has_element?(view, "#pool-row-#{created_pool.id}", "Generated Slug Pool")
    refute has_element?(view, "#pool-row-#{created_pool.id}", "generated-slug-pool")
    refute has_element?(view, "#pool-create-dialog")
    _ = await_pool_traffic(view)
  end

  test "defers lifecycle event reloads while the create wizard is open", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    open_create_dialog(view)
    assert has_element?(view, "#pool-create-upstream-identity-options")

    late_identity = active_identity_fixture(account_label: "Mid-edit lifecycle account")

    send(view.pid, {Events, %{pool_id: Ecto.UUID.generate(), topics: ["upstreams"]}})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#pool-create-dialog[open]")

    refute has_element?(
             view,
             "#pool-create-upstream-identity-options-card-#{late_identity.id}"
           )

    view |> element("#pool-create-cancel") |> render_click()
    refute has_element?(view, "#pool-create-dialog")

    open_create_dialog(view)

    assert has_element?(
             view,
             "#pool-create-upstream-identity-options-card-#{late_identity.id}"
           )

    _ = await_pool_traffic(view)
  end

  test "defers lifecycle event reloads while the edit dialog is open", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "lifecycle-edit-pool", name: "Lifecycle Edit Pool"})

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    assert has_element?(view, "#edit-pool-#{pool.id}")
    refute has_element?(view, "#models-pool-#{pool.id}")

    view |> element("#edit-pool-#{pool.id}") |> render_click()
    assert has_element?(view, "#pool-edit-dialog[open]")
    assert has_element?(view, "#pool-edit-upstream-assignment-options")

    _late_identity = active_identity_fixture(account_label: "Mid-edit assignment account")

    send(view.pid, {Events, %{pool_id: pool.id, topics: ["pools"]}})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#pool-edit-dialog[open]")

    refute has_element?(
             view,
             "#pool-edit-upstream-assignment-options",
             "Mid-edit assignment account"
           )

    view |> element("#pool-edit-cancel") |> render_click()
    refute has_element?(view, "#pool-edit-dialog")

    view |> element("#edit-pool-#{pool.id}") |> render_click()

    assert has_element?(
             view,
             "#pool-edit-upstream-assignment-options",
             "Mid-edit assignment account"
           )

    _ = await_pool_traffic(view)
  end

  test "creates pools with routing strategy, compatibility, compression, image generation, and upstream identities",
       %{conn: conn} do
    first_identity =
      active_identity_fixture(account_label: "First create account", plan_label: "pro")

    second_identity = active_identity_fixture(account_label: "Second create account")

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

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
        "v1_compatibility_enabled" => "false",
        "request_compression_enabled" => "true",
        "allow_image_generation" => "false",
        "upstream_identity_ids" => [first_identity.id, second_identity.id]
      }
    })

    created_pool = Repo.get_by!(Pool, slug: "routed-create-pool")
    settings = Pools.get_routing_settings(created_pool)
    assignments = Upstreams.list_pool_assignments(created_pool)

    assert created_pool.name == "Routed Create Pool"
    assert settings.routing_strategy == "least_recent_success"
    assert settings.prompt_cache_affinity_enabled == false
    assert settings.v1_compatibility_enabled == false
    assert settings.request_compression_enabled == true
    assert settings.allow_image_generation == false

    assert Enum.map(assignments, & &1.upstream_identity_id) |> Enum.sort() ==
             [first_identity.id, second_identity.id] |> Enum.sort()

    assert Enum.all?(assignments, &(&1.status == "active"))
    refute has_element?(view, "#pool-create-dialog")
    _ = await_pool_traffic(view)
  end

  test "rejects duplicate generated slugs and keeps the create dialog open", %{
    conn: conn,
    scope: scope
  } do
    {:ok, existing_pool} =
      Pools.create_pool(scope, %{slug: "duplicate-pool", name: "Duplicate Pool"})

    initial_pool_count = Repo.aggregate(Pool, :count, :id)

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    open_create_dialog(view)

    view
    |> element("#pool-create-form")
    |> render_submit(%{"pool" => %{"name" => "Duplicate Pool!!!"}})

    assert has_element?(view, "#pool-create-dialog[open]")
    assert Repo.aggregate(Pool, :count, :id) == initial_pool_count
    assert has_element?(view, "#pool-row-#{existing_pool.id}", "Duplicate Pool")
  end

  test "create validation keeps selected routing and upstream values", %{conn: conn, scope: scope} do
    {:ok, _existing_pool} =
      Pools.create_pool(scope, %{slug: "duplicate-routed-pool", name: "Duplicate Routed Pool"})

    initial_pool_count = Repo.aggregate(Pool, :count, :id)

    identity = active_identity_fixture(account_label: "Preserved create account")

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    open_create_dialog(view)

    view
    |> element("#pool-create-form")
    |> render_submit(%{
      "pool" => %{
        "name" => "Duplicate Routed Pool!!!",
        "routing_strategy" => "quota_first",
        "prompt_cache_affinity_enabled" => "false",
        "v1_compatibility_enabled" => "false",
        "request_compression_enabled" => "true",
        "upstream_identity_ids" => [identity.id]
      }
    })

    assert has_element?(view, "#pool-create-dialog[open]")
    assert has_element?(view, "#pool_routing_strategy_quota_first[checked]")

    assert has_element?(
             view,
             "#pool-create-upstream-identity-options input[checked][value='#{identity.id}']"
           )

    refute has_element?(view, "#pool_prompt_cache_affinity_enabled[checked]")
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
    _ = await_pool_traffic(view)

    view |> element("#edit-pool-#{pool.id}") |> render_click()

    assert has_element?(view, "#pool-edit-dialog[open]")
    assert has_element?(view, "#pool-edit-form")
    assert_policy_editor_docs_link(view, "pool-edit-dialog")
    assert has_element?(view, "#pool-edit-dialog-tabs[role='tablist']")
    assert has_element?(view, "#pool-edit-dialog-tab-details[aria-selected='true']")
    assert has_element?(view, "#pool-edit-dialog-tab-routing[role='tab']")
    assert has_element?(view, "#pool-edit-dialog-tab-models[role='tab']")
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
    _ = await_pool_traffic(view)
  end

  test "keeps Models last in the edit wizard while Create stays four tabs", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "wizard-tab-order", name: "Wizard Tab Order"})

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    open_create_dialog(view)

    assert_pool_wizard_tab_order(view, "pool-create-dialog", [
      {"details", "Details"},
      {"routing", "Routing"},
      {"upstreams", "Upstreams"},
      {"api-keys", "API keys"}
    ])

    view |> element("#pool-create-cancel") |> render_click()
    view |> element("#edit-pool-#{pool.id}") |> render_click()

    # Opening edit mode starts the model-serving database load. Complete it
    # before sandbox teardown so its task cannot lose its checked-out connection.
    _ = render_async(view)

    assert_pool_wizard_tab_order(view, "pool-edit-dialog", [
      {"details", "Details"},
      {"routing", "Routing"},
      {"upstreams", "Upstreams"},
      {"api-keys", "API keys"},
      {"models", "Models"}
    ])
  end

  test "saves model modes through the edit-only form without overwriting concurrent Pool state",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "model-modes", name: "Model Modes"})
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    model_fixture(pool, %{
      exposed_model_id: "gpt-model-modes",
      metadata: %{"source_assignment_ids" => [assignment.id]}
    })

    %{api_key: api_key} = api_key_fixture(pool, %{display_name: "Model mode key", scope: scope})
    assert {:ok, snapshot} = Pools.model_serving_modes_snapshot(scope, pool)

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    view |> element("#edit-pool-#{pool.id}") |> render_click()
    view |> element("#pool-edit-dialog-tab-models") |> render_click()

    assert has_element?(view, "#pool-edit-dialog-tab-models[aria-selected='true']")
    assert has_element?(view, "#pool-edit-dialog-section-models[role='tabpanel']")
    assert has_element?(view, "#pool-model-serving-form")

    assert has_element?(
             view,
             "#pool-model-serving-form input[name='pool_model_serving[rows][0][exposed_model_id]'][value='gpt-model-modes']"
           )

    pool
    |> Ecto.Changeset.change(
      name: "Concurrently renamed",
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    )
    |> Repo.update!()

    assert {:ok, _settings} =
             PoolRouting.update_routing_settings(scope, pool, %{
               "routing_strategy" => "quota_first"
             })

    view
    |> element("#pool-model-serving-form")
    |> render_submit(%{
      "pool_model_serving" => %{
        "revision" => snapshot.revision,
        "rows" => %{
          "0" => %{"exposed_model_id" => "gpt-model-modes", "mode" => "lite"}
        }
      }
    })

    _ = render_async(view)

    assert %ModelServingOverride{mode: "lite"} =
             Repo.get_by!(ModelServingOverride,
               pool_id: pool.id,
               exposed_model_id: "gpt-model-modes"
             )

    assert Repo.get!(Pool, pool.id).name == "Concurrently renamed"
    assert PoolRouting.get_routing_settings(pool).routing_strategy == "quota_first"
    assert Repo.get!(PoolUpstreamAssignment, assignment.id).status == "active"
    assert Repo.get!(APIKey, api_key.id).pool_id == pool.id
    assert has_element?(view, "#pool-edit-dialog[open]")
    assert has_element?(view, "#pool-edit-dialog-tab-models[aria-selected='true']")
    assert has_element?(view, "#pool-edit-form")
    _ = render_async(view)
    _ = await_pool_traffic(view)
  end

  @tag :task_15_acceptance
  test "issue 180 routes an Edit Pool mode save through the authenticated gateway", %{
    conn: conn,
    scope: scope
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_task_15_red",
          "object" => "response",
          "status" => "completed",
          "output" => []
        })
      )

    {:ok, pool} = Pools.create_pool(scope, %{slug: "task-15-red", name: "Task 15 Red"})
    setup = active_api_key_fixture(pool, %{scope: scope})
    upstream_ref = gateway_upstream(pool, upstream, "synthetic-upstream-token", [])
    prime_routing_quota!(upstream_ref.identity)

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-task-15-red",
        upstream_model_id: "provider-gpt-task-15-red",
        metadata: %{
          "source_assignment_ids" => [upstream_ref.assignment.id],
          "source_assignment_models" => %{
            upstream_ref.assignment.id => %{
              "slug" => "gpt-task-15-red",
              "use_responses_lite" => false
            }
          }
        }
      })

    setup =
      Map.merge(setup, %{
        identity: upstream_ref.identity,
        assignment: upstream_ref.assignment,
        model: model
      })

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)
    view |> element("#edit-pool-#{pool.id}") |> render_click()
    _ = render_async(view)
    view |> element("#pool-edit-dialog-tab-models") |> render_click()

    revision = model_serving_revision(view)

    view
    |> element("#pool-model-serving-form")
    |> render_submit(%{
      "pool_model_serving" => %{
        "revision" => revision,
        "rows" => %{
          "0" => %{"exposed_model_id" => model.exposed_model_id, "mode" => "lite"}
        }
      }
    })

    _ = render_async(view)

    assert %ModelServingOverride{mode: "lite"} =
             Repo.get_by!(ModelServingOverride,
               pool_id: pool.id,
               exposed_model_id: model.exposed_model_id
             )

    catalog_response = build_conn() |> auth(setup) |> get("/backend-api/codex/models")

    assert %{"models" => [%{"slug" => "gpt-task-15-red", "use_responses_lite" => true}]} =
             json_response(catalog_response, 200)

    response =
      build_conn()
      |> put_req_header("x-openai-internal-codex-responses-lite", "client-spoofed-full")
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "synthetic task 15 red input"}]
          }
        ],
        "parallel_tool_calls" => true
      })

    assert %{"id" => "resp_task_15_red"} = json_response(response, 200)
    assert [%{json: payload, headers: headers}] = FakeUpstream.requests(upstream)
    assert payload["model"] == model.upstream_model_id
    assert payload["parallel_tool_calls"] == false
    assert Map.new(headers)["x-openai-internal-codex-responses-lite"] == "true"

    pool_id = pool.id

    assert [request] =
             Repo.all(
               from(r in Request,
                 where: r.pool_id == ^pool_id and r.endpoint == "/backend-api/codex/responses"
               )
             )

    assert get_in(request.request_metadata, ["routing", "model_serving_mode"]) == "lite"
    request_id = request.id
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request_id))
    assert get_in(attempt.response_metadata, ["routing", "model_serving_mode"]) == "lite"

    view |> element("#edit-pool-#{pool.id}") |> render_click()
    _ = render_async(view)
    view |> element("#pool-edit-dialog-tab-models") |> render_click()

    full_revision = model_serving_revision(view)

    view
    |> element("#pool-model-serving-form")
    |> render_submit(%{
      "pool_model_serving" => %{
        "revision" => full_revision,
        "rows" => %{
          "0" => %{"exposed_model_id" => model.exposed_model_id, "mode" => "full"}
        }
      }
    })

    _ = render_async(view)

    assert %ModelServingOverride{mode: "full"} =
             Repo.get_by!(ModelServingOverride,
               pool_id: pool.id,
               exposed_model_id: model.exposed_model_id
             )

    full_catalog_response = build_conn() |> auth(setup) |> get("/backend-api/codex/models")

    assert %{"models" => [%{"slug" => "gpt-task-15-red", "use_responses_lite" => false}]} =
             json_response(full_catalog_response, 200)

    full_payloads = [
      %{
        "model" => model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "synthetic task 15 full absent input"}
            ]
          }
        ]
      },
      %{
        "model" => model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "synthetic task 15 full true input"}
            ]
          }
        ],
        "parallel_tool_calls" => true
      },
      %{
        "model" => model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "synthetic task 15 full false input"}
            ]
          }
        ],
        "parallel_tool_calls" => false
      }
    ]

    Enum.each(full_payloads, fn payload ->
      response =
        build_conn()
        |> put_req_header("x-openai-internal-codex-responses-lite", "client-spoofed-lite")
        |> auth(setup)
        |> post("/backend-api/codex/responses", payload)

      assert %{"id" => "resp_task_15_red"} = json_response(response, 200)
    end)

    assert [lite_capture, full_absent, full_true, full_false] = FakeUpstream.requests(upstream)
    assert lite_capture.json["model"] == model.upstream_model_id
    assert lite_capture.json["parallel_tool_calls"] == false
    assert Map.new(lite_capture.headers)["x-openai-internal-codex-responses-lite"] == "true"

    for capture <- [full_absent, full_true, full_false] do
      assert capture.json["model"] == model.upstream_model_id
      refute Map.has_key?(Map.new(capture.headers), "x-openai-internal-codex-responses-lite")
    end

    refute Map.has_key?(full_absent.json, "parallel_tool_calls")
    assert full_true.json["parallel_tool_calls"] == true
    assert full_false.json["parallel_tool_calls"] == false

    full_requests =
      Repo.all(
        from(r in Request,
          where: r.pool_id == ^pool_id and r.endpoint == "/backend-api/codex/responses",
          order_by: [asc: r.admitted_at]
        )
      )

    assert length(full_requests) == 4

    for request <- full_requests do
      expected = %{
        "model_serving_mode_configured" =>
          if(request == hd(full_requests), do: "lite", else: "full"),
        "model_serving_mode" => if(request == hd(full_requests), do: "lite", else: "full"),
        "model_serving_mode_source" => "override"
      }

      assert Map.take(request.request_metadata["routing"], Map.keys(expected)) == expected
      request_id = request.id
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request_id))
      assert Map.take(attempt.response_metadata["routing"], Map.keys(expected)) == expected
    end

    raw_provider_failure = "raw-task-15-provider-response-sentinel"

    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.http_500_json_error(%{
        "error" => %{
          "code" => "server_error",
          "message" => raw_provider_failure,
          "provider_body" => raw_provider_failure
        }
      })
    )

    invalid_response =
      build_conn()
      |> put_req_header("x-openai-internal-codex-responses-lite", "client-spoofed-lite")
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "synthetic task 15 invalid full input"}
            ]
          }
        ]
      })

    assert %{"error" => %{"code" => "server_error"}} = json_response(invalid_response, 500)
    refute invalid_response.resp_body =~ raw_provider_failure

    assert %ModelServingOverride{mode: "full"} =
             Repo.get_by!(ModelServingOverride,
               pool_id: pool.id,
               exposed_model_id: model.exposed_model_id
             )

    [failed_request | _successful_requests] =
      Repo.all(
        from(r in Request,
          where: r.pool_id == ^pool_id and r.endpoint == "/backend-api/codex/responses",
          order_by: [desc: r.admitted_at]
        )
      )

    assert failed_request.status == "failed"
    assert failed_request.last_error_code == "upstream_status"
    failed_request_id = failed_request.id

    assert [failed_attempt] =
             Repo.all(from(a in Attempt, where: a.request_id == ^failed_request_id))

    assert failed_attempt.status == "failed"
    refute inspect(failed_request.request_metadata) =~ raw_provider_failure
    refute inspect(failed_attempt.response_metadata) =~ raw_provider_failure

    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.json_response(%{
        "id" => "resp_task_15_after_full_failure",
        "object" => "response",
        "status" => "completed",
        "output" => []
      })
    )

    retained_response =
      build_conn()
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "synthetic task 15 retained full input"}
            ]
          }
        ]
      })

    assert %{"id" => "resp_task_15_after_full_failure"} =
             json_response(retained_response, 200)

    retained_capture = List.last(FakeUpstream.requests(upstream))
    assert retained_capture.json["model"] == model.upstream_model_id

    refute Map.has_key?(
             Map.new(retained_capture.headers),
             "x-openai-internal-codex-responses-lite"
           )

    retained_catalog = build_conn() |> auth(setup) |> get("/backend-api/codex/models")

    assert %{"models" => [%{"slug" => "gpt-task-15-red", "use_responses_lite" => false}]} =
             json_response(retained_catalog, 200)
  end

  test "rejects stale model mode edits and preserves the submitted form state", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "stale-model-modes", name: "Stale Modes"})
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    model_fixture(pool, %{
      exposed_model_id: "gpt-stale-modes",
      metadata: %{"source_assignment_ids" => [assignment.id]}
    })

    assert {:ok, initial} = Pools.model_serving_modes_snapshot(scope, pool)
    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    view |> element("#edit-pool-#{pool.id}") |> render_click()
    view |> element("#pool-edit-dialog-tab-models") |> render_click()

    assert {:ok, committed} =
             Pools.update_model_serving_modes(
               scope,
               pool,
               [%{exposed_model_id: "gpt-stale-modes", mode: "lite"}],
               initial.revision
             )

    view
    |> element("#pool-model-serving-form")
    |> render_submit(%{
      "pool_model_serving" => %{
        "revision" => initial.revision,
        "rows" => %{
          "0" => %{"exposed_model_id" => "gpt-stale-modes", "mode" => "full"}
        }
      }
    })

    _ = render_async(view)

    assert has_element?(view, "#pool-edit-dialog[open]")
    assert has_element?(view, "#pool-edit-dialog-tab-models[aria-selected='true']")

    assert has_element?(
             view,
             "#pool-model-serving-form input[type='radio'][value='full'][checked]"
           )

    assert %ModelServingOverride{mode: "lite"} =
             Repo.get_by!(ModelServingOverride,
               pool_id: pool.id,
               exposed_model_id: "gpt-stale-modes"
             )

    assert committed.revision != initial.revision
    assert model_serving_revision(view) == committed.revision

    view
    |> element("#pool-model-serving-form")
    |> render_submit(%{
      "pool_model_serving" => %{
        "revision" => committed.revision,
        "rows" => %{
          "0" => %{"exposed_model_id" => "gpt-stale-modes", "mode" => "full"}
        }
      }
    })

    _ = render_async(view)

    assert %ModelServingOverride{mode: "full"} =
             Repo.get_by!(ModelServingOverride,
               pool_id: pool.id,
               exposed_model_id: "gpt-stale-modes"
             )

    assert has_element?(view, "#pool-edit-dialog[open]")
  end

  test "loads the edit-only Models panel and renders accessible mode controls", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "model-controls", name: "Model Controls"})

    %{assignment: assignment} = upstream_assignment_fixture(pool)

    _auto_model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-auto-model",
        display_name: "Auto model",
        metadata: %{
          "source_assignment_ids" => [assignment.id],
          "source_assignment_models" => %{
            assignment.id => %{
              "description" => "Synthetic work routing alias.",
              "visibility" => "hide",
              "supported_in_api" => false,
              "use_responses_lite" => true
            }
          },
          "use_responses_lite" => true
        }
      })

    unavailable_model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-saved-unavailable",
        display_name: "Saved unavailable",
        metadata: %{
          "source_assignment_ids" => [assignment.id],
          "use_responses_lite" => false
        }
      })

    assert {:ok, snapshot} = Pools.model_serving_modes_snapshot(scope, pool)

    assert {:ok, _result} =
             Pools.update_model_serving_modes(
               scope,
               pool,
               [%{exposed_model_id: unavailable_model.exposed_model_id, mode: "full"}],
               snapshot.revision
             )

    assert {:ok, _retired_model} = Catalog.retire_model(unavailable_model)
    _sync_run = catalog_sync_run_fixture(pool, "succeeded")

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    loading_html = view |> element("#edit-pool-#{pool.id}") |> render_click()
    assert loading_html =~ ~s(id="pool-model-serving-state-loading")
    assert loading_html =~ "admin-loading-icon"

    _ = render_async(view)
    view |> element("#pool-edit-dialog-tab-models") |> render_click()

    assert has_element?(view, "#pool-edit-dialog-tab-models[aria-selected='true']")

    assert has_element?(
             view,
             "#pool-model-serving-panel[data-state='ready'][aria-busy='false']:not([aria-live])"
           )

    assert has_element?(
             view,
             "#pool-model-serving-state-ready[role='status'][aria-live='polite']",
             "Model serving modes loaded"
           )

    assert has_element?(
             view,
             "#pool-model-serving-form[phx-change='validate_pool_model_serving'][aria-labelledby='pool-model-serving-title']"
           )

    assert has_element?(
             view,
             "#pool-model-serving-revision[name='pool_model_serving[revision]']"
           )

    assert has_element?(
             view,
             "#pool-model-serving-guidance[role='note']",
             "Choose Auto unless an upstream requires an override"
           )

    assert has_element?(
             view,
             "#pool-model-serving-guidance",
             "Full is an advanced provider-dependent override using ordinary Responses"
           )

    assert has_element?(
             view,
             "#pool-model-serving-guidance",
             "upstream compatibility can change or reject it"
           )

    assert has_element?(
             view,
             "#pool-model-serving-guidance",
             "Pooler never silently downgrades Full"
           )

    auto_row_id = PoolForm.model_serving_dom_id("gpt-auto-model")
    unavailable_row_id = PoolForm.model_serving_dom_id("gpt-saved-unavailable")

    assert has_element?(
             view,
             "##{auto_row_id}[data-role='pool-model-serving-row'][data-availability='available'][aria-describedby='#{auto_row_id}-effective']"
           )

    assert has_element?(view, "##{auto_row_id} legend", "Auto model")

    assert has_element?(
             view,
             "##{auto_row_id}-model-info[data-role='model-info-popover'] [data-role='model-info-trigger'][popovertarget='#{auto_row_id}-model-info-content'][aria-controls='#{auto_row_id}-model-info-content'][aria-describedby='#{auto_row_id}-model-info-content']"
           )

    assert has_element?(
             view,
             "##{auto_row_id}-model-info-content[data-role='model-info-content'][popover][role='tooltip'] [data-role='model-info-description']",
             "Synthetic work routing alias."
           )

    assert has_element?(
             view,
             "##{auto_row_id}-model-info-content [data-role='model-info-facts']",
             "Hidden upstream alias"
           )

    assert has_element?(
             view,
             "##{auto_row_id}-model-info-content [data-role='model-info-facts']",
             "Not exposed by the public API"
           )

    assert has_element?(
             view,
             "##{auto_row_id}-effective[data-role='pool-model-serving-effective'][data-effective-mode='lite']",
             "resolves Lite"
           )

    for mode <- ~w(auto lite full) do
      assert has_element?(
               view,
               "##{auto_row_id}-#{mode}[type='radio'][name='pool_model_serving[rows][0][mode]']"
             )
    end

    assert has_element?(
             view,
             "##{unavailable_row_id}[data-role='pool-model-serving-row'][data-availability='saved-unavailable']"
           )

    assert has_element?(
             view,
             "##{unavailable_row_id}-availability-warning[role='status']",
             "Saved setting retained"
           )

    assert has_element?(
             view,
             "#pool-model-serving-form input[type='hidden'][name='pool_model_serving[rows][1][exposed_model_id]'][value='gpt-saved-unavailable']"
           )

    view
    |> element("#pool-model-serving-form")
    |> render_change(%{
      "pool_model_serving" => %{
        "revision" => model_serving_revision(view),
        "rows" => %{
          "0" => %{"exposed_model_id" => "gpt-auto-model", "mode" => "auto"},
          "1" => %{"exposed_model_id" => "gpt-saved-unavailable", "mode" => "auto"}
        }
      }
    })

    assert has_element?(
             view,
             "##{unavailable_row_id}-effective[data-effective-mode='removed']",
             "removed"
           )

    assert has_element?(
             view,
             "##{unavailable_row_id}-availability-warning",
             "Selecting Auto removes this saved override when you save"
           )
  end

  test "removes only an unavailable model override when Auto is saved", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "override-lifecycle", name: "Override Lifecycle"})

    %{assignment: assignment} = upstream_assignment_fixture(pool)

    unavailable_model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-lifecycle-unavailable",
        display_name: "Lifecycle unavailable",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

    sibling_model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-lifecycle-sibling",
        display_name: "Lifecycle sibling",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

    assert {:ok, initial} = Pools.model_serving_modes_snapshot(scope, pool)

    assert {:ok, configured} =
             Pools.update_model_serving_modes(
               scope,
               pool,
               [
                 %{exposed_model_id: unavailable_model.exposed_model_id, mode: "full"},
                 %{exposed_model_id: sibling_model.exposed_model_id, mode: "lite"}
               ],
               initial.revision
             )

    assert {:ok, _retired_model} = Catalog.retire_model(unavailable_model)
    _sync_run = catalog_sync_run_fixture(pool, "succeeded")

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)
    open_edit_models(view, pool)
    _ = render_async(view)

    unavailable_row_id = PoolForm.model_serving_dom_id(unavailable_model.exposed_model_id)
    sibling_row_id = PoolForm.model_serving_dom_id(sibling_model.exposed_model_id)

    assert has_element?(
             view,
             "##{unavailable_row_id}[data-availability='saved-unavailable']"
           )

    assert has_element?(
             view,
             "##{unavailable_row_id}-availability-warning",
             "Saved setting retained"
           )

    assert has_element?(view, "##{sibling_row_id}[data-availability='available']")

    audit_count_before =
      Repo.aggregate(
        from(event in AuditEvent, where: event.action == "pool.model_serving_modes_update"),
        :count
      )

    view
    |> element("#pool-model-serving-form")
    |> render_change(%{
      "pool_model_serving" => %{
        "revision" => model_serving_revision(view),
        "rows" => %{
          "0" => %{
            "exposed_model_id" => unavailable_model.exposed_model_id,
            "mode" => "auto"
          },
          "1" => %{
            "exposed_model_id" => sibling_model.exposed_model_id,
            "mode" => "lite"
          }
        }
      }
    })

    assert has_element?(
             view,
             "##{unavailable_row_id}-availability-warning",
             "Selecting Auto removes this saved override when you save"
           )

    view
    |> element("#pool-model-serving-form")
    |> render_submit(%{
      "pool_model_serving" => %{
        "revision" => model_serving_revision(view),
        "rows" => %{
          "0" => %{
            "exposed_model_id" => unavailable_model.exposed_model_id,
            "mode" => "auto"
          },
          "1" => %{
            "exposed_model_id" => sibling_model.exposed_model_id,
            "mode" => "lite"
          }
        }
      }
    })

    _ = render_async(view)

    refute Repo.get_by(ModelServingOverride,
             pool_id: pool.id,
             exposed_model_id: unavailable_model.exposed_model_id
           )

    assert %ModelServingOverride{mode: "lite"} =
             Repo.get_by!(ModelServingOverride,
               pool_id: pool.id,
               exposed_model_id: sibling_model.exposed_model_id
             )

    assert Repo.get!(CatalogModel, sibling_model.id).retired_at == nil
    assert Repo.get!(PoolUpstreamAssignment, assignment.id).pool_id == pool.id

    assert Repo.aggregate(
             from(event in AuditEvent, where: event.action == "pool.model_serving_modes_update"),
             :count
           ) == audit_count_before + 1

    assert %AuditEvent{
             details: %{
               "changed_count" => 1,
               "transitions" => [
                 %{
                   "exposed_model_id" => "gpt-lifecycle-unavailable",
                   "from_mode" => "full",
                   "to_mode" => "auto"
                 }
               ]
             }
           } =
             Repo.one!(
               from event in AuditEvent,
                 where: event.action == "pool.model_serving_modes_update",
                 order_by: [desc: event.occurred_at],
                 limit: 1
             )

    view |> element("#pool-edit-cancel") |> render_click()
    open_edit_models(view, pool)
    _ = render_async(view)

    refute has_element?(view, "##{unavailable_row_id}[data-availability='saved-unavailable']")
    assert has_element?(view, "##{sibling_row_id}[data-availability='available']")
    assert has_element?(view, "##{sibling_row_id}-effective[data-effective-mode='lite']")
    assert configured.revision != model_serving_revision(view)
  end

  test "saving Pool fields keeps unsaved model-mode choices in the open dialog", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "cross-form-state", name: "Cross Form State"})
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    model_fixture(pool, %{
      exposed_model_id: "gpt-cross-form-state",
      metadata: %{"source_assignment_ids" => [assignment.id]}
    })

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)
    open_edit_models(view, pool)

    view
    |> element("#pool-model-serving-form")
    |> render_change(%{
      "pool_model_serving" => %{
        "revision" => model_serving_revision(view),
        "rows" => %{
          "0" => %{"exposed_model_id" => "gpt-cross-form-state", "mode" => "full"}
        }
      }
    })

    view |> element("#pool-edit-dialog-tab-details") |> render_click()

    view
    |> element("#pool-edit-form")
    |> render_submit(%{
      "pool_edit" => %{
        "id" => pool.id,
        "name" => "Cross Form State Updated",
        "status" => "active",
        "routing_strategy" => "bridge_ring",
        "bridge_ring_size" => "3",
        "sticky_websocket_sessions" => "true",
        "sticky_http_sessions" => "false",
        "prompt_cache_affinity_enabled" => "true",
        "v1_compatibility_enabled" => "true",
        "request_compression_enabled" => "false",
        "allow_image_generation" => "false",
        "upstream_identity_ids" => [assignment.upstream_identity_id]
      }
    })

    assert has_element?(view, "#pool-edit-dialog[open]")
    assert Repo.get!(Pool, pool.id).name == "Cross Form State Updated"

    view |> element("#pool-edit-dialog-tab-models") |> render_click()

    assert has_element?(
             view,
             "#pool-model-serving-form input[type='radio'][value='full'][checked]"
           )

    refute Repo.get_by(ModelServingOverride, pool_id: pool.id)
  end

  test "Auto shows the same effective mode as runtime after assignment routability filtering", %{
    conn: conn,
    scope: scope
  } do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_auto_routability",
          "object" => "response",
          "status" => "completed",
          "output" => []
        })
      )

    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "auto-routability",
        name: "Auto Routability"
      })

    setup = active_api_key_fixture(pool, %{scope: scope})
    active_full = gateway_upstream(pool, upstream, "synthetic-upstream-token", [])
    prime_routing_quota!(active_full.identity)

    %{assignment: ineligible_lite} =
      upstream_assignment_fixture(pool, %{
        account_label: "Ineligible Lite source",
        eligibility_status: "ineligible"
      })

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-auto-routability",
        upstream_model_id: "provider-gpt-auto-routability",
        display_name: "Auto routability",
        metadata: %{
          "source_assignment_ids" => [ineligible_lite.id, active_full.assignment.id],
          "source_assignment_models" => %{
            ineligible_lite.id => %{
              "slug" => "gpt-auto-routability",
              "use_responses_lite" => true
            },
            active_full.assignment.id => %{
              "slug" => "gpt-auto-routability",
              "use_responses_lite" => false
            }
          },
          "use_responses_lite" => true
        }
      })

    setup =
      Map.merge(setup, %{
        identity: active_full.identity,
        assignment: active_full.assignment,
        model: model
      })

    _sync_run = catalog_sync_run_fixture(pool, "succeeded")

    # Given one ineligible Lite source and one active Full source, runtime filters first
    response =
      build_conn()
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => model.exposed_model_id,
        "input" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "synthetic Auto routability input"}]
          }
        ]
      })

    assert %{"id" => "resp_auto_routability"} = json_response(response, 200)
    assert [%{headers: headers}] = FakeUpstream.requests(upstream)
    refute Map.has_key?(Map.new(headers), "x-openai-internal-codex-responses-lite")

    pool_id = pool.id

    assert [request] =
             Repo.all(
               from(r in Request,
                 where: r.pool_id == ^pool_id and r.endpoint == "/backend-api/codex/responses"
               )
             )

    assert get_in(request.request_metadata, ["routing", "model_serving_mode"]) == "full"

    # When the operator opens the Models panel for the same Pool/model
    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)
    open_edit_models(view, pool)

    row_id = PoolForm.model_serving_dom_id(model.exposed_model_id)

    # Then Auto reports the same Full result rather than counting the ineligible Lite source
    assert has_element?(
             view,
             "##{row_id}-effective[data-role='pool-model-serving-effective'][data-effective-mode='full']",
             "resolves Full"
           )
  end

  test "renders a usable empty Models state with its revision", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "models-empty", name: "Models Empty"})
    _sync_run = catalog_sync_run_fixture(pool, "succeeded")

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)
    open_edit_models(view, pool)

    assert has_element?(view, "#pool-model-serving-panel[data-state='empty']")
    assert has_element?(view, "#pool-model-serving-state-empty-announcement[role='status']")
    assert has_element?(view, "#pool-model-serving-state-empty", "No routable models")
    assert has_element?(view, "#pool-model-serving-revision[value]")
    refute has_element?(view, "[data-role='pool-model-serving-row']")
    refute has_element?(view, "#pool-model-serving-submit")
  end

  test "keeps saved choices usable when the catalog reports an error", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "models-error", name: "Models Error"})
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    _model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-error-state",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

    _sync_run = catalog_sync_run_fixture(pool, "failed")

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)
    open_edit_models(view, pool)

    assert has_element?(view, "#pool-model-serving-panel[data-state='error']")
    assert has_element?(view, "#pool-model-serving-state-error[role='alert']")
    assert has_element?(view, "[data-role='pool-model-serving-row']")
    assert has_element?(view, "#pool-model-serving-submit:not([disabled])")
  end

  test "marks a stale catalog without disabling model mode edits", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "models-stale", name: "Models Stale"})
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    _model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-stale-catalog",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

    _sync_run =
      catalog_sync_run_fixture(pool, "succeeded",
        finished_at: DateTime.add(DateTime.utc_now(), -2, :day)
      )

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)
    open_edit_models(view, pool)

    assert has_element?(view, "#pool-model-serving-panel[data-state='stale']")
    assert has_element?(view, "#pool-model-serving-state-stale[role='status']")
    assert has_element?(view, "[data-role='pool-model-serving-row']")
    assert has_element?(view, "#pool-model-serving-submit:not([disabled])")
  end

  test "preserves a dirty mode form when model sync completes and refreshes after reopen", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "models-dirty", name: "Models Dirty"})
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    _model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-dirty-state",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

    _sync_run = catalog_sync_run_fixture(pool, "succeeded")

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)
    open_edit_models(view, pool)

    view
    |> element("#pool-model-serving-form")
    |> render_change(%{
      "pool_model_serving" => %{
        "revision" => model_serving_revision(view),
        "rows" => %{
          "0" => %{"exposed_model_id" => "gpt-dirty-state", "mode" => "full"}
        }
      }
    })

    assert has_element?(
             view,
             "#pool-model-serving-form input[type='radio'][value='full'][checked]"
           )

    _late_model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-after-sync",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

    assert {:ok, _event} = Events.broadcast_model_sync(pool, "model_sync_completed")
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#pool-model-serving-state-stale[role='status']")
    assert has_element?(view, "#pool-model-serving-state-stale", "unsaved choices are preserved")

    assert has_element?(
             view,
             "#pool-model-serving-form input[type='radio'][value='full'][checked]"
           )

    refute has_element?(
             view,
             "#pool-model-serving-form input[type='hidden'][value='gpt-after-sync']"
           )

    view |> element("#pool-edit-cancel") |> render_click()
    view |> element("#edit-pool-#{pool.id}") |> render_click()
    _ = render_async(view)
    view |> element("#pool-edit-dialog-tab-models") |> render_click()

    assert has_element?(
             view,
             "#pool-model-serving-form input[type='hidden'][value='gpt-after-sync']"
           )
  end

  test "rejects a forged model id without synthesizing it into the error form", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "models-forged", name: "Models Forged"})
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    _model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-known-model",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)
    open_edit_models(view, pool)

    view
    |> element("#pool-model-serving-form")
    |> render_submit(%{
      "pool_model_serving" => %{
        "revision" => model_serving_revision(view),
        "rows" => %{
          "0" => %{"exposed_model_id" => "gpt-known-model", "mode" => "full"},
          "1" => %{"exposed_model_id" => "forged-model", "mode" => "lite"}
        }
      }
    })

    assert has_element?(view, "#pool-model-serving-panel[data-state='error']")
    assert has_element?(view, "#pool-model-serving-form input[value='full'][checked]")
    refute has_element?(view, "#pool-model-serving-form input[value='forged-model']")
    refute Repo.get_by(ModelServingOverride, pool_id: pool.id)
  end

  test "rejects an invalid mode without changing persisted state", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "models-invalid", name: "Models Invalid"})
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    _model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-valid-mode",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)
    open_edit_models(view, pool)

    view
    |> element("#pool-model-serving-form")
    |> render_submit(%{
      "pool_model_serving" => %{
        "revision" => model_serving_revision(view),
        "rows" => %{
          "0" => %{"exposed_model_id" => "gpt-valid-mode", "mode" => "unsupported"}
        }
      }
    })

    assert has_element?(view, "#pool-model-serving-panel[data-state='error']")
    assert has_element?(view, "#pool-model-serving-state-error[role='alert']")
    refute Repo.get_by(ModelServingOverride, pool_id: pool.id)
  end

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
    _ = await_pool_traffic(view)

    view |> element("#edit-pool-#{pool.id}") |> render_click()

    assert has_element?(view, "#pool-edit-dialog-header", "Edit Pool")
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

    assert has_element?(view, "#pool-edit-routing-controls #pool_edit_v1_compatibility_enabled")

    assert has_element?(
             view,
             "#pool-edit-routing-controls #pool_edit_request_compression_enabled"
           )

    assert has_element?(
             view,
             "#pool-edit-routing-controls #pool_edit_allow_image_generation"
           )

    assert has_element?(view, "#pool_edit_routing_strategy")
    assert has_element?(view, "#pool_edit_bridge_ring_size")
    assert has_element?(view, "#pool_edit_sticky_websocket_sessions")
    assert has_element?(view, "#pool_edit_sticky_http_sessions")
    assert has_element?(view, "#pool_edit_prompt_cache_affinity_enabled[checked]")
    assert has_element?(view, "#pool_edit_v1_compatibility_enabled")
    refute has_element?(view, "#pool_edit_request_compression_enabled[checked]")

    assert has_element?(
             view,
             "#pool-edit-routing-controls",
             "Strategy and fan-out size used for runtime requests"
           )

    assert has_element?(
             view,
             "#pool-edit-routing-controls",
             "Identity-aware routing behavior"
           )

    assert has_element?(
             view,
             "#pool-edit-routing-controls",
             "Sends requests that share a prompt cache to the same upstream."
           )

    assert has_element?(
             view,
             "#pool-edit-routing-controls",
             "Sends requests that share a prompt cache to the same upstream."
           )

    assert has_element?(
             view,
             "#pool-edit-routing-controls",
             "Optional client surfaces"
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

    assert has_element?(
             view,
             "#pool-edit-routing-controls",
             "Stable rendezvous ordering, within continuity and quota."
           )

    refute has_element?(
             view,
             "#pool-edit-routing-controls",
             "Balances upstreams by continuity, cache locality, and quota evidence."
           )

    view |> element("#pool-edit-dialog-tab-upstreams") |> render_click()

    assert has_element?(view, "#pool-edit-dialog-tab-upstreams[aria-selected='true']")
    assert has_element?(view, "#pool-edit-dialog-section-upstreams[role='tabpanel']")

    assert has_element?(
             view,
             "#pool-edit-dialog-header",
             "Pool upstream assignments"
           )

    assert has_element?(view, "#pool-edit-upstream-assignment-count", "2 available")

    assert has_element?(
             view,
             "#pool-edit-upstream-assignment-options #pool-edit-upstream-assignment-count"
           )

    assert has_element?(view, "#pool-edit-upstream-assignment-options")
    assert has_element?(view, "#pool-edit-upstream-assignment-options [data-assignment-scroll]")
    assert has_element?(view, "#pool-edit-upstream-assignment-options-filter")
    assert has_element?(view, "#pool-edit-upstream-assignment-options-select-all", "Select all")
    assert has_element?(view, "#pool-edit-upstream-assignment-options-clear", "Clear")

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
    assert has_element?(view, "#pool-edit-dialog-header", "API Keys")
    assert has_element?(view, "#pool-edit-api-key-count", "2 available")

    assert has_element?(
             view,
             "#pool-edit-api-key-options #pool-edit-api-key-count"
           )

    assert has_element?(view, "#pool-edit-api-key-options")
    assert has_element?(view, "#pool-edit-api-key-options [data-assignment-scroll]")
    assert has_element?(view, "#pool-edit-api-key-options-filter")
    assert has_element?(view, "#pool-edit-api-key-options-select-all", "Select all")
    assert has_element?(view, "#pool-edit-api-key-options-clear", "Clear")
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
    assert settings.v1_compatibility_enabled == false
    assert settings.request_compression_enabled == true
    assert Repo.get!(PoolUpstreamAssignment, removed_assignment.id).status == "deleted"
    assert Repo.get!(PoolUpstreamAssignment, kept_assignment.id).status == "active"
    assert Repo.get!(APIKey, linked_api_key.id).pool_id == pool.id
    assert Repo.get!(APIKey, moved_api_key.id).pool_id == pool.id
    assert has_element?(view, "#pool-edit-dialog[open]")
    _ = await_pool_traffic(view)
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
    _ = await_pool_traffic(view)

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
    _ = await_pool_traffic(view)

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
    _ = await_pool_traffic(view)
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
    _ = await_pool_traffic(view)

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

    _ = await_pool_traffic(view)

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
    _ = await_pool_traffic(view)

    assert has_element?(view, "#pool-row-#{pool.id}-routing-strategy", "Bridge ring")
    refute has_element?(view, "#pool-inspector")

    assert {:ok, _settings} =
             Pools.update_routing_settings(scope, pool, %{
               "routing_strategy" => "deterministic_rotation"
             })

    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#pool-row-#{pool.id}-routing-strategy", "Deterministic rotation")
    refute has_element?(view, "#pool-inspector")
    _ = await_pool_traffic(view)
  end

  test "refreshes pool counts and usage metrics when events arrive", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "refresh-counts", name: "Refresh Counts"})

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

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

    state = :sys.get_state(view.pid)
    send(view.pid, {:refresh_pool_traffic, state.socket.assigns.pool_traffic_refresh_token})
    _ = :sys.get_state(view.pid)
    _ = await_pool_traffic(view)

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

  test "fallback tick refreshes rolling traffic on a quiet instance", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "fallback-traffic", name: "Fallback Traffic"})
    %{api_key: api_key} = api_key_fixture(pool, %{scope: scope})
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    assert has_element?(view, "#pool-row-#{pool.id}-request-count", "0")

    insert_timed_usage!(pool, api_key, assignment, DateTime.utc_now(), 100, 1_250_000, 2_000)

    {_result, live_view_queries} =
      capture_repo_queries(view.pid, fn ->
        send(view.pid, :fallback_refresh_pool_traffic)
        _ = :sys.get_state(view.pid)
      end)

    assert live_view_queries == []
    _ = await_pool_traffic(view)

    assert has_element?(view, "#pool-row-#{pool.id}-request-count", "1")
    assert has_element?(view, "#pool-row-#{pool.id}-settled-cost", "$1.25")
  end

  @tag :admin_pool_url_filters
  test "fallback tick holds while paused and resumes with URL-derived filters", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "paused-fallback", name: "Paused Fallback"})
    %{api_key: api_key} = api_key_fixture(pool, %{scope: scope})
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    {:ok, view, _html} =
      live(conn, ~p"/admin/pools?query=paused&status=active&traffic_window=7d")

    _ = await_pool_traffic(view)
    render_hook(view, "set_live_updates", %{"paused" => true})

    timestamp = DateTime.utc_now() |> DateTime.add(-5, :day) |> DateTime.truncate(:microsecond)
    insert_timed_usage!(pool, api_key, assignment, timestamp, 100, 750_000, 1_000)
    send(view.pid, :fallback_refresh_pool_traffic)
    _ = :sys.get_state(view.pid)

    refute :sys.get_state(view.pid).socket.assigns.pool_traffic_running?
    assert has_element?(view, "#pool-row-#{pool.id}-request-count", "0")
    assert has_element?(view, "#pool_filters_query[value='paused']")
    assert has_element?(view, "#pool_filters_status[value='active']")
    assert has_element?(view, "#pool_filters_traffic_window[value='7d']")

    render_hook(view, "set_live_updates", %{"paused" => false})
    _ = await_pool_traffic(view)

    assert has_element?(view, "#pool-row-#{pool.id}-request-count", "1")
    assert has_element?(view, "#pool-row-#{pool.id}-settled-cost", "$0.75")
    assert has_element?(view, "#pool-metric-requests", "Requests 7d")
  end

  test "coalesces traffic refreshes, ignores request logs, and makes stale timers harmless", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "coalesced-traffic", name: "Coalesced Traffic"})

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    state = :sys.get_state(view.pid)

    assert state.socket.assigns.subscribed_pool_event_topics ==
             MapSet.new(["model_sync", "pools", "upstreams", "usage"])

    {_result, request_log_queries} =
      capture_repo_queries(view.pid, fn ->
        assert {:ok, _event} = Events.broadcast_request_logs(pool.id, "request_logged", %{})
        _ = :sys.get_state(view.pid)
      end)

    assert request_log_queries == []

    {_result, traffic_queries} =
      capture_repo_queries(view.pid, fn ->
        broadcast_usage_events(pool.id, 100)
        _ = :sys.get_state(view.pid)
      end)

    assert traffic_queries == []

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.pool_traffic_dirty?
    assert is_reference(state.socket.assigns.pool_traffic_refresh_timer)
    timer_token = state.socket.assigns.pool_traffic_refresh_token

    {_result, timer_queries} =
      capture_repo_queries(view.pid, fn ->
        send(view.pid, {:refresh_pool_traffic, timer_token})
        _ = :sys.get_state(view.pid)
      end)

    # the traffic aggregate runs in an async task, never on the LiveView process
    assert timer_queries == []

    state = :sys.get_state(view.pid)
    refute state.socket.assigns.pool_traffic_dirty?
    assert is_nil(state.socket.assigns.pool_traffic_refresh_timer)

    _ = await_pool_traffic(view)
    state = :sys.get_state(view.pid)
    refute state.socket.assigns.pool_traffic_running?
    assert is_map(state.socket.assigns.pool_traffic_usage)

    {_result, stale_timer_queries} =
      capture_repo_queries(view.pid, fn ->
        send(view.pid, {:refresh_pool_traffic, timer_token})
        _ = :sys.get_state(view.pid)
      end)

    assert stale_timer_queries == []
    refute :sys.get_state(view.pid).socket.assigns.pool_traffic_running?
  end

  test "defers traffic and lifecycle reloads in every Pool dialog, flushing once on close", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "deferred-dialogs", name: "Deferred Dialogs"})

    {:ok, archived_pool} =
      Pools.create_pool(scope, %{slug: "deferred-delete", name: "Deferred Delete"})

    assert {:ok, _archived_pool} = Pools.change_pool_status(scope, archived_pool, "archived")
    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    open_create_dialog(view)

    assert_deferred_traffic_refresh(view, pool.id)

    {_result, create_flush_queries} =
      capture_repo_queries(view.pid, fn ->
        render_click(view, "cancel_create")
        _ = :sys.get_state(view.pid)
      end)

    assert create_flush_queries != []
    assert_no_pending_pool_traffic_refresh(view)

    view |> element("#edit-pool-#{pool.id}") |> render_click()
    _ = render_async(view)

    view
    |> element("#pool-edit-dialog-tab-routing")
    |> render_click()

    assert has_element?(view, "#pool-edit-dialog-tab-routing[aria-selected='true']")

    assert_deferred_traffic_refresh(view, pool.id)

    {_result, lifecycle_queries} =
      capture_repo_queries(view.pid, fn ->
        assert {:ok, _event} = Events.broadcast_pools(pool.id, "pool_changed", %{})

        assert {:ok, _event} =
                 Events.broadcast_upstreams(pool.id, "upstream_assignment_changed", %{})

        _ = :sys.get_state(view.pid)
      end)

    assert lifecycle_queries == []
    assert has_element?(view, "#pool-edit-dialog-tab-routing[aria-selected='true']")

    {_result, edit_flush_queries} =
      capture_repo_queries(view.pid, fn ->
        render_click(view, "cancel_edit")
        _ = :sys.get_state(view.pid)
      end)

    assert edit_flush_queries != []
    assert_no_pending_pool_traffic_refresh(view)

    view |> element("#delete-pool-#{archived_pool.id}") |> render_click()
    assert_deferred_traffic_refresh(view, pool.id)

    {_result, delete_flush_queries} =
      capture_repo_queries(view.pid, fn ->
        render_click(view, "cancel_delete")
        _ = :sys.get_state(view.pid)
      end)

    assert delete_flush_queries != []
    assert_no_pending_pool_traffic_refresh(view)

    open_create_dialog(view)
    assert_deferred_traffic_refresh(view, pool.id)

    view
    |> element("#pool-create-form")
    |> render_submit(%{"pool" => %{"name" => "Mutation clears traffic refresh"}})

    assert has_element?(
             view,
             "#pool-row-#{Repo.get_by!(Pool, slug: "mutation-clears-traffic-refresh").id}"
           )

    assert_no_pending_pool_traffic_refresh(view)
    _ = await_pool_traffic(view)
  end

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
        "request_compression_enabled" => true,
        "allow_image_generation" => false
      })

    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = await_pool_traffic(view)

    view |> element("#edit-pool-#{pool.id}") |> render_click()

    refute has_element?(view, "#pool_edit_prompt_cache_affinity_enabled[checked]")
    assert has_element?(view, "#pool_edit_request_compression_enabled[checked]")
    refute has_element?(view, "#pool_edit_allow_image_generation[checked]")

    view
    |> element("#pool-edit-form")
    |> render_submit(%{
      "pool_edit" => %{
        "id" => pool.id,
        "name" => "Preserved Routing",
        "status" => "active",
        "routing_strategy" => "quota_first",
        "prompt_cache_affinity_enabled" => "false",
        "v1_compatibility_enabled" => "false",
        "request_compression_enabled" => "false",
        "allow_image_generation" => "true",
        "upstream_identity_ids" => []
      }
    })

    settings = pool |> Pools.get_routing_settings() |> Repo.reload!()

    assert settings.routing_strategy == "quota_first"
    assert settings.bridge_ring_size == 7
    assert settings.sticky_websocket_sessions == false
    assert settings.sticky_http_sessions == true
    assert settings.prompt_cache_affinity_enabled == false
    assert settings.v1_compatibility_enabled == false
    assert settings.request_compression_enabled == false
    assert settings.allow_image_generation == true
    assert Repo.get!(Pool, pool.id).name == "Preserved Routing"
    assert has_element?(view, "#pool-edit-dialog[open]")
    _ = await_pool_traffic(view)
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
    _ = await_pool_traffic(view)

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
    _ = await_pool_traffic(view)

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
        "v1_compatibility_enabled" => "false",
        "request_compression_enabled" => "true",
        "upstream_identity_ids" => [second_assignment.upstream_identity_id]
      }
    })

    assert has_element?(view, "#pool-edit-dialog[open]")

    assert has_element?(
             view,
             "#pool_edit_routing_strategy_deterministic_rotation[checked]"
           )

    assert has_element?(
             view,
             "#pool-edit-upstream-assignment-options input[checked][value='#{second_assignment.upstream_identity_id}']"
           )

    refute has_element?(view, "#pool_edit_prompt_cache_affinity_enabled[checked]")
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
    _ = await_pool_traffic(view)

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
    _ = await_pool_traffic(view)
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

  # Waits for the async traffic task, including coalesced re-runs, so tests
  # never leave a task holding a sandbox connection when the view is killed.
  defp await_pool_traffic(view, opts \\ []) do
    if Keyword.get(opts, :activate_histograms?, true) do
      state = :sys.get_state(view.pid)

      Enum.each(state.socket.assigns.pools, fn pool_row ->
        render_hook(view, "set_pool_traffic_visibility", %{
          "pool_id" => pool_row.pool.id,
          "visible" => true
        })
      end)
    end

    await_pool_traffic_tasks(view)
  end

  defp await_pool_traffic_tasks(view) do
    html = render_async(view, 2_000)
    state = :sys.get_state(view.pid)

    cond do
      state.socket.assigns.pool_traffic_running? ->
        await_pool_traffic_tasks(view)

      state.socket.assigns.pool_traffic_rerun? ->
        _cooldown_token = expire_pool_traffic_cooldown(view)
        await_pool_traffic_tasks(view)

      true ->
        html
    end
  end

  defp expire_pool_traffic_cooldown(view) do
    assigns = :sys.get_state(view.pid).socket.assigns
    timer_ref = Map.get(assigns, :pool_traffic_cooldown_timer)
    cooldown_token = Map.get(assigns, :pool_traffic_cooldown_token)

    if is_reference(timer_ref) and is_reference(cooldown_token) do
      Repo.query!(
        """
        UPDATE admin_pool_traffic_gates
        SET cooldown_until = statement_timestamp(), updated_at = statement_timestamp()
        WHERE operator_id = $1::text::uuid
          AND owner_token IS NULL
        """,
        [assigns.current_scope.user.id]
      )

      Process.cancel_timer(timer_ref, async: false, info: false)
      send(view.pid, {:pool_traffic_cooldown_elapsed, cooldown_token})
      _ = :sys.get_state(view.pid)
    end

    cooldown_token
  end

  defp assert_deferred_traffic_refresh(view, pool_id) do
    {_result, traffic_queries} =
      capture_repo_queries(view.pid, fn ->
        broadcast_usage_events(pool_id, 100)
        _ = :sys.get_state(view.pid)
      end)

    assert traffic_queries == []

    state = :sys.get_state(view.pid)
    assert state.socket.assigns.pool_traffic_dirty?
    assert is_nil(state.socket.assigns.pool_traffic_refresh_timer)
  end

  defp assert_no_pending_pool_traffic_refresh(view) do
    state = :sys.get_state(view.pid)
    refute state.socket.assigns.pool_traffic_dirty?
    assert is_nil(state.socket.assigns.pool_traffic_refresh_timer)
  end

  defp broadcast_usage_events(pool_id, count) do
    Enum.each(1..count, fn _index ->
      assert {:ok, _event} = Events.broadcast_usage(pool_id, "usage_updated", %{})
    end)
  end

  defp capture_repo_queries(query_pid, fun) when is_pid(query_pid) and is_function(fun, 0) do
    test_pid = self()
    handler_id = {__MODULE__, :repo_query, test_pid, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo and self() == query_pid do
            send(test_pid, {handler_id, metadata[:source]})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_query_sources(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_query_sources(handler_id, sources) do
    receive do
      {^handler_id, source} -> drain_repo_query_sources(handler_id, [to_string(source) | sources])
    after
      0 -> Enum.reverse(sources)
    end
  end

  defp drain_lazy_query_pids(handler_id, query_pids) do
    receive do
      {^handler_id, :query, query_pid} ->
        drain_lazy_query_pids(handler_id, MapSet.put(query_pids, query_pid))
    after
      0 -> query_pids
    end
  end

  defp pool_traffic_projection_query?(metadata) do
    query = to_string(metadata[:query] || "")

    metadata[:repo] == Repo and
      not String.contains?(query, "admin_pool_traffic") and
      not String.contains?(query, "pg_advisory")
  end

  defp attach_pool_projection_telemetry do
    test_pid = self()
    telemetry_ref = make_ref()
    handler_id = {__MODULE__, :pool_projection, telemetry_ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            send(test_pid, {telemetry_ref, self(), metadata})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    telemetry_ref
  end

  defp assert_pool_patch_params(view, expected_params) do
    patched_path = assert_patch(view)
    uri = URI.parse(patched_path)

    assert uri.path == "/admin/pools"
    assert URI.decode_query(uri.query || "") == expected_params

    patched_path
  end

  defp drain_pool_projection_telemetry(telemetry_ref, events \\ []) do
    receive do
      {^telemetry_ref, query_pid, metadata} ->
        drain_pool_projection_telemetry(telemetry_ref, [{query_pid, metadata} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp structural_projection_count(events, view) do
    structural_pids = MapSet.new([self(), view.pid])

    Enum.count(events, fn {query_pid, metadata} ->
      MapSet.member?(structural_pids, query_pid) and
        to_string(metadata[:source]) == "upstream_identities"
    end)
  end

  defp traffic_projection_pids(events, view) do
    excluded_pids = MapSet.new([self(), view.pid])

    Enum.reduce(events, MapSet.new(), fn {query_pid, metadata}, query_pids ->
      if not MapSet.member?(excluded_pids, query_pid) and traffic_projection_query?(metadata) do
        MapSet.put(query_pids, query_pid)
      else
        query_pids
      end
    end)
  end

  defp traffic_projection_query?(metadata) do
    pool_traffic_projection_query?(metadata) and
      Enum.any?(metadata[:params] || [], &match?(%DateTime{}, &1))
  end

  defp traffic_projection_window(metadata) do
    now = DateTime.utc_now()

    metadata[:params]
    |> List.wrap()
    |> Enum.find_value(fn
      %DateTime{} = timestamp ->
        age_seconds = DateTime.diff(now, timestamp, :second)

        cond do
          age_seconds in (20 * 60 * 60)..(28 * 60 * 60) -> :twenty_four_hours
          age_seconds in (5 * 24 * 60 * 60)..(8 * 24 * 60 * 60) -> :seven_days
          true -> nil
        end

      _other ->
        nil
    end)
  end

  defp traffic_projection_windows(events, view) do
    traffic_pids = traffic_projection_pids(events, view)

    events
    |> Enum.filter(fn {query_pid, _metadata} -> MapSet.member?(traffic_pids, query_pid) end)
    |> Enum.reduce(MapSet.new(), fn {_query_pid, metadata}, windows ->
      case traffic_projection_window(metadata) do
        nil -> windows
        window -> MapSet.put(windows, window)
      end
    end)
  end

  defp hold_pool_traffic_advisory_lock(operator_id, holder_ref) do
    test_pid = self()

    Task.async(fn ->
      run_pool_traffic_advisory_lock_connection(operator_id, holder_ref, test_pid)
    end)
  end

  defp run_pool_traffic_advisory_lock_connection(operator_id, holder_ref, test_pid) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.checkout(fn ->
        run_pool_traffic_advisory_lock_holder(operator_id, holder_ref, test_pid)
      end)
    end)
  end

  defp run_pool_traffic_advisory_lock_holder(operator_id, holder_ref, test_pid) do
    assert {:ok, %{rows: [[lock_key, true]]}} =
             Repo.query(
               """
               SELECT
                 hashtextextended('admin_pool_traffic:' || $1::text, 0),
                 pg_try_advisory_lock(
                   hashtextextended('admin_pool_traffic:' || $1::text, 0)
                 )
               """,
               [operator_id]
             )

    send(test_pid, {holder_ref, :lock_held, self()})

    receive do
      {^holder_ref, :release} -> :ok
    after
      2_000 -> flunk("timed out waiting to release Pool traffic advisory lock")
    end

    assert {:ok, %{rows: [[true]]}} =
             Repo.query("SELECT pg_advisory_unlock($1)", [lock_key])

    :ok
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

  defp assert_pool_wizard_tab_order(view, dialog_id, expected_tabs) do
    Enum.with_index(expected_tabs, 1)
    |> Enum.each(fn {{step_id, label}, ordinal} ->
      tab_selector =
        "##{dialog_id}-tabs > li:nth-child(#{ordinal}) > ##{dialog_id}-tab-#{step_id}"

      assert has_element?(view, "#{tab_selector}[role='tab']", label)

      assert has_element?(
               view,
               "#{tab_selector} [data-role='policy-editor-step-marker']",
               Integer.to_string(ordinal)
             )
    end)

    refute has_element?(
             view,
             "##{dialog_id}-tabs > li:nth-child(#{length(expected_tabs) + 1})"
           )
  end

  defp open_edit_models(view, pool) do
    view |> element("#edit-pool-#{pool.id}") |> render_click()
    _ = render_async(view)
    view |> element("#pool-edit-dialog-tab-models") |> render_click()
  end

  defp model_serving_revision(view) do
    html = view |> element("#pool-model-serving-revision") |> render()
    [_, revision] = Regex.run(~r/\bvalue="([a-f0-9]+)"/, html)
    revision
  end

  defp catalog_sync_run_fixture(pool, status, opts \\ []) do
    finished_at = Keyword.get(opts, :finished_at, DateTime.utc_now())
    started_at = Keyword.get(opts, :started_at, DateTime.add(finished_at, -1, :second))

    %SyncRun{}
    |> SyncRun.changeset(%{
      pool_id: pool.id,
      trigger_kind: "manual",
      status: status,
      started_at: started_at,
      finished_at: if(status in ["succeeded", "failed", "cancelled"], do: finished_at),
      discovered_model_count: 0,
      upserted_model_count: 0,
      stale_marked_count: 0,
      retired_count: 0,
      error_message: if(status == "failed", do: "model catalog refresh failed"),
      stats: %{}
    })
    |> Repo.insert!()
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
