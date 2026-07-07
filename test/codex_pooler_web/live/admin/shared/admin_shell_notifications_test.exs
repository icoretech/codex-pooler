defmodule CodexPoolerWeb.Admin.AdminShellNotificationsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Phoenix.LiveViewTest

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertIncident
  alias CodexPooler.Alerts.Schemas.AlertIncidentReceipt
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  test "renders the empty notification shell on shared admin pages", %{conn: conn} do
    for path <- [~p"/admin/upstreams", ~p"/admin/settings"] do
      {:ok, view, html} = live(conn, path)

      assert_single_notification_shell(html)
      assert has_element?(view, "#admin-notifications-button[role='button']")
      assert has_element?(view, "#admin-notifications-popover[aria-label='Admin notifications']")

      assert has_element?(view, "#admin-notifications-list.max-h-96.overflow-y-auto")
      assert has_element?(view, "#admin-notifications-list", "No active notifications")

      assert has_element?(
               view,
               "#admin-notifications-list [data-role='admin-notifications-empty-icon'] .hero-check-circle"
             )

      refute has_element?(view, "#admin-notifications-badge")
      refute has_element?(view, "#admin-notifications-dismiss-all")
      refute has_element?(view, "[data-role='admin-notification-row']")
    end
  end

  test "renders populated notification rows from the shared shell assign on two pages", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique_slug("shell"), name: "Shell Visible"})

    raw_snapshot = "raw prompt body #{unique_suffix()}"

    critical =
      shell_incident_fixture(pool, %{
        severity: "critical",
        last_seen_at: timestamp(~U[2026-05-31 14:30:00Z]),
        safe_evidence_snapshot: %{"prompt" => raw_snapshot}
      })

    acknowledged =
      shell_incident_fixture(pool, %{
        severity: "warning",
        state: "acknowledged",
        acknowledged_at: timestamp(~U[2026-05-31 14:10:00Z]),
        last_seen_at: timestamp(~U[2026-05-31 14:20:00Z])
      })

    for path <- [~p"/admin/upstreams", ~p"/admin/settings"] do
      {:ok, view, html} = live(conn, path)

      assert_single_notification_shell(html)
      assert has_element?(view, "#admin-notifications-badge", "2")
      assert has_element?(view, "#admin-notifications-dismiss-all", "Dismiss all")
      assert has_element?(view, "#admin-notifications-list.max-h-96.overflow-y-auto")

      assert_notification_row(view, critical,
        severity: "Critical",
        state: "Open",
        title: "No usable assignments",
        pool: "Shell Visible",
        last_seen: "2026-05-31 14:30 UTC"
      )

      assert_notification_row(view, acknowledged,
        severity: "Warning",
        state: "Acknowledged",
        title: "No usable assignments",
        pool: "Shell Visible",
        last_seen: "2026-05-31 14:20 UTC"
      )

      assert has_element?(
               view,
               "#admin-notification-row-#{critical.id}[data-alert-anchor-id='alert-incident-#{critical.id}']"
             )

      assert has_element?(
               view,
               "#admin-notification-row-#{critical.id} [data-role='admin-notification-unread-indicator']",
               "Unread"
             )

      refute html =~ raw_snapshot
    end
  end

  test "notification rows use a compact readable card structure", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique_slug("layout"), name: "Layout Visible"})
    incident = shell_incident_fixture(pool, %{dedupe_key: unique_dedupe("layout")})

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    row_selector = "#admin-notification-row-#{incident.id}"

    assert has_element?(view, "#{row_selector} [data-role='admin-notification-heading']")
    assert has_element?(view, "#{row_selector} [data-role='admin-notification-meta']")
    assert has_element?(view, "#{row_selector}.rounded-box.border.bg-base-100.p-3")

    assert has_element?(
             view,
             "#{row_selector} [data-role='admin-notification-severity'].inline-flex.items-center.rounded-full"
           )

    assert has_element?(
             view,
             "#{row_selector} [data-role='admin-notification-state'].inline-flex.items-center.rounded-full"
           )

    assert has_element?(view, "#{row_selector} [data-role='admin-notification-actions'].flex")

    assert has_element?(
             view,
             "#{row_selector} [data-role='admin-notification-primary-action'].justify-center"
           )

    assert has_element?(
             view,
             "#admin-notification-dismiss-#{incident.id}[aria-label='Dismiss notification']"
           )

    refute has_element?(view, "#admin-notification-dismiss-#{incident.id}", "Dismiss")
  end

  test "caps the badge label at 99 plus while the scroll list stays bounded", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique_slug("cap"), name: "Cap Visible"})

    for offset <- 1..105 do
      shell_incident_fixture(pool, %{
        severity: "info",
        dedupe_key: "alert:shell:cap:#{unique_suffix()}:#{offset}",
        last_seen_at: DateTime.add(timestamp(~U[2026-05-31 09:00:00Z]), offset, :second)
      })
    end

    {:ok, view, html} = live(conn, ~p"/admin/settings")

    assert_single_notification_shell(html)
    assert has_element?(view, "#admin-notifications-badge", "99+")
    assert has_element?(view, "#admin-notifications-dismiss-all")
    assert has_element?(view, "#admin-notifications-list.max-h-96.overflow-y-auto")
    assert count_occurrences(html, ~s(data-role="admin-notification-row")) == 50
  end

  test "primary notification action marks read and navigates to the anchored alert incident", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique_slug("open"), name: "Open Visible"})
    incident = shell_incident_fixture(pool, %{dedupe_key: unique_dedupe("primary")})

    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    assert has_element?(view, "#admin-notification-open-#{incident.id}", "View incident")

    view
    |> element("#admin-notification-open-#{incident.id}")
    |> render_click()

    assert_redirect(view, "/admin/alerts?tab=incidents#alert-incident-#{incident.id}")

    receipt =
      Repo.get_by!(AlertIncidentReceipt, operator_id: scope.user.id, incident_id: incident.id)

    assert Alerts.incident_notification_read?(incident, receipt)
    assert Repo.get!(AlertIncident, incident.id).state == incident.state

    {:ok, alerts_view, _html} = live(conn, ~p"/admin/alerts?tab=incidents")
    assert has_element?(alerts_view, "#alerts-tab-incidents[aria-selected='true']")
    assert has_element?(alerts_view, "#alert-incident-#{incident.id}")
  end

  test "inline mark-read and dismiss refresh same-operator open tabs", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique_slug("inline"), name: "Inline Visible"})
    incident = shell_incident_fixture(pool, %{dedupe_key: unique_dedupe("inline")})

    {:ok, first_view, _html} = live(conn, ~p"/admin/settings")
    {:ok, second_view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(first_view, "#admin-notification-mark-read-#{incident.id}", "Mark read")
    assert has_element?(second_view, "#admin-notification-row-#{incident.id}", "Unread")

    first_view
    |> element("#admin-notification-mark-read-#{incident.id}")
    |> render_click()

    _ = :sys.get_state(second_view.pid)
    refute has_element?(first_view, "#admin-notification-mark-read-#{incident.id}")
    refute has_element?(second_view, "#admin-notification-mark-read-#{incident.id}")
    assert has_element?(first_view, "#admin-notification-row-#{incident.id}")
    assert has_element?(second_view, "#admin-notification-row-#{incident.id}")

    first_view
    |> element("#admin-notification-dismiss-#{incident.id}")
    |> render_click()

    _ = :sys.get_state(second_view.pid)
    refute has_element?(first_view, "#admin-notification-row-#{incident.id}")
    refute has_element?(second_view, "#admin-notification-row-#{incident.id}")
    assert Repo.get!(AlertIncident, incident.id).state == incident.state
  end

  test "dismiss all is server-scoped and independent per operator", %{
    conn: owner_conn,
    scope: scope
  } do
    {:ok, assigned_pool} =
      Pools.create_pool(scope, %{slug: unique_slug("assigned"), name: "Assigned Visible"})

    {:ok, hidden_pool} =
      Pools.create_pool(scope, %{slug: unique_slug("hidden"), name: "Hidden Visible"})

    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: scope.user.id)
    admin_scope = Scope.for_user(admin)

    shared_incident =
      shell_incident_fixture(assigned_pool, %{dedupe_key: unique_dedupe("shared")})

    hidden_incident = shell_incident_fixture(hidden_pool, %{dedupe_key: unique_dedupe("hidden")})

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, owner_view, _html} = live(owner_conn, ~p"/admin/settings")
    {:ok, admin_view, _html} = live(admin_conn, ~p"/admin/settings")

    assert has_element?(owner_view, "#admin-notification-row-#{shared_incident.id}")
    assert has_element?(owner_view, "#admin-notification-row-#{hidden_incident.id}")
    assert has_element?(admin_view, "#admin-notification-row-#{shared_incident.id}")
    refute has_element?(admin_view, "#admin-notification-row-#{hidden_incident.id}")

    owner_view
    |> element("#admin-notifications-dismiss-all")
    |> render_click()

    refute has_element?(owner_view, "#admin-notification-row-#{shared_incident.id}")
    refute has_element?(owner_view, "#admin-notification-row-#{hidden_incident.id}")
    assert has_element?(admin_view, "#admin-notification-row-#{shared_incident.id}")

    refute Repo.get_by(AlertIncidentReceipt,
             operator_id: admin.id,
             incident_id: shared_incident.id
           )

    assert Repo.get!(AlertIncident, shared_incident.id).state == shared_incident.state
    assert Repo.get!(AlertIncident, hidden_incident.id).state == hidden_incident.state

    render_click(admin_view, "dismiss_alert_notification", %{"id" => hidden_incident.id})

    refute Repo.get_by(AlertIncidentReceipt,
             operator_id: admin.id,
             incident_id: hidden_incident.id
           )

    assert has_element?(admin_view, "#admin-notification-row-#{shared_incident.id}")
    assert Alerts.dismiss_all_visible_incident_notifications(admin_scope) == {:ok, 1}
  end

  defp assert_notification_row(view, incident, opts) do
    row_selector = "#admin-notification-row-#{incident.id}"

    assert has_element?(view, row_selector, Keyword.fetch!(opts, :title))
    assert has_element?(view, "#{row_selector}-severity", Keyword.fetch!(opts, :severity))
    assert has_element?(view, "#{row_selector}-state", Keyword.fetch!(opts, :state))
    assert has_element?(view, "#{row_selector}-severity[data-role='admin-notification-severity']")
    assert has_element?(view, "#{row_selector}-state[data-role='admin-notification-state']")
    assert has_element?(view, row_selector, Keyword.fetch!(opts, :pool))
    assert has_element?(view, row_selector, Keyword.fetch!(opts, :last_seen))
  end

  defp assert_single_notification_shell(html) do
    assert count_occurrences(html, ~s(id="admin-notifications-button")) == 1
    assert count_occurrences(html, ~s(id="admin-notifications-popover")) == 1
    assert count_occurrences(html, ~s(id="admin-notifications-list")) == 1
  end

  defp shell_incident_fixture(pool, attrs) do
    attrs = Map.new(attrs)
    rule = alert_rule_fixture(pool, %{display_name: "Shell rule #{unique_suffix()}"})

    incident =
      attrs
      |> Map.put_new(:dedupe_key, "alert:shell:#{unique_suffix()}")
      |> Map.put(:pool, pool)
      |> alert_incident_fixture()

    alert_incident_target_fixture(incident, rule, pool, %{
      first_matched_at: Map.get(attrs, :first_seen_at, incident.first_seen_at),
      last_matched_at: Map.get(attrs, :last_seen_at, incident.last_seen_at)
    })

    incident
  end

  defp count_occurrences(value, pattern) do
    value
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end

  defp timestamp(value), do: %{value | microsecond: {0, 6}}
  defp unique_slug(prefix), do: "admin-shell-notifications-#{prefix}-#{unique_suffix()}"
  defp unique_dedupe(prefix), do: "alert:shell:#{prefix}:#{unique_suffix()}"
  defp unique_suffix, do: System.unique_integer([:positive])
end
