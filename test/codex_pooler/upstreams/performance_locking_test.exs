defmodule CodexPooler.Upstreams.PerformanceLockingTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPooler.AccountsFixtures
  import Ecto.Query

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Pools.{Membership, Pool}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.ImportBatchPlanner
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, UpstreamIdentity}
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @detection_timeout_ms 15_000

  @supporting_indexes [
    "upstream_identities_account_sibling_selection_idx",
    "upstream_identities_email_workspace_fallback_idx",
    "pool_upstream_assignments_identity_lock_idx"
  ]

  test "credential replacement locks only active secrets regardless of superseded history" do
    %{identity: identity} = active_upstream_assignment_fixture()

    for generation <- 1..5 do
      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "access_token",
                 plaintext: "synthetic-history-#{generation}"
               })
    end

    assert Repo.aggregate(
             from(secret in EncryptedSecret,
               where:
                 secret.upstream_identity_id == ^identity.id and secret.status == "superseded"
             ),
             :count
           ) == 5

    handler = "task-8-active-secret-lock-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          query = metadata[:query] || ""

          if metadata[:repo] == Repo and metadata[:source] == "encrypted_secrets" and
               String.contains?(String.upcase(query), "FOR UPDATE") do
            rows =
              case metadata[:result] do
                {:ok, %{num_rows: count}} when is_integer(count) -> count
                _result -> 0
              end

            send(parent, {handler, query, rows})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _identity} =
             Repo.transaction(fn ->
               locked_identity =
                 Repo.one!(
                   from row in UpstreamIdentity,
                     where: row.id == ^identity.id,
                     lock: "FOR UPDATE"
                 )

               CredentialFencing.lock_credential_replacement_after_identity(locked_identity)
             end)

    assert_receive {^handler, query, 1}
    assert String.contains?(query, "status")
  end

  test "supporting lock and sibling-selection indexes are installed and valid" do
    rows =
      Repo.query!(
        """
        SELECT indexrelid::regclass::text, indisvalid
        FROM pg_index
        WHERE indexrelid::regclass::text = ANY($1::text[])
        ORDER BY indexrelid::regclass::text
        """,
        [@supporting_indexes]
      ).rows

    assert rows == Enum.map(Enum.sort(@supporting_indexes), &[&1, true])
  end

  test "batch import, refresh finalization, and lifecycle writers share one row-lock order" do
    fixture =
      unboxed(fn ->
        scope = owner_scope()
        pool = pool_fixture(%{created_by_user_id: scope.user.id})
        first_attrs = import_attrs("mixed-first")
        second_attrs = import_attrs("mixed-second")

        assert {:ok, %{identity: first_identity}} =
                 Upstreams.import_trusted_account(scope, pool, first_attrs)

        assert {:ok, %{identity: second_identity}} =
                 Upstreams.import_trusted_account(scope, pool, second_attrs)

        assert {:ok, first_prepared} =
                 Upstreams.prepare_bundle_account(scope, pool, first_attrs)

        assert {:ok, second_prepared} =
                 Upstreams.prepare_bundle_account(scope, pool, second_attrs)

        %{
          scope: scope,
          pool: pool,
          identities: [first_identity, second_identity],
          prepared: [first_prepared, second_prepared]
        }
      end)

    on_exit(fn -> cleanup_mixed_fixture!(fixture) end)

    [first_identity, second_identity] = fixture.identities
    [first_prepared, second_prepared] = fixture.prepared

    parent = self()
    barrier = make_ref()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            backend_pid = backend_pid!()

            assert {:ok, _plan, _locked_rows, _diagnostics} =
                     ImportBatchPlanner.plan_prepared_batch_in_transaction(
                       fixture.scope,
                       fixture.pool,
                       [second_prepared, first_prepared]
                     )

            send(parent, {barrier, :holder_locked, backend_pid})
            await_release!(barrier)
            backend_pid
          end)
        end)
      end)

    assert_receive {^barrier, :holder_locked, holder_pid}, @detection_timeout_ms

    refresh = dependent_lock_task(parent, barrier, :refresh, second_identity.id)
    lifecycle = replacement_lock_task(parent, barrier, :lifecycle, first_identity.id)

    assert_receive {^barrier, :refresh, :ready, refresh_pid}, @detection_timeout_ms
    assert_receive {^barrier, :lifecycle, :ready, lifecycle_pid}, @detection_timeout_ms

    refresh_blocking = assert_waiting_on!(refresh_pid, holder_pid)
    lifecycle_blocking = assert_waiting_on!(lifecycle_pid, holder_pid)

    send(holder.pid, {barrier, :release})
    assert {:ok, ^holder_pid} = Task.await(holder, @detection_timeout_ms)
    assert {:ok, ^refresh_pid} = Task.await(refresh, @detection_timeout_ms)
    assert {:ok, ^lifecycle_pid} = Task.await(lifecycle, @detection_timeout_ms)

    CodexPooler.TestDiagnostics.puts(
      "GREEN mixed_writers holder=#{holder_pid} refresh=#{refresh_pid} lifecycle=#{lifecycle_pid} refresh_blocking=#{inspect(refresh_blocking)} lifecycle_blocking=#{inspect(lifecycle_blocking)} terminal=ok,ok,ok sqlstate_40P01=0"
    )
  end

  defp dependent_lock_task(parent, barrier, role, identity_id) do
    Task.async(fn ->
      unboxed(fn -> run_dependent_lock(parent, barrier, role, identity_id) end)
    end)
  end

  defp replacement_lock_task(parent, barrier, role, identity_id) do
    Task.async(fn ->
      unboxed(fn -> run_replacement_lock(parent, barrier, role, identity_id) end)
    end)
  end

  defp run_dependent_lock(parent, barrier, role, identity_id) do
    Repo.transaction(fn ->
      backend_pid = backend_pid!()
      send(parent, {barrier, role, :ready, backend_pid})

      identity =
        Repo.one!(
          from row in UpstreamIdentity,
            where: row.id == ^identity_id,
            lock: "FOR UPDATE"
        )

      CredentialFencing.lock_credential_replacement_after_identity(identity)
      backend_pid
    end)
  end

  defp run_replacement_lock(parent, barrier, role, identity_id) do
    Repo.transaction(fn ->
      backend_pid = backend_pid!()
      send(parent, {barrier, role, :ready, backend_pid})
      _identity = CredentialFencing.lock_credential_replacement(identity_id)
      backend_pid
    end)
  end

  defp assert_waiting_on!(waiter_pid, holder_pid) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    do_assert_waiting_on!(waiter_pid, holder_pid, deadline)
  end

  defp do_assert_waiting_on!(waiter_pid, holder_pid, deadline) do
    blocking =
      unboxed(fn ->
        %{rows: [[blocking]]} = SQL.query!(Repo, "SELECT pg_blocking_pids($1)", [waiter_pid])
        blocking
      end)

    cond do
      holder_pid in blocking ->
        blocking

      System.monotonic_time(:millisecond) < deadline ->
        do_assert_waiting_on!(waiter_pid, holder_pid, deadline)

      true ->
        flunk("backend #{waiter_pid} did not wait on #{holder_pid}")
    end
  end

  defp await_release!(barrier) do
    receive do
      {^barrier, :release} -> :ok
    after
      @detection_timeout_ms -> raise "mixed-writer holder was not released"
    end
  end

  defp import_attrs(label) do
    unique = System.unique_integer([:positive, :monotonic])

    %{
      chatgpt_account_id: "task8-account-#{label}-#{unique}",
      chatgpt_user_id: "task8-subject-#{label}-#{unique}",
      account_email: nil,
      account_label: "Synthetic task 8 account",
      workspace_id: "task8-workspace-#{label}",
      workspace_label: nil,
      seat_type: nil,
      plan_label: nil,
      token: "synthetic-task8-access-#{unique}",
      refresh_token: "synthetic-task8-refresh-#{unique}",
      credential_provenance: "codex_chatgpt_oauth",
      access_token_expires_at:
        DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.to_iso8601(),
      import_metadata: %{}
    }
  end

  defp owner_scope do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    user =
      %User{id: Ecto.UUID.generate(), created_at: now, updated_at: now}
      |> User.bootstrap_changeset(
        valid_bootstrap_attributes(%{
          "email" => "task8-#{System.unique_integer([:positive])}@example.com"
        })
      )
      |> Repo.insert!()

    Repo.insert!(%Membership{
      user_id: user.id,
      role: "instance_owner",
      status: "active",
      created_at: now
    })

    Scope.for_user(user)
  end

  defp cleanup_mixed_fixture!(fixture) do
    identity_ids = Enum.map(fixture.identities, & &1.id)

    unboxed(fn ->
      Repo.delete_all(
        from event in AuditEvent, where: event.actor_user_id == ^fixture.scope.user.id
      )

      Repo.delete_all(from identity in UpstreamIdentity, where: identity.id in ^identity_ids)
      Repo.delete_all(from pool in Pool, where: pool.id == ^fixture.pool.id)
      Repo.delete_all(from user in User, where: user.id == ^fixture.scope.user.id)
    end)
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
