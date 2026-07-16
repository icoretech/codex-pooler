defmodule CodexPooler.Admin.UpstreamAssignmentWorkflowTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.UpstreamAssignmentWorkflow
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Events
  alias CodexPooler.Jobs.CatalogSyncWorker
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "authorized assignment records an audit event, broadcasts, and queues catalog sync" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner)
    pool = pool_fixture(%{name: "Assignment Workflow Target"})

    identity =
      active_upstream_identity_fixture(%{
        account_label: "Workflow upstream",
        chatgpt_account_id: "acct_assignment_workflow"
      })

    assert :ok = Events.subscribe_pool(pool, "upstreams")

    assert {:ok, assignment} =
             Task.async(fn ->
               UpstreamAssignmentWorkflow.assign_to_pool(scope, pool, identity)
             end)
             |> Task.await(5_000)

    assert assignment.pool_id == pool.id
    assert assignment.upstream_identity_id == identity.id
    assert assignment.status == "active"
    assert assignment.health_status == "active"
    assert assignment.eligibility_status == "eligible"

    assert [job] = all_enqueued(worker: CatalogSyncWorker)
    assert job.args == %{"pool_id" => pool.id, "trigger_kind" => "manual"}

    assert_receive {Events, event}
    assert event.pool_id == pool.id
    assert event.reason == "upstream_assignment_assigned"
    assert event.payload["assignment_id"] == assignment.id
    assert event.payload["upstream_identity_id"] == identity.id

    assert %AuditEvent{} =
             audit_event =
             Repo.get_by(AuditEvent,
               action: "upstream_account.assign_pool",
               target_id: identity.id
             )

    assert audit_event.actor_user_id == owner.id
    assert audit_event.pool_id == pool.id
    assert audit_event.details["pool_assignment_ids"] == [assignment.id]
    assert audit_event.details["assignment_status"] == "active"
  end

  test "operator without target Pool access cannot create an assignment or side effects" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    scope = Scope.for_user(admin)
    pool = pool_fixture(%{name: "Hidden Assignment Target"})

    identity =
      active_upstream_identity_fixture(%{
        account_label: "Unauthorized workflow upstream",
        chatgpt_account_id: "acct_assignment_workflow_denied"
      })

    assert {:error, %{code: :capability_denied}} =
             UpstreamAssignmentWorkflow.assign_to_pool(scope, pool, identity)

    assert Upstreams.list_pool_assignments_for_identity(identity) == []
    assert [] = all_enqueued(worker: CatalogSyncWorker)

    refute Repo.get_by(AuditEvent,
             action: "upstream_account.assign_pool",
             target_id: identity.id
           )
  end
end
