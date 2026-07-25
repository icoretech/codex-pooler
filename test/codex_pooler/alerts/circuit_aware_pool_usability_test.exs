defmodule CodexPooler.Alerts.CircuitAwarePoolUsabilityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [primary_quota_window_attrs: 1]

  alias CodexPooler.Alerts
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  setup do
    previous_settings = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      settings: %OperationalSettings{
        circuit_open_seconds: 60,
        circuit_half_open_probe_limit: 1
      }
    )

    on_exit(fn ->
      if previous_settings do
        Application.put_env(:codex_pooler, OperationalSettings, previous_settings)
      else
        Application.delete_env(:codex_pooler, OperationalSettings)
      end
    end)
  end

  test "blocked serving assignments are not hidden by a healthy non-serving assignment" do
    observed_at = ~U[2026-05-30 09:20:00Z]
    pool = pool_fixture()
    assignments = for _index <- 1..4, do: usable_assignment(pool, observed_at)
    [first, second, third, non_serving] = assignments
    serving_ids = Enum.map([first, second, third], & &1.assignment.id)

    model_fixture(pool, %{
      exposed_model_id: "gpt-serving",
      metadata: %{"source_assignment_ids" => serving_ids},
      source_assignment_count: 3
    })

    model_fixture(pool, %{
      exposed_model_id: "gpt-other",
      metadata: %{"source_assignment_ids" => [non_serving.assignment.id]}
    })

    for assignment <- [first, second, third] do
      circuit_fixture(pool, assignment, "GPT-SERVING", observed_at,
        next_probe_at: DateTime.add(observed_at, 60, :second)
      )
    end

    scoped_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_no_usable_assignments",
        model: " gpt-serving "
      )

    assert [%{action: :match, match_attrs: match}] =
             Alerts.evaluate_rule(scoped_rule, at: observed_at)

    assert match.safe_evidence_snapshot["usable_assignment_count"] == 0
    assert match.safe_evidence_snapshot["circuit_blocked_assignment_count"] == 3
    assert match.safe_evidence_snapshot["non_serving_assignment_count"] == 1
    assert match.safe_evidence_snapshot["model_membership_resolved"] == true

    unscoped_rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")
    assert [%{action: :clear}] = Alerts.evaluate_rule(unscoped_rule, at: observed_at)
  end

  test "an unresolved scoped model leaves membership and even a blocked matching row inert" do
    observed_at = ~U[2026-05-30 09:20:00Z]
    pool = pool_fixture()
    assignment = usable_assignment(pool, observed_at)

    circuit_fixture(pool, assignment, "missing-model", observed_at,
      next_probe_at: DateTime.add(observed_at, 60, :second)
    )

    rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_low_usable_assignments",
        model: "missing-model",
        min_usable_assignments: 2
      )

    assert [%{action: :match, match_attrs: match}] =
             Alerts.evaluate_rule(rule, at: observed_at)

    assert match.safe_evidence_snapshot["usable_assignment_count"] == 1
    assert match.safe_evidence_snapshot["circuit_blocked_assignment_count"] == 0
    assert match.safe_evidence_snapshot["model_membership_resolved"] == false
  end

  test "a model-nil rule blocks an assignment only when every active model it serves is blocked" do
    observed_at = ~U[2026-05-30 09:20:00Z]
    pool = pool_fixture()
    assignment = usable_assignment(pool, observed_at)

    for model_id <- ["gpt-alpha", "gpt-beta"] do
      model_fixture(pool, %{
        exposed_model_id: model_id,
        metadata: %{"source_assignment_ids" => [assignment.assignment.id]}
      })
    end

    circuit_fixture(pool, assignment, "gpt-alpha", observed_at,
      next_probe_at: DateTime.add(observed_at, 60, :second)
    )

    rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")
    assert [%{action: :clear}] = Alerts.evaluate_rule(rule, at: observed_at)

    circuit_fixture(pool, assignment, "gpt-beta", observed_at,
      route_class: "proxy_compact",
      next_probe_at: DateTime.add(observed_at, 60, :second)
    )

    assert [%{action: :match, match_attrs: match}] =
             Alerts.evaluate_rule(rule, at: observed_at)

    assert match.safe_evidence_snapshot["usable_assignment_count"] == 0
    assert match.safe_evidence_snapshot["circuit_blocked_assignment_count"] == 1
  end

  test "a model-scoped blackout matches while a partially blocked second model keeps model-nil clear" do
    observed_at = ~U[2026-05-30 09:20:00Z]
    pool = pool_fixture()
    [first, second, third] = for _index <- 1..3, do: usable_assignment(pool, observed_at)

    model_fixture(pool, %{
      exposed_model_id: "gpt-fully-blocked",
      metadata: %{"source_assignment_ids" => [first.assignment.id]}
    })

    model_fixture(pool, %{
      exposed_model_id: "gpt-partially-blocked",
      metadata: %{
        "source_assignment_ids" => [
          first.assignment.id,
          second.assignment.id,
          third.assignment.id
        ]
      },
      source_assignment_count: 3
    })

    for model_id <- ["gpt-fully-blocked", "gpt-partially-blocked"] do
      circuit_fixture(pool, first, model_id, observed_at,
        next_probe_at: DateTime.add(observed_at, 60, :second)
      )
    end

    scoped_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_no_usable_assignments",
        model: "gpt-fully-blocked"
      )

    model_nil_rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    assert [%{action: :match}] = Alerts.evaluate_rule(scoped_rule, at: observed_at)
    assert [%{action: :clear}] = Alerts.evaluate_rule(model_nil_rule, at: observed_at)
  end

  test "a pool with no active models leaves membership and circuits inert" do
    observed_at = ~U[2026-05-30 09:20:00Z]
    pool = pool_fixture()
    assignment = usable_assignment(pool, observed_at)

    model_fixture(pool, %{
      exposed_model_id: "retired-model",
      status: "retired",
      metadata: %{"source_assignment_ids" => [assignment.assignment.id]}
    })

    circuit_fixture(pool, assignment, "retired-model", observed_at,
      next_probe_at: DateTime.add(observed_at, 60, :second)
    )

    rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_low_usable_assignments",
        min_usable_assignments: 2
      )

    assert [%{action: :match, match_attrs: match}] =
             Alerts.evaluate_rule(rule, at: observed_at)

    assert match.safe_evidence_snapshot["usable_assignment_count"] == 1
    assert match.safe_evidence_snapshot["circuit_blocked_assignment_count"] == 0
    assert match.safe_evidence_snapshot["model_membership_resolved"] == false
  end

  test "an assignment serving none of a pool's active models is unusable" do
    observed_at = ~U[2026-05-30 09:20:00Z]
    pool = pool_fixture()
    assignment = usable_assignment(pool, observed_at)
    other_assignment_id = Ecto.UUID.generate()

    model_fixture(pool, %{
      exposed_model_id: "gpt-unserved",
      metadata: %{"source_assignment_ids" => [other_assignment_id]}
    })

    rule = alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    assert [%{action: :match, match_attrs: match}] =
             Alerts.evaluate_rule(rule, at: observed_at)

    assert match.safe_evidence_snapshot["usable_assignment_count"] == 0
    assert match.safe_evidence_snapshot["non_serving_assignment_count"] == 1
    assert assignment.assignment.id != other_assignment_id
  end

  test "api-key scoped circuit rows and closed-row noise never block a pool assignment" do
    observed_at = ~U[2026-05-30 09:20:00Z]
    pool = pool_fixture()
    assignment = usable_assignment(pool, observed_at)
    %{api_key: api_key} = active_api_key_fixture(pool)

    model_fixture(pool, %{
      exposed_model_id: "gpt-pool-wide",
      metadata: %{"source_assignment_ids" => [assignment.assignment.id]}
    })

    circuit_fixture(pool, assignment, "gpt-pool-wide", observed_at,
      api_key_id: api_key.id,
      next_probe_at: DateTime.add(observed_at, 60, :second)
    )

    circuit_fixture(pool, assignment, "gpt-pool-wide", observed_at,
      status: "closed",
      route_class: "proxy_compact",
      last_failure_at: observed_at
    )

    rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_no_usable_assignments",
        model: "gpt-pool-wide"
      )

    assert [%{action: :clear}] = Alerts.evaluate_rule(rule, at: observed_at)
  end

  test "alert projection mirrors routing for absent stale open nil-open and half-open rows" do
    observed_at = ~U[2026-05-30 09:20:00Z]

    scenarios = [
      {:absent, nil, :clear},
      {:stale_open,
       [
         next_probe_at: DateTime.add(observed_at, -60, :second),
         last_failure_at: DateTime.add(observed_at, -901, :second)
       ], :clear},
      {:future_open, [next_probe_at: DateTime.add(observed_at, 60, :second)], :match},
      {:nil_open, [next_probe_at: nil], :match},
      {:half_open_saturated,
       [
         status: "half_open",
         metadata: %{"probe_in_flight_count" => 1},
         updated_at: observed_at
       ], :match},
      {:half_open_saturated_stale,
       [
         status: "half_open",
         metadata: %{"probe_in_flight_count" => 1},
         updated_at: DateTime.add(observed_at, -60, :second),
         last_failure_at: DateTime.add(observed_at, -901, :second)
       ], :clear}
    ]

    for {name, circuit_attrs, expected_action} <- scenarios do
      pool = pool_fixture()
      assignment = usable_assignment(pool, observed_at)
      model_id = "gpt-state-#{name}"

      model_fixture(pool, %{
        exposed_model_id: model_id,
        metadata: %{"source_assignment_ids" => [assignment.assignment.id]}
      })

      if circuit_attrs do
        circuit_fixture(pool, assignment, model_id, observed_at, circuit_attrs)
      end

      rule =
        alert_rule_fixture(pool,
          rule_kind: "pool_no_usable_assignments",
          model: model_id
        )

      assert [%{action: ^expected_action}] = Alerts.evaluate_rule(rule, at: observed_at)
    end
  end

  test "low usable fires with one usable lane while total blackout belongs only to no usable" do
    observed_at = ~U[2026-05-30 09:20:00Z]
    pool = pool_fixture()
    assignments = for _index <- 1..3, do: usable_assignment(pool, observed_at)
    assignment_ids = Enum.map(assignments, & &1.assignment.id)

    model_fixture(pool, %{
      exposed_model_id: "gpt-low-boundary",
      metadata: %{"source_assignment_ids" => assignment_ids},
      source_assignment_count: 3
    })

    for assignment <- Enum.take(assignments, 2) do
      circuit_fixture(pool, assignment, "gpt-low-boundary", observed_at,
        next_probe_at: DateTime.add(observed_at, 60, :second)
      )
    end

    low_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_low_usable_assignments",
        model: "gpt-low-boundary",
        min_usable_assignments: 2
      )

    no_usable_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_no_usable_assignments",
        model: "gpt-low-boundary"
      )

    assert [%{action: :match, match_attrs: low_match}] =
             Alerts.evaluate_rule(low_rule, at: observed_at)

    assert low_match.safe_evidence_snapshot["usable_assignment_count"] == 1
    assert [%{action: :clear}] = Alerts.evaluate_rule(no_usable_rule, at: observed_at)

    circuit_fixture(pool, List.last(assignments), "gpt-low-boundary", observed_at,
      route_class: "proxy_compact",
      next_probe_at: DateTime.add(observed_at, 60, :second)
    )

    assert [%{action: :clear}] = Alerts.evaluate_rule(low_rule, at: observed_at)
    assert [%{action: :match}] = Alerts.evaluate_rule(no_usable_rule, at: observed_at)
  end

  test "unscoped route classes are worst-wins while a scoped healthy class stays usable" do
    observed_at = ~U[2026-05-30 09:20:00Z]
    pool = pool_fixture()
    assignment = usable_assignment(pool, observed_at)

    model_fixture(pool, %{
      exposed_model_id: "gpt-route-scope",
      metadata: %{"source_assignment_ids" => [assignment.assignment.id]}
    })

    circuit_fixture(pool, assignment, "gpt-route-scope", observed_at,
      route_class: "proxy_compact",
      next_probe_at: DateTime.add(observed_at, 60, :second)
    )

    unscoped_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_no_usable_assignments",
        model: "gpt-route-scope"
      )

    stream_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_no_usable_assignments",
        model: "gpt-route-scope",
        route_class: "proxy_stream"
      )

    assert [%{action: :match, match_attrs: match}] =
             Alerts.evaluate_rule(unscoped_rule, at: observed_at)

    assert match.safe_evidence_snapshot["circuit_blocked_route_classes"] == ["proxy_compact"]
    assert match.safe_evidence_snapshot["route_class_scope"] == "any"
    assert [%{action: :clear}] = Alerts.evaluate_rule(stream_rule, at: observed_at)
  end

  test "recent lapsed circuits remain blocked for three cadence observations and not a fourth" do
    pool = pool_fixture()
    assignment = usable_assignment(pool, ~U[2026-05-30 09:08:00Z])

    model_fixture(pool, %{
      exposed_model_id: "gpt-recency",
      metadata: %{"source_assignment_ids" => [assignment.assignment.id]}
    })

    circuit_fixture(pool, assignment, "gpt-recency", ~U[2026-05-30 09:08:00Z],
      next_probe_at: ~U[2026-05-30 09:09:00Z],
      last_failure_at: ~U[2026-05-30 09:08:00Z]
    )

    rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_no_usable_assignments",
        model: "gpt-recency"
      )

    for observed_at <- [
          ~U[2026-05-30 09:10:00Z],
          ~U[2026-05-30 09:15:00Z],
          ~U[2026-05-30 09:20:00Z]
        ] do
      assert [%{action: :match, match_attrs: match}] =
               Alerts.evaluate_rule(rule,
                 at: ~U[2026-05-30 09:10:00Z],
                 circuit_observed_at: observed_at
               )

      assert match.safe_evidence_snapshot["circuit_recency_seconds"] == 900
    end

    assert [%{action: :clear}] =
             Alerts.evaluate_rule(rule,
               at: ~U[2026-05-30 09:10:00Z],
               circuit_observed_at: ~U[2026-05-30 09:25:00Z]
             )
  end

  test "recency uses a closed interval and rejects circuit failures newer than observation time" do
    observed_at = ~U[2026-05-30 09:20:00Z]
    pool = pool_fixture()
    assignment = usable_assignment(pool, observed_at)

    model_fixture(pool, %{
      exposed_model_id: "gpt-boundary",
      metadata: %{"source_assignment_ids" => [assignment.assignment.id]}
    })

    state =
      circuit_fixture(pool, assignment, "gpt-boundary", observed_at,
        next_probe_at: ~U[2026-05-30 09:00:00Z],
        last_failure_at: ~U[2026-05-30 09:05:00Z]
      )

    rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_no_usable_assignments",
        model: "gpt-boundary"
      )

    assert [%{action: :match}] = Alerts.evaluate_rule(rule, at: observed_at)

    update_circuit!(state, last_failure_at: ~U[2026-05-30 09:04:59Z])
    assert [%{action: :clear}] = Alerts.evaluate_rule(rule, at: observed_at)

    update_circuit!(state, last_failure_at: ~U[2026-05-30 09:21:00Z])
    assert [%{action: :clear}] = Alerts.evaluate_rule(rule, at: observed_at)
  end

  test "pool-all match and clear candidates keep the evaluation-window clock" do
    evaluation_at = ~U[2026-05-30 09:10:00Z]
    circuit_observed_at = ~U[2026-05-30 09:20:00Z]
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)

    rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: "missing_evidence"
      )

    opts = [at: evaluation_at, circuit_observed_at: circuit_observed_at]

    assert [%{action: :match, match_attrs: %{matched_at: ^evaluation_at}}] =
             Alerts.evaluate_rule(rule, opts)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("10"),
                 credits: 90,
                 reset_at: DateTime.add(circuit_observed_at, 2, :hour),
                 observed_at: evaluation_at
               })
             ])

    assert [%{action: :clear, clear_attrs: %{cleared_at: ^evaluation_at}}] =
             Alerts.evaluate_rule(rule, opts)
  end

  test "blocked circuits do not change pool-all or upstream rule verdicts" do
    observed_at = ~U[2026-05-30 09:20:00Z]
    pool = pool_fixture()
    assignment = upstream_assignment_fixture(pool)

    model_fixture(pool, %{
      exposed_model_id: "gpt-unaffected-rules",
      metadata: %{"source_assignment_ids" => [assignment.assignment.id]}
    })

    circuit_fixture(pool, assignment, "gpt-unaffected-rules", observed_at,
      next_probe_at: DateTime.add(observed_at, 60, :second)
    )

    rules = [
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: "missing_evidence"
      ),
      alert_rule_fixture(pool,
        scope_type: "upstream_identity",
        rule_kind: "upstream_quota_threshold",
        threshold_used_percent: Decimal.new("99")
      ),
      alert_rule_fixture(pool,
        scope_type: "upstream_identity",
        rule_kind: "upstream_auth_state",
        target_state: "reauth_required"
      ),
      alert_rule_fixture(pool,
        scope_type: "upstream_identity",
        rule_kind: "upstream_saved_reset_banked_first_seen",
        severity: "info"
      )
    ]

    assert [[%{action: :match}], [%{action: :clear}], [%{action: :clear}], [%{action: :clear}]] =
             Enum.map(rules, &Alerts.evaluate_rule(&1, at: observed_at))
  end

  defp usable_assignment(pool, timestamp) do
    assignment = upstream_assignment_fixture(pool)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(assignment.identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("10"),
                 credits: 90,
                 reset_at: DateTime.add(timestamp, 2, :hour),
                 observed_at: timestamp
               })
             ])

    assignment
  end

  defp circuit_fixture(pool, assignment, model_identifier, timestamp, attrs) do
    attrs = Map.new(attrs)

    %RoutingCircuitState{}
    |> RoutingCircuitState.changeset(%{
      pool_id: pool.id,
      api_key_id: Map.get(attrs, :api_key_id),
      pool_upstream_assignment_id: assignment.assignment.id,
      upstream_identity_id: assignment.identity.id,
      model_identifier: model_identifier,
      route_class: Map.get(attrs, :route_class, "proxy_stream"),
      status: Map.get(attrs, :status, "open"),
      reason_code: "synthetic_test_failure",
      failure_count: 3,
      success_count: 0,
      opened_at: timestamp,
      next_probe_at: Map.get(attrs, :next_probe_at),
      last_failure_at: Map.get(attrs, :last_failure_at, timestamp),
      metadata: Map.get(attrs, :metadata, %{"probe_in_flight_count" => 0}),
      created_at: timestamp,
      updated_at: Map.get(attrs, :updated_at, timestamp)
    })
    |> Repo.insert!()
  end

  defp update_circuit!(state, attrs) do
    state
    |> RoutingCircuitState.changeset(Map.new(attrs))
    |> Repo.update!()
  end
end
