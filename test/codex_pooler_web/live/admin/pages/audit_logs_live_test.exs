defmodule CodexPoolerWeb.Admin.AuditLogsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Phoenix.LiveViewTest

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.User
  alias CodexPooler.Alerts
  alias CodexPooler.Audit
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  test "renders redacted operator audit rows and filters by action and outcome", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "audit-page", name: "Audit Page"})
    {:ok, sorted_pool} = Pools.create_pool(scope, %{slug: "alpha-audit", name: "Alpha Audit"})
    hidden_pool = pool_fixture(%{slug: "hidden-audit", name: "Hidden Audit", status: "disabled"})

    assert {:ok, _settings} =
             Pools.update_routing_settings(scope, pool, %{"routing_strategy" => "quota_first"})

    assert %{items: [pool_routing_event]} =
             Audit.list_events(pool, filters: [action: "pool.routing_update"])

    assert {:ok, _settings} =
             Pools.update_routing_settings(scope, sorted_pool, %{
               "routing_strategy" => "least_recent_success"
             })

    assert {:ok, hidden_event} =
             Audit.record_system_event(%{
               pool_id: hidden_pool.id,
               action: "pool.update",
               target_type: "pool",
               target_id: hidden_pool.id,
               details: %{"hidden" => "should-not-render"}
             })

    sensitive_marker = "audit-page-secret-do-not-render"

    assert {:ok, operator_event} =
             Audit.record_user_event(user, %{
               action: "operator.update",
               target_type: "user",
               target_id: user.id,
               correlation_id: "operator-correlation",
               details: %{"safe" => "visible"}
             })

    request_id = Ecto.UUID.generate()

    assert {:error, :runtime_events_not_recorded} =
             Audit.record_system_event(%{
               pool_id: pool.id,
               action: "request.finalized",
               target_type: "request",
               target_id: request_id,
               outcome: "failure",
               correlation_id: "request-correlation",
               details: %{
                 "status" => "failed",
                 "authorization" => "Bearer #{sensitive_marker}"
               }
             })

    {:ok, view, _html} = live(conn, ~p"/admin/audit-logs")

    assert has_element?(view, "#admin-audit-logs-live")
    assert has_element?(view, "#audit-log-filter-form")
    refute has_element?(view, "#audit-log-filter-submit")
    refute has_element?(view, "#audit-log-filter-reset")
    assert has_element?(view, "#filters_pool_id[type='hidden']")
    assert has_element?(view, "#audit-log-pool-filter")
    refute has_element?(view, "#audit-log-filter-form label[for='audit-log-pool-filter']")
    assert has_element?(view, "#audit-log-pool-filter [aria-label='Pool']")

    assert has_element?(
             view,
             "#audit-log-pool-filter [data-role='pool-filter-trigger']",
             "All Pools"
           )

    assert has_element?(
             view,
             "#audit-log-pool-filter [data-role='pool-filter-trigger'] [data-role='pool-filter-icon'].text-base-content\\/60"
           )

    assert has_element?(
             view,
             "#audit-log-pool-filter button[data-pool-id='#{pool.id}']",
             "Audit Page"
           )

    assert has_element?(
             view,
             "#audit-log-pool-filter button[data-pool-id='#{pool.id}']",
             "Quota first"
           )

    assert has_element?(
             view,
             "#audit-log-pool-filter button[data-pool-id='#{pool.id}'] [data-role='pool-filter-icon'].text-success"
           )

    assert has_element?(
             view,
             "#audit-log-pool-filter button[data-pool-id='#{hidden_pool.id}']",
             "Hidden Audit"
           )

    assert has_element?(
             view,
             "#audit-log-pool-filter button[data-pool-id='#{hidden_pool.id}'] [data-role='pool-filter-icon'].text-warning"
           )

    html = render(view)
    all_pools_position = html =~ "All Pools"
    alpha_position = html =~ "Alpha Audit"
    audit_position = html =~ "Audit Page"
    hidden_position = html =~ "Hidden Audit"

    assert all_pools_position
    assert alpha_position
    assert audit_position
    assert hidden_position
    assert :binary.match(html, "All Pools") < :binary.match(html, "Alpha Audit")
    assert :binary.match(html, "Alpha Audit") < :binary.match(html, "Audit Page")

    refute has_element?(
             view,
             "#audit-log-pool-filter button[data-pool-id='#{pool.id}']",
             "audit-page"
           )

    assert has_element?(view, "#filters_outcome[type='hidden']")
    assert has_element?(view, "#audit-log-outcome-filter")
    refute has_element?(view, "#audit-log-filter-form label[for='audit-log-outcome-filter']")
    assert has_element?(view, "#audit-log-outcome-filter [aria-label='Outcome']")

    assert has_element?(
             view,
             "#audit-log-outcome-filter [data-role='outcome-filter-trigger']",
             "Any outcome"
           )

    assert has_element?(
             view,
             "#audit-log-outcome-filter [data-role='outcome-filter-trigger-icon'] .hero-squares-2x2"
           )

    assert has_element?(
             view,
             "#audit-log-outcome-filter [data-role='outcome-filter-menu'] button[data-outcome='success']",
             "Success"
           )

    assert has_element?(
             view,
             "#audit-log-outcome-filter button[data-outcome='success'] [data-role='outcome-filter-icon'].text-success"
           )

    assert has_element?(
             view,
             "#audit-log-outcome-filter [data-role='outcome-filter-menu'] button[data-outcome='failure']",
             "Failure"
           )

    assert has_element?(
             view,
             "#audit-log-outcome-filter button[data-outcome='failure'] [data-role='outcome-filter-icon'].text-error"
           )

    refute has_element?(view, "#audit-log-outcome-filter button[data-outcome='denied']")
    assert has_element?(view, "#filters_actor_type")
    refute has_element?(view, "#audit-log-filter-form-advanced label[for='filters_actor_type']")
    assert has_element?(view, "#filters_actor")
    refute has_element?(view, "#audit-log-filter-form-advanced label[for='filters_actor']")
    assert has_element?(view, "#filters_actor[aria-label='Actor']")
    assert has_element?(view, "#filters_actor-filter .input", "Actor")
    assert has_element?(view, "#filters_actor[placeholder='email or id']")
    assert has_element?(view, "#filters_action[type='hidden']")
    refute has_element?(view, "#audit-log-filter-form label[for='audit-log-action-filter']")
    assert has_element?(view, "#audit-log-action-filter [aria-label='Event']")
    assert has_element?(view, "#audit-log-action-filter")

    assert has_element?(
             view,
             "#audit-log-action-filter [data-role='action-filter-trigger']",
             "Any event"
           )

    assert has_element?(
             view,
             "#audit-log-action-filter [data-role='action-filter-trigger-icon'] .hero-squares-2x2"
           )

    assert has_element?(
             view,
             "#audit-log-action-filter [data-role='action-filter-menu'] button[data-action='operator.update']",
             "Operator account updated"
           )

    assert has_element?(
             view,
             "#audit-log-action-filter button[data-action='operator.update'] [data-role='action-filter-icon'].text-info"
           )

    assert has_element?(
             view,
             "#audit-log-action-filter button[data-action='upstream_account.import'] [data-role='action-filter-icon'].text-primary .hero-cloud-arrow-up"
           )

    assert has_element?(view, "#filters_target")
    refute has_element?(view, "#audit-log-filter-form-advanced label[for='filters_target']")
    assert has_element?(view, "#filters_target[aria-label='Target']")
    assert has_element?(view, "#filters_target-filter .input", "Target")
    assert has_element?(view, "#filters_target[placeholder='user or id']")
    refute has_element?(view, "#filters_request")
    assert has_element?(view, "#filters_date_from[type='hidden'][name='filters[date_from]']")
    assert has_element?(view, "#filters_date_to[type='hidden'][name='filters[date_to]']")
    refute has_element?(view, "input#filters_date_from[type='date']")
    refute has_element?(view, "input#filters_date_to[type='date']")
    assert has_element?(view, "#filters_date_from-picker[phx-hook='CallyDatePicker']")
    assert has_element?(view, "#filters_date_to-picker[phx-hook='CallyDatePicker']")
    refute has_element?(view, "#filters_date_from-picker > label[for='filters_date_from-button']")
    refute has_element?(view, "#filters_date_to-picker > label[for='filters_date_to-button']")

    assert has_element?(
             view,
             "#audit-log-filter-form-advanced #filters_date_from-picker button .label",
             "Date from"
           )

    assert has_element?(
             view,
             "#audit-log-filter-form-advanced #filters_date_to-picker button .label",
             "Date to"
           )

    assert has_element?(
             view,
             ~s|#audit-log-filter-form-advanced > div[class*="auto-fit"][class*="minmax(10rem,1fr)"]|
           )

    assert has_element?(view, "#audit-log-page-size", "Hard limit: 50 rows")
    assert has_element?(view, "#audit-event-details-drawer-root")
    assert has_element?(view, "#audit-event-details-drawer")
    refute has_element?(view, "#audit-event-details-title")
    assert has_element?(view, "#admin-audit-logs")
    assert has_element?(view, "#audit-logs-table")
    assert has_element?(view, "#admin-audit-logs thead", "Time")
    assert has_element?(view, "#admin-audit-logs thead", "Event")
    assert has_element?(view, "#admin-audit-logs thead", "Actor")
    assert has_element?(view, "#admin-audit-logs thead", "Context")
    assert has_element?(view, "#mobile-audit-logs-table")
    assert has_element?(view, "#mobile-audit-logs-table thead", "Time")
    assert has_element?(view, "#mobile-audit-logs-table thead", "Event")
    assert has_element?(view, "#mobile-audit-logs-table thead", "Actor")
    refute has_element?(view, "#mobile-audit-logs-table thead", "Context")
    assert has_element?(view, "#audit-log-row-#{operator_event.id}")
    assert has_element?(view, "#audit-log-row-#{pool_routing_event.id}", "Pool routing updated")

    assert has_element?(view, "#mobile-audit-log-row-#{operator_event.id}")
    assert has_element?(view, "#audit-log-row-#{hidden_event.id}", "Pool updated")
    assert has_element?(view, "a[href='/admin/operators']", user.email)

    html = render(view)
    assert html =~ "Operator account updated"
    assert html =~ user.email
    refute html =~ "Safe visible"
    refute html =~ "Request finished"
    refute html =~ "should-not-render"
    refute html =~ "Pool Audit Page"
    refute html =~ "Instance-wide"
    refute html =~ ">Failed<"
    refute html =~ "request #{String.slice(request_id, 0, 8)}"
    refute html =~ ~s(/admin/request-logs?pool_id=#{pool.id}&amp;request_id=#{request_id})
    refute html =~ sensitive_marker
    refute html =~ Enum.join(["Authorization", ": ", "Bearer"])

    view
    |> element("#audit-log-pool-filter button[data-pool-id='#{pool.id}']")
    |> render_click()

    assert_patch(view, ~p"/admin/audit-logs?pool_id=#{pool.id}")
    assert has_element?(view, "#filters_pool_id[value='#{pool.id}']")

    assert has_element?(
             view,
             "#audit-log-pool-filter [data-role='pool-filter-trigger']",
             "Audit Page"
           )

    view
    |> element("#audit-log-pool-filter button[data-pool-id='']")
    |> render_click()

    assert_patch(view, ~p"/admin/audit-logs")

    assert has_element?(
             view,
             "#audit-log-pool-filter [data-role='pool-filter-trigger']",
             "All Pools"
           )

    view
    |> element("#audit-log-pool-filter button[data-pool-id='#{hidden_pool.id}']")
    |> render_click()

    assert_patch(view, ~p"/admin/audit-logs?pool_id=#{hidden_pool.id}")
    assert has_element?(view, "#filters_pool_id[value='#{hidden_pool.id}']")

    assert has_element?(
             view,
             "#audit-log-pool-filter [data-role='pool-filter-trigger']",
             "Hidden Audit"
           )

    assert has_element?(view, "#audit-log-row-#{hidden_event.id}", "Pool updated")

    view
    |> element("#audit-log-pool-filter button[data-pool-id='']")
    |> render_click()

    assert_patch(view, ~p"/admin/audit-logs")

    view
    |> element("#audit-log-outcome-filter button[data-outcome='success']")
    |> render_click()

    assert_patch(view, ~p"/admin/audit-logs?outcome=success")
    assert has_element?(view, "#filters_outcome[value='success']")

    assert has_element?(
             view,
             "#audit-log-outcome-filter [data-role='outcome-filter-trigger']",
             "Success"
           )

    view
    |> element("#audit-log-outcome-filter button[data-outcome='']")
    |> render_click()

    assert_patch(view, ~p"/admin/audit-logs")

    view
    |> element("#mobile-audit-log-time-#{operator_event.id}")
    |> render_click()

    assert has_element?(view, "#audit-event-details-title", "Operator account updated")

    view
    |> element("#audit-event-details-close")
    |> render_click()

    refute has_element?(view, "#audit-event-details-title")

    view
    |> element("#audit-log-time-#{operator_event.id}")
    |> render_click()

    assert has_element?(view, "#audit-event-details-title", "Operator account updated")
    assert has_element?(view, "#audit-event-details-sidebar[role='dialog']")
    assert has_element?(view, "#audit-event-details-title", "Operator account updated")
    assert has_element?(view, "#audit-event-detail-summary", "Success")
    refute has_element?(view, "#audit-event-detail-summary", request_id)
    refute has_element?(view, "#audit-event-detail-summary", "Audit Page")
    assert has_element?(view, "#audit-event-detail-metadata", "Safe")
    assert has_element?(view, "#audit-event-detail-metadata", "visible")
    refute render(view) =~ sensitive_marker

    view
    |> element("#audit-event-details-close")
    |> render_click()

    refute has_element?(view, "#audit-event-details-title")

    view
    |> element("#audit-log-filter-form")
    |> render_submit(%{"filters" => %{"pool_id" => pool.id, "outcome" => "failure"}})

    refute render(view) =~ "Request finished"
    refute has_element?(view, "#audit-log-row-#{operator_event.id}")

    view
    |> element("#audit-log-filter-form")
    |> render_submit(%{
      "filters" => %{
        "pool_id" => "",
        "outcome" => "",
        "actor_type" => "",
        "actor" => "",
        "action" => "operator.update",
        "target" => "",
        "date_from" => "",
        "date_to" => ""
      }
    })

    assert has_element?(view, "#audit-log-row-#{operator_event.id}")
    assert render(view) =~ "Operator account updated"
    refute render(view) =~ "Request finished"

    view
    |> element("#audit-log-action-filter button[data-action='auth.login']")
    |> render_click()

    assert_patch(view, ~p"/admin/audit-logs?action=auth.login")
    assert has_element?(view, "#filters_action[value='auth.login']")

    assert has_element?(
             view,
             "#audit-log-action-filter [data-role='action-filter-trigger']",
             "Operator signed in"
           )

    assert has_element?(
             view,
             "#audit-log-action-filter [data-role='action-filter-trigger-icon'].text-success"
           )
  end

  test "renders table and drawer timestamps with operator datetime preferences", %{
    conn: conn,
    user: user
  } do
    set_datetime_preferences!(user, datetime_format: "short", timezone: "Europe/Rome")

    assert {:ok, event} =
             Audit.record_user_event(user, %{
               action: "operator.update",
               target_type: "user",
               target_id: user.id,
               details: %{"safe" => "timezone visible"}
             })

    {1, _rows} =
      from(audit in AuditEvent, where: audit.id == ^event.id)
      |> Repo.update_all(set: [occurred_at: ~U[2026-05-27 13:45:06Z]])

    {:ok, view, _html} = live(conn, ~p"/admin/audit-logs")

    assert has_element?(view, "#audit-log-time-#{event.id}", "2026-05-27 15:45")
    assert has_element?(view, "#mobile-audit-log-time-#{event.id}", "2026-05-27 15:45")

    view
    |> element("#audit-log-time-#{event.id}")
    |> render_click()

    assert has_element?(view, "#audit-event-details-sidebar", "2026-05-27 15:45")
    refute render(view) =~ "13:45:06 UTC"
  end

  test "invalid filters render validation feedback and keep safe default results", %{conn: conn} do
    {:ok, view, _html} =
      live(
        conn,
        ~p"/admin/audit-logs?outcome=denied&actor_type=robot&action=request.finalized&date_from=not-a-date"
      )

    assert has_element?(view, "#audit-log-filter-errors", "Outcome filter is not supported")
    assert has_element?(view, "#audit-log-filter-errors", "Actor type filter is not supported")
    assert has_element?(view, "#audit-log-filter-errors", "Action filter is not supported")
    assert has_element?(view, "#audit-log-filter-errors", "Date from must be a valid date")
    assert has_element?(view, "tr[id^='audit-log-row-']")
  end

  test "instance settings audit rows and drawer keep metrics and smtp secrets redacted", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      InstanceSettings.reset_cache_for_test()
    end)

    metrics_token = "audit-metrics-token-#{System.unique_integer([:positive])}"
    smtp_password = "audit-smtp-password-#{System.unique_integer([:positive])}"

    attrs =
      %{
        "smtp" => %{
          "enabled" => true,
          "host" => "smtp.example.com",
          "username" => "mailer",
          "from" => "sender@example.com"
        },
        :current_scope => scope
      }
      |> InstanceSettings.put_metrics_bearer_token(metrics_token)
      |> InstanceSettings.put_smtp_password(smtp_password)

    assert {:ok, updated} =
             InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), attrs)

    event =
      Repo.one!(
        from audit in AuditEvent,
          where: audit.action == "instance_settings.update" and audit.actor_user_id == ^user.id,
          order_by: [desc: audit.occurred_at, desc: audit.id],
          limit: 1
      )

    {:ok, view, html} = live(conn, ~p"/admin/audit-logs")

    assert has_element?(view, "#audit-log-row-#{event.id}", "Instance settings updated")
    refute html =~ metrics_token
    refute html =~ smtp_password

    view
    |> element("#audit-log-time-#{event.id}")
    |> render_click()

    drawer_html = render(view)

    assert has_element?(view, "#audit-event-details-title", "Instance settings updated")
    assert has_element?(view, "#audit-event-detail-metadata", "Credential changes")

    assert has_element?(
             view,
             "#audit-event-detail-metadata",
             updated.metrics.bearer_token_fingerprint
           )

    assert has_element?(view, "#audit-event-detail-metadata", "configured")
    refute drawer_html =~ metrics_token
    refute drawer_html =~ smtp_password
  end

  test "alert audit rows render labels and sanitized channel details", %{
    conn: conn,
    scope: scope
  } do
    raw_endpoint = "https://hooks.example.com/audit/path-secret?token=query-secret"
    signing_secret = "whsec_ui_audit_hidden"

    assert {:ok, channel} =
             Alerts.create_channel(scope, %{
               channel_type: "webhook",
               display_name: "Audit UI webhook",
               state: "active",
               endpoint_url: raw_endpoint,
               webhook_signing_secret: signing_secret,
               metadata: %{"authorization" => "Bearer audit-ui-token"}
             })

    event =
      Repo.one!(
        from audit in AuditEvent,
          where: audit.action == "alert_channel.create" and audit.target_id == ^channel.id,
          order_by: [desc: audit.occurred_at, desc: audit.id],
          limit: 1
      )

    {:ok, view, html} = live(conn, ~p"/admin/audit-logs")

    assert has_element?(view, "#audit-log-row-#{event.id}", "Alert channel created")

    assert has_element?(
             view,
             "#audit-log-action-filter button[data-action='alert_channel.create']",
             "Alert channel created"
           )

    assert has_element?(
             view,
             "#audit-log-action-filter button[data-action='alert_channel.create'] [data-role='action-filter-icon'].text-warning .hero-bell-alert"
           )

    refute html =~ raw_endpoint
    refute html =~ "path-secret"
    refute html =~ "query-secret"
    refute html =~ signing_secret
    refute html =~ "Bearer audit-ui-token"

    view
    |> element("#audit-log-time-#{event.id}")
    |> render_click()

    drawer_html = render(view)

    assert has_element?(view, "#audit-event-details-title", "Alert channel created")
    assert has_element?(view, "#audit-event-detail-summary", "alert_channel")
    assert has_element?(view, "#audit-event-detail-metadata", "Endpoint host")
    assert has_element?(view, "#audit-event-detail-metadata", "hooks.example.com")
    assert has_element?(view, "#audit-event-detail-metadata", "Webhook signing secret configured")
    refute drawer_html =~ raw_endpoint
    refute drawer_html =~ "path-secret"
    refute drawer_html =~ "query-secret"
    refute drawer_html =~ signing_secret
    refute drawer_html =~ "Bearer audit-ui-token"
  end

  test "scoped admins see only currently assigned pool audit rows and never nilified deleted-pool history",
       %{scope: scope} do
    {:ok, assigned_pool} =
      Pools.create_pool(scope, %{slug: "audit-scope-assigned", name: "Audit Scope Assigned"})

    {:ok, hidden_pool} =
      Pools.create_pool(scope, %{slug: "audit-scope-hidden", name: "Audit Scope Hidden"})

    {:ok, delete_pool} =
      Pools.create_pool(scope, %{slug: "audit-scope-delete", name: "Audit Scope Delete"})

    assert {:ok, assigned_event} =
             Audit.record_system_event(%{
               pool_id: assigned_pool.id,
               action: "pool.update",
               target_type: "pool",
               target_id: assigned_pool.id,
               details: %{"safe" => "assigned"}
             })

    assert {:ok, hidden_event} =
             Audit.record_system_event(%{
               pool_id: hidden_pool.id,
               action: "pool.update",
               target_type: "pool",
               target_id: hidden_pool.id,
               details: %{"safe" => "hidden"}
             })

    assert {:ok, global_event} =
             Audit.record_user_event(scope.user, %{
               action: "operator.update",
               target_type: "user",
               target_id: scope.user.id,
               details: %{"safe" => "global"}
             })

    %{conn: admin_conn} =
      assigned_admin_conn(scope, assigned_pool, "audit-scope-admin@example.com")

    {:ok, view, _html} = live(admin_conn, ~p"/admin/audit-logs")

    assert has_element?(view, "#audit-log-row-#{assigned_event.id}", "Pool updated")
    refute has_element?(view, "#audit-log-row-#{hidden_event.id}")
    refute has_element?(view, "#audit-log-row-#{global_event.id}")
    assert has_element?(view, "#audit-log-pool-filter button[data-pool-id='#{assigned_pool.id}']")
    refute has_element?(view, "#audit-log-pool-filter button[data-pool-id='#{hidden_pool.id}']")

    {:ok, hidden_filter_view, _html} =
      live(admin_conn, ~p"/admin/audit-logs?pool_id=#{hidden_pool.id}&target=#{hidden_pool.id}")

    assert has_element?(
             hidden_filter_view,
             "#audit-log-filter-errors",
             "Pool filter did not match an available Pool"
           )

    refute has_element?(hidden_filter_view, "#audit-log-row-#{hidden_event.id}")

    assert {:ok, archived_pool} = Pools.change_pool_status(scope, assigned_pool, "archived")

    {:ok, revoked_admin_view, _html} = live(admin_conn, ~p"/admin/audit-logs")
    refute has_element?(revoked_admin_view, "#audit-log-row-#{assigned_event.id}")

    refute has_element?(
             revoked_admin_view,
             "#audit-log-pool-filter button[data-pool-id='#{archived_pool.id}']"
           )

    assert {:ok, archived_delete_pool} = Pools.change_pool_status(scope, delete_pool, "archived")

    assert {:ok, _deleted_pool} =
             Pools.delete_archived_pool(scope, archived_delete_pool, archived_delete_pool.slug)

    nilified_event =
      Repo.one!(
        from audit in AuditEvent,
          where: audit.action == "pool.delete" and audit.target_id == ^delete_pool.id,
          order_by: [desc: audit.occurred_at, desc: audit.id],
          limit: 1
      )

    assert is_nil(nilified_event.pool_id)

    {:ok, deleted_filter_view, _html} =
      live(admin_conn, ~p"/admin/audit-logs?target=#{delete_pool.id}")

    refute has_element?(deleted_filter_view, "#audit-log-row-#{nilified_event.id}")

    {:ok, owner_view, _html} =
      live(
        build_conn() |> log_in_user(scope.user, session_token(scope.user)),
        ~p"/admin/audit-logs?target=#{delete_pool.id}"
      )

    assert has_element?(owner_view, "#audit-log-row-#{nilified_event.id}", "Pool deleted")
  end

  test "paginates audit logs, preserves filters, and clamps overflow pages", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for index <- 1..52 do
      %AuditEvent{
        occurred_at: DateTime.add(now, -index, :second),
        actor_type: "system",
        action: "pool.update",
        target_type: "pool",
        target_id: Ecto.UUID.generate(),
        outcome: "success",
        details: %{"index" => index}
      }
      |> Repo.insert!()
    end

    {:ok, view, _html} = live(conn, ~p"/admin/audit-logs?action=pool.update")

    assert has_element?(view, "#admin-audit-logs-pagination-top", "Page 1 of 2")
    assert has_element?(view, "#admin-audit-logs-pagination-bottom", "Page 1 of 2")
    assert has_element?(view, "#admin-audit-logs-range-top", "Showing 1-50 of 52")
    assert has_element?(view, "#admin-audit-logs-range-bottom", "Showing 1-50 of 52")
    assert has_element?(view, "#admin-audit-logs-pagination-top-prev.btn-disabled")
    refute has_element?(view, "#admin-audit-logs-pagination-top-next.btn-disabled")

    view
    |> element("#admin-audit-logs-pagination-top-next")
    |> render_click()

    assert_patch(view, "/admin/audit-logs?action=pool.update&page=2")
    assert has_element?(view, "#admin-audit-logs-pagination-bottom", "Page 2 of 2")
    assert has_element?(view, "#admin-audit-logs-range-bottom", "Showing 51-52 of 52")
    refute has_element?(view, "#admin-audit-logs-pagination-bottom-prev.btn-disabled")
    assert has_element?(view, "#admin-audit-logs-pagination-bottom-next.btn-disabled")

    view
    |> element("#admin-audit-logs-pagination-bottom-prev")
    |> render_click()

    assert_patch(view, "/admin/audit-logs?action=pool.update")

    assert {:error, {:live_redirect, %{to: overflow_to}}} =
             live(conn, ~p"/admin/audit-logs?action=pool.update&page=99")

    assert overflow_to == "/admin/audit-logs?action=pool.update&page=2"
  end

  test "clamps an empty audit-log page to page one", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: overflow_to}}} =
             live(conn, ~p"/admin/audit-logs?action=auth.logout&page=4")

    assert overflow_to == "/admin/audit-logs?action=auth.logout"
  end

  defp set_datetime_preferences!(user, attrs) do
    {1, _rows} =
      from(operator in User, where: operator.id == ^user.id)
      |> Repo.update_all(set: attrs)

    :ok
  end

  defp assigned_admin_conn(scope, pool, email) do
    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => email,
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, pool, created_by_user_id: scope.user.id)

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    %{conn: log_in_user(build_conn(), admin, token), user: admin}
  end

  defp session_token(user) do
    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => user.email, "password" => valid_user_password()})

    token
  end
end
