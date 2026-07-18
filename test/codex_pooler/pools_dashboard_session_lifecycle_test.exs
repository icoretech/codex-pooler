defmodule CodexPooler.PoolsDashboardSessionLifecycleTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKeyDashboardSession
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.AccountsFixtures

  test "disabling a Pool deletes dashboard sessions and emits key-specific invalidation" do
    %{user: owner} = bootstrap_owner_fixture()
    scope = Scope.for_user(owner, ["instance_owner"])
    suffix = System.unique_integer([:positive])

    assert {:ok, pool} =
             Pools.create_pool(scope, %{
               slug: "dashboard-pool-disable-#{suffix}",
               name: "Dashboard Pool disable #{suffix}"
             })

    assert {:ok, %{api_key: api_key, raw_key: raw_key}} =
             Access.create_api_key(scope, pool, %{
               display_name: "Pool lifecycle dashboard key",
               dashboard_access: true
             })

    assert {:ok, %{token: browser_token}} = Access.issue_dashboard_session(raw_key)
    listener = subscribe_dashboard_events_from_task(api_key.id)

    assert {:ok, disabled_pool} = Pools.change_pool_status(scope, pool, "disabled")

    assert {Events,
            %Events.Event{
              pool_id: pool_id,
              topics: ["dashboard_sessions"],
              reason: "dashboard_session_invalidated",
              payload: payload
            }} = Task.await(listener, 5_000)

    assert pool_id == pool.id
    assert disabled_pool.status == "disabled"

    assert payload == %{
             "api_key_id" => api_key.id,
             "cause" => "pool_status_updated",
             "pool_id" => pool.id,
             "status" => api_key.status
           }

    assert {:error, :invalid_dashboard_session} =
             authenticate_from_fresh_repo_process(browser_token)

    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
    refute inspect(payload) =~ raw_key
    refute inspect(payload) =~ browser_token
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
