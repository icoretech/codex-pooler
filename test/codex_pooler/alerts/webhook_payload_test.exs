defmodule CodexPooler.Alerts.WebhookPayloadTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Alerts.Schemas.{AlertChannel, AlertDeliveryAttempt, AlertIncident}
  alias CodexPooler.Alerts.WebhookPayload

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
    "raw idempotency key sentinel",
    "query-hidden",
    "https://hooks.example.com/alerts/team?token=query-hidden",
    "whsec_payload_hidden"
  ]

  test "webhook payload contains only the metadata delivery contract" do
    incident = incident_fixture()
    channel = channel_fixture()
    attempt = attempt_fixture(channel.id, incident.id)

    payload = WebhookPayload.payload(incident, channel, attempt)

    assert payload == %{
             "event_id" => "alert.#{incident.id}.#{channel.id}.2",
             "attempt_id" => attempt.id,
             "incident_id" => incident.id,
             "channel_id" => channel.id,
             "dedupe_key" => "alert:webhook:payload",
             "severity" => "critical",
             "rule_kind" => "pool_no_usable_assignments",
             "reason_code" => "no_usable_assignments",
             "scope_metadata" => %{
               "pool_id" => incident.pool_id,
               "scope_type" => "pool"
             },
             "safe_evidence_summary" => %{
               "assignment_count" => 0,
               "model" => "gpt-5.5",
               "quota_state" => "exhausted",
               "reason_code" => "no_usable_assignments",
               "status" => "active",
               "threshold_used_percent" => "97.5",
               "used_percent" => 98.25,
               "window_selector" => "weekly"
             },
             "occurrence_count" => 3,
             "first_seen_at" => "2026-05-30T14:00:00Z",
             "last_seen_at" => "2026-05-30T14:10:00Z"
           }

    refute Map.has_key?(payload, "endpoint_url")
    refute Map.has_key?(payload, "endpoint_host")
    refute Map.has_key?(payload, "endpoint_path_prefix")
    refute Map.has_key?(payload, "webhook_signing_secret")
  end

  test "encoded webhook payload is stable JSON and omits raw sensitive material" do
    incident = incident_fixture()
    channel = channel_fixture()
    attempt = attempt_fixture(channel.id, incident.id)

    assert %{event_id: event_id, body: body} = WebhookPayload.encode(incident, channel, attempt)
    assert event_id == "alert.#{incident.id}.#{channel.id}.2"
    assert Jason.decode!(body) == WebhookPayload.payload(incident, channel, attempt)
    assert body == WebhookPayload.encode(incident, channel, attempt).body

    refute_forbidden_values(body)
  end

  test "safe evidence summary allowlist excludes unsafe values and unsupported shapes" do
    summary = WebhookPayload.safe_evidence_summary(unsafe_evidence())

    assert summary == %{
             "assignment_count" => 0,
             "model" => "gpt-5.5",
             "quota_state" => "exhausted",
             "reason_code" => "no_usable_assignments",
             "status" => "active",
             "threshold_used_percent" => "97.5",
             "used_percent" => 98.25,
             "window_selector" => "weekly"
           }

    refute_forbidden_values(Jason.encode!(summary))
  end

  @tag :saved_reset_banked_first_seen
  test "saved reset webhook safe evidence summary uses the reset allowlist" do
    summary = WebhookPayload.safe_evidence_summary(saved_reset_evidence())

    assert summary == %{
             "available_count" => 2,
             "impacted_pool_count" => 2,
             "path_style" => "codex",
             "reason_code" => "saved_reset_banked_first_seen",
             "reset_expires_at" => "2026-07-03T09:00:00Z",
             "reset_first_seen_at" => "2026-07-02T08:00:00Z",
             "source" => "persisted_saved_resets"
           }

    encoded = Jason.encode!(summary)
    refute encoded =~ "provider-credit-hidden"
    refute encoded =~ "provider payload sentinel"
    refute encoded =~ "raw-auth-json-hidden"
    refute encoded =~ "pool_upstream_assignment_id"
    refute encoded =~ "upstream_identity_id"
    refute encoded =~ "pool_id"
  end

  defp incident_fixture do
    %AlertIncident{
      id: Ecto.UUID.generate(),
      dedupe_key: "alert:webhook:payload",
      scope_type: "pool",
      rule_kind: "pool_no_usable_assignments",
      severity: "critical",
      state: "open",
      pool_id: Ecto.UUID.generate(),
      occurrence_count: 3,
      first_seen_at: ~U[2026-05-30 14:00:00Z],
      last_seen_at: ~U[2026-05-30 14:10:00Z],
      safe_evidence_snapshot: unsafe_evidence(),
      suppression_metadata: %{"prompt" => "raw prompt sentinel"}
    }
  end

  defp channel_fixture do
    %AlertChannel{
      id: Ecto.UUID.generate(),
      channel_type: "webhook",
      display_name: "Payload webhook",
      state: "active",
      endpoint_scheme: "https",
      endpoint_host: "hooks.example.com",
      endpoint_path_prefix: "/aler.../****",
      endpoint_fingerprint: "sha256:masked",
      webhook_signing_secret_key_version: "v1",
      metadata: %{}
    }
  end

  defp attempt_fixture(channel_id, incident_id) do
    %AlertDeliveryAttempt{
      id: Ecto.UUID.generate(),
      incident_id: incident_id,
      channel_id: channel_id,
      attempt_number: 2,
      max_attempts: 5,
      status: "pending",
      scheduled_at: ~U[2026-05-30 14:11:00Z],
      attempted_at: ~U[2026-05-30 14:11:00Z],
      retryable: false,
      response_metadata: %{},
      failure_metadata: %{}
    }
  end

  defp unsafe_evidence do
    %{
      "reason_code" => "no_usable_assignments",
      "assignment_count" => 0,
      "model" => "gpt-5.5",
      "quota_state" => "exhausted",
      "status" => "active",
      "threshold_used_percent" => Decimal.new("97.5"),
      "used_percent" => 98.25,
      "window_selector" => "weekly",
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
      "webhook_signing_secret" => "whsec_payload_hidden",
      "endpoint_url" => "https://hooks.example.com/alerts/team?token=query-hidden",
      "file_body" => "file body sentinel",
      "websocket_frame" => "websocket frame sentinel",
      "idempotency_key" => "raw idempotency key sentinel",
      "safe_to_ignore" => "not in allowlist",
      "enabled_assignment_count" => %{"nested" => "unsupported"},
      "routing_usable" => [true],
      "target_state" => String.duplicate("a", 121)
    }
  end

  defp saved_reset_evidence do
    %{
      "reason_code" => "saved_reset_banked_first_seen",
      "reset_expires_at" => "2026-07-03T09:00:00Z",
      "reset_first_seen_at" => "2026-07-02T08:00:00Z",
      "available_count" => 2,
      "source" => "persisted_saved_resets",
      "path_style" => "codex",
      "impacted_pool_count" => 2,
      "pool_id" => Ecto.UUID.generate(),
      "upstream_identity_id" => Ecto.UUID.generate(),
      "pool_upstream_assignment_id" => Ecto.UUID.generate(),
      "provider_credit_id" => "provider-credit-hidden",
      "provider_payload" => "provider payload sentinel",
      "auth_json" => "raw-auth-json-hidden",
      "token" => "Bearer saved-reset-token",
      "request_body" => "raw request body sentinel"
    }
  end

  defp refute_forbidden_values(value) do
    encoded = to_string(value)

    for forbidden <- @raw_forbidden_values do
      refute encoded =~ forbidden
    end
  end
end
