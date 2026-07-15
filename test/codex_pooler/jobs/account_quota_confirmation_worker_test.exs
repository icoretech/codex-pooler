defmodule CodexPooler.Jobs.AccountQuotaConfirmationWorkerTest do
  use CodexPooler.DataCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Jobs.{AccountQuotaConfirmationWorker, AccountReconciliationWorker}
  alias CodexPooler.Jobs.UpstreamEnqueue
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @weekly_seconds 604_800

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "manual refresh schedules and runs its own delayed zero confirmation" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    provider_reset_at = DateTime.add(now, @weekly_seconds, :second)

    upstream = start_usage_upstream(0, provider_reset_at)

    %{identity: identity, assignment: assignment} = assignment_fixture(upstream)
    Repo.delete_all(Oban.Job)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               weekly_evidence(31, DateTime.add(now, -10, :minute), DateTime.add(now, 5, :day)),
               DateTime.add(now, -10, :minute)
             )

    assert :ok =
             perform_job(AccountReconciliationWorker, %{
               "pool_id" => assignment.pool_id,
               "pool_upstream_assignment_id" => assignment.id,
               "upstream_identity_id" => identity.id,
               "trigger_kind" => "admin_upstreams_live"
             })

    row = usage_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new(31))
    assert {:ok, candidate} = EvidenceStore.parse_candidate(row.metadata)

    priming = Repo.get!(PoolUpstreamAssignment, assignment.id).metadata["quota_priming"]
    assert priming["status"] == "confirmation_pending"
    assert priming["confirmation_pending_count"] == 1
    assert is_binary(priming["confirmation_due_at"])

    assert [confirmation_job] = all_enqueued(worker: AccountQuotaConfirmationWorker)
    assert confirmation_job.state == "scheduled"
    assert confirmation_job.args["upstream_identity_id"] == identity.id
    assert confirmation_job.args["trigger_kind"] == "admin_quota_confirmation"

    assert DateTime.diff(confirmation_job.scheduled_at, candidate.observed_at, :second) >=
             EvidenceStore.weekly_restart_confirmation_span_seconds()

    assert {:ok, duplicate_confirmation} =
             AccountQuotaConfirmationWorker.enqueue_if_pending(
               %{identity: identity, assignment: assignment},
               "admin_upstreams_live"
             )

    assert duplicate_confirmation.conflict?
    assert duplicate_confirmation.id == confirmation_job.id
    assert [_one_confirmation] = all_enqueued(worker: AccountQuotaConfirmationWorker)

    assert {:snooze, remaining_seconds} =
             AccountQuotaConfirmationWorker.perform(%Oban.Job{args: confirmation_job.args})

    assert remaining_seconds > 0

    candidate_at = DateTime.add(DateTime.utc_now(), -4, :minute)

    candidate_metadata = %{
      "version" => 1,
      "used_percent" => "0",
      "reset_at" =>
        candidate_at |> DateTime.add(@weekly_seconds, :second) |> DateTime.to_iso8601(),
      "observed_at" => DateTime.to_iso8601(candidate_at),
      "count" => 1
    }

    row
    |> Ecto.Changeset.change(%{
      metadata: Map.put(row.metadata, "__quota_confirmed_candidate_v1", candidate_metadata)
    })
    |> Repo.update!()

    assert {:ok, recent_reconciliation} =
             UpstreamEnqueue.enqueue_identity_account_reconciliation(
               assignment.pool_id,
               assignment,
               trigger_kind: "scheduled"
             )

    recent_reconciliation
    |> Ecto.Changeset.change(%{
      state: "completed",
      attempted_at: DateTime.utc_now(),
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()

    assert :ok = perform_job(AccountQuotaConfirmationWorker, confirmation_job.args)

    assert [reconciliation_job] = all_enqueued(worker: AccountReconciliationWorker)
    refute reconciliation_job.id == recent_reconciliation.id
    assert reconciliation_job.args["trigger_kind"] == "admin_quota_confirmation"

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :jobs)

    confirmed = usage_row(identity)
    assert Decimal.equal?(confirmed.used_percent, Decimal.new(0))
    assert EvidenceStore.parse_candidate(confirmed.metadata) == :none

    priming = Repo.get!(PoolUpstreamAssignment, assignment.id).metadata["quota_priming"]
    assert priming["status"] == "weekly_only_probe"
    assert priming["confirmation_pending_count"] == 0

    assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
             "/backend-api/wham/usage",
             "/backend-api/codex/usage",
             "/backend-api/wham/usage",
             "/backend-api/codex/usage"
           ]
  end

  test "manual refresh does not schedule confirmation without a pending zero" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    upstream = start_usage_upstream(43, DateTime.add(now, 5, :day))
    %{identity: identity, assignment: assignment} = assignment_fixture(upstream)
    Repo.delete_all(Oban.Job)

    assert :ok =
             perform_job(AccountReconciliationWorker, %{
               "pool_id" => assignment.pool_id,
               "pool_upstream_assignment_id" => assignment.id,
               "upstream_identity_id" => identity.id,
               "trigger_kind" => "admin_upstream_cockpit_live"
             })

    assert Decimal.equal?(usage_row(identity).used_percent, Decimal.new(43))
    assert [] = all_enqueued(worker: AccountQuotaConfirmationWorker)

    assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
             "/backend-api/wham/usage",
             "/backend-api/codex/usage"
           ]
  end

  test "delayed worker exits without another provider call after the candidate is resolved" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    upstream = start_usage_upstream(0, DateTime.add(now, @weekly_seconds, :second))
    %{identity: identity, assignment: assignment} = assignment_fixture(upstream)

    assert :ok =
             perform_job(AccountQuotaConfirmationWorker, %{
               "pool_id" => assignment.pool_id,
               "pool_upstream_assignment_id" => assignment.id,
               "upstream_identity_id" => identity.id,
               "trigger_kind" => "admin_quota_confirmation"
             })

    assert FakeUpstream.requests(upstream) == []
  end

  test "confirmation bypasses the normal successful reconciliation cooldown" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    upstream = start_usage_upstream(0, DateTime.add(now, @weekly_seconds, :second))
    %{identity: identity, assignment: assignment} = assignment_fixture(upstream)
    Repo.delete_all(Oban.Job)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               weekly_evidence(31, DateTime.add(now, -10, :minute), DateTime.add(now, 5, :day)),
               DateTime.add(now, -10, :minute)
             )

    candidate_at = DateTime.add(now, -4, :minute)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               weekly_evidence(
                 0,
                 candidate_at,
                 DateTime.add(candidate_at, @weekly_seconds, :second)
               ),
               candidate_at
             )

    assert {:ok, cooldown_job} =
             UpstreamEnqueue.enqueue_identity_account_reconciliation(
               assignment.pool_id,
               assignment,
               trigger_kind: "scheduled"
             )

    {1, _rows} =
      from(job in Oban.Job, where: job.id == ^cooldown_job.id)
      |> Repo.update_all(set: [state: "completed", attempted_at: now, completed_at: now])

    assert :ok =
             perform_job(AccountQuotaConfirmationWorker, %{
               "pool_id" => assignment.pool_id,
               "pool_upstream_assignment_id" => assignment.id,
               "upstream_identity_id" => identity.id,
               "trigger_kind" => "admin_quota_confirmation"
             })

    worker = Oban.Worker.to_string(AccountReconciliationWorker)
    account_jobs = Repo.all(from job in Oban.Job, where: job.worker == ^worker)
    assert Enum.map(account_jobs, & &1.state) |> Enum.sort() == ["available", "completed"]

    assert Enum.any?(account_jobs, fn job ->
             job.id != cooldown_job.id and
               job.args["trigger_kind"] == "admin_quota_confirmation"
           end)
  end

  defp assignment_fixture(upstream) do
    active_upstream_assignment_fixture(pool_fixture(), %{
      metadata: %{
        "base_url" => FakeUpstream.url(upstream),
        "access_token_expires_at" =>
          DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.to_iso8601()
      }
    })
  end

  defp weekly_evidence(used_percent, observed_at, reset_at) do
    %{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(used_percent),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh"
    }
  end

  defp usage_row(identity) do
    identity
    |> Windows.list_evidence()
    |> Enum.find(&(&1.source == "codex_usage_api" and &1.window_kind == "secondary"))
  end

  defp start_usage_upstream(used_percent, reset_at) do
    {:ok, upstream} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" =>
             {200,
              %{
                "rate_limit" => %{
                  "primary_window" => %{
                    "used_percent" => used_percent,
                    "limit_window_seconds" => @weekly_seconds,
                    "reset_at" => DateTime.to_iso8601(reset_at)
                  }
                }
              }}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end
end
