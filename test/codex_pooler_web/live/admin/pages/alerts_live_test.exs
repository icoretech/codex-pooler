defmodule CodexPoolerWeb.Admin.AlertsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertChannel
  alias CodexPooler.Alerts.Schemas.AlertDeliveryAttempt
  alias CodexPooler.Alerts.Schemas.AlertIncident
  alias CodexPooler.Alerts.Schemas.AlertRule
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.AlertNotificationsReadModel

  setup :register_and_log_in_user

  test "renders rule workspace and creates a Pool alert rule", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "alerts-create", name: "Alerts Create"})

    {:ok, view, _html} = live(conn, ~p"/admin/alerts")

    assert has_element?(view, "#admin-alerts-live")
    assert has_element?(view, "#alerts-tab-rules[aria-selected='true']", "Rules")
    assert has_element?(view, "#alerts-rules-section")
    assert has_element?(view, "#alerts-rule-form")
    assert has_element?(view, "#alert-rule-pool-id option[value='#{pool.id}']", pool.name)

    view
    |> element("#alerts-rule-form")
    |> render_submit(%{
      "alert_rule" => %{
        "pool_id" => pool.id,
        "rule_kind" => "pool_low_usable_assignments",
        "display_name" => "Low assignment coverage",
        "severity" => "warning",
        "state" => AlertRule.active_state(),
        "cooldown_minutes" => "45",
        "model" => "gpt-5.5",
        "min_usable_assignments" => "3"
      }
    })

    assert {:ok, [rule]} = Alerts.list_rules(scope, pool_id: pool.id)
    assert rule.display_name == "Low assignment coverage"
    assert rule.rule_kind == "pool_low_usable_assignments"
    assert rule.min_usable_assignments == 3
    assert rule.model == "gpt-5.5"

    assert has_element?(view, "#alert-rule-row-#{rule.id}", "Low assignment coverage")
    assert has_element?(view, "#alert-rule-row-#{rule.id}-pool", pool.name)
    assert has_element?(view, "#alert-rule-row-#{rule.id}-state", "Enabled")
    assert has_element?(view, "#alert-rule-row-#{rule.id}-threshold", "Minimum 3")
    assert has_element?(view, "#alert-rule-edit-#{rule.id}")
    assert has_element?(view, "#alert-rule-disable-#{rule.id}")
    assert has_element?(view, "#alert-rule-delete-#{rule.id}")
  end

  @tag :saved_reset_banked_first_seen
  test "creates saved reset first-seen rule with info default and no irrelevant fields", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "alerts-saved-reset-default",
        name: "Alerts Saved Reset Default"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/alerts")

    assert has_element?(
             view,
             "#alert-rule-kind option[value='upstream_saved_reset_banked_first_seen']",
             "First-seen banked saved reset"
           )

    view
    |> element("#alerts-rule-form")
    |> render_change(%{
      "alert_rule" => %{
        "pool_id" => pool.id,
        "rule_kind" => "upstream_saved_reset_banked_first_seen",
        "display_name" => "Saved reset first seen",
        "state" => AlertRule.active_state(),
        "cooldown_minutes" => "30"
      }
    })

    assert has_element?(view, "#alert-rule-no-extra-fields", "banked saved reset")
    refute has_element?(view, "#alert-rule-target-state")
    refute has_element?(view, "#alert-rule-window-selector")
    refute has_element?(view, "#alert-rule-threshold-used-percent")
    refute has_element?(view, "#alert-rule-min-usable-assignments")

    view
    |> element("#alerts-rule-form")
    |> render_submit(%{
      "alert_rule" => %{
        "pool_id" => pool.id,
        "rule_kind" => "upstream_saved_reset_banked_first_seen",
        "display_name" => "Saved reset first seen",
        "state" => AlertRule.active_state(),
        "cooldown_minutes" => "30"
      }
    })

    assert {:ok, [rule]} = Alerts.list_rules(scope, pool_id: pool.id)
    assert rule.rule_kind == "upstream_saved_reset_banked_first_seen"
    assert rule.scope_type == "upstream_identity"
    assert rule.severity == "info"
    assert is_nil(rule.target_state)
    assert is_nil(rule.window_selector)
    assert is_nil(rule.threshold_used_percent)
    assert is_nil(rule.min_usable_assignments)

    assert has_element?(view, "#alert-rule-row-#{rule.id}", "Saved reset first seen")
    assert has_element?(view, "#alert-rule-row-#{rule.id}-kind", "First-seen banked saved reset")

    assert has_element?(
             view,
             "#alert-rule-row-#{rule.id}-threshold",
             "First banked reset observed"
           )
  end

  @tag :saved_reset_banked_first_seen
  test "saved reset rule severity preserves explicit create and edit values", %{
    conn: conn,
    scope: scope
  } do
    {:ok, explicit_pool} =
      Pools.create_pool(scope, %{
        slug: "alerts-saved-reset-explicit",
        name: "Alerts Saved Reset Explicit"
      })

    {:ok, edit_pool} =
      Pools.create_pool(scope, %{
        slug: "alerts-saved-reset-edit",
        name: "Alerts Saved Reset Edit"
      })

    existing_rule =
      alert_rule_fixture(edit_pool,
        created_by_user_id: scope.user.id,
        rule_kind: "upstream_saved_reset_banked_first_seen",
        scope_type: "upstream_identity",
        severity: "warning",
        display_name: "Saved reset edit severity",
        cooldown_minutes: 30
      )

    {:ok, view, _html} = live(conn, ~p"/admin/alerts")

    view
    |> element("#alerts-rule-form")
    |> render_submit(%{
      "alert_rule" => %{
        "pool_id" => explicit_pool.id,
        "rule_kind" => "upstream_saved_reset_banked_first_seen",
        "display_name" => "Saved reset explicit severity",
        "severity" => "warning",
        "state" => AlertRule.active_state(),
        "cooldown_minutes" => "30"
      }
    })

    assert {:ok, [explicit_rule]} = Alerts.list_rules(scope, pool_id: explicit_pool.id)
    assert explicit_rule.severity == "warning"

    view
    |> element("#alert-rule-edit-#{existing_rule.id}")
    |> render_click()

    view
    |> element("#alerts-rule-form")
    |> render_submit(%{
      "alert_rule" => %{
        "pool_id" => edit_pool.id,
        "rule_kind" => "upstream_saved_reset_banked_first_seen",
        "display_name" => "Saved reset edit severity updated",
        "state" => AlertRule.active_state(),
        "cooldown_minutes" => "45"
      }
    })

    edited_rule = Repo.get!(AlertRule, existing_rule.id)
    assert edited_rule.severity == "warning"
    assert edited_rule.cooldown_minutes == 45
  end

  test "edits an existing alert rule from the rules table", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "alerts-edit", name: "Alerts Edit"})

    rule =
      alert_rule_fixture(pool,
        created_by_user_id: scope.user.id,
        display_name: "Original alert rule",
        cooldown_minutes: 30
      )

    {:ok, view, _html} = live(conn, ~p"/admin/alerts")

    view
    |> element("#alert-rule-edit-#{rule.id}")
    |> render_click()

    assert has_element?(view, "#alerts-rule-form-panel", "Edit rule")

    view
    |> element("#alerts-rule-form")
    |> render_submit(%{
      "alert_rule" => %{
        "pool_id" => pool.id,
        "rule_kind" => "pool_no_usable_assignments",
        "display_name" => "Updated alert rule",
        "severity" => "critical",
        "state" => AlertRule.active_state(),
        "cooldown_minutes" => "60",
        "model" => "gpt-5.5"
      }
    })

    updated_rule = Repo.get!(AlertRule, rule.id)
    assert updated_rule.display_name == "Updated alert rule"
    assert updated_rule.cooldown_minutes == 60
    assert updated_rule.model == "gpt-5.5"
    assert has_element?(view, "#alert-rule-row-#{rule.id}", "Updated alert rule")
    assert has_element?(view, "#alerts-rule-form-panel", "Create rule")
  end

  test "disables an active alert rule", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "alerts-disable", name: "Alerts Disable"})

    rule =
      alert_rule_fixture(pool,
        created_by_user_id: scope.user.id,
        display_name: "Disable alert rule",
        state: AlertRule.active_state()
      )

    {:ok, view, _html} = live(conn, ~p"/admin/alerts")

    view
    |> element("#alert-rule-disable-#{rule.id}")
    |> render_click()

    disabled_rule = Repo.get!(AlertRule, rule.id)
    assert disabled_rule.state == AlertRule.disabled_state()
    assert disabled_rule.disabled_at
    assert has_element?(view, "#alert-rule-row-#{rule.id}-state", "Disabled")
    refute has_element?(view, "#alert-rule-disable-#{rule.id}")
  end

  test "deletes an alert rule through the confirmation form", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "alerts-delete", name: "Alerts Delete"})

    rule =
      alert_rule_fixture(pool,
        created_by_user_id: scope.user.id,
        display_name: "Delete alert rule"
      )

    {:ok, view, _html} = live(conn, ~p"/admin/alerts")

    view
    |> element("#alert-rule-delete-#{rule.id}")
    |> render_click()

    assert has_element?(view, "#alert-rule-delete-dialog[open]", "Delete alert rule")
    assert has_element?(view, "#alert-rule-delete-form")

    view
    |> element("#alert-rule-delete-form")
    |> render_submit(%{"alert_rule_delete" => %{"id" => rule.id}})

    refute Repo.get(AlertRule, rule.id)
    refute has_element?(view, "#alert-rule-row-#{rule.id}")
    refute has_element?(view, "#alert-rule-delete-dialog")
  end

  test "assigned admin cannot create a rule for a hidden Pool and hidden Pool data is not rendered",
       %{
         scope: scope
       } do
    {:ok, assigned_pool} =
      Pools.create_pool(scope, %{slug: "alerts-assigned", name: "Alerts Assigned"})

    {:ok, hidden_pool} =
      Pools.create_pool(scope, %{slug: "alerts-hidden", name: "Alerts Hidden Secret"})

    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "alerts-assigned-admin@example.com",
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: scope.user.id)

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, view, html} = live(admin_conn, ~p"/admin/alerts")

    assert has_element?(
             view,
             "#alert-rule-pool-id option[value='#{assigned_pool.id}']",
             assigned_pool.name
           )

    refute html =~ hidden_pool.id
    refute html =~ hidden_pool.name
    refute html =~ hidden_pool.slug

    response =
      view
      |> element("#alerts-rule-form")
      |> render_submit(%{
        "alert_rule" => %{
          "pool_id" => hidden_pool.id,
          "rule_kind" => "pool_no_usable_assignments",
          "display_name" => "Hidden Pool rule",
          "severity" => "critical",
          "state" => AlertRule.active_state(),
          "cooldown_minutes" => "30"
        }
      })

    assert response =~ "Pool is not available for this operator"
    refute response =~ hidden_pool.id
    refute response =~ hidden_pool.name
    refute response =~ hidden_pool.slug

    assert {:ok, []} = Alerts.list_rules(scope, pool_id: hidden_pool.id)
    assert {:ok, []} = Alerts.list_rules(scope, pool_id: assigned_pool.id)
  end

  test "channels workspace creates an email channel", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/admin/alerts?tab=channels")

    assert has_element?(view, "#alerts-tab-channels[aria-selected='true']", "Channels")
    assert has_element?(view, "#alerts-channels-section")
    assert has_element?(view, "#alerts-channel-form")
    assert has_element?(view, "#alert-channel-email-to")

    view
    |> element("#alerts-channel-form")
    |> render_submit(%{
      "alert_channel" => %{
        "channel_type" => "email",
        "display_name" => "Operations email",
        "state" => AlertChannel.active_state(),
        "email_to" => "ops-alerts@example.com"
      }
    })

    assert {:ok, [channel]} = Alerts.list_channels(scope)
    assert channel.channel_type == "email"
    assert channel.email_to == "ops-alerts@example.com"

    assert has_element?(view, "#alert-channel-row-#{channel.id}", "Operations email")
    assert has_element?(view, "#alert-channel-row-#{channel.id}-type", "Email")

    assert has_element?(
             view,
             "#alert-channel-row-#{channel.id}-endpoint",
             "ops-alerts@example.com"
           )

    assert has_element?(view, "#alert-channel-disable-#{channel.id}")
  end

  test "creates a webhook channel with masked endpoint and write-only signing secret", %{
    conn: conn,
    scope: scope
  } do
    full_endpoint =
      "https://hooks.example.com/alerts/team-token/critical?token=query-secret&auth=bearer"

    signing_secret = "whsec_live_hidden_value"

    {:ok, view, _html} = live(conn, ~p"/admin/alerts?tab=channels")

    view
    |> element("#alerts-channel-form")
    |> render_change(%{"alert_channel" => %{"channel_type" => "webhook"}})

    assert has_element?(view, "#alert-channel-webhook-url")
    assert has_element?(view, "#alert-channel-webhook-signing-secret")
    assert has_element?(view, "#alert-channel-webhook-signing-secret-clear")

    response =
      view
      |> element("#alerts-channel-form")
      |> render_submit(%{
        "alert_channel" => %{
          "channel_type" => "webhook",
          "display_name" => "Incident webhook",
          "state" => AlertChannel.active_state(),
          "endpoint_url" => full_endpoint,
          "webhook_signing_secret" => signing_secret,
          "webhook_signing_secret_action" => "preserve"
        }
      })

    assert {:ok, [channel]} = Alerts.list_channels(scope)
    assert channel.channel_type == "webhook"
    assert channel.endpoint_host == "hooks.example.com"
    assert channel.endpoint_path_prefix =~ "/aler..."
    assert channel.webhook_signing_secret_key_version == "v1"

    assert has_element?(view, "#alert-channel-row-#{channel.id}", "Incident webhook")
    assert has_element?(view, "#alert-channel-row-#{channel.id}-endpoint", "hooks.example.com")
    assert has_element?(view, "#alert-channel-row-#{channel.id}-secret", "configured")

    html_after_save = render(view)
    refute response =~ full_endpoint
    refute response =~ "team-token"
    refute response =~ "query-secret"
    refute response =~ signing_secret
    refute html_after_save =~ full_endpoint
    refute html_after_save =~ "team-token"
    refute html_after_save =~ "query-secret"
    refute html_after_save =~ signing_secret

    view
    |> element("#alert-channel-edit-#{channel.id}")
    |> render_click()

    edit_html = render(view)
    refute edit_html =~ full_endpoint
    refute edit_html =~ "team-token"
    refute edit_html =~ "query-secret"
    refute edit_html =~ signing_secret

    {:ok, _remounted_view, remounted_html} = live(conn, ~p"/admin/alerts?tab=channels")
    refute remounted_html =~ full_endpoint
    refute remounted_html =~ "team-token"
    refute remounted_html =~ "query-secret"
    refute remounted_html =~ signing_secret
  end

  test "edits and disables an alert channel", %{conn: conn, scope: scope} do
    assert {:ok, channel} =
             Alerts.create_channel(scope, %{
               channel_type: "email",
               display_name: "Original channel",
               state: AlertChannel.active_state(),
               email_to: "original@example.com"
             })

    {:ok, view, _html} = live(conn, ~p"/admin/alerts?tab=channels")

    view
    |> element("#alert-channel-edit-#{channel.id}")
    |> render_click()

    assert has_element?(view, "#alerts-channel-form-panel", "Edit channel")

    view
    |> element("#alerts-channel-form")
    |> render_submit(%{
      "alert_channel" => %{
        "channel_type" => "email",
        "display_name" => "Updated channel",
        "state" => AlertChannel.active_state(),
        "email_to" => "updated@example.com"
      }
    })

    assert {:ok, [updated]} = Alerts.list_channels(scope)
    assert updated.display_name == "Updated channel"
    assert updated.email_to == "updated@example.com"
    assert has_element?(view, "#alert-channel-row-#{channel.id}", "Updated channel")

    view
    |> element("#alert-channel-disable-#{channel.id}")
    |> render_click()

    assert {:ok, [disabled]} = Alerts.list_channels(scope)
    assert disabled.state == AlertChannel.disabled_state()
    assert disabled.disabled_at
    assert has_element?(view, "#alert-channel-row-#{channel.id}-state", "Disabled")
    refute has_element?(view, "#alert-channel-disable-#{channel.id}")
  end

  test "deletes an alert channel through the confirmation form", %{conn: conn, scope: scope} do
    assert {:ok, channel} =
             Alerts.create_channel(scope, %{
               channel_type: "email",
               display_name: "Delete channel",
               state: AlertChannel.active_state(),
               email_to: "delete-channel@example.com"
             })

    {:ok, view, _html} = live(conn, ~p"/admin/alerts?tab=channels")

    view
    |> element("#alert-channel-delete-#{channel.id}")
    |> render_click()

    assert has_element?(view, "#alert-channel-delete-dialog[open]", "Delete alert channel")
    assert has_element?(view, "#alert-channel-delete-form")

    view
    |> element("#alert-channel-delete-form")
    |> render_submit(%{"alert_channel_delete" => %{"id" => channel.id}})

    assert {:ok, []} = Alerts.list_channels(scope)
    refute has_element?(view, "#alert-channel-row-#{channel.id}")
    refute has_element?(view, "#alert-channel-delete-dialog")
  end

  test "incidents workspace renders filtered owner incident metadata without raw evidence", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "alerts-incidents-owner", name: "Alerts Incidents Owner"})

    assert {:ok, channel} =
             Alerts.create_channel(scope, %{
               channel_type: "email",
               display_name: "Owner incident email",
               state: AlertChannel.active_state(),
               email_to: "owner-incidents@example.com"
             })

    assert {:ok, rule} =
             Alerts.create_rule(
               scope,
               alert_rule_attrs(pool, %{
                 display_name: "Owner incident rule",
                 severity: "critical",
                 channel_ids: [channel.id]
               })
             )

    raw_dedupe_key = "alert:owner-raw-dedupe-#{unique_suffix()}"
    raw_prompt = "raw prompt should not render #{unique_suffix()}"
    raw_header = "Bearer raw-header-#{unique_suffix()}"

    assert {:ok, incident} =
             Alerts.record_incident_match(%{
               dedupe_key: raw_dedupe_key,
               scope_type: "pool",
               rule_kind: rule.rule_kind,
               severity: rule.severity,
               pool_id: pool.id,
               matched_at: timestamp(~U[2026-05-31 09:00:00Z]),
               safe_evidence_snapshot: %{"prompt" => raw_prompt},
               suppression_metadata: %{"authorization" => raw_header},
               targets: [
                 %{
                   rule_id: rule.id,
                   pool_id: pool.id,
                   metadata: %{"authorization" => raw_header}
                 }
               ]
             })

    delivery_attempt_fixture(incident, channel, status: AlertDeliveryAttempt.sent_status())

    {:ok, view, html} = live(conn, ~p"/admin/alerts?tab=incidents")

    assert has_element?(view, "#alerts-tab-incidents[aria-selected='true']", "Incidents")
    assert has_element?(view, "#alerts-incidents-section")
    assert has_element?(view, "#alerts-incidents-filter-form")
    assert has_element?(view, "#alerts-incident-pool-filter [data-role='pool-filter-trigger']")
    assert has_element?(view, "#alerts-incident-severity-filter")
    assert has_element?(view, "#alerts-incident-state-filter")
    assert has_element?(view, "#alerts-incident-rule-filter")
    assert has_element?(view, "#alerts-incident-channel-filter")

    assert has_element?(view, "#alert-incident-#{incident.id}")
    assert has_element?(view, "#alert-incident-card-#{incident.id}")

    assert has_element?(
             view,
             "#alert-incident-row-#{incident.id}-reason",
             "No usable assignments"
           )

    assert has_element?(view, "#alert-incident-row-#{incident.id}-severity", "Critical")
    assert has_element?(view, "#alert-incident-row-#{incident.id}-state", "Open")
    assert has_element?(view, "#alert-incident-row-#{incident.id}-delivery", "1 attempt")

    assert has_element?(
             view,
             "#alert-incident-row-#{incident.id}-impacted-pool-#{pool.id} [data-role='incident-impacted-pool-name']",
             pool.name
           )

    assert has_element?(
             view,
             "#alert-incident-row-#{incident.id}-impacted-pool-#{pool.id} [data-role='incident-impacted-pool-slug']",
             pool.slug
           )

    refute has_element?(view, "#alert-incident-row-#{incident.id}-hidden-pool-count")
    refute html =~ raw_dedupe_key
    refute html =~ raw_prompt
    refute html =~ raw_header

    {:ok, filtered_view, _filtered_html} =
      live(conn, ~p"/admin/alerts?tab=incidents&severity=warning")

    assert has_element?(filtered_view, "#alerts-incidents-empty-state")
    refute has_element?(filtered_view, "#alert-incident-#{incident.id}")
  end

  @tag :saved_reset_banked_first_seen
  test "saved reset incidents and notifications render operator-facing safe labels", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "alerts-saved-reset-incident",
        name: "Alerts Saved Reset Incident"
      })

    assert {:ok, rule} =
             Alerts.create_rule(
               scope,
               alert_rule_attrs(pool, %{
                 rule_kind: "upstream_saved_reset_banked_first_seen",
                 scope_type: "upstream_identity",
                 display_name: "Saved reset incident rule",
                 severity: "info"
               })
             )

    %{identity: identity} = upstream_assignment_fixture(pool)
    raw_credit_id = "provider-credit-#{unique_suffix()}"
    raw_provider_payload = "provider payload #{unique_suffix()}"

    assert {:ok, incident} =
             Alerts.record_incident_match(%{
               dedupe_key: "alert:saved-reset:#{identity.id}:2026-07-03T09:00:00Z",
               scope_type: "upstream_identity",
               rule_kind: rule.rule_kind,
               severity: "info",
               upstream_identity_id: identity.id,
               matched_at: timestamp(~U[2026-07-02 08:01:00Z]),
               safe_evidence_snapshot: %{
                 "reason_code" => "saved_reset_banked_first_seen",
                 "reset_expires_at" => "2026-07-03T09:00:00Z",
                 "reset_first_seen_at" => "2026-07-02T08:00:00Z",
                 "available_count" => 2,
                 "source" => "persisted_saved_resets",
                 "path_style" => "codex",
                 "provider_credit_id" => raw_credit_id,
                 "provider_payload" => raw_provider_payload
               },
               suppression_metadata: %{},
               targets: [%{rule_id: rule.id, pool_id: pool.id, metadata: %{}}]
             })

    {:ok, view, html} = live(conn, ~p"/admin/alerts?tab=incidents")

    assert has_element?(
             view,
             "#alert-incident-row-#{incident.id}-reason",
             "First-seen banked saved reset"
           )

    assert has_element?(
             view,
             "#alert-incident-row-#{incident.id}-detail",
             "Persisted saved-reset metadata"
           )

    refute html =~ raw_credit_id
    refute html =~ raw_provider_payload

    notification_state = AlertNotificationsReadModel.load(scope)

    assert [%{reason_title: "First-seen banked saved reset"}] = notification_state.rows
  end

  test "acknowledges and resolves incidents through scoped UI actions and audit events", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "alerts-incident-actions", name: "Alerts Incident Actions"})

    assert {:ok, rule} =
             Alerts.create_rule(
               scope,
               alert_rule_attrs(pool, %{display_name: "Action incident rule"})
             )

    raw_dedupe_key = "alert:action-raw-dedupe-#{unique_suffix()}"
    raw_prompt = "raw action prompt #{unique_suffix()}"

    assert {:ok, incident} =
             Alerts.record_incident_match(%{
               dedupe_key: raw_dedupe_key,
               scope_type: "pool",
               rule_kind: rule.rule_kind,
               severity: rule.severity,
               pool_id: pool.id,
               matched_at: timestamp(~U[2026-05-31 11:00:00Z]),
               safe_evidence_snapshot: %{"prompt" => raw_prompt},
               suppression_metadata: %{},
               targets: [%{rule_id: rule.id, pool_id: pool.id, metadata: %{}}]
             })

    {:ok, view, html} = live(conn, ~p"/admin/alerts?tab=incidents")

    assert has_element?(view, "#alert-incident-acknowledge-#{incident.id}", "Acknowledge")
    assert has_element?(view, "#alert-incident-resolve-#{incident.id}", "Resolve")
    assert has_element?(view, "#alert-incident-card-acknowledge-#{incident.id}", "Acknowledge")
    assert has_element?(view, "#alert-incident-card-resolve-#{incident.id}", "Resolve")
    refute html =~ raw_dedupe_key
    refute html =~ raw_prompt

    view
    |> element("#alert-incident-acknowledge-#{incident.id}")
    |> render_click()

    acknowledged = Repo.get!(AlertIncident, incident.id)
    assert acknowledged.state == AlertIncident.acknowledged_state()
    assert acknowledged.acknowledged_at
    assert has_element?(view, "#alert-incident-row-#{incident.id}-state", "Acknowledged")
    refute has_element?(view, "#alert-incident-acknowledge-#{incident.id}")
    refute has_element?(view, "#alert-incident-card-acknowledge-#{incident.id}")
    assert has_element?(view, "#alert-incident-resolve-#{incident.id}", "Resolve")

    assert audit_event("alert_incident.acknowledge", incident.id).actor_user_id == scope.user.id

    view
    |> element("#alert-incident-resolve-#{incident.id}")
    |> render_click()

    resolved = Repo.get!(AlertIncident, incident.id)
    assert resolved.state == AlertIncident.resolved_state()
    assert resolved.resolved_at
    assert has_element?(view, "#alert-incident-row-#{incident.id}-state", "Resolved")

    assert has_element?(
             view,
             "#alert-incident-#{incident.id}-actions-resolved",
             "No pending actions"
           )

    assert has_element?(
             view,
             "#alert-incident-card-#{incident.id}-actions-resolved",
             "No pending actions"
           )

    refute has_element?(view, "#alert-incident-resolve-#{incident.id}")
    refute has_element?(view, "#alert-incident-card-resolve-#{incident.id}")

    resolve_audit = audit_event("alert_incident.resolve", incident.id)
    assert resolve_audit.actor_user_id == scope.user.id
    assert resolve_audit.details["previous_state"] == "acknowledged"
    assert resolve_audit.details["state"] == "resolved"

    audit_payload = inspect(audit_events_for_target(incident.id))
    refute audit_payload =~ raw_dedupe_key
    refute audit_payload =~ raw_prompt
  end

  test "incident delivery attempts render safe details on desktop and mobile surfaces", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "alerts-delivery-details", name: "Alerts Delivery Details"})

    assert {:ok, channel} =
             Alerts.create_channel(scope, %{
               channel_type: "webhook",
               display_name: "Delivery detail webhook",
               state: AlertChannel.active_state(),
               endpoint_url: "https://hooks.example.com/alerts/team-secret?token=query-secret",
               webhook_signing_secret: "whsec_hidden_delivery_detail",
               webhook_signing_secret_action: "preserve"
             })

    assert {:ok, rule} =
             Alerts.create_rule(
               scope,
               alert_rule_attrs(pool, %{
                 display_name: "Delivery detail rule",
                 channel_ids: [channel.id]
               })
             )

    raw_dedupe_key = "alert:delivery-raw-dedupe-#{unique_suffix()}"
    raw_url = "https://hooks.example.com/alerts/team-secret?token=query-secret"
    raw_response_body = "raw response body #{unique_suffix()}"
    raw_email_body = "raw email body #{unique_suffix()}"
    raw_bearer = "Bearer delivery-token-#{unique_suffix()}"
    raw_cookie = "session=delivery-cookie-#{unique_suffix()}"
    raw_prompt = "raw delivery prompt #{unique_suffix()}"
    raw_idempotency_key = "idempotency-key-#{unique_suffix()}"

    assert {:ok, incident} =
             Alerts.record_incident_match(%{
               dedupe_key: raw_dedupe_key,
               scope_type: "pool",
               rule_kind: rule.rule_kind,
               severity: rule.severity,
               pool_id: pool.id,
               matched_at: timestamp(~U[2026-05-31 12:00:00Z]),
               safe_evidence_snapshot: %{"prompt" => raw_prompt},
               suppression_metadata: %{},
               targets: [%{rule_id: rule.id, pool_id: pool.id, metadata: %{}}]
             })

    sent_attempt =
      delivery_attempt_fixture(incident, channel,
        status: AlertDeliveryAttempt.sent_status(),
        attempted_at: timestamp(~U[2026-05-31 12:01:00Z]),
        completed_at: timestamp(~U[2026-05-31 12:01:01Z]),
        response_status_code: 202,
        response_metadata: %{
          "delivery_adapter" => "webhook",
          "channel_type" => "webhook",
          "endpoint_host" => "hooks.example.com",
          "endpoint_path_prefix" => "/aler...",
          "endpoint_fingerprint" => "abc123",
          "payload_bytes" => 321,
          "response_status_code" => 202,
          "delivery_status" => "sent",
          "response_body" => raw_response_body,
          "request_body" => raw_email_body,
          "endpoint_url" => raw_url,
          "authorization" => raw_bearer,
          "headers" => %{"cookie" => raw_cookie},
          "prompt" => raw_prompt,
          "idempotency_key" => raw_idempotency_key,
          "dedupe_key" => raw_dedupe_key
        }
      )

    failed_attempt =
      delivery_attempt_fixture(incident, channel,
        status: AlertDeliveryAttempt.failed_status(),
        attempt_number: 2,
        attempted_at: timestamp(~U[2026-05-31 12:02:00Z]),
        completed_at: timestamp(~U[2026-05-31 12:02:01Z]),
        retryable: false,
        failure_code: "webhook_http_401",
        failure_message: "authorization=#{raw_bearer}",
        failure_metadata: %{
          "failure_code" => "webhook_http_401",
          "failure_message" => "token=#{raw_bearer}",
          "retryable" => false,
          "response_body" => raw_response_body,
          "cookie" => raw_cookie
        }
      )

    {:ok, view, html} = live(conn, ~p"/admin/alerts?tab=incidents")

    assert has_element?(view, "#alert-incident-row-#{incident.id}-delivery-label", "2 attempts")

    assert has_element?(
             view,
             "#alert-incident-row-#{incident.id}-delivery-label",
             "needs attention"
           )

    assert has_element?(
             view,
             "#alert-incident-row-#{incident.id}-delivery-label",
             "latest failed"
           )

    for prefix <- ["alert-incident-row", "alert-incident-card"] do
      assert has_element?(
               view,
               "##{prefix}-#{incident.id}-delivery-attempt-#{failed_attempt.id}",
               "Delivery detail webhook"
             )

      assert has_element?(
               view,
               "##{prefix}-#{incident.id}-delivery-attempt-#{failed_attempt.id}",
               "failed"
             )

      assert has_element?(
               view,
               "##{prefix}-#{incident.id}-delivery-attempt-#{failed_attempt.id}-details",
               "webhook_http_401"
             )

      assert has_element?(
               view,
               "##{prefix}-#{incident.id}-delivery-attempt-#{sent_attempt.id}-details",
               "hooks.example.com"
             )

      assert has_element?(
               view,
               "##{prefix}-#{incident.id}-delivery-attempt-#{sent_attempt.id}-details",
               "Payload bytes"
             )
    end

    refute html =~ raw_dedupe_key
    refute html =~ raw_response_body
    refute html =~ raw_email_body
    refute html =~ raw_url
    refute html =~ "team-secret"
    refute html =~ "query-secret"
    refute html =~ raw_bearer
    refute html =~ raw_cookie
    refute html =~ raw_prompt
    refute html =~ raw_idempotency_key
  end

  test "assigned admin incident tab redacts hidden impacted Pools and hidden channels", %{
    scope: scope
  } do
    {:ok, assigned_pool} =
      Pools.create_pool(scope, %{
        slug: "alerts-incident-assigned",
        name: "Alerts Incident Assigned"
      })

    {:ok, hidden_pool} =
      Pools.create_pool(scope, %{
        slug: "alerts-incident-hidden",
        name: "Alerts Incident Hidden Secret"
      })

    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "alerts-incident-admin@example.com",
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: scope.user.id)
    admin_scope = Scope.for_user(admin)

    assert {:ok, visible_channel} =
             Alerts.create_channel(admin_scope, %{
               channel_type: "email",
               display_name: "Visible incident email",
               state: AlertChannel.active_state(),
               email_to: "visible-incidents@example.com"
             })

    assert {:ok, hidden_channel} =
             Alerts.create_channel(scope, %{
               channel_type: "email",
               display_name: "Hidden incident email",
               state: AlertChannel.active_state(),
               email_to: "hidden-incidents@example.com"
             })

    assert {:ok, visible_rule} =
             Alerts.create_rule(
               admin_scope,
               alert_rule_attrs(assigned_pool, %{
                 rule_kind: "upstream_quota_threshold",
                 display_name: "Visible quota incident",
                 severity: "warning",
                 window_selector: "account_primary",
                 threshold_used_percent: Decimal.new("90"),
                 channel_ids: [visible_channel.id]
               })
             )

    assert {:ok, hidden_rule} =
             Alerts.create_rule(
               scope,
               alert_rule_attrs(hidden_pool, %{
                 rule_kind: "upstream_quota_threshold",
                 display_name: "Hidden quota incident",
                 severity: "warning",
                 window_selector: "account_primary",
                 threshold_used_percent: Decimal.new("90"),
                 channel_ids: [hidden_channel.id]
               })
             )

    %{identity: identity} = upstream_assignment_fixture(assigned_pool)
    raw_dedupe_key = "alert:assigned-hidden-dedupe-#{unique_suffix()}"
    raw_token = "hidden-token-#{unique_suffix()}"

    assert {:ok, incident} =
             Alerts.record_incident_match(%{
               dedupe_key: raw_dedupe_key,
               scope_type: "upstream_identity",
               rule_kind: "upstream_quota_threshold",
               severity: "warning",
               upstream_identity_id: identity.id,
               matched_at: timestamp(~U[2026-05-31 10:00:00Z]),
               safe_evidence_snapshot: %{"token" => raw_token},
               suppression_metadata: %{"cookie" => raw_token},
               targets: [
                 %{rule_id: visible_rule.id, pool_id: assigned_pool.id, metadata: %{}},
                 %{
                   rule_id: hidden_rule.id,
                   pool_id: hidden_pool.id,
                   metadata: %{"token" => raw_token}
                 }
               ]
             })

    delivery_attempt_fixture(incident, visible_channel,
      status: AlertDeliveryAttempt.sent_status()
    )

    delivery_attempt_fixture(incident, hidden_channel,
      status: AlertDeliveryAttempt.failed_status()
    )

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, view, html} = live(admin_conn, ~p"/admin/alerts?tab=incidents")

    assert has_element?(view, "#alert-incident-#{incident.id}")

    assert has_element?(
             view,
             "#alert-incident-row-#{incident.id}-impacted-pool-#{assigned_pool.id}",
             assigned_pool.name
           )

    assert has_element?(
             view,
             "#alert-incident-row-#{incident.id}-hidden-pool-count",
             "1 hidden impacted Pool"
           )

    assert has_element?(view, "#alert-incident-row-#{incident.id}-severity", "Warning")
    assert has_element?(view, "#alert-incident-row-#{incident.id}-state", "Open")
    assert has_element?(view, "#alert-incident-row-#{incident.id}-delivery", "1 attempt")
    refute has_element?(view, "#alert-incident-row-#{incident.id}-delivery", "needs attention")

    refute html =~ hidden_pool.id
    refute html =~ hidden_pool.name
    refute html =~ hidden_pool.slug
    refute html =~ hidden_rule.display_name
    refute html =~ hidden_channel.display_name
    refute html =~ hidden_channel.email_to
    refute html =~ raw_dedupe_key
    refute html =~ raw_token

    {:ok, blocked_view, blocked_html} =
      live(admin_conn, ~p"/admin/alerts?tab=incidents&pool_id=#{hidden_pool.id}")

    assert has_element?(blocked_view, "#alerts-incidents-filter-error-pool_id")
    assert has_element?(blocked_view, "#alerts-incidents-empty-state")
    refute blocked_html =~ hidden_pool.id
    refute blocked_html =~ hidden_pool.name
    refute blocked_html =~ hidden_pool.slug
  end

  defp alert_rule_attrs(pool, overrides) do
    overrides = Map.new(overrides)

    %{
      pool_id: pool.id,
      scope_type: "pool",
      rule_kind: Map.get(overrides, :rule_kind, "pool_no_usable_assignments"),
      display_name: Map.get(overrides, :display_name, "Pool usable assignment coverage"),
      severity: Map.get(overrides, :severity, "critical"),
      cooldown_minutes: Map.get(overrides, :cooldown_minutes, 30),
      state: Map.get(overrides, :state, AlertRule.active_state()),
      metadata: %{}
    }
    |> Map.merge(overrides)
  end

  defp delivery_attempt_fixture(incident, channel, attrs) do
    attrs = Map.new(attrs)
    now = now()

    %AlertDeliveryAttempt{}
    |> AlertDeliveryAttempt.changeset(%{
      incident_id: incident.id,
      channel_id: channel.id,
      attempt_number: Map.get(attrs, :attempt_number, 1),
      max_attempts: AlertDeliveryAttempt.fixed_max_attempts(),
      status: Map.fetch!(attrs, :status),
      scheduled_at: Map.get(attrs, :scheduled_at, now),
      attempted_at: Map.get(attrs, :attempted_at, now),
      completed_at: Map.get(attrs, :completed_at, now),
      response_status_code: Map.get(attrs, :response_status_code),
      retryable: Map.get(attrs, :retryable, false),
      failure_code: Map.get(attrs, :failure_code),
      failure_message: Map.get(attrs, :failure_message),
      response_metadata: Map.get(attrs, :response_metadata, %{}),
      failure_metadata: Map.get(attrs, :failure_metadata, %{}),
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp audit_event(action, target_id) do
    Repo.one!(
      from event in AuditEvent,
        where: event.action == ^action and event.target_id == ^target_id,
        order_by: [desc: event.occurred_at, desc: event.id],
        limit: 1
    )
  end

  defp audit_events_for_target(target_id) do
    Repo.all(
      from event in AuditEvent,
        where: event.target_id == ^target_id,
        order_by: [asc: event.occurred_at, asc: event.id]
    )
  end

  defp timestamp(value), do: %{value | microsecond: {0, 6}}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp unique_suffix, do: System.unique_integer([:positive])
end
