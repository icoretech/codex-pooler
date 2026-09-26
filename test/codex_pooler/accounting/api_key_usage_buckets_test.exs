defmodule CodexPooler.Accounting.APIKeyUsageBucketsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounting.RequestLifecycle.LedgerEntries
  alias CodexPooler.Repo

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures

  @lock_detection_timeout_ms 15_000

  describe "API-key usage bucket projection" do
    test "projects every effective ledger delta and reverses recorded rows on update and delete" do
      setup = accounting_setup()
      bucket = ~U[2026-08-02 00:00:00.000000Z]

      reservation =
        insert_entry!(setup, bucket, %{
          entry_kind: "reservation",
          usage_status: "usage_pending",
          request_count: 1,
          total_tokens: 100,
          estimated_cost_micros: "20"
        })

      release =
        insert_entry!(setup, DateTime.add(bucket, 1, :minute), %{
          entry_kind: "release",
          usage_status: "usage_known",
          request_count: 1,
          total_tokens: 100,
          estimated_cost_micros: "20"
        })

      known_settlement =
        insert_entry!(setup, DateTime.add(bucket, 2, :minute), %{
          entry_kind: "settlement",
          usage_status: "usage_known",
          request_count: 1,
          total_tokens: 7,
          estimated_cost_micros: "20",
          settled_cost_micros: "13"
        })

      insert_entry!(setup, DateTime.add(bucket, 3, :minute), %{
        entry_kind: "settlement",
        usage_status: "usage_unknown",
        request_count: 1,
        total_tokens: 90,
        estimated_cost_micros: "18",
        settled_cost_micros: "17"
      })

      insert_entry!(setup, DateTime.add(bucket, 4, :minute), %{
        entry_kind: "adjustment",
        usage_status: "usage_known",
        request_count: 2,
        total_tokens: 5,
        estimated_cost_micros: "3"
      })

      assert_bucket!(setup.api_key.id, bucket, 1, 100, "20")
      assert_bucket!(setup.api_key.id, DateTime.add(bucket, 1, :minute), -1, -100, "-20")
      assert_bucket!(setup.api_key.id, DateTime.add(bucket, 2, :minute), 1, 7, "13")
      assert_bucket!(setup.api_key.id, DateTime.add(bucket, 3, :minute), 1, 0, "0")
      assert_bucket!(setup.api_key.id, DateTime.add(bucket, 4, :minute), 2, 5, "3")

      voided_settlement =
        known_settlement
        |> Ecto.Changeset.change(amount_status: "voided")
        |> Repo.update!()

      assert_bucket!(setup.api_key.id, DateTime.add(bucket, 2, :minute), 0, 0, "0")

      recorded_settlement =
        voided_settlement
        |> Ecto.Changeset.change(amount_status: "recorded")
        |> Repo.update!()

      assert_bucket!(setup.api_key.id, DateTime.add(bucket, 2, :minute), 1, 7, "13")

      Repo.delete!(recorded_settlement)

      assert_bucket!(setup.api_key.id, DateTime.add(bucket, 2, :minute), 0, 0, "0")
      assert Repo.reload!(reservation).amount_status == "recorded"
      assert Repo.reload!(release).amount_status == "recorded"
    end

    test "updates move the exact delta between minute buckets" do
      setup = accounting_setup()
      original_bucket = ~U[2026-08-02 00:00:00.000000Z]
      moved_bucket = DateTime.add(original_bucket, 1, :minute)

      entry =
        insert_entry!(setup, original_bucket, %{
          entry_kind: "adjustment",
          usage_status: "usage_known",
          request_count: 2,
          total_tokens: 5,
          estimated_cost_micros: "3"
        })

      assert_bucket!(setup.api_key.id, original_bucket, 2, 5, "3")

      entry
      |> Ecto.Changeset.change(%{
        entry_kind: "release",
        request_count: 1,
        total_tokens: 4,
        estimated_cost_micros: Decimal.new(2),
        occurred_at: moved_bucket
      })
      |> Repo.update!()

      assert_bucket!(setup.api_key.id, original_bucket, 0, 0, "0")
      assert_bucket!(setup.api_key.id, moved_bucket, -1, -4, "-2")
    end

    test "window reads use the exact leading partial minute and precomputed complete buckets" do
      setup = accounting_setup()
      since = ~U[2026-08-02 00:00:30.000000Z]

      for {offset_microseconds, total_tokens} <- [
            {-1, 1_000},
            {0, 10},
            {29_999_999, 20},
            {30_000_000, 30}
          ] do
        insert_entry!(
          setup,
          DateTime.add(since, offset_microseconds, :microsecond),
          %{
            entry_kind: "settlement",
            usage_status: "usage_known",
            request_count: 1,
            total_tokens: total_tokens,
            settled_cost_micros: Integer.to_string(total_tokens)
          }
        )
      end

      usage =
        setup.api_key.id
        |> LedgerEntries.window_usages(weekly: since)
        |> Map.fetch!(:weekly)

      # These imported settlements have no committed reservation/admission.
      assert usage.effective_request_count == 0
      assert usage.known_total_tokens == 60
      assert usage.provisional_total_tokens == 0
      assert usage.pending_total_tokens == 0
      assert usage.effective_total_tokens == 60
      assert Decimal.equal?(usage.effective_cost_micros, Decimal.new(60))
    end

    test "late known usage replacement removes the old settlement delta before adding the correction" do
      setup = accounting_setup()
      reservation_at = ~U[2026-08-02 00:00:10.000000Z]
      unknown_at = ~U[2026-08-02 00:00:20.000000Z]
      known_at = ~U[2026-08-02 00:01:05.000000Z]

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 1},
                 %{correlation_id: "bucket-late-known-reservation", now: reservation_at}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, failed} =
               Accounting.finalize_failure(reserved.request, attempt, %{
                 now: unknown_at,
                 last_error_code: "synthetic_unknown_usage",
                 usage: %{status: "usage_unknown", source: "test", recorded_at: unknown_at}
               })

      assert_bucket!(setup.api_key.id, minute_start(reservation_at), 1, 0, "0")

      assert {:ok, corrected} =
               Accounting.finalize_success(
                 failed.request,
                 failed.attempt,
                 %{
                   status: "usage_known",
                   source: "late_test",
                   recorded_at: known_at,
                   input_tokens: 2,
                   cached_input_tokens: 0,
                   output_tokens: 1,
                   reasoning_tokens: 0,
                   total_tokens: 3
                 },
                 %{now: known_at, response_status_code: 200}
               )

      assert corrected.settlement.correction_of_entry_id == failed.settlement.id
      assert corrected.settlement.occurred_at == unknown_at
      assert corrected.settlement.created_at == known_at

      assert_bucket!(
        setup.api_key.id,
        minute_start(unknown_at),
        1,
        3,
        Decimal.to_string(corrected.settlement.settled_cost_micros)
      )

      usage =
        LedgerEntries.window_usages(setup.api_key.id, [minute: reservation_at], known_at).minute

      assert usage.effective_request_count == 1
      assert usage.known_total_tokens == 3
      assert usage.provisional_total_tokens == 0
      assert usage.pending_total_tokens == 0

      later =
        LedgerEntries.window_usages(
          setup.api_key.id,
          [minute: DateTime.add(unknown_at, 1, :microsecond)],
          known_at
        ).minute

      assert later.effective_request_count == 0
      assert later.effective_total_tokens == 0
    end

    test "API-key cascades remove ledger entries and buckets without recreating projection rows" do
      setup = accounting_setup()
      bucket = ~U[2026-08-02 00:00:00.000000Z]

      insert_entry!(setup, bucket, %{
        entry_kind: "reservation",
        usage_status: "usage_pending",
        request_count: 1,
        total_tokens: 100,
        estimated_cost_micros: "20"
      })

      assert_bucket!(setup.api_key.id, bucket, 1, 100, "20")
      Repo.delete!(setup.api_key)

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT COUNT(*) FROM api_key_usage_buckets WHERE api_key_id = $1::text::uuid",
                 [setup.api_key.id]
               )
    end

    test "request cascades reverse recorded bucket deltas" do
      setup = accounting_setup()
      bucket = ~U[2026-08-02 00:00:00.000000Z]

      entry =
        insert_entry!(setup, bucket, %{
          entry_kind: "reservation",
          usage_status: "usage_pending",
          request_count: 1,
          total_tokens: 100,
          estimated_cost_micros: "20"
        })

      assert_bucket!(setup.api_key.id, bucket, 1, 100, "20")

      entry.request_id
      |> then(&Repo.get!(Request, &1))
      |> Repo.delete!()

      assert_bucket!(setup.api_key.id, bucket, 0, 0, "0")
    end

    test "exact upper edge excludes future known, provisional and reservation events" do
      setup = accounting_setup()
      since = ~U[2026-08-02 00:00:30.000000Z]
      as_of = ~U[2026-08-02 00:01:15.000000Z]

      for {timestamp, tokens} <- [
            {since, 10},
            {as_of, 20},
            {DateTime.add(as_of, 1, :microsecond), 1_000}
          ] do
        insert_entry!(setup, timestamp, %{
          entry_kind: "settlement",
          usage_status: "usage_known",
          total_tokens: tokens
        })
      end

      insert_entry!(setup, DateTime.add(as_of, 1, :minute), %{
        entry_kind: "reservation",
        usage_status: "usage_pending",
        total_tokens: 2_000
      })

      future = DateTime.add(as_of, 1, :second)

      {:ok, reserved} =
        Accounting.reserve(setup.auth, setup.model, %{"model" => setup.model.exposed_model_id}, %{
          now: future
        })

      {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      {:ok, _} =
        Accounting.finalize_failure(reserved.request, attempt, %{
          now: future,
          usage: %{status: "usage_unknown", recorded_at: future}
        })

      assert %{
               known_total_tokens: 30,
               provisional_total_tokens: 0,
               pending_total_tokens: 0,
               effective_total_tokens: 30,
               effective_request_count: 0
             } =
               LedgerEntries.window_usages(setup.api_key.id, [window: since], as_of).window
    end

    test "rebuild is idempotent and matches insert, void, update and delete arithmetic" do
      setup = accounting_setup()
      timestamp = ~U[2026-08-02 00:00:30.000000Z]

      {:ok, reserved} =
        Accounting.reserve(setup.auth, setup.model, %{"model" => setup.model.exposed_model_id}, %{
          now: timestamp
        })

      {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      {:ok, failed} =
        Accounting.finalize_failure(reserved.request, attempt, %{
          now: DateTime.add(timestamp, 90, :second),
          usage: %{status: "usage_unknown", recorded_at: DateTime.add(timestamp, 90, :second)}
        })

      assert_rebuild_unchanged!(setup.api_key.id)
      failed.settlement |> Ecto.Changeset.change(amount_status: "voided") |> Repo.update!()
      assert_rebuild_unchanged!(setup.api_key.id)
      Repo.delete!(failed.release)
      assert_rebuild_unchanged!(setup.api_key.id)
      Repo.delete!(Repo.reload!(failed.settlement))
      assert_rebuild_unchanged!(setup.api_key.id)
    end

    test "rebuild arithmetic waits for an existing bucket reader before entering its maintenance window" do
      setup = accounting_setup()
      insert_entry!(setup, ~U[2026-08-02 00:00:00.000000Z], %{entry_kind: "settlement", usage_status: "usage_known", total_tokens: 7, settled_cost_micros: "13"})
      [[rebuild_backend]] = Repo.query!("SELECT pg_backend_pid()").rows
      [[previous_lock_timeout]] = Repo.query!("SHOW lock_timeout").rows
      {reader, reader_backend} = start_bucket_reader!()
      refute reader_backend == rebuild_backend
      supervisor = start_supervised!(Task.Supervisor)

      task = Task.Supervisor.async_nolink(supervisor, fn -> assert_rebuild_unchanged!(setup.api_key.id) end)
      task_pid = task.pid
      monitor = Process.monitor(task_pid)

      await_bucket_lock_wait!(reader, task_pid, rebuild_backend, reader_backend, System.monotonic_time(:millisecond) + @lock_detection_timeout_ms)
      Postgrex.query!(reader, "ROLLBACK", [])

      Task.await(task, @lock_detection_timeout_ms)
      assert_receive {:DOWN, ^monitor, :process, ^task_pid, :normal}, @lock_detection_timeout_ms
      assert Repo.query!("SHOW lock_timeout").rows == [[previous_lock_timeout]]
    end

    test "direct rebuild refuses a busy projection without changing buckets or retaining partial locks" do
      setup = accounting_setup()
      insert_entry!(setup, ~U[2026-08-02 00:00:00.000000Z], %{entry_kind: "settlement", usage_status: "usage_known", total_tokens: 7, settled_cost_micros: "13"})
      before = bucket_rows(setup.api_key.id)
      {reader, _reader_backend} = start_bucket_reader!()

      try do
        assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
                 Repo.query("SELECT public.rebuild_api_key_usage_components()", [], mode: :savepoint)

        assert bucket_rows(setup.api_key.id) == before

        assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM pg_locks WHERE pid = pg_backend_pid() AND relation = 'public.ledger_entries'::regclass AND mode = 'ShareRowExclusiveLock'")
      after
        Postgrex.query!(reader, "ROLLBACK", [])
      end
    end
  end

  defp assert_rebuild_unchanged!(api_key_id) do
    # The production rebuild deliberately uses NOWAIT. Establish its idle
    # maintenance window before checking arithmetic, rather than racing a
    # reader or autovacuum on the test database. These locks live only in the
    # sandbox transaction; a reader that never drains still fails the test.
    [[previous_lock_timeout]] = Repo.query!("SHOW lock_timeout").rows
    Repo.query!("SELECT set_config('lock_timeout', $1, true)", ["#{@lock_detection_timeout_ms}ms"])
    Repo.query!("LOCK TABLE public.ledger_entries IN SHARE ROW EXCLUSIVE MODE")
    Repo.query!("LOCK TABLE public.api_key_usage_buckets IN ACCESS EXCLUSIVE MODE")
    Repo.query!("SELECT set_config('lock_timeout', $1, true)", [previous_lock_timeout])

    before = bucket_rows(api_key_id)

    for _ <- 1..2 do
      Repo.query!("SELECT public.rebuild_api_key_usage_components()")
      assert bucket_rows(api_key_id) == before
    end
  end

  defp bucket_rows(api_key_id) do
    Repo.query!(
      "SELECT bucket_started_at, effective_request_count, effective_total_tokens, effective_cost_micros, known_total_tokens, provisional_total_tokens, admission_count, known_cost_micros FROM api_key_usage_buckets WHERE api_key_id = $1::text::uuid ORDER BY bucket_started_at",
      [api_key_id]
    ).rows
  end

  defp start_bucket_reader! do
    options = Repo.config() |> Keyword.take([:hostname, :port, :username, :password, :database, :socket_dir])
    reader = start_supervised!({Postgrex, options})
    Postgrex.query!(reader, "BEGIN", [])
    Postgrex.query!(reader, "SELECT 1 FROM public.api_key_usage_buckets LIMIT 0", [])
    [[backend]] = Postgrex.query!(reader, "SELECT pg_backend_pid()", []).rows
    {reader, backend}
  end

  defp await_bucket_lock_wait!(reader, task_pid, rebuild_backend, reader_backend, deadline) do
    %{rows: [[waiting?]]} =
      Postgrex.query!(reader, "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid = $1 AND relation = 'public.api_key_usage_buckets'::regclass AND mode = 'AccessExclusiveLock' AND NOT granted AND $2 = ANY(pg_blocking_pids($1)))", [rebuild_backend, reader_backend])

    cond do
      waiting? ->
        :ok

      not Process.alive?(task_pid) ->
        flunk("rebuild finished before the bucket reader released its lock")

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("rebuild did not wait on the bucket reader")

      true ->
        receive do
        after
          10 -> await_bucket_lock_wait!(reader, task_pid, rebuild_backend, reader_backend, deadline)
        end
    end
  end

  defp insert_entry!(setup, occurred_at, attrs) do
    request =
      request_fixture(setup.auth, %{
        model_id: setup.model.id,
        correlation_id: "bucket-#{System.unique_integer([:positive])}"
      })

    %LedgerEntry{
      request_id: request.id,
      pricing_snapshot_id: setup.pricing.id,
      pool_id: request.pool_id,
      api_key_id: request.api_key_id,
      model_id: request.model_id,
      entry_kind: Map.fetch!(attrs, :entry_kind),
      amount_status: Map.get(attrs, :amount_status, "recorded"),
      usage_status: Map.fetch!(attrs, :usage_status),
      transport: request.transport,
      currency_code: "USD",
      total_tokens: Map.get(attrs, :total_tokens),
      request_count: Map.get(attrs, :request_count, 1),
      estimated_cost_micros: Decimal.new(Map.get(attrs, :estimated_cost_micros, "0")),
      settled_cost_micros: Decimal.new(Map.get(attrs, :settled_cost_micros, "0")),
      source_event_id: "bucket-entry-#{Ecto.UUID.generate()}",
      occurred_at: occurred_at,
      created_at: occurred_at,
      details: %{}
    }
    |> Repo.insert!()
  end

  defp assert_bucket!(api_key_id, bucket_started_at, requests, tokens, cost) do
    assert %{rows: [[^requests, ^tokens, persisted_cost]]} =
             Repo.query!(
               """
               SELECT effective_request_count, effective_total_tokens, effective_cost_micros
               FROM api_key_usage_buckets
               WHERE api_key_id = $1::text::uuid AND bucket_started_at = $2
               """,
               [api_key_id, bucket_started_at]
             )

    assert Decimal.equal?(persisted_cost, Decimal.new(cost))
  end

  defp minute_start(timestamp), do: %{timestamp | second: 0, microsecond: {0, 6}}
end
