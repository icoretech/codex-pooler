defmodule CodexPooler.Gateway.Persistence.SessionContinuityLockingTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import CodexPooler.UnboxedFixture, only: [register_unboxed_cleanup!: 1]
  import Ecto.Query

  alias CodexPooler.Access
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Accounting.Request

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    SessionContinuity
  }

  alias CodexPooler.Gateway.Persistence.SessionContinuity.{Aliases, ExpiredSessions}
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @contention_context {__MODULE__, :contention_context}
  @contention_sequence {__MODULE__, :contention_sequence}
  @contention_paused {__MODULE__, :contention_paused}
  @frozen_context {__MODULE__, :frozen_context}
  @frozen_sequence {__MODULE__, :frozen_sequence}
  @frozen_paused {__MODULE__, :frozen_paused}
  @direction_iterations 10
  @start_first_direction "session_lease_start_first"
  @renewal_first_direction "session_lease_renewal_first"
  @deadlock_context {__MODULE__, :replacement_deadlock_context}
  @deadlock_paused {__MODULE__, :replacement_deadlock_paused}
  # A real PostgreSQL lock_timeout is the behavior under test: each bounded
  # renewal case waits it out once while the blocker holds its row, so a case
  # runs for about one second. The same window bounds the blocked observation.
  @bounded_renewal_lock_timeout_ms 1_000

  describe "session continuity baseline characterization" do
    @tag :session_continuity_pin
    test "missing renewal preserves owner-unavailable nil semantics and rolls back" do
      session_count = Repo.aggregate(CodexSession, :count)
      lease_count = Repo.aggregate(BridgeOwnerLease, :count)

      assert {:error, :owner_unavailable} =
               SessionContinuity.renew_owner_token(
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate(),
                 request_options(bridge_owner_lease_ttl_seconds: 120)
               )

      assert Repo.aggregate(CodexSession, :count) == session_count
      assert Repo.aggregate(BridgeOwnerLease, :count) == lease_count
    end

    @tag :session_continuity_pin
    test "missing continuity registration preserves raise semantics and rolls back" do
      missing_session = %CodexSession{id: Ecto.UUID.generate()}
      alias_count = Repo.aggregate(BridgeSessionAlias, :count)
      lease_count = Repo.aggregate(BridgeOwnerLease, :count)

      assert_raise Ecto.NoResultsError, fn ->
        SessionContinuity.register_codex_session_continuity(
          missing_session,
          %{},
          %{"id" => "response-placeholder"},
          request_options([])
        )
      end

      assert Repo.aggregate(BridgeSessionAlias, :count) == alias_count
      assert Repo.aggregate(BridgeOwnerLease, :count) == lease_count
    end

    @tag :session_continuity_pin
    test "owner release remains a transactional lease-only operation" do
      %{session: session, token: token} = owner_session_fixture()
      session_before = Repo.get!(CodexSession, session.id)

      {result, events} =
        capture_repo_queries(fn ->
          SessionContinuity.release_owner_lease(session.id, token, "owner_drained")
        end)

      assert :ok = result
      refute Enum.any?(events, &(&1.source == "codex_sessions"))

      assert Enum.any?(events, fn event ->
               event.source == "bridge_owner_leases" and event.command == "SELECT" and
                 event.for_update? and event.in_transaction?
             end)

      assert Enum.any?(events, fn event ->
               event.source == "bridge_owner_leases" and event.command == "UPDATE" and
                 event.in_transaction?
             end)

      assert %BridgeOwnerLease{status: "released"} =
               Repo.get!(BridgeOwnerLease, token_lease_id(token))

      assert Repo.get!(CodexSession, session.id) == session_before
    end

    @tag :session_continuity_pin
    test "turn sequence allocation is part of the insert statement" do
      %{auth: auth, session: session} = owner_session_fixture()
      request = request_fixture(auth, %{status: "in_progress", completed_at: nil})

      {result, events} =
        capture_repo_queries(fn ->
          SessionContinuity.start_codex_turn(
            session,
            request,
            RequestOptions.for_websocket(%{})
          )
        end)

      assert {:ok, %CodexPooler.Gateway.Persistence.CodexTurn{turn_sequence: 1}} = result

      assert Enum.any?(events, fn event ->
               event.command == "INSERT" and event.in_transaction? and
                 String.contains?(event.query, "INSERT INTO codex_turns") and
                 String.contains?(event.query, "MAX(turn_sequence)")
             end)

      refute Enum.any?(events, fn event ->
               event.source == "codex_turns" and event.command == "SELECT"
             end)
    end

    @tag :session_continuity_pin
    @tag timeout: 120_000
    test "turn allocation loads returned columns in a fresh runtime" do
      fixture = unboxed_fresh_runtime_turn_fixture()

      script = """
      alias CodexPooler.Accounting.Request
      alias CodexPooler.Gateway.Payloads.RequestOptions
      alias CodexPooler.Gateway.Persistence.{CodexSession, SessionContinuity}
      alias CodexPooler.Repo
      alias Ecto.Adapters.SQL.Sandbox

      [session_id, request_id] = System.argv()
      :ok = Sandbox.mode(Repo, :manual)
      :ok = Sandbox.checkout(Repo)

      try do
        :erlang.binary_to_existing_atom("turn_sequence")
        raise "turn_sequence was already interned"
      rescue
        ArgumentError -> :ok
      end

      session = Repo.get!(CodexSession, session_id)
      request = Repo.get!(Request, request_id)

      {:ok, turn} =
        SessionContinuity.start_codex_turn(
          session,
          request,
          RequestOptions.for_websocket(%{})
        )

      sequence_key = :erlang.binary_to_existing_atom("turn_sequence")
      1 = Map.fetch!(turn, sequence_key)
      IO.puts("fresh runtime turn allocation: ok")
      """

      {output, status} =
        System.cmd(
          "mix",
          [
            "run",
            "--no-compile",
            "-e",
            script,
            "--",
            fixture.session_id,
            fixture.request_id
          ],
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "fresh runtime turn allocation: ok"
    end

    test "alias resolution uses one priority-ordered row lock" do
      auth = auth_fixture()
      high_priority_alias = "high-priority-#{System.unique_integer([:positive, :monotonic])}"
      low_priority_alias = "low-priority-#{System.unique_integer([:positive, :monotonic])}"

      assert {:ok, %CodexSession{} = high_priority_session} =
               Gateway.start_codex_session(
                 auth,
                 request_options(accepted_turn_state: high_priority_alias)
               )

      assert {:ok, %CodexSession{} = low_priority_session} =
               Gateway.start_codex_session(
                 auth,
                 request_options(accepted_turn_state: "unused-#{low_priority_alias}")
               )

      insert_alias!(low_priority_session, auth, "previous_response_id", low_priority_alias)

      opts =
        request_options(
          accepted_turn_state: high_priority_alias,
          previous_response_id: low_priority_alias
        )

      {{:ok, resolved_session}, events} =
        capture_detailed_repo_queries(fn ->
          Repo.transaction(fn ->
            Aliases.resolved_session_for_update(
              auth,
              opts,
              high_priority_session.session_key,
              DateTime.utc_now() |> DateTime.truncate(:microsecond)
            )
          end)
        end)

      assert resolved_session.id == high_priority_session.id

      assert [alias_lookup] =
               Enum.filter(events, fn event ->
                 event.operation == "SELECT" and
                   String.contains?(event.query, ~s(JOIN "bridge_session_aliases"))
               end)

      assert alias_lookup.for_update?
      assert String.contains?(alias_lookup.query, "CASE WHEN")
    end

    test "alias registration uses one batched upsert for all candidates" do
      %{auth: auth, session: session} = owner_session_fixture()

      opts =
        request_options(
          accepted_turn_state: "batch-turn-#{System.unique_integer([:positive, :monotonic])}",
          previous_response_id:
            "batch-previous-#{System.unique_integer([:positive, :monotonic])}",
          response_id: "batch-response-#{System.unique_integer([:positive, :monotonic])}",
          session_header: "batch-header-#{System.unique_integer([:positive, :monotonic])}"
        )

      {{:ok, :ok}, events} =
        capture_detailed_repo_queries(fn ->
          Repo.transaction(fn ->
            Aliases.register!(
              session,
              auth,
              opts,
              DateTime.utc_now() |> DateTime.truncate(:microsecond)
            )
          end)
        end)

      assert [alias_insert] =
               Enum.filter(events, fn event ->
                 event.source == "bridge_session_aliases" and event.operation == "INSERT"
               end)

      assert String.contains?(String.upcase(alias_insert.query), "ON CONFLICT")

      assert Repo.aggregate(
               from(alias_record in BridgeSessionAlias,
                 where:
                   alias_record.codex_session_id == ^session.id and
                     alias_record.status == "active"
               ),
               :count
             ) >= 5
    end

    @tag :session_continuity_order_contract
    test "replacement and continuity registration lock session before owner lease" do
      %{session: replacement_session} = owner_session_fixture()

      {replacement_result, replacement_events} =
        capture_detailed_repo_queries(fn ->
          SessionContinuity.replace_unavailable_owner_lease(
            replacement_session,
            request_options(owner_instance_id: "node-b")
          )
        end)

      assert {:ok, %CodexSession{}} = replacement_result
      assert_session_before_lease_lock!(replacement_events)

      %{session: continuity_session} = owner_session_fixture()

      {continuity_result, continuity_events} =
        capture_detailed_repo_queries(fn ->
          SessionContinuity.register_codex_session_continuity(
            continuity_session,
            %{},
            %{"id" => "response-placeholder"},
            request_options([])
          )
        end)

      assert :ok = continuity_result
      assert_session_before_lease_lock!(continuity_events)
    end
  end

  describe "session continuity session and owner-lease contention" do
    @tag :session_continuity_contention
    @tag timeout: 30_000
    test "renewal cannot revive an owner that expires while waiting for the session lock" do
      fixture = unboxed_owner_session_fixture("renewal-expiry-wait", 1)
      fixture = set_unboxed_owner_deadline!(fixture, 1)
      parent = self()
      ref = make_ref()

      blocker =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              session =
                Repo.one!(
                  from session in CodexSession,
                    where: session.id == ^fixture.session.id,
                    lock: "FOR UPDATE"
                )

              backend_pid = backend_pid!()
              send(parent, {:renewal_expiry_blocker_ready, ref, backend_pid, session})

              receive do
                {:release_renewal_expiry_blocker, ^ref} -> :ok
              after
                15_000 -> raise "renewal expiry blocker was not released"
              end
            end)
          end)
        end)

      try do
        assert_receive {:renewal_expiry_blocker_ready, ^ref, blocker_backend_pid, locked_session},
                       5_000

        before_session = unboxed_get_session!(fixture.session.id)
        before_lease = unboxed_active_lease!(fixture.session.id)

        renewal =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              backend_pid = backend_pid!()
              send(parent, {:renewal_expiry_waiter_ready, ref, backend_pid})

              SessionContinuity.renew_owner_token(
                fixture.session.id,
                fixture.token,
                request_options(bridge_owner_lease_ttl_seconds: 120)
              )
            end)
          end)

        Process.put({__MODULE__, ref, :renewal}, renewal)

        assert_receive {:renewal_expiry_waiter_ready, ^ref, waiter_backend_pid}, 5_000
        assert waiter_backend_pid != blocker_backend_pid

        observation =
          Sandbox.unboxed_run(Repo, fn ->
            observe_session_block(waiter_backend_pid, blocker_backend_pid, "SELECT")
          end)

        assert observation.wait_event_type == "Lock"
        assert blocker_backend_pid in observation.blocking_pids

        milliseconds_to_expiry =
          DateTime.diff(locked_session.owner_lease_expires_at, DateTime.utc_now(), :millisecond)

        assert milliseconds_to_expiry > 0

        receive do
        after
          milliseconds_to_expiry + 50 -> :ok
        end

        send(blocker.pid, {:release_renewal_expiry_blocker, ref})

        assert {:error, :owner_unavailable} = Task.await(renewal, 15_000)
        assert {:ok, _} = Task.await(blocker, 15_000)

        after_session = unboxed_get_session!(fixture.session.id)
        after_lease = unboxed_active_lease!(fixture.session.id)

        assert after_session.owner_lease_expires_at == before_session.owner_lease_expires_at
        assert after_session.last_heartbeat_at == before_session.last_heartbeat_at
        assert after_session.updated_at == before_session.updated_at
        assert after_lease.expires_at == before_lease.expires_at
        assert after_lease.renewed_at == before_lease.renewed_at
        assert after_lease.updated_at == before_lease.updated_at

        report_atomic_renewal(%{
          kind: "owner_renewal_expiry_wait",
          blocking_observed?: true,
          blocker_count: length(observation.blocking_pids),
          result: "owner_unavailable",
          session_deadline_unchanged?: true,
          lease_deadline_unchanged?: true
        })
      after
        send(blocker.pid, {:release_renewal_expiry_blocker, ref})
        shutdown_task(blocker)

        case Process.delete({__MODULE__, ref, :renewal}) do
          %Task{} = renewal -> shutdown_task(renewal)
          nil -> :ok
        end
      end
    end

    @tag :session_continuity_contention
    @tag :session_continuity_red
    test "session_lease_start_first blocks renewal on session before lease" do
      records =
        run_direction(@start_first_direction, fn fixture ->
          {
            fn ->
              Gateway.start_codex_session(fixture.auth, %{
                session_key: fixture.session_key,
                owner_instance_id: "node-a"
              })
            end,
            fn ->
              SessionContinuity.renew_owner_token(
                fixture.session.id,
                fixture.token,
                request_options(bridge_owner_lease_ttl_seconds: 120)
              )
            end
          }
        end)

      assert length(records) == @direction_iterations
      report_direction(@start_first_direction, records)
    end

    @tag :session_continuity_contention
    test "session_lease_renewal_first blocks start on session before lease" do
      records =
        run_direction(@renewal_first_direction, fn fixture ->
          {
            fn ->
              SessionContinuity.renew_owner_token(
                fixture.session.id,
                fixture.token,
                request_options(bridge_owner_lease_ttl_seconds: 120)
              )
            end,
            fn ->
              Gateway.start_codex_session(fixture.auth, %{
                session_key: fixture.session_key,
                owner_instance_id: "node-a"
              })
            end
          }
        end)

      assert length(records) == @direction_iterations
      report_direction(@renewal_first_direction, records)
    end

    @tag :session_continuity_contention
    @tag timeout: 30_000
    test "a bounded renewal behind a session holder waiting on the key-wide mutex names that wait" do
      fixture = unboxed_owner_session_fixture("bounded-renewal-api-key-chain", 1)
      api_key = fixture.auth.api_key
      parent = self()
      ref = make_ref()

      # The key-wide reservation mutex is shared by every session of the key;
      # this holder takes it the way every runtime reservation does. The
      # `api_keys` row itself is only read under the reader lock, so the wait
      # this chain reports is the mutex, not the row.
      key_holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              {:ok, _authorization} =
                Access.authorize_api_key_runtime_turn(
                  api_key.id,
                  api_key.runtime_revocation_epoch
                )

              send(parent, {:api_key_holder_ready, ref, backend_pid!()})

              receive do
                {:release_api_key_holder, ^ref} -> :ok
              after
                15_000 -> raise "API key holder was not released"
              end
            end)
          end)
        end)

      Process.put({__MODULE__, ref, :key_holder}, key_holder)

      try do
        assert_receive {:api_key_holder_ready, ^ref, key_holder_backend_pid}, 5_000

        # Session first, then the API key: the HTTP reservation's lock order.
        session_holder =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Repo.transaction(fn ->
                _session = SessionContinuity.lock_codex_session_for_turn(fixture.session)
                send(parent, {:session_holder_locked, ref, backend_pid!()})

                Access.authorize_api_key_runtime_turn(
                  api_key.id,
                  api_key.runtime_revocation_epoch
                )
              end)
            end)
          end)

        Process.put({__MODULE__, ref, :session_holder}, session_holder)

        assert_receive {:session_holder_locked, ^ref, session_holder_backend_pid}, 5_000

        assert observe_session_holder_wait!(session_holder_backend_pid, key_holder_backend_pid) ==
                 "api_key_reservation_window"

        renewal =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              send(parent, {:bounded_renewal_waiter_ready, ref, backend_pid!()})
              bounded_renewal(fixture)
            end)
          end)

        Process.put({__MODULE__, ref, :renewal}, renewal)
        assert_receive {:bounded_renewal_waiter_ready, ^ref, waiter_backend_pid}, 5_000

        assert observe_renewal_lock_wait!(waiter_backend_pid, session_holder_backend_pid) ==
                 "codex_sessions"

        assert {:error,
                {:lock_timeout,
                 %{relation: :codex_sessions, waiter_pid: ^waiter_backend_pid, blocker: holder}}} =
                 Task.await(renewal, 15_000)

        assert holder.pid == session_holder_backend_pid

        assert %{
                 state: "active",
                 wait_event_type: "Lock",
                 waiting_relation: "api_key_reservation_window"
               } = holder

        assert holder.query_fingerprint =~ ~r/\A[0-9a-f]{12}\z/
        assert is_integer(holder.transaction_age_ms) and holder.transaction_age_ms >= 0

        send(key_holder.pid, {:release_api_key_holder, ref})
        assert {:ok, :ok} = Task.await(key_holder, 15_000)
        assert {:ok, {:ok, _authorization}} = Task.await(session_holder, 15_000)
      after
        send(key_holder.pid, {:release_api_key_holder, ref})

        for role <- [:renewal, :session_holder, :key_holder] do
          case Process.delete({__MODULE__, ref, role}) do
            %Task{} = task -> shutdown_task(task)
            nil -> :ok
          end
        end
      end
    end

    for held_row <- [:session, :lease] do
      @tag :session_continuity_contention
      @tag timeout: 30_000
      test "a bounded renewal ends its wait on a held #{held_row} row inside PostgreSQL" do
        held_row = unquote(held_row)
        fixture = unboxed_owner_session_fixture("bounded-renewal-#{held_row}", 1)
        parent = self()
        ref = make_ref()

        blocker =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Repo.transaction(fn ->
                lock_renewal_row!(held_row, fixture.session.id)
                send(parent, {:bounded_renewal_blocker_ready, ref, backend_pid!()})

                receive do
                  {:release_bounded_renewal_blocker, ^ref} -> :ok
                after
                  15_000 -> raise "bounded renewal blocker was not released"
                end
              end)
            end)
          end)

        try do
          assert_receive {:bounded_renewal_blocker_ready, ^ref, blocker_backend_pid}, 5_000
          before_session = unboxed_get_session!(fixture.session.id)
          before_lease = unboxed_active_lease!(fixture.session.id)

          renewal =
            Task.async(fn ->
              Sandbox.unboxed_run(Repo, fn ->
                send(parent, {:bounded_renewal_waiter_ready, ref, backend_pid!()})
                bounded_renewal(fixture)
              end)
            end)

          Process.put({__MODULE__, ref, :renewal}, renewal)

          assert_receive {:bounded_renewal_waiter_ready, ^ref, waiter_backend_pid}, 5_000
          assert waiter_backend_pid != blocker_backend_pid

          assert observe_renewal_lock_wait!(waiter_backend_pid, blocker_backend_pid) ==
                   renewal_row_relation(held_row)

          # The blocker still holds its row, so only PostgreSQL can end the wait,
          # and the still-open renewal transaction names the idle holder.
          assert {:error,
                  {:lock_timeout, %{relation: relation, waiter_pid: ^waiter_backend_pid} = wait}} =
                   Task.await(renewal, 15_000)

          holder = wait.blocker
          assert holder.pid == blocker_backend_pid
          # The configured Repo application_name names the holder's role.
          assert holder.application_name == "codex_pooler_test"

          assert Process.alive?(blocker.pid)
          assert Atom.to_string(relation) == renewal_row_relation(held_row)

          assert %{state: "idle in transaction", waiting_relation: nil} = holder
          assert holder.query_fingerprint == statement_fingerprint("SELECT pg_backend_pid()")
          assert is_integer(holder.transaction_age_ms) and holder.transaction_age_ms >= 0

          send(blocker.pid, {:release_bounded_renewal_blocker, ref})
          assert {:ok, :ok} = Task.await(blocker, 15_000)

          after_session = unboxed_get_session!(fixture.session.id)
          after_lease = unboxed_active_lease!(fixture.session.id)
          assert after_session.owner_lease_expires_at == before_session.owner_lease_expires_at
          assert after_session.last_heartbeat_at == before_session.last_heartbeat_at
          assert after_lease.expires_at == before_lease.expires_at
          assert after_lease.renewed_at == before_lease.renewed_at

          assert {:ok, %CodexSession{} = renewed} =
                   Sandbox.unboxed_run(Repo, fn -> bounded_renewal(fixture) end)

          assert DateTime.compare(
                   renewed.owner_lease_expires_at,
                   before_session.owner_lease_expires_at
                 ) == :gt
        after
          send(blocker.pid, {:release_bounded_renewal_blocker, ref})
          shutdown_task(blocker)

          case Process.delete({__MODULE__, ref, :renewal}) do
            %Task{} = renewal -> shutdown_task(renewal)
            nil -> :ok
          end
        end
      end
    end
  end

  describe "replacement turn and predecessor interruption lock order" do
    @tag :session_continuity_deadlock
    @tag timeout: 120_000
    test "replacement start locks the session before its claimed request" do
      fixture = unboxed_replacement_deadlock_fixture()

      with_replacement_deadlock_query_handler(fn ->
        run_replacement_deadlock_schedule(fixture)
      end)
    end
  end

  describe "session continuity expired-session frozen boundary" do
    @tag :session_continuity_frozen
    test "close_for_key freezes the old id while a replacement blocks on the partial unique index" do
      fixture = unboxed_expired_replacement_fixture()

      record =
        with_frozen_query_handler(fn ->
          run_frozen_replacement_schedule(fixture)
        end)

      assert record.boundary_signature == expired_boundary_signature()
      report_frozen_schedule(record)
    end

    @tag :session_continuity_start_boundary
    test "real start flow invokes the frozen boundary before inserting the replacement" do
      fixture = unboxed_expired_session_fixture("session_continuity-start-boundary")

      {result, events} =
        capture_detailed_repo_queries(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Gateway.start_codex_session(fixture.auth, %{
              session_key: fixture.session_key,
              owner_instance_id: "node-replacement"
            })
          end)
        end)

      assert {:ok, %CodexSession{} = replacement} = result
      refute replacement.id == fixture.session.id
      assert boundary_signature(events) == expired_boundary_signature()

      boundary_close =
        Enum.find_index(events, fn event ->
          event.source == "codex_sessions" and event.operation == "UPDATE"
        end)

      replacement_insert =
        Enum.find_index(events, fn event ->
          event.source == "codex_sessions" and event.operation == "INSERT"
        end)

      assert is_integer(boundary_close)
      assert is_integer(replacement_insert)
      assert boundary_close < replacement_insert

      assert %CodexSession{status: "closed"} =
               Sandbox.unboxed_run(Repo, fn -> Repo.get!(CodexSession, fixture.session.id) end)

      assert %CodexSession{status: "active"} =
               Sandbox.unboxed_run(Repo, fn -> Repo.get!(CodexSession, replacement.id) end)

      report_start_boundary(events, fixture.session.id)
    end
  end

  defp run_frozen_replacement_schedule(fixture) do
    parent = self()
    ref = make_ref()
    observer = start_observer(parent, ref)

    task_a =
      start_frozen_operation(parent, ref, fn ->
        Repo.transaction(fn ->
          ExpiredSessions.close_for_key!(
            fixture.auth.pool.id,
            fixture.auth.api_key.id,
            fixture.session_key,
            fixture.boundary_now
          )
        end)
      end)

    task_b =
      start_operation(
        parent,
        ref,
        :b,
        fn -> update_closed_replacement!(fixture) end,
        pause?: false
      )

    try do
      {_observer_pid, observer_backend_pid} = await_observer_ready!(ref)
      {_a_pid, a_backend_pid} = await_frozen_ready!(ref)
      {_b_pid, b_backend_pid} = await_operation_ready!(ref, :b)

      assert MapSet.size(MapSet.new([observer_backend_pid, a_backend_pid, b_backend_pid])) == 3

      send(task_a.pid, {:session_continuity_run_frozen, ref})
      {events, close_event} = await_frozen_close_barrier!(ref, [])

      send(task_b.pid, {:session_continuity_run, ref})

      observation =
        observe_blocked_session_operation!(
          observer,
          ref,
          b_backend_pid,
          a_backend_pid,
          "UPDATE"
        )

      send(task_a.pid, {:session_continuity_release_frozen, ref})

      assert {:ok, {:ok, %{closed_count: 1, preferred_assignment_id: nil}}} =
               Task.await(task_a, 10_000)

      assert {:ok, %CodexSession{status: "interrupted"}} = Task.await(task_b, 10_000)

      send(observer.pid, {:session_continuity_stop_observer, ref})
      assert :ok = Task.await(observer, 5_000)

      events = drain_frozen_events(ref, events)
      assert close_event.source == "codex_sessions"
      assert_frozen_boundary_events!(events, fixture.session.id)

      assert_frozen_replacement_state!(fixture)

      assert {:ok, %{closed_count: 1, preferred_assignment_id: nil}} =
               Sandbox.unboxed_run(Repo, fn ->
                 Repo.transaction(fn ->
                   ExpiredSessions.close_for_key!(
                     fixture.auth.pool.id,
                     fixture.auth.api_key.id,
                     fixture.session_key,
                     DateTime.add(fixture.boundary_now, 10, :second)
                   )
                 end)
               end)

      assert %CodexSession{status: "closed"} =
               Sandbox.unboxed_run(Repo, fn ->
                 Repo.get!(CodexSession, fixture.replacement.id)
               end)

      %{
        kind: "expired_sessions_frozen_set",
        backend_pid_hashes:
          Enum.map([a_backend_pid, b_backend_pid, observer_backend_pid], &sha256/1),
        blocked_replacement: sanitize_block(observation),
        frozen_session_id_sha256: sha256(fixture.session.id),
        replacement_id_sha256: sha256(fixture.replacement.id),
        boundary_signature: boundary_signature(events),
        ordered_id_hashes: ordered_id_hashes(events),
        replacement_untouched_by_first_boundary: true,
        replacement_closed_by_second_boundary: true,
        final_field_names: ["status", "owner_lease_expires_at", "closed_at", "updated_at"]
      }
    after
      send(task_a.pid, {:session_continuity_release_frozen, ref})
      send(task_b.pid, {:session_continuity_release, ref, :b, :session})
      send(task_b.pid, {:session_continuity_release, ref, :b, :lease})
      send(observer.pid, {:session_continuity_stop_observer, ref})
      shutdown_task(task_a)
      shutdown_task(task_b)
      shutdown_task(observer)
    end
  end

  defp run_replacement_deadlock_schedule(fixture) do
    parent = self()
    ref = make_ref()
    observer = start_observer(parent, ref)

    replacement =
      start_deadlock_operation(parent, ref, :replacement, fn ->
        Repo.transaction(fn ->
          request =
            Repo.one!(
              from request in Request,
                where: request.id == ^fixture.replacement_request.id,
                lock: "FOR UPDATE"
            )

          SessionContinuity.start_codex_turn(
            fixture.session,
            request,
            request_options(pool_upstream_assignment_id: fixture.assignment.id)
          )
        end)
      end)

    predecessor =
      start_deadlock_operation(parent, ref, :predecessor, fn ->
        Repo.transaction(fn ->
          session =
            Repo.one!(
              from session in CodexSession,
                where: session.id == ^fixture.session.id,
                lock: "FOR UPDATE"
            )

          request =
            Repo.one!(
              from request in Request,
                where: request.id == ^fixture.predecessor_request.id,
                lock: "FOR UPDATE"
            )

          {session, request}
        end)
      end)

    try do
      {_observer_pid, observer_backend_pid} = await_observer_ready!(ref)
      {_replacement_pid, replacement_backend_pid} = await_deadlock_ready!(ref, :replacement)
      {_predecessor_pid, predecessor_backend_pid} = await_deadlock_ready!(ref, :predecessor)

      assert MapSet.size(
               MapSet.new([
                 observer_backend_pid,
                 replacement_backend_pid,
                 predecessor_backend_pid
               ])
             ) == 3

      send(replacement.pid, {:replacement_deadlock_run, ref})
      await_deadlock_barrier!(ref, :replacement, :request)

      send(predecessor.pid, {:replacement_deadlock_run, ref})
      await_deadlock_barrier!(ref, :predecessor, :session)

      send(replacement.pid, {:replacement_deadlock_release, ref, :replacement, :request})

      replacement_block =
        observe_relation_block!(
          observer,
          ref,
          replacement_backend_pid,
          predecessor_backend_pid,
          "codex_sessions"
        )

      send(predecessor.pid, {:replacement_deadlock_release, ref, :predecessor, :session})

      assert {:ok, {:ok, {session, request}}} = Task.await(predecessor, 15_000)
      assert session.id == fixture.session.id
      assert request.id == fixture.predecessor_request.id

      assert {:ok, {:ok, {:ok, %CodexPooler.Gateway.Persistence.CodexTurn{} = turn}}} =
               Task.await(replacement, 15_000)

      assert turn.request_id == fixture.replacement_request.id
      assert replacement_block.wait_event_type == "Lock"
      assert replacement_block.relation == "codex_sessions"

      assert Sandbox.unboxed_run(Repo, fn ->
               Repo.aggregate(
                 from(turn in CodexPooler.Gateway.Persistence.CodexTurn,
                   where: turn.request_id == ^fixture.replacement_request.id
                 ),
                 :count
               )
             end) == 1

      send(observer.pid, {:session_continuity_stop_observer, ref})
      assert :ok = Task.await(observer, 5_000)
    after
      send(replacement.pid, {:replacement_deadlock_release, ref, :replacement, :request})
      send(predecessor.pid, {:replacement_deadlock_release, ref, :predecessor, :session})

      if Process.alive?(observer.pid) do
        send(observer.pid, {:session_continuity_stop_observer, ref})
      end

      shutdown_task(replacement)
      shutdown_task(predecessor)
      shutdown_task(observer)
    end
  end

  defp start_deadlock_operation(parent, ref, role, operation) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        backend_pid = backend_pid!()
        Process.put(@deadlock_context, %{parent: parent, ref: ref, role: role})
        send(parent, {:replacement_deadlock_ready, ref, role, self(), backend_pid})

        try do
          receive do
            {:replacement_deadlock_run, ^ref} -> safely_run(operation)
          after
            10_000 -> {:error, :replacement_deadlock_start_timeout}
          end
        after
          Process.delete(@deadlock_context)
          Process.delete({@deadlock_paused, :request})
          Process.delete({@deadlock_paused, :session})
        end
      end)
    end)
  end

  defp with_replacement_deadlock_query_handler(fun) when is_function(fun, 0) do
    handler_id =
      {__MODULE__, :replacement_deadlock, System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          handle_replacement_deadlock_query(metadata)
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  defp handle_replacement_deadlock_query(metadata) do
    case Process.get(@deadlock_context) do
      %{parent: parent, ref: ref, role: role} = context ->
        event = contention_event(metadata, 0)

        family = replacement_deadlock_family(role, event)

        if family && not Process.get({@deadlock_paused, family}, false) do
          Process.put({@deadlock_paused, family}, true)
          send(parent, {:replacement_deadlock_barrier, ref, role, family, event})

          receive do
            {:replacement_deadlock_release, ^ref, ^role, ^family} -> :ok
          after
            10_000 -> raise "replacement deadlock #{family} barrier was not released"
          end
        end

        context

      _context ->
        :ok
    end
  end

  defp replacement_deadlock_family(:replacement, %{source: "requests", for_update?: true}),
    do: :request

  defp replacement_deadlock_family(:predecessor, event) do
    if session_lock_event?(event), do: :session
  end

  defp replacement_deadlock_family(_role, _event), do: nil

  defp await_deadlock_ready!(ref, role) do
    receive do
      {:replacement_deadlock_ready, ^ref, ^role, pid, backend_pid} -> {pid, backend_pid}
    after
      5_000 -> flunk("replacement deadlock #{role} connection did not become ready")
    end
  end

  defp await_deadlock_barrier!(ref, role, family) do
    receive do
      {:replacement_deadlock_barrier, ^ref, ^role, ^family, event} -> event
    after
      10_000 -> flunk("replacement deadlock #{role} #{family} barrier was not observed")
    end
  end

  defp observe_relation_block!(observer, ref, waiter_pid, blocker_pid, relation) do
    request_ref = make_ref()

    send(
      observer.pid,
      {:session_continuity_observe_block, ref, request_ref, waiter_pid, blocker_pid, "SELECT"}
    )

    receive do
      {:session_continuity_block_observed, ^ref, ^request_ref, observation}
      when is_map(observation) ->
        assert String.contains?(observation.query, relation)
        Map.put(observation, :relation, relation)

      {:session_continuity_block_observed, ^ref, ^request_ref, {:error, reason}} ->
        flunk("PostgreSQL observer failed before positive lock evidence: #{inspect(reason)}")
    after
      6_000 -> flunk("PostgreSQL observer did not return a #{relation} blocker observation")
    end
  end

  defp start_frozen_operation(parent, ref, operation) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        backend_pid = backend_pid!()
        Process.put(@frozen_context, %{parent: parent, ref: ref})
        send(parent, {:session_continuity_frozen_ready, ref, self(), backend_pid})

        try do
          receive do
            {:session_continuity_run_frozen, ^ref} -> safely_run(operation)
          after
            10_000 -> {:error, :frozen_operation_start_timeout}
          end
        after
          Process.delete(@frozen_context)
          Process.delete(@frozen_sequence)
          Process.delete(@frozen_paused)
        end
      end)
    end)
  end

  defp with_frozen_query_handler(fun) when is_function(fun, 0) do
    handler_id = {__MODULE__, :frozen, System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          handle_frozen_query(metadata)
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  defp handle_frozen_query(metadata) do
    case Process.get(@frozen_context) do
      %{parent: parent, ref: ref} = context ->
        handle_frozen_query_context(metadata, context, parent, ref)

      _context ->
        :ok
    end
  end

  defp handle_frozen_query_context(metadata, context, parent, ref) do
    if metadata[:repo] == Repo do
      sequence = Process.get(@frozen_sequence, 0) + 1
      Process.put(@frozen_sequence, sequence)
      event = contention_event(metadata, sequence)
      send(parent, {:session_continuity_frozen_query, ref, event})

      maybe_pause_frozen_close(event, context, parent, ref)
    end
  end

  defp maybe_pause_frozen_close(event, _context, parent, ref) do
    if event.source == "codex_sessions" and event.operation == "UPDATE" and
         not Process.get(@frozen_paused, false) do
      Process.put(@frozen_paused, true)
      send(parent, {:session_continuity_frozen_close_barrier, ref, event})

      receive do
        {:session_continuity_release_frozen, ^ref} -> :ok
      after
        10_000 -> raise "session continuity frozen close barrier was not released"
      end
    end
  end

  defp await_frozen_close_barrier!(ref, events) do
    receive do
      {:session_continuity_frozen_query, ^ref, event} ->
        await_frozen_close_barrier!(ref, events ++ [event])

      {:session_continuity_frozen_close_barrier, ^ref, event} ->
        {events, event}
    after
      10_000 -> flunk("session continuity frozen session close barrier was not observed")
    end
  end

  defp await_frozen_ready!(ref) do
    receive do
      {:session_continuity_frozen_ready, ^ref, pid, backend_pid} -> {pid, backend_pid}
    after
      5_000 -> flunk("session continuity frozen boundary connection did not become ready")
    end
  end

  defp drain_frozen_events(ref, events) do
    receive do
      {:session_continuity_frozen_query, ^ref, event} ->
        drain_frozen_events(ref, events ++ [event])
    after
      0 -> events
    end
  end

  defp observe_blocked_session_operation!(
         observer,
         ref,
         waiter_pid,
         blocker_pid,
         expected_operation
       ) do
    request_ref = make_ref()

    send(
      observer.pid,
      {:session_continuity_observe_block, ref, request_ref, waiter_pid, blocker_pid,
       expected_operation}
    )

    receive do
      {:session_continuity_block_observed, ^ref, ^request_ref, {:error, reason}} ->
        flunk("PostgreSQL observer failed before positive lock evidence: #{inspect(reason)}")

      {:session_continuity_block_observed, ^ref, ^request_ref, observation} ->
        assert observation.wait_event_type == "Lock"
        assert observation.state == "active"
        observation
    after
      6_000 -> flunk("PostgreSQL observer did not return a session blocker observation")
    end
  end

  defp assert_frozen_boundary_events!(events, frozen_session_id) do
    assert boundary_signature(events) == expired_boundary_signature()

    dependent_events =
      Enum.filter(events, fn event ->
        event.source in ["bridge_owner_leases", "bridge_session_aliases"] or
          (event.source == "codex_sessions" and event.operation == "UPDATE")
      end)

    assert dependent_events != []

    Enum.each(dependent_events, fn event ->
      assert uuid_params(event.params) == [frozen_session_id]
      refute String.contains?(String.upcase(event.query), " IN (SELECT")
    end)

    events
    |> Enum.filter(&(&1.operation == "SELECT" and &1.for_update?))
    |> Enum.each(fn event -> assert ordered_primary_key_lock?(event.query) end)
  end

  defp assert_frozen_replacement_state!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      assert %CodexSession{status: "closed"} = Repo.get!(CodexSession, fixture.session.id)

      assert %CodexSession{
               status: "interrupted",
               closed_at: nil,
               owner_lease_expires_at: replacement_expiry,
               updated_at: replacement_updated_at
             } = Repo.get!(CodexSession, fixture.replacement.id)

      assert replacement_expiry == fixture.replacement_expires_at
      assert replacement_updated_at == fixture.replacement_updated_at

      assert %BridgeOwnerLease{status: "expired"} =
               Repo.get!(BridgeOwnerLease, fixture.lease.id)

      assert Enum.all?(
               Repo.all(
                 from alias_record in BridgeSessionAlias,
                   where: alias_record.codex_session_id == ^fixture.session.id
               ),
               &(&1.status == "expired")
             )
    end)
  end

  defp update_closed_replacement!(fixture) do
    fixture.replacement
    |> Ecto.Changeset.change(%{
      status: "interrupted",
      owner_instance_id: "node-replacement",
      owner_lease_token: fixture.replacement_token,
      owner_lease_expires_at: fixture.replacement_expires_at,
      last_heartbeat_at: fixture.replacement_expires_at,
      closed_at: nil,
      updated_at: fixture.replacement_updated_at
    })
    |> Repo.update!()
  end

  defp run_direction(direction_id, operations) do
    Enum.map(1..@direction_iterations, fn iteration ->
      run_direction_iteration(direction_id, iteration, operations)
    end)
  end

  defp run_direction_iteration(direction_id, iteration, operations) do
    # No per-iteration teardown: the next iteration's fixture starts with the same bootstrap
    # reset, and the registered one covers the last iteration and any failure.
    fixture = unboxed_owner_session_fixture(direction_id, iteration)

    with_contention_query_handler(fn ->
      run_contended_operations(direction_id, iteration, fixture, operations.(fixture))
    end)
  end

  defp run_contended_operations(direction_id, iteration, fixture, {a_operation, b_operation}) do
    parent = self()
    ref = make_ref()
    observer = start_observer(parent, ref)
    task_a = start_operation(parent, ref, :a, a_operation, pause?: true)
    task_b = start_operation(parent, ref, :b, b_operation, pause?: false)

    try do
      {_observer_pid, observer_backend_pid} = await_observer_ready!(ref)
      {_a_pid, a_backend_pid} = await_operation_ready!(ref, :a)
      {_b_pid, b_backend_pid} = await_operation_ready!(ref, :b)

      assert MapSet.size(MapSet.new([observer_backend_pid, a_backend_pid, b_backend_pid])) == 3

      send(task_a.pid, {:session_continuity_run, ref})
      {_session_event, traces} = await_barrier!(ref, :a, :session, empty_traces())

      send(task_b.pid, {:session_continuity_run, ref})

      {first_block, traces} =
        observe_blocked_before_lease!(
          observer,
          ref,
          :b,
          b_backend_pid,
          a_backend_pid,
          traces
        )

      send(task_a.pid, {:session_continuity_release, ref, :a, :session})
      {_lease_event, traces} = await_barrier!(ref, :a, :lease, traces)

      {second_block, traces} =
        observe_blocked_before_lease!(
          observer,
          ref,
          :b,
          b_backend_pid,
          a_backend_pid,
          traces
        )

      send(task_a.pid, {:session_continuity_release, ref, :a, :lease})

      assert {:ok, {:ok, %CodexSession{}}} = Task.await(task_a, 10_000)
      assert {:ok, {:ok, %CodexSession{}}} = Task.await(task_b, 10_000)

      send(observer.pid, {:session_continuity_stop_observer, ref})
      assert :ok = Task.await(observer, 5_000)

      traces = drain_contention_events(ref, traces)
      assert_canonical_order!(traces.a)
      assert_canonical_order!(traces.b)

      final = final_owner_snapshot(fixture.session.id)
      assert final.active_lease_count == 1
      assert final.session_owner_matches_lease?

      %{
        direction_id: direction_id,
        iteration: iteration,
        backend_pid_hashes:
          Enum.map([a_backend_pid, b_backend_pid, observer_backend_pid], &sha256/1),
        blocker_observations: [sanitize_block(first_block), sanitize_block(second_block)],
        a_order: relation_operation_order(traces.a),
        b_order: relation_operation_order(traces.b),
        final: final
      }
    after
      send(task_a.pid, {:session_continuity_release, ref, :a, :session})
      send(task_a.pid, {:session_continuity_release, ref, :a, :lease})
      send(task_b.pid, {:session_continuity_release, ref, :b, :session})
      send(task_b.pid, {:session_continuity_release, ref, :b, :lease})
      send(observer.pid, {:session_continuity_stop_observer, ref})
      shutdown_task(task_a)
      shutdown_task(task_b)
      shutdown_task(observer)
    end
  end

  defp with_contention_query_handler(fun) when is_function(fun, 0) do
    handler_id = {__MODULE__, :contention, System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          handle_contention_query(metadata)
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  defp handle_contention_query(metadata) do
    case Process.get(@contention_context) do
      %{parent: parent, ref: ref, role: role} = context ->
        if metadata[:repo] == Repo do
          sequence = Process.get(@contention_sequence, 0) + 1
          Process.put(@contention_sequence, sequence)
          event = contention_event(metadata, sequence)
          send(parent, {:session_continuity_query, ref, role, event})
          maybe_pause_contention(context, event)
        end

      _context ->
        :ok
    end
  end

  defp contention_event(metadata, sequence) do
    query = Map.get(metadata, :query, "")
    upcased_query = String.upcase(query)

    %{
      sequence: sequence,
      source: metadata[:source],
      operation: command_name(query),
      for_update?: String.contains?(upcased_query, "FOR UPDATE"),
      params: Map.get(metadata, :params, []),
      query: query,
      query_sha256: sha256(query)
    }
  end

  defp maybe_pause_contention(%{pause?: true} = context, event) do
    cond do
      session_lock_event?(event) -> pause_contention(context, :session, event)
      lease_lock_event?(event) -> pause_contention(context, :lease, event)
      true -> :ok
    end
  end

  defp maybe_pause_contention(_context, _event), do: :ok

  defp pause_contention(context, family, event) do
    pause_key = {@contention_paused, family}

    unless Process.get(pause_key, false) do
      Process.put(pause_key, true)

      send(
        context.parent,
        {:session_continuity_barrier, context.ref, context.role, family, event}
      )

      receive do
        {:session_continuity_release, ref, role, ^family}
        when ref == context.ref and role == context.role ->
          :ok
      after
        10_000 -> raise "session continuity #{family} barrier was not released"
      end
    end
  end

  defp start_operation(parent, ref, role, operation, opts) do
    pause? = Keyword.fetch!(opts, :pause?)

    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        backend_pid = backend_pid!()

        Process.put(@contention_context, %{
          parent: parent,
          ref: ref,
          role: role,
          pause?: pause?
        })

        send(parent, {:session_continuity_operation_ready, ref, role, self(), backend_pid})

        try do
          receive do
            {:session_continuity_run, ^ref} -> safely_run(operation)
          after
            10_000 -> {:error, :operation_start_timeout}
          end
        after
          Process.delete(@contention_context)
          Process.delete(@contention_sequence)
          Process.delete({@contention_paused, :session})
          Process.delete({@contention_paused, :lease})
        end
      end)
    end)
  end

  defp safely_run(operation) do
    {:ok, operation.()}
  rescue
    exception -> {:error, exception.__struct__, Exception.message(exception)}
  catch
    kind, reason -> {:error, kind, inspect(reason)}
  end

  defp start_observer(parent, ref) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        backend_pid = backend_pid!()
        send(parent, {:session_continuity_observer_ready, ref, self(), backend_pid})
        observer_loop(parent, ref)
      end)
    end)
  end

  defp observer_loop(parent, ref) do
    receive do
      {:session_continuity_observe_block, ^ref, request_ref, waiter_pid, blocker_pid,
       expected_operation} ->
        observation = observe_session_block(waiter_pid, blocker_pid, expected_operation)
        send(parent, {:session_continuity_block_observed, ref, request_ref, observation})
        observer_loop(parent, ref)

      {:session_continuity_stop_observer, ^ref} ->
        :ok
    after
      15_000 -> {:error, :observer_timeout}
    end
  end

  defp observe_session_block(waiter_pid, blocker_pid, expected_operation) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_observe_session_block(waiter_pid, blocker_pid, expected_operation, deadline)
  end

  defp do_observe_session_block(waiter_pid, blocker_pid, expected_operation, deadline) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT pg_blocking_pids($1), wait_event_type, wait_event, state, query
        FROM pg_stat_activity
        WHERE pid = $1
        """,
        [waiter_pid]
      )

    case rows do
      [[blocking_pids, "Lock", wait_event, "active", query]] ->
        if blocker_pid in blocking_pids and
             blocked_session_operation?(query, expected_operation) do
          %{
            blocking_pids: blocking_pids,
            wait_event_type: "Lock",
            wait_event: wait_event,
            state: "active",
            operation: expected_operation,
            query: query
          }
        else
          retry_session_block(waiter_pid, blocker_pid, expected_operation, deadline, rows)
        end

      _rows ->
        retry_session_block(waiter_pid, blocker_pid, expected_operation, deadline, rows)
    end
  end

  defp retry_session_block(waiter_pid, blocker_pid, expected_operation, deadline, last_rows) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, {:session_block_not_observed, last_rows}}
    else
      do_observe_session_block(waiter_pid, blocker_pid, expected_operation, deadline)
    end
  end

  defp observe_blocked_before_lease!(
         observer,
         ref,
         role,
         waiter_pid,
         blocker_pid,
         traces
       ) do
    request_ref = make_ref()

    send(
      observer.pid,
      {:session_continuity_observe_block, ref, request_ref, waiter_pid, blocker_pid, "SELECT"}
    )

    await_blocked_before_lease!(ref, role, request_ref, traces)
  end

  defp await_blocked_before_lease!(ref, role, request_ref, traces) do
    receive do
      {:session_continuity_query, ^ref, ^role, event} ->
        traces = append_trace(traces, role, event)

        if event.source == "bridge_owner_leases" do
          flunk(
            "bridge_owner_leases #{event.operation} completed before the blocked codex_sessions SELECT FOR UPDATE"
          )
        end

        await_blocked_before_lease!(ref, role, request_ref, traces)

      {:session_continuity_query, ^ref, other_role, event} when other_role in [:a, :b] ->
        await_blocked_before_lease!(
          ref,
          role,
          request_ref,
          append_trace(traces, other_role, event)
        )

      {:session_continuity_block_observed, ^ref, ^request_ref, {:error, reason}} ->
        flunk("PostgreSQL observer failed before positive lock evidence: #{inspect(reason)}")

      {:session_continuity_block_observed, ^ref, ^request_ref, observation} ->
        assert observation.wait_event_type == "Lock"
        assert observation.state == "active"
        {observation, traces}
    after
      6_000 -> flunk("PostgreSQL observer did not return a session blocker observation")
    end
  end

  defp await_barrier!(ref, role, family, traces) do
    receive do
      {:session_continuity_query, ^ref, query_role, event} when query_role in [:a, :b] ->
        if query_role == :b and family == :lease and event.source == "bridge_owner_leases" do
          flunk("blocked operation reached bridge_owner_leases before session release")
        end

        await_barrier!(ref, role, family, append_trace(traces, query_role, event))

      {:session_continuity_barrier, ^ref, ^role, ^family, event} ->
        {event, traces}
    after
      10_000 -> flunk("session continuity #{role} #{family} barrier was not observed")
    end
  end

  defp await_observer_ready!(ref) do
    receive do
      {:session_continuity_observer_ready, ^ref, pid, backend_pid} -> {pid, backend_pid}
    after
      5_000 -> flunk("session continuity observer connection did not become ready")
    end
  end

  defp await_operation_ready!(ref, role) do
    receive do
      {:session_continuity_operation_ready, ^ref, ^role, pid, backend_pid} -> {pid, backend_pid}
    after
      5_000 -> flunk("session continuity #{role} connection did not become ready")
    end
  end

  defp drain_contention_events(ref, traces) do
    receive do
      {:session_continuity_query, ^ref, role, event} when role in [:a, :b] ->
        drain_contention_events(ref, append_trace(traces, role, event))
    after
      0 -> traces
    end
  end

  defp empty_traces, do: %{a: [], b: []}

  defp append_trace(traces, role, event) do
    Map.update!(traces, role, &(&1 ++ [event]))
  end

  defp assert_canonical_order!(events) do
    session_index = Enum.find_index(events, &session_lock_event?/1)
    lease_index = Enum.find_index(events, &lease_lock_event?/1)

    assert is_integer(session_index)
    assert is_integer(lease_index)
    assert session_index < lease_index
  end

  defp assert_session_before_lease_lock!(events) do
    assert_canonical_order!(events)

    refute events
           |> Enum.take_while(&(not session_lock_event?(&1)))
           |> Enum.any?(&(&1.source == "bridge_owner_leases"))
  end

  defp relation_operation_order(events) do
    events
    |> Enum.filter(&(&1.source in ["codex_sessions", "bridge_owner_leases"]))
    |> Enum.map(fn event ->
      %{
        relation: event.source,
        operation: event.operation,
        lock: if(event.for_update?, do: "FOR UPDATE", else: nil),
        query_sha256: event.query_sha256
      }
    end)
  end

  defp session_lock_event?(event) do
    event.source == "codex_sessions" and event.operation == "SELECT" and event.for_update?
  end

  defp lease_lock_event?(event) do
    event.source == "bridge_owner_leases" and event.operation == "SELECT" and
      event.for_update?
  end

  defp blocked_session_operation?(query, operation) when is_binary(query) do
    upcased_query = String.upcase(query)

    String.starts_with?(String.trim_leading(upcased_query), operation) and
      String.contains?(upcased_query, "CODEX_SESSIONS")
  end

  defp blocked_session_operation?(_query, _operation), do: false

  defp final_owner_snapshot(session_id) do
    Sandbox.unboxed_run(Repo, fn ->
      session = Repo.get!(CodexSession, session_id)

      leases =
        Repo.all(
          from lease in BridgeOwnerLease,
            where: lease.codex_session_id == ^session_id and lease.status == "active",
            order_by: [asc: lease.id]
        )

      active_lease = List.first(leases)

      %{
        active_lease_count: length(leases),
        session_owner_matches_lease?:
          match?(%BridgeOwnerLease{}, active_lease) and
            session.owner_instance_id == active_lease.owner_instance_id and
            session.owner_lease_token == active_lease.lease_token and
            session.owner_lease_expires_at == active_lease.expires_at,
        final_field_names: [
          "status",
          "owner_instance_id",
          "owner_lease_token",
          "owner_lease_expires_at"
        ],
        session_status: session.status,
        lease_status: if(active_lease, do: active_lease.status)
      }
    end)
  end

  defp sanitize_block(observation) do
    %{
      blocking_pid_hashes: Enum.map(observation.blocking_pids, &sha256/1),
      wait_event_type: observation.wait_event_type,
      wait_event: observation.wait_event,
      state: observation.state,
      relation: "codex_sessions",
      operation: observation.operation,
      lock: if(observation.operation == "SELECT", do: "FOR UPDATE", else: "ROW/UNIQUE INDEX"),
      query_sha256: sha256(observation.query)
    }
  end

  defp report_direction(direction_id, records) do
    if path = System.get_env("SESSION_CONTINUITY_MANUAL_QA_PATH") do
      record = %{
        kind: "session_lease_direction",
        direction_id: direction_id,
        iterations: length(records),
        records: records
      }

      File.write!(path, CodexPooler.JSON.encode!(record) <> "\n", [:append])
    end
  end

  defp report_atomic_renewal(record) do
    if path = System.get_env("SESSION_CONTINUITY_MANUAL_QA_PATH") do
      File.write!(path, CodexPooler.JSON.encode!(record) <> "\n", [:append])
    end
  end

  defp shutdown_task(task) do
    if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
  end

  defp bounded_renewal(fixture) do
    SessionContinuity.renew_owner_token(
      fixture.session.id,
      fixture.token,
      request_options(bridge_owner_lease_ttl_seconds: 120),
      lock_timeout_ms: @bounded_renewal_lock_timeout_ms
    )
  end

  defp lock_renewal_row!(:session, session_id) do
    Repo.one!(from session in CodexSession, where: session.id == ^session_id, lock: "FOR UPDATE")
  end

  defp lock_renewal_row!(:lease, session_id) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == "active",
        lock: "FOR UPDATE"
    )
  end

  defp statement_fingerprint(statement) do
    :sha256 |> :crypto.hash(statement) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  # The session holder itself waits on the API key row, so its blocked
  # statement is observed before the renewal starts; no lock timeout bounds it.
  defp observe_session_holder_wait!(waiter_backend_pid, blocker_backend_pid) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_observe_renewal_lock_wait!(waiter_backend_pid, blocker_backend_pid, deadline)
  end

  defp renewal_row_relation(:session), do: "codex_sessions"
  defp renewal_row_relation(:lease), do: "bridge_owner_leases"

  defp observe_renewal_lock_wait!(waiter_backend_pid, blocker_backend_pid) do
    deadline = System.monotonic_time(:millisecond) + @bounded_renewal_lock_timeout_ms
    do_observe_renewal_lock_wait!(waiter_backend_pid, blocker_backend_pid, deadline)
  end

  # A waiter blocked on a row names its relation; one blocked on the key-wide
  # reservation mutex names no relation at all, because an advisory lock has
  # none.
  defp blocked_lock_target!(query) do
    case Regex.run(~r/FROM "(\w+)"/, query) do
      [_match, relation] -> relation
      nil -> advisory_lock_target!(query)
    end
  end

  defp advisory_lock_target!(query) do
    if query =~ "pg_advisory_xact_lock",
      do: "api_key_reservation_window",
      else: flunk("blocked renewal statement did not name a relation")
  end

  defp do_observe_renewal_lock_wait!(waiter_backend_pid, blocker_backend_pid, deadline) do
    rows =
      Sandbox.unboxed_run(Repo, fn ->
        SQL.query!(
          Repo,
          """
          SELECT query FROM pg_stat_activity
          WHERE pid = $1 AND wait_event_type = 'Lock' AND $2 = ANY(pg_blocking_pids(pid))
          """,
          [waiter_backend_pid, blocker_backend_pid]
        ).rows
      end)

    case rows do
      [[query]] ->
        blocked_lock_target!(query)

      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("bounded renewal was not observed waiting on the blocker's row lock")
        else
          do_observe_renewal_lock_wait!(waiter_backend_pid, blocker_backend_pid, deadline)
        end
    end
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp capture_detailed_repo_queries(fun) when is_function(fun, 0) do
    parent = self()
    handler_id = {__MODULE__, :detailed, System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo and self() == parent do
            send(parent, {handler_id, contention_event(metadata, 0)})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_detailed_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_detailed_queries(handler_id, events) do
    receive do
      {^handler_id, event} -> drain_detailed_queries(handler_id, events ++ [event])
    after
      0 -> events
    end
  end

  defp boundary_signature(events) do
    events
    |> boundary_events()
    |> Enum.map(fn event ->
      %{
        relation: event.source,
        operation: event.operation,
        lock: if(event.for_update?, do: "FOR UPDATE", else: nil),
        ordered_by_primary_key:
          event.operation != "SELECT" or ordered_primary_key_lock?(event.query)
      }
    end)
  end

  defp boundary_events(events) do
    case Enum.split_while(events, &(not expired_session_lock_event?(&1))) do
      {_before, []} -> []
      {_before, from_boundary} -> collect_boundary_events(from_boundary)
    end
  end

  defp collect_boundary_events(events) do
    Enum.reduce_while(events, [], &collect_boundary_event/2)
  end

  defp collect_boundary_event(event, acc) do
    if boundary_relation_event?(event) do
      next = acc ++ [event]

      if event.source == "codex_sessions" and event.operation == "UPDATE" do
        {:halt, next}
      else
        {:cont, next}
      end
    else
      {:cont, acc}
    end
  end

  defp expired_boundary_signature do
    [
      %{
        relation: "codex_sessions",
        operation: "SELECT",
        lock: "FOR UPDATE",
        ordered_by_primary_key: true
      },
      %{
        relation: "bridge_owner_leases",
        operation: "SELECT",
        lock: "FOR UPDATE",
        ordered_by_primary_key: true
      },
      %{
        relation: "bridge_session_aliases",
        operation: "SELECT",
        lock: "FOR UPDATE",
        ordered_by_primary_key: true
      },
      %{
        relation: "bridge_owner_leases",
        operation: "UPDATE",
        lock: nil,
        ordered_by_primary_key: true
      },
      %{
        relation: "bridge_session_aliases",
        operation: "UPDATE",
        lock: nil,
        ordered_by_primary_key: true
      },
      %{
        relation: "codex_sessions",
        operation: "UPDATE",
        lock: nil,
        ordered_by_primary_key: true
      }
    ]
  end

  defp expired_session_lock_event?(event) do
    event.source == "codex_sessions" and event.operation == "SELECT" and event.for_update? and
      String.contains?(String.upcase(event.query), "OWNER_LEASE_EXPIRES_AT") and
      ordered_primary_key_lock?(event.query)
  end

  defp boundary_relation_event?(event) do
    event.source in ["codex_sessions", "bridge_owner_leases", "bridge_session_aliases"] and
      event.operation in ["SELECT", "UPDATE"]
  end

  defp ordered_primary_key_lock?(query) do
    String.contains?(String.upcase(query), "ORDER BY") and
      Regex.match?(~r/ORDER BY\s+[^;]*\."id"(?:\s+ASC)?/i, query) and
      String.contains?(String.upcase(query), "FOR UPDATE")
  end

  defp uuid_params(params) do
    params
    |> flatten_params()
    |> Enum.flat_map(fn value ->
      case Ecto.UUID.cast(value) do
        {:ok, id} -> [id]
        :error -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp flatten_params(values) when is_list(values), do: Enum.flat_map(values, &flatten_params/1)
  defp flatten_params(value), do: [value]

  defp ordered_id_hashes(events) do
    events
    |> boundary_events()
    |> Enum.reject(&expired_session_lock_event?/1)
    |> Enum.map(fn event ->
      %{
        relation: event.source,
        operation: event.operation,
        id_sha256: Enum.map(uuid_params(event.params), &sha256/1)
      }
    end)
  end

  defp report_frozen_schedule(record) do
    if path = System.get_env("SESSION_CONTINUITY_MANUAL_QA_PATH") do
      File.write!(path, CodexPooler.JSON.encode!(record) <> "\n", [:append])
    end
  end

  defp report_start_boundary(events, frozen_session_id) do
    if path = System.get_env("SESSION_CONTINUITY_MANUAL_QA_PATH") do
      record = %{
        kind: "expired_sessions_start_boundary",
        boundary_signature: boundary_signature(events),
        frozen_session_id_sha256: sha256(frozen_session_id),
        ordered_id_hashes: ordered_id_hashes(events),
        start_after_close: true
      }

      File.write!(path, CodexPooler.JSON.encode!(record) <> "\n", [:append])
    end
  end

  defp unboxed_expired_replacement_fixture do
    fixture = unboxed_expired_session_fixture("session_continuity-frozen")

    Sandbox.unboxed_run(Repo, fn ->
      replacement =
        %CodexSession{
          pool_id: fixture.auth.pool.id,
          api_key_id: fixture.auth.api_key.id,
          session_key: fixture.session_key,
          status: "closed",
          closed_at: fixture.boundary_now,
          created_at: fixture.boundary_now,
          updated_at: fixture.boundary_now
        }
        |> Repo.insert!()

      Map.merge(fixture, %{
        replacement: replacement,
        replacement_token: Ecto.UUID.generate(),
        replacement_expires_at: DateTime.add(fixture.boundary_now, -30, :second),
        replacement_updated_at: DateTime.add(fixture.boundary_now, 1, :second)
      })
    end)
  end

  defp unboxed_expired_session_fixture(prefix) do
    register_bootstrap_reset!()

    Sandbox.unboxed_run(Repo, fn ->
      reset_bootstrap_state_fixture!()
      auth = auth_fixture()

      session_key =
        "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

      assert {:ok, %CodexSession{} = session} =
               Gateway.start_codex_session(auth, %{
                 session_key: session_key,
                 owner_instance_id: "node-old"
               })

      boundary_now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      expired_at = DateTime.add(boundary_now, -60, :second)
      session = Repo.get!(CodexSession, session.id)
      lease = active_lease!(session.id)

      session
      |> Ecto.Changeset.change(%{
        owner_lease_expires_at: expired_at,
        last_heartbeat_at: expired_at,
        updated_at: expired_at
      })
      |> Repo.update!()

      lease
      |> Ecto.Changeset.change(%{expires_at: expired_at, updated_at: expired_at})
      |> Repo.update!()

      %{
        auth: auth,
        boundary_now: boundary_now,
        lease: lease,
        session: Repo.get!(CodexSession, session.id),
        session_key: session_key
      }
    end)
  end

  defp active_lease!(session_id) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == "active",
        order_by: [asc: lease.id],
        limit: 1
    )
  end

  defp unboxed_get_session!(session_id) do
    Sandbox.unboxed_run(Repo, fn -> Repo.get!(CodexSession, session_id) end)
  end

  defp unboxed_active_lease!(session_id) do
    Sandbox.unboxed_run(Repo, fn -> active_lease!(session_id) end)
  end

  defp set_unboxed_owner_deadline!(fixture, seconds) do
    Sandbox.unboxed_run(Repo, fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      expires_at = DateTime.add(now, seconds, :second)
      session = Repo.get!(CodexSession, fixture.session.id)
      lease = active_lease!(session.id)

      session
      |> Ecto.Changeset.change(%{
        owner_lease_expires_at: expires_at,
        last_heartbeat_at: now,
        updated_at: now
      })
      |> Repo.update!()

      lease
      |> Ecto.Changeset.change(%{renewed_at: now, expires_at: expires_at, updated_at: now})
      |> Repo.update!()

      %{fixture | session: Repo.get!(CodexSession, session.id)}
    end)
  end

  defp unboxed_owner_session_fixture(direction_id, iteration) do
    register_bootstrap_reset!()

    Sandbox.unboxed_run(Repo, fn ->
      reset_bootstrap_state_fixture!()
      auth = auth_fixture()

      session_key =
        "session_continuity-#{direction_id}-#{iteration}-#{System.unique_integer([:positive, :monotonic])}"

      assert {:ok, %CodexSession{} = session} =
               Gateway.start_codex_session(auth, %{
                 session_key: session_key,
                 owner_instance_id: "node-a"
               })

      session = Repo.get!(CodexSession, session.id)

      %{
        auth: auth,
        session: session,
        session_key: session_key,
        token: session.owner_lease_token
      }
    end)
  end

  defp unboxed_fresh_runtime_turn_fixture do
    register_bootstrap_reset!()

    Sandbox.unboxed_run(Repo, fn ->
      reset_bootstrap_state_fixture!()
      auth = auth_fixture()

      assert {:ok, %CodexSession{} = session} =
               Gateway.start_codex_session(auth, %{
                 accepted_turn_state:
                   "session-continuity-fresh-runtime-#{System.unique_integer([:positive, :monotonic])}",
                 owner_instance_id: "node-a"
               })

      request = request_fixture(auth, %{status: "in_progress", completed_at: nil})
      %{request_id: request.id, session_id: session.id}
    end)
  end

  defp unboxed_replacement_deadlock_fixture do
    register_bootstrap_reset!()

    Sandbox.unboxed_run(Repo, fn ->
      reset_bootstrap_state_fixture!()
      auth = auth_fixture()
      %{assignment: assignment} = upstream_assignment_fixture(auth.pool)

      assert {:ok, %CodexSession{} = session} =
               Gateway.start_codex_session(auth, %{
                 accepted_turn_state:
                   "replacement-deadlock-#{System.unique_integer([:positive, :monotonic])}",
                 owner_instance_id: "node-a"
               })

      predecessor_request =
        request_fixture(auth, %{
          status: "in_progress",
          completed_at: nil,
          transport: "websocket",
          usage_status: "usage_pending"
        })

      replacement_request =
        request_fixture(auth, %{
          status: "in_progress",
          completed_at: nil,
          transport: "websocket",
          usage_status: "usage_pending"
        })

      %{
        assignment: assignment,
        predecessor_request: predecessor_request,
        replacement_request: replacement_request,
        session: Repo.get!(CodexSession, session.id)
      }
    end)
  end

  # Every unboxed fixture here commits a bootstrap owner on the fixed `owner@example.com`, and the
  # full bootstrap reset is the only teardown that removes it. Registered, never scoped: the
  # contention cases run their blockers in linked tasks, so an assertion failing in one kills the
  # test process before any `after` in it runs, and the ExUnit timeout kills it the same way.
  # Registered before the first commit, so a fixture that fails partway is covered, and once per
  # test, so the ten-iteration directions do not queue ten resets.
  defp register_bootstrap_reset! do
    key = {__MODULE__, :bootstrap_reset_registered}

    if !Process.get(key) do
      register_unboxed_cleanup!(&reset_bootstrap_state_fixture!/0)
      Process.put(key, true)
    end

    :ok
  end

  defp auth_fixture do
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
    %{pool: pool, api_key: api_key}
  end

  defp owner_session_fixture do
    auth = auth_fixture()

    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state:
                 "session-continuity-pin-#{System.unique_integer([:positive, :monotonic])}",
               owner_instance_id: "node-a"
             })

    session = Repo.get!(CodexSession, session.id)
    %{auth: auth, session: session, token: session.owner_lease_token}
  end

  defp insert_alias!(session, auth, kind, value) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    hash = :crypto.hash(:sha256, value)

    %BridgeSessionAlias{}
    |> BridgeSessionAlias.changeset(%{
      codex_session_id: session.id,
      pool_id: auth.pool.id,
      api_key_id: auth.api_key.id,
      alias_kind: kind,
      alias_hash: hash,
      alias_preview: hash |> Base.encode16(case: :lower) |> String.slice(0, 16),
      status: "active",
      expires_at: DateTime.add(now, 300, :second),
      last_seen_at: now,
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp token_lease_id(token) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where: lease.lease_token == ^token,
        select: lease.id
    )
  end

  defp request_options(opts) do
    opts
    |> Map.new()
    |> RequestOptions.for_websocket()
  end

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    parent = self()
    handler_id = {__MODULE__, System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            query = Map.get(metadata, :query, "")

            send(parent, {
              handler_id,
              %{
                source: metadata[:source],
                command: command_name(query),
                query: query,
                for_update?: String.contains?(String.upcase(query), "FOR UPDATE"),
                in_transaction?: Repo.in_transaction?()
              }
            })
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_queries(handler_id, events) do
    receive do
      {^handler_id, event} -> drain_repo_queries(handler_id, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp command_name(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.upcase()
  end

  defp sha256(value) do
    value
    |> to_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
