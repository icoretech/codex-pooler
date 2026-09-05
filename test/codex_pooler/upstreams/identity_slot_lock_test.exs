defmodule CodexPooler.Upstreams.IdentitySlotLockTest do
  use ExUnit.Case, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query

  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  alias CodexPooler.Upstreams.Lifecycle.{
    CredentialFencing,
    IdentityLifecycle,
    IdentitySlotLock
  }

  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @scenario_timeout_ms 5_000
  @detection_timeout_ms 15_000

  test "normalizes identity evidence and produces stable account and email resources" do
    normalized =
      IdentitySlotLock.normalize(%{
        "chatgpt_account_id" => "  acct_shared  ",
        "workspace_id" => "  workspace_alpha  ",
        "chatgpt_user_id" => "  subject_one  ",
        "account_email" => "  Person@Example.COM  "
      })

    assert normalized == %{
             chatgpt_account_id: "acct_shared",
             workspace_id: "workspace_alpha",
             chatgpt_user_id: "subject_one",
             account_email: "person@example.com"
           }

    resources = IdentitySlotLock.advisory_resources(normalized)

    assert resources == Enum.sort(resources)
    assert length(resources) == 2
    assert Enum.all?(resources, &Regex.match?(~r/^identity-slot:v1:[0-9a-f]{64}$/, &1))

    assert resources ==
             IdentitySlotLock.advisory_resources(%{
               chatgpt_account_id: "acct_shared",
               account_email: "PERSON@example.com"
             })
  end

  test "lock acquisition rejects callers outside a transaction" do
    unboxed(fn ->
      refute Repo.in_transaction?()

      assert_raise ArgumentError, "identity slot locks require a caller transaction", fn ->
        IdentitySlotLock.lock_slots!([%{chatgpt_account_id: "acct_outside_transaction"}])
      end

      assert_raise ArgumentError, "identity row locks require a caller transaction", fn ->
        IdentitySlotLock.lock_identity_rows!([Ecto.UUID.generate()])
      end
    end)
  end

  test "normalized same-account and same-email resources serialize real backends" do
    assert_serialized!(
      %{chatgpt_account_id: " acct_serialized ", account_email: "first@example.com"},
      %{chatgpt_account_id: "acct_serialized", account_email: "second@example.com"}
    )

    assert_serialized!(
      %{chatgpt_account_id: "acct_alpha", account_email: " Shared@Example.com "},
      %{chatgpt_account_id: "acct_beta", account_email: "shared@example.COM"}
    )
  end

  test "disjoint identity resources proceed while another transaction holds its slot" do
    parent = self()
    barrier = make_ref()

    blocker =
      lock_task(parent, barrier, :blocker, [%{chatgpt_account_id: "acct_blocked"}], true)

    assert_receive {^barrier, :blocker, :locked, blocker_backend_pid}, @detection_timeout_ms

    waiter =
      lock_task(parent, barrier, :waiter, [%{chatgpt_account_id: "acct_disjoint"}], false)

    assert_receive {^barrier, :waiter, :locked, waiter_backend_pid}, @detection_timeout_ms
    assert blocker_backend_pid != waiter_backend_pid
    assert {:ok, ^waiter_backend_pid} = Task.await(waiter, @detection_timeout_ms)

    send(blocker.pid, {barrier, :release})
    assert {:ok, ^blocker_backend_pid} = Task.await(blocker, @detection_timeout_ms)
  end

  test "reverse-ordered overlapping unions acquire one canonical order without deadlock" do
    parent = self()
    barrier = make_ref()

    first = %{chatgpt_account_id: "acct_union_alpha", account_email: "alpha@example.com"}
    second = %{chatgpt_account_id: "acct_union_beta", account_email: "beta@example.com"}

    blocker = lock_task(parent, barrier, :blocker, [first, second], true)
    assert_receive {^barrier, :blocker, :locked, blocker_backend_pid}, @detection_timeout_ms

    waiter = lock_task(parent, barrier, :waiter, [second, first, second], false)
    assert_receive {^barrier, :waiter, :ready, waiter_backend_pid}, @detection_timeout_ms
    assert blocker_backend_pid != waiter_backend_pid
    assert_waiting_on!(waiter_backend_pid, blocker_backend_pid)

    send(blocker.pid, {barrier, :release})
    assert {:ok, ^blocker_backend_pid} = Task.await(blocker, @detection_timeout_ms)
    assert_receive {^barrier, :waiter, :locked, ^waiter_backend_pid}, @detection_timeout_ms
    assert {:ok, ^waiter_backend_pid} = Task.await(waiter, @detection_timeout_ms)
  end

  test "workspace and subject selection stays distinct after acquiring broader account locks" do
    %{legacy: legacy, alpha: alpha, beta: beta} = committed_workspace_fixture!()

    try do
      unboxed(fn ->
        Repo.transaction(fn ->
          attrs = %{
            chatgpt_account_id: legacy.chatgpt_account_id,
            workspace_id: beta.workspace_id,
            chatgpt_user_id: "subject_beta"
          }

          IdentitySlotLock.lock_slots!([attrs])
          assert {:ok, selected} = IdentityLifecycle.select_upsert_identity(attrs)
          assert selected.id == beta.id
          refute selected.id == alpha.id
          refute selected.id == legacy.id
        end)
      end)
    after
      cleanup_identities!([legacy.id, alpha.id, beta.id])
    end
  end

  test "a concrete subject converges on the existing subjectless workspace slot" do
    identity =
      committed_identity!(%{
        chatgpt_account_id: unique("acct_subjectless"),
        workspace_id: "workspace_shared",
        chatgpt_user_id: nil
      })

    try do
      unboxed(fn ->
        Repo.transaction(fn ->
          attrs = %{
            chatgpt_account_id: identity.chatgpt_account_id,
            workspace_id: identity.workspace_id,
            chatgpt_user_id: "subject_new"
          }

          IdentitySlotLock.lock_slots!([attrs])
          assert {:ok, selected} = IdentityLifecycle.select_upsert_identity(attrs)
          assert selected.id == identity.id
        end)
      end)
    after
      cleanup_identities!([identity.id])
    end
  end

  test "identity, assignment, and secret rows are locked and returned in sorted id order" do
    fixture = committed_graph_fixture!()

    try do
      unboxed(fn ->
        Repo.transaction(fn ->
          locked =
            IdentitySlotLock.lock_identity_rows!([
              fixture.second.identity.id,
              fixture.first.identity.id,
              fixture.second.identity.id
            ])

          assert Enum.map(locked.identities, & &1.id) ==
                   Enum.sort([fixture.first.identity.id, fixture.second.identity.id])

          assert Enum.map(locked.assignments, & &1.id) ==
                   Enum.sort([fixture.first.assignment.id, fixture.second.assignment.id])

          assert Enum.map(locked.secrets, & &1.id) == Enum.sort(fixture.secret_ids)
        end)
      end)
    after
      cleanup_graph_fixture!(fixture)
    end
  end

  test "credential fencing delegates multi-identity replacement locks in sorted order" do
    fixture = committed_graph_fixture!()

    try do
      unboxed(fn ->
        Repo.transaction(fn ->
          locked =
            CredentialFencing.lock_credential_replacements([
              fixture.second.identity,
              fixture.first.identity.id,
              fixture.second.identity.id
            ])

          assert Enum.map(locked, & &1.id) ==
                   Enum.sort([fixture.first.identity.id, fixture.second.identity.id])
        end)
      end)
    after
      cleanup_graph_fixture!(fixture)
    end
  end

  defp assert_serialized!(first_attrs, second_attrs) do
    parent = self()
    barrier = make_ref()

    blocker = lock_task(parent, barrier, :blocker, [first_attrs], true)
    assert_receive {^barrier, :blocker, :locked, blocker_backend_pid}, @detection_timeout_ms

    waiter = lock_task(parent, barrier, :waiter, [second_attrs], false)
    assert_receive {^barrier, :waiter, :ready, waiter_backend_pid}, @detection_timeout_ms
    assert blocker_backend_pid != waiter_backend_pid
    assert_waiting_on!(waiter_backend_pid, blocker_backend_pid)

    send(blocker.pid, {barrier, :release})
    assert {:ok, ^blocker_backend_pid} = Task.await(blocker, @detection_timeout_ms)
    assert_receive {^barrier, :waiter, :locked, ^waiter_backend_pid}, @detection_timeout_ms
    assert {:ok, ^waiter_backend_pid} = Task.await(waiter, @detection_timeout_ms)
  end

  defp lock_task(parent, barrier, role, attrs, hold?) do
    Task.async(fn ->
      unboxed(fn -> run_lock_transaction(parent, barrier, role, attrs, hold?) end)
    end)
  end

  defp run_lock_transaction(parent, barrier, role, attrs, hold?) do
    Repo.transaction(fn ->
      backend_pid = backend_pid!()
      send(parent, {barrier, role, :ready, backend_pid})
      IdentitySlotLock.lock_slots!(attrs)
      send(parent, {barrier, role, :locked, backend_pid})
      await_release(barrier, hold?)
      backend_pid
    end)
  end

  defp await_release(_barrier, false), do: :ok

  defp await_release(barrier, true) do
    receive do
      {^barrier, :release} -> :ok
    after
      @scenario_timeout_ms -> raise "timed out waiting to release identity slot lock"
    end
  end

  defp assert_waiting_on!(waiter_pid, blocker_pid) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    do_assert_waiting_on!(waiter_pid, blocker_pid, deadline)
  end

  defp do_assert_waiting_on!(waiter_pid, blocker_pid, deadline) do
    blocking_pids =
      unboxed(fn ->
        %{rows: [[blocking_pids]]} =
          SQL.query!(Repo, "SELECT pg_blocking_pids($1)", [waiter_pid])

        blocking_pids
      end)

    cond do
      blocker_pid in blocking_pids ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        do_assert_waiting_on!(waiter_pid, blocker_pid, deadline)

      true ->
        flunk("backend #{waiter_pid} never waited on backend #{blocker_pid}")
    end
  end

  defp committed_workspace_fixture! do
    account_id = unique("acct_workspace")

    %{
      legacy: committed_identity!(%{chatgpt_account_id: account_id}),
      alpha:
        committed_identity!(%{chatgpt_account_id: account_id, workspace_id: "workspace_alpha"}),
      beta: committed_identity!(%{chatgpt_account_id: account_id, workspace_id: "workspace_beta"})
    }
  end

  defp committed_identity!(attrs) do
    unboxed(fn -> upstream_identity_fixture(attrs) end)
  end

  defp committed_graph_fixture! do
    unboxed(fn ->
      %{user: owner} = bootstrap_owner_fixture()
      first_pool = pool_fixture(%{created_by_user_id: owner.id})
      second_pool = pool_fixture(%{created_by_user_id: owner.id})
      first = active_upstream_assignment_fixture(first_pool, %{})
      second = active_upstream_assignment_fixture(second_pool, %{})

      secret_ids =
        Repo.all(
          from secret in CodexPooler.Upstreams.Schemas.EncryptedSecret,
            where: secret.upstream_identity_id in ^[first.identity.id, second.identity.id],
            select: secret.id
        )

      %{
        first: first,
        first_pool_id: first_pool.id,
        second: second,
        second_pool_id: second_pool.id,
        secret_ids: secret_ids
      }
    end)
  end

  defp cleanup_graph_fixture!(fixture) do
    unboxed(fn ->
      Repo.delete_all(
        from pool in Pool,
          where: pool.id in ^[fixture.first_pool_id, fixture.second_pool_id]
      )

      Repo.delete_all(
        from identity in UpstreamIdentity,
          where: identity.id in ^[fixture.first.identity.id, fixture.second.identity.id]
      )
    end)
  end

  defp cleanup_identities!(identity_ids) do
    unboxed(fn ->
      Repo.delete_all(from identity in UpstreamIdentity, where: identity.id in ^identity_ids)
    end)
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
