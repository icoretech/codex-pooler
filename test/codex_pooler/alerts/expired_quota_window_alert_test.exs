defmodule CodexPooler.Alerts.Evaluation.ExpiredQuotaWindowAlertTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Alerts
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.ReadModel
  alias CodexPooler.Upstreams.Quota.Windows

  # Degraded shape: the Usage API poll stopped succeeding, so every row of the
  # weekly window aged past the freshness TTL, and a rate-limit-event row of the
  # same window still describes a cycle that ended weeks ago at 100%. The
  # ended cycle says nothing about the running one, so every consumer must see
  # what it would see if that row did not exist (as after the retention
  # prune): the stale running-cycle weekly row with headroom, which the
  # weekly-only probe accepts without freshness. An exhausted-state rule must
  # not match, and routing must not stay blocked on the ended cycle.
  test "an ended cycle's exhaustion neither fires the exhausted rule nor blocks the weekly-only probe" do
    now = now()
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)

    write_weekly_rows!(identity, now,
      event: [used: "100", reset_at: DateTime.add(now, -60, :day), observed_at: DateTime.add(now, -67, :day)],
      usage: [used: "30", reset_at: DateTime.add(now, 3, :day), observed_at: DateTime.add(now, -2, :hour)]
    )

    assert_match!(pool, "weekly_only", now)
    assert [%{action: :clear}] = evaluate(pool, "exhausted", now)
    assert [%{state: :weekly_only_evidence}] = ReadModel.account_summaries_for_pool_ids([pool.id], now)
    assert %{eligible?: true, routing_state: :weekly_only_probe} = Windows.routing_quota_eligibility(identity, at: now, account_only: true)
  end

  # Control: an all-stale exhausted report of the running cycle keeps firing
  # the exhausted rule and keeps routing blocked, so the rule above is not a
  # blanket suppression.
  test "a stale exhausted report of the running cycle still fires the exhausted rule" do
    now = now()
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)
    running_reset = DateTime.add(now, 3, :day)

    write_weekly_rows!(identity, now,
      event: [used: "100", reset_at: running_reset, observed_at: DateTime.add(now, -2, :hour)],
      usage: [used: "30", reset_at: running_reset, observed_at: DateTime.add(now, -2, :hour)]
    )

    assert_match!(pool, "exhausted", now)
    assert [%{action: :clear}] = evaluate(pool, "stale", now)
    assert [%{state: :exhausted}] = ReadModel.account_summaries_for_pool_ids([pool.id], now)
    assert %{eligible?: false} = Windows.routing_quota_eligibility(identity, at: now, account_only: true)
  end

  defp assert_match!(pool, target_state, now) do
    assert [%{action: :match, match_attrs: match}] = evaluate(pool, target_state, now)
    assert match.safe_evidence_snapshot["reason_code"] == target_state
    assert match.safe_evidence_snapshot["state_counts"] == %{target_state => 1}
  end

  defp evaluate(pool, target_state, now) do
    pool
    |> alert_rule_fixture(rule_kind: "pool_all_assignments_in_state", target_state: target_state)
    |> Alerts.evaluate_rule(at: now)
  end

  defp write_weekly_rows!(identity, now, rows) do
    attrs =
      for {source, _row} <- rows do
        %{
          quota_key: "account",
          quota_scope: "account",
          quota_family: "account",
          window_kind: "secondary",
          window_minutes: 10_080,
          used_percent: Decimal.new(rows[source][:used]),
          reset_at: DateTime.add(now, 3, :day),
          source: source_name(source),
          source_precision: "observed",
          freshness_state: "fresh",
          last_sync_at: now,
          observed_at: now
        }
      end

    assert {:ok, [_, _]} = Windows.upsert_quota_windows(identity, attrs)

    for {source, row} <- rows do
      assert {1, _} =
               from(window in AccountQuotaWindow,
                 where: window.upstream_identity_id == ^identity.id and window.source == ^source_name(source)
               )
               |> Repo.update_all(set: [reset_at: row[:reset_at], observed_at: row[:observed_at], last_sync_at: row[:observed_at]])
    end
  end

  defp source_name(:event), do: "codex_rate_limit_event"
  defp source_name(:usage), do: "codex_usage_api"

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
