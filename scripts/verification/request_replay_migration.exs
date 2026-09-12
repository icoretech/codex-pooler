Code.require_file("request_replay_migration_projection.exs", __DIR__)

defmodule CodexPooler.Verification.RequestReplayMigration do
  @moduledoc """
  Provider-free populated rehearsal. Run with MIX_ENV=test, MIX_TEST_PARTITION=1,
  and CODEX_POOLER_TEST_RUN_NAMESPACE set to a fresh 16-character hex namespace:

      mix run --no-start scripts/verification/request_replay_migration.exs --rows 10000

  A focused committed projection-writer lock regression is also available:

      mix run --no-start scripts/verification/request_replay_migration.exs --projection-lock

  Creates and drops only the exact namespaced test database. Refuses an
  existing database. Prints metadata-only JSON receipts, including global WAL
  deltas (which may include other databases on the same PostgreSQL server).
  Non-loopback PostgreSQL services require an explicit
  CODEX_POOLER_TEST_POSTGRES_HOST matching the test repository configuration.
  """

  alias CodexPooler.Repo
  alias CodexPooler.Verification.RequestReplayMigrationProjection
  alias Ecto.Adapters.Postgres
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator

  @version 20_260_902_024_410
  @migration CodexPooler.Repo.Migrations.AddRequestReplayEntitlements
  @budget 60_000
  # Failure-detection budget for CREATE/DROP DATABASE on a loaded PostgreSQL host. Ecto's
  # storage helpers otherwise give up with "command timed out" after their own 15 s default.
  @storage_budget 60_000
  # The drop gets bounded attempts inside that budget rather than one command that owns all of
  # it. `Ecto.Adapters.Postgres.run_query/2` abandons a command that has not answered within its
  # own timeout, so a single attempt behind a backend that is still closing spends the whole
  # budget without ever retrying.
  @drop_attempt_budget 20_000
  @drop_retry_pause_ms 500
  # The exact message `run_query/2` produces for an abandoned command.
  @drop_timeout_reason "command timed out"

  @spec run([String.t()]) :: :ok
  def run(["--help"]), do: IO.puts(@moduledoc)

  def run(["--projection-lock"]), do: run_rehearsal(&projection_rehearsal/1)

  def run(["--drop-classification"]), do: drop_classification_self_test()

  def run(["--lock-matrix"]), do: run_rehearsal(&lock_matrix/1)

  def run(["--writer-failure"]), do: run_rehearsal(&projection_rehearsal(&1, :writer_failure))

  def run(["--rows", value]) do
    case Integer.parse(value) do
      {rows, ""} when rows in 4..100_000 and rem(rows, 4) == 0 ->
        run_rehearsal(&rehearse(&1, rows))

      _ ->
        raise ArgumentError, "--rows requires a multiple of four between 4 and 100000"
    end
  end

  def run(_args),
    do:
      raise(
        ArgumentError,
        "usage: --rows 10000 | --projection-lock | --lock-matrix | --writer-failure | " <>
          "--drop-classification | --help"
      )

  defp run_rehearsal(fun) do
    config = safe_config!()
    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    :ok = Postgres.storage_up(storage_options(config))

    outcome =
      try do
        {:ok, :ok, _} = Migrator.with_repo(Repo, fun, pool_size: 8)
        :ok
      catch
        kind, reason -> {:failed, kind, reason, __STACKTRACE__}
      end

    drop = drop_owned_database(config)

    case {outcome, drop} do
      {:ok, {:dropped, _attempts}} ->
        :ok

      # An undropped database is real residue either way, so both still fail. They are named
      # apart because only the second says something is wrong with the rehearsal.
      {:ok, {:timed_out, attempts}} ->
        raise "owned rehearsal database was not dropped: #{attempts} DROP DATABASE attempt(s) " <>
                "timed out inside the #{@storage_budget}ms cleanup budget " <>
                "(#{@drop_attempt_budget}ms per attempt). Every rehearsal stage passed; this is " <>
                "a slow or busy PostgreSQL host, not a rehearsal defect."

      {:ok, {:failed, attempts, reason}} ->
        raise "owned rehearsal database was not dropped: DROP DATABASE was refused after " <>
                "#{attempts} attempt(s) (#{cleanup_reason(reason)})"

      {{:failed, kind, reason, stacktrace}, _drop} ->
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  # Cleanup is unconditional: the receipt is printed whether or not the rehearsal succeeded,
  # a drop failure is reported in the receipt instead of masking the rehearsal error, and the
  # forced drop terminates backends that are still closing after the repo stopped.
  defp drop_owned_database(config) do
    outcome =
      await_drop(
        fn timeout ->
          Postgres.storage_down(storage_options(config, force_drop: true, timeout: timeout))
        end,
        drop_budgets()
      )

    receipt("cleanup", cleanup_receipt(outcome, drop_budgets()))
    outcome
  end

  defp drop_budgets,
    do: %{
      budget_ms: @storage_budget,
      attempt_budget_ms: @drop_attempt_budget,
      pause_ms: @drop_retry_pause_ms
    }

  @doc """
  Drops with bounded attempts inside one budget and classifies the result.

  A timed-out attempt is retried while the budget lasts; a refused drop is not retried, because
  retrying a refusal only hides the rehearsal defect it reports.
  """
  @spec await_drop((timeout() -> :ok | {:error, term()}), map()) ::
          {:dropped, pos_integer()}
          | {:timed_out, pos_integer()}
          | {:failed, pos_integer(), term()}
  def await_drop(drop_fun, budgets) do
    do_await_drop(drop_fun, budgets, System.monotonic_time(:millisecond) + budgets.budget_ms, 1)
  end

  defp do_await_drop(drop_fun, budgets, deadline, attempt) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case drop_fun.(max(1, min(budgets.attempt_budget_ms, remaining))) do
      :ok ->
        {:dropped, attempt}

      # A command abandoned client-side can still have committed server-side; the next attempt
      # then finds the database already gone, which is the cleanup contract satisfied.
      {:error, :already_down} ->
        {:dropped, attempt}

      {:error, @drop_timeout_reason} ->
        if System.monotonic_time(:millisecond) + budgets.pause_ms < deadline do
          Process.sleep(budgets.pause_ms)
          do_await_drop(drop_fun, budgets, deadline, attempt + 1)
        else
          {:timed_out, attempt}
        end

      {:error, reason} ->
        {:failed, attempt, reason}
    end
  end

  defp cleanup_receipt({:dropped, attempts}, _budgets),
    do: %{
      database_dropped: true,
      drop_outcome: "dropped",
      drop_attempts: attempts,
      build_cache_retained: true
    }

  defp cleanup_receipt({:timed_out, attempts}, budgets),
    do: %{
      database_dropped: false,
      drop_outcome: "timed_out",
      drop_attempts: attempts,
      drop_budget_ms: budgets.budget_ms,
      drop_attempt_budget_ms: budgets.attempt_budget_ms,
      build_cache_retained: true,
      reason: @drop_timeout_reason
    }

  defp cleanup_receipt({:failed, attempts, reason}, _budgets),
    do: %{
      database_dropped: false,
      drop_outcome: "failed",
      drop_attempts: attempts,
      build_cache_retained: true,
      reason: cleanup_reason(reason)
    }

  # Self-test for the cleanup contract, driving the real `await_drop/2` with scripted drop
  # results. Needs no database and no repo, which is why the test runs it under `--no-start`.
  defp drop_classification_self_test do
    budgets = %{budget_ms: 200, attempt_budget_ms: 20, pause_ms: 1}

    [
      {"retries a timed-out drop inside the budget",
       scripted([{:error, @drop_timeout_reason}, {:error, @drop_timeout_reason}, :ok])},
      {"spends the budget when the drop never answers",
       scripted([{:error, @drop_timeout_reason}])},
      {"a database already gone is dropped",
       scripted([{:error, @drop_timeout_reason}, {:error, :already_down}])},
      {"a refused drop is not retried", scripted([{:error, "permission denied"}, :ok])}
    ]
    |> Enum.each(fn {label, drop_fun} ->
      receipt(
        "drop_classification",
        Map.put(cleanup_receipt(await_drop(drop_fun, budgets), budgets), :case, label)
      )
    end)

    :ok
  end

  defp scripted(results) do
    key = {__MODULE__, :scripted_drop, make_ref()}
    Process.put(key, results)

    fn _timeout ->
      case Process.get(key) do
        [last] ->
          last

        [head | rest] ->
          Process.put(key, rest)
          head
      end
    end
  end

  defp cleanup_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp cleanup_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp cleanup_reason(reason), do: reason |> inspect() |> String.slice(0, 200)

  defp storage_options(config, extra \\ []),
    do: config |> Keyword.put(:timeout, @storage_budget) |> Keyword.merge(extra)

  defp projection_rehearsal(_repo, scenario \\ :projection) do
    Sandbox.mode(Repo, :auto)
    timed("baseline_schema", fn -> Migrator.run(Repo, :up, to: @version - 1, log: false) end)
    Code.require_file("priv/repo/migrations/20260902024410_add_request_replay_entitlements.exs")
    seed(4)
    RequestReplayMigrationProjection.run(&migrate_up/0, scenario)
    assert_already_applied!()
  end

  defp lock_matrix(_repo) do
    Sandbox.mode(Repo, :auto)
    Migrator.run(Repo, :up, to: @version - 1, log: false)
    Code.require_file("priv/repo/migrations/20260902024410_add_request_replay_entitlements.exs")
    seed(4)

    for scenario <- [:projection, :finalizer, :turn, :reservation, :pool, :model] do
      RequestReplayMigrationProjection.run(&migrate_up/0, scenario)
      :ok = Migrator.down(Repo, @version, @migration, log: false)
    end

    RequestReplayMigrationProjection.run(&migrate_up/0, :expiry)
  end

  defp safe_config! do
    config = Repo.config()
    database = Keyword.fetch!(config, :database)
    hostname = Keyword.fetch!(config, :hostname)

    permitted_host? =
      hostname in ["localhost", "127.0.0.1"] or
        (is_binary(hostname) and hostname != "" and
           hostname == System.get_env("CODEX_POOLER_TEST_POSTGRES_HOST"))

    unless Mix.env() == :test and is_nil(Process.whereis(Repo)) and
             permitted_host? and is_nil(config[:url]) and
             Regex.match?(~r/\Acodex_pooler_test_[0-9a-f]{8}_[0-9a-f]{16}_p1\z/, database) do
      raise ArgumentError,
            "requires --no-start and an isolated partition-one database on an explicit test host"
    end

    config
  end

  defp rehearse(_repo, rows) do
    Sandbox.mode(Repo, :auto)
    timed("baseline_schema", fn -> Migrator.run(Repo, :up, to: @version - 1, log: false) end)
    Code.require_file("priv/repo/migrations/20260902024410_add_request_replay_entitlements.exs")
    fixture = seed(rows)
    baseline_checksum = rows_checksum()
    receipt("before_upgrade", counts())
    timed("first_upgrade", fn -> RequestReplayMigrationProjection.run(&migrate_up/0, :reader) end)
    assert_already_applied!()
    assert_counts!(rows, div(rows, 4), div(rows, 2))
    true = baseline_checksum == rows_checksum()
    legacy_insert(fixture, "legacy-after-up")
    assert_counts!(rows + 1, div(rows, 4), div(rows, 2) + 1)
    upgraded_checksum = rows_checksum()
    timed("rollback", fn -> :ok = Migrator.down(Repo, @version, @migration, log: false) end)
    assert_counts!(rows + 1, div(rows, 4), div(rows, 2) + 1)
    true = upgraded_checksum == rows_checksum()

    [[true, 0]] =
      query("""
      SELECT to_regclass('public.request_replay_entitlements') IS NULL,
        (SELECT count(*) FROM information_schema.columns
          WHERE table_schema = 'public' AND
            ((table_name = 'attempts' AND column_name = 'replay_generation') OR
             (table_name = 'codex_turns' AND column_name = 'semantic_turn_digest')))
      """).rows

    receipt("rollback_correlations_preserved", %{all_correlations_unchanged: true})
    legacy_insert(fixture, "legacy-after-down")
    assert_counts!(rows + 2, div(rows, 4), div(rows, 2) + 2)
    rollback_checksum = rows_checksum()

    timed("second_upgrade", fn ->
      RequestReplayMigrationProjection.run(&migrate_up/0)
    end)

    assert_already_applied!()
    assert_counts!(rows + 2, div(rows, 4), div(rows, 2) + 2)
    true = rollback_checksum == rows_checksum()

    [[^rows, ^rows, 0]] =
      query("""
      SELECT (SELECT count(*) FROM codex_turns), count(*),
        count(*) FILTER (WHERE replay_generation <> 0) FROM attempts
      """).rows

    receipt("complete", %{request_rows: rows + 2, turn_rows: rows, attempt_rows: rows})
    :ok
  end

  defp seed(rows) do
    pool = CodexPooler.PoolerFixtures.pool_fixture()
    model = CodexPooler.PoolerFixtures.model_fixture(pool)
    %{assignment: assignment} = CodexPooler.PoolerFixtures.upstream_assignment_fixture(pool)
    pool_id = Ecto.UUID.dump!(pool.id)
    model_id = Ecto.UUID.dump!(model.id)
    key_id = Ecto.UUID.bingenerate()

    query(
      """
      INSERT INTO api_keys (id, pool_id, display_name, key_prefix, key_hash)
      VALUES ($1, $2, 'Synthetic migration key', 'synthetic', digest('synthetic-key', 'sha256'))
      """,
      [key_id, pool_id]
    )

    query(
      """
      INSERT INTO requests (pool_id, api_key_id, model_id, requested_model, endpoint,
        transport, status, usage_status, correlation_id, request_metadata)
      SELECT $1, $2, $3, 'synthetic-model', '/backend-api/codex/responses',
        'websocket', 'succeeded', 'usage_unknown',
        CASE n % 4 WHEN 0 THEN 'codex-turn:' || n WHEN 1 THEN 'codex-request:' || n
          WHEN 2 THEN 'sha256:' || encode(digest(n::text, 'sha256'), 'hex')
          ELSE 'synthetic-correlation-' || n END,
        jsonb_build_object('fixture_ordinal', n)
      FROM generate_series(1, $4::integer) n
      """,
      [pool_id, key_id, model_id, rows]
    )

    [[session_id]] =
      query(
        """
        INSERT INTO codex_sessions (pool_id, api_key_id, session_key)
        VALUES ($1, $2, 'synthetic-migration-session') RETURNING id
        """,
        [pool_id, key_id]
      ).rows

    query(
      """
      INSERT INTO codex_turns (codex_session_id, request_id, turn_sequence, transport_kind, status)
      SELECT $1, id, (request_metadata->>'fixture_ordinal')::integer, 'websocket', 'succeeded'
      FROM requests
      """,
      [session_id]
    )

    query(
      """
      INSERT INTO attempts (request_id, attempt_number, pool_upstream_assignment_id,
        model_id, upstream_model_id, transport, status, usage_status)
      SELECT id, 1, $1, model_id, 'synthetic-model', 'websocket', 'succeeded', 'usage_unknown'
      FROM requests
      """,
      [Ecto.UUID.dump!(assignment.id)]
    )

    %{pool_id: pool_id, key_id: key_id, model_id: model_id}
  end

  defp legacy_insert(fixture, ordinal) do
    correlation = "codex-request:" <> ordinal

    [[stored]] =
      query(
        """
        INSERT INTO requests (pool_id, api_key_id, model_id, requested_model, endpoint,
          transport, correlation_id)
        VALUES ($1, $2, $3, 'synthetic-model', '/backend-api/codex/responses', 'websocket', $4)
        RETURNING correlation_id
        """,
        [fixture.pool_id, fixture.key_id, fixture.model_id, correlation]
      ).rows

    [[matches]] =
      query("SELECT count(*) FROM requests WHERE correlation_id = $1", [correlation]).rows

    true = stored == correlation
    1 = matches

    {:error, %Postgrex.Error{postgres: %{code: :unique_violation, constraint: constraint}}} =
      Repo.query(
        """
        INSERT INTO requests (pool_id, api_key_id, requested_model, endpoint, transport, correlation_id)
        VALUES ($1, $2, 'synthetic-model', '/backend-api/codex/responses', 'websocket', $3)
        """,
        [fixture.pool_id, fixture.key_id, correlation],
        log: false
      )

    "requests_correlation_id_uq" = constraint

    receipt(ordinal, %{
      insert_succeeded: true,
      stored_hashed: stored != correlation,
      old_exact_lookup_matches: matches,
      duplicate_insert_rejected: true
    })
  end

  defp migrate_up, do: :ok = Migrator.up(Repo, @version, @migration, log: false)

  defp assert_already_applied! do
    checksum = rows_checksum()
    :already_up = Migrator.up(Repo, @version, @migration, log: false)
    ^checksum = rows_checksum()
    receipt("already_applied", %{migration_skipped: true, request_rows_unchanged: true})
  end

  defp timed(stage, fun) do
    [[wal]] = query("SELECT pg_current_wal_lsn()::text").rows
    {microseconds, result} = :timer.tc(fun)

    [[wal_bytes]] =
      query("SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), $1::text::pg_lsn)::bigint", [wal]).rows

    receipt(stage, %{elapsed_ms: div(microseconds, 1000), server_wal_delta_bytes: wal_bytes})
    result
  end

  defp counts do
    [[total, hashed, claims]] =
      query("""
      SELECT count(*), count(*) FILTER (WHERE correlation_id LIKE 'sha256:%'),
        count(*) FILTER (WHERE correlation_id LIKE 'codex-turn:%' OR correlation_id LIKE 'codex-request:%')
      FROM requests
      """).rows

    %{request_rows: total, hashed_rows: hashed, claim_rows: claims}
  end

  defp assert_counts!(total, hashed, claims) do
    %{request_rows: ^total, hashed_rows: ^hashed, claim_rows: ^claims} = counts()
    receipt("row_invariants", counts())
  end

  defp rows_checksum do
    [[checksum]] =
      query(
        "SELECT md5(string_agg(id::text || ':' || correlation_id, ',' ORDER BY id)) FROM requests"
      ).rows

    checksum
  end

  defp query(sql, params \\ []), do: Repo.query!(sql, params, log: false, timeout: @budget)

  defp receipt(stage, values),
    do: IO.puts(CodexPooler.JSON.encode!(Map.put(values, :stage, stage)))
end

CodexPooler.Verification.RequestReplayMigration.run(System.argv())
