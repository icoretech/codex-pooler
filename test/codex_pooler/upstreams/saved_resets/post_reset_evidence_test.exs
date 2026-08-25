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
      window_kind: Keyword.get(opts, :window_kind, "secondary"),
      window_minutes: Keyword.get(opts, :window_minutes, 10_080),
      used_percent: Keyword.get(opts, :used_percent, Decimal.new("10")),
      reset_at: Keyword.get(opts, :reset_at, DateTime.add(@now, 2, :day)),
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: Keyword.get(opts, :source, "codex_usage_api"),
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

  test "model-scoped additional quota cannot confirm or reblock a consumed reset" do
    reserve_window =
      window(
        quota_key: "gpt_reserve",
        used_percent: Decimal.new("0")
      )
      |> Map.merge(%{
        quota_scope: "model",
        quota_family: "codex_model",
        model: "gpt-reserve",
        metered_feature: "base_model_inference"
      })

    assert PostResetEvidence.classify([reserve_window], @consumed_at, @now) == :pending

    account_mutation = %{
      reserve_window
      | quota_key: "account",
        quota_scope: "account",
        quota_family: "account"
    }

    assert PostResetEvidence.classify([account_mutation], @consumed_at, @now) == :confirmed
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

  test "a genuinely distinct exhausted current window remains fail-closed" do
    windows = [
      window(used_percent: Decimal.new("5")),
      window(
        used_percent: Decimal.new("100"),
        window_kind: "primary",
        window_minutes: 300,
        reset_at: DateTime.add(@now, 5, :hour)
      )
    ]

    assert PostResetEvidence.classify(windows, @consumed_at, @now) == :reblocked
  end

  test "obsolete duplicate-source rows cannot veto newer canonical usable evidence" do
    consumed_at = DateTime.add(@now, -20, :hour)
    stale_observed_at = DateTime.add(@now, -14, :hour)

    windows = [
      # Current canonical account evidence, both logical windows usable.
      window(used_percent: Decimal.new("26")),
      window(
        used_percent: Decimal.new("20"),
        window_kind: "primary",
        window_minutes: 300,
        reset_at: DateTime.add(@now, 5, :hour)
      ),
      # Historical post-consume observations from other sources, now obsolete:
      # they describe the same logical windows and an already-ended cycle.
      window(
        used_percent: Decimal.new("100"),
        source: "codex_rate_limit_event",
        observed_at: stale_observed_at,
        reset_at: DateTime.add(stale_observed_at, 2, :hour)
      ),
      window(
        used_percent: Decimal.new("100"),
        source: "codex_response_headers",
        window_kind: "primary",
        window_minutes: 300,
        observed_at: stale_observed_at,
        reset_at: DateTime.add(stale_observed_at, 1, :hour)
      )
    ]

    assert PostResetEvidence.classify(windows, consumed_at, @now) == :confirmed
  end

  test "a still-fresh pre-consume exhausted row cannot eclipse post-consume usable evidence" do
    # The pre-consume row is still fresh, so it competes in the logical-window
    # fold; it must not eat the newer usable post-consume observation and leave
    # the account pending.
    consumed_at = DateTime.add(@now, -5, :minute)

    windows = [
      window(used_percent: Decimal.new("100"), observed_at: DateTime.add(@now, -10, :minute)),
      window(used_percent: Decimal.new("0"))
    ]

    assert PostResetEvidence.classify(windows, consumed_at, @now) == :confirmed
  end

  test "a newer unparseable exhausted row keeps the reset pending like routing" do
    # Routing's canonical fold ranks the newer unknown-precision exhausted row;
    # classification must fold the same way and then fail closed on it, instead
    # of discarding it early and declaring recovery routing cannot see.
    consumed_at = DateTime.add(@now, -10, :minute)

    windows = [
      window(
        used_percent: Decimal.new("5"),
        observed_at: DateTime.add(@now, -5, :minute)
      ),
      window(used_percent: Decimal.new("100"), source_precision: "unknown")
    ]

    assert PostResetEvidence.classify(windows, consumed_at, @now) == :pending
  end

  test "a current canonical exhausted window still reblocks over obsolete rows" do
    consumed_at = DateTime.add(@now, -20, :hour)
    stale_observed_at = DateTime.add(@now, -14, :hour)

    windows = [
      window(used_percent: Decimal.new("100")),
      window(
        used_percent: Decimal.new("10"),
        source: "codex_rate_limit_event",
        observed_at: stale_observed_at,
        reset_at: DateTime.add(stale_observed_at, 2, :hour)
      )
    ]

    assert PostResetEvidence.classify(windows, consumed_at, @now) == :reblocked
  end
end
