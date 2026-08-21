defmodule CodexPooler.Admin.PoolTrafficGateTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Admin.PoolTrafficGate
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @tag :shared_pool_traffic_gate
  test "same operator processes share one PostgreSQL lane while different operators stay independent" do
    # Given
    first_user = create_committed_user!("shared-gate-first")
    second_user = create_committed_user!("shared-gate-second")
    on_exit(fn -> delete_committed_users!([first_user.id, second_user.id]) end)

    first_scope = Scope.for_user(first_user, ["instance_owner"])
    second_scope = Scope.for_user(second_user, ["instance_owner"])
    first_token = Ecto.UUID.generate()
    test_pid = self()

    first_task =
      Task.async(fn ->
        unboxed(fn ->
          PoolTrafficGate.run(first_scope, first_token, fn ->
            send(test_pid, {:projection_entered, :first, self()})

            receive do
              :release_first -> :first_result
            end
          end)
        end)
      end)

    assert_receive {:projection_entered, :first, first_projection_pid}, 1_000

    # When: another PostgreSQL session for the same operator attempts to enter.
    same_operator_result =
      Task.async(fn ->
        unboxed(fn ->
          PoolTrafficGate.run(first_scope, Ecto.UUID.generate(), fn ->
            send(test_pid, {:projection_entered, :same_operator, self()})
            :unexpected
          end)
        end)
      end)
      |> Task.await(2_000)

    # Then: its callback is never entered, while another operator can enter.
    assert {:busy, retry_after_ms} = same_operator_result
    assert retry_after_ms > 0
    refute_received {:projection_entered, :same_operator, _pid}

    different_operator_task =
      Task.async(fn ->
        unboxed(fn ->
          PoolTrafficGate.run(second_scope, Ecto.UUID.generate(), fn ->
            send(test_pid, {:projection_entered, :different_operator, self()})

            receive do
              :release_different_operator -> :different_result
            end
          end)
        end)
      end)

    assert_receive {:projection_entered, :different_operator, different_projection_pid}, 1_000
    send(different_projection_pid, :release_different_operator)
    assert {:ok, :different_result, 1_000} = Task.await(different_operator_task, 2_000)

    send(first_projection_pid, :release_first)
    assert {:ok, :first_result, 1_000} = Task.await(first_task, 2_000)

    assert [[nil, nil, 1_000]] = gate_state(first_user.id)

    immediate_result =
      unboxed(fn ->
        PoolTrafficGate.run(first_scope, Ecto.UUID.generate(), fn ->
          send(test_pid, :immediate_projection_entered)
          :unexpected
        end)
      end)

    assert {:busy, immediate_retry_ms} = immediate_result
    assert immediate_retry_ms > 0
    refute_received :immediate_projection_entered

    expire_gate!(first_user.id)

    assert {:ok, :after_cooldown, 1_000} =
             unboxed(fn ->
               PoolTrafficGate.run(first_scope, Ecto.UUID.generate(), fn -> :after_cooldown end)
             end)
  end

  @tag :shared_pool_traffic_gate
  @tag capture_log: true
  test "crashed owner recovers through its lease and stale tokens cannot release the replacement" do
    # Given
    user = create_committed_user!("shared-gate-recovery")
    on_exit(fn -> delete_committed_users!([user.id]) end)

    scope = Scope.for_user(user, ["instance_owner"])
    stale_token = Ecto.UUID.generate()
    replacement_token = Ecto.UUID.generate()
    test_pid = self()

    {owner_pid, owner_monitor} =
      spawn_monitor(fn ->
        unboxed(fn ->
          PoolTrafficGate.run(scope, stale_token, fn ->
            send(test_pid, {:crash_owner_entered, self()})

            receive do
              :never_release -> :unexpected
            end
          end)
        end)
      end)

    assert_receive {:crash_owner_entered, _projection_pid}, 1_000

    # When: the owning process and checked-out connection disappear without finalization.
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_pid, :killed}, 5_000

    # Then: the row remains fail-closed until the database lease expires.
    assert [[^stale_token, true]] = gate_owner_state(user.id)

    assert {:busy, retry_after_ms} =
             unboxed(fn ->
               PoolTrafficGate.run(scope, Ecto.UUID.generate(), fn -> :unexpected end)
             end)

    assert retry_after_ms > 0
    expire_lease!(user.id)
    lock_release_task = await_stale_owner_lock_release(user.id, test_pid)

    assert_receive {:stale_owner_lock_released, lock_release_pid}, 5_000
    send(lock_release_pid, :release_stale_owner_lock)
    assert :ok = Task.await(lock_release_task, 5_000)

    replacement_task =
      Task.async(fn ->
        unboxed(fn ->
          PoolTrafficGate.run(scope, replacement_token, fn ->
            send(test_pid, {:replacement_entered, self()})

            receive do
              :release_replacement -> :replacement_result
            end
          end)
        end)
      end)

    assert_receive {:replacement_entered, replacement_projection_pid}, 5_000

    assert {:error, :stale_owner} =
             unboxed(fn -> PoolTrafficGate.finish(scope, stale_token) end)

    assert [[^replacement_token, true]] = gate_owner_state(user.id)

    send(replacement_projection_pid, :release_replacement)

    assert {:ok, :replacement_result, 1_000} =
             Task.await(replacement_task, 2_000)
  end

  @tag :shared_pool_traffic_gate
  test "projection errors finalize the shared cooldown and invalid scopes fail closed" do
    # Given
    user = create_committed_user!("shared-gate-error")
    on_exit(fn -> delete_committed_users!([user.id]) end)
    scope = Scope.for_user(user, ["instance_owner"])
    test_pid = self()

    # When/Then: a projection exception propagates only after fenced finalization.
    assert_raise RuntimeError, "projection failed", fn ->
      unboxed(fn ->
        PoolTrafficGate.run(scope, Ecto.UUID.generate(), fn ->
          raise "projection failed"
        end)
      end)
    end

    assert [[nil, nil, 1_000]] = gate_state(user.id)

    assert {:busy, retry_after_ms} =
             unboxed(fn ->
               PoolTrafficGate.run(scope, Ecto.UUID.generate(), fn ->
                 send(test_pid, :error_cooldown_bypassed)
               end)
             end)

    assert retry_after_ms > 0
    refute_received :error_cooldown_bypassed

    assert {:error, :gate_unavailable} =
             PoolTrafficGate.run(nil, Ecto.UUID.generate(), fn ->
               send(test_pid, :invalid_scope_entered)
             end)

    refute_received :invalid_scope_entered
  end

  defp create_committed_user!(label) do
    unique = System.unique_integer([:positive])
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    unboxed(fn ->
      Repo.insert!(%User{
        id: Ecto.UUID.generate(),
        email: "#{label}-#{unique}@example.com",
        password_hash: "test-password-hash",
        status: "active",
        password_change_required: false,
        created_at: now,
        updated_at: now
      })
    end)
  end

  defp delete_committed_users!(user_ids) do
    unboxed(fn ->
      Repo.query!("DELETE FROM users WHERE id = ANY($1::uuid[])", [dump_uuids(user_ids)])
    end)
  end

  defp gate_state(operator_id) do
    unboxed(fn ->
      Repo.query!(
        """
        SELECT owner_token::text,
               lease_expires_at,
               EXTRACT(EPOCH FROM (cooldown_until - updated_at))::integer * 1000
        FROM admin_pool_traffic_gates
        WHERE operator_id = $1::text::uuid
        """,
        [operator_id]
      ).rows
    end)
  end

  defp gate_owner_state(operator_id) do
    unboxed(fn ->
      Repo.query!(
        """
        SELECT owner_token::text, lease_expires_at > statement_timestamp()
        FROM admin_pool_traffic_gates
        WHERE operator_id = $1::text::uuid
        """,
        [operator_id]
      ).rows
    end)
  end

  defp expire_gate!(operator_id) do
    unboxed(fn ->
      Repo.query!(
        """
        UPDATE admin_pool_traffic_gates
        SET cooldown_until = statement_timestamp(), updated_at = statement_timestamp()
        WHERE operator_id = $1::text::uuid
        """,
        [operator_id]
      )
    end)
  end

  defp expire_lease!(operator_id) do
    unboxed(fn ->
      Repo.query!(
        """
        UPDATE admin_pool_traffic_gates
        SET lease_expires_at = statement_timestamp(), updated_at = statement_timestamp()
        WHERE operator_id = $1::text::uuid
        """,
        [operator_id]
      )
    end)
  end

  defp await_stale_owner_lock_release(operator_id, test_pid) do
    Task.async(fn -> hold_stale_owner_lock(operator_id, test_pid) end)
  end

  defp hold_stale_owner_lock(operator_id, test_pid) do
    unboxed(fn ->
      Repo.checkout(fn -> hold_stale_owner_lock_on_connection(operator_id, test_pid) end)
    end)
  end

  defp hold_stale_owner_lock_on_connection(operator_id, test_pid) do
    Repo.query!(
      """
      SELECT pg_advisory_lock(
        hashtextextended('admin_pool_traffic:' || $1::text, 0)
      )
      """,
      [operator_id]
    )

    send(test_pid, {:stale_owner_lock_released, self()})

    receive do
      :release_stale_owner_lock -> :ok
    end

    assert {:ok, %{rows: [[true]]}} =
             Repo.query(
               """
               SELECT pg_advisory_unlock(
                 hashtextextended('admin_pool_traffic:' || $1::text, 0)
               )
               """,
               [operator_id]
             )

    :ok
  end

  defp dump_uuids(ids), do: Enum.map(ids, &Ecto.UUID.dump!/1)
  defp unboxed(operation), do: Sandbox.unboxed_run(Repo, operation)
end
