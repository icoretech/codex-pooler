defmodule CodexPooler.Upstreams.ReadContractTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools.{Membership, OperatorPoolAssignment}
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  test "global management listing orders identities and forwards status filters" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner)
    pending = upstream_identity_fixture(%{account_label: "Zulu pending"})
    active = active_upstream_identity_fixture(%{account_label: "Alpha active"})

    assert Upstreams.list_upstream_identities() == [active, pending]
    assert Upstreams.list_upstream_identities(status: "pending") == [pending]

    assert {:ok, [^active, ^pending]} =
             Upstreams.list_upstream_identities_for_pool_management(scope)

    assert {:ok, [^active]} =
             Upstreams.list_upstream_identities_for_pool_management(scope, status: "active")

    assert Upstreams.get_upstream_identity(active.id) == active
    assert Upstreams.get_upstream_identity(Ecto.UUID.generate()) == nil
    assert Upstreams.get_upstream_identity(nil) == nil
  end

  test "admin visibility is deduplicated and excludes inaccessible and deleted rows" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{user: user} = operator_fixture(owner)
    first_pool = pool_fixture()
    second_pool = pool_fixture()
    disabled_pool = pool_fixture(%{status: "disabled"})
    operator_pool_assignment_fixture(user, first_pool)
    operator_pool_assignment_fixture(user, second_pool)
    operator_pool_assignment_fixture(user, disabled_pool)
    revoked_pool = pool_fixture()
    operator_pool_assignment_fixture(user, revoked_pool, %{status: "revoked"})

    %{identity: zulu} = upstream_assignment_fixture(first_pool, %{account_label: "Zulu"})
    {:ok, _} = PoolAssignments.create_pool_assignment(second_pool, zulu)

    %{identity: alpha} =
      upstream_assignment_fixture(second_pool, %{
        account_label: "Alpha",
        assignment_status: "paused"
      })

    upstream_assignment_fixture(disabled_pool)
    upstream_assignment_fixture(revoked_pool)
    upstream_assignment_fixture(pool_fixture())
    upstream_assignment_fixture(first_pool, %{identity_status: "deleted"})
    upstream_assignment_fixture(first_pool, %{assignment_status: "deleted"})

    scope = Scope.for_user(user)
    assert Upstreams.list_visible_upstream_identities(scope) == [alpha, zulu]

    assert {:error, %{code: :capability_denied}} =
             Upstreams.list_upstream_identities_for_pool_management(scope)

    Repo.update_all(from(a in OperatorPoolAssignment, where: a.user_id == ^user.id),
      set: [status: "revoked", revoked_at: DateTime.utc_now()]
    )

    assert Upstreams.list_visible_upstream_identities(scope) == []
  end

  test "revoked membership cannot reuse a cached owner role to list identities" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner)
    upstream_assignment_fixture()
    upstream_identity_fixture()

    Repo.update_all(from(m in Membership, where: m.user_id == ^owner.id),
      set: [status: "revoked", revoked_at: DateTime.utc_now()]
    )

    assert Upstreams.list_visible_upstream_identities(scope) == []

    assert {:error, %{code: :capability_denied}} =
             Upstreams.list_upstream_identities_for_pool_management(scope)
  end

  test "missing scopes cannot list management or visible account options" do
    upstream_assignment_fixture()
    upstream_identity_fixture()

    for scope <- [nil, %{}, %Scope{}] do
      assert Upstreams.list_visible_upstream_identities(scope) == []

      assert {:error, %{code: :capability_denied}} =
               Upstreams.list_upstream_identities_for_pool_management(scope)
    end
  end
end
