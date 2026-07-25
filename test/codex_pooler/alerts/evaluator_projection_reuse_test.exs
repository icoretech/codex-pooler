defmodule CodexPooler.Alerts.Evaluation.EvaluatorProjectionReuseTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [primary_quota_window_attrs: 1]

  alias CodexPooler.Alerts
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.AlertEvaluationWorker
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  test "shared-cache evaluation reuses pool projections (not the production path)" do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("44"),
                 credits: 56,
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])

    alert_rule_fixture(pool, rule_kind: "pool_no_usable_assignments")

    alert_rule_fixture(pool,
      rule_kind: "pool_low_usable_assignments",
      min_usable_assignments: 2
    )

    alert_rule_fixture(pool,
      rule_kind: "pool_all_assignments_in_state",
      target_state: "missing_evidence"
    )

    # Production evaluates one rule per Oban job; this shared-cache path is only
    # the direct context API and must not be used to infer production batching.
    {_candidates, query_counts} =
      count_repo_commands(fn ->
        Alerts.evaluate_active_rules(at: timestamp)
      end)

    assert command_count(query_counts, "pool_upstream_assignments", "SELECT") == 1
    assert command_count(query_counts, "account_quota_windows", "SELECT") == 1
    assert command_count(query_counts, "models", "SELECT") == 1
    assert command_count(query_counts, "routing_circuit_states", "SELECT") == 0
  end

  test "shared cache cannot poison a pool rule with an upstream projection" do
    timestamp = ~U[2026-05-30 09:20:00Z]
    pool = pool_fixture()
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    make_usable(identity, timestamp)

    model_fixture(pool, %{
      exposed_model_id: "gpt-cache-poison",
      metadata: %{"source_assignment_ids" => [assignment.id]}
    })

    circuit_fixture(pool, assignment, identity, "gpt-cache-poison", timestamp)

    alert_rule_fixture(pool,
      rule_kind: "upstream_quota_threshold",
      scope_type: "upstream_identity",
      threshold_used_percent: Decimal.new("99"),
      created_at: DateTime.add(timestamp, -2, :second),
      updated_at: DateTime.add(timestamp, -2, :second)
    )

    alert_rule_fixture(pool,
      rule_kind: "pool_no_usable_assignments",
      model: "gpt-cache-poison",
      created_at: DateTime.add(timestamp, -1, :second),
      updated_at: DateTime.add(timestamp, -1, :second)
    )

    candidates = Alerts.evaluate_active_rules(at: timestamp)

    assert Enum.any?(candidates, fn
             %{rule_kind: "pool_no_usable_assignments", action: :match} -> true
             _candidate -> false
           end)
  end

  test "unresolved and no-active-model projections never select circuit rows" do
    timestamp = ~U[2026-05-30 09:20:00Z]

    unresolved_pool = pool_fixture()

    %{identity: unresolved_identity, assignment: unresolved_assignment} =
      upstream_assignment_fixture(unresolved_pool)

    make_usable(unresolved_identity, timestamp)

    model_fixture(unresolved_pool, %{
      exposed_model_id: "gpt-known",
      metadata: %{"source_assignment_ids" => [unresolved_assignment.id]}
    })

    circuit_fixture(
      unresolved_pool,
      unresolved_assignment,
      unresolved_identity,
      "gpt-missing",
      timestamp
    )

    unresolved_rule =
      alert_rule_fixture(unresolved_pool,
        rule_kind: "pool_no_usable_assignments",
        model: "gpt-missing"
      )

    {_candidates, unresolved_counts} =
      count_repo_commands(fn -> Alerts.evaluate_rule(unresolved_rule, at: timestamp) end)

    assert_budget(unresolved_counts, 0, 1)

    no_models_pool = pool_fixture()

    %{identity: no_models_identity, assignment: no_models_assignment} =
      upstream_assignment_fixture(no_models_pool)

    make_usable(no_models_identity, timestamp)

    model_fixture(no_models_pool, %{
      exposed_model_id: "gpt-retired",
      status: "retired",
      metadata: %{"source_assignment_ids" => [no_models_assignment.id]}
    })

    circuit_fixture(
      no_models_pool,
      no_models_assignment,
      no_models_identity,
      "gpt-retired",
      timestamp
    )

    no_models_rule =
      alert_rule_fixture(no_models_pool, rule_kind: "pool_no_usable_assignments")

    {_candidates, no_models_counts} =
      count_repo_commands(fn -> Alerts.evaluate_rule(no_models_rule, at: timestamp) end)

    assert_budget(no_models_counts, 0, 1)
  end

  test "scheduled evaluation pays a bounded per-rule query budget on the worker path" do
    timestamp = ~U[2026-05-30 09:20:00Z]
    pool = pool_fixture()

    assignments =
      for index <- 1..3 do
        %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
        make_usable(identity, timestamp)
        {index, identity, assignment}
      end

    assignment_ids =
      Enum.map(assignments, fn {_index, _identity, assignment} -> assignment.id end)

    model_fixture(pool, %{
      exposed_model_id: "gpt-budget",
      metadata: %{"source_assignment_ids" => assignment_ids},
      source_assignment_count: 3
    })

    for {_index, identity, assignment} <- assignments do
      circuit_fixture(pool, assignment, identity, "gpt-budget", timestamp)
    end

    first_pool_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_no_usable_assignments",
        model: "gpt-budget"
      )

    upstream_rule =
      alert_rule_fixture(pool,
        rule_kind: "upstream_quota_threshold",
        scope_type: "upstream_identity",
        threshold_used_percent: Decimal.new("99")
      )

    assert {:ok, %{inserted: jobs, errors: []}} =
             Jobs.enqueue_alert_evaluations_for_active_rules(
               now: timestamp,
               trigger_kind: "scheduled"
             )

    counts_by_rule =
      Map.new(jobs, fn job ->
        {_result, counts} =
          count_repo_commands(fn ->
            perform_job(AlertEvaluationWorker, job.args, attempted_at: timestamp)
          end)

        {job.args["alert_rule_id"], counts}
      end)

    assert_budget(Map.fetch!(counts_by_rule, first_pool_rule.id), 1, 1)
    assert_budget(Map.fetch!(counts_by_rule, upstream_rule.id), 0, 0)

    second_pool_rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_no_usable_assignments",
        model: "gpt-budget",
        route_class: "proxy_stream"
      )

    Repo.delete_all(Oban.Job)

    assert {:ok, %{inserted: jobs, errors: []}} =
             Jobs.enqueue_alert_evaluations_for_active_rules(
               now: DateTime.add(timestamp, 300, :second),
               trigger_kind: "scheduled"
             )

    pool_rule_ids = MapSet.new([first_pool_rule.id, second_pool_rule.id])

    pool_counts =
      jobs
      |> Enum.filter(&MapSet.member?(pool_rule_ids, &1.args["alert_rule_id"]))
      |> Enum.map(fn job ->
        {_result, counts} =
          count_repo_commands(fn ->
            perform_job(
              AlertEvaluationWorker,
              job.args,
              attempted_at: DateTime.add(timestamp, 300, :second)
            )
          end)

        counts
      end)

    assert Enum.sum(Enum.map(pool_counts, &command_count(&1, "models", "SELECT"))) == 2

    assert Enum.sum(Enum.map(pool_counts, &command_count(&1, "routing_circuit_states", "SELECT"))) ==
             2
  end

  test "a direct pool projection selects only the four budgeted sources" do
    timestamp = ~U[2026-05-30 09:20:00Z]
    pool = pool_fixture()
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    make_usable(identity, timestamp)

    model_fixture(pool, %{
      exposed_model_id: "gpt-exact-budget",
      metadata: %{"source_assignment_ids" => [assignment.id]}
    })

    circuit_fixture(pool, assignment, identity, "gpt-exact-budget", timestamp)

    rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_no_usable_assignments",
        model: "gpt-exact-budget"
      )

    {_candidates, counts} =
      count_repo_commands(fn -> Alerts.evaluate_rule(rule, at: timestamp) end)

    assert_budget(counts, 1, 1)

    assert select_sources(counts) ==
             MapSet.new([
               "account_quota_windows",
               "models",
               "pool_upstream_assignments",
               "routing_circuit_states"
             ])
  end

  defp assert_budget(counts, circuit_count, model_count) do
    assert command_count(counts, "pool_upstream_assignments", "SELECT") == 1
    assert command_count(counts, "account_quota_windows", "SELECT") == 1
    assert command_count(counts, "routing_circuit_states", "SELECT") == circuit_count
    assert command_count(counts, "models", "SELECT") == model_count
  end

  defp make_usable(identity, timestamp) do
    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("10"),
                 credits: 90,
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])
  end

  defp circuit_fixture(pool, assignment, identity, model_identifier, timestamp) do
    %RoutingCircuitState{}
    |> RoutingCircuitState.changeset(%{
      pool_id: pool.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      model_identifier: model_identifier,
      route_class: "proxy_stream",
      status: "open",
      reason_code: "synthetic_test_failure",
      failure_count: 3,
      success_count: 0,
      opened_at: timestamp,
      next_probe_at: DateTime.add(timestamp, 60, :second),
      last_failure_at: timestamp,
      metadata: %{"probe_in_flight_count" => 0},
      created_at: timestamp,
      updated_at: timestamp
    })
    |> Repo.insert!()
  end

  defp count_repo_commands(fun) do
    parent = self()
    handler_id = "evaluator-projection-reuse-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            send(parent, {handler_id, metadata[:source], command_name(metadata[:query])})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_commands(handler_id, %{})}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_commands(handler_id, commands) do
    receive do
      {^handler_id, source, command} ->
        key = {source, command}
        drain_repo_commands(handler_id, Map.update(commands, key, 1, &(&1 + 1)))
    after
      0 -> commands
    end
  end

  defp command_count(commands, source, command), do: Map.get(commands, {source, command}, 0)

  defp select_sources(commands) do
    commands
    |> Enum.flat_map(fn
      {{source, "SELECT"}, count} when is_binary(source) and count > 0 -> [source]
      {_key, _count} -> []
    end)
    |> MapSet.new()
  end

  defp command_name(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.upcase()
  end

  defp command_name(_query), do: nil
end
