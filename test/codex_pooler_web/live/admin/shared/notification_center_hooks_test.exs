defmodule CodexPoolerWeb.Admin.NotificationCenterHooksTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Phoenix.LiveViewTest

  alias CodexPooler.Accounts
  alias CodexPooler.Admin.PoolWorkflow
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Incidents.NotificationEvents
  alias CodexPooler.Events
  alias CodexPooler.Events.Event
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.AlertNotificationsReadModel

  # Named detection budget for a NOTIFY committed on another connection to come
  # back through the application's notifications process, bridge and PubSub;
  # the green path finishes on the relayed message.
  @relay_detection_timeout_ms 15_000

  setup :register_and_log_in_user

  test "admin sessions refresh notification center after scoped incident invalidation", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique_slug("incident"), name: "Incident"})
    {:ok, first_view, _html} = live(conn, ~p"/admin/pools")
    _ = render_async(first_view, 2_000)
    {:ok, second_view, _html} = live(conn, ~p"/admin/jobs")

    assert %{badge_count: 0, badge_label: "0", rows: [], has_rows?: false, empty?: true} =
             notification_center(first_view)

    assert %{badge_count: 0, rows: []} = notification_center(second_view)

    incident = record_bell_incident!(pool)

    assert %{badge_count: 1, badge_label: "1", rows: [%{id: incident_id}], has_rows?: true} =
             notification_center(first_view)

    assert incident_id == incident.id

    assert %{badge_count: 1, rows: [%{id: ^incident_id}]} = notification_center(second_view)
  end

  test "receipt mutations refresh all open admin sessions for the current operator", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique_slug("receipt"), name: "Receipt"})
    first = record_bell_incident!(pool, %{dedupe_key: unique_dedupe("receipt-first")})
    second = record_bell_incident!(pool, %{dedupe_key: unique_dedupe("receipt-second")})
    first_id = first.id
    second_id = second.id

    {:ok, first_view, _html} = live(conn, ~p"/admin/pools")
    _ = render_async(first_view, 2_000)
    {:ok, second_view, _html} = live(conn, ~p"/admin/jobs")

    assert %{badge_count: 2, rows: rows} = notification_center(first_view)
    assert MapSet.new(Enum.map(rows, & &1.id)) == MapSet.new([first_id, second_id])

    assert {:ok, _receipt} = Alerts.mark_incident_notification_read(scope, first.id)

    first_center = notification_center(first_view)
    assert first_center.badge_count == 1
    assert %{id: ^first_id, unread?: false} = Enum.find(first_center.rows, &(&1.id == first_id))
    assert %{id: ^second_id, unread?: true} = Enum.find(first_center.rows, &(&1.id == second_id))

    second_center = notification_center(second_view)
    assert second_center.badge_count == 1
    assert %{id: ^first_id, unread?: false} = Enum.find(second_center.rows, &(&1.id == first_id))
    assert %{id: ^second_id, unread?: true} = Enum.find(second_center.rows, &(&1.id == second_id))

    assert {:ok, _receipt} = Alerts.dismiss_incident_notification(scope, first.id)
    assert %{badge_count: 1, rows: [%{id: ^second_id}]} = notification_center(first_view)
    assert %{badge_count: 1, rows: [%{id: ^second_id}]} = notification_center(second_view)

    assert {:ok, 1} = Alerts.dismiss_all_visible_incident_notifications(scope)
    assert %{badge_count: 0, rows: [], empty?: true} = notification_center(first_view)
    assert %{badge_count: 0, rows: [], empty?: true} = notification_center(second_view)
  end

  test "hidden pool incident invalidations do not refresh unassigned admins", %{
    conn: owner_conn,
    scope: owner_scope
  } do
    {:ok, assigned_pool} =
      Pools.create_pool(owner_scope, %{slug: unique_slug("assigned"), name: "Assigned"})

    {:ok, hidden_pool} =
      Pools.create_pool(owner_scope, %{slug: unique_slug("hidden"), name: "Hidden"})

    assigned_conn = assigned_admin_conn(owner_scope, assigned_pool)
    {:ok, owner_view, _html} = live(owner_conn, ~p"/admin/pools")
    _ = render_async(owner_view, 2_000)
    {:ok, assigned_view, _html} = live(assigned_conn, ~p"/admin/pools")
    _ = render_async(assigned_view, 2_000)

    assert %{badge_count: 0, rows: []} = notification_center(owner_view)
    assert %{badge_count: 0, rows: []} = notification_center(assigned_view)

    hidden_incident = record_bell_incident!(hidden_pool)

    assert %{badge_count: 1, rows: [%{id: hidden_incident_id}]} =
             notification_center(owner_view)

    assert hidden_incident_id == hidden_incident.id
    assert %{badge_count: 0, rows: [], empty?: true} = notification_center(assigned_view)
  end

  # An incident on an upstream identity shared by several Pools has a target in
  # each of them, and a page subscribes to every Pool it can see, so the one
  # invalidation reaches the page once per shared Pool; each copy used to
  # reload the notification center (findings#206 row 206-270).
  test "an incident over several shared Pools reloads an open notification center once", %{conn: conn, scope: scope} do
    pools = for index <- 1..3, do: pool!(scope, "shared-#{index}")
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    trace_notification_reloads!(view)

    incident = record_shared_incident!(pools)
    incident_id = incident.id

    assert notification_reloads(view) == 1
    assert %{badge_count: 1, rows: [%{id: ^incident_id}]} = notification_center(view)
  end

  # Coalescing must not merge two invalidations, and a page that sees one Pool
  # of a shared incident still reloads while a page that sees none does not.
  test "each invalidation of a visible Pool reloads once and hidden Pools never reload", %{
    conn: owner_conn,
    scope: owner_scope
  } do
    [hidden_pool, shared_pool] = for label <- ["hidden", "visible"], do: pool!(owner_scope, label)
    other_hidden_pool = pool!(owner_scope, "other-hidden")
    {:ok, owner_view, _html} = live(owner_conn, ~p"/admin/jobs")
    {:ok, assigned_view, _html} = live(assigned_admin_conn(owner_scope, shared_pool), ~p"/admin/jobs")
    trace_notification_reloads!(owner_view)
    trace_notification_reloads!(assigned_view)

    incident = record_shared_incident!([hidden_pool, shared_pool])
    incident_id = incident.id

    assert notification_reloads(owner_view) == 1
    assert notification_reloads(assigned_view) == 1
    assert %{badge_count: 1, rows: [%{id: ^incident_id}]} = notification_center(assigned_view)

    assert {:ok, %{state: "resolved"}} = Alerts.clear_incident_condition(incident.dedupe_key)

    assert notification_reloads(owner_view) == 1
    assert notification_reloads(assigned_view) == 1
    assert %{badge_count: 0, rows: []} = notification_center(assigned_view)

    _hidden = record_shared_incident!([hidden_pool, other_hidden_pool])

    assert notification_reloads(owner_view) == 1
    assert notification_reloads(assigned_view) == 0
  end

  # During a rolling update a clustered app pod still on the previous release
  # broadcasts the invalidation without an id. The jobs page has no catch-all
  # `handle_info/2`, so a message the hook passed on would crash it.
  test "an invalidation without an id from a previous release reloads the page instead of crashing it", %{
    conn: conn,
    scope: scope
  } do
    pool = pool!(scope, "previous-release")
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    trace_notification_reloads!(view)
    page_ref = Process.monitor(view.pid)

    Phoenix.PubSub.broadcast(CodexPooler.PubSub, NotificationEvents.pool_topic(pool.id), {NotificationEvents, :invalidated})

    assert notification_reloads(view) == 1
    refute_received {:DOWN, ^page_ref, :process, _pid, _reason}
  end

  # Deleting a rule drops its incident targets by database cascade, which sends
  # nothing: an open notification center kept an incident its viewer could no
  # longer see (findings#206 row 206-301). Every page that sees a Pool of the
  # incident reloads once, including one whose Pool keeps its target (its
  # impacted Pool counts change); a page that sees none of them does not.
  test "deleting an alert rule reloads the notification centers of its incidents' Pools once", %{
    conn: owner_conn,
    scope: owner_scope
  } do
    [rule_pool, other_pool, unrelated_pool] = for label <- ["rule", "other", "unrelated"], do: pool!(owner_scope, label)
    {incident, [rule, _other_rule]} = record_shared_incident_with_rules!([rule_pool, other_pool])
    incident_id = incident.id
    [owner_view, rule_pool_view, other_pool_view, unrelated_view] = views = open_notification_centers!(owner_conn, owner_scope, [rule_pool, other_pool, unrelated_pool])

    assert %{badge_count: 1, rows: [%{id: ^incident_id}]} = notification_center(rule_pool_view)
    assert %{rows: [%{id: ^incident_id, total_impacted_pool_count: 2, hidden_impacted_pool_count: 1}]} = notification_center(other_pool_view)

    assert {:ok, _deleted} = Alerts.delete_rule(owner_scope, rule)

    assert Enum.map(views, &notification_reloads/1) == [1, 1, 1, 0]
    assert %{badge_count: 1, rows: [%{id: ^incident_id, total_impacted_pool_count: 1}]} = notification_center(owner_view)
    assert %{badge_count: 0, rows: [], empty?: true} = notification_center(rule_pool_view)
    assert %{rows: [%{id: ^incident_id, total_impacted_pool_count: 1, hidden_impacted_pool_count: 0}]} = notification_center(other_pool_view)
    assert %{badge_count: 0, rows: []} = notification_center(unrelated_view)
  end

  # Only an archived Pool can be deleted, and no notification center shows an
  # archived Pool's incidents, so what the cascade changes is the impacted Pool
  # counts of an incident it shared with an active Pool: those pages reload
  # once. A page that sees only the archived Pool, or an unrelated one, does
  # not.
  test "deleting a Pool reloads the notification centers of the Pools its incidents shared once", %{conn: owner_conn, scope: owner_scope} do
    [deleted_pool, other_pool, unrelated_pool] = for label <- ["deleted", "kept", "unrelated"], do: pool!(owner_scope, label)
    {shared, _rules} = record_shared_incident_with_rules!([deleted_pool, other_pool])
    _own = record_bell_incident!(deleted_pool)
    shared_id = shared.id
    assert {:ok, archived_pool} = Pools.change_pool_status(owner_scope, deleted_pool, "archived")
    [owner_view, deleted_pool_view, other_pool_view, unrelated_view] = views = open_notification_centers!(owner_conn, owner_scope, [deleted_pool, other_pool, unrelated_pool])

    assert %{badge_count: 1, rows: [%{id: ^shared_id, total_impacted_pool_count: 2, hidden_impacted_pool_count: 1}]} = notification_center(owner_view)
    assert %{badge_count: 0} = notification_center(deleted_pool_view)
    assert %{rows: [%{id: ^shared_id, total_impacted_pool_count: 2, hidden_impacted_pool_count: 1}]} = notification_center(other_pool_view)

    assert {:ok, _deleted} = Pools.delete_archived_pool(owner_scope, archived_pool, archived_pool.slug)

    assert Enum.map(views, &notification_reloads/1) == [1, 0, 1, 0]
    assert %{badge_count: 1, rows: [%{id: ^shared_id, total_impacted_pool_count: 1, hidden_impacted_pool_count: 0}]} = notification_center(owner_view)
    assert %{badge_count: 0, rows: []} = notification_center(deleted_pool_view)
    assert %{rows: [%{id: ^shared_id, total_impacted_pool_count: 1, hidden_impacted_pool_count: 0}]} = notification_center(other_pool_view)
    assert %{badge_count: 0, rows: []} = notification_center(unrelated_view)
  end

  # A notification center shows only active Pools' incidents, and a Pool status
  # change sent nothing: an open page kept a disabled Pool's incident and went
  # on listening to the Pool (findings#206 row 206-308). The pages that saw the
  # Pool reload once and stop listening; a page that never saw it does not.
  test "disabling a Pool reloads the notification centers that saw it once and stops listening to it", %{conn: owner_conn, scope: owner_scope} do
    [pool, unrelated_pool] = for label <- ["disabled", "unrelated"], do: pool!(owner_scope, label)
    incident_id = record_bell_incident!(pool).id
    [owner_view, pool_view, unrelated_view] = views = open_notification_centers!(owner_conn, owner_scope, [pool, unrelated_pool])

    assert %{badge_count: 1, rows: [%{id: ^incident_id}]} = notification_center(owner_view)
    assert %{badge_count: 1, rows: [%{id: ^incident_id}]} = notification_center(pool_view)

    assert {:ok, _disabled} = Pools.change_pool_status(owner_scope, pool, "disabled")

    assert Enum.map(views, &notification_reloads/1) == [1, 1, 0]
    assert %{badge_count: 0, rows: []} = notification_center(owner_view)
    assert %{badge_count: 0, rows: []} = notification_center(pool_view)
    assert %{badge_count: 0, rows: []} = notification_center(unrelated_view)

    _hidden = record_bell_incident!(pool)

    assert Enum.map(views, &notification_reloads/1) == [0, 0, 0]
  end

  # A page subscribes only to the Pools its viewer can see, so a reactivated
  # Pool's incidents never reached an open page until it navigated. The
  # operators who see the Pool again are told on their own topics; their pages
  # reload once and listen to it from then on. A page of an admin not assigned
  # to it hears nothing and never listens to it.
  test "reactivating a Pool reloads the notification centers of the operators who see it again and listens to it", %{conn: owner_conn, scope: owner_scope} do
    [pool, unrelated_pool] = for label <- ["reactivated", "unrelated"], do: pool!(owner_scope, label)
    first_id = record_bell_incident!(pool).id
    assert {:ok, disabled} = Pools.change_pool_status(owner_scope, pool, "disabled")
    [owner_view, pool_view, unrelated_view] = views = open_notification_centers!(owner_conn, owner_scope, [pool, unrelated_pool])

    assert Enum.map(views, &notification_center(&1).badge_count) == [0, 0, 0]

    assert {:ok, _active} = Pools.change_pool_status(owner_scope, disabled, "active")

    assert Enum.map(views, &notification_reloads/1) == [1, 1, 0]
    assert %{badge_count: 1, rows: [%{id: ^first_id}]} = notification_center(owner_view)
    assert %{badge_count: 1, rows: [%{id: ^first_id}]} = notification_center(pool_view)
    assert %{badge_count: 0, rows: []} = notification_center(unrelated_view)

    second_id = record_bell_incident!(pool).id

    assert Enum.map(views, &notification_reloads/1) == [1, 1, 0]
    assert %{badge_count: 2, rows: rows} = notification_center(pool_view)
    assert rows |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([first_id, second_id])
    assert %{badge_count: 0} = notification_center(unrelated_view)
  end

  # A Pool created while a page is open is one more Pool its owner can see; the
  # page subscribed once at mount, so the new Pool's first incident never
  # reached it. The owners' pages reload once and listen to it; an assigned
  # admin's page hears nothing.
  test "creating a Pool reloads the owners' notification centers once and they hear its incidents", %{conn: owner_conn, scope: owner_scope} do
    assigned_pool = pool!(owner_scope, "assigned")
    [owner_view, admin_view] = views = open_notification_centers!(owner_conn, owner_scope, [assigned_pool])

    assert {:ok, created} = PoolWorkflow.create_pool_with_related_settings(owner_scope, %{"name" => "Notification created #{unique_suffix()}"})

    assert Enum.map(views, &notification_reloads/1) == [1, 0]

    direct = pool!(owner_scope, "created-direct")

    assert Enum.map(views, &notification_reloads/1) == [1, 0]

    for pool <- [created, direct] do
      incident_id = record_bell_incident!(pool).id

      assert Enum.map(views, &notification_reloads/1) == [1, 0]
      assert Enum.any?(notification_center(owner_view).rows, &(&1.id == incident_id))
    end

    assert %{badge_count: 0} = notification_center(admin_view)
  end

  # The Pool editor changes the status inside a transaction with the rest of
  # the Pool's settings, so the notification centers hear of it after the
  # commit, and an edit that keeps the status reloads nobody. Archiving revokes
  # the admin's assignment and restoring does not bring it back, so only the
  # owner sees the restored Pool's incident again.
  test "archiving a Pool in the Pool editor and restoring it reloads the notification centers whose Pools it changes once", %{conn: owner_conn, scope: owner_scope} do
    [pool, unrelated_pool] = for label <- ["archived", "unrelated"], do: pool!(owner_scope, label)
    incident_id = record_bell_incident!(pool).id
    [owner_view, pool_view, _unrelated_view] = views = open_notification_centers!(owner_conn, owner_scope, [pool, unrelated_pool])

    assert {:ok, %{status: "active"}} = PoolWorkflow.update_pool_with_related_settings(owner_scope, pool.id, pool_edit_attrs(pool, "active", "Renamed"))

    assert Enum.map(views, &notification_reloads/1) == [0, 0, 0]

    assert {:ok, %{status: "archived"} = archived} = PoolWorkflow.update_pool_with_related_settings(owner_scope, pool.id, pool_edit_attrs(pool, "archived"))

    assert Enum.map(views, &notification_reloads/1) == [1, 1, 0]
    assert Enum.map(views, &notification_center(&1).badge_count) == [0, 0, 0]

    assert {:ok, %{status: "active"}} = Pools.change_pool_status(owner_scope, archived, "active")

    assert Enum.map(views, &notification_reloads/1) == [1, 0, 0]
    assert %{badge_count: 1, rows: [%{id: ^incident_id}]} = notification_center(owner_view)
    assert %{badge_count: 0} = notification_center(pool_view)
  end

  # The same through the Pools page an operator uses: its form submit is the
  # producer, so the pages are awaited on their notification centers.
  test "disabling a Pool from the Pools page empties the notification centers that saw its incidents", %{conn: owner_conn, scope: owner_scope} do
    pool = pool!(owner_scope, "pools-page")
    incident_id = record_bell_incident!(pool).id
    [owner_view, pool_view] = open_notification_centers!(owner_conn, owner_scope, [pool])
    assert %{badge_count: 1, rows: [%{id: ^incident_id}]} = notification_center(pool_view)
    {:ok, pools_view, _html} = live(owner_conn, ~p"/admin/pools")
    _ = render_async(pools_view, 2_000)

    pools_view |> element("#edit-pool-#{pool.id}") |> render_click()
    pools_view |> element("#pool-edit-form") |> render_submit(%{"pool_edit" => %{"id" => pool.id, "name" => pool.name, "status" => "disabled"}})

    assert Repo.get!(CodexPooler.Pools.Pool, pool.id).status == "disabled"
    assert %{badge_count: 0, rows: []} = await_notification_center!(owner_view, &(&1.badge_count == 0))
    assert %{badge_count: 0, rows: []} = await_notification_center!(pool_view, &(&1.badge_count == 0))
  end

  # Assigning a Pool to an admin changes which Pools the admin sees, and the
  # assignment sent nothing: the admin's open page never heard the Pool's
  # incidents until it navigated (findings#206 row 206-319). The admin's own
  # topic carries one invalidation after the commit; the page reloads once,
  # shows the Pool's incident and listens to the Pool from then on. The owner
  # and an unrelated admin hear nothing.
  test "assigning a Pool to an admin reloads that admin's notification centers once and they hear its incidents", %{conn: owner_conn, scope: owner_scope} do
    [assigned_pool, new_pool] = for label <- ["kept", "granted"], do: pool!(owner_scope, label)
    first_id = record_bell_incident!(new_pool).id
    %{user: admin, conn: admin_conn} = assigned_admin!(owner_scope, [assigned_pool])
    [owner_view, admin_view, unrelated_view] = views = open_pages!([owner_conn, admin_conn, assigned_admin_conn(owner_scope, assigned_pool)])

    assert %{badge_count: 0} = notification_center(admin_view)

    assert {:ok, _admin} = Accounts.update_operator(owner_scope, admin, %{"pool_ids" => [assigned_pool.id, new_pool.id]})

    assert Enum.map(views, &notification_reloads/1) == [0, 1, 0]
    assert %{badge_count: 1, rows: [%{id: ^first_id}]} = notification_center(admin_view)
    assert %{badge_count: 0} = notification_center(unrelated_view)

    _second = record_bell_incident!(new_pool)

    assert Enum.map(views, &notification_reloads/1) == [1, 1, 0]
    assert %{badge_count: 2} = notification_center(admin_view)
    assert %{badge_count: 2} = notification_center(owner_view)
    assert %{badge_count: 0} = notification_center(unrelated_view)
  end

  # Revoking the assignment is the other direction: the page reloads once,
  # drops the Pool's incident and stops listening to the Pool, so a later
  # incident on it never reaches the admin's page.
  test "revoking an admin's Pool assignment reloads that admin's notification centers once and stops listening to the Pool", %{conn: owner_conn, scope: owner_scope} do
    [kept_pool, revoked_pool] = for label <- ["kept", "revoked"], do: pool!(owner_scope, label)
    _first = record_bell_incident!(revoked_pool)
    %{user: admin, conn: admin_conn} = assigned_admin!(owner_scope, [kept_pool, revoked_pool])
    [_owner_view, admin_view] = views = open_pages!([owner_conn, admin_conn])

    assert %{badge_count: 1} = notification_center(admin_view)

    assert {:ok, _admin} = Accounts.update_operator(owner_scope, admin, %{"pool_ids" => [kept_pool.id]})

    assert Enum.map(views, &notification_reloads/1) == [0, 1]
    assert %{badge_count: 0, rows: []} = notification_center(admin_view)

    _hidden = record_bell_incident!(revoked_pool)

    assert Enum.map(views, &notification_reloads/1) == [1, 0]
    assert %{badge_count: 0, rows: []} = notification_center(admin_view)
  end

  # A role change changes every Pool the operator sees: an admin promoted to
  # owner sees them all, an owner demoted to admin only the assigned ones. Each
  # change through the operator editor reloads the operator's pages once.
  test "changing an operator's role reloads that operator's notification centers once and follows the Pools they see", %{conn: owner_conn, scope: owner_scope} do
    [assigned_pool, other_pool] = for label <- ["assigned", "other"], do: pool!(owner_scope, label)
    other_id = record_bell_incident!(other_pool).id
    %{user: admin, conn: admin_conn} = assigned_admin!(owner_scope, [assigned_pool])
    # The Jobs page remounts when its viewer gains or loses the owner role
    # (findings#206 row 206-329), so the role change is watched from a page that
    # does not follow the viewer.
    [_owner_view, admin_view] = views = open_pages!([owner_conn, admin_conn], ~p"/admin/audit-logs")

    assert %{badge_count: 0} = notification_center(admin_view)

    assert {:ok, _owner} = Accounts.update_operator(owner_scope, admin, %{"role" => "instance_owner"})

    assert Enum.map(views, &notification_reloads/1) == [0, 1]
    assert %{badge_count: 1, rows: [%{id: ^other_id}]} = notification_center(admin_view)

    assert {:ok, _admin} = Accounts.update_operator(owner_scope, admin, %{"role" => "instance_admin", "pool_ids" => [assigned_pool.id]})

    assert Enum.map(views, &notification_reloads/1) == [0, 1]
    assert %{badge_count: 0, rows: []} = notification_center(admin_view)

    _hidden = record_bell_incident!(other_pool)

    assert Enum.map(views, &notification_reloads/1) == [1, 0]
  end

  # An operator edit that keeps the role and the assignments changes no Pool
  # the operator sees, so no page reloads.
  test "an operator edit that keeps the role and the Pool assignments reloads no notification center", %{conn: owner_conn, scope: owner_scope} do
    pool = pool!(owner_scope, "unchanged")
    %{user: admin, conn: admin_conn} = assigned_admin!(owner_scope, [pool])
    views = open_pages!([owner_conn, admin_conn])

    assert {:ok, _admin} = Accounts.update_operator(owner_scope, admin, %{"display_name" => "Renamed #{unique_suffix()}"})
    assert {:ok, _admin} = Accounts.update_operator(owner_scope, admin, %{"role" => "instance_admin", "pool_ids" => [pool.id]})

    assert Enum.map(views, &notification_reloads/1) == [0, 0]
  end

  # The same through the Operators page an owner uses: its form submit is the
  # producer, so the admin's page is awaited on its notification center.
  test "assigning a Pool on the Operators page shows its incidents on the admin's open notification center", %{conn: owner_conn, scope: owner_scope} do
    [assigned_pool, new_pool] = for label <- ["page-kept", "page-granted"], do: pool!(owner_scope, label)
    incident_id = record_bell_incident!(new_pool).id
    %{user: admin, conn: admin_conn} = assigned_admin!(owner_scope, [assigned_pool])
    {:ok, admin_view, _html} = live(admin_conn, ~p"/admin/jobs")
    assert %{badge_count: 0} = notification_center(admin_view)
    {:ok, operators_view, _html} = live(owner_conn, ~p"/admin/operators")

    operators_view |> element("#edit-operator-#{admin.id}") |> render_click()

    operators_view
    |> element("#operator-edit-form")
    |> render_submit(%{"operator_edit" => %{"id" => admin.id, "email" => admin.email, "display_name" => "", "role" => "instance_admin", "pool_ids" => [assigned_pool.id, new_pool.id]}})

    assert Accounts.operator_lifecycle(admin).assigned_pool_ids |> Enum.sort() == Enum.sort([assigned_pool.id, new_pool.id])
    assert %{badge_count: 1, rows: [%{id: ^incident_id}]} = await_notification_center!(admin_view, &(&1.badge_count == 1))
  end

  # A newer release may send a notification message of a shape this one does
  # not know during a rolling update. These pages have no catch-all
  # `handle_info/2`, so a message the hook passed on would crash them; the hook
  # takes every message under the tag and reloads (findings#206 row 206-302).
  for {path, label, message} <- [
        {"/admin/jobs", "an extra element", quote(do: {NotificationEvents, :invalidated, Ecto.UUID.generate(), %{"reason" => "future"}})},
        {"/admin/request-logs", "an unknown verb", quote(do: {NotificationEvents, :pruned, Ecto.UUID.generate()})},
        {"/admin/stats", "the bare tag", quote(do: {NotificationEvents})}
      ] do
    test "a notification message with #{label} from a newer release reloads #{path} instead of crashing it", %{conn: conn, scope: scope} do
      pool = pool!(scope, "newer-release")
      {:ok, view, _html} = live(conn, unquote(path))
      trace_notification_reloads!(view)
      page_ref = Process.monitor(view.pid)

      Phoenix.PubSub.broadcast(CodexPooler.PubSub, NotificationEvents.pool_topic(pool.id), unquote(message))

      assert notification_reloads(view) == 1
      refute_received {:DOWN, ^page_ref, :process, _pid, _reason}
    end
  end

  # The alert evaluation jobs run on the worker role, which is not in the app
  # pods' PubSub cluster: an incident it records reaches the app pods' pages only
  # as a PostgreSQL notification. A separate connection commits the worker's
  # notification; the incident rows are written without any PubSub broadcast.
  test "an incident another node recorded refreshes the notification center once through postgres", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique_slug("worker"), name: "Worker"})
    {:ok, view, _html} = live(conn, ~p"/admin/pools")
    _ = render_async(view, 2_000)
    assert %{badge_count: 0, rows: []} = notification_center(view)

    rule = alert_rule_fixture(pool, %{display_name: "Worker incident #{unique_suffix()}"})
    incident = alert_incident_fixture(pool: pool)
    _target = alert_incident_target_fixture(incident, rule, pool)
    incident_id = incident.id

    assert :ok = NotificationEvents.subscribe_pool(pool.id)
    assert :ok = Events.subscribe_pool(pool.id)
    sender = start_supervised!(%{id: :worker_connection, start: {Postgrex, :start_link, [connection_config()]}})
    marker = remote_pool_event(pool.id)

    notify!(sender, NotificationEvents.postgres_channel(), worker_alert_payload(pool.id))
    notify!(sender, Events.postgres_channel(), marker.payload)

    assert %{badge_count: 1, rows: [%{id: ^incident_id}]} = await_notification_center!(view, &(&1.badge_count == 1))

    # The trailing pool event travels the same connection and bridge, so once it
    # arrives a second copy of the invalidation would already be here.
    marker_event = marker.event
    assert_receive {Events, ^marker_event}, @relay_detection_timeout_ms
    assert_received {NotificationEvents, :invalidated, _invalidation_id}
    refute_received {NotificationEvents, :invalidated, _invalidation_id}
  end

  # Unclustered nodes get the invalidation of a shared incident as one
  # notification per Pool; they carry one invalidation id, so a page on an app
  # pod reloads once. A notification from a node that predates the id is its
  # own invalidation and still reloads.
  test "a shared incident another node recorded reloads the notification center once through postgres", %{
    conn: conn,
    scope: scope
  } do
    pools = for index <- 1..3, do: pool!(scope, "worker-shared-#{index}")
    {:ok, view, _html} = live(conn, ~p"/admin/jobs")
    trace_notification_reloads!(view)

    rule_pools = Enum.map(pools, &{alert_rule_fixture(&1, %{display_name: "Worker shared #{unique_suffix()}"}), &1})
    incident = alert_incident_fixture(pool: hd(pools))
    Enum.each(rule_pools, fn {rule, pool} -> alert_incident_target_fixture(incident, rule, pool) end)
    incident_id = incident.id

    sender = start_supervised!(%{id: :worker_connection, start: {Postgrex, :start_link, [connection_config()]}})
    invalidation_id = Ecto.UUID.generate()
    Enum.each(pools, &notify!(sender, NotificationEvents.postgres_channel(), worker_alert_payload(&1.id, invalidation_id)))

    marker = await_relayed_marker!(sender, hd(pools))
    assert notification_reloads(view) == 1
    assert %{badge_count: 1, rows: [%{id: ^incident_id}]} = notification_center(view)

    legacy_payload =
      hd(pools).id
      |> worker_alert_payload(Ecto.UUID.generate())
      |> CodexPooler.JSON.decode!()
      |> Map.delete("invalidation_id")
      |> CodexPooler.JSON.encode!()

    notify!(sender, NotificationEvents.postgres_channel(), legacy_payload)
    _marker = await_relayed_marker!(sender, hd(pools), marker)
    assert notification_reloads(view) == 1
  end

  test "an incident invalidation is also sent as one postgres notification per Pool naming one invalidation", %{scope: scope} do
    pools = for index <- 1..2, do: pool!(scope, "notify-#{index}")
    test_pid = self()
    telemetry_ref = make_ref()
    telemetry_id = "alert-notification-postgres-notify-#{unique_suffix()}"

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid, do: send(test_pid, {telemetry_ref, metadata.query, metadata.params})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    _incident = record_shared_incident!(pools)
    channel = NotificationEvents.postgres_channel()
    origin_node = Atom.to_string(node())
    origin_id = Events.origin_id()

    notifications =
      for _pool <- pools do
        assert_received {^telemetry_ref, "SELECT pg_notify($1, $2)", [^channel, payload]}

        assert %{"version" => 1, "scope" => "pool", "origin_id" => ^origin_id, "origin_node" => ^origin_node} =
                 notification = CodexPooler.JSON.decode!(payload)

        notification
      end

    refute_received {^telemetry_ref, "SELECT pg_notify($1, $2)", [^channel, _payload]}
    assert notifications |> Enum.map(& &1["target_id"]) |> Enum.sort() == pools |> Enum.map(& &1.id) |> Enum.sort()
    assert [invalidation_id] = notifications |> Enum.map(& &1["invalidation_id"]) |> Enum.uniq()
    assert {:ok, ^invalidation_id} = Ecto.UUID.cast(invalidation_id)
    assert notifications |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 2
  end

  # Counts the notification center reloads of one page: every reload is one
  # `AlertNotificationsReadModel.load/1` call in the page process. The trace
  # session is private to this test, so other tracers and pages are unaffected.
  defp trace_notification_reloads!(view) do
    session = :trace.session_create(:"#{__MODULE__}.#{unique_suffix()}", self(), [])
    on_exit(fn -> :trace.session_destroy(session) end)
    _ = :trace.function(session, {AlertNotificationsReadModel, :load, 1}, true, [:global])
    1 = :trace.process(session, view.pid, true, [:call])
    Process.put({__MODULE__, :reload_trace, view.pid}, session)
    :ok
  end

  # The reloads since the last count. Every invalidation reaches the page before
  # this call returns: the in-process broadcasts were sent by this process, which
  # `:sys.get_state/1` orders after them, and the relayed ones are awaited
  # through a marker first.
  defp notification_reloads(view) do
    session = Process.get({__MODULE__, :reload_trace, view.pid})
    _state = :sys.get_state(view.pid)
    delivered = :trace.delivered(session, view.pid)
    assert_receive {:trace_delivered, _tracee, ^delivered}, @relay_detection_timeout_ms
    count_reloads(view.pid, 0)
  end

  defp count_reloads(pid, count) do
    receive do
      {:trace, ^pid, :call, {AlertNotificationsReadModel, :load, [_scope]}} -> count_reloads(pid, count + 1)
    after
      0 -> count
    end
  end

  # A pool event sent after the alert notifications on the same connection
  # travels the same notifications process and bridge, so once it is relayed
  # every earlier invalidation has reached the page's mailbox. A page reads
  # this process's `:sys.get_state/1` only after that.
  defp await_relayed_marker!(sender, pool, previous \\ nil) do
    if previous == nil, do: assert(:ok = Events.subscribe_pool(pool.id))
    marker = remote_pool_event(pool.id)
    notify!(sender, Events.postgres_channel(), marker.payload)
    marker_event = marker.event
    assert_receive {Events, ^marker_event}, @relay_detection_timeout_ms
    marker
  end

  defp pool!(scope, label) do
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique_slug(label), name: "Notification #{label}"})
    pool
  end

  defp pool_edit_attrs(pool, status, name \\ nil) do
    %{"name" => name || pool.name, "status" => status, "routing_strategy" => "bridge_ring", "api_key_ids" => []}
  end

  defp record_shared_incident!(pools) do
    {incident, _rules} = record_shared_incident_with_rules!(pools)
    incident
  end

  defp record_shared_incident_with_rules!(pools) do
    %{identity: identity} = upstream_assignment_fixture(hd(pools))
    rules = Enum.map(pools, &alert_rule_fixture(&1, %{display_name: "Shared #{unique_suffix()}"}))
    targets = Enum.zip_with(rules, pools, &%{rule_id: &1.id, pool_id: &2.id})

    assert {:ok, incident} =
             Alerts.record_incident_match(%{
               dedupe_key: unique_dedupe("shared"),
               scope_type: "upstream_identity",
               rule_kind: "upstream_auth_state",
               severity: "critical",
               upstream_identity_id: identity.id,
               matched_at: now(),
               targets: targets
             })

    {incident, rules}
  end

  # The owner's page and one page per Pool, of an admin assigned to that Pool
  # only, each counting its notification center reloads from here on.
  defp open_notification_centers!(owner_conn, owner_scope, pools) do
    conns = [owner_conn | Enum.map(pools, &assigned_admin_conn(owner_scope, &1))]

    for conn <- conns do
      {:ok, view, _html} = live(conn, ~p"/admin/jobs")
      trace_notification_reloads!(view)
      view
    end
  end

  defp open_pages!(conns, path \\ ~p"/admin/jobs") do
    for conn <- conns do
      {:ok, view, _html} = live(conn, path)
      trace_notification_reloads!(view)
      view
    end
  end

  defp await_notification_center!(view, predicate) do
    deadline = System.monotonic_time(:millisecond) + @relay_detection_timeout_ms
    await_notification_center(view, predicate, deadline)
  end

  defp await_notification_center(view, predicate, deadline) do
    center = notification_center(view)

    cond do
      predicate.(center) ->
        center

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the notification center was not refreshed: #{inspect(Map.take(center, [:badge_count]))}")

      true ->
        receive do
        after
          10 -> await_notification_center(view, predicate, deadline)
        end
    end
  end

  defp worker_alert_payload(pool_id, invalidation_id \\ Ecto.UUID.generate()) do
    assert {:ok, payload} = NotificationEvents.postgres_payload("pool", pool_id, invalidation_id)

    payload
    |> CodexPooler.JSON.decode!()
    |> Map.put("origin_id", "notification-hooks-test-worker-" <> Ecto.UUID.generate())
    |> Map.put("origin_node", "notification-hooks-test-worker@127.0.0.1")
    |> CodexPooler.JSON.encode!()
  end

  defp remote_pool_event(pool_id) do
    event = %Event{
      version: 1,
      id: Ecto.UUID.generate(),
      pool_id: pool_id,
      topics: ["pools"],
      reason: "notification_hooks_marker",
      emitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      payload: %{}
    }

    assert {:ok, payload} = Events.event_to_postgres_payload(event)

    payload =
      payload
      |> CodexPooler.JSON.decode!()
      |> Map.put("origin_id", "notification-hooks-test-worker-" <> Ecto.UUID.generate())
      |> CodexPooler.JSON.encode!()

    %{event: event, payload: payload}
  end

  defp notify!(sender, channel, payload) do
    assert {:ok, _result} = Postgrex.query(sender, "SELECT pg_notify($1, $2)", [channel, payload])
  end

  defp connection_config do
    Keyword.take(Repo.config(), [:hostname, :port, :database, :username, :password, :ssl])
  end

  defp notification_center(view) do
    state = :sys.get_state(view.pid)
    state.socket.assigns.alert_notification_center
  end

  defp record_bell_incident!(pool, attrs \\ %{}) do
    attrs = Map.new(attrs)
    rule = alert_rule_fixture(pool, %{display_name: "Notification hook #{unique_suffix()}"})
    matched_at = Map.get(attrs, :matched_at, now())

    assert {:ok, incident} =
             Alerts.record_incident_match(%{
               dedupe_key: Map.get(attrs, :dedupe_key, unique_dedupe("hook")),
               scope_type: "pool",
               rule_kind: Map.get(attrs, :rule_kind, "pool_no_usable_assignments"),
               severity: Map.get(attrs, :severity, "critical"),
               pool_id: pool.id,
               matched_at: matched_at,
               targets: [%{rule_id: rule.id, pool_id: pool.id}]
             })

    incident
  end

  defp assigned_admin_conn(owner_scope, assigned_pool) do
    %{conn: conn} = assigned_admin!(owner_scope, [assigned_pool])
    conn
  end

  defp assigned_admin!(owner_scope, assigned_pools) do
    %{user: admin} =
      operator_fixture(owner_scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    Enum.each(assigned_pools, &operator_pool_assignment_fixture(admin, &1, created_by_user_id: owner_scope.user.id))

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => valid_user_password()})

    %{user: admin, conn: build_conn() |> log_in_user(admin, token)}
  end

  defp unique_slug(prefix), do: "notification-hooks-#{prefix}-#{unique_suffix()}"
  defp unique_dedupe(prefix), do: "alert:notification-hooks:#{prefix}:#{unique_suffix()}"
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp unique_suffix, do: System.unique_integer([:positive])
end
