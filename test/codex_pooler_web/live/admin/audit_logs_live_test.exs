defmodule CodexPoolerWeb.Admin.AuditLogsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures
  import Phoenix.LiveViewTest

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
             "#audit-log-pool-filter button[data-pool-id='#{pool.id}']",
             "Audit Page"
           )

    assert has_element?(
             view,
             "#audit-log-pool-filter button[data-pool-id='#{pool.id}']",
             "Quota first"
           )

    html = render(view)
    all_pools_position = html =~ "All Pools"
    alpha_position = html =~ "Alpha Audit"
    audit_position = html =~ "Audit Page"

    assert all_pools_position
    assert alpha_position
    assert audit_position
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
    refute has_element?(view, "#audit-log-row-#{hidden_event.id}")
    assert has_element?(view, "#audit-log-row-#{pool_routing_event.id}", "Pool routing updated")

    assert has_element?(view, "#mobile-audit-log-row-#{operator_event.id}")
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

    assert {:ok, updated} = InstanceSettings.update(InstanceSettings.ensure_singleton!(), attrs)

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
end
