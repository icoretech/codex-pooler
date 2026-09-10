defmodule CodexPooler.Upstreams.Quota.Windows.RuntimeCoherenceStoreTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Quota.Windows.RuntimeCoherence

  @key "__quota_runtime_coherence_v1"

  # Issue 376: after a provider incident the Usage API keeps reporting the
  # weekly window as 100% used every minute while runtime responses keep
  # succeeding at 37%.
  test "two coherent runtime readings supersede a fresh Usage API exhaustion of the same cycle" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    reset_at = DateTime.add(now, 5 * 86_400, :second) |> DateTime.truncate(:second)

    assert {:ok, first} =
             record!(
               identity,
               "codex_response_headers",
               "37",
               reset_at,
               DateTime.add(now, -132, :second),
               %{}
             )

    assert first.metadata[@key]["count"] == 1

    assert {:ok, _usage} =
             record!(
               identity,
               "codex_usage_api",
               "100",
               reset_at,
               DateTime.add(now, -60, :second),
               %{
                 "rate_limit_allowed" => false,
                 "rate_limit_reached" => true
               }
             )

    # One runtime reading is a suspicion: the newer exhausted Usage API row wins.
    assert [%{source: "codex_usage_api"}] = Windows.list_quota_windows(identity, now)

    assert {:ok, second} =
             record!(
               identity,
               "codex_response_headers",
               "37",
               reset_at,
               DateTime.add(now, -72, :second),
               %{}
             )

    assert second.metadata[@key]["count"] == 2
    assert RuntimeCoherence.confirmed?(second, now)

    # Two coherent readings are proof the account served, even though the
    # Usage API row is 12 seconds newer than the last runtime observation.
    assert [%{source: "codex_response_headers", used_percent: served}] =
             Windows.list_quota_windows(identity, now)

    assert Decimal.equal?(served, Decimal.new("37"))

    # The Usage API refreshing the same contradiction every minute changes nothing.
    assert {:ok, _usage} =
             record!(identity, "codex_usage_api", "100", reset_at, now, %{
               "rate_limit_allowed" => false,
               "rate_limit_reached" => true
             })

    assert [%{source: "codex_response_headers"}] =
             Windows.list_quota_windows(identity, DateTime.add(now, 1, :second))

    # A runtime denial clears the confirmation and the exhausted row wins again.
    assert {:ok, denied} =
             record!(
               identity,
               "codex_response_headers",
               "100",
               reset_at,
               DateTime.add(now, 30, :second),
               %{
                 "rate_limit_reached_type" => "usage_limit_reached"
               }
             )

    refute Map.has_key?(denied.metadata, @key)

    assert [%{used_percent: exhausted}] =
             Windows.list_quota_windows(identity, DateTime.add(now, 31, :second))

    assert Decimal.equal?(exhausted, Decimal.new("100"))
  end

  test "a runtime confirmation older than the tolerance does not override a later exhaustion" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    reset_at = DateTime.add(now, 5 * 86_400, :second) |> DateTime.truncate(:second)
    tolerance = RuntimeCoherence.override_tolerance_seconds()

    for offset <- [-(tolerance + 120), -(tolerance + 60)] do
      assert {:ok, _row} =
               record!(
                 identity,
                 "codex_response_headers",
                 "37",
                 reset_at,
                 DateTime.add(now, offset, :second),
                 %{}
               )
    end

    assert {:ok, _usage} =
             record!(identity, "codex_usage_api", "100", reset_at, now, %{
               "rate_limit_allowed" => false,
               "rate_limit_reached" => true
             })

    # The account may genuinely have exhausted since the last success.
    assert [%{source: "codex_usage_api"}] = Windows.list_quota_windows(identity, now)
  end

  defp record!(identity, source, used_percent, reset_at, observed_at, metadata) do
    EvidenceStore.record_evidence(
      identity,
      %{
        quota_key: "account",
        quota_scope: "account",
        quota_family: "account",
        window_kind: "secondary",
        window_minutes: 10_080,
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
end
