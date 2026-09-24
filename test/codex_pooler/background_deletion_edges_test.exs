defmodule CodexPooler.BackgroundDeletionEdgesTest do
  # The edges of the background Pool and API key deletion (findings#206 row 206-602): a
  # reactivation racing the scheduling on two connections, a job interrupted mid-run and run
  # again, the System Jobs explorer, and a runtime turn on a key whose deletion job is running.
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.APIKeys.Deletion, as: KeyDeletion
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Jobs.{APIKeyDeletionWorker, PoolDeletionWorker}
  alias CodexPooler.Jobs.ReadModel
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{Deletion, Pool}
  alias CodexPooler.Repo
  alias CodexPooler.TestAppEnv
  alias CodexPooler.UnboxedFixture
  alias CodexPoolerWeb.Admin.JobFilterForm
  alias CodexPoolerWeb.Admin.JobsPresentation
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @detection_budget_ms 15_000

  describe "a reactivation racing the deletion scheduling on two connections" do
    setup do
      %{user: owner} = committed_bootstrap_owner_fixture!()
      scope = Scope.for_user(owner, ["instance_owner"])

      pool =
        UnboxedFixture.run_unboxed(fn ->
          {:ok, pool} = Pools.create_pool(scope, %{slug: "race-#{System.unique_integer([:positive])}", name: "Race"})
          {:ok, pool} = Pools.change_pool_status(scope, pool, "archived")
          pool
        end)

      UnboxedFixture.register_unboxed_cleanup!(fn ->
        Repo.delete_all(from job in Oban.Job, where: fragment("?->>'pool_id'", job.args) == ^pool.id)
      end)

      %{owner: owner, scope: scope, pool: pool}
    end

    test "a reactivation that waits behind an uncommitted scheduling is refused", %{owner: owner, scope: scope, pool: pool} do
      {scheduler, scheduler_backend} = hold_uncommitted(fn -> Deletion.schedule(owner, pool) end)

      reactivation = unboxed_task(fn -> Pools.change_pool_status(scope, pool.id, "active") end)
      assert_receive {:backend, reactivation_backend}, @detection_budget_ms
      assert await_waiting_on!(reactivation_backend, scheduler_backend) == "pools"

      send(scheduler, :commit)
      assert {:deleting, %Pool{}} = await_holder(scheduler)
      assert {_backend, {:error, %{code: :pool_deletion_in_progress}}} = Task.await(reactivation, @detection_budget_ms)

      assert UnboxedFixture.run_unboxed(fn -> Repo.get!(Pool, pool.id).status end) == "archived"
    end

    test "a scheduling that waits behind an uncommitted reactivation schedules nothing", %{owner: owner, scope: scope, pool: pool} do
      {reactivator, reactivator_backend} = hold_uncommitted(fn -> Pools.change_pool_status(scope, pool.id, "active") end)

      scheduling = unboxed_task(fn -> Deletion.schedule(owner, pool) end)
      assert_receive {:backend, scheduling_backend}, @detection_budget_ms
      assert await_waiting_on!(scheduling_backend, reactivator_backend) == "pools"

      send(reactivator, :commit)
      assert {:ok, %Pool{status: "active"}} = await_holder(reactivator)
      assert {_backend, {:error, :pool_not_archived}} = Task.await(scheduling, @detection_budget_ms)

      assert UnboxedFixture.run_unboxed(fn ->
               Repo.aggregate(from(job in Oban.Job, where: fragment("?->>'pool_id'", job.args) == ^pool.id), :count)
             end) == 0
    end
  end

  test "a deletion job interrupted mid-run resumes, finishes once and audits once" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => "edges-resume@example.com"})
    scope = Scope.for_user(owner, ["instance_owner"])
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    request_ids = for _index <- 1..3, do: request_fixture(%{pool: pool, api_key: api_key}).id
    session!(pool, api_key)
    pool = pool |> Ecto.Changeset.change(status: "archived") |> Repo.update!()

    TestAppEnv.restore_on_exit(:pool_deletion_immediate_request_limit)
    Application.put_env(:codex_pooler, :pool_deletion_immediate_request_limit, 1)
    assert {:deleting, %Pool{}} = Pools.delete_archived_pool(scope, pool, pool.slug)
    assert [%Oban.Job{args: args}] = all_enqueued(worker: PoolDeletionWorker, args: %{"pool_id" => pool.id})

    # The run dies in the session batch after its request batches committed, as a killed node's
    # open batch transaction is rolled back by PostgreSQL.
    Repo.query!("""
    CREATE FUNCTION pg_temp.interrupt_session_delete() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'terminating connection due to administrator command' USING ERRCODE = 'admin_shutdown';
    END $$
    """)

    Repo.query!("CREATE TRIGGER interrupt_session_delete BEFORE DELETE ON codex_sessions FOR EACH ROW EXECUTE FUNCTION pg_temp.interrupt_session_delete()")

    assert {:error, _interrupted} = perform_job(PoolDeletionWorker, args)
    assert Repo.aggregate(from(r in "requests", where: r.id in type(^request_ids, {:array, :binary_id})), :count) == 0
    assert Repo.aggregate(from(s in CodexSession, where: s.pool_id == ^pool.id), :count) == 1
    assert Repo.get!(Pool, pool.id)
    assert pool_delete_audit_count(pool) == 0

    Repo.query!("DROP TRIGGER interrupt_session_delete ON codex_sessions")

    assert :ok = perform_job(PoolDeletionWorker, args)
    refute Repo.get(Pool, pool.id)
    assert pool_delete_audit_count(pool) == 1

    assert :ok = perform_job(PoolDeletionWorker, args)
    assert pool_delete_audit_count(pool) == 1
  end

  test "the System Jobs explorer lists both deletion jobs with their target and a readable name" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => "edges-explorer@example.com"})
    scope = Scope.for_user(owner, ["instance_owner"])
    pool = pool_fixture(%{status: "archived"})
    other_pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(other_pool)

    assert {:deleting, _pool} = Deletion.schedule(owner, pool)
    assert {:deleting, _api_key} = KeyDeletion.schedule(scope, api_key)

    {filters, _form_values, []} = JobFilterForm.parse_filters(%{})
    %{items: items} = ReadModel.list_explorer_jobs(scope, filters)

    assert %{target: %{pool_id: pool_id, pool_name: pool_name}} = Enum.find(items, &(&1.worker == "CodexPooler.Jobs.PoolDeletionWorker"))
    assert {pool_id, pool_name} == {pool.id, pool.name}

    assert %{target: %{api_key_id: api_key_id, api_key_label: label}} = Enum.find(items, &(&1.worker == "CodexPooler.Jobs.APIKeyDeletionWorker"))
    assert {api_key_id, label} == {api_key.id, api_key.display_name}

    assert JobsPresentation.job_worker_label("CodexPooler.Jobs.PoolDeletionWorker") == "Pool deletion"
    assert JobsPresentation.job_worker_label("CodexPooler.Jobs.APIKeyDeletionWorker") == "API key deletion"
  end

  test "a runtime turn on a key whose deletion job is running is refused and leaves no rows" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => "edges-runtime@example.com"})
    scope = Scope.for_user(owner, ["instance_owner"])
    pool = pool_fixture()
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture(pool)
    for _index <- 1..3, do: request_fixture(%{pool: pool, api_key: api_key})
    session!(pool, api_key)

    TestAppEnv.restore_on_exit(:api_key_deletion_immediate_request_limit)
    Application.put_env(:codex_pooler, :api_key_deletion_immediate_request_limit, 1)
    assert {:deleting, %APIKey{status: "revoked"}} = Access.delete_api_key(scope, api_key)
    assert [%Oban.Job{args: args}] = all_enqueued(worker: APIKeyDeletionWorker, args: %{"api_key_id" => api_key.id})

    # The job has detached the history but not yet removed the sessions.
    assert KeyDeletion.purge_history(api_key.id, System.monotonic_time(:millisecond) + 60_000) == :done
    counts_before = key_row_counts(api_key.id)

    assert {:error, %{code: code}} = Access.authenticate_api_key(raw_key)
    assert code in [:api_key_revoked, :invalid_api_key]

    assert {:ok, {:error, %{code: :api_key_revoked}}} =
             Repo.transaction(fn -> Access.authorize_api_key_runtime_turn(api_key.id, 0) end)

    assert key_row_counts(api_key.id) == counts_before

    assert :ok = perform_job(APIKeyDeletionWorker, args)

    assert {:ok, {:error, %{code: :api_key_missing}}} =
             Repo.transaction(fn -> Access.authorize_api_key_runtime_turn(api_key.id, 0) end)

    assert key_row_counts(api_key.id) == %{requests: 0, codex_sessions: 0, api_keys: 0}
  end

  # Runs `fun` inside an unboxed transaction left open until the test sends `:commit`.
  defp hold_uncommitted(fun) do
    parent = self()

    holder = spawn_link(fn -> send(parent, {:held_result, self(), hold_unboxed(fun, parent)}) end)

    assert_receive {:held, ^holder, backend}, @detection_budget_ms
    {holder, backend}
  end

  defp hold_unboxed(fun, parent),
    do: Sandbox.unboxed_run(Repo, fn -> Repo.transaction(fn -> run_and_hold(fun, parent) end) end)

  defp run_and_hold(fun, parent) do
    result = fun.()
    send(parent, {:held, self(), backend_pid!()})

    receive do
      :commit -> result
    after
      @detection_budget_ms -> Repo.rollback(:not_released)
    end
  end

  defp await_holder(holder) do
    assert_receive {:held_result, ^holder, {:ok, result}}, @detection_budget_ms
    result
  end

  # Runs `fun` on its own unboxed connection and reports that connection's backend first.
  defp unboxed_task(fun) do
    parent = self()

    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        backend = backend_pid!()
        send(parent, {:backend, backend})
        {backend, fun.()}
      end)
    end)
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp await_waiting_on!(waiter, blocker) do
    deadline = System.monotonic_time(:millisecond) + @detection_budget_ms
    await_waiting_on!(waiter, blocker, deadline)
  end

  defp await_waiting_on!(waiter, blocker, deadline) do
    rows =
      Sandbox.unboxed_run(Repo, fn ->
        SQL.query!(
          Repo,
          "SELECT query FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock' AND $2 = ANY(pg_blocking_pids(pid))",
          [waiter, blocker]
        ).rows
      end)

    relation =
      case rows do
        [[query]] -> with [_match, relation] <- Regex.run(~r/FROM "(\w+)"/, query), do: relation
        [] -> nil
      end

    cond do
      is_binary(relation) -> relation
      System.monotonic_time(:millisecond) >= deadline -> flunk("backend #{waiter} was not observed waiting on backend #{blocker}")
      true -> await_waiting_on!(waiter, blocker, deadline)
    end
  end

  defp session!(pool, api_key) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%CodexSession{
      pool_id: pool.id,
      api_key_id: api_key.id,
      session_key: "edges-session-#{System.unique_integer([:positive])}",
      status: "active",
      created_at: now,
      updated_at: now
    })
  end

  defp pool_delete_audit_count(pool),
    do: Repo.aggregate(from(event in AuditEvent, where: event.action == "pool.delete" and event.target_id == ^pool.id), :count)

  defp key_row_counts(api_key_id) do
    %{
      requests: Repo.aggregate(from(r in "requests", where: r.api_key_id == type(^api_key_id, :binary_id)), :count),
      codex_sessions: Repo.aggregate(from(s in CodexSession, where: s.api_key_id == ^api_key_id), :count),
      api_keys: Repo.aggregate(from(k in APIKey, where: k.id == ^api_key_id), :count)
    }
  end
end
