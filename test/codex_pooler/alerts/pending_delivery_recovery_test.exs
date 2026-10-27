defmodule CodexPooler.Alerts.PendingDeliveryRecoveryTest do
  use CodexPooler.DataCase, async: false
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.AlertIncidentRelationships
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Delivery.{AttemptLifecycle, Execution, PendingRecovery}
  alias CodexPooler.Alerts.Schemas.AlertDeliveryAttempt
  alias CodexPooler.Jobs.AlertDeliveryWorker
  alias CodexPooler.Jobs.RuntimeStateCleanup
  alias Ecto.Adapters.SQL
  alias Oban.Engines.Basic

  test "pending detached attempts converge to a bounded channel-deleted failure" do
    {_incident, _channel, job, pending} = fixture!()
    now = DateTime.utc_now()

    pending
    |> Ecto.Changeset.change(channel_id: nil, channel_deleted_at: now)
    |> Repo.update!()

    assert {:ok, recovered} = PendingRecovery.recover_one(Repo.get!(AlertDeliveryAttempt, pending.id), now)
    assert recovered.status == "failed"
    refute recovered.retryable
    assert recovered.failure_code == "alert_delivery_channel_deleted"
    assert recovered.failure_message == "alert channel was deleted before delivery completed"
    assert job.state == "executing"
  end

  test "real channel deletion terminalizes malformed and pruned email and webhook receipts" do
    for adapter <- ["email", "webhook"] do
      for kind <- [:claimed, :unlinked, :malformed, :pruned] do
        %{user: owner} = bootstrap_owner_fixture()
        {incident, channel, job, pending} = fixture!(%{"delivery_adapter" => adapter})
        channel = Repo.update!(Ecto.Changeset.change(channel, created_by_user_id: owner.id))
        assert {:ok, _deleted} = Alerts.delete_channel(Scope.for_user(owner), channel.id)

        metadata =
          case kind do
            :claimed -> pending.response_metadata
            :unlinked -> %{"delivery_adapter" => adapter}
            :malformed -> %{"delivery_adapter" => adapter, "delivery_execution" => %{"job_id" => "invalid"}}
            :pruned -> pending.response_metadata
          end

        pending
        |> Ecto.Changeset.change(response_metadata: metadata, created_at: DateTime.add(DateTime.utc_now(), -60))
        |> Repo.update!()

        if kind in [:unlinked, :malformed, :pruned], do: Repo.delete!(job)

        detached = Repo.get!(AlertDeliveryAttempt, pending.id)
        assert detached.channel_id == nil
        assert {:ok, recovered} = PendingRecovery.recover_one(detached, DateTime.utc_now())
        assert recovered.status == "failed"
        assert recovered.failure_code == "alert_delivery_channel_deleted"
        assert recovered.failure_metadata["delivery_adapter"] == adapter
        assert {:ok, :unchanged} = PendingRecovery.recover_one(recovered, DateTime.utc_now())
        assert {:error, %{code: "alert_delivery_execution_superseded"}} = AttemptLifecycle.mark_sent_attempt(detached, DateTime.utc_now(), %{})
        assert incident.id == recovered.incident_id
      end
    end
  end

  test "batch recovery converges detached email and webhook receipts" do
    for adapter <- ["email", "webhook"] do
      %{user: owner} = bootstrap_owner_fixture()
      {_incident, channel, _job, pending} = fixture!(%{"delivery_adapter" => adapter})
      channel = Repo.update!(Ecto.Changeset.change(channel, created_by_user_id: owner.id))
      assert {:ok, _deleted} = Alerts.delete_channel(Scope.for_user(owner), channel.id)
      pending |> Ecto.Changeset.change(created_at: DateTime.add(DateTime.utc_now(), -60)) |> Repo.update!()
    end

    assert {:ok, summary} = PendingRecovery.recover()
    assert summary.alert_deliveries_recovered >= 2
  end

  test "normal completion preserves provenance and stale callbacks cannot reopen a recovery winner" do
    {incident, channel, job, pending} = fixture!()
    binding = pending.response_metadata["delivery_execution"]
    assert {:ok, _} = job |> Ecto.Changeset.change(state: "retryable", scheduled_at: DateTime.add(DateTime.utc_now(), 60)) |> Repo.update()
    assert {:ok, recovered} = PendingRecovery.recover_one(pending, DateTime.utc_now())
    assert recovered.status == "retryable"
    assert recovered.response_metadata["delivery_execution"] == binding
    assert recovered.response_metadata["delivery_outcome"] == "unknown"
    assert {:error, %{code: "alert_delivery_execution_superseded"}} = AttemptLifecycle.mark_sent_attempt(pending, DateTime.utc_now(), %{})
    assert Repo.get!(AlertDeliveryAttempt, pending.id).status == "retryable"
    assert {:ok, :unchanged} = PendingRecovery.recover_one(pending, DateTime.utc_now())
    assert incident.id == pending.incident_id
    assert channel.id == pending.channel_id
  end

  test "matching executing job stays pending regardless of receipt age" do
    {_incident, _channel, _job, pending} = fixture!()
    old = DateTime.add(DateTime.utc_now(), -86_400)
    pending |> Ecto.Changeset.change(created_at: old) |> Repo.update!()
    assert {:ok, %{alert_deliveries_recovered: 0}} = PendingRecovery.recover()
    current = Repo.get!(AlertDeliveryAttempt, pending.id)
    refute Map.has_key?(current.response_metadata, "delivery_recovery")
    assert current.status == "pending"
    assert {:ok, sent} = AttemptLifecycle.mark_sent_attempt(pending, DateTime.utc_now(), %{"delivery_status" => "sent"})
    assert sent.status == "sent"
    assert sent.response_metadata["delivery_execution"] == pending.response_metadata["delivery_execution"]
  end

  test "legacy malformed missing and mismatched jobs remain unresolved attention without invented terminal states" do
    {_incident, _channel, job, pending} = fixture!()
    Repo.delete!(job)
    assert {:ok, unresolved} = PendingRecovery.recover_one(pending, DateTime.utc_now())
    assert unresolved.status == "pending"
    assert PendingRecovery.unresolved?(unresolved)

    for metadata <- [%{}, %{"delivery_execution" => %{"job_id" => "invalid"}}] do
      changed = unresolved |> Ecto.Changeset.change(response_metadata: metadata) |> Repo.update!()
      assert {:ok, result} = PendingRecovery.recover_one(changed, DateTime.utc_now())
      assert result.status == "pending"
      assert PendingRecovery.unresolved?(result)
    end
  end

  test "pending registration rejects a stale execution and cannot accept binding from metadata" do
    {incident, channel, job, pending} = fixture!()
    assert {:ok, _} = job |> Ecto.Changeset.change(attempt: job.attempt + 1) |> Repo.update()
    assert {:error, %{code: "alert_delivery_execution_superseded"}} = AttemptLifecycle.insert_pending_attempt(incident, channel, 2, DateTime.utc_now(), %{}, Execution.new(job))
    assert {:ok, unlinked} = AttemptLifecycle.insert_pending_attempt(incident, channel, 2, DateTime.utc_now(), %{"delivery_execution" => pending.response_metadata["delivery_execution"]})
    refute Map.has_key?(unlinked.response_metadata, "delivery_execution")
  end

  test "unresolved head rows rotate so a linked recoverable row beyond one batch is reached" do
    {incident, channel, job, pending} = fixture!()
    old = DateTime.add(DateTime.utc_now(), -60)

    for number <- 2..111 do
      assert {:ok, row} = AttemptLifecycle.insert_pending_attempt(incident, channel, number, old, %{})
      metadata = if rem(number, 2) == 0, do: %{"delivery_execution" => Map.put(pending.response_metadata["delivery_execution"], "job_id", 9_223_372_036_854_775_808)}, else: %{}
      row |> Ecto.Changeset.change(created_at: DateTime.add(old, -number), response_metadata: metadata) |> Repo.update!()
    end

    job |> Ecto.Changeset.change(state: "completed") |> Repo.update!()
    pending |> Ecto.Changeset.change(created_at: old) |> Repo.update!()
    assert {:ok, first} = PendingRecovery.recover()
    assert first.alert_deliveries_unresolved == 100
    assert {:ok, second} = PendingRecovery.recover()
    assert second.alert_deliveries_recovered == 1
    assert Repo.get!(AlertDeliveryAttempt, pending.id).status == "failed"
    plan = SQL.explain(Repo, :all, PendingRecovery.candidates(DateTime.utc_now()), analyze: true)
    assert is_binary(plan)
    assert plan =~ "Limit"
    CodexPooler.TestDiagnostics.puts("alert-recovery-plan " <> plan)
  end

  test "retry-start catchup recovers only the old generation and preserves current successor authority" do
    {incident, channel, job, old} = fixture!()
    job |> Ecto.Changeset.change(state: "available") |> Repo.update!()
    conf = Oban.config()
    {:ok, meta} = Basic.init(conf, queue: job.queue, limit: 1)
    {:ok, {_meta, [successor]}} = Basic.fetch_jobs(conf, meta, %{})
    assert successor.attempt == job.attempt + 1
    assert {:ok, current} = AttemptLifecycle.insert_pending_attempt(incident, channel, 2, DateTime.utc_now(), %{}, Execution.new(successor))
    assert {:error, %{code: "alert_delivery_execution_superseded"}} = AttemptLifecycle.finalize_failed_attempt(old, DateTime.utc_now(), "webhook", "late", "late", retryable: true)
    assert {:ok, %{alert_deliveries_recovered: 1}} = PendingRecovery.recover(job_id: job.id)
    assert Repo.get!(AlertDeliveryAttempt, current.id) == current
    assert Repo.get!(AlertDeliveryAttempt, old.id).status == "retryable"
    assert {:ok, sent} = AttemptLifecycle.mark_sent_attempt(current, DateTime.utc_now(), %{})
    assert sent.response_metadata["delivery_execution"]["job_attempt"] == 2
  end

  for state <- ["completed", "cancelled", "discarded"] do
    test "job #{state} cannot turn a pending receipt into sent" do
      {_incident, _channel, job, pending} = fixture!()
      job |> Ecto.Changeset.change(state: unquote(state)) |> Repo.update!()
      assert {:ok, recovered} = PendingRecovery.recover_one(pending, DateTime.utc_now())
      assert recovered.status == "failed"
      assert recovered.retryable == false
      assert recovered.response_metadata["delivery_outcome"] == "unknown"
      assert {:error, %{code: "alert_delivery_execution_superseded"}} = AttemptLifecycle.finalize_failed_attempt(pending, DateTime.utc_now(), "webhook", "late", "late")
      assert Repo.get!(AlertDeliveryAttempt, pending.id) == recovered
    end
  end

  test "wrong job identity stays unresolved and gets bounded operator attention" do
    %{user: owner} = bootstrap_owner_fixture()
    scope = Scope.for_user(owner, ["instance_owner"])
    {incident, _channel, job, pending} = fixture!()
    job |> Ecto.Changeset.change(args: %{"alert_incident_id" => Ecto.UUID.generate(), "alert_channel_id" => pending.channel_id}) |> Repo.update!()
    assert {:ok, unresolved} = PendingRecovery.recover_one(pending, DateTime.utc_now())
    assert unresolved.status == "pending"
    assert unresolved.response_metadata["delivery_recovery"]["reason"] == "job_mismatch"
    projections = AlertIncidentRelationships.incident_relationship_projections(scope, [incident])
    summary = projections.delivery_summaries_by_incident[incident.id]
    assert summary.attention_count == 1
    [projected] = summary.attempts
    assert projected.status == "pending"
    assert projected.failure_code == "alert_delivery_unresolved"
    assert projected.failure_message == "delivery outcome unresolved; execution evidence unavailable"
    refute Map.has_key?(projected.response_metadata, "delivery_execution")
  end

  test "deleted receipts do not create a retry or replacement row" do
    {_incident, _channel, job, pending} = fixture!()
    Repo.delete!(pending)
    assert {:ok, :unchanged} = PendingRecovery.recover_one(pending, DateTime.utc_now())
    assert {:error, %{code: "alert_delivery_execution_superseded"}} = AttemptLifecycle.mark_sent_attempt(pending, DateTime.utc_now(), %{})
    job |> Ecto.Changeset.change(state: "discarded") |> Repo.update!()
    refute Repo.get(AlertDeliveryAttempt, pending.id)
  end

  test "the existing independent runtime cleanup step publishes pending recovery counts" do
    {_incident, _channel, job, pending} = fixture!()
    job |> Ecto.Changeset.change(state: "cancelled") |> Repo.update!()
    pending |> Ecto.Changeset.change(created_at: DateTime.add(DateTime.utc_now(), -60)) |> Repo.update!()
    assert {:ok, summary} = RuntimeStateCleanup.run()
    assert summary.alert_deliveries_recovered == 1
    assert Repo.get!(AlertDeliveryAttempt, pending.id).status == "failed"
  end

  test "exact-shaped out-of-range execution numbers become unresolved without entering database encoders" do
    {_incident, _channel, _job, pending} = fixture!()
    domains = SQL.query!(Repo, "SELECT column_name, data_type FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'oban_jobs' AND column_name IN ('id', 'attempt') ORDER BY column_name", []).rows
    assert domains == [["attempt", "integer"], ["id", "bigint"]]
    CodexPooler.TestDiagnostics.puts("binding-domains job_id=bigint job_attempt=integer")

    for {field, value} <- [{"job_id", 9_223_372_036_854_775_808}, {"job_attempt", 2_147_483_648}] do
      binding = Map.put(pending.response_metadata["delivery_execution"], field, value)
      changed = pending |> Ecto.Changeset.change(response_metadata: %{"delivery_execution" => binding}) |> Repo.update!()
      assert {:ok, result} = PendingRecovery.recover_one(changed, DateTime.utc_now())
      assert result.status == "pending"
      assert result.response_metadata["delivery_recovery"]["reason"] == "invalid_execution"
    end
  end

  test "a backwards durable generation remains unresolved without revoking the recorded execution" do
    {_incident, _channel, job, pending} = fixture!()
    job |> Ecto.Changeset.change(attempted_at: DateTime.add(job.attempted_at, -1, :second), state: "retryable") |> Repo.update!()
    assert {:ok, result} = PendingRecovery.recover_one(pending, DateTime.utc_now())
    assert result.status == "pending"
    assert result.response_metadata["delivery_recovery"]["reason"] == "execution_unknown"
    assert result.response_metadata["delivery_execution"] == pending.response_metadata["delivery_execution"]
  end

  test "revoked final execution records failure without scheduling another delivery" do
    {_incident, _channel, job, pending} = fixture!()
    job |> Ecto.Changeset.change(max_attempts: job.attempt, state: "retryable") |> Repo.update!()
    before_jobs = Repo.aggregate(Oban.Job, :count)
    assert {:ok, result} = PendingRecovery.recover_one(pending, DateTime.utc_now())
    assert result.status == "failed"
    refute result.retryable
    assert is_nil(result.next_retry_at)
    assert result.response_metadata["delivery_outcome"] == "unknown"
    assert Repo.aggregate(Oban.Job, :count) == before_jobs
  end

  test "email recovery preserves adapter identity for retryable and terminal executions" do
    for state <- ["retryable", "cancelled"] do
      {_incident, _channel, job, pending} = fixture!(%{"delivery_adapter" => "email"})
      job |> Ecto.Changeset.change(state: state) |> Repo.update!()
      assert {:ok, recovered} = PendingRecovery.recover_one(pending, DateTime.utc_now())
      assert recovered.status == if(state == "retryable", do: "retryable", else: "failed")
      assert recovered.failure_code == "alert_email_execution_interrupted"
      assert recovered.failure_message == "email execution ended; delivery outcome unknown"
      assert recovered.failure_metadata["delivery_adapter"] == "email"
      assert recovered.response_metadata["delivery_outcome"] == "unknown"
    end
  end

  defp fixture!(metadata \\ %{}) do
    pool = pool_fixture()
    incident = alert_incident_fixture(pool: pool)

    channel_attrs =
      if Map.get(metadata, "delivery_adapter") == "webhook" do
        %{
          channel_type: "webhook",
          email_to: nil,
          endpoint_scheme: "https",
          endpoint_host: "hooks.example.com",
          endpoint_path_prefix: "/alerts",
          endpoint_fingerprint: "sha256:example",
          webhook_signing_secret_ciphertext: <<1, 2, 3>>,
          webhook_signing_secret_nonce: <<4, 5, 6>>,
          webhook_signing_secret_key_version: "v1"
        }
      else
        %{}
      end

    channel = alert_channel_fixture(channel_attrs)
    queue = "recovery_#{System.unique_integer([:positive])}"
    job = %{"alert_incident_id" => incident.id, "alert_channel_id" => channel.id} |> AlertDeliveryWorker.new(queue: queue) |> Repo.insert!()
    conf = Oban.config()
    {:ok, meta} = Basic.init(conf, queue: queue, limit: 1)
    {:ok, {_meta, [claimed]}} = Basic.fetch_jobs(conf, meta, %{})
    assert claimed.id == job.id
    assert {:ok, pending} = AttemptLifecycle.insert_pending_attempt(incident, channel, 1, DateTime.utc_now(), metadata, Execution.new(claimed))
    {incident, channel, claimed, pending}
  end
end
