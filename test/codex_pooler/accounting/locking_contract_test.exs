defmodule CodexPooler.Accounting.LockingContractTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounting.RequestLifecycle.ReferenceLocks
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures

  @scenario_timeout_ms 5_000
  @detection_timeout_ms 15_000

  describe "real FOR UPDATE contracts" do
    test "L08 attempt creation locks the request row" do
      setup = accounting_setup()
      reserved = reserve!(setup, "l08-lock")

      {result, queries} =
        capture_queries(fn -> Accounting.create_attempt(reserved.request, setup.assignment) end)

      assert {:ok, _attempt} = result

      assert_for_update!(
        queries,
        "L08",
        "RequestLifecycle.create_attempt/3",
        "requests",
        reserved.request.id
      )

      queries
      |> assert_reference_sequences!("attempts", setup.identity.id, setup.assignment.id, 1)
      |> hd()
      |> record_reference_sequence(
        "A01",
        "RequestLifecycle.create_attempt/3",
        "attempt"
      )
    end

    test "L09 retry failure locks the request row" do
      {setup, reserved, attempt} = open_attempt_fixture("l09-lock")

      {result, queries} =
        capture_queries(fn -> Accounting.record_retryable_attempt_failure(attempt) end)

      assert {:ok, _attempt} = result

      assert_for_update!(
        queries,
        "L09",
        "RequestLifecycle.record_retryable_attempt_failure/2",
        "requests",
        reserved.request.id
      )

      assert setup.assignment.id == attempt.pool_upstream_assignment_id
    end

    test "L10 retry failure locks the attempt row" do
      {_setup, _reserved, attempt} = open_attempt_fixture("l10-lock")

      {result, queries} =
        capture_queries(fn -> Accounting.record_retryable_attempt_failure(attempt) end)

      assert {:ok, _attempt} = result

      assert_for_update!(
        queries,
        "L10",
        "RequestLifecycle.record_retryable_attempt_failure/2",
        "attempts",
        attempt.id
      )
    end

    test "L11 reserved failure locks the request row" do
      setup = accounting_setup()
      reserved = reserve!(setup, "l11-lock")

      {result, queries} =
        capture_queries(fn -> Accounting.finalize_reserved_request_failure(reserved.request) end)

      assert {:ok, _finalized} = result

      assert_for_update!(
        queries,
        "L11",
        "RequestLifecycle.finalize_reserved_request_failure/2",
        "requests",
        reserved.request.id
      )
    end

    test "L12 finalization locks the request row" do
      {_setup, reserved, attempt} = open_attempt_fixture("l12-lock")

      {result, queries} =
        capture_queries(fn -> Accounting.finalize_failure(reserved.request, attempt) end)

      assert {:ok, _finalized} = result

      assert_for_update!(
        queries,
        "L12",
        "RequestLifecycle.finalize_request/3",
        "requests",
        reserved.request.id
      )
    end

    test "L13 finalization locks the attempt row" do
      {_setup, reserved, attempt} = open_attempt_fixture("l13-lock")

      {result, queries} =
        capture_queries(fn -> Accounting.finalize_failure(reserved.request, attempt) end)

      assert {:ok, _finalized} = result

      assert_for_update!(
        queries,
        "L13",
        "RequestLifecycle.finalize_request/3",
        "attempts",
        attempt.id
      )
    end

    test "L14 stale terminal recovery locks the request row" do
      %{now: now, request: request} = stale_terminal_attempt_fixture()

      {result, queries} = capture_queries(fn -> Accounting.recover_stale_reservations(now) end)

      assert {:ok, %{stale_terminal_attempts_recovered: 1}} = result

      assert_for_update!(
        queries,
        "L14",
        "RequestLifecycle.recover_stale_reservations/2",
        "requests",
        request.id
      )
    end

    test "L15 stale terminal recovery locks the attempt row" do
      %{attempt: attempt, now: now} = stale_terminal_attempt_fixture()

      {result, queries} = capture_queries(fn -> Accounting.recover_stale_reservations(now) end)

      assert {:ok, %{stale_terminal_attempts_recovered: 1}} = result

      assert_for_update!(
        queries,
        "L15",
        "RequestLifecycle.recover_stale_reservations/2",
        "attempts",
        attempt.id
      )
    end
  end

  describe "pre-change absence contracts" do
    test "L08 attempt creation raises when the request row is missing" do
      setup = accounting_setup()

      assert_raise Ecto.NoResultsError, fn ->
        Accounting.create_attempt(%Request{id: Ecto.UUID.generate()}, setup.assignment)
      end
    end

    test "L09 retry failure raises when the request row is missing" do
      missing_request_attempt = %Attempt{
        id: Ecto.UUID.generate(),
        request_id: Ecto.UUID.generate()
      }

      assert_raise Ecto.NoResultsError, fn ->
        Accounting.record_retryable_attempt_failure(missing_request_attempt)
      end
    end

    test "L10 retry failure raises when the attempt row is missing" do
      setup = accounting_setup()
      reserved = reserve!(setup, "l10-missing-attempt")

      missing_attempt = %Attempt{
        id: Ecto.UUID.generate(),
        request_id: reserved.request.id
      }

      assert_raise Ecto.NoResultsError, fn ->
        Accounting.record_retryable_attempt_failure(missing_attempt)
      end
    end

    test "L11 reserved failure raises when the request row is missing" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounting.finalize_reserved_request_failure(%Request{id: Ecto.UUID.generate()})
      end
    end

    test "L12 finalization raises when the request row is missing" do
      missing_request = %Request{id: Ecto.UUID.generate()}
      missing_attempt = %Attempt{id: Ecto.UUID.generate(), request_id: missing_request.id}

      assert_raise Ecto.NoResultsError, fn ->
        Accounting.finalize_failure(missing_request, missing_attempt)
      end
    end

    test "L13 finalization raises when the attempt row is missing" do
      setup = accounting_setup()
      reserved = reserve!(setup, "l13-missing-attempt")

      missing_attempt = %Attempt{
        id: Ecto.UUID.generate(),
        request_id: reserved.request.id
      }

      assert_raise Ecto.NoResultsError, fn ->
        Accounting.finalize_failure(reserved.request, missing_attempt)
      end
    end

    test "L14 stale recovery preserves the zero-count noop contract without a request row" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, summary} = Accounting.recover_stale_reservations(now)
      assert summary.stale_terminal_attempts_recovered == 0
    end

    test "L15 stale recovery preserves the zero-count noop contract without an attempt row" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, summary} = Accounting.recover_stale_reservations(now)
      assert summary.stale_terminal_attempts_recovered == 0
    end
  end

  describe "upstream reference validation" do
    test "A01 rejects a nil identity with zero attempts" do
      setup = accounting_setup()
      reserved = reserve!(setup, "a01-nil-identity")
      assignment = %{setup.assignment | upstream_identity_id: nil}

      assert {:error, %{code: :upstream_identity_not_found}} =
               Accounting.create_attempt(reserved.request, assignment)

      assert attempt_count(reserved.request.id) == 0
    end

    test "A01 rejects a nil assignment with zero attempts" do
      setup = accounting_setup()
      reserved = reserve!(setup, "a01-nil-assignment")
      assignment = %{setup.assignment | id: nil}

      assert {:error, %{code: :pool_upstream_assignment_not_found}} =
               Accounting.create_attempt(reserved.request, assignment)

      assert attempt_count(reserved.request.id) == 0
    end

    test "A01 rejects a missing identity with zero attempts" do
      setup = accounting_setup()
      reserved = reserve!(setup, "a01-missing-identity")
      assignment = %{setup.assignment | upstream_identity_id: Ecto.UUID.generate()}

      assert {:error, %{code: :upstream_identity_not_found}} =
               Accounting.create_attempt(reserved.request, assignment)

      assert attempt_count(reserved.request.id) == 0
    end

    test "A01 rejects a missing assignment with zero attempts" do
      setup = accounting_setup()
      reserved = reserve!(setup, "a01-missing-assignment")
      assignment = %{setup.assignment | id: Ecto.UUID.generate()}

      assert {:error, %{code: :pool_upstream_assignment_not_found}} =
               Accounting.create_attempt(reserved.request, assignment)

      assert attempt_count(reserved.request.id) == 0
    end

    test "A01 rejects an identity assignment mismatch with zero attempts" do
      setup = accounting_setup()
      %{identity: other_identity} = upstream_assignment_fixture(setup.pool)
      reserved = reserve!(setup, "a01-mismatch")
      assignment = %{setup.assignment | upstream_identity_id: other_identity.id}

      assert {:error, %{code: :upstream_reference_mismatch}} =
               Accounting.create_attempt(reserved.request, assignment)

      assert attempt_count(reserved.request.id) == 0
    end

    test "G01 reservation bypasses upstream locks only for the nil pair" do
      setup = accounting_setup()

      {result, queries} = capture_queries(fn -> reserve!(setup, "g01-bypass") end)

      assert %{request: _request} = result
      refute_reference_locks!(queries)
      assert Enum.any?(queries, &insert_query?(&1, "ledger_entries"))
      record_accounting_path("G01", "Reservation.reserve_for_model/4", "nil_pair_bypass")
    end

    test "G02 undispatched failure release bypasses upstream locks only for the nil pair" do
      setup = accounting_setup()
      reserved = reserve!(setup, "g02-bypass")

      {result, queries} =
        capture_queries(fn -> Accounting.finalize_reserved_request_failure(reserved.request) end)

      assert {:ok, _finalized} = result
      refute_reference_locks!(queries)
      assert Enum.any?(queries, &insert_query?(&1, "ledger_entries"))

      record_accounting_path(
        "G02",
        "RequestLifecycle.finalize_reserved_request_failure/2",
        "nil_pair_bypass"
      )
    end

    test "G03 and G04 lock identity then assignment before settlement and release inserts" do
      {setup, reserved, attempt} = open_attempt_fixture("g03-g04-order")

      {result, queries} =
        capture_queries(fn ->
          Accounting.finalize_success(
            reserved.request,
            attempt,
            %{status: "usage_known", input_tokens: 2, output_tokens: 1, total_tokens: 3},
            %{response_status_code: 200}
          )
        end)

      assert {:ok, finalized} = result

      [settlement_sequence, release_sequence] =
        assert_reference_sequences!(
          queries,
          "ledger_entries",
          setup.identity.id,
          setup.assignment.id,
          2
        )

      assert finalized.settlement.entry_kind == "settlement"
      assert finalized.release.entry_kind == "release"
      assert query_has_param?(settlement_sequence.insert, finalized.settlement.source_event_id)
      assert query_has_param?(release_sequence.insert, finalized.release.source_event_id)

      record_reference_sequence(
        settlement_sequence,
        "G03",
        "LedgerEntries.create_or_get_with_status!/1",
        "settlement"
      )

      record_reference_sequence(
        release_sequence,
        "G04",
        "LedgerEntries.create_or_get_with_status!/1",
        "release"
      )
    end

    test "G05 locks identity then assignment before replacement settlement insert" do
      {setup, reserved, attempt} = open_attempt_fixture("g05-order")
      first_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, failed} =
               Accounting.finalize_failure(reserved.request, attempt, %{
                 now: first_at,
                 last_error_code: "synthetic_failure",
                 usage: %{status: "usage_unknown", source: "test"}
               })

      {result, queries} =
        capture_queries(fn ->
          Accounting.finalize_success(
            failed.request,
            failed.attempt,
            %{
              status: "usage_known",
              source: "late_test",
              recorded_at: DateTime.add(first_at, 1, :second),
              input_tokens: 2,
              output_tokens: 1,
              total_tokens: 3
            },
            %{now: DateTime.add(first_at, 1, :second), response_status_code: 200}
          )
        end)

      assert {:ok, finalized} = result

      [replacement_sequence | _release_sequences] =
        assert_reference_sequences!(
          queries,
          "ledger_entries",
          setup.identity.id,
          setup.assignment.id,
          2
        )

      assert finalized.settlement.entry_kind == "settlement"
      assert finalized.settlement.amount_status == "recorded"
      assert finalized.settlement.correction_of_entry_id == failed.settlement.id
      assert query_has_param?(replacement_sequence.insert, finalized.settlement.source_event_id)

      record_reference_sequence(
        replacement_sequence,
        "G05",
        "LedgerEntries.create_or_get_with_status!/1",
        "replacement_settlement"
      )
    end

    test "G03 mismatch rolls back request attempt and dependent rows" do
      {setup, reserved, attempt} = open_attempt_fixture("g03-mismatch")
      %{identity: other_identity} = upstream_assignment_fixture(setup.pool)
      request_status = reserved.request.status

      attempt
      |> Ecto.Changeset.change(upstream_identity_id: other_identity.id)
      |> Repo.update!()

      assert {:error, %{code: :upstream_reference_mismatch}} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{status: "usage_known", input_tokens: 2, output_tokens: 1, total_tokens: 3}
               )

      assert Repo.reload!(reserved.request).status == request_status
      assert Repo.reload!(attempt).status == "in_progress"
      assert ledger_kinds(reserved.request.id) == ["reservation"]
    end

    test "G05 mismatch rolls back the void and replacement insert" do
      {setup, reserved, attempt} = open_attempt_fixture("g05-mismatch")
      first_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, failed} =
               Accounting.finalize_failure(reserved.request, attempt, %{
                 now: first_at,
                 usage: %{status: "usage_unknown", source: "test"}
               })

      %{identity: other_identity} = upstream_assignment_fixture(setup.pool)

      failed.attempt
      |> Ecto.Changeset.change(upstream_identity_id: other_identity.id)
      |> Repo.update!()

      assert {:error, %{code: :upstream_reference_mismatch}} =
               Accounting.finalize_success(
                 failed.request,
                 failed.attempt,
                 %{
                   status: "usage_known",
                   source: "late_test",
                   recorded_at: DateTime.add(first_at, 1, :second),
                   input_tokens: 2,
                   output_tokens: 1,
                   total_tokens: 3
                 },
                 %{now: DateTime.add(first_at, 1, :second)}
               )

      assert Repo.reload!(failed.request).status == "failed"
      assert Repo.reload!(failed.attempt).status == "failed"

      assert [settlement] =
               Repo.all(
                 from entry in LedgerEntry,
                   where:
                     entry.request_id == ^reserved.request.id and
                       entry.entry_kind == "settlement"
               )

      assert settlement.id == failed.settlement.id
      assert settlement.amount_status == "recorded"
      assert is_nil(settlement.correction_of_entry_id)
    end

    test "reference lock helper rejects calls outside a transaction" do
      assert_raise ArgumentError, "upstream reference locks require an active transaction", fn ->
        ReferenceLocks.lock_and_validate!(nil, nil)
      end
    end
  end

  describe "real PostgreSQL assignment membership contention" do
    @tag :task3_membership_lock
    test "assignment FOR SHARE blocks membership mutation until A01 inserts and commits" do
      fixture = committed_membership_fixture!()
      on_exit(fn -> cleanup_committed_membership_fixture!(fixture) end)

      parent = self()
      barrier = make_ref()
      handler_id = "task3-membership-lock-#{System.unique_integer([:positive])}"

      attempt_task =
        Task.async(fn ->
          receive do
            {^barrier, :start_attempt} ->
              Sandbox.unboxed_run(Repo, fn ->
                Process.put({__MODULE__, barrier, :backend_pid}, backend_pid!())
                Accounting.create_attempt(fixture.request, fixture.assignment)
              end)
          end
        end)

      :ok =
        :telemetry.attach(
          handler_id,
          [:codex_pooler, :repo, :query],
          fn _event, _measurements, metadata, _config ->
            if self() == attempt_task.pid and assignment_share_query?(metadata) and
                 is_nil(Process.get({__MODULE__, barrier, :paused})) do
              Process.put({__MODULE__, barrier, :paused}, true)
              backend_pid = Process.get({__MODULE__, barrier, :backend_pid})

              send(
                parent,
                {barrier, :assignment_share_acquired, backend_pid}
              )

              receive do
                {^barrier, :release_attempt} -> :ok
              after
                @scenario_timeout_ms ->
                  raise "timed out waiting to release the A01 membership barrier"
              end
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      send(attempt_task.pid, {barrier, :start_attempt})

      assert_receive {^barrier, :assignment_share_acquired, blocker_pid},
                     @detection_timeout_ms

      assert attempt_count(fixture.request.id) == 0

      membership_task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            waiter_pid = backend_pid!()
            send(parent, {barrier, :membership_update_started, waiter_pid})

            fixture.assignment
            |> Ecto.Changeset.change(upstream_identity_id: fixture.alternate_identity.id)
            |> Repo.update!()
          end)
        end)

      assert_receive {^barrier, :membership_update_started, waiter_pid},
                     @detection_timeout_ms

      observation =
        Task.async(fn -> observe_blocked_membership_update!(waiter_pid, blocker_pid) end)
        |> Task.await(@detection_timeout_ms)

      assert blocker_pid in observation.blocking_pids
      assert observation.wait_event_type == "Lock"
      assert attempt_count(fixture.request.id) == 0
      assert Repo.reload!(fixture.assignment).upstream_identity_id == fixture.identity.id

      send(attempt_task.pid, {barrier, :release_attempt})

      assert {:ok, attempt} = Task.await(attempt_task, @detection_timeout_ms)
      updated_assignment = Task.await(membership_task, @detection_timeout_ms)

      assert attempt.pool_upstream_assignment_id == fixture.assignment.id
      assert attempt.upstream_identity_id == fixture.identity.id
      assert updated_assignment.upstream_identity_id == fixture.alternate_identity.id
      assert attempt_count(fixture.request.id) == 1

      record_membership_evidence(blocker_pid, waiter_pid, observation, attempt)
    end
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

  defp open_attempt_fixture(correlation_id) do
    setup = accounting_setup()
    reserved = reserve!(setup, correlation_id)
    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    {setup, reserved, attempt}
  end

  defp stale_terminal_attempt_fixture do
    setup = accounting_setup()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    request =
      request_fixture(%{pool: setup.pool, api_key: setup.api_key}, %{
        correlation_id: "stale-terminal-lock-#{System.unique_integer([:positive])}",
        model_id: setup.model.id,
        status: "failed",
        usage_status: "usage_unknown",
        completed_at: now,
        response_status_code: 500
      })

    attempt =
      attempt_fixture(request, setup.assignment, %{
        status: "in_progress",
        completed_at: nil,
        upstream_status_code: nil,
        usage_status: "usage_pending"
      })
      |> Ecto.Changeset.change(started_at: DateTime.add(now, -7, :hour))
      |> Repo.update!()

    %{attempt: attempt, now: now, request: request}
  end

  defp capture_queries(fun) do
    parent = self()
    handler_id = "accounting-lock-contract-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            send(parent, {handler_id, metadata[:source], metadata[:query], metadata[:params]})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, queries) do
    receive do
      {^handler_id, source, query, params} ->
        drain_queries(handler_id, [%{params: params, query: query, source: source} | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp assert_for_update!(queries, id, caller, relation, primary_key) do
    query =
      Enum.find(queries, fn query ->
        query.source == relation and is_binary(query.query) and
          String.contains?(query.query, "FOR UPDATE")
      end)

    assert query, "#{id} did not emit FOR UPDATE for #{relation}"
    assert query.params == [Ecto.UUID.dump!(primary_key)]

    record_lock_evidence(id, caller, relation, primary_key, query.query)
  end

  defp insert_query?(query, relation) do
    query.source == relation and is_binary(query.query) and
      String.starts_with?(String.trim_leading(query.query), "INSERT")
  end

  defp refute_reference_locks!(queries) do
    refute Enum.any?(queries, fn query ->
             query.source in ["upstream_identities", "pool_upstream_assignments"] and
               is_binary(query.query) and String.contains?(query.query, "FOR ")
           end)
  end

  defp assert_reference_sequences!(
         queries,
         insert_relation,
         identity_id,
         assignment_id,
         expected_count
       ) do
    trace =
      Enum.flat_map(queries, fn query ->
        case classify_reference_query(query, insert_relation) do
          nil -> []
          operation -> [%{operation: operation, query: query}]
        end
      end)

    sequences = Enum.chunk_every(trace, 3)

    assert length(sequences) == expected_count

    Enum.map(sequences, fn sequence ->
      assert Enum.map(sequence, & &1.operation) == [
               :identity_key_share,
               :assignment_share,
               :dependent_insert
             ]

      [identity, assignment, insert] = sequence
      assert identity.query.params == [Ecto.UUID.dump!(identity_id)]
      assert assignment.query.params == [Ecto.UUID.dump!(assignment_id)]

      %{identity: identity.query, assignment: assignment.query, insert: insert.query}
    end)
  end

  defp classify_reference_query(query, insert_relation) do
    statement = if is_binary(query.query), do: String.trim_leading(query.query), else: ""

    cond do
      query.source == "upstream_identities" and String.contains?(statement, "FOR KEY SHARE") ->
        :identity_key_share

      query.source == "pool_upstream_assignments" and
          String.contains?(statement, "FOR SHARE") ->
        :assignment_share

      query.source == insert_relation and String.starts_with?(statement, "INSERT") ->
        :dependent_insert

      true ->
        nil
    end
  end

  defp query_has_param?(query, value), do: Enum.any?(query.params, &(&1 == value))

  defp assignment_share_query?(metadata) do
    metadata[:repo] == Repo and metadata[:source] == "pool_upstream_assignments" and
      is_binary(metadata[:query]) and String.contains?(metadata[:query], "FOR SHARE")
  end

  defp attempt_count(request_id) do
    Repo.aggregate(
      from(attempt in Attempt, where: attempt.request_id == ^request_id),
      :count,
      :id
    )
  end

  defp ledger_kinds(request_id) do
    Repo.all(
      from entry in LedgerEntry,
        where: entry.request_id == ^request_id,
        order_by: [asc: entry.entry_kind],
        select: entry.entry_kind
    )
  end

  defp record_lock_evidence(id, caller, relation, primary_key, query) do
    if path = System.get_env("TASK3_LOCK_EVIDENCE_PATH") do
      append_evidence(path, %{
        id: id,
        caller: caller,
        relation: relation,
        lock_mode: "FOR UPDATE",
        primary_key_field: "id",
        primary_key_sha256: sha256(primary_key),
        query_sha256: sha256(query)
      })
    end
  end

  defp record_accounting_path(id, caller, result) do
    if path = System.get_env("TASK3_REFERENCE_EVIDENCE_PATH") do
      append_evidence(path, %{id: id, caller: caller, result: result})
    end
  end

  defp record_reference_sequence(sequence, id, caller, insert_kind) do
    if path = System.get_env("TASK3_REFERENCE_EVIDENCE_PATH") do
      append_evidence(path, %{
        id: id,
        caller: caller,
        result: "canonical_lock_order",
        lock_order: ["upstream_identities:FOR KEY SHARE", "pool_upstream_assignments:FOR SHARE"],
        dependent_insert: insert_kind,
        identity_parameter_sha256: parameter_sha256(sequence.identity.params),
        assignment_parameter_sha256: parameter_sha256(sequence.assignment.params),
        insert_parameters_sha256: parameter_sha256(sequence.insert.params),
        identity_query_sha256: sha256(sequence.identity.query),
        assignment_query_sha256: sha256(sequence.assignment.query),
        insert_query_sha256: sha256(sequence.insert.query)
      })
    end

    sequence
  end

  defp record_membership_evidence(blocker_pid, waiter_pid, observation, attempt) do
    if path = System.get_env("TASK3_MANUAL_QA_EVIDENCE_PATH") do
      append_evidence(path, %{
        id: "A01-membership-update",
        result: "blocked_until_attempt_commit",
        relation: "pool_upstream_assignments",
        protected_field: "upstream_identity_id",
        accounting_lock: "FOR SHARE",
        blocker_pid_sha256: sha256(blocker_pid),
        waiter_pid_sha256: sha256(waiter_pid),
        blocking_pid_count: length(observation.blocking_pids),
        wait_event_type: observation.wait_event_type,
        attempt_id_sha256: sha256(attempt.id)
      })
    end
  end

  defp committed_membership_fixture! do
    run_unboxed(fn ->
      unique = System.unique_integer([:positive])
      setup = accounting_setup(%{account_label: "Membership lock #{unique}"})
      reserved = reserve!(setup, "membership-lock-#{unique}")

      alternate_identity =
        upstream_identity_fixture(%{
          account_label: "Alternate membership #{unique}",
          chatgpt_account_id: "acct_membership_#{unique}"
        })

      Map.merge(setup, %{request: reserved.request, alternate_identity: alternate_identity})
    end)
  end

  defp cleanup_committed_membership_fixture!(fixture) do
    result =
      run_unboxed(fn ->
        {pool_count, _} =
          Repo.delete_all(from pool in Pool, where: pool.id == ^fixture.pool.id)

        identity_ids = [fixture.identity.id, fixture.alternate_identity.id]

        {identity_count, _} =
          Repo.delete_all(from identity in UpstreamIdentity, where: identity.id in ^identity_ids)

        {pricing_count, _} =
          Repo.delete_all(
            from pricing in PricingSnapshot,
              where: pricing.id == ^fixture.pricing.id
          )

        %{pools: pool_count, identities: identity_count, pricing_snapshots: pricing_count}
      end)

    if path = System.get_env("TASK3_CLEANUP_EVIDENCE_PATH") do
      append_evidence(path, %{
        id: "A01-membership-update-cleanup",
        result: "exact_fixture_cleanup",
        deleted: result,
        pool_id_sha256: sha256(fixture.pool.id),
        identity_id_sha256:
          Enum.map([fixture.identity.id, fixture.alternate_identity.id], &sha256/1),
        pricing_snapshot_id_sha256: sha256(fixture.pricing.id)
      })
    end

    result
  end

  defp run_unboxed(fun) do
    Task.async(fn -> Sandbox.unboxed_run(Repo, fun) end)
    |> Task.await(15_000)
  end

  defp backend_pid! do
    %{rows: [[pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    pid
  end

  defp observe_blocked_membership_update!(waiter_pid, blocker_pid) do
    run_unboxed(fn ->
      deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
      do_observe_blocked_membership_update!(waiter_pid, blocker_pid, deadline)
    end)
  end

  defp do_observe_blocked_membership_update!(waiter_pid, blocker_pid, deadline) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT pg_blocking_pids($1), wait_event_type, state FROM pg_stat_activity WHERE pid = $1",
        [waiter_pid]
      )

    case rows do
      [[blocking_pids, wait_event_type, state]] ->
        if blocker_pid in blocking_pids and wait_event_type == "Lock" do
          %{blocking_pids: blocking_pids, state: state, wait_event_type: wait_event_type}
        else
          retry_blocking_observation!(waiter_pid, blocker_pid, deadline)
        end

      _ ->
        retry_blocking_observation!(waiter_pid, blocker_pid, deadline)
    end
  end

  defp retry_blocking_observation!(waiter_pid, blocker_pid, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("membership update never reported the accounting backend as its PostgreSQL blocker")
    else
      do_observe_blocked_membership_update!(waiter_pid, blocker_pid, deadline)
    end
  end

  defp append_evidence(path, record) do
    File.write!(path, Jason.encode!(record) <> "\n", [:append])
  end

  defp parameter_sha256(params), do: params |> :erlang.term_to_binary() |> sha256()

  defp sha256(value), do: :crypto.hash(:sha256, to_string(value)) |> Base.encode16(case: :lower)
end
