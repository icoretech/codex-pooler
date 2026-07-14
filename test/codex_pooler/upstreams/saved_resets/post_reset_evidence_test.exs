defmodule CodexPooler.Upstreams.SavedResets.PostResetEvidenceTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.SavedResets.PostResetEvidence

  @now ~U[2026-07-14 03:30:00.000000Z]
  # The credit was consumed ten minutes ago.
  @consumed_at ~U[2026-07-14 03:20:00.000000Z]

  defp window(opts) do
    observed_at = Keyword.get(opts, :observed_at, @now)

    %AccountQuotaWindow{
      quota_key: Keyword.get(opts, :quota_key, "account"),
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Keyword.get(opts, :used_percent, Decimal.new("10")),
      reset_at: Keyword.get(opts, :reset_at, DateTime.add(@now, 2, :day)),
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: "codex_usage_api",
      source_precision: Keyword.get(opts, :source_precision, "observed"),
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh"
    }
  end

  test "fresh usable post-consume account evidence confirms" do
    windows = [window(used_percent: Decimal.new("0"))]
    assert PostResetEvidence.classify(windows, @consumed_at, @now) == :confirmed
  end

  test "fresh exhausted post-consume account evidence reblocks" do
    windows = [window(used_percent: Decimal.new("100"))]
    assert PostResetEvidence.classify(windows, @consumed_at, @now) == :reblocked
  end

  test "an omitted account window (stale observed_at) leaves the reset pending" do
    # The provider omitted the account descriptor, so the stored window keeps its
    # pre-consume observation time — exactly the deadlock shape.
    windows = [
      window(
        used_percent: Decimal.new("100"),
        observed_at: DateTime.add(@consumed_at, -5, :minute)
      )
    ]

    assert PostResetEvidence.classify(windows, @consumed_at, @now) == :pending
  end

  test "no account windows at all leaves the reset pending" do
    assert PostResetEvidence.classify([], @consumed_at, @now) == :pending
  end

  test "evidence observed exactly at consume time is accepted" do
    windows = [window(used_percent: Decimal.new("0"), observed_at: @consumed_at)]
    assert PostResetEvidence.classify(windows, @consumed_at, @now) == :confirmed
  end

  test "inferred precision still counts as explicit provider evidence" do
    windows = [window(used_percent: Decimal.new("0"), source_precision: "inferred")]
    assert PostResetEvidence.classify(windows, @consumed_at, @now) == :confirmed
  end

  test "unknown precision is not parse-safe enough to transition" do
    windows = [window(used_percent: Decimal.new("0"), source_precision: "unknown")]
    assert PostResetEvidence.classify(windows, @consumed_at, @now) == :pending
  end

  test "non-account windows are ignored" do
    windows = [
      window(quota_key: "model", used_percent: Decimal.new("0")),
      window(quota_key: "feature", used_percent: Decimal.new("0"))
    ]

    assert PostResetEvidence.classify(windows, @consumed_at, @now) == :pending
  end

  test "an exhausted sibling reblocks even when another window is usable" do
    # A single blocking window still excludes the identity from routing, so the
    # reset is not confirmed just because a different window is usable.
    windows = [
      window(used_percent: Decimal.new("100")),
      window(used_percent: Decimal.new("5"))
    ]

    assert PostResetEvidence.classify(windows, @consumed_at, @now) == :reblocked
  end
end
