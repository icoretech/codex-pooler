defmodule CodexPooler.Access.APIKeyLifecycleEpochTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.AccountsFixtures

  describe "disabling lifecycle epochs" do
    test "all disabling entry points advance the persisted epoch and emit one sanitized event" do
      Sandbox.unboxed_run(Repo, fn ->
        {scope, pool} = owner_scope_and_pool()
        assert :ok = Events.subscribe_pool(pool.id, "pools")

        scenarios = [
          {"pause", "api_key_status_updated",
           fn api_key ->
             Access.pause_api_key(scope, api_key)
           end},
          {"revoke", "api_key_revoked",
           fn api_key ->
             Access.revoke_api_key(scope, api_key)
           end},
          {"generic update", "api_key_updated",
           fn api_key ->
             Access.update_api_key(scope, api_key, %{status: "paused"})
           end},
          {"policy update", "api_key_updated",
           fn api_key ->
             Access.update_api_key_with_policy(scope, api_key, %{status: "paused"})
           end}
        ]

        for {label, reason, mutation} <- scenarios do
          api_key = create_api_key!(scope, pool, label)

          assert {:ok, result} = publish_from_task(fn -> mutation.(api_key) end)
          updated_api_key = api_key_from_result(result)

          assert %APIKey{status: status, runtime_revocation_epoch: 1} =
                   Repo.get!(APIKey, api_key.id)

          assert {Events,
                  %Events.Event{
                    pool_id: pool_id,
                    topics: ["pools"],
                    reason: ^reason,
                    payload: payload
                  }} = receive_event(api_key.id)

          assert pool_id == pool.id
          assert status == updated_api_key.status

          assert payload == %{
                   "api_key_id" => api_key.id,
                   "pool_id" => pool.id,
                   "runtime_revocation_epoch" => 1,
                   "status" => status
                 }
        end
      end)
    end

    test "paused to revoked advances again while stale structs use the locked persisted row" do
      Sandbox.unboxed_run(Repo, fn ->
        {scope, pool} = owner_scope_and_pool()
        assert :ok = Events.subscribe_pool(pool.id, "pools")
        stale_active_key = create_api_key!(scope, pool, "stale transition")

        assert {:ok, paused_key} =
                 publish_from_task(fn -> Access.pause_api_key(scope, stale_active_key.id) end)

        assert paused_key.runtime_revocation_epoch == 1
        assert_lifecycle_event(stale_active_key.id, "api_key_status_updated", "paused", 1)

        assert {:ok, revoked_key} =
                 publish_from_task(fn -> Access.revoke_api_key(scope, stale_active_key) end)

        assert revoked_key.status == "revoked"
        assert revoked_key.runtime_revocation_epoch == 2
        assert Repo.get!(APIKey, stale_active_key.id).runtime_revocation_epoch == 2
        assert_lifecycle_event(stale_active_key.id, "api_key_revoked", "revoked", 2)
      end)
    end

    test "generic and policy edits keep repeat and resume epochs stable then advance on revoke" do
      Sandbox.unboxed_run(Repo, fn ->
        {scope, pool} = owner_scope_and_pool()
        assert :ok = Events.subscribe_pool(pool.id, "pools")

        scenarios = [
          {"generic edit",
           fn api_key, status ->
             Access.update_api_key(scope, api_key, %{status: status})
           end},
          {"policy edit",
           fn api_key, status ->
             Access.update_api_key_with_policy(scope, api_key, %{status: status})
           end}
        ]

        for {label, mutation} <- scenarios do
          api_key = create_api_key!(scope, pool, label)

          assert {:ok, paused_result} =
                   publish_from_task(fn -> mutation.(api_key, "paused") end)

          assert api_key_from_result(paused_result).runtime_revocation_epoch == 1
          assert_lifecycle_event(api_key.id, "api_key_updated", "paused", 1)

          assert {:ok, repeated_result} =
                   publish_from_task(fn -> mutation.(api_key, "paused") end)

          assert api_key_from_result(repeated_result).runtime_revocation_epoch == 1
          refute_api_key_event_before_barrier(pool.id, api_key.id)

          assert {:ok, resumed_result} =
                   publish_from_task(fn -> mutation.(api_key, "active") end)

          assert api_key_from_result(resumed_result).runtime_revocation_epoch == 1
          refute_api_key_event_before_barrier(pool.id, api_key.id)

          assert {:ok, revoked_result} =
                   publish_from_task(fn -> mutation.(api_key, "revoked") end)

          assert api_key_from_result(revoked_result).runtime_revocation_epoch == 2
          assert_lifecycle_event(api_key.id, "api_key_updated", "revoked", 2)
        end
      end)
    end

    test "pool move plus disable publishes exactly once to the canonical new pool" do
      Sandbox.unboxed_run(Repo, fn ->
        {scope, source_pool} = owner_scope_and_pool()
        target_pool = create_pool!(scope, "target")
        assert :ok = Events.subscribe_pool(source_pool.id, "pools")
        assert :ok = Events.subscribe_pool(target_pool.id, "pools")

        scenarios = [
          {"generic move",
           fn api_key ->
             Access.update_api_key(scope, api_key, %{
               pool_id: target_pool.id,
               status: "paused"
             })
           end},
          {"policy move",
           fn api_key ->
             Access.update_api_key_with_policy(scope, api_key, %{
               pool_id: target_pool.id,
               status: "paused"
             })
           end}
        ]

        for {label, mutation} <- scenarios do
          api_key = create_api_key!(scope, source_pool, label)
          assert {:ok, result} = publish_from_task(fn -> mutation.(api_key) end)
          updated_api_key = api_key_from_result(result)

          assert updated_api_key.pool_id == target_pool.id
          assert updated_api_key.runtime_revocation_epoch == 1

          events = receive_events_before_barriers([source_pool.id, target_pool.id])
          lifecycle_events = Enum.filter(events, &api_key_event?(&1, api_key.id))

          assert [event] = lifecycle_events
          assert event.pool_id == target_pool.id

          assert event.payload == %{
                   "api_key_id" => api_key.id,
                   "pool_id" => target_pool.id,
                   "runtime_revocation_epoch" => 1,
                   "status" => "paused"
                 }
        end
      end)
    end

    test "repeat and resume transitions keep the epoch stable" do
      Sandbox.unboxed_run(Repo, fn ->
        {scope, pool} = owner_scope_and_pool()
        assert :ok = Events.subscribe_pool(pool.id, "pools")
        api_key = create_api_key!(scope, pool, "stable transition")

        assert {:ok, paused_key} =
                 publish_from_task(fn -> Access.pause_api_key(scope, api_key) end)

        assert paused_key.runtime_revocation_epoch == 1
        assert_lifecycle_event(api_key.id, "api_key_status_updated", "paused", 1)

        assert {:ok, repeated_pause} = Access.pause_api_key(scope, api_key)
        assert repeated_pause.status == "paused"
        assert repeated_pause.runtime_revocation_epoch == 1
        refute_api_key_event_before_barrier(pool.id, api_key.id)

        resume_listener = subscribe_from_task(pool.id)
        assert {:ok, resumed_key} = Access.resume_api_key(scope, api_key)
        assert resumed_key.status == "active"
        assert resumed_key.runtime_revocation_epoch == 1

        assert_lifecycle_event_from_task(
          resume_listener,
          api_key.id,
          "api_key_status_updated",
          "active",
          1
        )

        assert {:ok, paused_again} =
                 publish_from_task(fn -> Access.pause_api_key(scope, api_key) end)

        assert paused_again.runtime_revocation_epoch == 2
        assert_lifecycle_event(api_key.id, "api_key_status_updated", "paused", 2)

        assert Repo.get!(APIKey, api_key.id).runtime_revocation_epoch == 2
      end)
    end

    test "an outer rollback persists neither the disabling epoch nor its event" do
      Sandbox.unboxed_run(Repo, fn ->
        {scope, pool} = owner_scope_and_pool()
        assert :ok = Events.subscribe_pool(pool.id, "pools")
        api_key = create_api_key!(scope, pool, "rolled back transition")
        generic_api_key = create_api_key!(scope, pool, "rolled back generic transition")

        assert {:error, :intentional_rollback} =
                 Repo.transact(fn ->
                   assert {:ok, paused_key} = Access.pause_api_key(scope, api_key)
                   assert paused_key.runtime_revocation_epoch == 1

                   assert {:ok, generic_paused_key} =
                            Access.update_api_key(scope, generic_api_key, %{status: "paused"})

                   assert generic_paused_key.runtime_revocation_epoch == 1
                   {:error, :intentional_rollback}
                 end)

        assert %APIKey{status: "active", runtime_revocation_epoch: 0} =
                 Repo.get!(APIKey, api_key.id)

        assert %APIKey{status: "active", runtime_revocation_epoch: 0} =
                 Repo.get!(APIKey, generic_api_key.id)

        events_before_barrier = receive_events_before_barrier(pool.id)

        refute Enum.any?(events_before_barrier, fn
                 %Events.Event{payload: %{"api_key_id" => api_key_id}} ->
                   api_key_id in [api_key.id, generic_api_key.id]

                 _event ->
                   false
               end)
      end)
    end

    test "policy rollback persists neither its disabling epoch nor its event" do
      Sandbox.unboxed_run(Repo, fn ->
        {scope, pool} = owner_scope_and_pool()
        assert :ok = Events.subscribe_pool(pool.id, "pools")

        assert {:ok, %{api_key: api_key}} =
                 Access.create_api_key(scope, pool, %{
                   display_name: "Policy rollback lifecycle key",
                   model_mode: "selected_models",
                   allowed_model_identifiers: ["gpt-alpha"],
                   model_policies: [%{model_identifier: "gpt-alpha", max_tokens_per_day: 1000}]
                 })

        assert {:error, %Ecto.Changeset{}} =
                 Access.update_api_key_with_policy(scope, api_key, %{
                   status: "paused",
                   model_mode: "selected_models",
                   allowed_model_identifiers: ["gpt-alpha"],
                   model_policies: [%{model_identifier: "gpt-alpha", max_tokens_per_day: 0}]
                 })

        assert %APIKey{status: "active", runtime_revocation_epoch: 0} =
                 Repo.get!(APIKey, api_key.id)

        events_before_barrier = receive_events_before_barrier(pool.id)

        refute Enum.any?(events_before_barrier, fn
                 %Events.Event{payload: %{"api_key_id" => api_key_id}} -> api_key_id == api_key.id
                 _event -> false
               end)
      end)
    end
  end

  defp create_api_key!(scope, pool, label) do
    assert {:ok, %{api_key: api_key}} =
             Access.create_api_key(scope, pool, %{display_name: "Lifecycle #{label} key"})

    api_key
  end

  defp api_key_from_result(%APIKey{} = api_key), do: api_key
  defp api_key_from_result(%{api_key: %APIKey{} = api_key}), do: api_key

  defp assert_lifecycle_event(api_key_id, reason, status, epoch) do
    assert {Events,
            %Events.Event{
              topics: ["pools"],
              reason: ^reason,
              payload: %{
                "api_key_id" => ^api_key_id,
                "runtime_revocation_epoch" => ^epoch,
                "status" => ^status
              }
            }} = receive_event(api_key_id)
  end

  defp publish_from_task(fun) do
    fn -> Sandbox.unboxed_run(Repo, fun) end
    |> Task.async()
    |> Task.await(5_000)
  end

  defp subscribe_from_task(pool_id) do
    parent = self()

    task =
      Task.async(fn ->
        :ok = Events.subscribe_pool(pool_id, "pools")
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

  defp assert_lifecycle_event_from_task(listener, api_key_id, reason, status, epoch) do
    assert {Events,
            %Events.Event{
              topics: ["pools"],
              reason: ^reason,
              payload: %{
                "api_key_id" => ^api_key_id,
                "runtime_revocation_epoch" => ^epoch,
                "status" => ^status
              }
            }} = Task.await(listener, 5_000)
  end

  defp receive_event(api_key_id) do
    receive do
      {Events, %Events.Event{payload: %{"api_key_id" => ^api_key_id}}} = message -> message
    after
      5_000 -> flunk("timed out waiting for API-key lifecycle event")
    end
  end

  defp receive_events_before_barrier(pool_id) do
    barrier_id = publish_barrier(pool_id, fn operation -> operation.() end)

    collect_events_until_barrier(barrier_id, [])
  end

  defp receive_events_before_barriers(pool_ids) do
    barriers =
      Map.new(pool_ids, fn pool_id ->
        {publish_barrier(pool_id, &publish_from_task/1), pool_id}
      end)

    collect_events_until_barriers(barriers, [])
  end

  defp collect_events_until_barriers(barriers, events) when map_size(barriers) == 0,
    do: Enum.reverse(events)

  defp collect_events_until_barriers(barriers, events) do
    receive do
      {Events,
       %Events.Event{
         reason: "lifecycle_test_barrier",
         payload: %{"barrier_id" => barrier_id}
       }} ->
        collect_events_until_barriers(Map.delete(barriers, barrier_id), events)

      {Events, %Events.Event{} = event} ->
        collect_events_until_barriers(barriers, [event | events])
    after
      5_000 -> flunk("timed out waiting for lifecycle event barriers")
    end
  end

  defp refute_api_key_event_before_barrier(pool_id, api_key_id) do
    refute Enum.any?(receive_events_before_barrier(pool_id), &api_key_event?(&1, api_key_id))
  end

  defp api_key_event?(%Events.Event{payload: %{"api_key_id" => event_api_key_id}}, api_key_id),
    do: event_api_key_id == api_key_id

  defp api_key_event?(_event, _api_key_id), do: false

  defp publish_barrier(pool_id, transaction_runner) do
    barrier_id = Ecto.UUID.generate()

    assert {:ok, :barrier_published} =
             transaction_runner.(fn ->
               Repo.transact(fn ->
                 assert {:ok, _event} =
                          Events.broadcast_pool_event_after_commit(
                            pool_id,
                            ["pools"],
                            "lifecycle_test_barrier",
                            %{barrier_id: barrier_id}
                          )

                 {:ok, :barrier_published}
               end)
             end)

    barrier_id
  end

  defp collect_events_until_barrier(barrier_id, events) do
    receive do
      {Events,
       %Events.Event{
         reason: "lifecycle_test_barrier",
         payload: %{"barrier_id" => ^barrier_id}
       }} ->
        Enum.reverse(events)

      {Events, %Events.Event{} = event} ->
        collect_events_until_barrier(barrier_id, [event | events])
    after
      5_000 -> flunk("timed out waiting for lifecycle event barrier")
    end
  end

  defp owner_scope_and_pool do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner, ["instance_owner"])
    suffix = System.unique_integer([:positive])

    assert {:ok, pool} =
             Pools.create_pool(scope, %{
               slug: "lifecycle-epoch-#{suffix}",
               name: "Lifecycle epoch #{suffix}"
             })

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from event in CodexPooler.Audit.AuditEvent,
            where: event.pool_id == ^pool.id
        )

        Repo.delete_all(from pool_row in CodexPooler.Pools.Pool, where: pool_row.id == ^pool.id)
      end)
    end)

    {scope, pool}
  end

  defp create_pool!(scope, label) do
    suffix = System.unique_integer([:positive])

    assert {:ok, pool} =
             Pools.create_pool(scope, %{
               slug: "lifecycle-epoch-#{label}-#{suffix}",
               name: "Lifecycle epoch #{label} #{suffix}"
             })

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from event in CodexPooler.Audit.AuditEvent,
            where: event.pool_id == ^pool.id
        )

        Repo.delete_all(from pool_row in CodexPooler.Pools.Pool, where: pool_row.id == ^pool.id)
      end)
    end)

    pool
  end
end
