defmodule CodexPooler.Platform.CommittedPoolCleanupTest do
  @moduledoc """
  Locks `CodexPooler.PoolerFixtures.delete_committed_pools!/2`, the shared cleanup every committed
  Pool fixture delegates to.

  A committed fixture registers its cleanup before it commits, so the cleanup runs for a fixture
  that failed part way through and runs again when a test repeats it: it must be callable on ids
  whose Pools are already gone. It must also leave alone what another Pool still uses, because a
  test that deletes its own Pool runs while other committed fixtures of the same `mix test` hold
  identities and fixture owners of their own.

  `CodexPooler.Gateway.Runtime.CommittedGatewayFixtureCleanupTest` pins the gateway wrapper built
  on this helper; this one pins the helper itself.
  """
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounts.User
  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  test "an empty id list deletes no Pool" do
    before = Repo.aggregate(Pool, :count)

    assert delete_committed_pools!([]) == 0
    assert Repo.aggregate(Pool, :count) == before
  end

  test "a second call on the same ids deletes nothing more and does not raise" do
    pool = pool_fixture()
    %{identity: identity} = active_upstream_assignment_fixture(pool)

    job = Repo.insert!(TokenRefreshWorker.new(%{upstream_identity_id: identity.id}))

    assert delete_committed_pools!([pool.id]) == 1
    refute Repo.get(Pool, pool.id)
    refute Repo.get(Oban.Job, job.id)

    assert delete_committed_pools!([pool.id]) == 0
  end

  test "a Pool sharing the deleted Pool's identity keeps that identity's job" do
    deleted = pool_fixture()
    kept = pool_fixture()

    %{identity: shared} = active_upstream_assignment_fixture(deleted)
    %{identity: exclusive} = active_upstream_assignment_fixture(deleted)

    assert {:ok, kept_assignment} =
             PoolAssignments.create_pool_assignment(kept, shared, %{
               assignment_label: "Committed pool cleanup shared assignment"
             })

    shared_job = Repo.insert!(TokenRefreshWorker.new(%{upstream_identity_id: shared.id}))
    exclusive_job = Repo.insert!(TokenRefreshWorker.new(%{upstream_identity_id: exclusive.id}))

    assert delete_committed_pools!([deleted.id]) == 1

    assert Repo.get(Pool, kept.id)
    assert Repo.get(PoolUpstreamAssignment, kept_assignment.id)

    assert Repo.get(Oban.Job, shared_job.id),
           "the job of an identity another Pool still uses must survive that Pool's deletion"

    refute Repo.get(Oban.Job, exclusive_job.id)
  end

  test "a fixture owner another Pool's key still creates for survives, and goes with the last one" do
    deleted = pool_fixture()
    kept = pool_fixture()

    %{api_key: deleted_key} = api_key_fixture(deleted)
    %{api_key: kept_key} = api_key_fixture(kept)

    owner_id = deleted_key.created_by_user_id

    assert is_binary(owner_id)
    assert kept_key.created_by_user_id == owner_id

    assert delete_committed_pools!([deleted.id]) == 1
    refute Repo.get(APIKey, deleted_key.id)

    assert Repo.get(User, owner_id),
           "the fixture owner still creating another Pool's key must survive"

    assert delete_committed_pools!([kept.id]) == 1
    refute Repo.get(User, owner_id)
  end
end
