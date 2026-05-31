defmodule CodexPooler.Jobs.AlertEvaluatorJobTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [primary_quota_window_attrs: 1]

  alias CodexPooler.Alerts.Schemas.{
    AlertIncident,
    AlertIncidentTarget,
    AlertRule,
    AlertRuleChannel
  }

  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.{AlertEvaluationEnqueueWorker, AlertEvaluationWorker}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @forbidden_arg_fragments ~w(
    prompt request_body response_body body bearer token access_token refresh_token authorization
    headers cookies cookie auth_json provider_payload webhook file websocket idempotency_key
  )

  setup do
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

    assert :ok = perform_job(AlertEvaluationEnqueueWorker, %{})

    assert [job] = all_enqueued(worker: AlertEvaluationWorker)
    assert job.args["alert_rule_id"] == rule.id
    assert job.args["trigger_kind"] == "scheduled"
    assert_safe_job_args(job.args)
  end

  test "per-rule worker records persisted evaluator matches through the incident lifecycle" do
    timestamp = timestamp(~U[2026-05-30 11:00:00Z])
    pool = pool_fixture()
    upstream_assignment_fixture(pool)
    rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    assert :ok = perform_job(AlertEvaluationWorker, alert_job_args(rule, timestamp))

    assert %AlertIncident{} = incident = incident_for_rule(rule)
    assert incident.state == "open"
    assert incident.pool_id == pool.id
    assert incident.rule_kind == "pool_no_usable_assignments"
    assert incident.safe_evidence_snapshot["reason_code"] == "no_usable_assignments"
    assert incident.safe_evidence_snapshot["assignment_count"] == 1
  end

  test "per-rule worker clears resolved persisted conditions through the incident lifecycle" do
    first_seen = timestamp(~U[2026-05-30 12:00:00Z])
    cleared_at = timestamp(~U[2026-05-30 12:05:00Z])
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)
    rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    assert :ok = perform_job(AlertEvaluationWorker, alert_job_args(rule, first_seen))
    assert %AlertIncident{} = incident = incident_for_rule(rule)
    assert incident.state == "open"

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("12"),
                 credits: 88,
                 reset_at: DateTime.add(cleared_at, 1, :hour),
                 observed_at: cleared_at
               })
             ])

    assert :ok = perform_job(AlertEvaluationWorker, alert_job_args(rule, cleared_at))

    assert %AlertIncident{state: "resolved", resolved_at: ^cleared_at} =
             Repo.get!(AlertIncident, incident.id)
  end

  test "disabled rules do not create repeated incident matches from queued jobs" do
    timestamp = timestamp(~U[2026-05-30 13:00:00Z])
    pool = pool_fixture()
    upstream_assignment_fixture(pool)
    rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments", state: "disabled")

    assert :ok = perform_job(AlertEvaluationWorker, alert_job_args(rule, timestamp))
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

  defp assert_safe_job_args(args) do
    assert Map.keys(args) |> Enum.all?(&is_binary/1)
    encoded_args = Jason.encode!(args)

    for fragment <- @forbidden_arg_fragments do
      refute encoded_args =~ fragment
    end
  end

  defp timestamp(value), do: %{value | microsecond: {0, 6}}
end
