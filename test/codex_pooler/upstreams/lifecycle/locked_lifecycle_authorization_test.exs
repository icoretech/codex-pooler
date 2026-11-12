defmodule CodexPooler.Upstreams.Lifecycle.LockedLifecycleAuthorizationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Jobs.UpstreamDeletionWorker
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @barrier {__MODULE__, :barrier}

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(Upstreams)
    CodexPooler.TestAppEnv.restore_on_exit(:upstream_deletion_immediate_row_limit)
    Application.put_env(:codex_pooler, Upstreams, upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "synthetic-lifecycle-root")), upstream_secret_key_version: "test-v1")
    Application.put_env(:codex_pooler, :upstream_deletion_immediate_row_limit, 0)

    handler = "locked-lifecycle-authorization-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok = :telemetry.attach(handler, [:codex_pooler, :repo, :query], &__MODULE__.hold_after_authorization/4, nil)

    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{user: admin} = operator_fixture(owner)
    served = pool_fixture()
    other = pool_fixture()
    operator_pool_assignment_fixture(admin, served, created_by_user_id: owner.id)
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture(served)

    %{owner: owner, admin: admin, owner_scope: Scope.for_user(owner), admin_scope: Scope.for_user(admin), served: served, other: other, identity: identity, assignment: assignment}
  end

  # Holds a lifecycle call of an opted-in process after its second plain identity read: the first
  # belongs to authorization, the second is the last statement before the locking transaction.
  @doc false
  def hold_after_authorization(_event, _measurements, %{source: "upstream_identities"}, _config) do
    case Process.get(@barrier) do
      {test_pid, 1} ->
        Process.put(@barrier, :passed)
        send(test_pid, {:authorized, self()})

        receive do
          :resume -> :ok
        after
          5_000 -> :ok
        end

      {test_pid, reads} ->
        Process.put(@barrier, {test_pid, reads + 1})

      _other ->
        :ok
    end
  end

  def hold_after_authorization(_event, _measurements, _metadata, _config), do: :ok

  describe "permanent deletion committed after Pause was authorized" do
    test "wins: Pause changes nothing and the queued deletion completes", f do
      result =
        authorized_then(fn -> Upstreams.pause_account_for_scope(f.owner_scope, f.identity.id, %{}) end, fn ->
          assert {:ok, _removed} = PoolAssignments.delete_pool_assignment(f.served.id, f.assignment.id)
          assert {:deleting, _receipt} = Upstreams.delete_account_for_scope(f.owner_scope, f.identity.id)
          Repo.get!(UpstreamIdentity, f.identity.id)
        end)

      assert {{:error, %{code: :upstream_account_deleting}}, deleting} = result
      assert deleting.status == "deleted"
      assert Repo.get!(UpstreamIdentity, f.identity.id) == deleting
      assert :ok = perform_job(UpstreamDeletionWorker, %{upstream_identity_id: f.identity.id, requested_by_user_id: f.owner.id})
      refute Repo.get(UpstreamIdentity, f.identity.id)
    end

    test "control: the same held Pause succeeds when nothing is committed in between", f do
      assert {{:ok, %{status: :paused}}, :idle} = authorized_then(fn -> Upstreams.pause_account_for_scope(f.owner_scope, f.identity.id, %{}) end, fn -> :idle end)
      assert Repo.get!(UpstreamIdentity, f.identity.id).status == "paused"
      assert Repo.get!(PoolUpstreamAssignment, f.assignment.id).status == "paused"
    end
  end

  describe "a Pool attached after the lifecycle call was authorized" do
    test "Pause by an operator without the new Pool is denied and nothing is paused", f do
      {result, attached} = authorized_then(fn -> Upstreams.pause_account_for_scope(f.admin_scope, f.identity.id, %{}) end, fn -> attach!(f.other, f.identity) end)

      assert {:error, %{code: :capability_denied}} = result
      assert Repo.get!(UpstreamIdentity, f.identity.id) == Repo.reload!(f.identity)
      assert Repo.get!(UpstreamIdentity, f.identity.id).status == "active"
      assert Repo.get!(PoolUpstreamAssignment, attached.id).status == "active"
      assert Repo.get!(PoolUpstreamAssignment, f.assignment.id).status == "active"
    end

    test "control: an operator of both Pools pauses both, and so does the owner", f do
      operator_pool_assignment_fixture(f.admin, f.other, created_by_user_id: f.owner.id)

      {result, attached} = authorized_then(fn -> Upstreams.pause_account_for_scope(f.admin_scope, f.identity.id, %{}) end, fn -> attach!(f.other, f.identity) end)

      assert {:ok, %{status: :paused}} = result
      assert Repo.get!(PoolUpstreamAssignment, attached.id).status == "paused"
      assert Repo.get!(PoolUpstreamAssignment, f.assignment.id).status == "paused"

      assert {:ok, %{status: :active}} = Upstreams.reactivate_account_for_scope(f.owner_scope, f.identity.id, %{})
      assert {:ok, %{status: :paused}} = Upstreams.pause_account_for_scope(f.owner_scope, f.identity.id, %{})
    end

    test "control: without an attachment the single-Pool operator pauses the account", f do
      assert {{:ok, %{status: :paused}}, :idle} = authorized_then(fn -> Upstreams.pause_account_for_scope(f.admin_scope, f.identity.id, %{}) end, fn -> :idle end)
    end

    test "Reactivate by an operator without the new Pool is denied and nothing is reactivated", f do
      assert {:ok, %{status: :paused}} = Upstreams.pause_account_for_scope(f.owner_scope, f.identity.id, %{})
      paused = Repo.get!(UpstreamIdentity, f.identity.id)

      {result, attached} = authorized_then(fn -> Upstreams.reactivate_account_for_scope(f.admin_scope, f.identity.id, %{}) end, fn -> attach_row!(f.other, f.identity) end)

      assert {:error, %{code: :capability_denied}} = result
      assert Repo.get!(UpstreamIdentity, f.identity.id) == paused
      assert Repo.get!(PoolUpstreamAssignment, attached.id).status == attached.status
      assert Repo.get!(PoolUpstreamAssignment, f.assignment.id).status == "paused"
    end
  end

  defp authorized_then(lifecycle_call, interleaved) do
    test_pid = self()

    task =
      Task.async(fn ->
        Process.put(@barrier, {test_pid, 0})
        lifecycle_call.()
      end)

    assert_receive {:authorized, held}, 5_000
    assert held == task.pid
    between = interleaved.()
    send(held, :resume)
    {Task.await(task, 5_000), between}
  end

  defp attach!(pool, identity) do
    assignment = attach_row!(pool, identity)
    assert {:ok, active} = PoolAssignments.activate_pool_assignment(assignment)
    active
  end

  defp attach_row!(pool, identity) do
    assert {:ok, assignment} = PoolAssignments.create_pool_assignment(pool, identity)
    assignment
  end
end
