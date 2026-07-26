defmodule CodexPooler.Jobs.AlertEvaluatorJobTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import Swoosh.TestAssertions

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [primary_quota_window_attrs: 1]

  alias CodexPooler.Alerts.Schemas.{
    AlertDeliveryAttempt,
    AlertIncident,
    AlertIncidentTarget,
    AlertRule,
    AlertRuleChannel
  }

  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Jobs

  alias CodexPooler.Jobs.{
    AlertDeliveryWorker,
    AlertEvaluationEnqueueWorker,
    AlertEvaluationWorker
  }

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @forbidden_arg_fragments ~w(
    prompt request_body response_body body bearer token access_token refresh_token authorization
    headers cookies cookie auth_json provider_payload webhook file websocket idempotency_key
  )

  setup do
    Repo.delete_all(AlertDeliveryAttempt)
    Repo.delete_all(Oban.Job)
    Repo.delete_all(AlertIncidentTarget)
    Repo.delete_all(AlertIncident)
    Repo.delete_all(AlertRuleChannel)
    Repo.delete_all(AlertRule)
    :ok
  end

  test "fan-out enqueues bounded active rule evaluation jobs with safe args" do
    timestamp = timestamp(~U[2026-05-30 10:07:13Z])
    created_at = timestamp(~U[2026-05-30 10:00:00Z])
    pool = pool_fixture()

    first_rule =
      alert_rule_fixture(pool,
        display_name: "First alert rule",
        created_at: created_at,
        updated_at: created_at
      )

    second_rule =
      alert_rule_fixture(pool,
        display_name: "Second alert rule",
        created_at: DateTime.add(created_at, 1, :second),
        updated_at: DateTime.add(created_at, 1, :second)
      )

    disabled_rule =
      alert_rule_fixture(pool,
        display_name: "Disabled alert rule",
        state: "disabled",
        created_at: DateTime.add(created_at, 2, :second),
        updated_at: DateTime.add(created_at, 2, :second)
      )

    assert {:ok, %{inserted: jobs, conflicts: [], errors: []}} =
             Jobs.enqueue_alert_evaluations_for_active_rules(
               trigger_kind: "scheduled",
               now: timestamp,
               limit: 2
             )

    assert length(jobs) == 2

    args = Enum.map(jobs, & &1.args)
    queued_rule_ids = Enum.map(args, & &1["alert_rule_id"])

    assert first_rule.id in queued_rule_ids
    assert second_rule.id in queued_rule_ids
    refute disabled_rule.id in queued_rule_ids

    for job_args <- args do
      assert job_args["evaluation_window_started_at"] == "2026-05-30T10:05:00Z"
      assert job_args["trigger_kind"] == "scheduled"
      assert_safe_job_args(job_args)
    end

    assert {:ok, %{inserted: [], conflicts: duplicate_jobs, errors: []}} =
             Jobs.enqueue_alert_evaluations_for_active_rules(
               trigger_kind: "scheduled",
               now: timestamp,
               limit: 2
             )

    assert length(duplicate_jobs) == 2
  end

  test "scheduled enqueue worker fans out through the central jobs facade" do
    pool = pool_fixture()
    rule = alert_rule_fixture(pool)
    scheduled_at = timestamp(~U[2026-05-30 10:05:00Z])

    assert :ok = perform_job(AlertEvaluationEnqueueWorker, %{}, scheduled_at: scheduled_at)

    assert [job] = all_enqueued(worker: AlertEvaluationWorker)
    assert job.args["alert_rule_id"] == rule.id
    assert job.args["trigger_kind"] == "scheduled"
    assert job.args["evaluation_window_started_at"] == "2026-05-30T10:05:00Z"
    assert_safe_job_args(job.args)
  end

  test "delayed pool usability jobs observe and timestamp circuits at attempted_at" do
    window_started_at = timestamp(~U[2026-05-30 09:10:00Z])
    attempted_at = timestamp(~U[2026-05-30 09:20:00Z])
    pool = pool_fixture()
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("10"),
                 credits: 90,
                 reset_at: DateTime.add(attempted_at, 1, :hour),
                 observed_at: window_started_at
               })
             ])

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-delayed",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

    rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_no_usable_assignments",
        model: model.exposed_model_id
      )

    circuit =
      circuit_fixture(pool, assignment, identity, model.exposed_model_id, attempted_at,
        next_probe_at: timestamp(~U[2026-05-30 09:00:00Z]),
        last_failure_at: timestamp(~U[2026-05-30 09:18:00Z])
      )

    assert :ok =
             perform_job(
               AlertEvaluationWorker,
               alert_job_args(rule, window_started_at),
               attempted_at: attempted_at
             )

    assert %AlertIncident{last_seen_at: ^attempted_at} = incident = incident_for_rule(rule)

    circuit
    |> RoutingCircuitState.changeset(%{last_failure_at: timestamp(~U[2026-05-30 09:21:00Z])})
    |> Repo.update!()

    assert :ok =
             perform_job(
               AlertEvaluationWorker,
               alert_job_args(rule, window_started_at),
               attempted_at: attempted_at
             )

    assert %AlertIncident{state: "resolved", resolved_at: ^attempted_at} =
             Repo.get!(AlertIncident, incident.id)
  end

  test "disabled usability rules clear at attempted_at and malformed clocks are cancelled" do
    window_started_at = timestamp(~U[2026-05-30 09:10:00Z])
    attempted_at = timestamp(~U[2026-05-30 09:20:00Z])
    pool = pool_fixture()
    upstream_assignment_fixture(pool)
    rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    assert :ok =
             perform_job(
               AlertEvaluationWorker,
               alert_job_args(rule, window_started_at),
               attempted_at: window_started_at
             )

    assert %AlertIncident{} = incident = incident_for_rule(rule)

    rule
    |> AlertRule.changeset(%{state: "disabled", disabled_at: attempted_at})
    |> Repo.update!()

    assert :ok =
             perform_job(
               AlertEvaluationWorker,
               alert_job_args(rule, window_started_at),
               attempted_at: attempted_at
             )

    assert %AlertIncident{state: "resolved", resolved_at: ^attempted_at} =
             Repo.get!(AlertIncident, incident.id)

    assert {:cancel, :invalid_alert_evaluation_args} =
             AlertEvaluationWorker.perform(%Oban.Job{
               args: alert_job_args(rule, window_started_at),
               attempted_at: nil
             })

    assert {:cancel, :invalid_alert_evaluation_args} =
             AlertEvaluationWorker.perform(%Oban.Job{
               args: alert_job_args(rule, window_started_at),
               attempted_at: "2026-05-30T09:20:00Z"
             })

    assert {:cancel, :invalid_evaluation_window_started_at} =
             AlertEvaluationWorker.perform(%Oban.Job{
               args:
                 alert_job_args(rule, window_started_at)
                 |> Map.put("evaluation_window_started_at", "not-a-timestamp"),
               attempted_at: attempted_at
             })
  end

  test "circuit blackout follows the real evaluation delivery recurrence and clear path" do
    window_started_at = timestamp(~U[2026-05-30 09:10:00Z])
    attempted_at = timestamp(~U[2026-05-30 09:20:00Z])
    cleared_at = timestamp(~U[2026-05-30 09:25:00Z])
    failed_at = timestamp(~U[2026-05-30 09:18:00Z])
    pool = pool_fixture()
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("10"),
                 credits: 90,
                 reset_at: DateTime.add(attempted_at, 1, :hour),
                 observed_at: window_started_at
               })
             ])

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-e2e-blackout",
        metadata: %{"source_assignment_ids" => [assignment.id]}
      })

    rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_no_usable_assignments",
        model: model.exposed_model_id,
        cooldown_minutes: 30
      )

    channel = alert_channel_fixture(%{display_name: "Circuit blackout operations email"})
    link_rule_channel!(rule, channel, window_started_at)

    circuit =
      circuit_fixture(pool, assignment, identity, model.exposed_model_id, failed_at,
        next_probe_at: DateTime.add(attempted_at, 60, :second),
        last_failure_at: failed_at
      )

    assert :ok =
             perform_job(AlertEvaluationEnqueueWorker, %{}, scheduled_at: window_started_at)

    assert [evaluation_job] = all_enqueued(worker: AlertEvaluationWorker)
    assert evaluation_job.args["evaluation_window_started_at"] == "2026-05-30T09:10:00Z"

    assert :ok =
             perform_job(
               AlertEvaluationWorker,
               evaluation_job.args,
               attempted_at: attempted_at
             )

    assert %AlertIncident{
             occurrence_count: 1,
             first_seen_at: ^attempted_at,
             last_seen_at: ^attempted_at
           } = incident = incident_for_rule(rule)

    assert incident.dedupe_key ==
             "alerts:v1:pool_no_usable_assignments:pool:#{pool.id}:model:gpt-e2e-blackout:min:none:state:none:route_class:any"

    assert incident.safe_evidence_snapshot["circuit_blocked_assignment_count"] == 1
    assert incident.safe_evidence_snapshot["circuit_blocked_lane_count"] == 1
    assert incident.safe_evidence_snapshot["circuit_blocked_reasons"] == ["open_cooldown"]
    assert incident.safe_evidence_snapshot["circuit_blocked_route_classes"] == ["proxy_stream"]
    assert incident.safe_evidence_snapshot["circuit_recency_seconds"] == 900
    assert incident.safe_evidence_snapshot["model_membership_resolved"] == true
    assert incident.safe_evidence_snapshot["non_serving_assignment_count"] == 0

    assert [delivery_job] = all_enqueued(worker: AlertDeliveryWorker)

    assert :ok = perform_job(AlertDeliveryWorker, delivery_job.args)

    assert [
             %AlertDeliveryAttempt{
               status: "sent",
               attempted_at: delivery_attempted_at,
               completed_at: delivery_attempted_at
             }
           ] = Repo.all(AlertDeliveryAttempt)

    assert %DateTime{} = delivery_attempted_at

    assert_email_sent(fn email ->
      assert email.subject == "Codex Pooler alert: critical: pool_no_usable_assignments"
      assert email.text_body =~ "Incident id: #{incident.id}"
      true
    end)

    Repo.delete_all(Oban.Job)

    assert :ok =
             perform_job(
               AlertEvaluationWorker,
               evaluation_job.args,
               attempted_at: attempted_at
             )

    assert %AlertIncident{occurrence_count: 2} = Repo.get!(AlertIncident, incident.id)
    assert [] = all_enqueued(worker: AlertDeliveryWorker)

    circuit
    |> RoutingCircuitState.changeset(%{
      status: "closed",
      next_probe_at: nil,
      closed_at: cleared_at,
      last_success_at: cleared_at
    })
    |> Repo.update!()

    assert :ok =
             perform_job(
               AlertEvaluationWorker,
               evaluation_job.args,
               attempted_at: cleared_at
             )

    assert %AlertIncident{state: "resolved", resolved_at: ^cleared_at} =
             Repo.get!(AlertIncident, incident.id)
  end

  test "per-rule worker records persisted evaluator matches through the incident lifecycle" do
    timestamp = timestamp(~U[2026-05-30 11:00:00Z])
    pool = pool_fixture()
    upstream_assignment_fixture(pool)
    rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    assert :ok =
             perform_job(AlertEvaluationWorker, alert_job_args(rule, timestamp),
               attempted_at: timestamp
             )

    assert %AlertIncident{} = incident = incident_for_rule(rule)
    assert incident.state == "open"
    assert incident.pool_id == pool.id
    assert incident.rule_kind == "pool_no_usable_assignments"
    assert incident.safe_evidence_snapshot["reason_code"] == "no_usable_assignments"
    assert incident.safe_evidence_snapshot["assignment_count"] == 1
  end

  test "per-rule worker enqueues delivery once for each linked active channel on incident match" do
    timestamp = timestamp(~U[2026-05-30 11:30:00Z])
    pool = pool_fixture()
    upstream_assignment_fixture(pool)
    rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")
    active_channel = alert_channel_fixture(%{display_name: "Active operations email"})

    disabled_channel =
      alert_channel_fixture(%{display_name: "Disabled operations email", state: "disabled"})

    link_rule_channel!(rule, active_channel, timestamp)
    link_rule_channel!(rule, disabled_channel, timestamp)

    assert :ok =
             perform_job(AlertEvaluationWorker, alert_job_args(rule, timestamp),
               attempted_at: timestamp
             )

    assert %AlertIncident{} = incident_for_rule(rule)
    assert [job] = all_enqueued(worker: AlertDeliveryWorker)
    assert job.args["alert_channel_id"] == active_channel.id
    assert job.args["trigger_kind"] == "incident_match"
    assert_safe_job_args(job.args)

    assert :ok =
             perform_job(AlertEvaluationWorker, alert_job_args(rule, timestamp),
               attempted_at: timestamp
             )

    assert [job] = all_enqueued(worker: AlertDeliveryWorker)
    assert job.args["alert_channel_id"] == active_channel.id
  end

  test "per-rule worker enqueues recurrence delivery only after channel cooldown allows it" do
    first_seen = timestamp(~U[2026-05-30 11:45:00Z])
    within_cooldown = timestamp(~U[2026-05-30 11:49:00Z])
    after_cooldown = timestamp(~U[2026-05-30 11:51:00Z])
    pool = pool_fixture()
    upstream_assignment_fixture(pool)
    rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments", cooldown_minutes: 5)
    channel = alert_channel_fixture(%{display_name: "Cooldown operations email"})
    link_rule_channel!(rule, channel, first_seen)

    assert :ok =
             perform_job(AlertEvaluationWorker, alert_job_args(rule, first_seen),
               attempted_at: first_seen
             )

    assert [first_job] = all_enqueued(worker: AlertDeliveryWorker)
    incident = incident_for_rule(rule)
    Repo.delete_all(Oban.Job)
    insert_sent_attempt!(incident, channel, 1, first_seen)

    assert :ok =
             perform_job(AlertEvaluationWorker, alert_job_args(rule, within_cooldown),
               attempted_at: within_cooldown
             )

    assert [] = all_enqueued(worker: AlertDeliveryWorker)

    assert :ok =
             perform_job(AlertEvaluationWorker, alert_job_args(rule, after_cooldown),
               attempted_at: after_cooldown
             )

    assert [recurrence_job] = all_enqueued(worker: AlertDeliveryWorker)
    assert recurrence_job.args == first_job.args
  end

  test "per-rule worker clears resolved persisted conditions through the incident lifecycle" do
    first_seen = timestamp(~U[2026-05-30 12:00:00Z])
    cleared_at = timestamp(~U[2026-05-30 12:05:00Z])
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)
    rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")
    channel = alert_channel_fixture(%{display_name: "Clear path operations email"})
    link_rule_channel!(rule, channel, first_seen)

    assert :ok =
             perform_job(AlertEvaluationWorker, alert_job_args(rule, first_seen),
               attempted_at: first_seen
             )

    assert %AlertIncident{} = incident = incident_for_rule(rule)
    assert incident.state == "open"
    assert [_first_delivery_job] = all_enqueued(worker: AlertDeliveryWorker)
    Repo.delete_all(Oban.Job)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("12"),
                 credits: 88,
                 reset_at: DateTime.add(cleared_at, 1, :hour),
                 observed_at: cleared_at
               })
             ])

    assert :ok =
             perform_job(AlertEvaluationWorker, alert_job_args(rule, cleared_at),
               attempted_at: cleared_at
             )

    assert %AlertIncident{state: "resolved", resolved_at: ^cleared_at} =
             Repo.get!(AlertIncident, incident.id)

    assert [] = all_enqueued(worker: AlertDeliveryWorker)
  end

  test "disabled rules do not create repeated incident matches from queued jobs" do
    timestamp = timestamp(~U[2026-05-30 13:00:00Z])
    pool = pool_fixture()
    upstream_assignment_fixture(pool)
    rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments", state: "disabled")

    assert :ok =
             perform_job(AlertEvaluationWorker, alert_job_args(rule, timestamp),
               attempted_at: timestamp
             )

    assert [] = Repo.all(AlertIncident)
  end

  defp alert_job_args(rule, timestamp) do
    %{
      "alert_rule_id" => rule.id,
      "evaluation_window_started_at" => DateTime.to_iso8601(timestamp),
      "trigger_kind" => "test"
    }
  end

  defp incident_for_rule(rule) do
    Repo.one!(
      from incident in AlertIncident,
        where: incident.rule_kind == ^rule.rule_kind,
        order_by: [desc: incident.created_at, desc: incident.id],
        limit: 1
    )
  end

  defp insert_sent_attempt!(incident, channel, attempt_number, timestamp) do
    %AlertDeliveryAttempt{}
    |> AlertDeliveryAttempt.changeset(%{
      incident_id: incident.id,
      channel_id: channel.id,
      attempt_number: attempt_number,
      status: AlertDeliveryAttempt.sent_status(),
      scheduled_at: timestamp,
      attempted_at: timestamp,
      completed_at: timestamp,
      retryable: false,
      response_metadata: %{"delivery_adapter" => "email"},
      failure_metadata: %{},
      created_at: timestamp,
      updated_at: timestamp
    })
    |> Repo.insert!()
  end

  defp circuit_fixture(pool, assignment, identity, model_identifier, timestamp, attrs) do
    attrs = Map.new(attrs)

    %RoutingCircuitState{}
    |> RoutingCircuitState.changeset(%{
      pool_id: pool.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      model_identifier: model_identifier,
      route_class: Map.get(attrs, :route_class, "proxy_stream"),
      status: Map.get(attrs, :status, "open"),
      reason_code: "synthetic_test_failure",
      failure_count: 3,
      success_count: 0,
      opened_at: timestamp,
      next_probe_at: Map.get(attrs, :next_probe_at),
      last_failure_at: Map.get(attrs, :last_failure_at, timestamp),
      metadata: %{"probe_in_flight_count" => 0},
      created_at: timestamp,
      updated_at: timestamp
    })
    |> Repo.insert!()
  end

  defp link_rule_channel!(rule, channel, timestamp) do
    %AlertRuleChannel{}
    |> AlertRuleChannel.changeset(%{
      alert_rule_id: rule.id,
      alert_channel_id: channel.id,
      created_at: timestamp
    })
    |> Repo.insert!()
  end

  defp assert_safe_job_args(args) do
    assert Map.keys(args) |> Enum.all?(&is_binary/1)
    encoded_args = Jason.encode!(args)

    for fragment <- @forbidden_arg_fragments do
      refute encoded_args =~ fragment
    end
  end

  defp timestamp(value), do: %{value | microsecond: {0, 6}}
end
