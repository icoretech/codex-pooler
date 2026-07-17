defmodule CodexPooler.Alerts.EmailRedactionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import Swoosh.TestAssertions

  alias CodexPooler.Alerts.Delivery.EmailDelivery

  alias CodexPooler.Alerts.Schemas.{
    AlertChannel,
    AlertDeliveryAttempt,
    AlertIncident,
    AlertIncidentTarget,
    AlertRule,
    AlertRuleChannel
  }

  alias CodexPooler.Jobs.AlertDeliveryWorker
  alias CodexPooler.Mailer
  alias CodexPooler.Repo

  @raw_forbidden_values [
    "raw prompt sentinel",
    "raw request body sentinel",
    "raw response body sentinel",
    "Bearer raw-token-sentinel",
    "auth json sentinel",
    "cookie sentinel",
    "headers sentinel",
    "provider payload sentinel",
    "webhook raw payload sentinel",
    "webhook secret sentinel",
    "file body sentinel",
    "websocket frame sentinel",
    "raw idempotency key sentinel"
  ]

  setup do
    mailer_config = Application.get_env(:codex_pooler, Mailer)

    Repo.delete_all(AlertDeliveryAttempt)
    Repo.delete_all(Oban.Job)
    Repo.delete_all(AlertIncidentTarget)
    Repo.delete_all(AlertIncident)
    Repo.delete_all(AlertRuleChannel)
    Repo.delete_all(AlertRule)
    Repo.delete_all(AlertChannel)

    Application.put_env(:codex_pooler, Mailer, adapter: Swoosh.Adapters.Test)

    on_exit(fn -> restore_env(:codex_pooler, Mailer, mailer_config) end)

    :ok
  end

  test "alert email body and delivery attempt metadata stay metadata-only" do
    pool =
      pool_fixture(%{slug: "redaction-alert-#{unique_suffix()}", name: "Redaction Alert Pool"})

    channel = alert_channel_fixture(email_to: "redaction-alerts@example.com")
    rule = alert_rule_fixture(pool, cooldown_minutes: 30)
    link_rule_channel!(rule, channel)

    incident =
      alert_incident_fixture(
        pool: pool,
        dedupe_key: "alert:redaction:#{unique_suffix()}",
        safe_evidence_snapshot: unsafe_evidence(),
        suppression_metadata: unsafe_suppression_metadata()
      )

    alert_incident_target_fixture(incident, rule, pool, metadata: unsafe_evidence())

    email = EmailDelivery.alert_email(incident, channel)
    refute_forbidden_values(email.text_body)
    assert email.text_body =~ "Reason code: no_usable_assignments"
    assert email.text_body =~ "- assignment_count: 0"
    refute email.text_body =~ "safe_to_ignore"

    assert :ok =
             perform_job(AlertDeliveryWorker, %{
               "alert_incident_id" => incident.id,
               "alert_channel_id" => channel.id
             })

    assert_email_sent(fn sent_email ->
      refute_forbidden_values(sent_email.text_body)
      true
    end)

    assert [attempt] = Repo.all(AlertDeliveryAttempt)

    attempt_metadata =
      Jason.encode!(%{
        response_metadata: attempt.response_metadata,
        failure_metadata: attempt.failure_metadata,
        failure_code: attempt.failure_code,
        failure_message: attempt.failure_message
      })

    refute_forbidden_values(attempt_metadata)

    assert attempt.response_metadata["safe_evidence_summary"] == %{
             "assignment_count" => 0,
             "reason_code" => "no_usable_assignments"
           }
  end

  @tag :saved_reset_banked_first_seen
  test "saved reset alert email summary exposes only reset safe evidence" do
    pool =
      pool_fixture(%{
        slug: "saved-reset-email-#{unique_suffix()}",
        name: "Saved Reset Email Pool"
      })

    channel = alert_channel_fixture(email_to: "saved-reset-alerts@example.com")

    rule =
      alert_rule_fixture(pool,
        rule_kind: "upstream_saved_reset_banked_first_seen",
        scope_type: "upstream_identity",
        severity: "info",
        cooldown_minutes: 30
      )

    link_rule_channel!(rule, channel)

    %{identity: identity} = upstream_assignment_fixture(pool)

    incident =
      alert_incident_fixture(
        upstream_identity: identity,
        rule_kind: "upstream_saved_reset_banked_first_seen",
        severity: "info",
        dedupe_key: "alert:saved-reset:#{identity.id}:2026-07-03T09:00:00Z",
        safe_evidence_snapshot: saved_reset_evidence(),
        suppression_metadata: unsafe_suppression_metadata()
      )

    alert_incident_target_fixture(incident, rule, pool, metadata: saved_reset_evidence())

    email = EmailDelivery.alert_email(incident, channel)
    refute_forbidden_values(email.text_body)
    assert email.text_body =~ "Reason code: saved_reset_banked_first_seen"
    assert email.text_body =~ "- available_count: 2"
    assert email.text_body =~ "- new_reset_count: 2"
    assert email.text_body =~ "- earliest_reset_first_seen_at: 2026-07-02T08:00:00Z"
    assert email.text_body =~ "- latest_reset_first_seen_at: 2026-07-02T09:30:00Z"
    assert email.text_body =~ "- next_reset_expires_at: 2026-07-03T09:00:00Z"
    assert email.text_body =~ "- latest_reset_expires_at: 2026-07-04T10:00:00Z"
    assert email.text_body =~ "- source: persisted_saved_resets"
    refute email.text_body =~ "provider-credit-hidden"
    refute email.text_body =~ "pool_upstream_assignment_id"
    refute email.text_body =~ "upstream_identity_id"

    assert :ok =
             perform_job(AlertDeliveryWorker, %{
               "alert_incident_id" => incident.id,
               "alert_channel_id" => channel.id
             })

    assert [attempt] = Repo.all(AlertDeliveryAttempt)

    assert attempt.response_metadata["safe_evidence_summary"] == %{
             "available_count" => 2,
             "new_reset_count" => 2,
             "impacted_pool_count" => 1,
             "path_style" => "codex",
             "reason_code" => "saved_reset_banked_first_seen",
             "earliest_reset_first_seen_at" => "2026-07-02T08:00:00Z",
             "latest_reset_first_seen_at" => "2026-07-02T09:30:00Z",
             "next_reset_expires_at" => "2026-07-03T09:00:00Z",
             "latest_reset_expires_at" => "2026-07-04T10:00:00Z",
             "source" => "persisted_saved_resets"
           }

    attempt_metadata = Jason.encode!(attempt.response_metadata)
    refute attempt_metadata =~ "provider-credit-hidden"
    refute attempt_metadata =~ "pool_upstream_assignment_id"
  end

  defp unsafe_evidence do
    %{
      "reason_code" => "no_usable_assignments",
      "assignment_count" => 0,
      "prompt" => "raw prompt sentinel",
      "request_body" => "raw request body sentinel",
      "response_body" => "raw response body sentinel",
      "authorization" => "Bearer raw-token-sentinel",
      "auth_json" => "auth json sentinel",
      "cookies" => "cookie sentinel",
      "headers" => "headers sentinel",
      "provider_payload" => "provider payload sentinel",
      "webhook_raw_payload" => "webhook raw payload sentinel",
      "webhook_secret" => "webhook secret sentinel",
      "file_body" => "file body sentinel",
      "websocket_frame" => "websocket frame sentinel",
      "idempotency_key" => "raw idempotency key sentinel",
      "safe_to_ignore" => "not rendered because not in the alert summary allowlist"
    }
  end

  defp saved_reset_evidence do
    %{
      "reason_code" => "saved_reset_banked_first_seen",
      "earliest_reset_first_seen_at" => "2026-07-02T08:00:00Z",
      "latest_reset_first_seen_at" => "2026-07-02T09:30:00Z",
      "next_reset_expires_at" => "2026-07-03T09:00:00Z",
      "latest_reset_expires_at" => "2026-07-04T10:00:00Z",
      "available_count" => 2,
      "new_reset_count" => 2,
      "source" => "persisted_saved_resets",
      "path_style" => "codex",
      "impacted_pool_count" => 1,
      "pool_id" => Ecto.UUID.generate(),
      "upstream_identity_id" => Ecto.UUID.generate(),
      "pool_upstream_assignment_id" => Ecto.UUID.generate(),
      "provider_credit_id" => "provider-credit-hidden",
      "provider_payload" => "provider payload sentinel",
      "auth_json" => "auth json sentinel",
      "token" => "Bearer raw-token-sentinel",
      "request_body" => "raw request body sentinel"
    }
  end

  defp unsafe_suppression_metadata do
    %{
      "prompt" => "raw prompt sentinel",
      "token" => "Bearer raw-token-sentinel"
    }
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

  defp refute_forbidden_values(value) do
    encoded = to_string(value)

    for forbidden <- @raw_forbidden_values do
      refute encoded =~ forbidden
    end
  end

  defp unique_suffix, do: System.unique_integer([:positive])
  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
