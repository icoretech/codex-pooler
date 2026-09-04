defmodule CodexPooler.Accounting.RequestReplayPostgresTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import CodexPooler.RequestReplayFixtures
  alias CodexPooler.Accounting.RequestReplay
  alias CodexPooler.Accounting.RequestReplayEntitlement
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.InstanceSettings.AppSecretCrypto
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  test "consume and key pause or delete use separate backends without duplicate settlement" do
    for mutation <- [:pause_api_key, :delete_api_key] do
      fixture = Sandbox.unboxed_run(Repo, fn -> replay_fixture(reservation?: true) end)

      try do
        {:ok, armed} = Sandbox.unboxed_run(Repo, fn -> RequestReplay.arm(arm_input(fixture)) end)
        input = consume_input(fixture, armed, :crypto.strong_rand_bytes(32))
        allow_committed_owner(fixture)

        [consume, changed] =
          run_concurrently([
            fn -> RequestReplay.consume(input) end,
            fn -> apply(CodexPooler.Access, mutation, [fixture.scope, fixture.api_key]) end
          ])

        assert {:ok, _key} = changed
        assert match?({:ok, _result}, consume) or match?({:error, _reason}, consume)

        Sandbox.unboxed_run(Repo, fn ->
          if mutation == :pause_api_key do
            assert {:ok, :closed} = RequestReplay.close(fixture.request.id, :owner_shutdown)
            assert terminal_ledger_count(fixture.request.id, "settlement") == 1
            assert terminal_ledger_count(fixture.request.id, "release") == 1
            assert request_attempt_count(fixture.request.id) in 1..2
          else
            assert is_nil(Repo.get(CodexPooler.Accounting.Request, fixture.request.id))
            assert request_attempt_count(fixture.request.id) == 0
            assert terminal_ledger_count(fixture.request.id, "settlement") == 0
            assert terminal_ledger_count(fixture.request.id, "release") == 0
          end
        end)
      after
        cleanup_fixture(fixture)
      end
    end
  end

  test "a locked first candidate is deferred while the next expired replay closes" do
    first = Sandbox.unboxed_run(Repo, fn -> replay_fixture(reservation?: true) end)
    second = Sandbox.unboxed_run(Repo, fn -> replay_fixture(reservation?: true) end)
    parent = self()

    try do
      Sandbox.unboxed_run(Repo, fn ->
        for {fixture, offset} <- [{first, -2}, {second, -1}] do
          due_at = DateTime.add(DateTime.utc_now(), offset, :second)

          insert_entitlement!(fixture, %{
            armed_at: DateTime.add(due_at, -30, :second),
            expires_at: due_at
          })
        end
      end)

      holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              Repo.one!(
                from session in CodexSession,
                  where: session.id == ^first.session.id,
                  lock: "FOR UPDATE"
              )

              send(parent, {:candidate_locked, self()})

              receive do
                :release_candidate -> :ok
              end
            end)
          end)
        end)

      assert_receive {:candidate_locked, holder_pid}, 15_000

      try do
        assert {:ok, %{replay_entitlements_deferred: 1, replay_entitlements_closed: 1}} =
                 Sandbox.unboxed_run(Repo, &RequestReplay.cleanup_due/0)

        assert Sandbox.unboxed_run(Repo, fn ->
                 terminal_ledger_count(second.request.id, "settlement")
               end) == 1
      after
        send(holder_pid, :release_candidate)
        Task.await(holder, 15_000)
      end
    after
      cleanup_fixture(first)
      cleanup_fixture(second)
    end
  end

  test "independent PostgreSQL arm and terminal finalization transactions converge once" do
    for _ <- 1..10 do
      fixture = Sandbox.unboxed_run(Repo, fn -> replay_fixture(reservation?: true) end)

      try do
        [arm, terminal] =
          run_concurrently([
            fn -> RequestReplay.arm(arm_input(fixture)) end,
            fn ->
              CodexPooler.Accounting.finalize_request(fixture.request, fixture.attempt, %{
                request_status: "succeeded",
                attempt_status: "succeeded",
                response_status_code: 200,
                usage: %{
                  status: "usage_known",
                  input_tokens: 1,
                  output_tokens: 1,
                  total_tokens: 2
                }
              })
            end
          ])

        case arm do
          {:ok, _entitlement} ->
            assert {:ok, %{stale_generation?: true}} = terminal

            assert {:ok, :closed} =
                     Sandbox.unboxed_run(Repo, fn ->
                       RequestReplay.close(fixture.request.id, :owner_shutdown)
                     end)

          {:error, :terminal_won} ->
            assert {:ok, _result} = terminal
        end

        Sandbox.unboxed_run(Repo, fn ->
          assert terminal_ledger_count(fixture.request.id, "settlement") == 1
          assert terminal_ledger_count(fixture.request.id, "release") == 1
          assert request_attempt_count(fixture.request.id) == 1
        end)
      after
        cleanup_fixture(fixture)
      end
    end
  end

  test "consume checks expiry after a real PostgreSQL session lock wait" do
    fixture = Sandbox.unboxed_run(Repo, fn -> replay_fixture(reservation?: true) end)
    parent = self()

    try do
      armed =
        Sandbox.unboxed_run(Repo, fn ->
          now = DateTime.utc_now()
          {:ok, digest} = RequestReplayEntitlement.owner_lease_digest(fixture.owner_lease_token)

          entitlement =
            insert_entitlement!(fixture, %{
              armed_at: DateTime.add(now, -28, :second),
              expires_at: DateTime.add(now, 2, :second),
              owner_lease_digest: digest,
              owner_lease_key_version: AppSecretCrypto.key_version()
            })

          %{
            entitlement_id: entitlement.id,
            owner_lease_digest: digest,
            expires_at: entitlement.expires_at
          }
        end)

      input = consume_input(fixture, armed, :crypto.strong_rand_bytes(32))
      allow_committed_owner(fixture)

      holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              Repo.one!(
                from session in CodexSession,
                  where: session.id == ^fixture.session.id,
                  lock: "FOR UPDATE"
              )

              %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()", [])
              send(parent, {:replay_session_locked, self(), pid})

              receive do
                :release_replay_session -> :ok
              end
            end)
          end)
        end)

      assert_receive {:replay_session_locked, holder_pid, holder_backend}, 15_000
      Process.put(:replay_lock_holder, holder_pid)

      consumer =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()", [])
            send(parent, {:replay_consume_backend, pid})
            RequestReplay.consume(input)
          end)
        end)

      assert_receive {:replay_consume_backend, consumer_backend}, 15_000
      refute holder_backend == consumer_backend

      Sandbox.unboxed_run(Repo, fn ->
        deadline = System.monotonic_time(:millisecond) + 15_000
        await_replay_blocked!(consumer_backend, holder_backend, armed.expires_at, deadline)
      end)

      send(holder_pid, :release_replay_session)
      assert {:ok, :ok} = Task.await(holder, 15_000)
      assert {:error, :ineligible} = Task.await(consumer, 15_000)
      assert Sandbox.unboxed_run(Repo, fn -> request_attempt_count(fixture.request.id) end) == 1
    after
      if holder_pid = Process.delete(:replay_lock_holder),
        do: send(holder_pid, :release_replay_session)

      Sandbox.unboxed_run(Repo, fn ->
        {:ok, owner} =
          WebsocketOwnerSession.lookup(fixture.session.id)

        Sandbox.allow(Repo, self(), owner)
        stop_replay_owner(fixture.session.id)
      end)

      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[lock_timeout]]} = Repo.query!("SHOW lock_timeout", [])

        assert {:ok, _deleted} =
                 Repo.transaction(fn ->
                   Repo.query!("SET LOCAL lock_timeout = '1s'", [])

                   Repo.delete_all(
                     from entitlement in RequestReplayEntitlement,
                       where: entitlement.request_id == ^fixture.request.id
                   )

                   Repo.delete_all(
                     from pool in CodexPooler.Pools.Pool, where: pool.id == ^fixture.pool.id
                   )

                   Repo.delete_all(
                     from identity in CodexPooler.Upstreams.Schemas.UpstreamIdentity,
                       where: identity.id == ^fixture.identity.id
                   )
                 end)

        assert %{rows: [[^lock_timeout]]} = Repo.query!("SHOW lock_timeout", [])
      end)
    end
  end

  defp await_replay_blocked!(waiter, holder, expires_at, deadline) do
    %{rows: [[blockers, expired]]} =
      Repo.query!(
        "SELECT pg_blocking_pids($1), clock_timestamp() > $2::timestamptz",
        [waiter, expires_at]
      )

    cond do
      holder in blockers and expired ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        await_replay_blocked!(waiter, holder, expires_at, deadline)

      true ->
        flunk("consume did not wait on the session lock across expiry")
    end
  end

  defp cleanup_fixture(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      case WebsocketOwnerSession.lookup(fixture.session.id) do
        {:ok, owner} ->
          Sandbox.allow(Repo, self(), owner)
          stop_replay_owner(fixture.session.id)

        {:error, :owner_unavailable} ->
          :ok
      end

      Repo.delete_all(
        from row in RequestReplayEntitlement, where: row.request_id == ^fixture.request.id
      )

      Repo.delete_all(from row in CodexPooler.Pools.Pool, where: row.id == ^fixture.pool.id)

      Repo.delete_all(
        from row in CodexPooler.Upstreams.Schemas.UpstreamIdentity,
          where: row.id == ^fixture.identity.id
      )
    end)
  end

  defp allow_committed_owner(fixture) do
    database_owner =
      Process.get(:committed_replay_database_owner) ||
        Sandbox.start_owner!(Repo, sandbox: false)

    unless Process.get(:committed_replay_database_owner) do
      Process.put(:committed_replay_database_owner, database_owner)
      on_exit(fn -> Sandbox.stop_owner(database_owner) end)
    end

    {:ok, owner} =
      WebsocketOwnerSession.lookup(fixture.session.id)

    :ok = Sandbox.allow(Repo, database_owner, owner)
  end

  defp run_concurrently(operations) do
    parent = self()
    ref = make_ref()

    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn -> run_concurrent_operation(parent, ref, operation) end)
      end)

    backends =
      Enum.map(tasks, fn _ ->
        assert_receive {:postgres_ready, ^ref, _pid, backend}, 15_000
        backend
      end)

    assert length(Enum.uniq(backends)) == length(tasks)
    Enum.each(tasks, &send(&1.pid, {:run, ref}))
    Enum.map(tasks, &Task.await(&1, 15_000))
  end

  defp run_concurrent_operation(parent, ref, operation) do
    Sandbox.unboxed_run(Repo, fn ->
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()", [])
      send(parent, {:postgres_ready, ref, self(), backend})

      receive do
        {:run, ^ref} -> operation.()
      end
    end)
  end
end
