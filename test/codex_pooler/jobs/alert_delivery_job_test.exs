defmodule CodexPooler.Jobs.AlertDeliveryJobTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Swoosh.TestAssertions

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.WebhookSigning

  alias CodexPooler.Alerts.Schemas.{
    AlertChannel,
    AlertDeliveryAttempt,
    AlertIncident,
    AlertIncidentTarget,
    AlertRule,
    AlertRuleChannel
  }

  alias CodexPooler.FakeUpstream
  alias CodexPooler.InstanceSettings.AppSecretCrypto
  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.AlertDeliveryWorker
  alias CodexPooler.Mailer
  alias CodexPooler.Repo

  @forbidden_arg_fragments ~w(
    prompt request_body response_body body bearer token access_token refresh_token authorization
    headers cookies cookie auth_json provider_payload webhook file websocket idempotency_key
  )

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

    on_exit(fn ->
      restore_env(:codex_pooler, Mailer, mailer_config)
    end)

    :ok
  end

  test "successful email delivery records a sent attempt with metadata-only content" do
    %{incident: incident, channel: channel} = alert_delivery_fixture()

    assert {:ok, job} =
             Jobs.enqueue_alert_delivery(incident, channel, trigger_kind: "incident_match")

    assert job.args["alert_incident_id"] == incident.id
    assert job.args["alert_channel_id"] == channel.id
    assert job.args["trigger_kind"] == "incident_match"
    assert_safe_job_args(job.args)

    assert :ok = perform_job(AlertDeliveryWorker, job.args)

    assert [attempt] = attempts_for(incident, channel)
    assert attempt.status == "sent"
    assert attempt.attempt_number == 1
    assert attempt.max_attempts == 5
    refute attempt.retryable
    assert attempt.failure_metadata == %{}
    assert attempt.failure_code == nil
    assert attempt.response_metadata["delivery_adapter"] == "email"
    assert attempt.response_metadata["incident_id"] == incident.id
    assert attempt.response_metadata["channel_id"] == channel.id
    assert attempt.response_metadata["rule_kind"] == "pool_no_usable_assignments"
    assert attempt.response_metadata["severity"] == "critical"
    assert attempt.response_metadata["reason_code"] == "no_usable_assignments"

    assert attempt.response_metadata["safe_evidence_summary"] == %{
             "assignment_count" => 0,
             "reason_code" => "no_usable_assignments"
           }

    assert_email_sent(fn email ->
      assert email.to == [{"", "alerts@example.com"}]
      assert email.subject == "Codex Pooler alert: critical: pool_no_usable_assignments"
      assert email.text_body =~ "Incident id: #{incident.id}"
      assert email.text_body =~ "Channel id: #{channel.id}"
      assert email.text_body =~ "Reason code: no_usable_assignments"
      assert email.text_body =~ "- assignment_count: 0"
      true
    end)
  end

  test "unconfigured mailer records a sanitized failed attempt without crashing" do
    %{incident: incident, channel: channel} = alert_delivery_fixture()
    Application.put_env(:codex_pooler, Mailer, [])

    assert :ok = perform_job(AlertDeliveryWorker, delivery_args(incident, channel))

    assert [attempt] = attempts_for(incident, channel)
    assert attempt.status == "failed"
    refute attempt.retryable
    assert attempt.failure_code == "alert_email_mailer_unconfigured"
    assert attempt.failure_message == "email delivery is not configured"

    assert attempt.failure_metadata == %{
             "delivery_adapter" => "email",
             "failure_code" => "alert_email_mailer_unconfigured",
             "failure_message" => "email delivery is not configured",
             "retryable" => false
           }

    assert_no_email_sent()
  end

  test "disabled email channel records a discarded attempt without sending" do
    %{incident: incident, channel: channel} = alert_delivery_fixture(channel_state: "disabled")

    assert :ok = perform_job(AlertDeliveryWorker, delivery_args(incident, channel))

    assert [attempt] = attempts_for(incident, channel)
    assert attempt.status == "discarded"
    refute attempt.retryable
    assert attempt.failure_code == "alert_channel_disabled"
    assert attempt.failure_message == "alert channel is disabled"
    assert_no_email_sent()
  end

  test "recent sent attempts suppress repeated incident-channel delivery during cooldown" do
    %{incident: incident, channel: channel} = alert_delivery_fixture(rule_cooldown_minutes: 30)
    args = delivery_args(incident, channel)

    assert :ok = perform_job(AlertDeliveryWorker, args)

    assert :ok = AlertDeliveryWorker.perform(%Oban.Job{args: args, attempt: 2})

    assert [sent_attempt, suppressed_attempt] = attempts_for(incident, channel)
    assert sent_attempt.status == "sent"
    assert suppressed_attempt.status == "discarded"
    assert suppressed_attempt.attempt_number == 2
    assert suppressed_attempt.failure_code == "alert_delivery_cooldown_suppressed"
  end

  test "post-cooldown recurrence records the next persisted attempt number" do
    %{incident: incident, channel: channel} = alert_delivery_fixture(rule_cooldown_minutes: 5)
    args = delivery_args(incident, channel)

    assert :ok = perform_job(AlertDeliveryWorker, args)

    stale_completed_at =
      DateTime.add(DateTime.utc_now(), -10, :minute) |> DateTime.truncate(:microsecond)

    from(attempt in AlertDeliveryAttempt, where: attempt.incident_id == ^incident.id)
    |> Repo.update_all(set: [attempted_at: stale_completed_at, completed_at: stale_completed_at])

    assert :ok = AlertDeliveryWorker.perform(%Oban.Job{args: args, attempt: 1})

    assert [first_attempt, recurrence_attempt] = attempts_for(incident, channel)
    assert first_attempt.status == "sent"
    assert first_attempt.attempt_number == 1
    assert recurrence_attempt.status == "sent"
    assert recurrence_attempt.attempt_number == 2
  end

  test "successful webhook delivery records one signed metadata-only attempt" do
    signing_secret = "whsec_delivery_success"
    fake = start_fake_upstream(FakeUpstream.json_response(%{"ok" => true}, 202))
    endpoint_url = FakeUpstream.url(fake) <> "/alerts/team?token=query-hidden"

    %{incident: incident, channel: channel} =
      alert_delivery_fixture(
        channel_type: :webhook,
        endpoint_url: endpoint_url,
        signing_secret: signing_secret
      )

    assert {:ok, job} =
             Jobs.enqueue_alert_delivery(incident, channel, trigger_kind: "incident_match")

    assert_safe_job_args(job.args)

    assert :ok = perform_job(AlertDeliveryWorker, job.args)

    assert [request] = FakeUpstream.requests(fake)
    assert request.method == "POST"
    assert request.path == "/alerts/team"
    assert request.query_string == "token=query-hidden"

    assert [attempt] = attempts_for(incident, channel)
    assert attempt.status == "sent"
    refute attempt.retryable
    assert attempt.response_status_code == 202
    assert attempt.failure_metadata == %{}
    assert attempt.response_metadata["delivery_adapter"] == "webhook"
    assert attempt.response_metadata["incident_id"] == incident.id
    assert attempt.response_metadata["channel_id"] == channel.id
    assert attempt.response_metadata["endpoint_path_prefix"] == "/aler.../****"
    assert attempt.response_metadata["payload_bytes"] == byte_size(request.body)

    assert event_id = header(request, "x-codex-pooler-event-id")
    assert attempt_id = header(request, "x-codex-pooler-attempt-id")
    assert signature = header(request, "x-codex-pooler-signature")
    assert attempt_id == attempt.id
    assert event_id == attempt.response_metadata["event_id"]
    assert WebhookSigning.verify?(event_id, attempt_id, request.body, signing_secret, signature)

    assert request.json["event_id"] == event_id
    assert request.json["attempt_id"] == attempt.id
    assert request.json["incident_id"] == incident.id
    assert request.json["channel_id"] == channel.id
    assert request.json["severity"] == "critical"
    assert request.json["reason_code"] == "no_usable_assignments"

    assert request.json["scope_metadata"] == %{
             "pool_id" => incident.pool_id,
             "scope_type" => "pool"
           }

    assert request.json["safe_evidence_summary"] == %{
             "assignment_count" => 0,
             "reason_code" => "no_usable_assignments"
           }

    encoded =
      Jason.encode!(%{
        payload: request.json,
        response_metadata: attempt.response_metadata,
        failure_metadata: attempt.failure_metadata
      })

    refute encoded =~ signing_secret
    refute encoded =~ "query-hidden"
    refute encoded =~ endpoint_url
    refute encoded =~ "raw prompt sentinel"
    refute encoded =~ "raw request body sentinel"
    refute encoded =~ "Bearer raw-token-sentinel"
  end

  test "webhook retryable HTTP statuses record retryable failed attempts" do
    for status <- [409, 425, 500, 507] do
      fake = start_fake_upstream(FakeUpstream.json_response(%{"error" => "retryable"}, status))
      endpoint_url = FakeUpstream.url(fake) <> "/alerts/retry-#{status}"
      expected_code = "alert_webhook_http_#{status}"

      %{incident: incident, channel: channel} =
        alert_delivery_fixture(
          channel_type: :webhook,
          endpoint_url: endpoint_url,
          signing_secret: "whsec_delivery_retry_#{status}"
        )

      assert {:error, %{code: ^expected_code, retryable: true}} =
               perform_job(AlertDeliveryWorker, delivery_args(incident, channel))

      assert [request] = FakeUpstream.requests(fake)
      assert request.path == "/alerts/retry-#{status}"

      assert [attempt] = attempts_for(incident, channel)
      assert attempt.status == "retryable"
      assert attempt.retryable
      assert attempt.attempt_number == 1
      assert attempt.response_status_code == status
      assert attempt.next_retry_at
      assert attempt.failure_code == expected_code
      assert attempt.failure_message == "webhook endpoint returned a retryable failure"
      assert attempt.failure_metadata["retryable"] == true
    end
  end

  test "webhook permanent HTTP 422 records a terminal failed attempt" do
    fake = start_fake_upstream(FakeUpstream.json_response(%{"error" => "invalid"}, 422))
    endpoint_url = FakeUpstream.url(fake) <> "/alerts/permanent"

    %{incident: incident, channel: channel} =
      alert_delivery_fixture(
        channel_type: :webhook,
        endpoint_url: endpoint_url,
        signing_secret: "whsec_delivery_terminal"
      )

    assert :ok = perform_job(AlertDeliveryWorker, delivery_args(incident, channel))

    assert [request] = FakeUpstream.requests(fake)
    assert request.path == "/alerts/permanent"

    assert [attempt] = attempts_for(incident, channel)
    assert attempt.status == "failed"
    refute attempt.retryable
    assert attempt.response_status_code == 422
    assert attempt.next_retry_at == nil
    assert attempt.failure_code == "alert_webhook_http_422"
    assert attempt.failure_message == "webhook endpoint rejected the alert notification"
    assert attempt.failure_metadata["retryable"] == false
  end

  defp alert_delivery_fixture(opts \\ []) do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner, ["instance_owner"])
    channel_type = Keyword.get(opts, :channel_type, :email)

    pool =
      pool_fixture(%{
        slug: "alert-#{channel_type}-#{unique_suffix()}",
        name: "Alert Delivery Pool"
      })

    channel = delivery_channel_fixture(scope, opts)

    assert {:ok, rule} =
             Alerts.create_rule(scope, %{
               pool_id: pool.id,
               scope_type: "pool",
               rule_kind: "pool_no_usable_assignments",
               display_name: "Pool usable assignment coverage",
               severity: "critical",
               cooldown_minutes: Keyword.get(opts, :rule_cooldown_minutes, 30),
               state: "active",
               metadata: %{},
               channel_ids: [channel.id]
             })

    assert {:ok, incident} =
             Alerts.record_incident_match(%{
               dedupe_key: "alert:#{channel_type}:#{unique_suffix()}",
               scope_type: "pool",
               rule_kind: rule.rule_kind,
               severity: rule.severity,
               pool_id: pool.id,
               matched_at: timestamp(~U[2026-05-30 14:00:00Z]),
               safe_evidence_snapshot: %{
                 "reason_code" => "no_usable_assignments",
                 "assignment_count" => 0
               },
               targets: [
                 %{rule_id: rule.id, pool_id: pool.id, metadata: %{}}
               ]
             })

    %{pool: pool, rule: rule, channel: channel, incident: incident}
  end

  defp delivery_channel_fixture(scope, opts) do
    case Keyword.get(opts, :channel_type, :email) do
      :email ->
        assert {:ok, channel} =
                 Alerts.create_channel(scope, %{
                   channel_type: "email",
                   display_name: "Operations email",
                   state: Keyword.get(opts, :channel_state, "active"),
                   email_to: "alerts@example.com",
                   metadata: %{}
                 })

        channel

      :webhook ->
        webhook_channel_fixture(scope, opts)
    end
  end

  defp webhook_channel_fixture(scope, opts) do
    endpoint_url = Keyword.fetch!(opts, :endpoint_url)
    signing_secret = Keyword.fetch!(opts, :signing_secret)
    endpoint_encrypted = encrypt_secret!(endpoint_url, "alert_webhook_endpoint_url")
    signing_encrypted = encrypt_secret!(signing_secret, "alert_webhook_signing_secret")
    uri = URI.parse(endpoint_url)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %AlertChannel{
      channel_type: "webhook",
      display_name: "Operations webhook",
      state: Keyword.get(opts, :channel_state, "active"),
      endpoint_scheme: uri.scheme,
      endpoint_host: endpoint_host(uri),
      endpoint_path_prefix: masked_path_prefix(uri.path || "/"),
      endpoint_fingerprint: AppSecretCrypto.safe_fingerprint(endpoint_url),
      endpoint_url_ciphertext: endpoint_encrypted.ciphertext,
      endpoint_url_nonce: endpoint_encrypted.nonce,
      endpoint_url_aad: endpoint_encrypted.aad,
      endpoint_url_key_version: endpoint_encrypted.key_version,
      webhook_signing_secret_ciphertext: signing_encrypted.ciphertext,
      webhook_signing_secret_nonce: signing_encrypted.nonce,
      webhook_signing_secret_aad: signing_encrypted.aad,
      webhook_signing_secret_key_version: signing_encrypted.key_version,
      created_by_user_id: scope.user.id,
      metadata: %{},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp delivery_args(incident, channel) do
    %{"alert_incident_id" => incident.id, "alert_channel_id" => channel.id}
  end

  defp attempts_for(incident, channel) do
    Repo.all(
      from attempt in AlertDeliveryAttempt,
        where: attempt.incident_id == ^incident.id and attempt.channel_id == ^channel.id,
        order_by: [asc: attempt.attempt_number]
    )
  end

  defp assert_safe_job_args(args) do
    assert Map.keys(args) |> Enum.all?(&is_binary/1)
    encoded_args = Jason.encode!(args)

    for fragment <- @forbidden_arg_fragments do
      refute encoded_args =~ fragment
    end
  end

  defp start_fake_upstream(mode) do
    {:ok, fake} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(fake) end)
    fake
  end

  defp encrypt_secret!(value, kind) do
    assert {:ok, encrypted} = AppSecretCrypto.encrypt(value, kind)
    encrypted
  end

  defp header(request, key) do
    Enum.find_value(request.headers, fn {header_key, value} ->
      if header_key == key, do: value
    end)
  end

  defp endpoint_host(%URI{host: host, port: nil}), do: host
  defp endpoint_host(%URI{host: host, port: port}), do: "#{host}:#{port}"

  defp masked_path_prefix("/"), do: "/"

  defp masked_path_prefix(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.take(2)
    |> Enum.map(&mask_segment/1)
    |> then(fn segments -> "/" <> Enum.join(segments, "/") end)
  end

  defp mask_segment(segment) when byte_size(segment) <= 4,
    do: String.duplicate("*", byte_size(segment))

  defp mask_segment(segment), do: String.slice(segment, 0, 4) <> "..."

  defp timestamp(value), do: %{value | microsecond: {0, 6}}
  defp unique_suffix, do: System.unique_integer([:positive])
  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
