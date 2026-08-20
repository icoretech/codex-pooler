defmodule CodexPooler.Access.APIKeyRuntimeAuthorizationTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  describe "existing persisted API key authorization" do
    test "preserves active, paused, revoked, and missing dispositions" do
      {scope, pool} = owner_scope_and_pool()

      %{api_key: active_key, raw_key: active_raw_key} =
        active_api_key_fixture(pool, %{scope: scope})

      %{api_key: paused_key, raw_key: paused_raw_key} =
        active_api_key_fixture(pool, %{scope: scope, display_name: "Paused runtime key"})

      %{api_key: revoked_key, raw_key: revoked_raw_key} =
        active_api_key_fixture(pool, %{scope: scope, display_name: "Revoked runtime key"})

      assert {:ok, _paused_key} = Access.pause_api_key(scope, paused_key)
      assert {:ok, _revoked_key} = Access.revoke_api_key(scope, revoked_key)

      assert {:ok, %{api_key_id: api_key_id}} = Access.authenticate_api_key(active_raw_key)
      assert api_key_id == active_key.id
      assert {:error, %{code: :api_key_paused}} = Access.authenticate_api_key(paused_raw_key)
      assert {:error, %{code: :api_key_revoked}} = Access.authenticate_api_key(revoked_raw_key)
      assert {:error, %{code: :api_key_missing}} = Access.authenticate_api_key("sk-cxp-missing")
    end
  end

  describe "runtime authorization" do
    test "captures and authorizes a matching active epoch inside the caller transaction" do
      {scope, pool} = owner_scope_and_pool()
      %{api_key: api_key} = active_api_key_fixture(pool, %{scope: scope})
      counts_before = lifecycle_counts()

      assert {:ok, {:ok, 0}} =
               Repo.transaction(fn -> Access.capture_api_key_runtime_epoch(api_key.id) end)

      assert {:ok, {:ok, %{api_key: authorized_key, runtime_revocation_epoch: 0}}} =
               Repo.transaction(fn -> Access.authorize_api_key_runtime_turn(api_key.id, 0) end)

      assert authorized_key.id == api_key.id
      assert lifecycle_counts() == counts_before
    end

    test "returns safe paused, revoked, missing, and internal stale dispositions without side effects" do
      {scope, pool} = owner_scope_and_pool()
      %{api_key: active_key} = active_api_key_fixture(pool, %{scope: scope})

      %{api_key: paused_key} =
        active_api_key_fixture(pool, %{
          scope: scope,
          display_name: "Paused runtime authorization key"
        })

      %{api_key: revoked_key} =
        active_api_key_fixture(pool, %{
          scope: scope,
          display_name: "Revoked runtime authorization key"
        })

      assert {:ok, paused_key} = Access.pause_api_key(scope, paused_key)
      assert {:ok, revoked_key} = Access.revoke_api_key(scope, revoked_key)

      counts_before = lifecycle_counts()
      stale_paused_key = %{paused_key | status: "active"}
      stale_revoked_key = %{revoked_key | status: "active"}

      assert {:ok, {:error, %{code: :api_key_paused, disabling_epoch: 1}}} =
               Repo.transaction(fn ->
                 Access.authorize_api_key_runtime_turn(stale_paused_key, 0)
               end)

      assert {:ok, {:error, %{code: :api_key_revoked, disabling_epoch: 1}}} =
               Repo.transaction(fn ->
                 Access.authorize_api_key_runtime_turn(stale_revoked_key, 0)
               end)

      assert {:ok, {:error, %{code: :api_key_missing}}} =
               Repo.transaction(fn ->
                 Access.authorize_api_key_runtime_turn(Ecto.UUID.generate(), 0)
               end)

      assert {:ok,
              {:error, %{code: :api_key_runtime_epoch_stale, disabling_epoch: 0} = stale_error}} =
               Repo.transaction(fn ->
                 Access.authorize_api_key_runtime_turn(active_key.id, 1)
               end)

      refute inspect(stale_error) =~ "sk-cxp-"
      assert lifecycle_counts() == counts_before
    end

    test "derives the next epoch only for an effective disabling status change" do
      {scope, pool} = owner_scope_and_pool()
      %{api_key: active_key} = active_api_key_fixture(pool, %{scope: scope})

      %{api_key: paused_key} =
        active_api_key_fixture(pool, %{scope: scope, display_name: "Paused epoch key"})

      assert {:ok, paused_key} = Access.pause_api_key(scope, paused_key)

      assert Access.api_key_runtime_epoch_for_status_change(active_key, "active") == 0
      assert Access.api_key_runtime_epoch_for_status_change(active_key, "paused") == 1
      assert Access.api_key_runtime_epoch_for_status_change(active_key, "revoked") == 1
      assert Access.api_key_runtime_epoch_for_status_change(paused_key, "paused") == 1
      assert Access.api_key_runtime_epoch_for_status_change(paused_key, "revoked") == 2
      assert Access.api_key_runtime_epoch_for_status_change(paused_key, "active") == 1
    end
  end

  defp lifecycle_counts do
    %{
      attempts: Repo.aggregate(Attempt, :count),
      codex_sessions: Repo.aggregate(CodexSession, :count),
      codex_turns: Repo.aggregate(CodexTurn, :count),
      ledger_entries: Repo.aggregate(LedgerEntry, :count),
      requests: Repo.aggregate(Request, :count)
    }
  end

  defp owner_scope_and_pool do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner, ["instance_owner"])

    assert {:ok, pool} =
             Pools.create_pool(scope, %{
               slug: "runtime-epoch-#{System.unique_integer([:positive])}",
               name: "Runtime epoch test pool"
             })

    {scope, pool}
  end
end
