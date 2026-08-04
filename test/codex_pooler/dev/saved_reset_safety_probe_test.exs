defmodule CodexPooler.Dev.SavedResetSafetyProbeTest do
  use CodexPooler.DataCase, async: true

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Dev.SavedResetSafetyProbe, as: Probe
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  test "parses only the named certification scenarios" do
    assert {:ok, %{scenarios: ["sibling-barrier"]}} =
             Probe.parse_args(["--scenario", "sibling-barrier"])

    assert {:ok, %{scenarios: ["first-turn-capacity"]}} =
             Probe.parse_args(["--scenario", "first-turn-capacity"])

    assert {:ok, %{scenarios: ["reblocked-convergence"]}} =
             Probe.parse_args(["--scenario", "reblocked-convergence"])

    assert {:ok,
            %{
              scenarios: [
                "sibling-barrier",
                "ambiguous-replay",
                "markerless-legacy",
                "first-turn-capacity",
                "reblocked-convergence"
              ]
            }} = Probe.parse_args(["--scenario", "all"])

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

  test "certifies the race only for callers pinned to distinct database backends" do
    assert Probe.distinct_pinned_backends?(
             %{before: 101, after: 101},
             %{before: 202, after: 202}
           )

    # Same-backend misuse: both callers observed one PostgreSQL backend.
    refute Probe.distinct_pinned_backends?(
             %{before: 101, after: 101},
             %{before: 101, after: 101}
           )

    # Unpinned misuse: a caller's connection changed mid-redemption, so the
    # marker pid does not prove which backend ran its transactions.
    refute Probe.distinct_pinned_backends?(
             %{before: 101, after: 303},
             %{before: 202, after: 202}
           )

    refute Probe.distinct_pinned_backends?(
             %{before: 101, after: 101},
             %{before: 202, after: 404}
           )

    refute Probe.distinct_pinned_backends?(%{before: nil, after: nil}, %{before: 202, after: 202})
    refute Probe.distinct_pinned_backends?(%{}, %{before: 202, after: 202})
  end

  test "a missing provider barrier signal resolves to timeout instead of hanging" do
    assert Probe.receive_provider_barrier(0) == :timeout

    send(self(), {:saved_reset_probe_provider_barrier, self(), :sibling})
    parent = self()
    assert {:provider_barrier, ^parent, :sibling} = Probe.receive_provider_barrier(0)
  end

  test "accepts only byte-identical replayed consume requests" do
    first = %{"credit_id" => "dev-credit-a", "redeem_request_id" => "req-1"}

    assert Probe.replay_request_reused?(first, %{
             "credit_id" => "dev-credit-a",
             "redeem_request_id" => "req-1"
           })

    # Reordered-credit retargeting: the replay picked a different credit.
    refute Probe.replay_request_reused?(first, %{
             "credit_id" => "dev-credit-b",
             "redeem_request_id" => "req-1"
           })

    # Changed derived request id breaks provider-side idempotency.
    refute Probe.replay_request_reused?(first, %{
             "credit_id" => "dev-credit-a",
             "redeem_request_id" => "req-2"
           })

    refute Probe.replay_request_reused?(first, %{"credit_id" => "", "redeem_request_id" => ""})
    refute Probe.replay_request_reused?(first, %{})
    refute Probe.replay_request_reused?(first, nil)
  end

  test "derives the legacy observe-only mode from the persisted record" do
    persisted = %{
      "status" => "redeeming",
      "phase" => "consuming",
      "legacy_recovery" => %{"version" => 1, "state" => "unresolved"}
    }

    assert Probe.legacy_observe_only_mode(persisted) == "observe_only"

    assert Probe.legacy_observe_only_mode(Map.put(persisted, "provider_replay", %{"version" => 1})) ==
             "unexpected"

    assert Probe.legacy_observe_only_mode(Map.put(persisted, "status", "succeeded")) ==
             "unexpected"

    assert Probe.legacy_observe_only_mode(Map.put(persisted, "phase", "confirmed_by_quota")) ==
             "unexpected"

    assert Probe.legacy_observe_only_mode(
             Map.put(persisted, "legacy_recovery", %{"version" => 2, "state" => "operator_owned"})
           ) == "unexpected"

    assert Probe.legacy_observe_only_mode(%{}) == "unexpected"
  end

  test "removes exactly the journaled run-owned rows and detects survivors" do
    owned = active_upstream_assignment_fixture(pool_fixture())
    unrelated = active_upstream_assignment_fixture(pool_fixture())

    journal = %{
      pool_ids: [owned.assignment.pool_id],
      identity_ids: [owned.identity.id],
      assignment_ids: [owned.assignment.id]
    }

    refute Probe.owned_resources_removed?(journal)

    assert :ok = Probe.cleanup_owned!(journal)
    assert Probe.owned_resources_removed?(journal)

    refute Repo.get(Pool, owned.assignment.pool_id)
    refute Repo.get(UpstreamIdentity, owned.identity.id)
    refute Repo.get(PoolUpstreamAssignment, owned.assignment.id)

    assert Repo.get(Pool, unrelated.assignment.pool_id)
    assert Repo.get(UpstreamIdentity, unrelated.identity.id)
    assert Repo.get(PoolUpstreamAssignment, unrelated.assignment.id)

    assert :ok = Probe.cleanup_owned!(journal)
  end

  test "allows only metadata-safe receipt fields" do
    assert :ok =
             Probe.validate_receipt(%{
               run_fingerprint: "0a1b2c3d4e5f",
               scenarios: %{
                 "sibling-barrier" => %{
                   consume_count: 1,
                   distinct_backend_pids: true,
                   backend_pinned: true,
                   barrier: true,
                   winner_applied: true,
                   loser_code: "gateway_auto_sibling_consume_barrier"
                 },
                 "first-turn-capacity" => %{
                   first_turn_vetoed: true,
                   veto_code: "gateway_auto_sibling_usable_capacity",
                   hard_pin_applied: true,
                   consume_count: 1
                 },
                 "reblocked-convergence" => %{
                   converged: "confirmed_by_quota",
                   repeat: "unchanged",
                   provider_requests: 0,
                   attempt_preserved: true
                 }
               },
               status: "passed",
               cleanup: "exact_owned_rows_removed",
               endpoint_isolated: true,
               oban_isolated: true,
               source_sha: "0123456789abcdef0123456789abcdef01234567"
             })

    # A capacity receipt that cannot prove the first-turn veto is invalid.
    for override <- [
          %{first_turn_vetoed: false},
          %{veto_code: "gateway_auto_sibling_consume_barrier"},
          %{consume_count: 2}
        ] do
      assert {:error, "receipt contains a field outside the metadata allowlist"} =
               Probe.validate_receipt(%{
                 run_fingerprint: "0a1b2c3d4e5f",
                 scenarios: %{
                   "first-turn-capacity" =>
                     Map.merge(
                       %{
                         first_turn_vetoed: true,
                         veto_code: "gateway_auto_sibling_usable_capacity",
                         hard_pin_applied: true,
                         consume_count: 1
                       },
                       override
                     )
                 },
                 status: "passed",
                 cleanup: "exact_owned_rows_removed",
                 endpoint_isolated: true,
                 oban_isolated: true,
                 source_sha: "unavailable"
               })
    end

    # A convergence receipt claiming provider traffic or a different outcome is
    # invalid.
    for override <- [
          %{provider_requests: 1},
          %{converged: "reblocked"},
          %{attempt_preserved: false}
        ] do
      assert {:error, "receipt contains a field outside the metadata allowlist"} =
               Probe.validate_receipt(%{
                 run_fingerprint: "0a1b2c3d4e5f",
                 scenarios: %{
                   "reblocked-convergence" =>
                     Map.merge(
                       %{
                         converged: "confirmed_by_quota",
                         repeat: "unchanged",
                         provider_requests: 0,
                         attempt_preserved: true
                       },
                       override
                     )
                 },
                 status: "passed",
                 cleanup: "exact_owned_rows_removed",
                 endpoint_isolated: true,
                 oban_isolated: true,
                 source_sha: "unavailable"
               })
    end

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

    # A sibling receipt that cannot prove pinned distinct backends is invalid.
    for backend_override <- [
          %{backend_pinned: false},
          %{distinct_backend_pids: false},
          %{}
        ] do
      sibling =
        Map.merge(
          %{
            consume_count: 1,
            distinct_backend_pids: true,
            backend_pinned: true,
            barrier: true,
            winner_applied: true,
            loser_code: "gateway_auto_sibling_consume_barrier"
          },
          backend_override
        )

      sibling =
        if backend_override == %{},
          do: Map.delete(sibling, :backend_pinned),
          else: sibling

      assert {:error, "receipt contains a field outside the metadata allowlist"} =
               Probe.validate_receipt(%{
                 run_fingerprint: "0a1b2c3d4e5f",
                 scenarios: %{"sibling-barrier" => sibling},
                 status: "passed",
                 cleanup: "exact_owned_rows_removed",
                 endpoint_isolated: true,
                 oban_isolated: true,
                 source_sha: "unavailable"
               })
    end

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
