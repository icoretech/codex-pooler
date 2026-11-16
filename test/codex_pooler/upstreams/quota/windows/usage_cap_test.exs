defmodule CodexPooler.Upstreams.Quota.Windows.UsageCapTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPooler.Upstreams.Quota.Windows.UsageCap

  @observed_at ~U[2026-11-10 09:00:00.000000Z]
  @primary_reset ~U[2026-11-10 12:00:00.000000Z]
  @weekly_reset ~U[2026-11-14 08:00:00.000000Z]
  @at ~U[2026-11-10 09:00:10.000000Z]

  test "a weekly reading at or above the cap is in force until the weekly reset" do
    for used <- ["80", "80.0", "93.5"] do
      assert %{cap_percent: 80, reset_at: @weekly_reset, used_percent: used_percent, window_kind: :weekly} = UsageCap.active(snapshot(windows(weekly: used), cap: 80))
      assert Decimal.equal?(used_percent, Decimal.new(used))
    end

    snapshot = snapshot(windows(weekly: "85"), cap: 80)
    assert UsageCap.active(%{snapshot | as_of: DateTime.add(@weekly_reset, -1, :second)})
    refute UsageCap.active(%{snapshot | as_of: @weekly_reset})
  end

  test "a weekly reading below the cap leaves the account uncapped" do
    refute UsageCap.active(snapshot(windows(weekly: "79.99"), cap: 80))
  end

  test "the 5h window never caps, however high it reads" do
    refute UsageCap.active(snapshot(windows(primary: "100", weekly: "10"), cap: 50))
  end

  test "no cap, an out-of-range cap and no snapshot mean no cap" do
    for cap <- [nil, 0, 100] do
      refute UsageCap.active(snapshot(windows(weekly: "99"), cap: cap))
    end

    refute UsageCap.active(nil)
  end

  test "no weekly window, no percentage or no reset leave the account uncapped" do
    refute UsageCap.active(snapshot([window("primary", 300, "90", @primary_reset)], cap: 50))
    refute UsageCap.active(snapshot([window("secondary", 10_080, nil, @weekly_reset)], cap: 50))
    refute UsageCap.active(snapshot([window("secondary", 10_080, "90", nil)], cap: 50))
  end

  test "a stale reading at or above the cap still caps inside its cycle" do
    at = DateTime.add(@observed_at, Evidence.freshness_ttl_seconds() * 4, :second)

    assert %{cap_percent: 60} = UsageCap.active(snapshot(windows(weekly: "70"), cap: 60, at: at))
  end

  test "a reading observed after the snapshot instant is not visible" do
    refute UsageCap.active(snapshot(windows(weekly: "90"), cap: 50, at: DateTime.add(@observed_at, -1, :second)))
  end

  test "a weekly limit the provider moved into the primary slot is judged as the weekly window" do
    refute is_nil(UsageCap.active(snapshot([window("primary", 10_080, "88", @weekly_reset)], cap: 80)))
  end

  test "a plan without a weekly window is capped on its 30-day window" do
    monthly = window("primary", 43_200, "41", @weekly_reset)

    assert %{cap_percent: 40, window_kind: :monthly} = UsageCap.active(snapshot([monthly], cap: 40))
    refute UsageCap.active(snapshot([monthly], cap: 50))
    assert UsageCap.state(snapshot([monthly], cap: 50)) == {:below, :monthly}
  end

  test "the weekly window decides when the account reports both long windows" do
    windows = [window("primary", 43_200, "90", @weekly_reset), window("secondary", 10_080, "20", @weekly_reset)]

    refute UsageCap.active(snapshot(windows, cap: 50))
    assert UsageCap.state(snapshot(windows, cap: 50)) == {:below, :weekly}
  end

  test "state tells no cap, unmeasurable, below and reached apart" do
    assert UsageCap.state(snapshot(windows(weekly: "90"), cap: nil)) == :none
    assert UsageCap.state(snapshot([], cap: 50)) == :unmeasurable
    assert UsageCap.state(snapshot([window("primary", 300, "90", @primary_reset)], cap: 50)) == :unmeasurable
    assert UsageCap.state(snapshot([window("secondary", 10_080, nil, @weekly_reset)], cap: 50)) == :unmeasurable
    assert UsageCap.state(snapshot(windows(weekly: "10"), cap: 50)) == {:below, :weekly}
    assert UsageCap.state(snapshot(windows(weekly: "60"), cap: 50)) == {:reached, :weekly}
    assert UsageCap.state(%{snapshot(windows(weekly: "60"), cap: 50) | as_of: @weekly_reset}) == :unmeasurable
  end

  defp windows(opts) do
    [
      window("primary", 300, Keyword.get(opts, :primary, "20"), @primary_reset),
      window("secondary", 10_080, Keyword.fetch!(opts, :weekly), @weekly_reset)
    ]
  end

  defp window(kind, minutes, used_percent, reset_at) do
    %AccountQuotaWindow{
      id: Ecto.UUID.generate(),
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: kind,
      window_minutes: minutes,
      used_percent: used_percent && Decimal.new(used_percent),
      reset_at: reset_at,
      source: "codex_response_headers",
      source_precision: "observed",
      freshness_state: "fresh",
      observed_at: @observed_at,
      last_sync_at: @observed_at,
      metadata: %{"header_limit_id" => "codex"}
    }
  end

  defp snapshot(windows, opts) do
    %RoutingQuotaSnapshot{
      upstream_identity_id: Ecto.UUID.generate(),
      raw_windows: windows,
      availability: nil,
      credential_epoch: 1,
      usage_cap_percent: Keyword.get(opts, :cap),
      as_of: Keyword.get(opts, :at, @at)
    }
  end
end
