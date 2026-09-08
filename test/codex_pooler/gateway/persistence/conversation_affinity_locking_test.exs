defmodule CodexPooler.Gateway.Persistence.ConversationAffinityLockingTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPooler.AccountsFixtures, only: [reset_bootstrap_state_fixture!: 0]

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.BridgeAffinity
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Pools
  alias Ecto.Adapters.SQL.Sandbox

  test "independent transactions share first reservation and fence a late old-account writer" do
    context = committed_context()

    parent = self()

    first =
      actor(fn ->
        Repo.transaction(fn ->
          plan = route(context)
          send(parent, {:first_reserved, plan, backend()})

          receive do
            :commit_first -> plan
          after
            10_000 -> flunk("first reservation not released")
          end
        end)
      end)

    assert_receive {:first_reserved, first_plan, first_backend}, 5000

    contender =
      actor(fn ->
        send(parent, {:contender_backend, backend()})
        route(%{context | candidates: Enum.reverse(context.candidates)})
      end)

    try do
      assert_receive {:contender_backend, second_backend}, 5000
      refute first_backend == second_backend
      await_blocked(second_backend, 200)
      send(first.pid, :commit_first)
      assert {:ok, ^first_plan} = Task.await(first)
      second_plan = Task.await(contender)
      assert second_plan.affinity.row.id == first_plan.affinity.row.id
      assert second_plan.selected_assignment_id == first_plan.selected_assignment_id
      assert second_plan.affinity.status == "reserved"
      refute second_plan.request_metadata["affinity_hit"]
      [a, b] = first_plan.candidates

      failover =
        actor(fn ->
          Repo.transaction(fn ->
            BridgeRing.record_success(second_plan, elem(b, 0), elem(b, 1))
            send(parent, :failover_written)

            receive do
              :commit_failover -> :ok
            after
              10_000 -> flunk("failover not released")
            end
          end)
        end)

      assert_receive :failover_written, 5000

      late =
        actor(fn ->
          send(parent, {:late_backend, backend()})
          BridgeRing.record_success(first_plan, elem(a, 0), elem(a, 1))
        end)

      try do
        assert_receive {:late_backend, late_backend}, 5000
        await_blocked(late_backend, 200)
        send(failover.pid, :commit_failover)
        assert {:ok, :ok} = Task.await(failover)
        assert :ok = Task.await(late)

        unboxed(fn ->
          row = Repo.get!(BridgeAffinity, first_plan.affinity.row.id)
          assert row.generation == 1
          assert row.pool_upstream_assignment_id == elem(b, 0).id
        end)

        after_restart = actor(fn -> route(context) end) |> Task.await()
        assert after_restart.selected_assignment_id == elem(b, 0).id
      after
        send(failover.pid, :commit_failover)
        Task.shutdown(failover, :brutal_kill)
        Task.shutdown(late, :brutal_kill)
      end
    after
      send(first.pid, :commit_first)
      Task.shutdown(first, :brutal_kill)
      Task.shutdown(contender, :brutal_kill)
      unboxed(fn -> reset_bootstrap_state_fixture!() end)
    end
  end

  test "completion waiting on affinity row cannot revive it after idle expiry" do
    context = committed_context()
    plan = unboxed(fn -> route(context) end)
    expires_at = DateTime.add(DateTime.utc_now(), 500, :millisecond)

    unboxed(fn ->
      Repo.update!(Ecto.Changeset.change(plan.affinity.row, expires_at: expires_at))
    end)

    parent = self()

    blocker =
      actor(fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from a in BridgeAffinity, where: a.id == ^plan.affinity.row.id, lock: "FOR UPDATE"
          )

          send(parent, :affinity_locked)

          receive do
            :unlock -> :ok
          after
            10_000 -> flunk("expiry lock not released")
          end
        end)
      end)

    assert_receive :affinity_locked, 5000

    completion =
      actor(fn ->
        send(parent, {:completion_backend, backend()})
        {assignment, identity} = hd(plan.candidates)
        BridgeRing.record_success(plan, assignment, identity)
      end)

    try do
      assert_receive {:completion_backend, backend}, 5000
      await_blocked(backend, 200)
      Process.sleep(max(DateTime.diff(expires_at, DateTime.utc_now(), :millisecond), 0) + 50)
      send(blocker.pid, :unlock)
      assert {:ok, :ok} = Task.await(blocker)
      assert :ok = Task.await(completion)

      unboxed(fn ->
        row = Repo.get!(BridgeAffinity, plan.affinity.row.id)
        assert row.expires_at == expires_at
        assert row.last_hit_at == nil
      end)
    after
      send(blocker.pid, :unlock)
      Task.shutdown(blocker, :brutal_kill)
      Task.shutdown(completion, :brutal_kill)
      unboxed(fn -> reset_bootstrap_state_fixture!() end)
    end
  end

  defp committed_context do
    unboxed(fn ->
      reset_bootstrap_state_fixture!()
      key = active_api_key_fixture()

      candidates =
        for _ <- 1..2 do
          %{assignment: assignment, identity: identity} =
            active_upstream_assignment_fixture(key.pool)

          {assignment, identity}
        end

      model = model_fixture(key.pool)

      Pools.ensure_routing_settings(key.pool)
      |> Ecto.Changeset.change(durable_conversation_affinity_enabled: true)
      |> Repo.update!()

      %{auth: %{pool: key.pool, api_key: key.api_key}, model: model, candidates: candidates}
    end)
  end

  defp route(context) do
    opts =
      RequestOptions.build(
        %{conversation_key: "synthetic-shared-thread"},
        "/backend-api/codex/responses",
        %{}
      )

    BridgeRing.plan_route(
      Map.merge(context, %{
        request_options: opts,
        route_plan_input: %RoutePlanInput{correlation_id: Ecto.UUID.generate()}
      })
    )
  end

  defp actor(fun), do: Task.async(fn -> unboxed(fun) end)
  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp backend do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp await_blocked(_backend, 0), do: flunk("competing transaction never waited on its row lock")

  defp await_blocked(backend, retries) do
    blocked =
      unboxed(fn ->
        %{rows: [[blocked]]} =
          Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

        blocked
      end)

    unless blocked do
      Process.sleep(10)
      await_blocked(backend, retries - 1)
    end
  end
end
