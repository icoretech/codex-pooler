defmodule CodexPooler.Upstreams.Quota.Windows.SameCycleCountdownTest do
  # A Usage API poll that reports the reset already stored is the same cycle:
  # the stored reset stays pinned and the used percent keeps the higher value.
  # The stored countdown (`metadata["reset_after_seconds"]`) used to be copied
  # from the stored row on every such poll, so the first countdown of a cycle
  # stayed stored for the whole window while `observed_at` and the liveness
  # marker moved with each poll (production: a weekly row kept 604,795 s
  # against a true 34,375 s, findings#206 row 206-555). The copy exists for a
  # poll whose reset differs from the pinned one (79e0888e1): its countdown
  # was measured against that other reset and must not describe the pinned
  # one. Both are satisfied by measuring the countdown again against the
  # pinned reset from the poll's own provider observation
  # (`reset_at - reset_after_seconds` of the poll); a poll without a countdown
  # keeps the stored one.
  #
  # Metadata only, no traffic: EvidenceStore on the test database, the Usage
  # API payload shape of an account window, synthetic times.
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore

  @evaluation_at ~U[2026-07-21 12:00:00Z]

  # window kind => {payload key, limit seconds, drift the provider interleaves
  # behind the stored reset within the same cycle}
  @windows %{
    "primary" => {"primary_window", 18_000, -1_440},
    "secondary" => {"secondary_window", 604_800, -361}
  }

  for kind <- ["primary", "secondary"] do
    @tag window: kind
    test "#{kind}: same-reset polls 60 s apart leave the stored countdown 60 s lower each time", %{window: kind} do
      identity = identity!()
      reset_at = DateTime.add(@evaluation_at, div(limit_seconds(kind), 3), :second)
      first_at = DateTime.add(@evaluation_at, -120, :second)
      second_at = DateTime.add(first_at, 60, :second)
      third_at = DateTime.add(second_at, 60, :second)

      first = poll!(identity, kind, first_at, 20, reset_at)
      second = poll!(identity, kind, second_at, 21, reset_at)
      third = poll!(identity, kind, third_at, 21, reset_at)

      assert second.id == first.id and third.id == first.id
      assert DateTime.compare(third.reset_at, reset_at) == :eq
      assert Decimal.equal?(third.used_percent, Decimal.new(21))

      assert Enum.map([first, second, third], & &1.metadata["reset_after_seconds"]) == [
               DateTime.diff(reset_at, first_at, :second),
               DateTime.diff(reset_at, second_at, :second),
               DateTime.diff(reset_at, third_at, :second)
             ]

      assert DateTime.compare(third.observed_at, third_at) == :eq
    end

    # The poll's reset lies a little behind the stored one (the provider
    # interleaves claims of the running window): the stored reset stays, and
    # the stored countdown is the one to the stored reset from the poll's
    # observation, neither the poll's own countdown (measured against its
    # reset) nor the stored row's previous one.
    @tag window: kind
    test "#{kind}: a same-cycle poll with a drifted reset stores the countdown measured against the pinned reset", %{window: kind} do
      identity = identity!()
      {_key, _limit, drift} = Map.fetch!(@windows, kind)
      reset_at = DateTime.add(@evaluation_at, div(limit_seconds(kind), 4), :second)
      canonical_at = DateTime.add(@evaluation_at, -60, :second)
      incoming_at = DateTime.add(@evaluation_at, -1, :second)
      drifted_reset_at = DateTime.add(reset_at, drift, :second)

      canonical = poll!(identity, kind, canonical_at, 0, reset_at)
      stored = poll!(identity, kind, incoming_at, 8, drifted_reset_at)

      assert stored.id == canonical.id
      assert DateTime.compare(stored.reset_at, reset_at) == :eq
      assert Decimal.equal?(stored.used_percent, Decimal.new(8))
      assert stored.metadata["reset_after_seconds"] == DateTime.diff(reset_at, incoming_at, :second)
      refute stored.metadata["reset_after_seconds"] == DateTime.diff(drifted_reset_at, incoming_at, :second)
      refute stored.metadata["reset_after_seconds"] == canonical.metadata["reset_after_seconds"]
      assert Evidence.current_freshness_state(stored, @evaluation_at) == "fresh"
    end
  end

  defp poll!(identity, kind, observed_at, used_percent, reset_at) do
    {key, limit_seconds, _drift} = Map.fetch!(@windows, kind)

    payload = %{
      "rate_limit" => %{
        key => %{
          "used_percent" => used_percent,
          "limit_window_seconds" => limit_seconds,
          "reset_at" => DateTime.to_iso8601(reset_at),
          "reset_after_seconds" => DateTime.diff(reset_at, observed_at, :second)
        }
      }
    }

    assert {:ok, windows} = QuotaWindows.codex_usage_quota_windows_from_payload(payload, observed_at)
    assert [{:ok, row}] = Enum.map(windows, &EvidenceStore.record_evidence(identity, &1, observed_at, @evaluation_at))
    row
  end

  defp limit_seconds(kind), do: kind |> then(&Map.fetch!(@windows, &1)) |> elem(1)

  defp identity! do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    identity
  end
end
