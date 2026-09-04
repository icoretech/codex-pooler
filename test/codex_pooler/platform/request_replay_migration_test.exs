defmodule CodexPooler.RequestReplayMigrationTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000

  test "upgrade and rollback preserve populated rows while a projection writer commits" do
    {output, exit_code} = run_rehearsal(["--rows", "1000"])
    assert exit_code == 0, output
    receipts = parse_receipts(output)

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

    assert %{"request_rows" => 1002, "turn_rows" => 1000, "attempt_rows" => 1000} =
             receipt(receipts, "complete")

    assert %{"database_dropped" => true} = receipt(receipts, "cleanup")
  end

  test "all referenced-table writers commit and lock-budget expiry leaves the schema unchanged" do
    {output, exit_code} = run_rehearsal(["--lock-matrix"])
    assert exit_code == 0, output
    receipts = parse_receipts(output)

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

    assert elapsed_ms >= 10_000 and elapsed_ms < 15_000

    assert %{"database_dropped" => true} = receipt(receipts, "cleanup")
  end

  test "a non-database writer failure still cleans the owned database" do
    {output, exit_code} = run_rehearsal(["--writer-failure"])
    assert exit_code != 0
    receipts = parse_receipts(output)
    assert %{"writer" => "runtime_failure"} = receipt(receipts, "projection_lock_result")
    assert %{"database_dropped" => true} = receipt(receipts, "cleanup")
  end

  defp run_rehearsal(args) do
    namespace = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    configured_host = Keyword.fetch!(CodexPooler.Repo.config(), :hostname)
    test_host = if configured_host == "localhost", do: "localhost.", else: configured_host

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
  end

  defp parse_receipts(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> Enum.map(&Jason.decode!/1)
  end

  defp receipt(receipts, stage), do: Enum.find(receipts, &(&1["stage"] == stage))

  defp scenario_receipt(receipts, stage, scenario),
    do: Enum.find(receipts, &(&1["stage"] == stage and &1["scenario"] == scenario))
end
