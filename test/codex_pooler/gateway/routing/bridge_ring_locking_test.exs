defmodule CodexPooler.Gateway.Routing.BridgeRingLockingTest do
  # Reproduces the 2026-07-22 production 40P01 schedule proven by the CNPG
  # deadlock DETAIL and Oban job 449798: reconciliation-style guards take the
  # identity row FOR UPDATE and then every assignment FOR UPDATE
  # (CredentialFencing.lock_credential_replacement), while post-turn routing
  # side effects insert rows whose FK checks lock the same pair through
  # statement-implicit order. The routing writers must take the canonical
  # identity-first reference locks so no cycle can form.
  use CodexPooler.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  alias CodexPooler.Gateway.Persistence.{BridgeAffinity, BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Gateway.Routing.{BridgeRing, CircuitState}
  alias CodexPooler.Repo

  import CodexPooler.AccountingTestSupport

  @actor_timeout 15_000
  @barrier_timeout 5_000
  @observer_deadline_ms 5_000

  test "record_success takes the canonical identity lock before touching the assignment" do
    fixture = committed_routing_fixture!()

    try do
      %{fencing: fencing, routing: routing, held_relations: held_relations} =
        run_schedule(fixture, :identity_first, fn ->
          BridgeRing.record_success(fixture.plan, fixture.assignment, fixture.identity)
        end)

      assert fencing == :ok
      assert routing == :ok

      refute "bridge_affinities" in held_relations
      refute_assignment_locks(held_relations)

      assert [%BridgeAffinity{} = affinity] = pool_rows(BridgeAffinity, fixture)
      assert affinity.pool_upstream_assignment_id == fixture.assignment.id
      assert affinity.upstream_identity_id == fixture.identity.id
    after
      cleanup_committed_fixture!(fixture)
    end
  end

  test "record_failure takes the canonical identity lock before touching the assignment" do
    fixture = committed_routing_fixture!()

    try do
      %{fencing: fencing, routing: routing, held_relations: held_relations} =
        run_schedule(fixture, :identity_first, fn ->
          BridgeRing.record_failure(
            fixture.plan,
            fixture.assignment,
            fixture.identity,
            "upstream_5xx"
          )
        end)

      assert fencing == :ok
      assert routing == "upstream_5xx"

      refute "bridge_demotions" in held_relations
      refute_assignment_locks(held_relations)

      assert [%BridgeDemotion{} = demotion] = pool_rows(BridgeDemotion, fixture)
      assert demotion.pool_upstream_assignment_id == fixture.assignment.id
      assert demotion.upstream_identity_id == fixture.identity.id
    after
      cleanup_committed_fixture!(fixture)
    end
  end

  test "circuit first-failure insert takes the canonical identity lock first" do
    fixture = committed_routing_fixture!()

    try do
      %{fencing: fencing, routing: routing, held_relations: held_relations} =
        run_schedule(fixture, :identity_first, fn ->
          CircuitState.record_failure(
            fixture.auth,
            fixture.model,
            fixture.assignment,
            "proxy_stream",
            "upstream_5xx"
          )
        end)

      assert fencing == :ok
      assert {:ok, %RoutingCircuitState{}} = routing

      # latest_for_update legitimately read-locks the circuit table before the
      # reference locks; the canonical contract only forbids holding any
      # assignment lock while waiting for the identity row.
      refute_assignment_locks(held_relations)

      assert [%RoutingCircuitState{} = state] = pool_rows(RoutingCircuitState, fixture)
      assert state.pool_upstream_assignment_id == fixture.assignment.id
    after
      cleanup_committed_fixture!(fixture)
    end
  end

  test "record_success converges without raising against an inverted assignment-first holder" do
    fixture = committed_routing_fixture!()

    try do
      %{fencing: fencing, routing: routing, held_relations: _held} =
        run_schedule(fixture, :assignment_first, fn ->
          BridgeRing.record_success(fixture.plan, fixture.assignment, fixture.identity)
        end)

      assert routing == :ok
      assert fencing in [:ok, {:deadlock, :deadlock_detected}]

      assert [%BridgeAffinity{} = affinity] = pool_rows(BridgeAffinity, fixture)
      assert affinity.pool_upstream_assignment_id == fixture.assignment.id
    after
      cleanup_committed_fixture!(fixture)
    end
  end

  defp run_schedule(fixture, fencing_order, routing_fun) do
    parent = self()
    release_ref = make_ref()

    fencing_task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          fencing_transaction(fixture, fencing_order, parent, release_ref)
        end)
      end)

    routing_task_holder = {__MODULE__, make_ref()}

    try do
      assert_receive {:fencing_first_lock_held, ^release_ref}, @barrier_timeout

      routing_task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            try do
              routing_fun.()
            rescue
              error in Postgrex.Error -> {:deadlock, error.postgres[:code]}
            end
          end)
        end)

      Process.put(routing_task_holder, routing_task)

      held_relations = await_lock_waiter!()

      send(fencing_task.pid, {:fencing_release, release_ref})

      fencing_result = Task.await(fencing_task, @actor_timeout)
      routing_result = Task.await(routing_task, @actor_timeout)

      %{fencing: fencing_result, routing: routing_result, held_relations: held_relations}
    after
      shutdown_task(fencing_task)
      shutdown_task(Process.delete(routing_task_holder))
    end
  end

  defp shutdown_task(%Task{pid: pid} = task) when is_pid(pid) do
    if Process.alive?(pid), do: Task.shutdown(task, :brutal_kill)
  end

  defp shutdown_task(_task), do: :ok

  defp refute_assignment_locks(held_relations) do
    refute Enum.any?(held_relations, &String.starts_with?(&1, "pool_upstream_assignments")),
           "waiter already holds assignment locks: #{inspect(held_relations)}"
  end

  # The same statements CredentialFencing.lock_credential_replacement issues,
  # sequenced explicitly so the second lock is requested only after the routing
  # writer is observed waiting. :assignment_first simulates a not-yet-audited
  # writer holding the pair in the inverted order.
  defp fencing_transaction(fixture, order, parent, release_ref) do
    identity_id = Ecto.UUID.dump!(fixture.identity.id)

    {first, second} =
      case order do
        :identity_first -> {&lock_identity!/1, &lock_assignments!/1}
        :assignment_first -> {&lock_assignments!/1, &lock_identity!/1}
      end

    Repo.transaction(fn ->
      first.(identity_id)
      send(parent, {:fencing_first_lock_held, release_ref})

      receive do
        {:fencing_release, ^release_ref} -> :ok
      after
        @actor_timeout -> raise "fencing release timed out"
      end

      second.(identity_id)
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Postgrex.Error -> {:deadlock, error.postgres[:code]}
  end

  defp lock_identity!(identity_id) do
    SQL.query!(
      Repo,
      "SELECT id FROM upstream_identities WHERE id = $1 FOR UPDATE",
      [identity_id]
    )
  end

  defp lock_assignments!(identity_id) do
    SQL.query!(
      Repo,
      "SELECT id FROM pool_upstream_assignments " <>
        "WHERE upstream_identity_id = $1 AND status != 'deleted' ORDER BY id FOR UPDATE",
      [identity_id]
    )
  end

  defp await_lock_waiter!(deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @observer_deadline_ms

    # Postgrex can pipeline BEGIN with the first statement, leaving the blocked
    # backend reported as `idle in transaction` with query `BEGIN`, so the
    # waiter is identified by its lock wait alone and the acquisition order is
    # proven from the locks it already holds.
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT pid FROM pg_stat_activity " <>
          "WHERE wait_event_type = 'Lock' AND datname = current_database()",
        []
      )

    case rows do
      [[pid] | _rest] ->
        %{rows: held} =
          SQL.query!(
            Repo,
            "SELECT relation::regclass::text FROM pg_locks " <>
              "WHERE pid = $1 AND granted AND relation IS NOT NULL",
            [pid]
          )

        Enum.map(held, fn [relation] -> relation end)

      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          %{rows: snapshot} =
            SQL.query!(
              Repo,
              "SELECT state, wait_event_type, wait_event, left(query, 90) " <>
                "FROM pg_stat_activity WHERE datname = current_database() " <>
                "AND pid <> pg_backend_pid() AND state <> 'idle'",
              []
            )

          flunk(
            "no backend entered a lock wait within #{@observer_deadline_ms}ms; " <>
              "non-idle activity: #{inspect(snapshot, printable_limit: 800)}"
          )
        else
          receive do
          after
            20 -> :ok
          end

          await_lock_waiter!(deadline)
        end
    end
  end

  defp committed_routing_fixture! do
    run_unboxed(fn ->
      unique = System.unique_integer([:positive])

      # Self-heal a fixed-version pricing row left over by an interrupted
      # earlier run; accounting_setup inserts it with a unique constraint.
      Repo.delete_all(
        from pricing in CodexPooler.Catalog.PricingSnapshot,
          where:
            pricing.price_version == "test-v1" and
              pricing.model_identifier == "provider-gpt-accounting-mini"
      )

      setup =
        accounting_setup(%{
          account_label: "Bridge ring locking #{unique}"
        })

      plan = %{
        affinity: %{
          enabled?: true,
          status: "miss",
          row: nil,
          kind: "codex_session",
          key_hash: :crypto.hash(:sha256, "bridge-ring-locking-#{unique}"),
          pool_id: setup.pool.id,
          api_key_id: setup.api_key.id,
          model_identifier: setup.model.exposed_model_id
        }
      }

      Map.put(setup, :plan, plan)
    end)
  end

  defp cleanup_committed_fixture!(fixture) do
    run_unboxed(fn ->
      for schema <- [BridgeAffinity, BridgeDemotion, RoutingCircuitState] do
        Repo.delete_all(from row in schema, where: row.pool_id == ^fixture.pool.id)
      end

      Repo.delete_all(
        from pool in CodexPooler.Pools.Pool,
          where: pool.id == ^fixture.pool.id
      )

      Repo.delete_all(
        from identity in CodexPooler.Upstreams.Schemas.UpstreamIdentity,
          where: identity.id == ^fixture.identity.id
      )

      Repo.delete_all(
        from pricing in CodexPooler.Catalog.PricingSnapshot,
          where: pricing.id == ^fixture.pricing.id
      )

      :ok
    end)
  end

  defp pool_rows(schema, fixture) do
    run_unboxed(fn ->
      Repo.all(from row in schema, where: row.pool_id == ^fixture.pool.id)
    end)
  end

  defp run_unboxed(operation) do
    Task.async(fn -> Sandbox.unboxed_run(Repo, operation) end)
    |> Task.await(@actor_timeout)
  end
end
