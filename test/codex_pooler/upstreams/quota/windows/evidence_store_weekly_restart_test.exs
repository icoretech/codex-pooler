defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStoreWeeklyRestartTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows

  # Production shape after the provider retired anchored 5h windows: a restarted
  # weekly account arrives from the usage endpoint as a weak zero (no active
  # limit or credits) whose relative reset is recomputed at response time, so
  # reset_at slides forward in step with each observation. A cached or replayed
  # body keeps a fixed reset_at instead.

  @window_seconds 10_080 * 60

  defp identity! do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    identity
  end

  defp exhausted_row!(identity, observed_at) do
    Windows.record_evidence(
      identity,
      %{
        quota_key: "account",
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new("100"),
        reset_at: DateTime.add(observed_at, 5, :day),
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

  test "a cached body with a fixed reset never clears the exhausted row" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = exhausted_row!(identity, t0)

    t1 = DateTime.add(t0, 300, :second)
    fixed_reset = DateTime.add(t1, @window_seconds, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t1, reset_at: fixed_reset), t1)

    # Same cached reset_at minutes later: delta_reset stays zero while time
    # advanced — not live, must stay quarantined.
    t2 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t2, reset_at: fixed_reset), t2)

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

  test "a non-exhausted row is untouched by the restart path" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               Map.put(floating_zero(t0), :used_percent, Decimal.new("40")),
               t0
             )

    t1 = DateTime.add(t0, 300, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t1), t1)

    # Pre-existing semantics for non-exhausted rows apply; nothing crashes and
    # the row still exists with a valid percent.
    row = account_row(identity)
    assert row
  end
end
