defmodule CodexPooler.Upstreams.Quota.Windows.UsageCoherenceStoreTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Quota.Windows.UsageCoherence

  @key "__quota_usage_coherence_v1"

  test "two coherent usage readings supersede a fresh header exhaustion in the effective view" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    reset_at = DateTime.add(now, 900, :second) |> DateTime.truncate(:second)

    assert {:ok, _headers} =
             record!(
               identity,
               "codex_response_headers",
               "100",
               reset_at,
               DateTime.add(now, -90, :second),
               %{}
             )

    assert [%{used_percent: exhausted}] = Windows.list_quota_windows(identity, now)
    assert Decimal.equal?(exhausted, Decimal.new("100"))

    assert {:ok, first} =
             record!(
               identity,
               "codex_usage_api",
               "20",
               reset_at,
               DateTime.add(now, -60, :second),
               safe_status()
             )

    assert first.metadata[@key]["count"] == 1
    refute UsageCoherence.confirmed?(first, now)

    # One lower reading is retained beside the exhausted row, which still wins.
    assert [%{source: "codex_response_headers"}] = Windows.list_quota_windows(identity, now)

    assert {:ok, second} =
             record!(
               identity,
               "codex_usage_api",
               "20",
               reset_at,
               DateTime.add(now, -30, :second),
               safe_status()
             )

    assert second.metadata[@key]["count"] == 2
    assert UsageCoherence.confirmed?(second, now)

    assert [%{source: "codex_usage_api", used_percent: recovered}] =
             Windows.list_quota_windows(identity, now)

    assert Decimal.equal?(recovered, Decimal.new("20"))

    # A denied reading clears the confirmation and the exhausted row wins again.
    assert {:ok, denied} =
             record!(identity, "codex_usage_api", "20", reset_at, now, %{
               "rate_limit_allowed" => false,
               "rate_limit_reached" => true
             })

    refute Map.has_key?(denied.metadata, @key)
    assert [%{source: "codex_response_headers"}] = Windows.list_quota_windows(identity, now)
  end

  test "a lower usage reading without provider permission facts never confirms" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    reset_at = DateTime.add(now, 900, :second) |> DateTime.truncate(:second)

    assert {:ok, _headers} =
             record!(
               identity,
               "codex_response_headers",
               "100",
               reset_at,
               DateTime.add(now, -90, :second),
               %{}
             )

    for offset <- [-60, -30] do
      assert {:ok, row} =
               record!(
                 identity,
                 "codex_usage_api",
                 "20",
                 reset_at,
                 DateTime.add(now, offset, :second),
                 %{}
               )

      refute Map.has_key?(row.metadata, @key)
    end

    assert [%{source: "codex_response_headers"}] = Windows.list_quota_windows(identity, now)
  end

  defp record!(identity, source, used_percent, reset_at, observed_at, metadata) do
    EvidenceStore.record_evidence(
      identity,
      %{
        quota_key: "account",
        quota_scope: "account",
        quota_family: "account",
        window_kind: "primary",
        window_minutes: 300,
        used_percent: Decimal.new(used_percent),
        reset_at: reset_at,
        observed_at: observed_at,
        last_sync_at: observed_at,
        source: source,
        source_precision: "observed",
        freshness_state: "fresh",
        metadata:
          Map.put(metadata, "reset_after_seconds", DateTime.diff(reset_at, observed_at, :second))
      },
      observed_at,
      observed_at
    )
  end

  defp safe_status, do: %{"rate_limit_allowed" => true, "rate_limit_reached" => false}
end
