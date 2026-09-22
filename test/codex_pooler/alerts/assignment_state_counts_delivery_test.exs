defmodule CodexPooler.Alerts.AssignmentStateCountsDeliveryTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Alerts.Delivery.{EmailDelivery, WebhookPayload}
  alias CodexPooler.Alerts.Schemas.{AlertChannel, AlertIncident}
  alias CodexPooler.Alerts.StatusVocabulary.AssignmentState

  # An incident caused by a model the Pool does not serve must say so in its
  # deliveries, not only through `model_membership_resolved=false`. Only the
  # bounded state vocabulary with positive integer counts is carried.
  @evidence %{
    "reason_code" => "no_usable_assignments",
    "model_membership_resolved" => false,
    "state_counts" => %{
      "model_not_served" => 2,
      "stale" => 1,
      "raw prompt sentinel" => 3,
      "exhausted" => "many",
      "usable" => 0
    }
  }

  test "the webhook summary carries bounded state counts" do
    summary = WebhookPayload.safe_evidence_summary(@evidence)

    assert summary["state_counts"] == %{"model_not_served" => 2, "stale" => 1}
    refute CodexPooler.JSON.encode!(summary) =~ "sentinel"
  end

  test "a summary without known state counts omits the key" do
    refute Map.has_key?(WebhookPayload.safe_evidence_summary(%{"state_counts" => %{"prompt" => 1}}), "state_counts")
    refute Map.has_key?(WebhookPayload.safe_evidence_summary(%{"state_counts" => "model_not_served"}), "state_counts")
  end

  test "the email body names the assignment states in words" do
    email = EmailDelivery.alert_email(incident(), %AlertChannel{id: Ecto.UUID.generate(), channel_type: "email", display_name: "Example channel", email_to: "ops@example.com"})

    assert email.text_body =~ "- state_counts: 2 model not served, 1 quota stale"
    refute email.text_body =~ "sentinel"
  end

  test "the vocabulary describes counts in a stable order and drops unknown states" do
    assert AssignmentState.describe(%{"stale" => 1, "model_not_served" => 2, "unknown" => 5}) == "2 model not served, 1 quota stale"
    assert AssignmentState.describe(%{"unknown" => 5}) == nil
    assert "model_not_served" in AssignmentState.states()
  end

  defp incident do
    %AlertIncident{
      id: Ecto.UUID.generate(),
      dedupe_key: "alert:state-counts",
      scope_type: "pool",
      rule_kind: "pool_no_usable_assignments",
      severity: "critical",
      state: "open",
      pool_id: Ecto.UUID.generate(),
      occurrence_count: 1,
      first_seen_at: ~U[2026-09-23 10:00:00Z],
      last_seen_at: ~U[2026-09-23 10:05:00Z],
      safe_evidence_snapshot: @evidence,
      suppression_metadata: %{}
    }
  end
end
