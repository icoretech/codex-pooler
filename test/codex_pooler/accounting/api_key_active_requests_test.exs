defmodule CodexPooler.Accounting.APIKeyActiveRequestsTest do
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  import Ecto.Query
  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounting.RequestLifecycle.LedgerEntries
  alias CodexPooler.Accounting.RequestLifecycle.Reservation
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @detection_budget 15_000

  setup do
    deadlocks_before = unboxed(&deadlock_count/0)
    # Register ownership before any committed fixture exists. Fixture creation is
    # atomic; supervised actors stop before this callback removes committed rows.
    {:ok, ownership} = Agent.start(fn -> [] end)

    on_exit(fn ->
      fixtures = Agent.get(ownership, & &1)

      unboxed(fn ->
        Enum.each(fixtures, fn fixture ->
          CodexPooler.PoolerFixtures.delete_committed_pools!([fixture.pool.id])

          Repo.delete_all(
            from i in CodexPooler.Upstreams.Schemas.UpstreamIdentity,
              where: i.id == ^fixture.identity.id
          )

          Repo.delete_all(
            from p in CodexPooler.Catalog.PricingSnapshot,
              where: p.id == ^fixture.pricing.id
          )

          refute Repo.get(CodexPooler.Pools.Pool, fixture.pool.id)
          refute Repo.get(CodexPooler.Upstreams.Schemas.UpstreamIdentity, fixture.identity.id)
          refute Repo.get(CodexPooler.Catalog.PricingSnapshot, fixture.pricing.id)
        end)

        assert deadlock_count() == deadlocks_before

        CodexPooler.TestDiagnostics.puts(
          inspect(%{
            scenario: :active_cap_cleanup,
            fixtures_removed: length(fixtures),
            deadlock_delta: 0,
            remaining_owned_resources: 0
          })
        )
      end)

      Agent.stop(ownership)
    end)

    supervisor = start_supervised!(Task.Supervisor)
    %{ownership: ownership, supervisor: supervisor}
  end

  test "cap one serializes committed admissions while readers and another key progress",
       context do
    fixture = fixture(context, 1)
    other = fixture(context, 1)
    parent = self()
    release = make_ref()

    first =
      actor(context, fn ->
        [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
        send(parent, {:holder_backend, pid})

        Process.put(
          {Reservation, :runtime_authorization_barrier},
          {parent, release, {:reserve, :after}}
        )

        reserve_and_attempt(fixture)
      end)

    assert_receive {:runtime_authorization_barrier, ^release, :reserve, :after, holder},
                   @detection_budget

    # The barrier is inside the transaction, after the advisory and reader locks.
    assert_receive {:holder_backend, holder_backend}, @detection_budget

    second =
      actor(context, fn ->
        [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
        send(parent, {:waiter_backend, pid})
        reserve_and_attempt(fixture)
      end)

    assert_receive {:waiter_backend, waiter_backend}, @detection_budget
    refute waiter_backend == holder_backend
    snapshot = unboxed(fn -> await_blocker(waiter_backend, holder_backend) end)
    assert snapshot == [[holder_backend, "advisory", false]]

    unboxed(fn ->
      assert {:ok, {:ok, _auth}} =
               Repo.transaction(fn ->
                 CodexPooler.Access.authorize_api_key_runtime_turn_for_read(
                   fixture.api_key,
                   fixture.api_key.runtime_revocation_epoch
                 )
               end)

      assert {:ok, _reserved} = reserve_and_attempt(other)
    end)

    send(holder, {:runtime_authorization_release, release})
    assert {:ok, winner} = Task.await(first, @detection_budget)

    assert {:error, %{code: :api_key_concurrency_limit_exceeded}} =
             Task.await(second, @detection_budget)

    unboxed(fn ->
      assert counts(fixture) == %{requests: 1, reservations: 1, attempts: 1}

      assert {:ok, _} =
               Accounting.finalize_failure(winner.request, winner.attempt, %{
                 last_error_code: "stream_interrupted",
                 usage: %{status: "usage_unknown"}
               })

      assert {:ok, _} = reserve_and_attempt(fixture)
      assert counts(fixture) == %{requests: 2, reservations: 2, attempts: 2}
    end)

    CodexPooler.TestDiagnostics.puts(
      inspect(%{
        scenario: :committed_cap_race,
        holder_backend: holder_backend,
        waiter_backend: waiter_backend,
        blocked_locks: snapshot,
        admitted: 1,
        denied: 1,
        independent_key: :passed,
        release_then_admit: :passed
      })
    )
  end

  test "nil cap skips the count and enabling it adds exactly one statement", context do
    fixture = fixture(context, nil)

    unboxed(fn ->
      {nil_result, nil_queries} = capture_queries(fn -> reserve(fixture) end)
      assert {:ok, _} = nil_result
      assert {:ok, _} = reserve(fixture)
      set_cap(fixture, 3)
      {enabled_result, enabled_queries} = capture_queries(fn -> reserve(fixture) end)
      assert {:ok, _} = enabled_result
      assert length(enabled_queries) == length(nil_queries) + 1
      refute Enum.any?(nil_queries, &active_count_query?/1)
      assert Enum.count(enabled_queries, &active_count_query?/1) == 1

      CodexPooler.TestDiagnostics.puts(
        inspect(%{
          scenario: :cap_query_cost,
          nil_count: length(nil_queries),
          enabled_count: length(enabled_queries),
          nil_active_counts: 0,
          enabled_active_counts: 1
        })
      )
    end)
  end

  test "window enforcement sees a later admission committed before an earlier caller obtains the mutex",
       context do
    fixture = fixture(context, nil)
    parent = self()
    release = make_ref()
    earlier = DateTime.add(DateTime.utc_now(), -10, :second)
    later = DateTime.add(earlier, 1, :second)

    unboxed(fn ->
      Repo.update_all(from(b in APIKeyPolicyBinding, where: b.api_key_id == ^fixture.api_key.id),
        set: [status: "active", max_requests_per_minute: 1]
      )
    end)

    first =
      actor(context, fn ->
        [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
        send(parent, {:holder_backend, backend})

        Process.put(
          {Reservation, :runtime_authorization_barrier},
          {parent, release, {:reserve, :after}}
        )

        reserve_at(fixture, later)
      end)

    assert_receive {:runtime_authorization_barrier, ^release, :reserve, :after, holder},
                   @detection_budget

    assert_receive {:holder_backend, holder_backend}, @detection_budget

    second =
      actor(context, fn ->
        [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
        send(parent, {:waiter_backend, backend})
        reserve_at(fixture, earlier)
      end)

    assert_receive {:waiter_backend, waiter_backend}, @detection_budget
    refute holder_backend == waiter_backend
    snapshot = unboxed(fn -> await_blocker(waiter_backend, holder_backend) end)
    assert snapshot == [[holder_backend, "advisory", false]]
    first_monitor = Process.monitor(first.pid)
    second_monitor = Process.monitor(second.pid)
    send(holder, {:runtime_authorization_release, release})
    assert {:ok, winner} = Task.await(first, @detection_budget)

    assert {:error, %{code: :api_key_policy_limit_exceeded}} =
             Task.await(second, @detection_budget)

    assert_receive {:DOWN, ^first_monitor, :process, _, _}, @detection_budget
    assert_receive {:DOWN, ^second_monitor, :process, _, _}, @detection_budget

    unboxed(fn ->
      assert Repo.get!(LedgerEntry, winner.reservation.id).occurred_at == later
      assert counts(fixture) == %{requests: 1, reservations: 1, attempts: 0}

      Repo.update_all(from(b in APIKeyPolicyBinding, where: b.api_key_id == ^fixture.api_key.id),
        set: [max_requests_per_minute: 2]
      )

      assert {:ok, delayed} = reserve_at(fixture, earlier)
      assert Repo.get!(LedgerEntry, delayed.reservation.id).occurred_at == earlier
    end)

    CodexPooler.TestDiagnostics.puts(
      inspect(%{
        scenario: :serialized_enforcement_clock,
        holder_backend: holder_backend,
        waiter_backend: waiter_backend,
        blocked_locks: snapshot,
        earlier_admission_denied: true,
        admission_timestamps_preserved: true
      })
    )
  end

  test "cap applies with disabled bindings across routes and models and uses fresh key",
       context do
    fixture = fixture(context, 1)

    unboxed(fn ->
      assert {:ok, first} = reserve(fixture)

      model =
        CodexPooler.PoolerFixtures.model_fixture(
          fixture.pool,
          %{exposed_model_id: "sample-other-model"}
        )

      assert {:error, %{code: :api_key_concurrency_limit_exceeded}} =
               Accounting.reserve(fixture.auth, model, %{"model" => model.exposed_model_id}, %{
                 endpoint: "/backend-api/codex/responses/compact",
                 correlation_id: Ecto.UUID.generate()
               })

      assert counts(fixture) == %{requests: 1, reservations: 1, attempts: 0}

      assert {:ok, _} =
               Accounting.finalize_reservation_failure(
                 first.request,
                 %{last_error_code: "dispatch_unavailable"}
               )

      assert {:ok, _} = reserve(fixture)
    end)
  end

  test "lowering drains without cancelling and rollback creates no occupied slot", context do
    fixture = fixture(context, nil)

    unboxed(fn ->
      assert {:ok, first} = reserve(fixture)
      assert {:ok, second} = reserve(fixture)
      set_cap(fixture, 1)
      assert {:error, %{code: :api_key_concurrency_limit_exceeded}} = reserve(fixture)

      assert {:ok, _} =
               Accounting.finalize_reservation_failure(
                 first.request,
                 %{last_error_code: "dispatch_unavailable"}
               )

      assert {:error, %{code: :api_key_concurrency_limit_exceeded}} = reserve(fixture)

      assert {:ok, _} =
               Accounting.finalize_reservation_failure(
                 second.request,
                 %{last_error_code: "dispatch_unavailable"}
               )

      assert {:error, :cancelled} =
               Repo.transaction(fn ->
                 assert {:ok, _} = reserve(fixture)
                 Repo.rollback(:cancelled)
               end)

      assert {:ok, _} = reserve(fixture)
      assert counts(fixture) == %{requests: 3, reservations: 3, attempts: 0}
    end)
  end

  test "uncommitted terminal retains the slot and late correction cannot free a newer slot",
       context do
    fixture = fixture(context, 1)
    {:ok, first} = unboxed(fn -> reserve_and_attempt(fixture) end)
    parent = self()
    release = make_ref()

    terminal =
      actor(context, fn ->
        Repo.transaction(fn ->
          assert {:ok, _} =
                   Accounting.finalize_failure(first.request, first.attempt, %{
                     last_error_code: "stream_interrupted",
                     usage: %{status: "usage_unknown"}
                   })

          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:terminal_written, self(), backend})

          receive do
            {:commit_terminal, ^release} -> :ok
          after
            @detection_budget -> flunk("terminal commit was not released")
          end
        end)
      end)

    assert_receive {:terminal_written, holder, terminal_backend}, @detection_budget

    unboxed(fn ->
      [[admission_backend]] = Repo.query!("SELECT pg_backend_pid()").rows
      refute admission_backend == terminal_backend
      assert {:error, %{code: :api_key_concurrency_limit_exceeded}} = reserve(fixture)
    end)

    send(holder, {:commit_terminal, release})
    assert {:ok, :ok} = Task.await(terminal, @detection_budget)

    unboxed(fn ->
      assert {:ok, _newer} = reserve(fixture)

      %{minute: usage} =
        LedgerEntries.window_usages(fixture.api_key.id,
          minute: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      assert usage.known_total_tokens == 0
      assert usage.provisional_total_tokens == first.estimate.total_tokens
      assert usage.pending_total_tokens == first.estimate.total_tokens

      assert {:ok, _} =
               Accounting.finalize_failure(first.request, first.attempt, %{
                 last_error_code: "stream_interrupted",
                 usage: %{status: "usage_unknown"}
               })
    end)

    correction =
      actor(context, fn ->
        Repo.transaction(fn ->
          assert {:ok, _} =
                   Accounting.finalize_success(first.request, first.attempt, %{
                     status: "usage_known",
                     input_tokens: 4,
                     output_tokens: 4,
                     total_tokens: 8
                   })

          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:correction_written, self(), backend})

          receive do
            {:commit_correction, ^release} -> :ok
          after
            @detection_budget -> flunk("correction commit was not released")
          end
        end)
      end)

    assert_receive {:correction_written, corrector, correction_backend}, @detection_budget

    unboxed(fn ->
      [[admission_backend]] = Repo.query!("SELECT pg_backend_pid()").rows
      refute admission_backend == correction_backend
      assert {:error, %{code: :api_key_concurrency_limit_exceeded}} = reserve(fixture)
    end)

    send(corrector, {:commit_correction, release})
    assert {:ok, :ok} = Task.await(correction, @detection_budget)

    unboxed(fn ->
      assert {:error, %{code: :api_key_concurrency_limit_exceeded}} = reserve(fixture)
      assert Accounting.LedgerReads.outstanding_reservation_count(fixture.api_key.id) == 1
    end)
  end

  test "model overrides and an absent binding share the same active cap", context do
    fixture = fixture(context, 1)

    unboxed(fn ->
      Repo.insert!(%APIKeyPolicyBinding{
        api_key_id: fixture.api_key.id,
        binding_scope: "model",
        model_identifier: fixture.model.exposed_model_id,
        status: "active",
        max_tokens_per_day: 100_000
      })

      assert {:ok, _} = reserve(fixture)
      assert {:error, %{code: :api_key_concurrency_limit_exceeded}} = reserve(fixture)
      Repo.delete_all(from b in APIKeyPolicyBinding, where: b.api_key_id == ^fixture.api_key.id)
      assert {:error, %{code: :api_key_concurrency_limit_exceeded}} = reserve(fixture)
    end)
  end

  test "sixteen admissions retain the exact query budget with and without an active cap",
       context do
    for cap <- [nil, 32] do
      fixture = fixture(context, cap)

      unboxed(fn ->
        # A committed release ends the warmup slot. One pass preserves the
        # query-count contract; repeated latency samples belong in benchmarks.
        {:ok, warmup} = reserve(fixture)

        {:ok, _} =
          Accounting.finalize_reservation_failure(
            warmup.request,
            %{last_error_code: "dispatch_unavailable"}
          )

        {_results, queries} =
          capture_queries(fn ->
            for _ <- 1..16, do: assert({:ok, _} = reserve(fixture))
          end)

        assert length(queries) == 16 * if(is_nil(cap), do: 10, else: 11)
        assert Enum.count(queries, &active_count_query?/1) == if(is_nil(cap), do: 0, else: 16)
        assert Accounting.LedgerReads.outstanding_reservation_count(fixture.api_key.id) == 16
      end)
    end
  end

  test "active count excludes retained terminals regardless of amount status", context do
    fixture = fixture(context, 2)
    unrelated = fixture(context, nil)

    unboxed(fn ->
      seed_retained_history(unrelated, 2_048)
      # One real reservation and release, then 128 copies of their persisted rows:
      # the count reads rows, so copies retain the shape without 128 round trips.
      seed_retained_history(fixture, 128)

      # A voided terminal still ends execution; correction replaces debit, not capacity.
      Repo.update_all(
        from(e in LedgerEntry,
          where: e.api_key_id == ^fixture.api_key.id and e.entry_kind == "release"
        ),
        set: [amount_status: "voided"]
      )

      assert {:ok, _} = reserve(fixture)

      {count, queries} =
        capture_queries(fn ->
          Accounting.LedgerReads.outstanding_reservation_count(fixture.api_key.id)
        end)

      assert count == 1
      assert [query] = queries

      # The plan is a receipt, not an assertion, so it is only collected when printed.
      CodexPooler.TestDiagnostics.puts(fn ->
        Repo.query!("ANALYZE ledger_entries")
        plan = Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> query.query, query.params)

        Jason.encode!(%{
          scenario: :active_count_explain,
          retained_terminals: 129,
          unrelated_terminals: 2_049,
          active: count,
          plan: plan.rows
        })
      end)
    end)
  end

  defp seed_retained_history(fixture, count) do
    {:ok, reserved} = reserve(fixture)

    {:ok, _} =
      Accounting.finalize_reservation_failure(
        reserved.request,
        %{last_error_code: "dispatch_unavailable"}
      )

    request = Repo.get!(Request, reserved.request.id)

    release =
      Repo.one!(
        from e in LedgerEntry,
          where: e.request_id == ^request.id and e.entry_kind == "release"
      )

    request_attrs = request |> Map.from_struct() |> Map.take(Request.__schema__(:fields))

    reservation_attrs =
      reserved.reservation |> Map.from_struct() |> Map.take(LedgerEntry.__schema__(:fields))

    release_attrs = release |> Map.from_struct() |> Map.take(LedgerEntry.__schema__(:fields))
    ids = for _ <- 1..count, do: Ecto.UUID.generate()

    ledger_batches =
      Enum.map([reservation_attrs, release_attrs], fn template ->
        Enum.map(ids, fn id ->
          %{
            template
            | id: Ecto.UUID.generate(),
              request_id: id,
              source_event_id: Ecto.UUID.generate()
          }
        end)
      end)

    {:ok, :ok} =
      Repo.transaction(fn ->
        Repo.insert_all(
          Request,
          Enum.map(ids, fn id ->
            %{request_attrs | id: id, correlation_id: Ecto.UUID.generate()}
          end)
        )

        Enum.each(ledger_batches, &Repo.insert_all(LedgerEntry, &1))

        :ok
      end)
  end

  defp fixture(context, cap) do
    unboxed(fn ->
      {:ok, fixture} =
        Repo.transaction(fn ->
          fixture = accounting_setup()
          # Authentication deliberately remains stale: admission must reread the key.
          set_cap(fixture, cap)

          Repo.update_all(
            from(b in APIKeyPolicyBinding,
              where: b.api_key_id == ^fixture.api_key.id
            ),
            set: [status: "disabled"]
          )

          Agent.update(context.ownership, &[fixture | &1])
          fixture
        end)

      fixture
    end)
  end

  defp set_cap(fixture, cap) do
    fixture.api_key |> Ecto.Changeset.change(max_active_requests: cap) |> Repo.update!()
  end

  defp reserve(fixture),
    do:
      Accounting.reserve(
        fixture.auth,
        fixture.model,
        %{"model" => fixture.model.exposed_model_id},
        %{correlation_id: Ecto.UUID.generate()}
      )

  defp reserve_at(fixture, timestamp),
    do:
      Accounting.reserve(
        fixture.auth,
        fixture.model,
        %{"model" => fixture.model.exposed_model_id},
        %{correlation_id: Ecto.UUID.generate(), now: timestamp}
      )

  defp reserve_and_attempt(fixture) do
    with {:ok, reserved} <- reserve(fixture),
         {:ok, attempt} <- Accounting.create_attempt(reserved.request, fixture.assignment) do
      {:ok, Map.put(reserved, :attempt, attempt)}
    end
  end

  defp counts(fixture) do
    %{
      requests: Repo.aggregate(from(r in Request, where: r.api_key_id == ^fixture.api_key.id), :count),
      reservations:
        Repo.aggregate(
          from(e in LedgerEntry,
            where: e.api_key_id == ^fixture.api_key.id and e.entry_kind == "reservation"
          ),
          :count
        ),
      attempts:
        Repo.aggregate(
          from(a in Attempt,
            join: r in Request,
            on: r.id == a.request_id,
            where: r.api_key_id == ^fixture.api_key.id
          ),
          :count
        )
    }
  end

  defp actor(context, fun),
    do:
      Task.Supervisor.async_nolink(
        context.supervisor,
        fn -> unboxed(fun) end
      )

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp deadlock_count do
    [[count]] =
      Repo.query!("SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()").rows

    count
  end

  defp await_blocker(waiter, holder),
    do: await_blocker(waiter, holder, System.monotonic_time(:millisecond) + @detection_budget)

  defp await_blocker(waiter, holder, deadline) do
    rows =
      Repo.query!(
        """
        SELECT blocker, locks.locktype, locks.granted
        FROM unnest(pg_blocking_pids($1)) AS blocker
        JOIN pg_locks AS locks ON locks.pid = $1 AND NOT locks.granted
        WHERE blocker = $2
        """,
        [waiter, holder]
      ).rows

    cond do
      rows != [] -> rows
      System.monotonic_time(:millisecond) < deadline -> await_blocker(waiter, holder, deadline)
      true -> flunk("expected advisory blocker was not observed")
    end
  end

  defp capture_queries(fun) do
    ref = make_ref()
    owner = self()
    on_exit(fn -> :telemetry.detach(ref) end)

    :ok =
      :telemetry.attach(
        ref,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == owner,
            do: send(owner, {:captured_query, ref, Map.take(metadata, [:query, :params])})
        end,
        nil
      )

    try do
      result = fun.()
      :telemetry.detach(ref)
      {result, drain_queries(ref, [])}
    after
      :telemetry.detach(ref)
    end
  end

  defp drain_queries(ref, acc) do
    receive do
      {:captured_query, ^ref, query} -> drain_queries(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # `LedgerReads.outstanding_reservation_count/1`: the key's live requests with
  # one aggregate probe of each request's ledger entries.
  defp active_count_query?(query), do: String.starts_with?(query.query, "SELECT count(*) FROM \"requests\"") and String.contains?(query.query, "HAVING")
end
