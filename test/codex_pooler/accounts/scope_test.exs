defmodule CodexPooler.Accounts.ScopeTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools.Membership

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  test "scope loads only the user's active roles and assignments in stable order" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{user: user} = operator_fixture(owner)
    first_pool = pool_fixture()
    second_pool = pool_fixture()
    now = DateTime.utc_now()
    later = operator_pool_assignment_fixture(user, second_pool, %{created_at: now})

    operator_pool_assignment_fixture(user, first_pool, %{
      created_at: DateTime.add(now, -1, :second)
    })

    operator_pool_assignment_fixture(user, pool_fixture(), %{status: "revoked"})
    operator_pool_assignment_fixture(owner, pool_fixture())

    %Membership{}
    |> Membership.changeset(%{
      user_id: user.id,
      role: "instance_owner",
      status: "revoked",
      created_at: now,
      revoked_at: now
    })
    |> Repo.insert!()

    scope = Scope.for_user(user)
    assert scope.user == user
    assert scope.roles == ["instance_admin"]
    assert scope.assigned_pool_ids == [first_pool.id, second_pool.id]

    later |> Ecto.Changeset.change(status: "revoked", revoked_at: now) |> Repo.update!()
    assert Scope.for_user(user).assigned_pool_ids == [first_pool.id]
  end

  test "explicit role projection filters non-strings and still reads persisted assignments" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    pool = pool_fixture()
    operator_pool_assignment_fixture(owner, pool)

    scope = Scope.for_user(owner, [nil, "instance_admin", :instance_owner, 1])
    assert scope.roles == ["instance_admin"]
    assert scope.assigned_pool_ids == [pool.id]
  end

  test "absent users have no scope" do
    assert Scope.for_user(nil) == nil
    assert Scope.for_user(nil, ["instance_owner"]) == nil
  end
end
