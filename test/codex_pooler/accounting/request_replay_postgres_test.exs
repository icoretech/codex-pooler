defmodule CodexPooler.Accounting.RequestReplayPostgresTest do
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard
  import Ecto.Query
  import CodexPooler.AccountsFixtures, only: [committed_bootstrap_owner_fixture!: 0]
  import CodexPooler.RequestReplayFixtures
  import CodexPooler.UnboxedFixture, only: [register_unboxed_cleanup!: 1]
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounting.RequestReplay
  alias CodexPooler.Accounting.RequestReplayEntitlement
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.InstanceSettings.AppSecretCrypto
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  # Each mutation and ordering is its own committed fixture and race, so each is
  # its own test rather than six passes accumulated in one.
  for mutation <- [:pause_api_key, :delete_api_key], order <- [:concurrent, :consume_first, :mutation_first] do
    @tag replay_mutation: mutation, replay_order: order
    test "consume and #{mutation} use separate backends without duplicate settlement (#{order})", %{replay_mutation: mutation, replay_order: order} do
      fixture = committed_replay_fixture!()

      {:ok, armed} = Sandbox.unboxed_run(Repo, fn -> RequestReplay.arm(arm_input(fixture)) end)
      input = consume_input(fixture, armed, :crypto.strong_rand_bytes(32))
      allow_committed_owner(fixture)

      [consume, changed] =
        run_concurrently(
          [
            fn -> RequestReplay.consume(input) end,
            fn -> apply(CodexPooler.Access, mutation, [fixture.scope, fixture.api_key]) end
          ],
          order
        )

      assert {:ok, _key} = changed

      expected_generations =
        case consume do
          {:ok, result} ->
            assert result.attempt.replay_generation == 1
            [0, 1]

          {:error, _reason} ->
            [0]
        end

      case order do
        :consume_first -> assert match?({:ok, _}, consume)
        :mutation_first -> assert match?({:error, _}, consume)
        :concurrent -> :ok
      end

      Sandbox.unboxed_run(Repo, fn ->
        if mutation == :pause_api_key do
          assert {:ok, :closed} = RequestReplay.close(fixture.request.id, :owner_shutdown)
          assert terminal_ledger_count(fixture.request.id, "settlement") == 1
          assert terminal_ledger_count(fixture.request.id, "release") == 1
          assert request_attempt_count(fixture.request.id) == length(expected_generations)
        else
          assert %{api_key_id: nil, status: "failed"} =
                   Repo.get!(CodexPooler.Accounting.Request, fixture.request.id)

          assert request_attempt_count(fixture.request.id) == length(expected_generations)
          assert terminal_ledger_count(fixture.request.id, "settlement") == 1
          assert terminal_ledger_count(fixture.request.id, "release") == 1
        end

        assert Repo.all(
                 from(a in Attempt,
                   where: a.request_id == ^fixture.request.id,
                   order_by: a.replay_generation,
                   select: a.replay_generation
                 )
               ) == expected_generations
      end)

      cleanup_fixture(fixture)
    end
  end

  test "a locked first candidate is deferred while the next expired replay closes" do
    first = committed_replay_fixture!()
    second = committed_replay_fixture!()
    parent = self()

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

    cleanup_fixture(first)
    cleanup_fixture(second)
  end

  @tag slow: "races actual committed entitlement arming and terminal finalization on separate PostgreSQL connections"
  test "independent PostgreSQL arm and terminal finalization transactions converge once" do
    for _ <- 1..10 do
      fixture = committed_replay_fixture!()

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

      cleanup_fixture(fixture)
    end
  end

  test "PostgreSQL replay states preserve one request and one reservation through N2" do
    fixture = committed_replay_fixture!()
    expired_fixture = committed_replay_fixture!()

    Sandbox.unboxed_run(Repo, fn ->
      fixture.api_key |> Ecto.Changeset.change(max_active_requests: 1) |> Repo.update!()
    end)

    assert {:active_generation_zero, active} =
             Sandbox.unboxed_run(Repo, fn ->
               RequestReplay.preflight_snapshot(fixture.preflight)
             end)

    assert active.request_id == fixture.request.id
    assert active.replay_generation == 0

    {:ok, armed} =
      Sandbox.unboxed_run(Repo, fn -> RequestReplay.arm(arm_input(fixture)) end)

    assert {:armed_generation_one, armed_snapshot} =
             Sandbox.unboxed_run(Repo, fn ->
               RequestReplay.preflight_snapshot(fixture.preflight)
             end)

    assert armed_snapshot.entitlement_id == armed.entitlement_id
    assert armed_snapshot.replay_generation == 1

    input = consume_input(fixture, armed, :crypto.strong_rand_bytes(32))
    allow_committed_owner(fixture)

    assert {:ok, consumed} =
             Sandbox.unboxed_run(Repo, fn -> RequestReplay.consume(input) end)

    assert consumed.attempt.replay_generation == 1

    assert {:error, :lifecycle_conflict} =
             Sandbox.unboxed_run(Repo, fn ->
               RequestReplay.preflight_snapshot(fixture.preflight)
             end)

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(
               from(request in Request, where: request.id == ^fixture.request.id),
               :count
             ) == 1

      assert Repo.all(
               from(attempt in Attempt,
                 where: attempt.request_id == ^fixture.request.id,
                 order_by: [asc: attempt.replay_generation],
                 select: attempt.replay_generation
               )
             ) == [0, 1]

      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where:
                   entry.request_id == ^fixture.request.id and
                     entry.entry_kind == "reservation"
               ),
               :count
             ) == 1
    end)

    Sandbox.unboxed_run(Repo, fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      insert_entitlement!(expired_fixture, %{
        armed_at: DateTime.add(now, -60, :second),
        expires_at: DateTime.add(now, -30, :second)
      })

      assert {:error, :lifecycle_conflict} =
               RequestReplay.preflight_snapshot(expired_fixture.preflight)

      assert request_attempt_count(expired_fixture.request.id) == 1
    end)

    cleanup_fixture(fixture)
    cleanup_fixture(expired_fixture)
  end

  @tag slow: "holds a real PostgreSQL session lock across entitlement expiry"
  test "consume checks expiry after a real PostgreSQL session lock wait" do
    fixture = committed_replay_fixture!()
    parent = self()
    deadlocks_before = Sandbox.unboxed_run(Repo, &deadlock_count/0)

    armed =
      Sandbox.unboxed_run(Repo, fn ->
        now = DateTime.utc_now()
        {:ok, digest} = RequestReplayEntitlement.owner_lease_digest(fixture.owner_lease_token)

        # The entitlement must outlive consume's path to the session lock and
        # expire only while it waits there; `await_replay_blocked!/4` fails
        # loudly if consume never blocks, so a one-second remainder is the
        # scenario budget rather than a detection budget.
        entitlement =
          insert_entitlement!(fixture, %{
            armed_at: DateTime.add(now, -29, :second),
            expires_at: DateTime.add(now, 1, :second),
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

    lock_snapshot =
      Sandbox.unboxed_run(Repo, fn ->
        deadline = System.monotonic_time(:millisecond) + 15_000
        await_replay_blocked!(consumer_backend, holder_backend, armed.expires_at, deadline)
      end)

    send(holder_pid, :release_replay_session)
    assert {:ok, :ok} = Task.await(holder, 15_000)
    consume_result = Task.await(consumer, 15_000)

    assert lock_snapshot.state == "active"
    assert lock_snapshot.wait_event_type == "Lock"
    assert holder_backend in lock_snapshot.blockers
    assert lock_snapshot.ungranted_lock_count > 0
    assert {:error, :ineligible} = consume_result

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.query!("SELECT pg_blocking_pids($1)", [consumer_backend]).rows == [[[]]]
      assert deadlock_count() == deadlocks_before
      assert request_attempt_count(fixture.request.id) == 1
    end)

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

                 Repo.delete_all(from pool in CodexPooler.Pools.Pool, where: pool.id == ^fixture.pool.id)

                 Repo.delete_all(
                   from identity in CodexPooler.Upstreams.Schemas.UpstreamIdentity,
                     where: identity.id == ^fixture.identity.id
                 )
               end)

      assert %{rows: [[^lock_timeout]]} = Repo.query!("SHOW lock_timeout", [])
    end)
  end

  test "consume revalidates the API key epoch after a real session lock wait" do
    fixture = committed_replay_fixture!()
    parent = self()
    deadlocks_before = Sandbox.unboxed_run(Repo, &deadlock_count/0)

    {:ok, armed} = Sandbox.unboxed_run(Repo, fn -> RequestReplay.arm(arm_input(fixture)) end)
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
            send(parent, {:epoch_session_locked, self(), pid})

            receive do
              :release_epoch_session -> :ok
            end
          end)
        end)
      end)

    assert_receive {:epoch_session_locked, holder_pid, holder_backend}, 15_000
    Process.put(:epoch_lock_holder, holder_pid)

    consumer =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()", [])
          send(parent, {:epoch_consumer_backend, pid})
          RequestReplay.consume(input)
        end)
      end)

    assert_receive {:epoch_consumer_backend, consumer_backend}, 15_000

    snapshot =
      Sandbox.unboxed_run(Repo, fn ->
        snapshot =
          await_replay_blocked!(
            consumer_backend,
            holder_backend,
            DateTime.add(DateTime.utc_now(), -1, :second),
            System.monotonic_time(:millisecond) + 15_000
          )

        api_key = Repo.get!(APIKey, fixture.api_key.id)

        api_key
        |> Ecto.Changeset.change(runtime_revocation_epoch: api_key.runtime_revocation_epoch + 1)
        |> Repo.update!()

        snapshot
      end)

    send(holder_pid, :release_epoch_session)
    assert {:ok, :ok} = Task.await(holder, 15_000)
    Process.delete(:epoch_lock_holder)
    consume_result = Task.await(consumer, 15_000)

    assert snapshot.wait_event_type == "Lock"
    assert holder_backend in snapshot.blockers
    assert {:error, :ineligible} = consume_result

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.query!("SELECT pg_blocking_pids($1)", [consumer_backend]).rows == [[[]]]
      assert deadlock_count() == deadlocks_before
      assert request_attempt_count(fixture.request.id) == 1
      assert Repo.get!(RequestReplayEntitlement, armed.entitlement_id).status == "armed"
    end)

    if holder_pid = Process.delete(:epoch_lock_holder),
      do: send(holder_pid, :release_epoch_session)

    cleanup_fixture(fixture)
  end

  # Decision (findings#204): replay consume passes the same lifecycle fence as
  # a claim. Active-Pool ownership and the exact runtime epoch were already
  # fenced and stay as controls here; the natural expiry crossing is the new
  # edge, because it changes neither status nor epoch. Time moves through the
  # replay clock function `request_replay_db_now()`, which consume reads under
  # its locks, so nothing sleeps and no key attribute is edited after arming.
  test "consume fails closed when the armed key expires between arm and consume at locked database time" do
    on_exit(fn -> Sandbox.unboxed_run(Repo, &restore_replay_db_now!/0) end)

    scenarios = [
      :expires_between_arm_and_consume,
      :valid_unexpired,
      :nil_expiry,
      :stale_epoch,
      :inactive_pool
    ]

    for scenario <- scenarios do
      fixture = committed_replay_fixture!()
      fixture = Sandbox.unboxed_run(Repo, fn -> put_key_expiry!(fixture, scenario) end)
      {:ok, armed} = Sandbox.unboxed_run(Repo, fn -> RequestReplay.arm(arm_input(fixture)) end)
      assert_key_valid_when_armed!(fixture, armed)

      input = consume_input(fixture, armed, :crypto.strong_rand_bytes(32))
      allow_committed_owner(fixture)
      ledger_before = Sandbox.unboxed_run(Repo, fn -> ledger_snapshot(fixture) end)

      Sandbox.unboxed_run(Repo, fn ->
        cross_between_arm_and_consume!(fixture, armed, scenario)
      end)

      consume_result = Sandbox.unboxed_run(Repo, fn -> RequestReplay.consume(input) end)
      Sandbox.unboxed_run(Repo, &restore_replay_db_now!/0)

      Sandbox.unboxed_run(Repo, fn ->
        entitlement = Repo.get!(RequestReplayEntitlement, armed.entitlement_id)
        api_key = Repo.get!(APIKey, fixture.api_key.id)

        if scenario in [:valid_unexpired, :nil_expiry] do
          assert {:ok, consumed} = consume_result, "#{scenario}: #{inspect(consume_result)}"
          assert consumed.attempt.replay_generation == 1
          assert entitlement.status == "consumed"
          assert request_attempt_count(fixture.request.id) == 2
        else
          assert {:error, :ineligible} = consume_result, "#{scenario}: #{inspect(consume_result)}"
          assert entitlement.status == "armed"
          assert request_attempt_count(fixture.request.id) == 1
          assert upstream_send_count(fixture) == 0
          assert ledger_snapshot(fixture) == ledger_before
        end

        # One reservation for every scenario: a refused consume consumes nothing
        # more, and an admitted replay reuses the reservation it inherited.
        assert ledger_snapshot(fixture).reservations == 1

        if scenario == :expires_between_arm_and_consume do
          # The refusal came from the clock alone: status and epoch are exactly
          # what the entitlement captured when it was armed.
          assert api_key.status == "active"
          assert api_key.runtime_revocation_epoch == entitlement.api_key_runtime_epoch
        end
      end)

      cleanup_fixture(fixture)
    end
  end

  # Ten seconds keeps the key valid across `arm` under CI scheduling pressure
  # while staying well inside the entitlement's own 30-second window, so the
  # overridden clock below expires the key and nothing else.
  @key_expiry_window_seconds 10

  defp put_key_expiry!(fixture, :expires_between_arm_and_consume),
    do: put_key_expiry!(fixture, DateTime.add(db_clock!(), @key_expiry_window_seconds, :second))

  defp put_key_expiry!(fixture, :valid_unexpired),
    do: put_key_expiry!(fixture, DateTime.add(db_clock!(), 3_600, :second))

  defp put_key_expiry!(fixture, :nil_expiry) do
    assert is_nil(fixture.api_key.expires_at)
    fixture
  end

  defp put_key_expiry!(fixture, scenario) when scenario in [:stale_epoch, :inactive_pool],
    do: fixture

  defp put_key_expiry!(fixture, %DateTime{} = expires_at) do
    api_key =
      APIKey
      |> Repo.get!(fixture.api_key.id)
      |> Ecto.Changeset.change(expires_at: expires_at)
      |> Repo.update!()

    %{fixture | api_key: api_key}
  end

  defp assert_key_valid_when_armed!(%{api_key: %APIKey{expires_at: nil}}, _armed), do: :ok

  defp assert_key_valid_when_armed!(%{api_key: %APIKey{expires_at: expires_at}}, armed) do
    assert DateTime.compare(armed.armed_at, expires_at) == :lt,
           "the key expired before replay was armed; widen @key_expiry_window_seconds"
  end

  defp cross_between_arm_and_consume!(fixture, armed, :expires_between_arm_and_consume) do
    crossed_at = DateTime.add(fixture.api_key.expires_at, 1, :microsecond)
    # The entitlement itself is still live at the crossed instant, so only the
    # key's own expiry can refuse the consume.
    assert DateTime.compare(crossed_at, armed.expires_at) == :lt
    set_replay_db_now!(crossed_at)
  end

  defp cross_between_arm_and_consume!(fixture, _armed, :stale_epoch) do
    api_key = Repo.get!(APIKey, fixture.api_key.id)

    api_key
    |> Ecto.Changeset.change(runtime_revocation_epoch: api_key.runtime_revocation_epoch + 1)
    |> Repo.update!()
  end

  defp cross_between_arm_and_consume!(fixture, _armed, :inactive_pool) do
    Pool
    |> Repo.get!(fixture.pool.id)
    |> Ecto.Changeset.change(status: "disabled")
    |> Repo.update!()
  end

  defp cross_between_arm_and_consume!(_fixture, _armed, _control), do: :ok

  # Exact original definition from the entitlements migration, re-verified
  # here against the same contract the schema contract test pins: volatile,
  # parallel safe, `search_path=pg_catalog`, and a clock that moves again.
  defp restore_replay_db_now! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION public.request_replay_db_now()
    RETURNS timestamp with time zone
    LANGUAGE sql VOLATILE PARALLEL SAFE
    SET search_path = pg_catalog
    AS $$ SELECT clock_timestamp() $$
    """)

    assert %{rows: [["v", "s", ["search_path=pg_catalog"]]]} =
             Repo.query!("""
             SELECT provolatile::text, proparallel::text, proconfig
             FROM pg_proc
             WHERE pronamespace = 'public'::regnamespace
               AND proname = 'request_replay_db_now'
             """)

    assert %{rows: [[true]]} =
             Repo.query!("SELECT request_replay_db_now() <= clock_timestamp()")

    :ok
  end

  defp db_clock! do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [])

    case now do
      %DateTime{} -> now
      %NaiveDateTime{} -> DateTime.from_naive!(now, "Etc/UTC")
    end
  end

  defp ledger_snapshot(fixture) do
    entries =
      Repo.all(
        from entry in LedgerEntry,
          where: entry.request_id == ^fixture.request.id,
          select: entry.entry_kind
      )

    %{
      total: length(entries),
      reservations: Enum.count(entries, &(&1 == "reservation"))
    }
  end

  defp upstream_send_count(fixture) do
    {:ok, owner} = WebsocketOwnerSession.lookup(fixture.session.id)
    Agent.get(:sys.get_state(owner).upstream_pid, & &1)
  end

  defp await_replay_blocked!(waiter, holder, expires_at, deadline) do
    %{rows: [[state, wait_event_type, wait_event, blockers, ungranted_lock_count, expired]]} =
      Repo.query!(
        """
        SELECT activity.state,
               activity.wait_event_type,
               activity.wait_event,
               pg_blocking_pids($1),
               count(locks.*) FILTER (WHERE locks.granted = false),
               clock_timestamp() > $2::timestamptz
        FROM pg_stat_activity AS activity
        LEFT JOIN pg_locks AS locks ON locks.pid = activity.pid
        WHERE activity.pid = $1
        GROUP BY activity.state, activity.wait_event_type, activity.wait_event
        """,
        [waiter, expires_at]
      )

    cond do
      holder in blockers and wait_event_type == "Lock" and expired ->
        %{
          state: state,
          wait_event_type: wait_event_type,
          wait_event: wait_event,
          blockers: blockers,
          ungranted_lock_count: ungranted_lock_count
        }

      System.monotonic_time(:millisecond) < deadline ->
        await_replay_blocked!(waiter, holder, expires_at, deadline)

      true ->
        flunk("consume did not wait on the session lock across expiry")
    end
  end

  # Registered straight after the commit, never scoped in `try/after`: `run_concurrently/1` and
  # the session lock holders run in linked tasks, so an assertion failing in one kills the test
  # process before an enclosing `after` runs, and the committed pool, identity, entitlement and
  # replay owner would outlive the test. The inline `cleanup_fixture/1` calls stay because they
  # run before `allow_committed_owner/1`'s own teardown stops the database owner the replay owner
  # is allowed on; the registered pass then finds nothing left. `replay_fixture/1` derives every
  # key while it commits, so this cannot be registered earlier and a fixture that fails partway
  # through is not covered. The bootstrap owner is committed and registered first instead, keyed on
  # its email, so its removal runs after this fixture's and covers a bootstrap that failed.
  defp committed_replay_fixture! do
    %{user: owner} = committed_bootstrap_owner_fixture!()

    fixture =
      Sandbox.unboxed_run(Repo, fn -> replay_fixture(reservation?: true, owner: owner) end)

    register_unboxed_cleanup!(fn -> delete_replay_fixture!(fixture) end)
    fixture
  end

  defp cleanup_fixture(fixture) do
    Sandbox.unboxed_run(Repo, fn -> delete_replay_fixture!(fixture) end)
  end

  defp delete_replay_fixture!(fixture) do
    case WebsocketOwnerSession.lookup(fixture.session.id) do
      {:ok, owner} ->
        Sandbox.allow(Repo, self(), owner)
        stop_replay_owner(fixture.session.id)

      {:error, :owner_unavailable} ->
        :ok
    end

    Repo.delete_all(from row in RequestReplayEntitlement, where: row.request_id == ^fixture.request.id)

    CodexPooler.PoolerFixtures.delete_committed_pools!([fixture.pool.id])

    Repo.delete_all(
      from row in CodexPooler.Upstreams.Schemas.UpstreamIdentity,
        where: row.id == ^fixture.identity.id
    )

    :ok
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

  defp run_concurrently(operations, order \\ :concurrent) do
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

    case order do
      :concurrent ->
        Enum.each(tasks, &send(&1.pid, {:run, ref}))
        Enum.map(tasks, &Task.await(&1, 15_000))

      :consume_first ->
        run_ordered(tasks, ref, 0)

      :mutation_first ->
        run_ordered(tasks, ref, 1)
    end
  end

  defp run_ordered(tasks, ref, first_index) do
    first = Enum.at(tasks, first_index)
    second = Enum.at(tasks, 1 - first_index)
    send(first.pid, {:run, ref})
    first_result = Task.await(first, 15_000)
    send(second.pid, {:run, ref})
    second_result = Task.await(second, 15_000)
    if first_index == 0, do: [first_result, second_result], else: [second_result, first_result]
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

  defp deadlock_count do
    %{rows: [[deadlocks]]} =
      Repo.query!("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()")

    deadlocks
  end
end
