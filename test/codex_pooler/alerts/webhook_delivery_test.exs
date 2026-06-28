defmodule CodexPooler.Alerts.WebhookDeliveryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.{AlertChannel, AlertDeliveryAttempt, AlertRuleChannel}
  alias CodexPooler.Alerts.WebhookDelivery
  alias CodexPooler.Repo

  setup do
    Repo.delete_all(AlertDeliveryAttempt)
    Repo.delete_all(AlertRuleChannel)
    %{user: user} = bootstrap_owner_fixture()
    {:ok, scope: Scope.for_user(user, ["instance_owner"])}
  end

  test "delivery exceptions after pending attempt insertion finalize that attempt", %{
    scope: scope
  } do
    pool = pool_fixture(%{slug: "webhook-pending-exception-#{unique_suffix()}"})
    channel = webhook_channel!(scope)
    incident = linked_incident!(pool, channel)

    channel
    |> Ecto.Changeset.change(webhook_signing_secret_nonce: <<>>)
    |> Repo.update!()

    assert {:ok, attempt} =
             WebhookDelivery.deliver_incident_to_channel(incident.id, channel.id, 1)

    assert attempt.status == "failed"
    assert attempt.failure_code == "alert_webhook_delivery_exception"
    assert attempt.failure_message == "ErlangError raised during alert webhook delivery"
    assert attempt.completed_at
    assert attempt.retryable == false

    assert [persisted] = Repo.all(AlertDeliveryAttempt)
    assert persisted.id == attempt.id
    assert persisted.status == "failed"
    assert persisted.failure_metadata["failure_code"] == "alert_webhook_delivery_exception"
    assert persisted.response_metadata["delivery_adapter"] == "webhook"
    refute inspect(persisted) =~ "whsec_exception_boundary"
  end

  test "delivery exceptions before pending attempt insertion record a failed attempt", %{
    scope: scope
  } do
    pool = pool_fixture(%{slug: "webhook-pre-pending-exception-#{unique_suffix()}"})
    channel = webhook_channel!(scope)
    incident = linked_incident!(pool, channel)

    channel
    |> Ecto.Changeset.change(endpoint_url_nonce: <<>>)
    |> Repo.update!()

    assert {:ok, attempt} =
             WebhookDelivery.deliver_incident_to_channel(incident.id, channel.id, 1)

    assert attempt.status == "failed"
    assert attempt.failure_code == "alert_webhook_delivery_exception"
    assert attempt.failure_message == "ErlangError raised during alert webhook delivery"
    assert attempt.completed_at
    assert attempt.retryable == false

    assert [persisted] = Repo.all(AlertDeliveryAttempt)
    assert persisted.id == attempt.id
    assert persisted.failure_metadata["failure_code"] == "alert_webhook_delivery_exception"
    assert persisted.response_metadata == %{"delivery_adapter" => "webhook"}
    refute inspect(persisted) =~ "https://alerts.example.com"
  end

  defp webhook_channel!(scope) do
    {:ok, channel} =
      Alerts.create_channel(scope, %{
        channel_type: "webhook",
        display_name: "Exception boundary webhook #{unique_suffix()}",
        endpoint_url: "https://alerts.example.com/hooks/#{unique_suffix()}?api_key=hidden",
        webhook_signing_secret: "whsec_exception_boundary_#{unique_suffix()}",
        webhook_signing_secret_action: "preserve"
      })

    Repo.get!(AlertChannel, channel.id)
  end

  defp linked_incident!(pool, channel) do
    rule = alert_rule_fixture(pool, cooldown_minutes: 30)
    link_rule_channel!(rule, channel)

    incident =
      alert_incident_fixture(
        pool: pool,
        dedupe_key: "alert:webhook:exception:#{unique_suffix()}",
        safe_evidence_snapshot: %{
          "reason_code" => "no_usable_assignments",
          "assignment_count" => 0
        }
      )

    alert_incident_target_fixture(incident, rule, pool)
    incident
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

  defp unique_suffix, do: System.unique_integer([:positive])
end
