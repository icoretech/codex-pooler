defmodule CodexPoolerWeb.Admin.AlertsSavedResetIncidentsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertRule
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.AlertIncidentsReadModel
  alias CodexPoolerWeb.Admin.AlertNotificationsReadModel

  setup :register_and_log_in_user

  @tag :saved_reset_banked_first_seen
  test "saved reset aggregate incidents render safe account evidence without duplicate pool slugs",
       %{
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

    hostile_account_label = ~s|<script>alert("reset")</script> Banked account|
    raw_account_email = "saved-reset-raw-email-#{unique_suffix()}@example.com"

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: hostile_account_label,
        account_email: raw_account_email,
        chatgpt_account_id: "acct_safe_#{unique_suffix()}"
      })

    raw_credit_id = "provider-credit-#{unique_suffix()}"
    raw_provider_payload = "provider payload #{unique_suffix()}"

    assert {:ok, incident} =
             Alerts.record_incident_match(%{
               dedupe_key:
                 "alerts:v2:upstream_saved_reset_banked_first_seen:upstream_identity:#{identity.id}",
               scope_type: "upstream_identity",
               rule_kind: rule.rule_kind,
               severity: "info",
               upstream_identity_id: identity.id,
               matched_at: timestamp(~U[2026-07-02 08:01:00Z]),
               safe_evidence_snapshot: %{
                 "reason_code" => "saved_reset_banked_first_seen",
                 "available_count" => 3,
                 "new_reset_count" => 2,
                 "earliest_reset_first_seen_at" => "2026-07-02T08:00:00Z",
                 "latest_reset_first_seen_at" => "2026-07-02T08:05:00Z",
                 "next_reset_expires_at" => "2026-07-03T09:00:00Z",
                 "latest_reset_expires_at" => "2026-07-04T10:00:00Z",
                 "source" => "persisted_saved_resets",
                 "path_style" => "codex",
                 "pool_upstream_assignment_id" => "raw-assignment-#{unique_suffix()}",
                 "upstream_identity_id" => identity.id,
                 "provider_credit_id" => raw_credit_id,
                 "provider_payload" => raw_provider_payload,
                 "raw_saved_reset_payload" => %{"secret" => "raw payload #{unique_suffix()}"}
               },
               suppression_metadata: %{},
               targets: [%{rule_id: rule.id, pool_id: pool.id, metadata: %{}}]
             })

    {:ok, view, html} = live(conn, ~p"/admin/alerts?tab=incidents")

    assert Regex.scan(~r/data-role="alert-incident-row"/, html) |> length() == 1
    assert html =~ ~s(id="alert-incident-#{incident.id}")
    assert html =~ ~s(id="alert-incident-card-#{incident.id}")

    assert has_element?(
             view,
             "#alert-incident-row-#{incident.id}-reason",
             "New banked reset evidence"
           )

    for prefix <- ["alert-incident-row", "alert-incident-card"] do
      assert has_element?(
               view,
               "##{prefix}-#{incident.id}-detail",
               "new banked reset evidence on an upstream account"
             )

      assert has_element?(view, "##{prefix}-#{incident.id}-detail", hostile_account_label)
      assert has_element?(view, "##{prefix}-#{incident.id}-detail", "2 new resets")
      assert has_element?(view, "##{prefix}-#{incident.id}-detail", "3 banked resets available")

      assert has_element?(
               view,
               "##{prefix}-#{incident.id}-detail",
               "next expires 2026-07-03T09:00:00Z"
             )

      assert has_element?(
               view,
               "##{prefix}-#{incident.id}-detail",
               "latest expires 2026-07-04T10:00:00Z"
             )

      assert has_element?(
               view,
               "##{prefix}-#{incident.id}-impacted-pool-#{pool.id} [data-role='incident-impacted-pool-name']",
               pool.name
             )
    end

    assert html =~ "&lt;script&gt;alert(&quot;reset&quot;)&lt;/script&gt; Banked account"
    refute html =~ ~s|<script>alert("reset")</script>|
    refute html =~ "data-role=\"incident-impacted-pool-slug\""
    refute html =~ "#{pool.name} #{pool.slug}"
    refute html =~ identity.id
    refute html =~ raw_account_email
    refute html =~ raw_credit_id
    refute html =~ raw_provider_payload
    refute html =~ "pool_upstream_assignment_id"
    refute html =~ "upstream_identity_id"
    refute html =~ "provider_credit_id"
    refute html =~ "provider_payload"
    refute html =~ "raw_saved_reset_payload"
    refute html =~ "reset_expires_at"
    refute html =~ "reset_first_seen_at"

    notification_state = AlertNotificationsReadModel.load(scope)

    assert [%{reason_title: "First-seen banked saved reset"}] = notification_state.rows
  end

  @tag :saved_reset_banked_first_seen
  test "saved reset incident account label precedence stays metadata-only", %{scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{
        slug: "alerts-saved-reset-account-labels",
        name: "Alerts Saved Reset Account Labels"
      })

    assert {:ok, rule} =
             Alerts.create_rule(
               scope,
               alert_rule_attrs(pool, %{
                 rule_kind: "upstream_saved_reset_banked_first_seen",
                 scope_type: "upstream_identity",
                 display_name: "Saved reset account labels",
                 severity: "info"
               })
             )

    %{identity: labeled_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Labeled upstream account",
        chatgpt_account_id: "acct_label_unused_#{unique_suffix()}",
        account_email: "labeled-hidden-#{unique_suffix()}@example.com"
      })

    %{identity: chatgpt_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: " ",
        chatgpt_account_id: "acct_visible_#{unique_suffix()}",
        account_email: "chatgpt-hidden-#{unique_suffix()}@example.com"
      })

    %{identity: fallback_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: " ",
        chatgpt_account_id: nil,
        account_email: "fallback-hidden-#{unique_suffix()}@example.com"
      })

    safe_chatgpt_account_id = "acct_safe_visible_#{unique_suffix()}"
    email_like_account_label = "email-label-hidden-#{unique_suffix()}@example.com"

    %{identity: email_label_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: email_like_account_label,
        chatgpt_account_id: safe_chatgpt_account_id,
        account_email: "email-label-source-hidden-#{unique_suffix()}@example.com"
      })

    fallback_email_like_account_label = "fallback-label-hidden-#{unique_suffix()}@example.com"

    %{identity: email_label_fallback_identity} =
      upstream_assignment_fixture(pool, %{
        account_label: fallback_email_like_account_label,
        chatgpt_account_id: nil,
        account_email: "email-label-fallback-source-hidden-#{unique_suffix()}@example.com"
      })

    incidents =
      for identity <- [
            labeled_identity,
            chatgpt_identity,
            fallback_identity,
            email_label_identity,
            email_label_fallback_identity
          ] do
        assert {:ok, incident} =
                 Alerts.record_incident_match(%{
                   dedupe_key:
                     "alerts:v2:upstream_saved_reset_banked_first_seen:upstream_identity:#{identity.id}",
                   scope_type: "upstream_identity",
                   rule_kind: rule.rule_kind,
                   severity: "info",
                   upstream_identity_id: identity.id,
                   matched_at: timestamp(~U[2026-07-02 08:01:00Z]),
                   safe_evidence_snapshot: %{
                     "reason_code" => "saved_reset_banked_first_seen",
                     "available_count" => 1,
                     "new_reset_count" => 1
                   },
                   suppression_metadata: %{},
                   targets: [%{rule_id: rule.id, pool_id: pool.id, metadata: %{}}]
                 })

        {identity, incident}
      end

    rows_by_id =
      scope
      |> AlertIncidentsReadModel.load(%{})
      |> Map.fetch!(:incidents)
      |> Map.new(&{&1.id, &1})

    for {identity, incident} <- incidents do
      row = Map.fetch!(rows_by_id, incident.id)
      refute row.reason_detail =~ identity.id
      refute row.reason_detail =~ "hidden-"
    end

    assert rows_by_id[elem(Enum.at(incidents, 0), 1).id].upstream_account_label ==
             "Labeled upstream account"

    assert rows_by_id[elem(Enum.at(incidents, 1), 1).id].upstream_account_label =~ "acct_visible_"

    assert rows_by_id[elem(Enum.at(incidents, 2), 1).id].upstream_account_label ==
             "Upstream account"

    email_label_row = rows_by_id[elem(Enum.at(incidents, 3), 1).id]

    assert email_label_row.upstream_account_label == safe_chatgpt_account_id
    assert email_label_row.reason_detail =~ safe_chatgpt_account_id
    refute email_label_row.reason_detail =~ email_like_account_label

    email_label_fallback_row = rows_by_id[elem(Enum.at(incidents, 4), 1).id]

    assert email_label_fallback_row.upstream_account_label == "Upstream account"
    assert email_label_fallback_row.reason_detail =~ "upstream account: Upstream account"
    refute email_label_fallback_row.reason_detail =~ fallback_email_like_account_label
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

  defp timestamp(value), do: %{value | microsecond: {0, 6}}
  defp unique_suffix, do: System.unique_integer([:positive])
end
