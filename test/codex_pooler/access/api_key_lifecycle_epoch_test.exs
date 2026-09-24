defmodule CodexPooler.Access.APIKeyLifecycleEpochTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Events
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.AccountsFixtures

  @tag :replay_api_key_delete
  @tag :replay_lock_order
  test "API key deletion refreshes a post-snapshot session drift before deleting" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner, ["instance_owner"])
    pool = create_pool!(scope, "delete-drift")
    api_key = create_api_key!(scope, pool, "delete drift")
    auth = %{pool: pool, api_key: api_key}
    barrier = make_ref()
    parent = self()

    Application.put_env(:codex_pooler, :api_key_delete_test_barrier, %{
      test_pid: parent,
      ref: barrier,
      block_attempts_left: [3]
    })

    on_exit(fn -> Application.delete_env(:codex_pooler, :api_key_delete_test_barrier) end)

    delete_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        Access.delete_api_key(scope, api_key)
      end)

    assert_receive {:api_key_delete_session_snapshot, ^barrier, delete_pid, 3, []}

    assert {:ok, session} =
             Websocket.start_codex_session(auth, %{
               accepted_turn_state: Ecto.UUID.generate()
             })

    send(delete_pid, {:release_api_key_delete_snapshot, barrier})

    assert_receive {:api_key_delete_session_snapshot, ^barrier, ^delete_pid, 2, session_ids}
    assert session_ids == [session.id]
    assert {:ok, deleted} = Task.await(delete_task, 15_000)
    assert deleted.id == api_key.id
    assert Repo.get(APIKey, api_key.id) == nil
    assert Repo.get(CodexPooler.Gateway.Persistence.CodexSession, session.id) == nil
  end

  @tag :replay_api_key_delete
  @tag :replay_lock_order
  test "API key deletion returns deterministic conflict after bounded session drift retries" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner, ["instance_owner"])
    pool = create_pool!(scope, "delete-bounded-drift")
    api_key = create_api_key!(scope, pool, "delete bounded drift")
    auth = %{pool: pool, api_key: api_key}
    barrier = make_ref()
    parent = self()

    Application.put_env(:codex_pooler, :api_key_delete_test_barrier, %{
      test_pid: parent,
      ref: barrier,
      block_attempts_left: [3, 2, 1]
    })

    on_exit(fn -> Application.delete_env(:codex_pooler, :api_key_delete_test_barrier) end)

    delete_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        Access.delete_api_key(scope, api_key)
      end)

    inserted_session_ids =
      for attempts_left <- [3, 2, 1] do
        assert_receive {:api_key_delete_session_snapshot, ^barrier, delete_pid, ^attempts_left, _session_ids}

        assert {:ok, session} =
                 Websocket.start_codex_session(auth, %{
                   accepted_turn_state: Ecto.UUID.generate()
                 })

        send(delete_pid, {:release_api_key_delete_snapshot, barrier})
        session.id
      end

    assert {:error, %{code: :api_key_delete_conflict}} = Task.await(delete_task, 15_000)
    assert Repo.get!(APIKey, api_key.id).id == api_key.id

    assert Repo.all(
             from session in CodexPooler.Gateway.Persistence.CodexSession,
               where: session.id in ^inserted_session_ids,
               order_by: [asc: session.id],
               select: session.id
           ) == Enum.sort(inserted_session_ids)
  end

  @tag :replay_api_key_delete
  test "API key deletion propagates a non-retryable replay close error unchanged" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner, ["instance_owner"])
    pool = create_pool!(scope, "delete-replay-error")
    api_key = create_api_key!(scope, pool, "delete replay error")
    error = {:request_replay_close_failed, :synthetic_non_retryable}

    Application.put_env(
      :codex_pooler,
      :api_key_delete_replay_close_test_override,
      fn _api_key_id -> {:error, error} end
    )

    on_exit(fn ->
      Application.delete_env(:codex_pooler, :api_key_delete_replay_close_test_override)
    end)

    assert {:error, ^error} = Access.delete_api_key(scope, api_key)
    assert Repo.get!(APIKey, api_key.id).id == api_key.id
  end

  describe "disabling lifecycle epochs" do
    test "rotation replaces the secret and fences each previously captured epoch even with stale structs" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      scope = Scope.for_user(owner, ["instance_owner"])
      pool = create_pool!(scope, "rotation")

      assert {:ok, %{api_key: original, raw_key: old_secret}} =
               Access.create_api_key(scope, pool, %{display_name: "Rotation lifecycle key"})

      assert {:ok, %{api_key: rotated, raw_key: new_secret}} =
               Access.rotate_api_key(scope, original)

      assert {:error, _} = Access.authenticate_authorization_header("Bearer " <> old_secret)
      assert {:ok, _} = Access.authenticate_authorization_header("Bearer " <> new_secret)
      assert rotated.runtime_revocation_epoch == 1
    end

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

    test "pool move plus disable publishes once to the source pool and once to the canonical new pool" do
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

          assert Enum.sort(Enum.map(lifecycle_events, & &1.pool_id)) ==
                   Enum.sort([source_pool.id, target_pool.id])

          # Both Pools receive the same paused/epoch payload: an idle socket on the
          # source Pool latches on exactly these fields.
          for pool <- [source_pool, target_pool] do
            event = Enum.find(lifecycle_events, &(&1.pool_id == pool.id))

            assert event.payload == %{
                     "api_key_id" => api_key.id,
                     "pool_id" => target_pool.id,
                     "runtime_revocation_epoch" => 1,
                     "status" => "paused"
                   }
          end
        end
      end)
    end

    # A move with an unchanged active status is the admin form's and the Pool
    # wizard's shape; it is not a disabling transition, so it must still reach
    # both Pools through the reread-required path, on the generic and the
    # policy update alike (the two notify helpers are separate copies).
    test "pure pool move publishes an active api_key_updated to both pools on both update paths" do
      Sandbox.unboxed_run(Repo, fn ->
        {scope, source_pool} = owner_scope_and_pool()
        target_pool = create_pool!(scope, "puremove")
        assert :ok = Events.subscribe_pool(source_pool.id, "pools")
        assert :ok = Events.subscribe_pool(target_pool.id, "pools")

        scenarios = [
          {"generic pure move", fn api_key -> Access.update_api_key(scope, api_key, %{pool_id: target_pool.id}) end},
          {"policy pure move",
           fn api_key ->
             Access.update_api_key_with_policy(scope, api_key, %{pool_id: target_pool.id})
           end}
        ]

        for {label, mutation} <- scenarios do
          api_key = create_api_key!(scope, source_pool, label)
          assert {:ok, result} = publish_from_task(fn -> mutation.(api_key) end)
          updated_api_key = api_key_from_result(result)

          assert updated_api_key.pool_id == target_pool.id
          assert updated_api_key.status == "active"
          assert updated_api_key.runtime_revocation_epoch == 1

          events = receive_events_before_barriers([source_pool.id, target_pool.id])
          lifecycle_events = Enum.filter(events, &api_key_event?(&1, api_key.id))

          assert Enum.sort(Enum.map(lifecycle_events, & &1.pool_id)) ==
                   Enum.sort([source_pool.id, target_pool.id]),
                 label

          for pool <- [source_pool, target_pool] do
            event = Enum.find(lifecycle_events, &(&1.pool_id == pool.id))
            assert event.reason == "api_key_updated", label

            assert event.payload == %{
                     "api_key_id" => api_key.id,
                     "pool_id" => target_pool.id,
                     "runtime_revocation_epoch" => 1,
                     "status" => "active"
                   },
                   label
          end
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

  # An open socket judges a turn against the key it read at the upgrade: the
  # allowed and enforced model, the reasoning-effort policy and the enforced
  # service tier. An edit of any of them advances the runtime epoch, so every
  # open socket of the key closes and reconnects under the new policy
  # (findings#206 row 206-484). Limits, bindings and the active-request cap
  # are read again by every reservation and leave the epoch alone.
  describe "policy edit epochs" do
    test "an edit of a field the upgrade reads advances the epoch once and prompts a reread on both update paths" do
      Sandbox.unboxed_run(Repo, fn ->
        {scope, pool} = owner_scope_and_pool()
        assert :ok = Events.subscribe_pool(pool.id, "pools")

        scenarios = [
          {"generic allowed models", fn api_key -> Access.update_api_key(scope, api_key, %{status: "active", allowed_model_identifiers: ["gpt-alpha"]}) end},
          {"policy allowed models", fn api_key -> Access.update_api_key_with_policy(scope, api_key, %{status: "active", model_mode: "selected_models", allowed_model_identifiers: ["gpt-alpha"]}) end},
          {"policy enforced model", fn api_key -> Access.update_api_key_with_policy(scope, api_key, %{status: "active", enforced_model_identifier: "gpt-alpha"}) end},
          {"policy maximum effort", fn api_key -> Access.update_api_key_with_policy(scope, api_key, %{status: "active", maximum_reasoning_effort: "medium"}) end},
          {"policy enforced effort", fn api_key -> Access.update_api_key_with_policy(scope, api_key, %{status: "active", enforced_reasoning_effort: "low"}) end},
          {"policy service tier", fn api_key -> Access.update_api_key_with_policy(scope, api_key, %{status: "active", enforced_service_tier: "flex"}) end}
        ]

        for {label, mutation} <- scenarios do
          api_key = create_api_key!(scope, pool, label)
          assert {:ok, result} = publish_from_task(fn -> mutation.(api_key) end)

          assert api_key_from_result(result).runtime_revocation_epoch == 1, label
          assert %APIKey{status: "active", runtime_revocation_epoch: 1} = Repo.get!(APIKey, api_key.id)
          assert_lifecycle_event(api_key.id, "api_key_updated", "active", 1)
          assert latest_update_audit(api_key.id).details["runtime_revocation_epoch_advanced"] == true, label
        end
      end)
    end

    test "limits, the active-request cap, a rename and an unchanged resubmit keep the epoch" do
      Sandbox.unboxed_run(Repo, fn ->
        {scope, pool} = owner_scope_and_pool()

        scenarios = [
          {"policy limits", %{status: "active", default_policy: %{max_input_tokens_per_request: 1, max_tokens_per_day: 10}, model_policies: [%{model_identifier: "gpt-alpha", max_requests_per_minute: 1}]}},
          {"policy active cap", %{status: "active", max_active_requests: 1}},
          {"policy rename", %{status: "active", display_name: "Renamed lifecycle key", model_mode: "all_models"}},
          {"policy unchanged", %{status: "active"}},
          {"generic active cap", {:generic, %{status: "active", max_active_requests: 1}}},
          {"generic dashboard access", {:generic, %{dashboard_access: true}}}
        ]

        for {label, attrs} <- scenarios do
          api_key = create_api_key!(scope, pool, label)

          assert {:ok, _result} =
                   (case attrs do
                      {:generic, attrs} -> Access.update_api_key(scope, api_key, attrs)
                      attrs -> Access.update_api_key_with_policy(scope, api_key, attrs)
                    end)

          assert Repo.get!(APIKey, api_key.id).runtime_revocation_epoch == 0, label
          assert latest_update_audit(api_key.id).details["runtime_revocation_epoch_advanced"] == false, label
        end

        # The allow list is a set: the same models resubmitted in another order
        # grant nothing new.
        assert {:ok, %{api_key: selected}} =
                 Access.create_api_key(scope, pool, %{display_name: "Lifecycle reordered key", model_mode: "selected_models", allowed_model_identifiers: ["gpt-alpha", "gpt-beta"]})

        assert {:ok, _reordered} =
                 Access.update_api_key_with_policy(scope, selected, %{status: "active", model_mode: "selected_models", allowed_model_identifiers: ["gpt-beta", "gpt-alpha"]})

        assert Repo.get!(APIKey, selected.id).runtime_revocation_epoch == 0
      end)
    end

    test "a policy edit that also pauses or moves the key advances the epoch once" do
      Sandbox.unboxed_run(Repo, fn ->
        {scope, pool} = owner_scope_and_pool()
        target_pool = create_pool!(scope, "policy-move")

        scenarios = [
          {"pause", %{status: "paused", model_mode: "selected_models", allowed_model_identifiers: ["gpt-alpha"]}},
          {"move", %{status: "active", pool_id: target_pool.id, maximum_reasoning_effort: "low"}}
        ]

        for {label, attrs} <- scenarios do
          api_key = create_api_key!(scope, pool, label)
          assert {:ok, result} = Access.update_api_key_with_policy(scope, api_key, attrs)
          assert api_key_from_result(result).runtime_revocation_epoch == 1, label
        end
      end)
    end
  end

  defp latest_update_audit(api_key_id) do
    Repo.one!(
      from event in CodexPooler.Audit.AuditEvent,
        where: event.target_id == ^api_key_id and event.action == "api_key.update",
        order_by: [desc: event.occurred_at],
        limit: 1
    )
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

  # Every caller runs inside `Sandbox.unboxed_run/2`, so this owner is committed. The committed
  # fixture registers its removal first, which also returns the bootstrap singleton to pending;
  # `bootstrap_owner_fixture/1` left both behind for the next file to find.
  defp owner_scope_and_pool do
    %{user: owner} = committed_bootstrap_owner_fixture!(%{"email" => unique_user_email()})
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
