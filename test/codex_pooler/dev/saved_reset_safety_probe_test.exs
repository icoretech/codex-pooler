defmodule CodexPooler.Dev.SavedResetSafetyProbeTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Dev.SavedResetSafetyProbe, as: Probe

  test "parses only the named certification scenarios" do
    assert {:ok, %{scenarios: ["sibling-barrier"]}} =
             Probe.parse_args(["--scenario", "sibling-barrier"])

    assert {:ok, %{scenarios: ["sibling-barrier", "ambiguous-replay", "markerless-legacy"]}} =
             Probe.parse_args(["--scenario", "all"])

    assert {:error, _message} = Probe.parse_args([])
    assert {:error, _message} = Probe.parse_args(["--scenario", "production"])

    assert {:error, _message} =
             Probe.parse_args(["--scenario", "all", "--scenario", "sibling-barrier"])

    assert {:error, _message} = Probe.parse_args(["--scenario", "all", "unexpected"])
    assert {:error, "scenario command is invalid"} = Probe.execute(%{scenarios: []})
    assert {:error, "scenario command is invalid"} = Probe.execute(%{scenarios: ["all"]})
  end

  test "refuses non-dev and non-canonical database configurations before side effects" do
    assert {:error, "saved-reset safety probe runs only with MIX_ENV=dev"} =
             Probe.validate_environment(:test, database: "codex_pooler_dev")

    assert {:error, "saved-reset safety probe requires database codex_pooler_dev"} =
             Probe.validate_environment(:dev, database: "other")

    assert :ok = Probe.validate_environment(:dev, database: "codex_pooler_dev")
  end

  test "forces endpoint and Oban isolation" do
    isolated =
      Probe.isolated_config([queues: [jobs: 8], plugins: [:cron]],
        server: true,
        watchers: [:esbuild],
        live_reload: []
      )

    assert isolated.oban[:testing] == :manual
    assert isolated.oban[:queues] == false
    assert isolated.oban[:plugins] == false
    assert isolated.endpoint[:server] == false
    assert isolated.endpoint[:watchers] == []
    refute Keyword.has_key?(isolated.endpoint, :live_reload)
  end

  test "allows only metadata-safe receipt fields" do
    assert :ok =
             Probe.validate_receipt(%{
               run_fingerprint: "0a1b2c3d4e5f",
               scenarios: %{
                 "sibling-barrier" => %{
                   consume_count: 1,
                   distinct_backend_pids: true,
                   barrier: true,
                   winner_applied: true,
                   loser_code: "gateway_auto_sibling_consume_barrier"
                 }
               },
               status: "passed",
               cleanup: "exact_owned_rows_removed",
               endpoint_isolated: true,
               oban_isolated: true,
               source_sha: "0123456789abcdef0123456789abcdef01234567"
             })

    assert {:error, "receipt contains a field outside the metadata allowlist"} =
             Probe.validate_receipt(%{run_fingerprint: "safe", raw_credit_id: "forbidden"})

    assert {:error, "receipt contains a field outside the metadata allowlist"} =
             Probe.validate_receipt(%{
               run_fingerprint: "0a1b2c3d4e5f",
               scenarios: %{"ambiguous-replay" => %{raw_credit_id: "forbidden"}},
               status: "passed",
               cleanup: "exact_owned_rows_removed",
               endpoint_isolated: true,
               oban_isolated: true,
               source_sha: "unavailable"
             })

    assert {:error, "receipt contains a field outside the metadata allowlist"} =
             Probe.validate_receipt(%{
               run_fingerprint: "not-a-fingerprint",
               scenarios: %{},
               status: "failed",
               cleanup: "unsafe",
               endpoint_isolated: "true",
               oban_isolated: false,
               source_sha: "unavailable"
             })

    assert {:error, "receipt contains a field outside the metadata allowlist"} =
             Probe.validate_receipt(%{
               run_fingerprint: "0a1b2c3d4e5f",
               scenarios: %{
                 "markerless-legacy" => %{
                   legacy_recovery: "v1_unresolved",
                   mode: "observe_only",
                   provider_requests: 0,
                   snooze_seconds: "21600",
                   next_action_scheduled: true
                 }
               },
               status: "passed",
               cleanup: "exact_owned_rows_removed",
               endpoint_isolated: true,
               oban_isolated: true,
               source_sha: "unavailable"
             })
  end
end
