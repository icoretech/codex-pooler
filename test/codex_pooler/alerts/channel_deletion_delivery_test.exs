defmodule CodexPooler.Alerts.ChannelDeletionDeliveryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Swoosh.TestAssertions

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Delivery.{AttemptLifecycle, EmailDelivery, Execution, PendingRecovery, WebhookDelivery}
  alias CodexPooler.Alerts.Schemas.{AlertChannel, AlertDeliveryAttempt}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.AlertDeliveryWorker
  alias CodexPooler.Mailer
  alias CodexPooler.TestAppEnv
  alias CodexPooler.WebhookDestinationFixture
  alias Oban.Engines.Basic

  setup do
    TestAppEnv.restore_on_exit(Mailer)
    Application.put_env(:codex_pooler, Mailer, adapter: Swoosh.Adapters.Test)
    %{user: owner} = bootstrap_owner_fixture()
    %{scope: Scope.for_user(owner)}
  end

  for adapter <- ["email", "webhook"] do
    test "deleting #{adapter} cancels queued work, settles open receipts and preserves history", %{scope: scope} do
      assert_deleted_delivery(scope, unquote(adapter))
    end

    test "detached retryable #{adapter} receipts from earlier deletions converge in recovery", %{scope: scope} do
      assert_legacy_retry_recovered(scope, unquote(adapter))
    end
  end

  test "a claimed email delivery still sends the next receipt while its channel exists", %{scope: scope} do
    {incident, channel} = fixture!(scope, "email")
    retryable = retryable_attempt!(incident, channel, 1)
    job = claim_job!(incident, channel)

    assert :ok = AlertDeliveryWorker.perform(job)
    assert [old, sent] = attempts_for(incident)
    assert old == retryable
    assert sent.status == "sent"
    assert sent.attempt_number == 2
    assert sent.response_metadata["delivery_execution"]["job_id"] == job.id
    assert_email_sent(fn email -> email.to == [{"", "alerts@example.com"}] end)
  end

  test "a claimed webhook delivery still reaches a real HTTPS receiver while its channel exists", %{scope: scope} do
    tls = WebhookDestinationFixture.setup!()
    receiver = WebhookDestinationFixture.start_fake!({:path_json, %{"/alerts" => {202, %{}}}}, tls)
    {incident, channel} = fixture!(scope, "webhook", FakeUpstream.url(receiver) <> "/alerts")
    retryable = retryable_attempt!(incident, channel, 1)
    job = claim_job!(incident, channel)

    assert :ok = AlertDeliveryWorker.perform(job)
    assert [old, sent] = attempts_for(incident)
    assert old == retryable
    assert sent.status == "sent"
    assert sent.attempt_number == 2
    assert sent.response_status_code == 202
    assert sent.response_metadata["delivery_execution"]["job_id"] == job.id
    assert [%{method: "POST", path: "/alerts"}] = FakeUpstream.requests(receiver)
  end

  test "stale and unauthorized deletes leave the channel receipts and queued jobs untouched", %{scope: scope} do
    {incident, channel} = fixture!(scope, "email")
    retryable = retryable_attempt!(incident, channel, 1)
    {:ok, job} = Jobs.enqueue_alert_delivery(incident, channel)
    job = Repo.get!(Oban.Job, job.id)
    %{user: admin} = operator_fixture(scope, %{"role" => "instance_admin"})

    assert {:error, %{code: :channel_not_found}} = Alerts.delete_channel(Scope.for_user(admin), channel.id)
    assert {:error, %{code: :stale_update}} = Alerts.delete_channel(scope, channel.id, expected_updated_at: nil)
    assert Repo.get!(AlertChannel, channel.id) == channel
    assert Repo.get!(AlertDeliveryAttempt, retryable.id) == retryable
    assert Repo.get!(Oban.Job, job.id) == job
  end

  test "stale channel snapshots cannot register or insert a replacement receipt after deletion", %{scope: scope} do
    {incident, channel} = fixture!(scope, "email")
    job = claim_job!(incident, channel)
    assert {:ok, _} = Alerts.delete_channel(scope, channel.id)
    now = DateTime.utc_now()
    expected = {:error, %{code: "alert_delivery_channel_deleted", retryable: false}}

    assert ^expected = AttemptLifecycle.insert_pending_attempt(incident, channel, 1, now, %{}, Execution.new(job))
    assert ^expected = AttemptLifecycle.insert_sent_attempt(incident, channel, 1, now, %{})
    assert ^expected = AttemptLifecycle.record_failed_attempt(incident.id, channel.id, 1, now, "email", "synthetic_failure", "delivery unavailable", retryable: true)
    assert attempts_for(incident) == []
  end

  test "receipt foreign keys return changeset errors instead of raw constraint exceptions", %{scope: scope} do
    {incident, channel} = fixture!(scope, "email")
    assert {:ok, _} = Alerts.delete_channel(scope, channel.id)
    now = DateTime.utc_now()
    attrs = %{incident_id: incident.id, channel_id: channel.id, attempt_number: 1, status: "pending", scheduled_at: now, retryable: false, response_metadata: %{}, failure_metadata: %{}, created_at: now, updated_at: now}

    assert {:error, changeset} = %AlertDeliveryAttempt{} |> AlertDeliveryAttempt.changeset(attrs) |> Repo.insert(mode: :savepoint)
    assert {"does not exist", metadata} = Keyword.fetch!(changeset.errors, :channel_id)
    assert metadata[:constraint] == :foreign
    assert metadata[:constraint_name] == "alert_delivery_attempts_channel_id_fkey"
    assert attempts_for(incident) == []
  end

  defp assert_deleted_delivery(scope, adapter) do
    {incident, channel} = fixture!(scope, adapter)
    retryable = retryable_attempt!(incident, channel, 1)
    old_time = DateTime.add(DateTime.utc_now(), -3600, :second)
    assert {:ok, sent} = AttemptLifecycle.insert_sent_attempt(incident, channel, 2, old_time, %{"delivery_adapter" => adapter, "delivery_status" => "sent"})
    sent = Repo.get!(AlertDeliveryAttempt, sent.id)
    job = claim_job!(incident, channel)
    assert {:ok, pending} = AttemptLifecycle.insert_pending_attempt(incident, channel, 3, DateTime.utc_now(), %{"delivery_adapter" => adapter}, Execution.new(job))
    assert {:ok, failed} = AttemptLifecycle.record_failed_attempt(incident.id, channel.id, 4, old_time, adapter, "synthetic_permanent_failure", "delivery permanently unavailable")
    failed = Repo.get!(AlertDeliveryAttempt, failed.id)

    queued =
      for state <- ~w(available scheduled retryable suspended completed cancelled discarded) do
        queue = "channel_delete_#{state}_#{System.unique_integer([:positive])}"
        queued = enqueue_in_queue!(incident, channel, queue)
        queued |> change(state: state) |> Repo.update!()
        Repo.get!(Oban.Job, queued.id)
      end

    other_channel = alert_channel_fixture(created_by_user_id: scope.user.id)
    other_receipt = retryable_attempt!(incident, other_channel, 1)
    assert {:ok, other_job} = Jobs.enqueue_alert_delivery(incident, other_channel)
    other_job = Repo.get!(Oban.Job, other_job.id)
    assert {:ok, _} = Alerts.delete_channel(scope, channel.id)
    refute Repo.get(AlertChannel, channel.id)

    for receipt <- [retryable, pending] do
      retained = Repo.get!(AlertDeliveryAttempt, receipt.id)
      assert retained.channel_id == nil
      assert retained.status == "failed"
      refute retained.retryable
      assert retained.next_retry_at == nil
      assert retained.failure_code == "alert_delivery_channel_deleted"
      assert retained.failure_message == "alert channel was deleted before delivery completed"
      assert retained.failure_metadata["delivery_adapter"] == adapter
      assert retained.response_metadata == receipt.response_metadata
      assert retained.channel_created_by_user_id == scope.user.id
      assert retained.channel_display_name == channel.display_name
      assert retained.channel_type == adapter
      assert %DateTime{} = retained.channel_deleted_at
      assert %DateTime{} = retained.completed_at
    end

    for receipt <- [sent, failed] do
      retained = Repo.get!(AlertDeliveryAttempt, receipt.id)
      assert Map.drop(Map.from_struct(retained), [:channel_id, :channel_deleted_at, :updated_at]) == Map.drop(Map.from_struct(receipt), [:channel_id, :channel_deleted_at, :updated_at])
      assert retained.channel_id == nil
      assert %DateTime{} = retained.channel_deleted_at
    end

    assert {:error, %{code: "alert_delivery_execution_superseded"}} = AttemptLifecycle.mark_sent_attempt(pending, DateTime.utc_now(), %{})
    assert {:error, %{code: "alert_delivery_execution_superseded"}} = AttemptLifecycle.finalize_failed_attempt(pending, DateTime.utc_now(), adapter, "synthetic_late_failure", "late delivery failure", retryable: true, next_retry_at: DateTime.add(DateTime.utc_now(), 60, :second))
    assert Repo.get!(AlertDeliveryAttempt, pending.id).failure_code == "alert_delivery_channel_deleted"
    assert Repo.get!(AlertDeliveryAttempt, pending.id).next_retry_at == nil

    for queued_job <- queued do
      persisted = Repo.get!(Oban.Job, queued_job.id)

      if queued_job.state in ~w(available scheduled retryable suspended) do
        assert persisted.state == "cancelled"
        assert %DateTime{} = persisted.cancelled_at
      else
        assert persisted == queued_job
      end
    end

    assert Repo.get!(Oban.Job, job.id).state == "executing"

    for attempt <- 1..5 do
      assert {:cancel, %{code: "alert_delivery_channel_deleted"}} = AlertDeliveryWorker.perform(%{job | attempt: attempt})
    end

    delivery = if adapter == "email", do: EmailDelivery, else: WebhookDelivery
    assert {:error, %{code: "alert_delivery_channel_deleted", retryable: false}} = delivery.deliver_incident_to_channel(incident.id, channel.id, 5)
    assert Repo.get!(Oban.Job, other_job.id) == other_job
    assert Repo.get!(AlertDeliveryAttempt, other_receipt.id) == other_receipt
    assert {:ok, %{alert_deliveries_recovered: 0}} = PendingRecovery.recover()
    assert length(attempts_for(incident)) == 5
    assert_no_email_sent()
  end

  defp assert_legacy_retry_recovered(scope, adapter) do
    {incident, channel} = fixture!(scope, adapter)
    retryable = retryable_attempt!(incident, channel, 1)
    job = claim_job!(incident, channel)
    old = DateTime.add(DateTime.utc_now(), -60, :second)
    Repo.update!(change(retryable, created_at: old))
    # The database retention action predates context-level settlement and left
    # these detached rows behind without a usable execution binding.
    Repo.delete!(channel)

    assert {:ok, %{alert_deliveries_recovered: 1, alert_delivery_recovery_errors: 0}} = PendingRecovery.recover()
    recovered = Repo.get!(AlertDeliveryAttempt, retryable.id)
    assert recovered.status == "failed"
    refute recovered.retryable
    assert recovered.next_retry_at == nil
    assert recovered.channel_id == nil
    assert recovered.failure_code == "alert_delivery_channel_deleted"
    assert recovered.failure_metadata["delivery_adapter"] == adapter
    assert recovered.response_metadata["delivery_recovery"]["reason"] == "channel_deleted"
    assert {:ok, :unchanged} = PendingRecovery.recover_one(recovered, DateTime.utc_now())
    assert {:cancel, %{code: "alert_delivery_channel_deleted"}} = AlertDeliveryWorker.perform(job)
  end

  defp fixture!(scope, adapter, endpoint_url \\ "https://hooks.example.com/alerts") do
    pool = pool_fixture()
    incident = alert_incident_fixture(pool: pool)
    attrs = %{channel_type: adapter, display_name: "Deletion #{adapter} #{System.unique_integer([:positive])}"}
    attrs = if adapter == "email", do: Map.put(attrs, :email_to, "alerts@example.com"), else: Map.merge(attrs, %{endpoint_url: endpoint_url, webhook_signing_secret: "synthetic-deletion-signing-secret"})
    assert {:ok, created} = Alerts.create_channel(scope, attrs)
    {incident, Repo.get!(AlertChannel, created.id)}
  end

  defp retryable_attempt!(incident, channel, number) do
    now = DateTime.utc_now()
    assert {:error, %{retryable: true, attempt_id: id}} = AttemptLifecycle.record_failed_attempt(incident.id, channel.id, number, now, channel.channel_type, "synthetic_retryable_failure", "delivery temporarily unavailable", retryable: true, next_retry_at: DateTime.add(now, -120, :second))
    Repo.get!(AlertDeliveryAttempt, id)
  end

  defp claim_job!(incident, channel) do
    queue = "channel_delete_claim_#{System.unique_integer([:positive])}"
    job = enqueue_in_queue!(incident, channel, queue)
    conf = Oban.config()
    assert {:ok, meta} = Basic.init(conf, queue: queue, limit: 1)
    assert {:ok, {_meta, [claimed]}} = Basic.fetch_jobs(conf, meta, %{})
    assert claimed.id == job.id
    claimed
  end

  defp enqueue_in_queue!(incident, channel, queue) do
    assert {:ok, job} = Jobs.enqueue_alert_delivery(incident, channel)
    refute job.conflict?
    job |> change(queue: queue) |> Repo.update!()
    Repo.get!(Oban.Job, job.id)
  end

  defp attempts_for(incident) do
    Repo.all(from attempt in AlertDeliveryAttempt, where: attempt.incident_id == ^incident.id, order_by: [asc: attempt.attempt_number, asc: attempt.id])
  end
end
