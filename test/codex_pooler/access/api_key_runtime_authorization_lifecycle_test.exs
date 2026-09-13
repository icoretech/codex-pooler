defmodule CodexPooler.Access.APIKeyRuntimeAuthorizationLifecycleTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures, only: [active_api_key_fixture: 2, model_fixture: 2]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  @endpoint "/backend-api/codex/responses"

  describe "runtime authorization dispositions" do
    test "an expired key is refused by the reader, reservation and capture modes" do
      scope = owner_scope()
      %{api_key: api_key} = active_api_key_fixture(pool_for!(scope), %{scope: scope})
      now = DateTime.utc_now()
      put_expiry!(api_key, DateTime.add(now, -1, :second))
      counts_before = lifecycle_counts()

      for authorize <- [
            &Access.authorize_api_key_runtime_turn_for_read/2,
            &Access.authorize_api_key_runtime_turn/2
          ] do
        assert {:ok, {:error, %{code: :api_key_expired, disabling_epoch: 0}}} =
                 Repo.transaction(fn -> authorize.(api_key.id, 0) end)
      end

      assert {:ok, {:error, %{code: :api_key_expired, disabling_epoch: 0}}} =
               Repo.transaction(fn -> Access.capture_api_key_runtime_epoch(api_key.id) end)

      assert lifecycle_counts() == counts_before
    end

    test "a key whose expiry is still ahead stays authorized" do
      scope = owner_scope()
      %{api_key: api_key} = active_api_key_fixture(pool_for!(scope), %{scope: scope})
      now = DateTime.utc_now()
      put_expiry!(api_key, DateTime.add(now, 3_600, :second))

      assert {:ok, {:ok, %{api_key: %APIKey{id: authorized_id}, runtime_revocation_epoch: 0}}} =
               Repo.transaction(fn ->
                 Access.authorize_api_key_runtime_turn_for_read(api_key.id, 0)
               end)

      assert authorized_id == api_key.id
    end

    test "a disabled or archived Pool refuses its keys as pool_inactive" do
      scope = owner_scope()

      for status <- ["disabled", "archived"] do
        pool = pool_for!(scope)
        %{api_key: api_key} = active_api_key_fixture(pool, %{scope: scope})
        assert {:ok, %{status: ^status}} = Pools.change_pool_status(scope, pool, status)
        counts_before = lifecycle_counts()

        for authorize <- [
              &Access.authorize_api_key_runtime_turn_for_read/2,
              &Access.authorize_api_key_runtime_turn/2
            ] do
          assert {:ok, {:error, %{code: :pool_inactive, disabling_epoch: 0} = error}} =
                   Repo.transaction(fn -> authorize.(api_key.id, 0) end)

          refute inspect(error) =~ "sk-cxp-"
        end

        assert lifecycle_counts() == counts_before
      end
    end

    test "a deleted key and a never-existing key are refused as missing with the captured epoch" do
      scope = owner_scope()
      %{api_key: api_key} = active_api_key_fixture(pool_for!(scope), %{scope: scope})
      assert {:ok, _deleted} = Access.delete_api_key(scope, api_key)

      for {api_key_id, captured_epoch} <- [{api_key.id, 0}, {Ecto.UUID.generate(), 7}] do
        for authorize <- [
              &Access.authorize_api_key_runtime_turn_for_read/2,
              &Access.authorize_api_key_runtime_turn/2
            ] do
          assert {:ok, {:error, %{code: :api_key_missing, disabling_epoch: ^captured_epoch}}} =
                   Repo.transaction(fn -> authorize.(api_key_id, captured_epoch) end)
        end
      end
    end

    test "deleting an archived Pool removes its keys, which are then refused as missing" do
      scope = owner_scope()
      pool = pool_for!(scope)
      %{api_key: api_key} = active_api_key_fixture(pool, %{scope: scope})
      assert {:ok, archived} = Pools.change_pool_status(scope, pool, "archived")
      assert {:ok, _deleted} = Pools.delete_archived_pool(scope, archived, archived.slug)

      assert {:ok, {:error, %{code: :api_key_missing, disabling_epoch: 0}}} =
               Repo.transaction(fn ->
                 Access.authorize_api_key_runtime_turn_for_read(api_key.id, 0)
               end)
    end
  end

  describe "moving a key to another Pool" do
    # The operator form always submits the key's status, so the key edit moves
    # the key with its unchanged status alongside the Pool; the Pool wizard
    # moves it through the policy update without one.
    for mover <- [:key_edit, :policy_edit, :pool_wizard] do
      test "a #{mover} move makes every authorization captured under the previous Pool stale" do
        mover = unquote(mover)
        scope = owner_scope()
        source_pool = pool_for!(scope)
        target_pool = pool_for!(scope)
        %{api_key: api_key} = active_api_key_fixture(source_pool, %{scope: scope})

        move!(mover, scope, api_key, target_pool)

        assert %APIKey{pool_id: pool_id, status: "active", runtime_revocation_epoch: 1} =
                 Repo.get!(APIKey, api_key.id)

        assert pool_id == target_pool.id

        for authorize <- [
              &Access.authorize_api_key_runtime_turn_for_read/2,
              &Access.authorize_api_key_runtime_turn/2
            ] do
          assert {:ok, {:error, %{code: :api_key_runtime_epoch_stale, disabling_epoch: 1}}} =
                   Repo.transaction(fn -> authorize.(api_key.id, 0) end)

          assert {:ok, {:ok, %{runtime_revocation_epoch: 1}}} =
                   Repo.transaction(fn -> authorize.(api_key.id, 1) end)
        end
      end
    end

    test "an edit that keeps the Pool keeps the epoch" do
      scope = owner_scope()
      pool = pool_for!(scope)
      %{api_key: api_key} = active_api_key_fixture(pool, %{scope: scope})

      move!(:key_edit, scope, api_key, pool)
      assert %APIKey{runtime_revocation_epoch: 0} = Repo.get!(APIKey, api_key.id)

      assert {:ok, {:ok, %{runtime_revocation_epoch: 0}}} =
               Repo.transaction(fn ->
                 Access.authorize_api_key_runtime_turn_for_read(api_key.id, 0)
               end)
    end

    test "a move that also pauses the key advances the epoch once" do
      scope = owner_scope()
      source_pool = pool_for!(scope)
      target_pool = pool_for!(scope)
      %{api_key: api_key} = active_api_key_fixture(source_pool, %{scope: scope})

      assert {:ok, %APIKey{status: "paused", runtime_revocation_epoch: 1}} =
               Access.update_api_key(scope, api_key, %{pool_id: target_pool.id, status: "paused"})
    end
  end

  describe "durable claim and reservation fences" do
    test "expired, pool-inactive and deleted keys are refused before any request, attempt or ledger row" do
      scope = owner_scope()

      for {invalidation, expected_code} <- [
            expired: :api_key_expired,
            pool_inactive: :pool_inactive,
            deleted: :api_key_missing
          ] do
        pool = pool_for!(scope)
        %{api_key: api_key} = active_api_key_fixture(pool, %{scope: scope})

        model =
          model_fixture(pool, %{exposed_model_id: "gpt-lifecycle-#{invalidation}"})

        auth = auth_context(pool, api_key)
        invalidate!(invalidation, scope, pool, api_key)
        counts_before = lifecycle_counts()

        assert {:error, %{code: ^expected_code, disabling_epoch: 0}} =
                 Accounting.claim_websocket_turn(auth, model, %{
                   correlation_id: "lifecycle-claim-#{invalidation}-#{unique()}",
                   endpoint: @endpoint,
                   requested_model: model.exposed_model_id,
                   runtime_revocation_epoch: 0
                 })

        assert {:error, %{code: ^expected_code, disabling_epoch: 0}} =
                 Accounting.reserve(
                   auth,
                   model,
                   %{"model" => model.exposed_model_id, "input" => "lifecycle"},
                   %{
                     correlation_id: "lifecycle-reserve-#{invalidation}-#{unique()}",
                     endpoint: @endpoint,
                     requested_model: model.exposed_model_id,
                     runtime_revocation_epoch: 0
                   }
                 )

        assert lifecycle_counts() == counts_before
      end
    end

    test "replay intent refuses an expired key and a key on a disabled Pool with their own codes" do
      for {invalidation, expected_code} <- [
            expired: :api_key_expired,
            pool_inactive: :pool_inactive
          ] do
        upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
        setup = gateway_setup(upstream)
        {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
        model_id = setup.model.exposed_model_id

        session_opts =
          replay_request_options(auth, %{}, model_id, "lifecycle-session-#{unique()}")

        assert {:ok, %CodexSession{} = session} =
                 Websocket.start_codex_session(auth, session_opts)

        payload = %{
          "type" => "response.create",
          "model" => model_id,
          "turn_id" => "lifecycle-intent-#{invalidation}",
          "input" => []
        }

        opts =
          auth
          |> replay_request_options(payload, model_id, "lifecycle-intent-#{unique()}")
          |> RequestOptions.put_continuity(codex_session: session)
          |> RequestOptions.capture_api_key_runtime_epoch(auth)

        assert {:ok, prepared} =
                 Service.prepare_websocket_response(
                   CodexPooler.JSON.encode!(payload),
                   opts,
                   fn _frame -> :ok end
                 )

        invalidate!(invalidation, key_owner_scope(setup.api_key), setup.pool, setup.api_key)
        counts_before = lifecycle_counts()

        assert {:error, %{code: ^expected_code, disabling_epoch: 0}} =
                 Service.prepare_replay_intent(auth, prepared)

        assert lifecycle_counts() == counts_before
        assert FakeUpstream.count(upstream) == 0
      end
    end
  end

  defp move!(:key_edit, scope, api_key, target_pool) do
    assert {:ok, %APIKey{}} =
             Access.update_api_key(scope, api_key, %{
               pool_id: target_pool.id,
               status: api_key.status
             })
  end

  defp move!(:policy_edit, scope, api_key, target_pool) do
    assert {:ok, %{api_key: %APIKey{}}} =
             Access.update_api_key_with_policy(scope, api_key, %{pool_id: target_pool.id})
  end

  defp move!(:pool_wizard, scope, api_key, target_pool),
    do: assert(:ok = Access.assign_api_keys_to_pool(scope, target_pool, [api_key.id]))

  defp invalidate!(:expired, _scope, _pool, api_key),
    do: put_expiry!(api_key, DateTime.add(DateTime.utc_now(), -1, :second))

  defp invalidate!(:pool_inactive, scope, pool, _api_key),
    do: assert({:ok, %{status: "disabled"}} = Pools.change_pool_status(scope, pool, "disabled"))

  defp invalidate!(:deleted, scope, _pool, api_key),
    do: assert({:ok, _deleted} = Access.delete_api_key(scope, api_key))

  # Moves the expiry without an operator event, the way the clock crossing it does.
  defp put_expiry!(api_key, expires_at) do
    assert {1, _rows} =
             Repo.update_all(from(key in APIKey, where: key.id == ^api_key.id),
               set: [expires_at: expires_at]
             )
  end

  defp auth_context(pool, api_key) do
    %{
      pool: pool,
      api_key: api_key,
      api_key_id: api_key.id,
      pool_id: pool.id,
      key_prefix: api_key.key_prefix
    }
  end

  defp replay_request_options(auth, payload, model, request_id) do
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)

    turn_claim_key =
      "codex-turn:" <> (:crypto.hash(:sha256, request_id) |> Base.url_encode64(padding: false))

    %{
      request_id: request_id,
      upstream_endpoint: @endpoint,
      transport: "websocket",
      websocket_writer: fn _frame -> :ok end,
      turn_claim_key: turn_claim_key,
      request_claim_key: turn_claim_key
    }
    |> RequestOptions.build(@endpoint, payload)
    |> RequestOptions.put_routing(
      requested_model: model,
      effective_model: model,
      api_key_policy: policy
    )
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

  defp key_owner_scope(api_key) do
    User
    |> Repo.get!(api_key.created_by_user_id)
    |> Scope.for_user(["instance_owner"])
  end

  # The bootstrap singleton admits one owner per test, so a test takes its
  # owner once and creates every Pool it needs under that scope.
  defp owner_scope do
    %{user: owner} = bootstrap_owner_fixture()
    Scope.for_user(owner, ["instance_owner"])
  end

  defp pool_for!(scope) do
    assert {:ok, pool} =
             Pools.create_pool(scope, %{
               slug: "runtime-lifecycle-#{unique()}",
               name: "Runtime lifecycle test pool"
             })

    pool
  end

  defp unique, do: System.unique_integer([:positive])
end
