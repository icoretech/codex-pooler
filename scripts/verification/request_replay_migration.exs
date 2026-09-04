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

  @spec run([String.t()]) :: :ok
  def run(["--help"]), do: IO.puts(@moduledoc)

  def run(["--projection-lock"]), do: run_rehearsal(&projection_rehearsal/1)

  def run(["--lock-matrix"]), do: run_rehearsal(&lock_matrix/1)

  def run(["--writer-failure"]), do: run_rehearsal(&projection_rehearsal(&1, :writer_failure))

  def run(["--rows", value]) do
    case Integer.parse(value) do
      {rows, ""} when rows in 1_000..100_000 and rem(rows, 4) == 0 ->
        run_rehearsal(&rehearse(&1, rows))

      _ ->
        raise ArgumentError, "--rows requires a multiple of four between 1000 and 100000"
    end
  end

  def run(_args),
    do:
      raise(
        ArgumentError,
        "usage: --rows 10000 | --projection-lock | --lock-matrix | --writer-failure | --help"
      )

  defp run_rehearsal(fun) do
    config = safe_config!()
    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    :ok = Postgres.storage_up(config)

    try do
      {:ok, :ok, _} = Migrator.with_repo(Repo, fun, pool_size: 8)
    after
      :ok = Postgres.storage_down(config)
      receipt("cleanup", %{database_dropped: true, build_cache_retained: true})
    end
  end

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
  defp receipt(stage, values), do: IO.puts(Jason.encode!(Map.put(values, :stage, stage)))
end

CodexPooler.Verification.RequestReplayMigration.run(System.argv())
