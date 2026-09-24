defmodule CodexPooler.Upstreams.Quota.Windows.BlockedAvailabilityHintTest do
  # An account the provider refused (`allowed: false`) is excluded without a
  # window of its own, so the exclusion carries `hint_reset_at`, the retry
  # advice of an all-exhausted Pool's terminal usage-limit answer (findings#206
  # row 206-508): the soonest fresh reset among the account's exhausted windows,
  # or among all its fresh account windows when none reads exhausted. It never
  # makes the account routable.
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Quota.AccountAvailabilityStore
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPooler.Upstreams.Quota.Windows

  @at ~U[2030-01-01 00:00:00.000000Z]

  test "the exhausted window binds, not an earlier reset of a window with room left" do
    windows = [window("primary", 300, "20", 3_600), window("secondary", 10_080, "100", 259_200)]

    assert %{eligible?: false, exclusions: [exclusion]} = eligibility(windows)
    assert exclusion.reason_codes == ["exhausted"]
    assert exclusion.hint_reset_at == iso(259_200)
  end

  test "the soonest of several exhausted windows" do
    windows = [window("primary", 300, "100", 3_600), window("secondary", 10_080, "100", 259_200)]

    assert %{exclusions: [%{hint_reset_at: hint}]} = eligibility(windows)
    assert hint == iso(3_600)
  end

  test "a block below 100% advises the soonest fresh account reset" do
    windows = [window("primary", 300, "97", 3_600), window("secondary", 10_080, "96", 259_200)]

    assert %{exclusions: [%{hint_reset_at: hint}]} = eligibility(windows)
    assert hint == iso(3_600)
  end

  test "without a fresh reset-bearing account window there is no hint" do
    stale = %{window("secondary", 10_080, "100", 259_200) | freshness_state: "stale", observed_at: DateTime.add(@at, -86_400, :second), last_sync_at: DateTime.add(@at, -86_400, :second)}

    for windows <- [[], [stale], [window("secondary", 10_080, "100", -60)]] do
      assert %{eligible?: false, exclusions: [exclusion]} = eligibility(windows)
      refute Map.has_key?(exclusion, :hint_reset_at)
    end
  end

  defp eligibility(windows) do
    snapshot = %RoutingQuotaSnapshot{
      upstream_identity_id: Ecto.UUID.generate(),
      raw_windows: windows,
      availability: %AccountAvailabilityStore.Snapshot{state: :blocked, observed_at: DateTime.add(@at, -10, :second), credential_epoch: 1},
      credential_epoch: 1,
      as_of: @at
    }

    Windows.routing_quota_eligibility_from_snapshot(snapshot, model: "gpt-test-model", upstream_model: "provider-gpt-test-model")
  end

  defp window(kind, minutes, used_percent, reset_in) do
    %AccountQuotaWindow{
      id: Ecto.UUID.generate(),
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: kind,
      window_minutes: minutes,
      used_percent: Decimal.new(used_percent),
      reset_at: DateTime.add(@at, reset_in, :second),
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      observed_at: DateTime.add(@at, -10, :second),
      last_sync_at: DateTime.add(@at, -10, :second),
      metadata: %{}
    }
  end

  defp iso(seconds), do: @at |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
end
