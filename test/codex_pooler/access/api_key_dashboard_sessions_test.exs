defmodule CodexPooler.Access.APIKeyDashboardSessionsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access
  alias CodexPooler.Access.{APIKey, APIKeyDashboardSession}
  alias CodexPooler.Access.APIKeys.TouchDebounce
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.AccountsFixtures

  describe "existing runtime API key contracts" do
    test "successful runtime authentication advances persisted last_used_at" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: api_key, raw_key: raw_key}} =
               Access.create_api_key(scope, pool, %{display_name: "Runtime touch key"})

      assert Repo.get!(APIKey, api_key.id).last_used_at == nil

      assert {:ok, %{api_key: authenticated_key}} = Access.authenticate_api_key(raw_key)
      assert %DateTime{} = authenticated_key.last_used_at
      assert :ok = TouchDebounce.flush()
      assert Repo.get!(APIKey, api_key.id).last_used_at == authenticated_key.last_used_at
    end

    test "pause keeps the existing sanitized pool lifecycle notification contract" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: api_key}} =
               Access.create_api_key(scope, pool, %{display_name: "Lifecycle event key"})

      listener = subscribe_from_task(pool.id, "pools")

      assert {:ok, paused_key} = Access.pause_api_key(scope, api_key)

      assert {Events,
              %Events.Event{
                pool_id: pool_id,
                topics: ["pools"],
                reason: "api_key_status_updated",
                payload: payload
              }} = Task.await(listener, 5_000)

      assert pool_id == pool.id

      assert payload == %{
               "api_key_id" => api_key.id,
               "pool_id" => pool.id,
               "status" => paused_key.status
             }
    end
  end

  describe "dashboard session boundary" do
    test "issues and authenticates a digest-only session without runtime side effects" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: api_key, raw_key: raw_key}} =
               Access.create_api_key(scope, pool, %{display_name: "Observatory key"})

      api_key = enable_dashboard_access!(api_key)
      issued_after = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, %{token: browser_token, expires_at: expires_at}} =
               Access.issue_dashboard_session(raw_key)

      assert is_binary(browser_token)
      assert byte_size(browser_token) >= 43
      assert DateTime.diff(expires_at, issued_after, :second) in 1_209_599..1_209_600

      assert %APIKeyDashboardSession{} =
               session =
               Repo.get_by!(APIKeyDashboardSession, api_key_id: api_key.id)

      assert session.token_hash == :crypto.hash(:sha256, browser_token)
      refute inspect(session) =~ browser_token
      refute inspect(session) =~ raw_key

      assert {:ok, principal} = Access.authenticate_dashboard_session(browser_token)

      assert Map.keys(Map.from_struct(principal)) |> Enum.sort() ==
               [:api_key_id, :display_name, :key_prefix, :pool_id]

      assert principal.api_key_id == api_key.id
      assert principal.pool_id == pool.id
      assert principal.display_name == api_key.display_name
      assert principal.key_prefix == api_key.key_prefix
      assert is_nil(Map.get(principal, :api_key))
      assert is_nil(Map.get(principal, :pool))
      refute Map.has_key?(Map.from_struct(principal), :key_hash)
      refute Map.has_key?(Map.from_struct(principal), :policy)
      refute Map.has_key?(Map.from_struct(principal), :owner)
      refute inspect(principal) =~ browser_token
      refute inspect(principal) =~ raw_key

      handoff = Access.dashboard_session_handoff(browser_token)
      assert Map.keys(handoff) == [:dashboard_session_id]
      assert handoff.dashboard_session_id == session.id
      assert {:ok, ^principal} = Access.authenticate_dashboard_session_handoff(handoff)

      assert {:error, :invalid_dashboard_session} =
               handoff
               |> Map.put(:token_hash, "forbidden-extra-field")
               |> Access.authenticate_dashboard_session_handoff()

      assert {:error, :invalid_dashboard_session} =
               Access.authenticate_dashboard_session(handoff.dashboard_session_id)

      assert Repo.get!(APIKey, api_key.id).last_used_at == nil
      assert Repo.aggregate(Request, :count, :id) == 0
    end

    test "pause deletes the session, emits a key-specific event, and fails from a fresh Repo process" do
      {scope, pool} = owner_scope_and_pool()

      assert {:ok, %{api_key: api_key, raw_key: raw_key}} =
               Access.create_api_key(scope, pool, %{display_name: "Remote invalidation key"})

      api_key = enable_dashboard_access!(api_key)

      assert {:ok, %{token: browser_token}} = Access.issue_dashboard_session(raw_key)
      assert {:ok, _principal} = authenticate_from_fresh_repo_process(browser_token)

      listener = subscribe_dashboard_events_from_task(api_key.id)

      assert {:ok, paused_key} = Access.pause_api_key(scope, api_key)

      assert {Events,
              %Events.Event{
                pool_id: pool_id,
                topics: ["dashboard_sessions"],
                reason: "dashboard_session_invalidated",
                payload: payload
              }} = Task.await(listener, 5_000)

      assert pool_id == pool.id

      assert payload == %{
               "api_key_id" => api_key.id,
               "cause" => "api_key_status_updated",
               "pool_id" => pool.id,
               "status" => paused_key.status
             }

      assert {:error, :invalid_dashboard_session} =
               authenticate_from_fresh_repo_process(browser_token)

      assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == 0
    end
  end

  defp subscribe_from_task(pool_id, topic) do
    parent = self()

    task =
      Task.async(fn ->
        :ok = Events.subscribe_pool(pool_id, topic)
        send(parent, {:event_listener_ready, self()})

        receive do
          message -> message
        after
          5_000 -> :event_timeout
        end
      end)

    assert_receive {:event_listener_ready, listener_pid}
    assert listener_pid == task.pid
    task
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

  defp enable_dashboard_access!(api_key) do
    api_key
    |> APIKey.changeset(%{dashboard_access: true})
    |> Repo.update!()
  end

  defp owner_scope_and_pool do
    %{user: owner} = bootstrap_owner_fixture()
    scope = Scope.for_user(owner, ["instance_owner"])
    suffix = System.unique_integer([:positive])

    assert {:ok, pool} =
             Pools.create_pool(scope, %{
               slug: "dashboard-session-#{suffix}",
               name: "Dashboard session #{suffix}"
             })

    {scope, pool}
  end
end
