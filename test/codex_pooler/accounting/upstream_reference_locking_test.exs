defmodule CodexPooler.Accounting.UpstreamReferenceLockingTest do
  use CodexPooler.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry}
  alias CodexPooler.Accounting.RequestLifecycle.LedgerEntries
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing

  alias CodexPooler.Upstreams.Schemas.{
    PoolUpstreamAssignment,
    UpstreamIdentity
  }

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures

  @schedule_iterations 10
  @actor_timeout 15_000
  @barrier_timeout 10_000
  @observer_timeout_ms 5_000

  @schedules [
    %{
      id: "A01-forward",
      path: :attempt,
      direction: :forward,
      target_ordinal: 1,
      target_entry_kind: "attempt"
    },
    %{
      id: "A01-reverse",
      path: :attempt,
      direction: :reverse,
      target_ordinal: 1,
      target_entry_kind: "attempt"
    },
    %{
      id: "G03-forward",
      path: :initial_settlement,
      direction: :forward,
      target_ordinal: 1,
      target_entry_kind: "settlement"
    },
    %{
      id: "G03-reverse",
      path: :initial_settlement,
      direction: :reverse,
      target_ordinal: 1,
      target_entry_kind: "settlement"
    },
    %{
      id: "G04-forward",
      path: :release,
      direction: :forward,
      target_ordinal: 2,
      target_entry_kind: "release"
    },
    %{
      id: "G04-reverse",
      path: :release,
      direction: :reverse,
      target_ordinal: 2,
      target_entry_kind: "release"
    },
    %{
      id: "G05-forward",
      path: :replacement_settlement,
      direction: :forward,
      target_ordinal: 1,
      target_entry_kind: "replacement_settlement"
    },
    %{
      id: "G05-reverse",
      path: :replacement_settlement,
      direction: :reverse,
      target_ordinal: 1,
      target_entry_kind: "replacement_settlement"
    }
  ]

  for schedule <- @schedules do
    schedule_id = schedule.id

    @tag task8_schedule: schedule_id
    test "#{schedule_id} serializes accounting and credential fencing for 10 iterations" do
      summaries =
        Enum.map(1..@schedule_iterations, fn iteration ->
          run_schedule_iteration(unquote(Macro.escape(schedule)), iteration)
        end)

      assert Enum.map(summaries, & &1.iteration) == Enum.to_list(1..@schedule_iterations)
      assert Enum.all?(summaries, &(&1.schedule_id == unquote(schedule_id)))
      assert Enum.all?(summaries, & &1.no_deadlock)
      assert Enum.all?(summaries, & &1.blocked_side_stayed_before_assignment_or_insert)
      assert Enum.uniq_by(summaries, & &1.trace_sha256) |> length() == @schedule_iterations
    end
  end

  @tag :task8_membership_lock
  test "assignment membership update waits behind accounting validation until A01 commits" do
    fixture = committed_membership_fixture!()
    cleanup_key = {__MODULE__, make_ref(), :membership_cleanup}

    summary =
      try do
        run_membership_contention(fixture)
      after
        Process.put(cleanup_key, cleanup_committed_fixture!(fixture))
      end

    cleanup = Process.delete(cleanup_key)

    assert cleanup == %{identities: 2, pools: 1, pricing_snapshots: 1}

    record_evidence(
      summary
      |> Map.put(:record_type, "membership_proof")
      |> Map.put(:cleanup, "exact_fixture_cleanup")
      |> Map.put(:cleanup_counts, cleanup)
    )
  end

  defp run_schedule_iteration(schedule, iteration) do
    fixture = committed_schedule_fixture!(schedule.path, iteration)
    cleanup_key = {__MODULE__, make_ref(), :schedule_cleanup}

    summary =
      try do
        run_schedule(schedule, iteration, fixture)
      after
        Process.put(cleanup_key, cleanup_committed_fixture!(fixture))
      end

    cleanup = Process.delete(cleanup_key)

    assert cleanup == %{identities: 1, pools: 1, pricing_snapshots: 1}

    summary =
      summary
      |> Map.put(:record_type, "schedule_iteration")
      |> Map.put(:cleanup, "exact_fixture_cleanup")
      |> Map.put(:cleanup_counts, cleanup)

    record_evidence(summary)
    summary
  end

  defp run_schedule(schedule, iteration, fixture) do
    parent = self()
    barrier = make_ref()

    accounting_task =
      waiting_actor_task(parent, barrier, :accounting, fn ->
        run_accounting_operation(schedule.path, fixture)
      end)

    fencing_task =
      waiting_actor_task(parent, barrier, :fencing, fn ->
        run_fencing_operation(fixture)
      end)

    handler_id =
      attach_query_handler!(barrier, schedule, accounting_task.pid, fencing_task.pid)

    try do
      execution =
        case schedule.direction do
          :forward ->
            run_forward_schedule(barrier, accounting_task, fencing_task)

          :reverse ->
            run_reverse_schedule(barrier, accounting_task, fencing_task)
        end

      query_proof = assert_query_proof!(execution.events, schedule)
      transition = assert_row_transition!(fixture, schedule, execution.accounting_result)

      assert {:ok, %UpstreamIdentity{} = fenced_identity} = execution.fencing_result
      assert CredentialFencing.credential_epoch(fenced_identity) == 2
      assert execution.accounting_backend_pid != execution.fencing_backend_pid

      summary = %{
        schedule_id: schedule.id,
        direction: Atom.to_string(schedule.direction),
        iteration: iteration,
        accounting_backend_pid_sha256: sha256(execution.accounting_backend_pid),
        fencing_backend_pid_sha256: sha256(execution.fencing_backend_pid),
        backend_pids_distinct: true,
        blocked_side: execution.blocked_side,
        blocked_relation: execution.observation.relation,
        blocked_lock_mode: execution.observation.lock_mode,
        blocked_query_sha256: execution.observation.query_sha256,
        blocker_pid_sha256: sha256(execution.observation.blocker_pid),
        waiter_pid_sha256: sha256(execution.observation.waiter_pid),
        blocking_pid_count: length(execution.observation.blocking_pids),
        wait_event_type: execution.observation.wait_event_type,
        blocked_side_stayed_before_assignment_or_insert: true,
        accounting_lock_order: [
          "upstream_identities:FOR KEY SHARE",
          "pool_upstream_assignments:FOR SHARE",
          query_proof.accounting.dependent_insert
        ],
        accounting_query_sha256: query_proof.accounting.query_sha256,
        fencing_lock_order: [
          "upstream_identities:FOR UPDATE",
          "pool_upstream_assignments:FOR UPDATE:ORDER BY id",
          "encrypted_secrets:FOR UPDATE:ORDER BY id"
        ],
        fencing_query_sha256: query_proof.fencing.query_sha256,
        target_reference_ordinal: schedule.target_ordinal,
        target_entry_kind: schedule.target_entry_kind,
        target_event_kind: transition.target_event_kind,
        target_source_event_sha256: transition.target_source_event_sha256,
        row_transition: transition.row_transition,
        credential_epoch_transition: [1, 2],
        deadlock_count: 0,
        no_deadlock: true
      }

      Map.put(summary, :trace_sha256, term_sha256(summary))
    after
      send(accounting_task.pid, {barrier, :release_actor, :accounting})
      send(fencing_task.pid, {barrier, :release_actor, :fencing})
      :telemetry.detach(handler_id)
      shutdown_task(accounting_task)
      shutdown_task(fencing_task)
    end
  end

  defp run_forward_schedule(barrier, accounting_task, fencing_task) do
    send(accounting_task.pid, {barrier, :start_actor, :accounting})

    assert_receive {^barrier, :actor_started, :accounting, accounting_backend_pid},
                   @barrier_timeout

    assert_receive {^barrier, :actor_paused, :accounting, ^accounting_backend_pid},
                   @barrier_timeout

    send(fencing_task.pid, {barrier, :start_actor, :fencing})

    assert_receive {^barrier, :actor_started, :fencing, fencing_backend_pid}, @barrier_timeout

    observation =
      observe_blocked_query!(fencing_backend_pid, accounting_backend_pid, :identity_for_update)

    pre_release_events = drain_query_events(barrier, [])

    refute Enum.any?(pre_release_events, fn event ->
             event.actor == :fencing and
               event.operation in [:assignment_for_update, :secrets_for_update]
           end)

    send(accounting_task.pid, {barrier, :release_actor, :accounting})

    accounting_result = await_actor!(accounting_task)
    fencing_result = await_actor!(fencing_task)
    events = pre_release_events ++ drain_query_events(barrier, [])

    %{
      accounting_backend_pid: accounting_backend_pid,
      accounting_result: accounting_result,
      blocked_side: "fencing",
      events: events,
      fencing_backend_pid: fencing_backend_pid,
      fencing_result: fencing_result,
      observation: observation
    }
  end

  defp run_reverse_schedule(barrier, accounting_task, fencing_task) do
    send(fencing_task.pid, {barrier, :start_actor, :fencing})

    assert_receive {^barrier, :actor_started, :fencing, fencing_backend_pid}, @barrier_timeout

    assert_receive {^barrier, :actor_paused, :fencing, ^fencing_backend_pid}, @barrier_timeout

    send(accounting_task.pid, {barrier, :start_actor, :accounting})

    assert_receive {^barrier, :actor_started, :accounting, accounting_backend_pid},
                   @barrier_timeout

    observation =
      observe_blocked_query!(accounting_backend_pid, fencing_backend_pid, :identity_key_share)

    pre_release_events = drain_query_events(barrier, [])

    refute Enum.any?(pre_release_events, fn event ->
             event.actor == :accounting and
               event.operation in [:assignment_share, :attempt_insert, :ledger_insert]
           end)

    send(fencing_task.pid, {barrier, :release_actor, :fencing})

    fencing_result = await_actor!(fencing_task)
    accounting_result = await_actor!(accounting_task)
    events = pre_release_events ++ drain_query_events(barrier, [])

    %{
      accounting_backend_pid: accounting_backend_pid,
      accounting_result: accounting_result,
      blocked_side: "accounting",
      events: events,
      fencing_backend_pid: fencing_backend_pid,
      fencing_result: fencing_result,
      observation: observation
    }
  end

  defp run_membership_contention(fixture) do
    parent = self()
    barrier = make_ref()

    attempt_task =
      waiting_actor_task(parent, barrier, :accounting, fn ->
        Accounting.create_attempt(fixture.request, fixture.assignment)
      end)

    handler_id = attach_membership_handler!(barrier, attempt_task.pid)

    try do
      send(attempt_task.pid, {barrier, :start_actor, :accounting})

      assert_receive {^barrier, :actor_started, :accounting, accounting_backend_pid},
                     @barrier_timeout

      assert_receive {^barrier, :actor_paused, :accounting, ^accounting_backend_pid},
                     @barrier_timeout

      pre_release_events = drain_query_events(barrier, [])
      refute Enum.any?(pre_release_events, &(&1.operation == :attempt_insert))

      membership_task =
        waiting_actor_task(parent, barrier, :membership, fn ->
          fixture.assignment
          |> Ecto.Changeset.change(upstream_identity_id: fixture.alternate_identity.id)
          |> Repo.update!()
        end)

      try do
        send(membership_task.pid, {barrier, :start_actor, :membership})

        assert_receive {^barrier, :actor_started, :membership, membership_backend_pid},
                       @barrier_timeout

        observation =
          observe_blocked_query!(
            membership_backend_pid,
            accounting_backend_pid,
            :assignment_update
          )

        assert Repo.reload!(fixture.assignment).upstream_identity_id == fixture.identity.id

        send(attempt_task.pid, {barrier, :release_actor, :accounting})

        assert {:ok, %Attempt{} = attempt} = await_actor!(attempt_task)
        assert %PoolUpstreamAssignment{} = updated_assignment = await_actor!(membership_task)

        assert attempt.pool_upstream_assignment_id == fixture.assignment.id
        assert attempt.upstream_identity_id == fixture.identity.id
        assert updated_assignment.upstream_identity_id == fixture.alternate_identity.id
        assert attempt_count(fixture.request.id) == 1

        summary = %{
          id: "A01-membership-update",
          relation: "pool_upstream_assignments",
          protected_field: "upstream_identity_id",
          accounting_lock: "FOR SHARE",
          result: "blocked_until_attempt_commit",
          accounting_backend_pid_sha256: sha256(accounting_backend_pid),
          membership_backend_pid_sha256: sha256(membership_backend_pid),
          blocker_pid_sha256: sha256(observation.blocker_pid),
          waiter_pid_sha256: sha256(observation.waiter_pid),
          blocking_pid_count: length(observation.blocking_pids),
          wait_event_type: observation.wait_event_type,
          blocked_query_sha256: observation.query_sha256,
          attempt_id_sha256: sha256(attempt.id),
          assignment_identity_transition: ["original", "alternate"],
          deadlock_count: 0
        }

        Map.put(summary, :trace_sha256, term_sha256(summary))
      after
        send(membership_task.pid, {barrier, :release_actor, :membership})
        shutdown_task(membership_task)
      end
    after
      send(attempt_task.pid, {barrier, :release_actor, :accounting})
      :telemetry.detach(handler_id)
      shutdown_task(attempt_task)
    end
  end

  defp waiting_actor_task(parent, barrier, actor, operation) do
    Task.async(fn ->
      receive do
        {^barrier, :start_actor, ^actor} ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = backend_pid!()
            Process.put({__MODULE__, barrier, :backend_pid}, backend_pid)
            send(parent, {barrier, :actor_started, actor, backend_pid})
            operation.()
          end)
      after
        @barrier_timeout ->
          raise "timed out waiting to start the #{actor} actor"
      end
    end)
  end

  defp run_accounting_operation(:attempt, fixture) do
    Accounting.create_attempt(fixture.request, fixture.assignment)
  end

  defp run_accounting_operation(path, fixture)
       when path in [:initial_settlement, :release, :replacement_settlement] do
    Accounting.finalize_success(
      fixture.request,
      fixture.attempt,
      %{
        status: "usage_known",
        source: "task8_concurrency",
        recorded_at: fixture.final_at,
        input_tokens: 2,
        output_tokens: 1,
        total_tokens: 3
      },
      %{now: fixture.final_at, response_status_code: 200}
    )
  end

  defp run_fencing_operation(fixture) do
    Repo.transaction(fn ->
      locked_identity = CredentialFencing.lock_credential_replacement(fixture.identity.id)
      %UpstreamIdentity{} = locked_identity

      locked_identity
      |> Ecto.Changeset.change(%{
        metadata: CredentialFencing.advance_credential_epoch(locked_identity),
        updated_at: fixture.fencing_at
      })
      |> Repo.update!()
    end)
  end

  defp attach_query_handler!(barrier, schedule, accounting_pid, fencing_pid) do
    parent = self()
    handler_id = "task8-accounting-#{schedule.id}-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          handle_schedule_query(
            barrier,
            schedule,
            accounting_pid,
            fencing_pid,
            parent,
            metadata
          )
        end,
        nil
      )

    handler_id
  end

  defp attach_membership_handler!(barrier, accounting_pid) do
    parent = self()
    handler_id = "task8-membership-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          handle_membership_query(barrier, accounting_pid, parent, metadata)
        end,
        nil
      )

    handler_id
  end

  defp query_actor(pid, accounting_pid, _fencing_pid) when pid == accounting_pid,
    do: :accounting

  defp query_actor(pid, _accounting_pid, fencing_pid) when pid == fencing_pid,
    do: :fencing

  defp query_actor(_pid, _accounting_pid, _fencing_pid), do: nil

  defp handle_schedule_query(
         barrier,
         schedule,
         accounting_pid,
         fencing_pid,
         parent,
         metadata
       ) do
    actor = query_actor(self(), accounting_pid, fencing_pid)

    with actor when not is_nil(actor) <- actor,
         true <- metadata[:repo] == Repo,
         event when not is_nil(event) <- classify_query(actor, barrier, metadata) do
      send(parent, {barrier, :query_event, event})
      maybe_pause_actor!(barrier, schedule, event, parent)
    else
      _ignored_query -> :ok
    end
  end

  defp handle_membership_query(barrier, accounting_pid, parent, metadata) do
    with true <- self() == accounting_pid,
         true <- metadata[:repo] == Repo,
         event when not is_nil(event) <- classify_query(:accounting, barrier, metadata) do
      send(parent, {barrier, :query_event, event})
      maybe_pause_membership_actor!(barrier, event, parent)
    else
      _ignored_query -> :ok
    end
  end

  defp maybe_pause_membership_actor!(barrier, event, parent) do
    pause_key = {__MODULE__, barrier, :membership_paused}

    if event.operation == :assignment_share and is_nil(Process.get(pause_key)) do
      Process.put(pause_key, true)
      backend_pid = Process.get({__MODULE__, barrier, :backend_pid})
      send(parent, {barrier, :actor_paused, :accounting, backend_pid})
      await_release!(barrier, :accounting)
    end
  end

  defp classify_query(actor, barrier, %{query: query} = metadata) when is_binary(query) do
    statement = String.trim_leading(query)
    source = metadata[:source]
    operation = classify_operation(source, statement)

    if operation do
      reference_ordinal = reference_ordinal(actor, barrier, operation)

      %{
        actor: actor,
        operation: operation,
        relation: source,
        lock_mode: lock_mode(operation),
        ordered_by_primary_key:
          operation in [:assignment_for_update, :secrets_for_update] and
            Regex.match?(~r/ORDER BY .*\."id"/s, statement),
        query_sha256: sha256(statement),
        reference_ordinal: reference_ordinal
      }
    end
  end

  defp classify_query(_actor, _barrier, _metadata), do: nil

  defp classify_operation("upstream_identities", statement) do
    cond do
      String.contains?(statement, "FOR KEY SHARE") -> :identity_key_share
      String.contains?(statement, "FOR UPDATE") -> :identity_for_update
      true -> nil
    end
  end

  defp classify_operation("pool_upstream_assignments", statement) do
    cond do
      String.contains?(statement, "FOR SHARE") -> :assignment_share
      String.contains?(statement, "FOR UPDATE") -> :assignment_for_update
      true -> nil
    end
  end

  defp classify_operation("encrypted_secrets", statement) do
    if String.contains?(statement, "FOR UPDATE"), do: :secrets_for_update
  end

  defp classify_operation("attempts", statement) do
    if String.starts_with?(statement, "INSERT"), do: :attempt_insert
  end

  defp classify_operation("ledger_entries", statement) do
    cond do
      String.starts_with?(statement, "INSERT") -> :ledger_insert
      String.starts_with?(statement, "UPDATE") -> :ledger_update
      true -> nil
    end
  end

  defp classify_operation(_source, _statement), do: nil

  defp reference_ordinal(actor, barrier, operation)
       when operation in [:identity_key_share, :identity_for_update] do
    key = {__MODULE__, barrier, actor, :reference_ordinal}
    ordinal = Process.get(key, 0) + 1
    Process.put(key, ordinal)
    ordinal
  end

  defp reference_ordinal(actor, barrier, _operation) do
    Process.get({__MODULE__, barrier, actor, :reference_ordinal}, 0)
  end

  defp maybe_pause_actor!(barrier, schedule, event, parent) do
    pause? =
      case schedule.direction do
        :forward ->
          event.actor == :accounting and event.operation == :identity_key_share and
            event.reference_ordinal == schedule.target_ordinal

        :reverse ->
          event.actor == :fencing and event.operation == :identity_for_update and
            event.reference_ordinal == 1
      end

    pause_key = {__MODULE__, barrier, event.actor, :paused}

    if pause? && is_nil(Process.get(pause_key)) do
      Process.put(pause_key, true)
      backend_pid = Process.get({__MODULE__, barrier, :backend_pid})
      send(parent, {barrier, :actor_paused, event.actor, backend_pid})
      await_release!(barrier, event.actor)
    end
  end

  defp await_release!(barrier, actor) do
    receive do
      {^barrier, :release_actor, ^actor} -> :ok
    after
      @barrier_timeout -> raise "timed out waiting to release the #{actor} actor"
    end
  end

  defp observe_blocked_query!(waiter_pid, blocker_pid, expected_operation) do
    run_unboxed(fn ->
      deadline = System.monotonic_time(:millisecond) + @observer_timeout_ms
      do_observe_blocked_query!(waiter_pid, blocker_pid, expected_operation, deadline)
    end)
  end

  defp do_observe_blocked_query!(waiter_pid, blocker_pid, expected_operation, deadline) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT pg_blocking_pids($1), wait_event_type, state, query FROM pg_stat_activity WHERE pid = $1",
        [waiter_pid]
      )

    case rows do
      [[blocking_pids, "Lock" = wait_event_type, state, query]] ->
        query_proof = classify_blocked_query(query)

        if blocking_pids == [blocker_pid] and query_proof.operation == expected_operation do
          Map.merge(query_proof, %{
            blocker_pid: blocker_pid,
            blocking_pids: blocking_pids,
            state: state,
            waiter_pid: waiter_pid,
            wait_event_type: wait_event_type
          })
        else
          retry_blocking_observation!(waiter_pid, blocker_pid, expected_operation, deadline)
        end

      _ ->
        retry_blocking_observation!(waiter_pid, blocker_pid, expected_operation, deadline)
    end
  end

  defp retry_blocking_observation!(waiter_pid, blocker_pid, expected_operation, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("backend never reported the expected #{expected_operation} PostgreSQL lock wait")
    else
      receive do
      after
        0 -> do_observe_blocked_query!(waiter_pid, blocker_pid, expected_operation, deadline)
      end
    end
  end

  defp classify_blocked_query(query) when is_binary(query) do
    statement = String.trim_leading(query)

    cond do
      String.contains?(statement, ~s(FROM "upstream_identities")) and
          String.contains?(statement, "FOR KEY SHARE") ->
        blocked_query_proof(
          :identity_key_share,
          "upstream_identities",
          "FOR KEY SHARE",
          statement
        )

      String.contains?(statement, ~s(FROM "upstream_identities")) and
          String.contains?(statement, "FOR UPDATE") ->
        blocked_query_proof(:identity_for_update, "upstream_identities", "FOR UPDATE", statement)

      String.starts_with?(statement, ~s(UPDATE "pool_upstream_assignments")) ->
        blocked_query_proof(:assignment_update, "pool_upstream_assignments", "UPDATE", statement)

      true ->
        %{
          operation: :other,
          relation: "other",
          lock_mode: "other",
          query_sha256: sha256(statement)
        }
    end
  end

  defp blocked_query_proof(operation, relation, lock_mode, statement) do
    %{
      operation: operation,
      relation: relation,
      lock_mode: lock_mode,
      query_sha256: sha256(statement)
    }
  end

  defp assert_query_proof!(events, schedule) do
    accounting_events =
      Enum.filter(events, fn event ->
        event.actor == :accounting and
          event.operation in [
            :identity_key_share,
            :assignment_share,
            :attempt_insert,
            :ledger_insert
          ]
      end)

    target_index =
      Enum.find_index(accounting_events, fn event ->
        event.operation == :identity_key_share and
          event.reference_ordinal == schedule.target_ordinal
      end)

    assert is_integer(target_index),
           "#{schedule.id} did not emit its target identity KEY SHARE"

    expected_insert = if schedule.path == :attempt, do: :attempt_insert, else: :ledger_insert
    target_sequence = Enum.slice(accounting_events, target_index, 3)

    assert Enum.map(target_sequence, & &1.operation) == [
             :identity_key_share,
             :assignment_share,
             expected_insert
           ]

    assert Enum.all?(target_sequence, &(&1.reference_ordinal == schedule.target_ordinal))

    fencing_events =
      Enum.filter(events, fn event ->
        event.actor == :fencing and
          event.operation in [:identity_for_update, :assignment_for_update, :secrets_for_update]
      end)

    assert Enum.map(Enum.take(fencing_events, 3), & &1.operation) == [
             :identity_for_update,
             :assignment_for_update,
             :secrets_for_update
           ]

    [identity_lock, assignment_lock, secrets_lock] = Enum.take(fencing_events, 3)
    assert assignment_lock.ordered_by_primary_key
    assert secrets_lock.ordered_by_primary_key

    %{
      accounting: %{
        dependent_insert: dependent_insert_label(expected_insert),
        query_sha256: Enum.map(target_sequence, & &1.query_sha256)
      },
      fencing: %{
        query_sha256: Enum.map([identity_lock, assignment_lock, secrets_lock], & &1.query_sha256)
      }
    }
  end

  defp assert_row_transition!(fixture, %{path: :attempt}, accounting_result) do
    assert {:ok, %Attempt{} = result_attempt} = accounting_result

    run_unboxed(fn ->
      assert [attempt] =
               Repo.all(from attempt in Attempt, where: attempt.request_id == ^fixture.request.id)

      assert attempt.id == result_attempt.id
      assert attempt.pool_upstream_assignment_id == fixture.assignment.id
      assert attempt.upstream_identity_id == fixture.identity.id

      %{
        target_event_kind: "attempt_id",
        target_source_event_sha256: sha256(attempt.id),
        row_transition: %{
          attempts: 1,
          assignment_reference: "original",
          identity_reference: "original"
        }
      }
    end)
  end

  defp assert_row_transition!(fixture, %{path: path}, accounting_result)
       when path in [:initial_settlement, :release] do
    assert {:ok, %{settlement: result_settlement, release: result_release}} = accounting_result

    run_unboxed(fn ->
      entries = ledger_entries(fixture.request.id)
      settlements = Enum.filter(entries, &(&1.entry_kind == "settlement"))
      releases = Enum.filter(entries, &(&1.entry_kind == "release"))

      assert Enum.count(entries, &(&1.entry_kind == "reservation")) == 1
      assert [settlement] = settlements
      assert [release] = releases
      assert settlement.id == result_settlement.id
      assert release.id == result_release.id
      assert settlement.amount_status == "recorded"
      assert settlement.usage_status == "usage_known"
      assert is_nil(settlement.correction_of_entry_id)

      target = if path == :release, do: release, else: settlement

      %{
        target_event_kind:
          if(path == :release,
            do: "release_source_event",
            else: "settlement_source_event"
          ),
        target_source_event_sha256: sha256(target.source_event_id),
        row_transition: %{
          ledger_entries: 3,
          recorded_releases: 1,
          recorded_settlements: 1,
          replacement_settlements: 0,
          target_entry_kind: target.entry_kind
        }
      }
    end)
  end

  defp assert_row_transition!(fixture, %{path: :replacement_settlement}, accounting_result) do
    assert {:ok, %{settlement: replacement, release: release}} = accounting_result

    run_unboxed(fn ->
      entries = ledger_entries(fixture.request.id)
      settlements = Enum.filter(entries, &(&1.entry_kind == "settlement"))
      releases = Enum.filter(entries, &(&1.entry_kind == "release"))

      assert Enum.count(entries, &(&1.entry_kind == "reservation")) == 1
      assert length(settlements) == 2
      assert [release_row] = releases
      assert release_row.id == release.id

      assert [voided] = Enum.filter(settlements, &(&1.amount_status == "voided"))
      assert [recorded] = Enum.filter(settlements, &(&1.amount_status == "recorded"))

      assert voided.id == fixture.prior_settlement.id
      assert recorded.id == replacement.id
      assert recorded.usage_status == "usage_known"
      assert recorded.correction_of_entry_id == voided.id

      assert recorded.source_event_id ==
               LedgerEntries.reconciled_settlement_source_event_id(fixture.request.id)

      %{
        target_event_kind: "reconciled_settlement_source_event",
        target_source_event_sha256: sha256(recorded.source_event_id),
        row_transition: %{
          ledger_entries: 4,
          recorded_releases: 1,
          recorded_settlements: 1,
          replacement_settlements: 1,
          voided_settlements: 1,
          correction_link: "original_settlement"
        }
      }
    end)
  end

  defp committed_schedule_fixture!(path, iteration) do
    run_unboxed(fn ->
      unique = System.unique_integer([:positive])

      setup =
        accounting_setup(%{
          account_label: "Task 8 accounting #{unique}"
        })

      reserved =
        reserve!(
          setup,
          "task8-accounting-#{path}-#{iteration}-#{unique}"
        )

      timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      fixture =
        setup
        |> Map.merge(%{
          request: reserved.request,
          fencing_at: DateTime.add(timestamp, 2, :second),
          final_at: DateTime.add(timestamp, 1, :second),
          identity_ids: [setup.identity.id]
        })

      case path do
        :attempt ->
          fixture

        path when path in [:initial_settlement, :release] ->
          assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
          Map.put(fixture, :attempt, attempt)

        :replacement_settlement ->
          assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

          assert {:ok, failed} =
                   Accounting.finalize_failure(reserved.request, attempt, %{
                     now: timestamp,
                     last_error_code: "task8_prior_unknown",
                     usage: %{status: "usage_unknown", source: "task8_prior"}
                   })

          fixture
          |> Map.put(:request, failed.request)
          |> Map.put(:attempt, failed.attempt)
          |> Map.put(:prior_settlement, failed.settlement)
      end
    end)
  end

  defp committed_membership_fixture! do
    run_unboxed(fn ->
      unique = System.unique_integer([:positive])

      setup =
        accounting_setup(%{
          account_label: "Task 8 membership #{unique}"
        })

      reserved = reserve!(setup, "task8-membership-#{unique}")

      alternate_identity =
        upstream_identity_fixture(%{
          account_label: "Task 8 alternate #{unique}",
          chatgpt_account_id: "task8_alternate_#{unique}"
        })

      setup
      |> Map.merge(%{
        request: reserved.request,
        alternate_identity: alternate_identity,
        identity_ids: [setup.identity.id, alternate_identity.id]
      })
    end)
  end

  defp cleanup_committed_fixture!(fixture) do
    run_unboxed(fn ->
      {pool_count, _} =
        Repo.delete_all(from pool in Pool, where: pool.id == ^fixture.pool.id)

      {identity_count, _} =
        Repo.delete_all(
          from identity in UpstreamIdentity,
            where: identity.id in ^fixture.identity_ids
        )

      {pricing_count, _} =
        Repo.delete_all(
          from pricing in PricingSnapshot,
            where: pricing.id == ^fixture.pricing.id
        )

      %{
        identities: identity_count,
        pools: pool_count,
        pricing_snapshots: pricing_count
      }
    end)
  end

  defp reserve!(setup, correlation_id) do
    assert {:ok, reserved} =
             Accounting.reserve(
               setup.auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 4},
               %{correlation_id: correlation_id}
             )

    reserved
  end

  defp ledger_entries(request_id) do
    Repo.all(
      from entry in LedgerEntry,
        where: entry.request_id == ^request_id,
        order_by: [asc: entry.created_at, asc: entry.id]
    )
  end

  defp attempt_count(request_id) do
    Repo.aggregate(
      from(attempt in Attempt, where: attempt.request_id == ^request_id),
      :count,
      :id
    )
  end

  defp backend_pid! do
    %{rows: [[pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    pid
  end

  defp run_unboxed(operation) do
    Task.async(fn -> Sandbox.unboxed_run(Repo, operation) end)
    |> Task.await(@actor_timeout)
  end

  defp await_actor!(task), do: Task.await(task, @actor_timeout)

  defp shutdown_task(task) do
    if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
  end

  defp drain_query_events(barrier, events) do
    receive do
      {^barrier, :query_event, event} -> drain_query_events(barrier, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp lock_mode(:identity_key_share), do: "FOR KEY SHARE"
  defp lock_mode(:identity_for_update), do: "FOR UPDATE"
  defp lock_mode(:assignment_share), do: "FOR SHARE"
  defp lock_mode(:assignment_for_update), do: "FOR UPDATE"
  defp lock_mode(:secrets_for_update), do: "FOR UPDATE"
  defp lock_mode(_operation), do: nil

  defp dependent_insert_label(:attempt_insert), do: "attempts:INSERT"
  defp dependent_insert_label(:ledger_insert), do: "ledger_entries:INSERT"

  defp record_evidence(record) do
    if path = System.get_env("TASK8_ACCOUNTING_EVIDENCE_PATH") do
      File.mkdir_p!(Path.dirname(path))

      File.open!(path, [:append, :binary], fn io ->
        IO.binwrite(io, Jason.encode!(record) <> "\n")
        :ok = :file.sync(io)
      end)
    end
  end

  defp term_sha256(value), do: value |> :erlang.term_to_binary() |> sha256()

  defp sha256(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp sha256(value), do: value |> to_string() |> sha256()
end
