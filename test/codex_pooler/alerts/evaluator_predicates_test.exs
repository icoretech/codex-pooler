defmodule CodexPooler.Alerts.EvaluatorPredicatesTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [primary_quota_window_attrs: 1, weekly_quota_window_attrs: 1]

  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertRule
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  test "quota target states stay separate for all-assignment predicates" do
    timestamp = now()

    assert_quota_state_candidate("missing_evidence", [], timestamp)

    assert_quota_state_candidate(
      "stale",
      [
        primary_quota_window_attrs(%{
          freshness_state: "stale",
          reset_at: DateTime.add(timestamp, 1, :hour),
          observed_at: timestamp
        })
      ],
      timestamp
    )

    assert_quota_state_candidate(
      "weekly_only",
      [
        weekly_quota_window_attrs(%{
          reset_at: DateTime.add(timestamp, 7, :day),
          observed_at: timestamp
        })
      ],
      timestamp
    )

    assert_quota_state_candidate(
      "exhausted",
      [
        primary_quota_window_attrs(%{
          used_percent: Decimal.new("100"),
          credits: 0,
          reset_at: DateTime.add(timestamp, 1, :hour),
          observed_at: timestamp
        })
      ],
      timestamp
    )
  end

  test "fresh usable quota clears missing stale weekly-only and exhausted target predicates" do
    timestamp = now()
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

    for target_state <- ~w(missing_evidence stale weekly_only exhausted) do
      rule =
        alert_rule_fixture(pool,
          rule_kind: "pool_all_assignments_in_state",
          target_state: target_state
        )

      assert [%{action: :clear, clear_attrs: clear_attrs}] =
               Alerts.evaluate_rule(rule, at: timestamp)

      assert clear_attrs.dedupe_key =~ target_state
    end
  end

  test "credit-backed probe quota projection keeps a distinct state and reason" do
    timestamp = now()
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)

    assert {:ok, [_primary, _weekly]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("20"),
                 credits: 80,
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               }),
               weekly_quota_window_attrs(%{
                 used_percent: Decimal.new("100"),
                 credits: 25,
                 reset_at: DateTime.add(timestamp, 7, :day),
                 observed_at: timestamp
               })
             ])

    credit_rule = all_assignments_state_rule(pool, "credit_backed_probe")
    usable_rule = all_assignments_state_rule(pool, "usable")

    assert [%{action: :match, match_attrs: match}] =
             Alerts.evaluate_rule(credit_rule, at: timestamp)

    assert match.safe_evidence_snapshot["reason_code"] == "credit_backed_probe"
    assert match.safe_evidence_snapshot["state_counts"] == %{"credit_backed_probe" => 1}

    assert [%{action: :clear}] = Alerts.evaluate_rule(usable_rule, at: timestamp)
  end

  test "active rule evaluation reuses pool quota projections for the same pool" do
    timestamp = now()
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

    {_candidates, query_counts} =
      count_repo_commands(fn ->
        Alerts.evaluate_active_rules(at: timestamp)
      end)

    assert command_count(query_counts, "pool_upstream_assignments", "SELECT") == 1
    assert command_count(query_counts, "account_quota_windows", "SELECT") == 1
  end

  test "upstream quota threshold produces upstream-global metadata-only match candidates" do
    timestamp = now()
    pool = pool_fixture()
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               primary_quota_window_attrs(%{
                 used_percent: Decimal.new("88.6"),
                 credits: 12,
                 reset_at: DateTime.add(timestamp, 1, :hour),
                 observed_at: timestamp
               })
             ])

    rule =
      alert_rule_fixture(pool,
        scope_type: "upstream_identity",
        rule_kind: "upstream_quota_threshold",
        severity: "warning",
        window_selector: "account_primary",
        threshold_used_percent: Decimal.new("80")
      )

    assert [%{action: :match, match_attrs: match}] = Alerts.evaluate_rule(rule, at: timestamp)
    assert match.scope_type == "upstream_identity"
    assert match.pool_id == nil
    assert match.upstream_identity_id == identity.id
    assert match.severity == "warning"
    assert match.safe_evidence_snapshot.reason_code == "quota_threshold"
    assert match.safe_evidence_snapshot.window_selector == "account_primary"
    assert match.safe_evidence_snapshot.threshold_used_percent == "80"
    assert match.safe_evidence_snapshot.used_percent == 88.6
    assert match.safe_evidence_snapshot.pool_upstream_assignment_id == assignment.id
    assert [%{rule_id: rule_id, pool_id: pool_id, metadata: target_metadata}] = match.targets
    assert rule_id == rule.id
    assert pool_id == pool.id
    assert target_metadata["window_selector"] == "account_primary"
    assert match.dedupe_key =~ identity.id
    assert match.dedupe_key =~ "threshold:80"
  end

  test "upstream auth state predicates use persisted identity status only" do
    timestamp = now()
    pool = pool_fixture()
    %{identity: reauth} = upstream_assignment_fixture(pool, %{identity_status: "reauth_required"})

    %{identity: refresh_failed} =
      upstream_assignment_fixture(pool, %{identity_status: "refresh_failed"})

    reauth_rule =
      alert_rule_fixture(pool,
        scope_type: "upstream_identity",
        rule_kind: "upstream_auth_state",
        target_state: "reauth_required"
      )

    refresh_rule =
      alert_rule_fixture(pool,
        scope_type: "upstream_identity",
        rule_kind: "upstream_auth_state",
        target_state: "refresh_failed",
        severity: "warning"
      )

    reauth_candidates = Alerts.evaluate_rule(reauth_rule, at: timestamp)
    assert Enum.any?(reauth_candidates, &match?(%{action: :match}, &1))
    reauth_match = Enum.find(reauth_candidates, &(&1.action == :match)).match_attrs
    assert reauth_match.upstream_identity_id == reauth.id
    assert reauth_match.severity == "critical"
    assert reauth_match.safe_evidence_snapshot.reason_code == "reauth_required"

    refresh_candidates = Alerts.evaluate_rule(refresh_rule, at: timestamp)
    refresh_match = Enum.find(refresh_candidates, &(&1.action == :match)).match_attrs
    assert refresh_match.upstream_identity_id == refresh_failed.id
    assert refresh_match.severity == "warning"
    assert refresh_match.safe_evidence_snapshot.reason_code == "refresh_failed"
  end

  defp all_assignments_state_rule(pool, target_state) do
    %AlertRule{
      id: Ecto.UUID.generate(),
      pool_id: pool.id,
      scope_type: "pool",
      rule_kind: "pool_all_assignments_in_state",
      severity: "warning",
      target_state: target_state
    }
  end

  defp assert_quota_state_candidate(target_state, windows, timestamp) do
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)

    if windows != [] do
      assert {:ok, _windows} = QuotaWindows.upsert_quota_windows(identity, windows)
    end

    rule =
      alert_rule_fixture(pool,
        rule_kind: "pool_all_assignments_in_state",
        target_state: target_state
      )

    assert [%{action: :match, match_attrs: match}] = Alerts.evaluate_rule(rule, at: timestamp)
    assert match.safe_evidence_snapshot["reason_code"] == target_state
    assert match.safe_evidence_snapshot["state_counts"][target_state] == 1
  end

  defp count_repo_commands(fun) do
    parent = self()
    handler_id = "evaluator-predicates-test-#{System.unique_integer([:positive])}"

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

  defp command_name(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.upcase()
  end

  defp command_name(_query), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
