defmodule CodexPooler.Accounting.ClientRetryPostgresTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import CodexPooler.AccountingTestSupport
  import CodexPooler.UnboxedFixture, only: [register_unboxed_cleanup!: 1]

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting

  alias CodexPooler.Accounting.{
    Attempt,
    ClientRetry,
    PreAttemptRelease,
    Request,
    RequestClientRetryLink
  }

  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @detection_budget 15_000

  test "committed retry cleanup removes its identity and pricing without touching another fixture" do
    Sandbox.unboxed_run(Repo, fn ->
      fixture = committed_fixture()
      other = committed_fixture()

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          cleanup_fixture(fixture)
          cleanup_fixture(other)
        end)
      end)

      cleanup_fixture(fixture)

      refute Repo.get(CodexPooler.Upstreams.Schemas.UpstreamIdentity, fixture.identity_id)
      refute Repo.get(CodexPooler.Catalog.PricingSnapshot, fixture.pricing_id)
      assert Repo.get!(Pool, other.pool_id)
      assert Repo.get!(CodexPooler.Upstreams.Schemas.UpstreamIdentity, other.identity_id)
      assert Repo.get!(CodexPooler.Catalog.PricingSnapshot, other.pricing_id)
      cleanup_fixture(fixture)
    end)
  end

  for predecessor_kind <- [:attempted, :pre_attempt_drain, :claim_only_drain] do
    @predecessor_kind predecessor_kind
    test "two PostgreSQL backends race to one successor for #{@predecessor_kind}" do
      race_successor_claims(@predecessor_kind)
    end
  end

  defp race_successor_claims(predecessor_kind) do
    fixture = Sandbox.unboxed_run(Repo, fn -> committed_fixture(predecessor_kind) end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        cleanup_fixture(fixture)
      end)
    end)

    parent = self()
    release = make_ref()

    tasks =
      for lane <- [:first, :second] do
        Task.async(fn ->
          claim_from_backend(fixture, parent, release, lane)
        end)
      end

    ready =
      for _lane <- 1..2 do
        assert_receive {:backend_ready, lane, backend_pid, task_pid}, @detection_budget
        {lane, backend_pid, task_pid}
      end

    assert ready |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 2
    Enum.each(ready, fn {_lane, _backend, task_pid} -> send(task_pid, {:release, release}) end)

    results = Enum.map(tasks, &Task.await(&1, @detection_budget))
    assert Enum.count(results, &match?({:ok, %ClientRetry.SuccessorClaim{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :successor_claimed}, &1)) == 1

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(RequestClientRetryLink, :count) == 1
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^fixture.pool_id), :count) == 2

      assert Repo.aggregate(
               from(t in CodexTurn, where: t.codex_session_id == ^fixture.session_id),
               :count
             ) == if(predecessor_kind == :claim_only_drain, do: 1, else: 2)

      assert Repo.aggregate(
               from(a in Attempt, where: a.request_id == ^fixture.predecessor_id),
               :count
             ) == if(predecessor_kind == :attempted, do: 1, else: 0)

      successor_id = Repo.one!(from l in RequestClientRetryLink, select: l.successor_request_id)
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^successor_id), :count) == 0
    end)
  end

  defp claim_from_backend(fixture, parent, release, lane) do
    Sandbox.unboxed_run(Repo, fn ->
      [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
      send(parent, {:backend_ready, lane, backend_pid, self()})

      receive do
        {:release, ^release} ->
          Accounting.claim_client_retry_successor(
            fixture.auth,
            fixture.model,
            fixture.payload,
            fixture.opts
          )
      after
        @detection_budget -> flunk("successor claim was not released")
      end
    end)
  end

  test "a late old-attempt creator blocks behind the successor claim and cannot dispatch" do
    fixture = Sandbox.unboxed_run(Repo, fn -> committed_fixture(:pre_attempt_drain) end)
    on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> cleanup_fixture(fixture) end) end)
    parent = self()
    release = make_ref()

    claimant =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          opts =
            Map.put(fixture.opts, :after_locks, fn ->
              [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
              send(parent, {:claim_locked, backend})

              receive do
                {:release, ^release} -> :ok
              after
                @detection_budget -> flunk("claim lock was not released")
              end
            end)

          Accounting.claim_client_retry_successor(
            fixture.auth,
            fixture.model,
            fixture.payload,
            opts
          )
        end)
      end)

    assert_receive {:claim_locked, claim_backend}, @detection_budget

    creator =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:attempt_backend, backend})
          Accounting.create_attempt(fixture.predecessor, fixture.assignment)
        end)
      end)

    assert_receive {:attempt_backend, attempt_backend}, @detection_budget

    Sandbox.unboxed_run(Repo, fn ->
      await_blocked(
        attempt_backend,
        claim_backend,
        System.monotonic_time(:millisecond) + @detection_budget
      )
    end)

    send(claimant.pid, {:release, release})
    assert {:ok, %ClientRetry.SuccessorClaim{}} = Task.await(claimant, @detection_budget)
    assert {:error, %{code: :request_already_finalized}} = Task.await(creator, @detection_budget)

    Sandbox.unboxed_run(Repo, fn ->
      refute Repo.exists?(from a in Attempt, where: a.request_id == ^fixture.predecessor_id)
    end)
  end

  for mutation <- [:auth_epoch, :deadline] do
    @mutation mutation
    test "successor claim revalidates #{@mutation} after a real session lock wait" do
      assert_lock_wait_revalidation(@mutation)
    end
  end

  defp assert_lock_wait_revalidation(mutation) do
    fixture = Sandbox.unboxed_run(Repo, fn -> committed_fixture(:attempted) end)
    on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> cleanup_fixture(fixture) end) end)
    parent = self()
    release = make_ref()
    deadlocks_before = Sandbox.unboxed_run(Repo, &deadlock_count/0)

    holder = Task.async(fn -> hold_session_lock(fixture, parent, release) end)

    assert_receive {:session_holder_ready, ^release, holder_backend}, @detection_budget

    claimant =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:blocked_claimant_ready, release, backend})

          Accounting.claim_client_retry_successor(
            fixture.auth,
            fixture.model,
            fixture.payload,
            fixture.opts
          )
        end)
      end)

    assert_receive {:blocked_claimant_ready, ^release, claimant_backend}, @detection_budget

    snapshot =
      Sandbox.unboxed_run(Repo, fn ->
        snapshot =
          await_blocked_snapshot(
            claimant_backend,
            holder_backend,
            System.monotonic_time(:millisecond) + @detection_budget
          )

        mutate_after_lock_wait!(fixture, mutation)
        snapshot
      end)

    send(holder.pid, {:release_session_holder, release})
    assert {:ok, :ok} = Task.await(holder, @detection_budget)
    claim_result = Task.await(claimant, @detection_budget)

    assert snapshot.state == "active"
    assert snapshot.wait_event_type == "Lock"
    assert holder_backend in snapshot.blockers
    assert snapshot.ungranted_lock_count > 0

    expected_error = if mutation == :auth_epoch, do: :authorization_changed, else: :retry_expired
    assert {:error, ^expected_error} = claim_result

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.query!("SELECT pg_blocking_pids($1)", [claimant_backend]).rows == [[[]]]
      assert deadlock_count() == deadlocks_before

      refute Repo.exists?(
               from link in RequestClientRetryLink,
                 where: link.predecessor_request_id == ^fixture.predecessor_id
             )

      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^fixture.pool_id), :count) == 1
    end)
  end

  defp hold_session_lock(fixture, parent, release) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn -> hold_session_lock_transaction(fixture, parent, release) end)
    end)
  end

  defp hold_session_lock_transaction(fixture, parent, release) do
    Repo.one!(
      from session in CodexSession,
        where: session.id == ^fixture.session_id,
        lock: "FOR UPDATE"
    )

    [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
    send(parent, {:session_holder_ready, release, backend})

    receive do
      {:release_session_holder, ^release} -> :ok
    after
      @detection_budget -> flunk("session holder was not released")
    end
  end

  test "fixed client retry workload keeps the same query schedule at concurrency 1 4 and 16" do
    logical_operations = 16

    schedules =
      for concurrency <- [1, 4, 16] do
        fixtures =
          for _index <- 1..logical_operations do
            # Registered as soon as each fixture exists, never scoped in `try/after`: the claims
            # run in linked tasks, so a failing one kills the test process before an enclosing
            # `after` runs. `committed_fixture/1` derives its keys while it commits, so a
            # fixture that fails partway through is not covered.
            fixture = Sandbox.unboxed_run(Repo, fn -> committed_fixture(:attempted) end)
            register_unboxed_cleanup!(fn -> cleanup_fixture(fixture) end)
            fixture
          end

        {results, events} =
          capture_repo_schedule(fn ->
            run_claim_workload(fixtures, concurrency)
          end)

        assert Enum.all?(results, &match?({:ok, %ClientRetry.SuccessorClaim{}}, &1))

        schedule = %{
          concurrency: concurrency,
          total: length(events),
          per_operation: div(length(events), logical_operations),
          operation_sources: Enum.frequencies_by(events, &{&1.operation, &1.source}),
          query_time_us: Enum.sum(Enum.map(events, & &1.query_time_us)),
          max_query_time_us: Enum.max(Enum.map(events, & &1.query_time_us)),
          queue_time_us: Enum.sum(Enum.map(events, & &1.queue_time_us)),
          max_queue_time_us: Enum.max(Enum.map(events, & &1.queue_time_us))
        }

        # Also removed now, so each concurrency level runs against the database it always did;
        # the registered pass then finds nothing left.
        Enum.each(fixtures, fn fixture ->
          Sandbox.unboxed_run(Repo, fn -> cleanup_fixture(fixture) end)
        end)

        schedule
      end

    # Twenty-two statements per claim, the twenty-second being the key-wide
    # reservation mutex `pg_advisory_xact_lock/2` that the reservation mode
    # takes before it reads the key row.
    assert Enum.map(schedules, & &1.total) == [352, 352, 352]
    assert Enum.map(schedules, & &1.per_operation) == [22, 22, 22]
    assert Enum.map(schedules, & &1.operation_sources) |> Enum.uniq() |> length() == 1
  end

  defp await_blocked(waiter, holder, deadline) do
    [[blocked?]] = Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [holder, waiter]).rows

    cond do
      blocked? -> :ok
      System.monotonic_time(:millisecond) < deadline -> await_blocked(waiter, holder, deadline)
      true -> flunk("old attempt did not block on the successor request lock")
    end
  end

  defp await_blocked_snapshot(waiter, holder, deadline) do
    [[state, wait_event_type, wait_event, blockers, ungranted_lock_count]] =
      Repo.query!(
        """
        SELECT activity.state,
               activity.wait_event_type,
               activity.wait_event,
               pg_blocking_pids($1),
               count(locks.*) FILTER (WHERE locks.granted = false)
        FROM pg_stat_activity AS activity
        LEFT JOIN pg_locks AS locks ON locks.pid = activity.pid
        WHERE activity.pid = $1
        GROUP BY activity.state, activity.wait_event_type, activity.wait_event
        """,
        [waiter]
      ).rows

    if holder in blockers and wait_event_type == "Lock" do
      %{
        state: state,
        wait_event_type: wait_event_type,
        wait_event: wait_event,
        blockers: blockers,
        ungranted_lock_count: ungranted_lock_count
      }
    else
      if System.monotonic_time(:millisecond) < deadline do
        await_blocked_snapshot(waiter, holder, deadline)
      else
        flunk("claimant did not block on the session lock")
      end
    end
  end

  defp mutate_after_lock_wait!(fixture, :auth_epoch) do
    api_key = Repo.get!(APIKey, fixture.auth.api_key.id)

    api_key
    |> Ecto.Changeset.change(runtime_revocation_epoch: api_key.runtime_revocation_epoch + 1)
    |> Repo.update!()
  end

  defp mutate_after_lock_wait!(fixture, :deadline) do
    [[now]] = Repo.query!("SELECT clock_timestamp()").rows
    expired_at = DateTime.add(now, -31, :second)

    fixture.predecessor
    |> Repo.reload!()
    |> Ecto.Changeset.change(completed_at: expired_at)
    |> Repo.update!()
  end

  defp run_claim_workload(fixtures, concurrency) do
    fixtures
    |> Enum.chunk_every(concurrency)
    |> Enum.flat_map(&run_claim_batch/1)
  end

  defp run_claim_batch(fixtures) do
    parent = self()
    release = make_ref()

    tasks =
      Enum.map(fixtures, fn fixture ->
        Task.async(fn ->
          send(parent, {:claim_actor_ready, release, self()})

          receive do
            {:run_claim, ^release} ->
              Sandbox.unboxed_run(Repo, fn ->
                Accounting.claim_client_retry_successor(
                  fixture.auth,
                  fixture.model,
                  fixture.payload,
                  fixture.opts
                )
              end)
          after
            @detection_budget -> flunk("query schedule actor was not released")
          end
        end)
      end)

    actors =
      Enum.map(tasks, fn _task ->
        assert_receive {:claim_actor_ready, ^release, actor}, @detection_budget
        actor
      end)

    Enum.each(actors, &send(&1, {:run_claim, release}))
    Enum.map(tasks, &Task.await(&1, @detection_budget))
  end

  defp capture_repo_schedule(fun) do
    table = :ets.new(:client_retry_query_schedule, [:ordered_set, :public])
    handler_id = {__MODULE__, :query_schedule, System.unique_integer([:positive, :monotonic])}

    # Also on_exit: a linked crash or the ExUnit timeout kills the test before `after` runs.
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, measurements, metadata, query_table ->
          if metadata[:repo] == Repo do
            query = Map.get(metadata, :query, "")

            :ets.insert(query_table, {
              System.unique_integer([:positive, :monotonic]),
              %{
                source: metadata[:source],
                operation: query_operation(query),
                query_time_us: native_microseconds(measurements[:query_time]),
                queue_time_us: native_microseconds(measurements[:queue_time])
              }
            })
          end
        end,
        table
      )

    try do
      result = fun.()
      events = table |> :ets.tab2list() |> Enum.map(&elem(&1, 1))
      {result, events}
    after
      :telemetry.detach(handler_id)
      :ets.delete(table)
    end
  end

  defp query_operation(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.upcase()
  end

  defp native_microseconds(nil), do: 0

  defp native_microseconds(value),
    do: System.convert_time_unit(value, :native, :microsecond)

  defp deadlock_count do
    [[deadlocks]] =
      Repo.query!("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()").rows

    deadlocks
  end

  defp cleanup_fixture(fixture) do
    Repo.delete_all(from pool in Pool, where: pool.id == ^fixture.pool_id)

    Repo.delete_all(
      from identity in CodexPooler.Upstreams.Schemas.UpstreamIdentity,
        where: identity.id == ^fixture.identity_id
    )

    Repo.delete_all(
      from pricing in CodexPooler.Catalog.PricingSnapshot,
        where: pricing.id == ^fixture.pricing_id
    )
  end

  defp committed_fixture(predecessor_kind \\ :attempted) do
    setup = accounting_setup(%{price_version: unique_price_version()})
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [])
    digest = :crypto.strong_rand_bytes(32)
    semantic_digest = :crypto.strong_rand_bytes(32)
    witness = ClientRetry.original_witness!(digest, setup.api_key.runtime_revocation_epoch)

    {:ok, %{request: predecessor}} =
      Accounting.claim_websocket_turn(setup.auth, setup.model, %{
        endpoint: "/backend-api/codex/responses",
        correlation_id: "codex-turn:" <> Base.url_encode64(semantic_digest, padding: false),
        native_client_retry_witness: witness
      })

    session =
      Repo.insert!(%CodexSession{
        pool_id: setup.pool.id,
        api_key_id: setup.api_key.id,
        session_key: "retry-pg-#{System.unique_integer([:positive, :monotonic])}",
        pool_upstream_assignment_id: setup.assignment.id,
        status: "active",
        created_at: now,
        updated_at: now
      })

    turn =
      Repo.insert!(%CodexTurn{
        codex_session_id: session.id,
        request_id: predecessor.id,
        turn_sequence: 1,
        transport_kind: "websocket",
        semantic_turn_digest: semantic_digest,
        status: "failed",
        error_code: "upstream_stream_error",
        first_visible_output_at: now,
        completed_at: now,
        started_at: now,
        created_at: now,
        updated_at: now
      })

    predecessor = finalize_predecessor(setup, predecessor, turn, now, predecessor_kind)

    %{
      auth: setup.auth,
      model: setup.model,
      predecessor: predecessor,
      assignment: setup.assignment,
      identity_id: setup.identity.id,
      pricing_id: setup.pricing.id,
      payload: %{"model" => setup.model.exposed_model_id, "input" => []},
      pool_id: setup.pool.id,
      session_id: session.id,
      predecessor_id: predecessor.id,
      opts: %{
        endpoint: "/backend-api/codex/responses",
        requested_model: setup.model.exposed_model_id,
        runtime_revocation_epoch: setup.api_key.runtime_revocation_epoch,
        codex_session: session,
        semantic_turn_digest: semantic_digest,
        original_request_claim: predecessor.correlation_id,
        replay_claim_digest: digest
      }
    }
  end

  defp finalize_predecessor(setup, predecessor, turn, now, :attempted) do
    attempt =
      CodexPooler.PoolerFixtures.attempt_fixture(predecessor, setup.assignment, %{
        status: "failed",
        completed_at: now,
        network_error_code: "upstream_stream_error",
        usage_status: "usage_unknown",
        transport: "websocket",
        replay_generation: 0,
        response_metadata: eligible_metadata(now)
      })

    predecessor =
      Repo.update!(
        Ecto.Changeset.change(predecessor,
          status: "failed",
          usage_status: "usage_unknown",
          completed_at: now,
          last_error_code: "upstream_stream_error"
        )
      )

    Repo.update!(Ecto.Changeset.change(turn, final_attempt_id: attempt.id))

    predecessor
  end

  defp finalize_predecessor(setup, predecessor, turn, _now, :pre_attempt_drain) do
    {:ok, %{request: reserved}} =
      Accounting.reserve(
        setup.auth,
        setup.model,
        %{"model" => setup.model.exposed_model_id, "input" => []},
        %{
          transport: "websocket",
          endpoint: predecessor.endpoint,
          correlation_id: predecessor.correlation_id,
          turn_claim: predecessor
        }
      )

    {:ok, %{request: request}} =
      Accounting.finalize_reservation_failure(reserved, %{
        last_error_code: "owner_drained",
        usage_status: "usage_unknown",
        response_status_code: 499,
        pre_attempt_phase: PreAttemptRelease.turn_interrupted()
      })

    Repo.update!(
      Ecto.Changeset.change(turn,
        status: "interrupted",
        error_code: "owner_drained",
        first_visible_output_at: nil,
        completed_at: request.completed_at
      )
    )

    # Stamped input for the predicate, not a claim that anything produces it
    # here. The real writer is `Interruption.interrupt_direct_request/2` on a
    # `%DirectCleanup{}` receipt, covered end to end in
    # `test/codex_pooler_web/controllers/runtime/backend_codex_pre_attempt_drain_resend_test.exs`
    # (icoretech/codex-pooler-findings#160, #170).
    Repo.update!(
      Ecto.Changeset.change(request,
        request_metadata:
          Map.put(request.request_metadata || %{}, "websocket_pre_attempt_drain", true)
      )
    )
  end

  # Same stamping contract as `:pre_attempt_drain` above: the marker is input to
  # `verified_claim_only_drain?/1`, and the producer lives in the drain suite.
  defp finalize_predecessor(_setup, predecessor, turn, now, :claim_only_drain) do
    Repo.delete!(turn)

    Repo.update!(
      Ecto.Changeset.change(predecessor,
        status: "failed",
        response_status_code: 499,
        last_error_code: "owner_drained",
        usage_status: "usage_unknown",
        completed_at: now,
        request_metadata: %{"websocket_pre_attempt_drain" => true}
      )
    )
  end

  defp eligible_metadata(now) do
    %{
      "transport_failure" => %{
        "phase" => "receive",
        "termination_source" => "peer_close_frame",
        "transport_signal" => "tcp_closed"
      },
      "native_client_retry_observation" => %{
        "version" => 1,
        "authority_complete" => true,
        "output_item_done_count" => 0,
        "output_item_done_count_saturated" => false,
        "partial_reasoning_seen" => true,
        "first_visible_at" => DateTime.to_iso8601(now),
        "terminal_seen" => false,
        "terminal_candidate_seen" => false
      }
    }
  end

  defp unique_price_version,
    do: "t10-pg-#{System.unique_integer([:positive, :monotonic])}"
end
