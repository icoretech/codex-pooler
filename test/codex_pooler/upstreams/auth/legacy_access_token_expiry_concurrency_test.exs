defmodule CodexPooler.Upstreams.Auth.LegacyAccessTokenExpiryConcurrencyTest do
  use ExUnit.Case, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Events
  alias CodexPooler.Pools.{Membership, Pool}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Auth.{LegacyAccessTokenExpiry, TokenRefreshMetadata}
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.{Secrets, TokenLinking}
  alias Ecto.Adapters.SQL.Sandbox

  @detection_budget 15_000
  @recovered "upstream_access_token_expiry_recovered"

  for first <- [:repair, :replacement] do
    test "#{first} locks first: stale hydration cannot overwrite replacement credentials" do
      assert_serialized_replacement!(committed_fixture!(), unquote(first))
    end
  end

  defp assert_serialized_replacement!(fixture, first) do
    second = if first == :repair, do: :replacement, else: :repair
    parent = self()
    barrier = make_ref()
    handler = {__MODULE__, barrier}
    :ok = Events.subscribe_pool(fixture.pool.id, "upstreams")

    :ok =
      :telemetry.attach(handler, [:codex_pooler, :repo, :query], &__MODULE__.hold_lock/4, nil)

    blocker = operation_task(fixture, first, parent, barrier, true)

    try do
      assert_receive {^barrier, :locked, blocker_backend}, @detection_budget
      waiter = operation_task(fixture, second, parent, barrier, false)

      try do
        assert_receive {^barrier, :started, ^second, waiter_backend}, @detection_budget
        refute blocker_backend == waiter_backend
        assert_blocked!(waiter_backend, blocker_backend)
        refute_received {^barrier, :finished, ^second}
        send(blocker.pid, {barrier, :release})
        assert {:ok, _} = Task.await(blocker, @detection_budget)
        assert {:ok, _} = Task.await(waiter, @detection_budget)
        assert_current_replacement!(fixture)

        if first == :repair do
          pool_id = fixture.pool.id
          assert_receive {Events, %{pool_id: ^pool_id, reason: @recovered}}, @detection_budget
        end

        assert {:ok, _} = unboxed(fn -> LegacyAccessTokenExpiry.repair(fixture.identity) end)
        event_fence!(fixture.pool.id)
        refute_received {Events, %{reason: @recovered}}
      after
        send(blocker.pid, {barrier, :release})
        Task.shutdown(waiter, :brutal_kill)
      end
    after
      send(blocker.pid, {barrier, :release})
      Task.shutdown(blocker, :brutal_kill)
      :telemetry.detach(handler)
    end
  end

  test "outer rollback discards hydration metadata and its transactional notification" do
    fixture = committed_fixture!()
    :ok = Events.subscribe_pool(fixture.pool.id, "upstreams")

    assert {:error, :synthetic_rollback} =
             unboxed(fn ->
               Repo.transaction(fn ->
                 assert {:ok, repaired} = LegacyAccessTokenExpiry.repair(fixture.identity)

                 assert TokenRefreshMetadata.project_access_token_expiry(repaired.metadata).state ==
                          :known

                 Repo.rollback(:synthetic_rollback)
               end)
             end)

    assert unboxed(fn -> Repo.reload!(fixture.identity).metadata end) == fixture.identity.metadata
    event_fence!(fixture.pool.id)
    refute_received {Events, %{reason: @recovered}}
  end

  test "committed fixture cleanup is exact and idempotent" do
    fixture = committed_fixture!()
    other = committed_fixture!()
    cleanup!(fixture.ids)
    cleanup!(fixture.ids)

    unboxed(fn ->
      refute Repo.get(Pool, fixture.pool.id)
      refute Repo.get(User, fixture.ids.user_id)
      refute Repo.get(UpstreamIdentity, fixture.identity.id)

      refute Repo.exists?(
               from row in EncryptedSecret,
                 where: row.upstream_identity_id == ^fixture.identity.id
             )

      refute Repo.get(PoolUpstreamAssignment, fixture.assignment.id)
      assert Repo.get!(Pool, other.pool.id)
      assert Repo.get!(User, other.ids.user_id)
      assert Repo.get!(UpstreamIdentity, other.identity.id)

      assert Repo.exists?(
               from row in EncryptedSecret, where: row.upstream_identity_id == ^other.identity.id
             )

      assert Repo.get!(PoolUpstreamAssignment, other.assignment.id)
    end)
  end

  @doc false
  def hold_lock(_event, _measurements, metadata, _config) do
    case Process.get({__MODULE__, :barrier}) do
      {parent, barrier, backend} ->
        if metadata[:source] == "encrypted_secrets" and
             String.contains?(metadata.query, "FOR UPDATE") do
          Process.delete({__MODULE__, :barrier})
          send(parent, {barrier, :locked, backend})

          receive do
            {^barrier, :release} -> :ok
          after
            @detection_budget * 2 -> raise "credential lock barrier was not released"
          end
        end

      nil ->
        :ok
    end
  end

  defp operation_task(fixture, operation, parent, barrier, hold?) do
    Task.async(fn ->
      unboxed(fn -> checkout_operation(fixture, operation, parent, barrier, hold?) end)
    end)
  end

  defp checkout_operation(fixture, operation, parent, barrier, hold?) do
    # checkout pins a genuine, independent connection; no shared sandbox owner.
    Repo.checkout(fn ->
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      if hold?, do: Process.put({__MODULE__, :barrier}, {parent, barrier, backend})
      send(parent, {barrier, :started, operation, backend})
      result = run_operation(fixture, operation)
      send(parent, {barrier, :finished, operation})
      result
    end)
  end

  defp run_operation(fixture, :repair), do: LegacyAccessTokenExpiry.repair(fixture.identity)

  defp run_operation(fixture, :replacement),
    do: TokenLinking.link_tokens(fixture.scope, fixture.pool, fixture.replacement, [])

  defp assert_blocked!(waiter, blocker) do
    deadline = System.monotonic_time(:millisecond) + @detection_budget
    assert_blocked!(waiter, blocker, deadline)
  end

  defp assert_blocked!(waiter, blocker, deadline) do
    rows =
      unboxed(fn ->
        Repo.query!(
          "SELECT pg_blocking_pids($1), wait_event_type FROM pg_stat_activity WHERE pid = $1",
          [waiter]
        ).rows
      end)

    case rows do
      [[blockers, "Lock"]] when blockers != [] ->
        assert blocker in blockers

      _ ->
        assert System.monotonic_time(:millisecond) < deadline,
               "credential replacement did not serialize independent postgres backends"

        assert_blocked!(waiter, blocker, deadline)
    end
  end

  defp assert_current_replacement!(fixture) do
    unboxed(fn ->
      current = Repo.reload!(fixture.identity)
      assert current.metadata["credential_epoch"] == 7

      assert %{state: :known, deadline: deadline} =
               TokenRefreshMetadata.project_access_token_expiry(current.metadata)

      assert deadline == fixture.replacement_deadline
      assert current.metadata["token_refresh"]["access_token_expiry"]["credential_epoch"] == 7
      assert current.metadata["unrelated"] == "preserved"
      assert current.status == "active"
      assert {:ok, token} = Secrets.decrypt_active_secret(current, "access_token")
      assert token == fixture.replacement.token
      refute inspect(current.metadata) =~ token

      assert Repo.aggregate(
               from(row in EncryptedSecret,
                 where:
                   row.upstream_identity_id == ^current.id and row.status == "active" and
                     row.secret_kind == "access_token"
               ),
               :count
             ) == 1
    end)
  end

  defp event_fence!(pool_id) do
    # The same notification connection delivers prior committed events before this sentinel.
    assert {:ok, {:ok, _}} =
             unboxed(fn ->
               Repo.transaction(fn ->
                 Events.broadcast_upstreams_after_commit(pool_id, "synthetic_notification_fence")
               end)
             end)

    assert_receive {Events, %{pool_id: ^pool_id, reason: "synthetic_notification_fence"}},
                   @detection_budget
  end

  defp committed_fixture! do
    unique = Ecto.UUID.generate()

    ids = %{
      user_id: Ecto.UUID.generate(),
      account_id: "synthetic-#{unique}",
      pool_slug: "expiry-#{unique}"
    }

    on_exit(fn -> cleanup!(ids) end)

    unboxed(fn ->
      {:ok, fixture} =
        Repo.transaction(fn ->
          now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

          user =
            %User{id: ids.user_id, created_at: now, updated_at: now}
            |> User.bootstrap_changeset(
              valid_bootstrap_attributes(%{"email" => "expiry-#{unique}@example.com"})
            )
            |> Repo.insert!()

          Repo.insert!(%Membership{
            user_id: user.id,
            role: "instance_admin",
            status: "active",
            created_at: now
          })

          pool = pool_fixture(%{slug: ids.pool_slug, created_by_user_id: user.id})
          operator_pool_assignment_fixture(user, pool)
          old_deadline = now |> DateTime.add(3600) |> DateTime.truncate(:second)

          %{identity: identity, assignment: assignment} =
            active_upstream_assignment_fixture(pool, %{
              chatgpt_account_id: ids.account_id,
              access_token: jwt(old_deadline)
            })

          identity =
            identity
            |> Ecto.Changeset.change(
              metadata: %{
                "credential_epoch" => 6,
                "unrelated" => "preserved",
                "token_refresh" => %{"status" => "succeeded", "generation" => 5}
              }
            )
            |> Repo.update!()

          replacement_deadline = now |> DateTime.add(7200) |> DateTime.truncate(:second)

          %{
            ids: ids,
            identity: identity,
            assignment: assignment,
            pool: pool,
            scope: Scope.for_user(user),
            replacement_deadline: replacement_deadline,
            replacement: %{
              chatgpt_account_id: ids.account_id,
              account_label: "Synthetic replacement",
              token: jwt(replacement_deadline)
            }
          }
        end)

      fixture
    end)
  end

  defp cleanup!(ids) do
    unboxed(fn ->
      Repo.delete_all(from pool in Pool, where: pool.slug == ^ids.pool_slug)

      Repo.delete_all(
        from identity in UpstreamIdentity, where: identity.chatgpt_account_id == ^ids.account_id
      )

      Repo.delete_all(from user in User, where: user.id == ^ids.user_id)
    end)
  end

  defp jwt(deadline) do
    payload =
      CodexPooler.JSON.encode!(%{"exp" => DateTime.to_unix(deadline)})
      |> Base.url_encode64(padding: false)

    "synthetic." <> payload <> ".signature"
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
