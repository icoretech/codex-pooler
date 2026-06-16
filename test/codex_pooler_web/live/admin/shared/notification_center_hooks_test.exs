defmodule CodexPoolerWeb.Admin.NotificationCenterHooksTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Phoenix.LiveViewTest

  alias CodexPooler.Accounts
  alias CodexPooler.Alerts
  alias CodexPooler.Pools

  setup :register_and_log_in_user

  test "admin sessions refresh notification center after scoped incident invalidation", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique_slug("incident"), name: "Incident"})
    {:ok, first_view, _html} = live(conn, ~p"/admin/pools")
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
    {:ok, assigned_view, _html} = live(assigned_conn, ~p"/admin/pools")

    assert %{badge_count: 0, rows: []} = notification_center(owner_view)
    assert %{badge_count: 0, rows: []} = notification_center(assigned_view)

    hidden_incident = record_bell_incident!(hidden_pool)

    assert %{badge_count: 1, rows: [%{id: hidden_incident_id}]} =
             notification_center(owner_view)

    assert hidden_incident_id == hidden_incident.id
    assert %{badge_count: 0, rows: [], empty?: true} = notification_center(assigned_view)
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
    %{user: admin} =
      operator_fixture(owner_scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, assigned_pool,
      created_by_user_id: owner_scope.user.id
    )

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => valid_user_password()})

    build_conn() |> log_in_user(admin, token)
  end

  defp unique_slug(prefix), do: "notification-hooks-#{prefix}-#{unique_suffix()}"
  defp unique_dedupe(prefix), do: "alert:notification-hooks:#{prefix}:#{unique_suffix()}"
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp unique_suffix, do: System.unique_integer([:positive])
end
