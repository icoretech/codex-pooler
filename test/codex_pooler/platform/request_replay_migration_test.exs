defmodule CodexPooler.RequestReplayMigrationTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  # Every rehearsal boots its own `mix run` VM, creates an owned database, and applies the
  # baseline migrations before the scenario runs, so each test carries a ~2 s floor that is
  # the property under test (a real populated migration), not a wait. The module timeout is
  # the failure-detection budget for that whole VM on a loaded host.
  @moduletag timeout: 120_000

  # The migration's lock budget is hard-coded inside its `DO $migration_lock$` block, so the
  # expiry scenario must wait the real production budget out to prove the migration gives up
  # on its own instead of queueing behind a long-running writer.
  @migration_lock_budget_ms 10_000

  # The populated rehearsal proves rows survive upgrade and rollback; the count is not the
  # claim, so it stays small.
  @rows 100

  test "upgrade and rollback preserve populated rows while a projection writer commits" do
    rehearsal = run_rehearsal(["--rows", Integer.to_string(@rows)])
    assert rehearsal.exit_code == 0, rehearsal.output
    receipts = rehearsal.receipts

    for scenario <- ["reader", "projection"] do
      assert %{"distinct_backends" => true, "partial_table_locks_released" => true} =
               scenario_receipt(receipts, "projection_lock_retry", scenario)

      assert %{"writer" => "committed", "migration" => "committed"} =
               scenario_receipt(receipts, "projection_lock_result", scenario)
    end

    assert %{"migration_skipped" => true, "request_rows_unchanged" => true} =
             receipt(receipts, "already_applied")

    assert %{"all_correlations_unchanged" => true} =
             receipt(receipts, "rollback_correlations_preserved")

    request_rows = @rows + 2
    turn_rows = @rows

    assert %{
             "request_rows" => ^request_rows,
             "turn_rows" => ^turn_rows,
             "attempt_rows" => ^turn_rows
           } = receipt(receipts, "complete")

    assert_owned_database_dropped!(rehearsal)
  end

  # Runs longer than two seconds on purpose: the `expiry` scenario waits out the migration's
  # real @migration_lock_budget_ms before the migration raises `lock_not_available`.
  test "all referenced-table writers commit and lock-budget expiry leaves the schema unchanged" do
    rehearsal = run_rehearsal(["--lock-matrix"])
    assert rehearsal.exit_code == 0, rehearsal.output
    receipts = rehearsal.receipts

    for scenario <- ["projection", "finalizer", "turn", "reservation", "pool", "model"] do
      assert %{"distinct_backends" => true, "partial_table_locks_released" => true} =
               scenario_receipt(receipts, "projection_lock_retry", scenario)

      assert %{"writer" => "committed", "migration" => "committed"} =
               scenario_receipt(receipts, "projection_lock_result", scenario)
    end

    assert %{
             "writer" => "committed",
             "migration" => "lock_not_available",
             "schema_unchanged" => true
           } =
             receipt(receipts, "projection_lock_expiry")

    assert %{"elapsed_ms" => elapsed_ms} =
             scenario_receipt(receipts, "migration_lock_duration", "expiry")

    # The migration must honour its whole budget before giving up. There is no wall-clock
    # upper bound: `lock_not_available` above already proves it gave up rather than waiting
    # for the writer, and the rehearsal's own detection budgets bound the run.
    assert elapsed_ms >= @migration_lock_budget_ms

    assert_owned_database_dropped!(rehearsal)
  end

  test "a non-database writer failure still cleans the owned database" do
    rehearsal = run_rehearsal(["--writer-failure"])
    assert rehearsal.exit_code != 0
    receipts = rehearsal.receipts
    assert %{"writer" => "runtime_failure"} = receipt(receipts, "projection_lock_result")
    assert_owned_database_dropped!(rehearsal)
  end

  defp run_rehearsal(args) do
    namespace = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    configured_host = Keyword.fetch!(Repo.config(), :hostname)
    test_host = if configured_host == "localhost", do: "localhost.", else: configured_host

    {output, exit_code} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "--no-compile",
          "scripts/verification/request_replay_migration.exs"
        ] ++ args,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_TEST_PARTITION", "1"},
          {"CODEX_POOLER_TEST_POSTGRES_HOST", test_host},
          {"CODEX_POOLER_TEST_RUN_NAMESPACE", namespace}
        ],
        stderr_to_stdout: true
      )

    %{
      output: output,
      exit_code: exit_code,
      receipts: parse_receipts(output),
      namespace: namespace
    }
  end

  defp parse_receipts(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> Enum.map(&CodexPooler.JSON.decode!/1)
  end

  defp receipt(receipts, stage), do: Enum.find(receipts, &(&1["stage"] == stage))

  defp scenario_receipt(receipts, stage, scenario),
    do: Enum.find(receipts, &(&1["stage"] == stage and &1["scenario"] == scenario))

  # The cleanup receipt must be printed on every path, including a failing rehearsal, and
  # the owned database must really be gone from the server afterwards.
  defp assert_owned_database_dropped!(rehearsal) do
    case receipt(rehearsal.receipts, "cleanup") do
      %{"database_dropped" => true} ->
        :ok

      other ->
        flunk("""
        rehearsal did not report a successful cleanup receipt: #{inspect(other)}
        #{rehearsal.output}
        """)
    end

    assert owned_databases(rehearsal.namespace) == [],
           "owned rehearsal database for namespace #{rehearsal.namespace} survived cleanup"
  end

  defp owned_databases(namespace) do
    Sandbox.unboxed_run(Repo, fn ->
      %{rows: rows} =
        Repo.query!(
          "SELECT datname FROM pg_database WHERE datname LIKE $1",
          ["codex_pooler_test_%_#{namespace}_p1"],
          log: false
        )

      List.flatten(rows)
    end)
  end
end
