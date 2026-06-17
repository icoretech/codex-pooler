defmodule CodexPooler.Admin.AlertIncidentsReadModelTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.AlertIncidentsReadModel

  alias CodexPooler.Alerts.Schemas.{
    AlertDeliveryAttempt,
    AlertRuleChannel
  }

  alias CodexPooler.Repo

  test "relationship projections return linked visible rules, channels, and redacted delivery metadata" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner)

    pool =
      pool_fixture(%{slug: "alert-incidents-owner-#{unique_suffix()}", name: "Owner Incidents"})

    channel = alert_channel_fixture(%{display_name: "Owner delivery channel"})
    rule = alert_rule_fixture(pool, %{display_name: "Owner linked rule"})
    link_rule_channel!(rule, channel)

    raw_url = "https://hooks.example.com/alerts/team-secret?token=#{unique_suffix()}"
    raw_bearer = "Bearer owner-delivery-token-#{unique_suffix()}"
    raw_prompt = "prompt #{unique_suffix()}"

    incident =
      alert_incident_fixture(
        pool: pool,
        safe_evidence_snapshot: %{"prompt" => raw_prompt},
        suppression_metadata: %{"token" => raw_bearer}
      )

    alert_incident_target_fixture(incident, rule, pool)

    attempt =
      delivery_attempt_fixture(incident, channel,
        status: AlertDeliveryAttempt.failed_status(),
        failure_code: "webhook_http_401",
        failure_message: "authorization=#{raw_bearer}",
        response_status_code: 401,
        response_metadata: %{
          "delivery_adapter" => "webhook",
          "channel_type" => "webhook",
          "endpoint_host" => "hooks.example.com",
          "endpoint_url" => raw_url,
          "request_body" => raw_prompt,
          "authorization" => raw_bearer
        },
        failure_metadata: %{"failure_code" => "webhook_http_401", "token" => raw_bearer}
      )

    assert {:ok, incidents} = AlertIncidentsReadModel.list_incidents(scope, %{state: "open"})
    assert Enum.any?(incidents, &(&1.id == incident.id))

    incident_id = incident.id
    projections = AlertIncidentsReadModel.incident_relationship_projections(scope, incidents)

    assert %{
             linked_rules_by_incident: %{^incident_id => [linked_rule]},
             delivery_summaries_by_incident: %{^incident_id => summary}
           } = projections

    assert linked_rule.label == "Owner linked rule"
    assert linked_rule.value == rule.id

    assert [%{label: "Owner delivery channel", value: channel_id, channel_type: "email"}] =
             linked_rule.channels

    assert channel_id == channel.id

    assert summary.total_count == 1
    assert summary.sent_count == 0
    assert summary.attention_count == 1
    assert summary.latest_status == AlertDeliveryAttempt.failed_status()

    assert [%{id: attempt_id, channel_label: "Owner delivery channel"} = projected_attempt] =
             summary.attempts

    assert attempt_id == attempt.id

    assert projected_attempt.response_metadata == %{
             "delivery_adapter" => "webhook",
             "channel_type" => "webhook",
             "endpoint_host" => "hooks.example.com"
           }

    refute inspect(projections) =~ raw_url
    refute inspect(projections) =~ raw_bearer
    refute inspect(projections) =~ raw_prompt
  end

  test "assigned admin projections hide hidden Pool rule/channel/delivery relationships" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)

    %{user: admin} =
      operator_fixture(owner, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    assigned_pool =
      pool_fixture(%{
        slug: "alert-incidents-assigned-#{unique_suffix()}",
        name: "Assigned Incidents"
      })

    hidden_pool =
      pool_fixture(%{slug: "alert-incidents-hidden-#{unique_suffix()}", name: "Hidden Incidents"})

    operator_pool_assignment_fixture(admin, assigned_pool, created_by_user_id: owner.id)
    admin_scope = Scope.for_user(admin)

    visible_channel =
      alert_channel_fixture(%{
        display_name: "Visible incident channel",
        created_by_user_id: admin.id
      })

    hidden_channel =
      alert_channel_fixture(%{
        display_name: "Hidden incident channel",
        created_by_user_id: owner.id
      })

    visible_rule = alert_rule_fixture(assigned_pool, %{display_name: "Visible incident rule"})
    hidden_rule = alert_rule_fixture(hidden_pool, %{display_name: "Hidden incident rule"})
    link_rule_channel!(visible_rule, visible_channel)
    link_rule_channel!(hidden_rule, hidden_channel)

    raw_hidden = "hidden-token-#{unique_suffix()}"
    %{identity: identity} = upstream_assignment_fixture(assigned_pool)

    incident =
      alert_incident_fixture(
        upstream_identity_id: identity.id,
        rule_kind: "upstream_quota_threshold",
        safe_evidence_snapshot: %{"token" => raw_hidden}
      )

    alert_incident_target_fixture(incident, visible_rule, assigned_pool)

    alert_incident_target_fixture(incident, hidden_rule, hidden_pool,
      metadata: %{"token" => raw_hidden}
    )

    delivery_attempt_fixture(incident, visible_channel,
      status: AlertDeliveryAttempt.sent_status()
    )

    delivery_attempt_fixture(incident, hidden_channel,
      status: AlertDeliveryAttempt.failed_status(),
      failure_message: raw_hidden
    )

    assert {:ok, incidents} = AlertIncidentsReadModel.list_incidents(admin_scope, %{})
    incident_id = incident.id
    assert Enum.any?(incidents, &(&1.id == incident_id))

    projections =
      AlertIncidentsReadModel.incident_relationship_projections(admin_scope, incidents)

    assert %{^incident_id => [linked_rule]} = projections.linked_rules_by_incident
    assert linked_rule.label == "Visible incident rule"
    assert [%{label: "Visible incident channel"}] = linked_rule.channels

    assert %{^incident_id => summary} = projections.delivery_summaries_by_incident
    assert summary.total_count == 1
    assert [%{channel_label: "Visible incident channel", status: "sent"}] = summary.attempts

    refute inspect(projections) =~ hidden_pool.id
    refute inspect(projections) =~ hidden_pool.name
    refute inspect(projections) =~ hidden_rule.display_name
    refute inspect(projections) =~ hidden_channel.display_name
    refute inspect(projections) =~ raw_hidden

    assert {:ok, owner_incidents} = AlertIncidentsReadModel.list_incidents(owner_scope, %{})

    owner_projections =
      AlertIncidentsReadModel.incident_relationship_projections(owner_scope, owner_incidents)

    assert %{^incident_id => owner_summary} = owner_projections.delivery_summaries_by_incident
    assert owner_summary.total_count == 2
  end

  defp link_rule_channel!(rule, channel) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %AlertRuleChannel{}
    |> AlertRuleChannel.changeset(%{
      alert_rule_id: rule.id,
      alert_channel_id: channel.id,
      created_at: now
    })
    |> Repo.insert!()
  end

  defp delivery_attempt_fixture(incident, channel, attrs) do
    attrs = Map.new(attrs)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

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

  defp unique_suffix, do: System.unique_integer([:positive])
end
