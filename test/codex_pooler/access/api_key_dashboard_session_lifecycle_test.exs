defmodule CodexPooler.Access.APIKeyDashboardSessionLifecycleTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access
  alias CodexPooler.Access.{APIKey, APIKeyDashboardSession}
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures, only: [request_fixture: 1]

  describe "API key lifecycle invalidation" do
    test "revoke removes sessions and emits sanitized key-specific invalidation" do
      fixture = opted_in_key_fixture("Revoke dashboard key")

      assert {:ok, revoked_key} =
               assert_invalidates(fixture, "api_key_revoked", "revoked", fn ->
                 Access.revoke_api_key(fixture.scope, fixture.api_key)
               end)

      assert revoked_key.id == fixture.api_key.id
    end

    test "rotation preserves the API key id while invalidating browser sessions" do
      fixture = opted_in_key_fixture("Rotate dashboard key")
      historical_request = request_fixture(fixture)

      assert {:ok, %{api_key: rotated_key, raw_key: new_raw_key}} =
               assert_invalidates(fixture, "api_key_rotated", "active", fn ->
                 Access.rotate_api_key(fixture.scope, fixture.api_key)
               end)

      assert rotated_key.id == fixture.api_key.id
      assert rotated_key.key_prefix != fixture.api_key.key_prefix
      assert Repo.get!(Request, historical_request.id).api_key_id == fixture.api_key.id
      assert {:ok, %{token: replacement_token}} = Access.issue_dashboard_session(new_raw_key)
      assert {:ok, _principal} = Access.authenticate_dashboard_session(replacement_token)
    end

    test "delete emits invalidation even though the foreign key also cascades sessions" do
      fixture = opted_in_key_fixture("Delete dashboard key")

      assert {:ok, deleted_key} =
               assert_invalidates(fixture, "api_key_deleted", "active", fn ->
                 Access.delete_api_key(fixture.scope, fixture.api_key)
               end)

      assert deleted_key.id == fixture.api_key.id
      assert Repo.get(APIKey, fixture.api_key.id) == nil
    end

    test "Pool reassignment invalidates sessions and identifies the canonical new Pool" do
      fixture = opted_in_key_fixture("Reassign dashboard key")
      target_pool = create_pool!(fixture.scope, "reassigned")

      assert :ok =
               assert_invalidates(
                 fixture,
                 "api_key_updated",
                 "active",
                 fn ->
                   Access.assign_api_keys_to_pool(
                     fixture.scope,
                     target_pool,
                     [fixture.api_key.id]
                   )
                 end,
                 target_pool.id
               )

      assert Repo.get!(APIKey, fixture.api_key.id).pool_id == target_pool.id
    end

    test "dashboard-access disable invalidates sessions through the policy API" do
      fixture = opted_in_key_fixture("Disable dashboard key")

      assert {:ok, %{api_key: disabled_key}} =
               assert_invalidates(fixture, "api_key_updated", "active", fn ->
                 Access.update_api_key_with_policy(fixture.scope, fixture.api_key, %{
                   "dashboard_access" => false
                 })
               end)

      assert disabled_key.dashboard_access == false
      assert Repo.get!(APIKey, fixture.api_key.id).dashboard_access == false
    end

    test "canonical expiry fails closed from a fresh Repo process without event delivery" do
      fixture = opted_in_key_fixture("Expired dashboard key")

      fixture.api_key
      |> APIKey.changeset(%{
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })
      |> Repo.update!()

      assert {:error, :invalid_dashboard_session} =
               authenticate_from_fresh_repo_process(fixture.browser_token)

      assert Repo.aggregate(
               from(session in APIKeyDashboardSession,
                 where: session.api_key_id == ^fixture.api_key.id
               ),
               :count,
               :id
             ) == 1
    end
  end

  defp assert_invalidates(fixture, cause, status, mutation, expected_pool_id \\ nil) do
    expected_pool_id = expected_pool_id || fixture.pool.id
    listener = subscribe_dashboard_events_from_task(fixture.api_key.id)

    result = mutation.()

    assert {Events,
            %Events.Event{
              pool_id: ^expected_pool_id,
              topics: ["dashboard_sessions"],
              reason: "dashboard_session_invalidated",
              payload: payload
            }} = Task.await(listener, 5_000)

    assert payload == %{
             "api_key_id" => fixture.api_key.id,
             "cause" => cause,
             "pool_id" => expected_pool_id,
             "status" => status
           }

    assert {:error, :invalid_dashboard_session} =
             authenticate_from_fresh_repo_process(fixture.browser_token)

    assert Repo.aggregate(
             from(session in APIKeyDashboardSession,
               where: session.api_key_id == ^fixture.api_key.id
             ),
             :count,
             :id
           ) == 0

    result
  end

  defp opted_in_key_fixture(display_name) do
    %{user: owner} = bootstrap_owner_fixture()
    scope = Scope.for_user(owner, ["instance_owner"])
    pool = create_pool!(scope, "source")

    assert {:ok, %{api_key: api_key, raw_key: raw_key}} =
             Access.create_api_key(scope, pool, %{
               display_name: display_name,
               dashboard_access: true
             })

    assert api_key.dashboard_access
    assert {:ok, %{token: browser_token}} = Access.issue_dashboard_session(raw_key)
    assert {:ok, _principal} = authenticate_from_fresh_repo_process(browser_token)

    %{
      scope: scope,
      pool: pool,
      api_key: api_key,
      browser_token: browser_token
    }
  end

  defp create_pool!(scope, label) do
    suffix = System.unique_integer([:positive])

    assert {:ok, pool} =
             Pools.create_pool(scope, %{
               slug: "dashboard-#{label}-#{suffix}",
               name: "Dashboard #{label} #{suffix}"
             })

    pool
  end

  defp subscribe_dashboard_events_from_task(api_key_id) do
    parent = self()

    task =
      Task.async(fn ->
        :ok = Events.subscribe_dashboard_sessions(api_key_id)
        send(parent, {:dashboard_event_listener_ready, self()})

        receive do
          message -> message
        after
          5_000 -> :event_timeout
        end
      end)

    assert_receive {:dashboard_event_listener_ready, listener_pid}
    assert listener_pid == task.pid
    task
  end

  defp authenticate_from_fresh_repo_process(browser_token) do
    sandbox_owner = self()

    task =
      Task.async(fn ->
        receive do
          :authenticate -> Access.authenticate_dashboard_session(browser_token)
        after
          5_000 -> {:error, :task_timeout}
        end
      end)

    Sandbox.allow(Repo, sandbox_owner, task.pid)
    send(task.pid, :authenticate)
    Task.await(task, 5_000)
  end
end
