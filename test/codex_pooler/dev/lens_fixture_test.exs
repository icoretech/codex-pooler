defmodule CodexPooler.Dev.LensFixtureTest do
  use CodexPooler.DataCase, async: false
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounting.RequestLogs.ModelHistory
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Dev.LensFixture
  alias CodexPooler.Upstreams.Schemas.EncryptedSecret

  test "repeatable synthetic signals preserve existing history and never create upstream secrets" do
    scope = Scope.for_user(bootstrap_owner_fixture().user)
    existing = request_fixture(active_api_key_fixture())
    secrets = Repo.aggregate(EncryptedSecret, :count)
    first = LensFixture.seed!(scope)
    first.pool |> Ecto.Changeset.change(name: "Inspector demo (synthetic)") |> Repo.update!()
    second = LensFixture.seed!(scope)
    assert first.pool.id == second.pool.id
    assert second.pool.name == "Lens demo (synthetic)"
    assert second.path =~ "/admin/lens?"
    assert second.pool.status == "disabled"
    assert Repo.get!(Request, existing.id)
    assert Repo.aggregate(Attempt, :count) == 96
    assert Repo.aggregate(EncryptedSecret, :count) == secrets
    history = ModelHistory.for_scope(scope, %{"pool_id" => first.pool.id})
    assert %{total: 96, mismatches: 24, conflicts: 16, missing: 16, uncollected: 16} = history.counts
    assert length(history.attempts) == 32
    assert length(history.model_pairs) == 3
    assert Enum.sum(Enum.map(history.model_pairs, & &1.total)) == 32
    assert length(history.groups) == 3
    assert Enum.sum(Enum.map(history.groups, & &1.total)) == 32
    assert Enum.all?(history.groups, &(&1.mismatches > 0 or &1.conflicts > 0))
  end

  test "the command refuses the test environment before writes" do
    assert_raise Mix.Error, fn -> Mix.Tasks.Dev.LensFixture.run([]) end
  end
end
