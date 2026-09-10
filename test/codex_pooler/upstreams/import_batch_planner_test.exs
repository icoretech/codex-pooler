defmodule CodexPooler.Upstreams.ImportBatchPlannerTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, Request, RequestLogFact}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Events
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.ImportBatchPlanner
  alias CodexPooler.Upstreams.Lifecycle.IdentitySlotLock
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets
  alias CodexPooler.Upstreams.TokenLinking
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @detection_timeout_ms 15_000

  test "empty batch is a query-free no-op even without a transaction" do
    pool = pool_fixture()
    scope = owner_scope()
    handler = "batch-empty-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :repo, :query],
        fn _, _, _, pid ->
          send(pid, :repo_query)
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, []} = TokenLinking.link_prepared_batch_in_transaction(scope, pool, [])
    refute_received :repo_query

    assert {:ok, [], diagnostics} =
             ImportBatchPlanner.diagnose_prepared_batch_in_transaction(scope, pool, [])

    assert diagnostics == %{
             advisory_resources: [],
             candidate_loads: %{account: 0, email: 0},
             candidate_domains: %{account: 0, email: 0},
             expected_identity_count: 0,
             current_identity_count: 0,
             locked_identity_count: 0,
             locked_assignment_count: 0,
             locked_active_secret_count: 0
           }

    CodexPooler.TestDiagnostics.puts(
      "GREEN empty queries=0 resources=0 loads=0 locks=0 result=ok_empty"
    )
  end

  test "exact duplicate entries preflight once and the final input is authoritative" do
    pool = pool_fixture()
    scope = owner_scope()
    attrs = import_attrs("duplicate")

    assert {:ok, first} = Upstreams.prepare_bundle_account(scope, pool, attrs)

    assert {:ok, second} =
             Upstreams.prepare_bundle_account(
               scope,
               pool,
               %{attrs | token: "synthetic-access-last", refresh_token: "synthetic-refresh-last"}
             )

    {plan, diagnostics} = diagnose(scope, pool, [first, second])
    assert Enum.map(plan, &elem(&1, 1)) == [{:new, 0}, {:existing, projected_id(0)}]
    assert diagnostics.candidate_loads == %{account: 3, email: 3}
    assert diagnostics.locked_identity_count == 0

    before = counts()

    assert {:error, %{code: :batch_composition_required}} =
             Repo.transaction(fn ->
               IdentitySlotLock.lock_slots!([first.attrs, second.attrs])

               Enum.reduce_while([first, second], [], fn prepared, results ->
                 case TokenLinking.link_prepared_in_transaction(
                        scope,
                        pool,
                        prepared,
                        slots_locked?: true
                      ) do
                   {:ok, result} -> {:cont, [result | results]}
                   {:error, reason} -> Repo.rollback(reason)
                 end
               end)
             end)

    assert counts() == before

    assert {:ok, {:ok, [first_result, second_result]}} =
             Repo.transaction(fn ->
               TokenLinking.link_prepared_batch_in_transaction(scope, pool, [first, second])
             end)

    assert first_result.identity.id == second_result.identity.id

    assert {:ok, "synthetic-access-last"} =
             Secrets.decrypt_active_secret(second_result.identity, "access_token")

    assert {:ok, "synthetic-refresh-last"} =
             Secrets.decrypt_active_secret(second_result.identity, "refresh_token")

    assert Repo.aggregate(UpstreamIdentity, :count) == 1
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 1

    CodexPooler.TestDiagnostics.puts(
      "GREEN duplicate order=0,1 targets=new0,existing0 result=created,existing last_authoritative=true"
    )
  end

  test "distinct entries keep original dry-run and persistence order" do
    pool = pool_fixture()
    scope = owner_scope()

    prepared =
      prepare_many!(scope, pool, [import_attrs("distinct-a"), import_attrs("distinct-b")])

    {plan, diagnostics} = diagnose(scope, pool, prepared)
    assert Enum.map(plan, &elem(&1, 1)) == [{:new, 0}, {:new, 1}]
    assert diagnostics.candidate_loads == %{account: 3, email: 3}

    assert {:ok, {:ok, results}} =
             Repo.transaction(fn ->
               TokenLinking.link_prepared_batch_in_transaction(scope, pool, prepared)
             end)

    assert Enum.map(results, & &1.status) == [:created, :created]

    CodexPooler.TestDiagnostics.puts(
      "GREEN distinct order=0,1 targets=new0,new1 result=created,created dry_real_parity=true"
    )
  end

  test "legacy workspace adoption resolves to the witnessed identity" do
    pool = pool_fixture()
    scope = owner_scope()

    existing =
      active_upstream_assignment_fixture(pool, %{
        chatgpt_account_id: unique("legacy-account"),
        account_email: unique("legacy") <> "@example.com",
        workspace_id: nil,
        identity_metadata: %{}
      })

    attrs =
      import_attrs("legacy-adoption")
      |> Map.put(:chatgpt_account_id, existing.identity.chatgpt_account_id)
      |> Map.put(:account_email, existing.identity.account_email)
      |> Map.put(:workspace_id, unique("workspace"))

    assert {:ok, prepared} = Upstreams.prepare_bundle_account(scope, pool, attrs)
    {plan, _diagnostics} = diagnose(scope, pool, [prepared])
    assert [{_prepared, {:existing, existing_id}}] = plan
    assert existing_id == existing.identity.id

    assert {:ok, {:ok, [result]}} =
             Repo.transaction(fn ->
               TokenLinking.link_prepared_batch_in_transaction(scope, pool, [prepared])
             end)

    assert result.identity.id == existing.identity.id
    assert result.identity.workspace_id == attrs.workspace_id

    CodexPooler.TestDiagnostics.puts(
      "GREEN legacy_workspace order=0 target=existing result=existing"
    )
  end

  test "subjectless identity adoption resolves to the witnessed identity" do
    pool = pool_fixture()
    scope = owner_scope()

    existing =
      active_upstream_assignment_fixture(pool, %{
        chatgpt_account_id: unique("subjectless-account"),
        account_email: unique("subjectless") <> "@example.com",
        workspace_id: unique("subjectless-workspace"),
        chatgpt_user_id: nil,
        identity_metadata: %{}
      })

    attrs =
      import_attrs("subject-adoption")
      |> Map.put(:chatgpt_account_id, existing.identity.chatgpt_account_id)
      |> Map.put(:account_email, existing.identity.account_email)
      |> Map.put(:workspace_id, existing.identity.workspace_id)
      |> Map.put(:chatgpt_user_id, unique("subject"))

    assert {:ok, prepared} = Upstreams.prepare_bundle_account(scope, pool, attrs)
    {plan, _diagnostics} = diagnose(scope, pool, [prepared])
    assert [{_prepared, {:existing, existing_id}}] = plan
    assert existing_id == existing.identity.id

    assert {:ok, {:ok, [result]}} =
             Repo.transaction(fn ->
               TokenLinking.link_prepared_batch_in_transaction(scope, pool, [prepared])
             end)

    assert result.identity.id == existing.identity.id
    assert result.identity.chatgpt_user_id == attrs.chatgpt_user_id

    CodexPooler.TestDiagnostics.puts(
      "GREEN subjectless_subject order=0 target=existing result=existing"
    )
  end

  test "a stale later entry rejects the whole batch before mutation" do
    pool = pool_fixture()
    scope = owner_scope()
    first_attrs = import_attrs("stale-first")
    second_attrs = import_attrs("stale-second")

    assert {:ok, first} = Upstreams.prepare_bundle_account(scope, pool, first_attrs)
    assert {:ok, second} = Upstreams.prepare_bundle_account(scope, pool, second_attrs)
    assert {:ok, _fresh_result} = Upstreams.import_trusted_account(scope, pool, second_attrs)
    before = counts()
    :ok = Events.subscribe_pool(pool, ["upstreams"])

    assert {:error, %{code: :stale_import}} =
             Repo.transaction(fn ->
               case TokenLinking.link_prepared_batch_in_transaction(scope, pool, [first, second]) do
                 {:ok, results} -> results
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    assert counts() == before
    refute_received {Events, _event}

    assert Upstreams.get_upstream_identity_by_chatgpt_account(first_attrs.chatgpt_account_id) ==
             nil

    CodexPooler.TestDiagnostics.puts("GREEN stale_later error=stale_import deltas=zero")
  end

  test "an incompatible projected second entry rejects before the first mutation" do
    pool = pool_fixture()
    scope = owner_scope()
    account_id = unique("overlap-account")
    base = import_attrs("overlap") |> Map.put(:chatgpt_account_id, account_id)

    assert {:ok, first} =
             Upstreams.prepare_bundle_account(
               scope,
               pool,
               Map.put(base, :chatgpt_user_id, unique("subject"))
             )

    assert {:ok, second} =
             Upstreams.prepare_bundle_account(scope, pool, Map.put(base, :chatgpt_user_id, nil))

    before = counts()
    :ok = Events.subscribe_pool(pool, ["upstreams"])

    assert {:error, {:identity_conflict, :workspace_identity_mismatch, _safe}} =
             Repo.transaction(fn ->
               case TokenLinking.link_prepared_batch_in_transaction(scope, pool, [first, second]) do
                 {:ok, results} -> results
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    assert counts() == before
    refute_received {Events, _event}

    CodexPooler.TestDiagnostics.puts(
      "GREEN incompatible_overlap error=identity_conflict deltas=zero"
    )
  end

  test "diagnostics include the account closure reached through an email-only witness" do
    pool = pool_fixture()
    scope = owner_scope()

    existing =
      active_upstream_assignment_fixture(pool, %{
        chatgpt_account_id: unique("stored-account"),
        account_email: unique("stored-email") <> "@example.com",
        workspace_id: nil,
        identity_metadata: %{}
      })

    attrs =
      import_attrs("email-fallback")
      |> Map.put(:chatgpt_account_id, nil)
      |> Map.put(:account_email, existing.identity.account_email)
      |> Map.put(:workspace_id, nil)

    assert {:ok, prepared} = Upstreams.prepare_bundle_account(scope, pool, attrs)
    {plan, diagnostics} = diagnose(scope, pool, [prepared])

    assert [{_prepared, {:existing, existing_id}}] = plan
    assert existing_id == existing.identity.id
    assert length(diagnostics.advisory_resources) == 2
    assert diagnostics.advisory_resources == Enum.sort(diagnostics.advisory_resources)
    assert diagnostics.candidate_domains == %{account: 1, email: 1}
    assert diagnostics.candidate_loads == %{account: 3, email: 3}
    assert diagnostics.expected_identity_count == 1
    assert diagnostics.current_identity_count == 1
    assert diagnostics.locked_identity_count == 1
    assert diagnostics.locked_assignment_count == 1
    assert diagnostics.locked_active_secret_count == 1

    CodexPooler.TestDiagnostics.puts(
      "GREEN email_account_closure resources=#{Enum.join(diagnostics.advisory_resources, ",")} sorted=true domains=1,1 loads=3,3 identities=1 assignments=1 active_secrets=1"
    )
  end

  test "unexpected account closure reached from email fallback rejects before writes" do
    before = counts()

    candidate = %UpstreamIdentity{
      id: Ecto.UUID.generate(),
      chatgpt_account_id: unique("unexpected-account"),
      account_email: unique("unexpected-email") <> "@example.com"
    }

    resources =
      candidate
      |> Map.from_struct()
      |> IdentitySlotLock.advisory_resources()

    assert length(resources) == 2
    [first_resource, second_resource] = resources

    assert {:error, %{code: :stale_import}} =
             ImportBatchPlanner.validate_declared_closure([candidate], [first_resource])

    assert :ok =
             ImportBatchPlanner.validate_declared_closure(
               [candidate],
               Enum.sort([first_resource, second_resource])
             )

    assert counts() == before

    CodexPooler.TestDiagnostics.puts(
      "GREEN unexpected_closure error=stale_import missing_resource=true deltas=zero"
    )
  end

  test "email fallback rejects a concurrently inserted account resource outside its locked closure" do
    fixture = committed_email_account_fixture!()

    sentinel =
      Sandbox.unboxed_run(Repo, fn ->
        upstream_identity_fixture(%{
          chatgpt_account_id: unique("unrelated-sentinel"),
          account_email: unique("sentinel") <> "@example.com",
          account_label: "Unrelated sentinel",
          identity_metadata: %{"sentinel" => true}
        })
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from assignment in PoolUpstreamAssignment,
            where: assignment.pool_id == ^fixture.pool.id
        )

        Repo.delete_all(
          from identity in UpstreamIdentity,
            where: identity.account_email == ^fixture.identity.account_email
        )

        Repo.delete_all(
          from pool in CodexPooler.Pools.Pool,
            where: pool.id == ^fixture.pool.id
        )

        Repo.delete_all(
          from identity in UpstreamIdentity,
            where: identity.id == ^sentinel.id
        )
      end)
    end)

    parent = self()
    barrier = make_ref()
    :ok = Events.subscribe_pool(fixture.pool, ["upstreams"])
    before = unboxed_counts()

    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            pid = backend_pid!()

            existing =
              Repo.one!(
                from identity in UpstreamIdentity,
                  where: identity.id == ^fixture.identity.id,
                  lock: "FOR UPDATE"
              )

            send(parent, {barrier, :holder, :locked, pid})

            receive do
              {^barrier, :insert_sibling} ->
                sibling =
                  existing
                  |> Map.from_struct()
                  |> Map.drop([:__meta__, :id])
                  |> Map.put(:chatgpt_account_id, unique("late-account"))
                  |> Map.put(:created_at, DateTime.utc_now())
                  |> Map.put(:updated_at, DateTime.utc_now())
                  |> then(&struct!(UpstreamIdentity, &1))
                  |> Repo.insert!()

                sibling.id
            after
              @detection_timeout_ms -> raise "late sibling insertion timed out"
            end
          end)
        end)
      end)

    assert_receive {^barrier, :holder, :locked, holder_pid}, @detection_timeout_ms

    planner =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            pid = backend_pid!()
            send(parent, {barrier, :planner, :ready, pid})

            TokenLinking.link_prepared_batch_in_transaction(
              fixture.scope,
              fixture.pool,
              [fixture.email_prepared]
            )
          end)
        end)
      end)

    assert_receive {^barrier, :planner, :ready, planner_pid}, @detection_timeout_ms
    assert_waiting_on!(planner_pid, holder_pid)
    send(holder.pid, {barrier, :insert_sibling})

    assert {:ok, sibling_id} = Task.await(holder, @detection_timeout_ms)
    assert {:ok, {:error, %{code: :stale_import}}} = Task.await(planner, @detection_timeout_ms)

    after_counts = unboxed_counts()
    assert after_counts == %{before | identities: before.identities + 1}
    assert is_binary(sibling_id)
    refute_received {Events, _event}

    CodexPooler.TestDiagnostics.puts(
      "GREEN closure_race holder_pid=#{holder_pid} planner_pid=#{planner_pid} blocking=#{holder_pid} error=stale_import external_identity_delta=1 planner_other_deltas=zero pubsub=0"
    )

    assert {1, nil} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.delete_all(
                 from identity in UpstreamIdentity,
                   where:
                     identity.id == ^sibling_id and
                       identity.account_email == ^fixture.identity.account_email
               )
             end)

    restored_counts = unboxed_counts()
    assert restored_counts == before

    assert nil ==
             Sandbox.unboxed_run(Repo, fn -> Repo.get(UpstreamIdentity, sibling_id) end)

    restored_original =
      Sandbox.unboxed_run(Repo, fn -> Repo.get!(UpstreamIdentity, fixture.identity.id) end)

    assert restored_original.chatgpt_account_id == fixture.identity.chatgpt_account_id
    assert restored_original.account_email == fixture.identity.account_email

    restored_sentinel =
      Sandbox.unboxed_run(Repo, fn -> Repo.get!(UpstreamIdentity, sentinel.id) end)

    assert restored_sentinel.chatgpt_account_id == sentinel.chatgpt_account_id
    assert restored_sentinel.metadata == sentinel.metadata

    CodexPooler.TestDiagnostics.puts(
      "GREEN closure_race_cleanup restoration_observed=true external_mutation_removed_or_reverted=true unrelated_sentinel_survived=true restored_identity_delta=0 restored_other_deltas=zero"
    )
  end

  test "malformed current epoch rejects the whole batch before writes" do
    pool = pool_fixture()
    scope = owner_scope()

    existing =
      active_upstream_assignment_fixture(pool, %{
        chatgpt_account_id: unique("malformed-account"),
        identity_metadata: %{}
      })

    attrs =
      import_attrs("malformed")
      |> Map.put(:chatgpt_account_id, existing.identity.chatgpt_account_id)
      |> Map.put(:workspace_id, existing.identity.workspace_id)
      |> Map.put(:chatgpt_user_id, existing.identity.chatgpt_user_id)

    assert {:ok, prepared} = Upstreams.prepare_bundle_account(scope, pool, attrs)

    existing.identity
    |> Ecto.Changeset.change(metadata: %{"credential_epoch" => "invalid"})
    |> Repo.update!()

    before = counts()
    :ok = Events.subscribe_pool(pool, ["upstreams"])

    assert {:error, %{code: :invalid_credential_epoch}} =
             Repo.transaction(fn ->
               case TokenLinking.link_prepared_batch_in_transaction(scope, pool, [prepared]) do
                 {:ok, results} -> results
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    assert counts() == before
    refute_received {Events, _event}

    CodexPooler.TestDiagnostics.puts(
      "GREEN malformed_epoch error=invalid_credential_epoch deltas=zero"
    )
  end

  test "reverse-input complete batch plans serialize real backends without deadlock" do
    fixture = committed_batch_fixture!()
    parent = self()
    barrier = make_ref()

    try do
      holder = batch_plan_task(parent, barrier, :holder, fixture, fixture.prepared, true)
      assert_receive {^barrier, :holder, :planned, holder_pid}, @detection_timeout_ms

      waiter =
        batch_plan_task(parent, barrier, :waiter, fixture, Enum.reverse(fixture.prepared), false)

      assert_receive {^barrier, :waiter, :ready, waiter_pid}, @detection_timeout_ms

      assert_waiting_on!(waiter_pid, holder_pid)

      CodexPooler.TestDiagnostics.puts(
        "GREEN reverse_batch holder_pid=#{holder_pid} waiter_pid=#{waiter_pid} blocking=#{holder_pid}"
      )

      send(holder.pid, {barrier, :release})
      assert {:ok, :holder} = Task.await(holder, @detection_timeout_ms)
      assert {:ok, :waiter} = Task.await(waiter, @detection_timeout_ms)
      CodexPooler.TestDiagnostics.puts("GREEN reverse_batch terminal=ok,ok sqlstate_40P01=0")
    after
      cleanup_committed_batch_fixture!(fixture)
    end
  end

  defp owner_scope do
    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    Scope.for_user(user, ["instance_owner"])
  end

  defp import_attrs(label) do
    %{
      chatgpt_account_id: unique("account-#{label}"),
      chatgpt_user_id: nil,
      account_email: unique(label) <> "@example.com",
      account_label: "Synthetic #{label}",
      workspace_id: unique("workspace-#{label}"),
      workspace_label: "Synthetic workspace",
      seat_type: "member",
      plan_label: "team",
      token: "synthetic-access-#{label}",
      refresh_token: "synthetic-refresh-#{label}",
      credential_provenance: "codex_chatgpt_oauth",
      import_metadata: %{}
    }
  end

  defp counts do
    %{
      identities: Repo.aggregate(UpstreamIdentity, :count),
      assignments: Repo.aggregate(PoolUpstreamAssignment, :count),
      active_secrets:
        Repo.aggregate(from(secret in EncryptedSecret, where: secret.status == "active"), :count),
      superseded_secrets:
        Repo.aggregate(
          from(secret in EncryptedSecret, where: secret.status == "superseded"),
          :count
        ),
      total_secrets: Repo.aggregate(EncryptedSecret, :count),
      audits: Repo.aggregate(AuditEvent, :count),
      jobs: Repo.aggregate(Oban.Job, :count),
      requests: Repo.aggregate(Request, :count),
      attempts: Repo.aggregate(Attempt, :count),
      request_logs: Repo.aggregate(RequestLogFact, :count)
    }
  end

  defp unboxed_counts, do: Sandbox.unboxed_run(Repo, &counts/0)

  defp diagnose(scope, pool, prepared) do
    assert {:error, {plan, diagnostics}} =
             Repo.transaction(fn ->
               assert {:ok, plan, diagnostics} =
                        ImportBatchPlanner.diagnose_prepared_batch_in_transaction(
                          scope,
                          pool,
                          prepared
                        )

               Repo.rollback({plan, diagnostics})
             end)

    {plan, diagnostics}
  end

  defp committed_batch_fixture! do
    Sandbox.unboxed_run(Repo, fn ->
      scope = owner_scope()
      pool = pool_fixture(%{created_by_user_id: scope.user.id})

      prepared =
        prepare_many!(scope, pool, [import_attrs("reverse-a"), import_attrs("reverse-b")])

      %{scope: scope, pool: pool, prepared: prepared, user_id: scope.user.id}
    end)
  end

  defp committed_email_account_fixture! do
    Sandbox.unboxed_run(Repo, fn ->
      scope = owner_scope()
      pool = pool_fixture(%{created_by_user_id: scope.user.id})

      fixture =
        active_upstream_assignment_fixture(pool, %{
          chatgpt_account_id: unique("stored-account"),
          account_email: unique("stored-email") <> "@example.com",
          workspace_id: nil,
          identity_metadata: %{}
        })

      attrs =
        import_attrs("email-race")
        |> Map.put(:chatgpt_account_id, nil)
        |> Map.put(:account_email, fixture.identity.account_email)
        |> Map.put(:workspace_id, nil)

      {:ok, email_prepared} = Upstreams.prepare_bundle_account(scope, pool, attrs)

      %{
        scope: scope,
        pool: pool,
        identity: fixture.identity,
        email_prepared: email_prepared,
        user_id: scope.user.id
      }
    end)
  end

  defp cleanup_committed_batch_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(from pool in CodexPooler.Pools.Pool, where: pool.id == ^fixture.pool.id)
    end)
  end

  defp batch_plan_task(parent, barrier, role, fixture, prepared, hold?) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        run_batch_plan_transaction(parent, barrier, role, fixture, prepared, hold?)
      end)
    end)
  end

  defp run_batch_plan_transaction(parent, barrier, role, fixture, prepared, hold?) do
    Repo.transaction(fn ->
      pid = backend_pid!()
      send(parent, {barrier, role, :ready, pid})

      assert {:ok, _plan, _diagnostics} =
               ImportBatchPlanner.diagnose_prepared_batch_in_transaction(
                 fixture.scope,
                 fixture.pool,
                 prepared
               )

      send(parent, {barrier, role, :planned, pid})
      if hold?, do: await_release(barrier)
      role
    end)
  end

  defp assert_waiting_on!(waiter_pid, holder_pid) do
    blocking =
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[blocking]]} = SQL.query!(Repo, "SELECT pg_blocking_pids($1)", [waiter_pid])
        blocking
      end)

    if holder_pid not in blocking, do: assert_waiting_on!(waiter_pid, holder_pid)
  end

  defp await_release(barrier) do
    receive do
      {^barrier, :release} -> :ok
    after
      @detection_timeout_ms -> raise "batch holder release timed out"
    end
  end

  defp backend_pid! do
    %{rows: [[pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    pid
  end

  defp prepare_many!(scope, pool, attrs),
    do:
      Enum.map(attrs, fn entry ->
        {:ok, prepared} = Upstreams.prepare_bundle_account(scope, pool, entry)
        prepared
      end)

  defp projected_id(index),
    do: "00000000-0000-0000-0000-#{index |> Integer.to_string() |> String.pad_leading(12, "0")}"

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
