defmodule CodexPooler.Upstreams.QuotaReconciliationEnqueueTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.Jobs.UpstreamEnqueue
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "queues one reconciliation for a shared identity and audits every affected pool" do
    scope = owner_scope()
    first_pool = pool_fixture(%{name: "First quota pool"})
    second_pool = pool_fixture(%{name: "Second quota pool"})

    %{identity: identity, assignment: first_assignment} =
      active_upstream_assignment_fixture(first_pool)

    assert {:ok, second_assignment} =
             PoolAssignments.assign_pool_assignment(second_pool, identity)

    assert {:ok, second_assignment} =
             PoolAssignments.update_pool_assignment(second_assignment, %{status: "paused"})

    Repo.delete_all(Oban.Job)

    assert {:ok, %{status: :queued, job: job, assignments: assignments}} =
             Upstreams.enqueue_quota_reconciliation_for_scope(
               scope,
               identity,
               trigger_kind: "admin_upstreams_live"
             )

    assert Enum.map(assignments, & &1.id) == [first_assignment.id, second_assignment.id]
    assert Enum.map(assignments, & &1.status) == ["active", "paused"]
    assert job.worker == Oban.Worker.to_string(AccountReconciliationWorker)
    assert job.args["pool_id"] == first_pool.id
    assert job.args["pool_upstream_assignment_id"] == first_assignment.id
    assert job.args["upstream_identity_id"] == identity.id
    assert job.args["target_kind"] == "upstream_identity"
    assert job.args["trigger_kind"] == "admin_upstreams_live"

    assert [persisted_job] = all_enqueued(worker: AccountReconciliationWorker)
    assert persisted_job.id == job.id

    audit_pool_ids =
      Repo.all(
        from event in AuditEvent,
          where: event.action == "upstream_account.quota_reconciliation_enqueue",
          where: event.target_id == ^identity.id,
          select: event.pool_id
      )

    assert MapSet.new(audit_pool_ids) == MapSet.new([first_pool.id, second_pool.id])
  end

  test "reports a duplicate identity reconciliation without inserting another job" do
    scope = owner_scope()
    pool = pool_fixture()
    %{identity: identity} = active_upstream_assignment_fixture(pool)
    Repo.delete_all(Oban.Job)

    assert {:ok, %{status: :queued, job: first_job}} =
             Upstreams.enqueue_quota_reconciliation_for_scope(scope, identity)

    assert {:ok, %{status: :already_queued, job: second_job}} =
             Upstreams.enqueue_quota_reconciliation_for_scope(scope, identity)

    assert first_job.id == second_job.id
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "deduplicates against an automatic job queued through another pool assignment" do
    scope = owner_scope()
    first_pool = pool_fixture(%{name: "First automatic pool"})
    second_pool = pool_fixture(%{name: "Second automatic pool"})
    %{identity: identity} = active_upstream_assignment_fixture(first_pool)

    assert {:ok, second_assignment} =
             PoolAssignments.assign_pool_assignment(second_pool, identity)

    Repo.delete_all(Oban.Job)

    assert {:ok, automatic_job} =
             UpstreamEnqueue.enqueue_scheduled_identity_account_reconciliation(second_assignment)

    assert {:ok, %{status: :already_queued, job: manual_job}} =
             Upstreams.enqueue_quota_reconciliation_for_scope(scope, identity)

    assert manual_job.id == automatic_job.id
    assert manual_job.args["pool_upstream_assignment_id"] == second_assignment.id
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "rejects identities without a reconcilable assignment" do
    scope = owner_scope()
    pool = pool_fixture()
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture(pool)

    assert {:ok, _assignment} =
             PoolAssignments.update_pool_assignment(assignment, %{status: "paused"})

    Repo.delete_all(Oban.Job)

    assert {:error, %{code: :quota_reconciliation_unavailable}} =
             Upstreams.enqueue_quota_reconciliation_for_scope(scope, identity)

    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "rejects an invalid user scope" do
    identity = active_upstream_identity_fixture()

    assert {:error, %{code: :invalid_request}} =
             Upstreams.enqueue_quota_reconciliation_for_scope(nil, identity)
  end

  defp owner_scope do
    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    Scope.for_user(user, ["instance_owner"])
  end
end
