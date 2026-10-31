defmodule CodexPoolerWeb.Admin.OperationsLocaleTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Alerts
  alias CodexPooler.Audit
  alias CodexPooler.OpenAIStatus
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.AuditLogsComponents.Prose

  setup :register_and_log_in_user

  test "Chinese alert workspace translates rule editor and rule vocabulary", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "locale-alert-rules", name: "Locale alert rules"})
    {:ok, rule} = Alerts.create_rule(scope, rule_attrs(pool))

    {:ok, view, _html} = live(put_locale(conn, "zh-CN"), ~p"/admin/alerts")

    assert has_element?(view, "#alerts-page-header", "告警")
    assert has_element?(view, "#alert-rule-submit", "创建规则")
    assert has_element?(view, "label[for='alert-rule-display-name']", "规则名称")
    assert has_element?(view, "#alert-rule-kind option[value='pool_no_usable_assignments']", "无可用分配")
    assert has_element?(view, "#alert-rule-row-#{rule.id}-state", "已启用")
    assert has_element?(view, "#alert-rule-row-#{rule.id}-kind", "无可用分配")
  end

  test "Chinese alert incidents translate projected state and acknowledgement feedback", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "locale-alert-incidents", name: "Locale incident Pool"})
    {:ok, rule} = Alerts.create_rule(scope, rule_attrs(pool))
    dedupe_key = "locale-incident-#{System.unique_integer([:positive])}"

    {:ok, incident} =
      Alerts.record_incident_match(%{
        dedupe_key: dedupe_key,
        scope_type: "pool",
        rule_kind: rule.rule_kind,
        severity: rule.severity,
        pool_id: pool.id,
        matched_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        safe_evidence_snapshot: %{"state_counts" => %{"model_not_served" => 2}},
        suppression_metadata: %{},
        targets: [%{rule_id: rule.id, pool_id: pool.id, metadata: %{}}]
      })

    {:ok, view, html} = live(put_locale(conn, "zh-CN"), ~p"/admin/alerts?tab=incidents")

    assert has_element?(view, "#alerts-incidents-list", "告警事件")
    assert has_element?(view, "#alert-incident-row-#{incident.id}-reason", "无可用分配")
    assert has_element?(view, "#alert-incident-row-#{incident.id}-state", "未解决")
    assert has_element?(view, "#alert-incident-row-#{incident.id}-detail", "模型未提供服务")
    assert has_element?(view, "#alert-incident-row-#{incident.id}-delivery-label", "暂无投递尝试")
    assert has_element?(view, "#alert-incident-acknowledge-#{incident.id}", "确认")
    refute html =~ dedupe_key

    view |> element("#alert-incident-acknowledge-#{incident.id}") |> render_click()

    assert has_element?(view, "#alert-incident-row-#{incident.id}-state", "已确认")
    assert has_element?(view, "#flash-info", "告警事件已确认")
  end

  test "Chinese OpenAI incidents translate heading empty history and read-model status", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, incident} =
      OpenAIStatus.upsert_incident(
        %{
          guid: "locale-openai-incident",
          title: "Synthetic service incident",
          status: "Investigating",
          summary: "Synthetic service metadata",
          component: nil,
          link: "https://status.openai.com/incidents/locale-openai-incident",
          published_at: now,
          content_hash: "locale-openai-content"
        },
        now
      )

    OpenAIStatus.upsert_feed_state(%{last_success_at: now, last_attempt_at: now, active_count: 1, aggregate_revision: 1, updated_at: now})
    {:ok, view, _html} = live(put_locale(conn, "zh-CN"), ~p"/admin/incidents")

    assert has_element?(view, "#admin-incidents-page-header", "OpenAI 事件")
    assert has_element?(view, "#admin-incidents-history-empty", "暂无历史事件")
    assert has_element?(view, "#openai-incident-status-active-#{incident.id}", "调查中")
    assert has_element?(view, "#admin-incidents-active-table-row-#{incident.id} [data-role='incident-component']", "未指定")
    assert has_element?(view, "#admin-incidents-active-table-source-#{incident.id}", "查看")
  end

  test "Chinese audit sentences translate two actions while retaining semantic filters", %{conn: conn, scope: scope, user: user} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "locale-audit-pool", name: "Locale audit Pool"})
    {:ok, login} = Audit.record_user_event(user, %{action: "auth.login", target_type: "user", target_id: user.id, ip_address: "192.0.2.14"})

    {:ok, status} =
      Audit.record_user_event(user, %{
        pool_id: pool.id,
        action: "pool.status_update",
        target_type: "pool",
        target_id: pool.id,
        details: %{"status" => "paused"}
      })

    {:ok, view, _html} = live(put_locale(conn, "zh-CN"), ~p"/admin/audit-logs")

    assert has_element?(view, "#audit-log-page-header", "审计日志")
    assert has_element?(view, "#audit-log-action-filter button[data-action='auth.login']", "运营者已登录")
    assert has_element?(view, "#audit-log-row-#{login.id}", "登录")
    assert has_element?(view, "#audit-log-row-#{login.id}", "来源")
    assert has_element?(view, "#audit-log-row-#{login.id}", "192.0.2.14")
    assert has_element?(view, "#audit-log-row-#{status.id}", "更改了 Pool")
    assert has_element?(view, "#audit-log-row-#{status.id} [data-role='audit-prose-detail-tail']", "paused")
    assert has_element?(view, "#audit-log-row-#{status.id} [data-role='audit-prose-pool']", pool.name)

    view |> element("#audit-log-row-#{status.id} [data-role='audit-prose-pool']") |> render_click()
    assert_patch(view, ~p"/admin/audit-logs?pool_id=#{pool.id}")
    assert has_element?(view, "#audit-log-row-#{status.id}", "更改了 Pool")
  end

  test "Chinese operator page translates create dialog and role vocabulary", %{conn: conn, user: user} do
    {:ok, view, _html} = live(put_locale(conn, "zh-CN"), ~p"/admin/operators")

    assert has_element?(view, "#operators-page-header", "运营者")
    assert has_element?(view, "#operator-row-#{user.id}-role", "实例所有者")
    view |> element("#operator-page-create-action") |> render_click()

    assert has_element?(view, "#operator-create-dialog[open]", "运营者")
    assert has_element?(view, "#operator-create-submit", "创建运营者")
    assert has_element?(view, "label[for='operator_email']", "电子邮件")
    assert has_element?(view, "#operator_role", "实例管理员")
    assert has_element?(view, "#operator_role_instance_admin[value='instance_admin'][checked]")
  end

  test "Chinese invite page translates empty state dialog and stored status", %{conn: conn, scope: scope} do
    pool = pool_fixture(%{slug: "locale-invite-pool", name: "Locale invite Pool"})
    conn = put_locale(conn, "zh-CN")
    {:ok, empty_view, _html} = live(conn, ~p"/admin/invites")

    assert has_element?(empty_view, "#invite-page-header", "邀请")
    assert has_element?(empty_view, "#invite-empty-state", "暂无 Pool 邀请")
    empty_view |> element("#invite-page-create-action") |> render_click()
    assert has_element?(empty_view, "#pool-invite-dialog[open]", "创建 Pool 邀请")
    assert has_element?(empty_view, "#pool-invite-submit", "创建 Pool 邀请")

    {:ok, %{invite: invite}} = Access.create_invite(scope, pool, %{invited_email: "locale-invite@example.com"})
    {:ok, view, _html} = live(conn, ~p"/admin/invites")
    assert has_element?(view, "#invite-status-#{invite.id}", "启用")
    assert has_element?(view, "#invite-row-#{invite.id}", "等待接受")
  end

  test "audit templates preserve English wording, interactive slots, and unknown fallback" do
    event = %{
      id: "literal-audit",
      action: "pool.status_update",
      actor_type: "user",
      actor_user_email: "audit-actor@example.com",
      actor_user_id: "actor-id",
      pool_id: "pool-id",
      target_type: "pool",
      target_id: "pool-id",
      outcome: "success",
      occurred_at: ~U[2026-10-30 12:00:00Z],
      details: %{"status" => "paused"}
    }

    preferences = CodexPoolerWeb.DateTimeDisplay.preferences_for_user(nil)
    assigns = %{event: event, pool_names: %{"pool-id" => "Example Pool"}, datetime_preferences: preferences}
    html = render_component(&Prose.event_sentence/1, assigns)
    text = html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.replace(~r/\s+/, " ")

    assert text =~ "audit-actor@example.com changed the status of the Pool Example Pool to paused"
    assert html =~ ~s(data-role="audit-prose-pool")
    assert html =~ ~s(data-role="audit-prose-detail-tail")

    fallback = render_component(&Prose.event_sentence/1, %{assigns | event: %{event | action: "future.action"}})
    assert fallback =~ ~s(data-role="audit-prose-fallback")
    assert fallback |> LazyHTML.from_fragment() |> LazyHTML.text() =~ "future action"
  end

  test "translated audit slots reorder data without interpreting user text as markup" do
    Gettext.put_locale("zh_CN")
    email = "<script>audit-value</script>"

    event = %{
      id: "literal-invite",
      action: "invite.create",
      actor_type: "system",
      pool_id: "pool-id",
      target_type: "pool",
      target_id: "pool-id",
      outcome: "success",
      occurred_at: ~U[2026-10-30 12:00:00Z],
      details: %{"invited_email" => email}
    }

    html =
      render_component(&Prose.event_sentence/1,
        event: event,
        pool_names: %{"pool-id" => "Example Pool"},
        datetime_preferences: CodexPoolerWeb.DateTimeDisplay.preferences_for_user(nil)
      )

    document = LazyHTML.from_fragment(html)
    assert document |> LazyHTML.query("script") |> Enum.empty?()
    assert document |> LazyHTML.query("[data-role='audit-prose-invited-email']") |> LazyHTML.text() == email
    assert LazyHTML.text(document) =~ "邀请"
    assert document |> LazyHTML.query("[data-role='audit-prose-pool']") |> LazyHTML.text() == "Example Pool"
  end

  defp rule_attrs(pool) do
    %{
      pool_id: pool.id,
      scope_type: "pool",
      rule_kind: "pool_no_usable_assignments",
      display_name: "Locale rule",
      severity: "critical",
      cooldown_minutes: 30,
      state: "active",
      metadata: %{}
    }
  end
end
