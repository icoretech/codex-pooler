defmodule CodexPooler.Upstreams.Quota.WindowSelectorTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.WindowSelector

  @as_of ~U[2026-07-09 15:45:00Z]

  test "prefers measured account evidence over a later zero-capacity usage outlier" do
    outlier =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("0"),
        reset_at: DateTime.add(@as_of, 5, :hour),
        observed_at: DateTime.add(@as_of, 60, :second)
      )

    measured =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("6"),
        reset_at: DateTime.add(@as_of, 2, :hour),
        observed_at: @as_of
      )

    assert WindowSelector.best_account_window([outlier, measured], :primary_5h, @as_of) ==
             measured
  end

  test "keeps the only reset-bearing zero-capacity account evidence visible" do
    outlier =
      account_window(
        active_limit: 0,
        credits: 0,
        used_percent: Decimal.new("0"),
        reset_at: DateTime.add(@as_of, 5, :hour)
      )

    assert WindowSelector.best_account_window([outlier], :primary_5h, @as_of) == outlier
  end

  test "prefers usable monthly primary over usable 5h primary for routing selection" do
    primary_5h =
      account_window(
        used_percent: Decimal.new("6"),
        reset_at: DateTime.add(@as_of, 2, :hour)
      )

    monthly =
      account_window(
        window_minutes: 43_200,
        active_limit: 4_018,
        credits: 3_817,
        used_percent: Decimal.new("5"),
        reset_at: DateTime.add(@as_of, 14, :day)
      )

    assert WindowSelector.best_account_primary_variant([primary_5h, monthly], @as_of) ==
             monthly
  end

  test "does not let an unusable monthly outlier hide a usable 5h primary" do
    primary_5h =
      account_window(
        used_percent: Decimal.new("6"),
        reset_at: DateTime.add(@as_of, 2, :hour)
      )

    monthly_outlier =
      account_window(
        window_minutes: 43_200,
        active_limit: nil,
        credits: 3_817,
        used_percent: Decimal.new("100"),
        reset_at: DateTime.add(@as_of, 14, :day),
        observed_at: DateTime.add(@as_of, 60, :second)
      )

    assert WindowSelector.best_account_primary_variant([monthly_outlier, primary_5h], @as_of) ==
             primary_5h
  end

  test "a fresh new-cycle window supersedes stale prior-cycle rows in the logical merge" do
    # Live incident shape: a stale rate-limit-event row at 94% from the ended
    # cycle was outranking the fresh 0% rows of the restarted cycle by pressure,
    # showing 6% remaining for a genuinely unused account.
    stale_prior_cycle =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        source: "codex_rate_limit_event",
        merge_precedence: 90,
        used_percent: Decimal.new("94"),
        reset_at: DateTime.add(@as_of, 2, :day),
        observed_at: DateTime.add(@as_of, -7, :hour)
      )

    fresh_new_cycle =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new("0"),
        reset_at: DateTime.add(@as_of, 7, :day),
        observed_at: DateTime.add(@as_of, -60, :second)
      )

    assert WindowSelector.logical_windows([stale_prior_cycle, fresh_new_cycle], @as_of) == [
             fresh_new_cycle
           ]
  end

  test "an all-stale exhausted group keeps its pessimistic row" do
    # No fresh new-cycle evidence: fail-closed pessimism is preserved.
    stale_exhausted =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new("100"),
        reset_at: DateTime.add(@as_of, 2, :day),
        observed_at: DateTime.add(@as_of, -4, :hour)
      )

    stale_lower =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        source: "codex_response_headers",
        merge_precedence: 80,
        used_percent: Decimal.new("77"),
        reset_at: DateTime.add(@as_of, 2, :day),
        observed_at: DateTime.add(@as_of, -10, :hour)
      )

    assert WindowSelector.logical_windows([stale_exhausted, stale_lower], @as_of) == [
             stale_exhausted
           ]
  end

  test "same-cycle rows with countdown jitter are not rejected" do
    # Resets within the margin describe the same running cycle.
    fresh_zero =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new("0"),
        reset_at: DateTime.add(@as_of, 7, :day),
        observed_at: DateTime.add(@as_of, -60, :second)
      )

    jittered =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        source: "codex_response_headers",
        merge_precedence: 80,
        used_percent: Decimal.new("12"),
        reset_at: DateTime.add(@as_of, 7, :day) |> DateTime.add(-120, :second),
        observed_at: DateTime.add(@as_of, -30, :second)
      )

    # Both survive the cycle filter; the winner is chosen by the normal score
    # (pressure prefers the measured 12%).
    assert WindowSelector.logical_windows([fresh_zero, jittered], @as_of) == [jittered]
  end

  test "fresh exhausted runtime evidence outranks usable usage evidence in one logical window" do
    usage =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new("96"),
        reset_at: DateTime.add(@as_of, 7, :day),
        observed_at: DateTime.add(@as_of, -30, :second)
      )

    exhausted_headers =
      account_window(
        window_kind: "secondary",
        window_minutes: 10_080,
        source: "codex_response_headers",
        merge_precedence: 80,
        used_percent: Decimal.new("100"),
        reset_at: DateTime.add(@as_of, 3, :day),
        observed_at: @as_of
      )

    assert WindowSelector.logical_windows([usage, exhausted_headers], @as_of) == [
             exhausted_headers
           ]
  end

  test "anchored runtime Spark evidence remains selected over newer floating usage evidence" do
    floating_usage =
      spark_window(
        source: "codex_usage_api",
        merge_precedence: 60,
        used_percent: Decimal.new("0"),
        reset_at: ~U[2026-07-28 12:10:00Z],
        observed_at: DateTime.add(@as_of, -10, :second),
        metadata: %{"reset_state" => "floating", "reset_after_seconds" => 604_800}
      )

    anchored_runtime =
      spark_window(
        source: "codex_response_headers",
        merge_precedence: 80,
        used_percent: Decimal.new("12"),
        reset_at: ~U[2026-07-26 12:06:16Z],
        observed_at: DateTime.add(@as_of, -30, :second)
      )

    assert WindowSelector.logical_windows([floating_usage, anchored_runtime], @as_of) == [
             anchored_runtime
           ]
  end

  test "codex02 and codex03 floating Spark evidence remains selected without an anchored row" do
    for reset_at <- [~U[2026-07-28 12:10:00Z], ~U[2026-07-28 12:14:00Z]] do
      floating_usage =
        spark_window(
          used_percent: Decimal.new("0"),
          reset_at: reset_at,
          metadata: %{"reset_state" => "floating", "reset_after_seconds" => 604_800}
        )

      assert WindowSelector.logical_windows([floating_usage], @as_of) == [floating_usage]
    end
  end

  defp account_window(attrs) do
    observed_at = Keyword.get(attrs, :observed_at, @as_of)

    struct!(
      AccountQuotaWindow,
      Keyword.merge(
        [
          quota_key: "account",
          quota_scope: "account",
          quota_family: "account",
          window_kind: "primary",
          window_minutes: 300,
          source: "codex_usage_api",
          source_precision: "observed",
          freshness_state: "fresh",
          merge_precedence: 60,
          observed_at: observed_at,
          last_sync_at: observed_at,
          updated_at: observed_at,
          metadata: %{}
        ],
        attrs
      )
    )
  end

  defp spark_window(attrs) do
    observed_at = Keyword.get(attrs, :observed_at, @as_of)

    struct!(
      AccountQuotaWindow,
      Keyword.merge(
        [
          quota_key: "codex_spark",
          quota_scope: "model",
          quota_family: "codex_model",
          model: "gpt-5.3-codex-spark",
          window_kind: "secondary",
          window_minutes: 10_080,
          source: "codex_usage_api",
          source_precision: "observed",
          freshness_state: "fresh",
          merge_precedence: 60,
          observed_at: observed_at,
          last_sync_at: observed_at,
          updated_at: observed_at,
          metadata: %{}
        ],
        attrs
      )
    )
  end
end
