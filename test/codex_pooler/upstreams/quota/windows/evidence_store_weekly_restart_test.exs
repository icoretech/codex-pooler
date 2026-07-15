defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStoreWeeklyRestartTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows

  # Production shape while the provider's anchored 5h windows are suspended
  # (announced as temporary on 2026-07-13): a restarted weekly account arrives
  # from the usage endpoint as a weak zero (no active limit or credits) whose
  # relative reset is recomputed at response time, so reset_at slides forward in
  # step with each observation. A cached or replayed body keeps a fixed reset_at
  # instead.

  @window_seconds 10_080 * 60

  defp identity! do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    identity
  end

  defp usage_row!(identity, observed_at, used_percent, opts \\ []) do
    reset_at = Keyword.get(opts, :reset_at, DateTime.add(observed_at, 5, :day))

    Windows.record_evidence(
      identity,
      %{
        quota_key: "account",
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new(to_string(used_percent)),
        reset_at: reset_at,
        observed_at: observed_at,
        last_sync_at: observed_at,
        source: "codex_usage_api",
        source_precision: "observed",
        quota_scope: "account",
        quota_family: "account",
        freshness_state: "fresh"
      },
      observed_at
    )
  end

  defp exhausted_row!(identity, observed_at, opts \\ []),
    do: usage_row!(identity, observed_at, 100, opts)

  defp floating_zero(observed_at, opts \\ []) do
    reset_at = Keyword.get(opts, :reset_at, DateTime.add(observed_at, @window_seconds, :second))

    %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new("0"),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      metadata: %{"reset_after_seconds" => @window_seconds}
    }
  end

  defp account_row(identity) do
    Repo.one(
      from w in AccountQuotaWindow,
        where:
          w.upstream_identity_id == ^identity.id and w.quota_key == "account" and
            w.window_kind == "secondary" and w.source == "codex_usage_api"
    )
  end

  test "sliding live restart observations converge an exhausted weekly account" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = exhausted_row!(identity, t0)

    # First live zero: quarantined, but tracked as a restart candidate.
    t1 = DateTime.add(t0, 300, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t1), t1)
    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("100")) == :eq

    # Second live zero after the confirmation span, reset advanced in step with
    # observation time: the restart is confirmed and the row converges to 0%.
    t2 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t2), t2)
    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
    assert DateTime.compare(row.observed_at, t2) == :eq
  end

  test "a cached same-cycle body never clears the exhausted row" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    # Existing exhausted cycle resets in 5 days.
    assert {:ok, _row} = exhausted_row!(identity, t0)

    # A cached/replayed body carries the OLD cycle's reset: a zero that claims
    # the account restarted while still pointing at the current cycle's reset
    # is contradictory and must stay quarantined no matter how often it repeats.
    same_cycle_reset = DateTime.add(t0, 5, :day)
    t1 = DateTime.add(t0, 300, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t1, reset_at: same_cycle_reset), t1)

    t2 = DateTime.add(t1, 240, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t2, reset_at: same_cycle_reset), t2)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("100")) == :eq
  end

  test "a zero inside the confirmation span keeps waiting without resetting the clock" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = exhausted_row!(identity, t0)

    t1 = DateTime.add(t0, 300, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t1), t1)

    # One minute later: consistent but span not reached — still 100%.
    t2 = DateTime.add(t1, 60, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t2), t2)
    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("100")) == :eq

    # Two more minutes (3 minutes after the FIRST candidate): confirmed. If the
    # intermediate observation had replaced the candidate, the span would never
    # be reached under minute-by-minute reconciliation.
    t3 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t3), t3)
    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
  end

  test "anchored zeros converge once the exhausted cycle's own reset time has passed" do
    # Future-proof for the anchored 5h shape returning: the reset does not
    # slide, but the canonical itself declared the cycle over, so a candidate-
    # confirmed zero across the span converges it.
    t0 = DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.truncate(:microsecond)
    identity = identity!()
    # The exhausted row's own reset passed an hour ago.
    assert {:ok, _row} = exhausted_row!(identity, t0, reset_at: DateTime.add(t0, 1, :hour))

    t1 = DateTime.utc_now() |> DateTime.add(-6, :minute) |> DateTime.truncate(:microsecond)
    anchored_reset = DateTime.add(t1, @window_seconds, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t1, reset_at: anchored_reset), t1)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("100")) == :eq

    t2 = DateTime.add(t1, 240, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t2, reset_at: anchored_reset), t2)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
  end

  test "a forward-anchored new cycle converges while the exhausted cycle has not ended" do
    # Production shape once the restarted window anchors (first request of the
    # new cycle, often from another deployment sharing the account): the reset
    # is fixed BEYOND the exhausted row's own reset. Only the provider can mint
    # that anchor after the new cycle began, so a zero holding the same forward
    # anchor across the span converges even though nothing slides.
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    # Existing exhausted cycle would reset in 5 days.
    assert {:ok, _row} = exhausted_row!(identity, t0)

    t1 = DateTime.add(t0, 300, :second)
    forward_anchor = DateTime.add(t1, @window_seconds, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t1, reset_at: forward_anchor), t1)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("100")) == :eq

    # Same anchor one minute later: span not reached, candidate must be kept.
    t2 = DateTime.add(t1, 60, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t2, reset_at: forward_anchor), t2)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("100")) == :eq

    # Same anchor past the confirmation span: the new cycle is confirmed.
    t3 = DateTime.add(t1, 240, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t3, reset_at: forward_anchor), t3)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
    assert DateTime.compare(row.reset_at, forward_anchor) == :eq
  end

  test "sliding live zeroes converge a non-exhausted weekly account" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = usage_row!(identity, t0, 31)

    # The first provider zero starts confirmation without immediately lowering
    # a still-usable canonical row.
    t1 = DateTime.add(t0, 300, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t1), t1)
    assert Decimal.compare(account_row(identity).used_percent, Decimal.new("31")) == :eq

    # Repeated live evidence inside the confirmation span keeps waiting.
    t2 = DateTime.add(t1, 60, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t2), t2)
    assert Decimal.compare(account_row(identity).used_percent, Decimal.new("31")) == :eq

    # Once the floating reset advances with observations across the span, the
    # same transition that production reported converges to 0% used.
    t3 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t3), t3)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
    assert DateTime.compare(row.observed_at, t3) == :eq
  end

  test "repeated cached zeroes cannot lower a non-exhausted weekly account" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    fixed_reset = DateTime.add(t0, 5, :day)
    assert {:ok, _row} = usage_row!(identity, t0, 31, reset_at: fixed_reset)

    for minute <- 1..16 do
      observed_at = DateTime.add(t0, minute, :minute)

      assert {:ok, _row} =
               Windows.record_evidence(
                 identity,
                 floating_zero(observed_at, reset_at: fixed_reset),
                 observed_at
               )
    end

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("31")) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  test "repeated live zeroes keep an accepted weekly reset fresh beyond the ttl" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t0), t0)

    for minute <- 1..16 do
      observed_at = DateTime.add(t0, minute, :minute)

      assert {:ok, _row} =
               Windows.record_evidence(identity, floating_zero(observed_at), observed_at)

      assert Evidence.current_freshness_state(account_row(identity), observed_at) == "fresh"
    end

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
    assert DateTime.diff(row.observed_at, t0, :minute) >= 12
  end

  test "live zeroes recover an already stale accepted weekly reset" do
    t0 = DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t0), t0)

    stale_at = DateTime.add(t0, 16, :minute)
    assert Evidence.current_freshness_state(account_row(identity), stale_at) == "stale"

    # The first live response starts a new confirmation without trusting one
    # weak zero enough to refresh routing immediately.
    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(stale_at), stale_at)

    assert DateTime.compare(account_row(identity).observed_at, t0) == :eq

    # A later response whose reset advanced with wall time proves the endpoint
    # is live and makes the already-zero canonical usable again.
    confirmed_at = DateTime.add(stale_at, 4, :minute)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(confirmed_at), confirmed_at)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
    assert DateTime.compare(row.observed_at, confirmed_at) == :eq
    assert Evidence.current_freshness_state(row, confirmed_at) == "fresh"
  end

  test "repeated cached zeroes cannot keep an accepted weekly reset fresh" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    fixed_reset = DateTime.add(t0, @window_seconds, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t0, reset_at: fixed_reset), t0)

    for minute <- 1..16 do
      observed_at = DateTime.add(t0, minute, :minute)

      assert {:ok, _row} =
               Windows.record_evidence(
                 identity,
                 floating_zero(observed_at, reset_at: fixed_reset),
                 observed_at
               )
    end

    row = account_row(identity)
    assert DateTime.compare(row.observed_at, t0) == :eq
    assert Evidence.current_freshness_state(row, DateTime.add(t0, 16, :minute)) == "stale"
  end
end
