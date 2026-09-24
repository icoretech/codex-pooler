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
  # A relative claim that keeps an existing reset (a response-header claim, or
  # a Usage API window that reports a countdown without a reset time) takes
  # another merge that copied the stored countdown the same way (findings#206
  # row 206-563). It is measured again there too, but only from a claim
  # observed after the row: that merge does not require a newer observation,
  # and an older claim's countdown would move the stored one back in time.
  #
  # Metadata only, no traffic: EvidenceStore on the test database, the Usage
  # API payload shape of an account window and evidence attributes of a
  # response-header and a relative Usage API claim, synthetic times.
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

  # A same-cycle poll whose countdown is present but not a valid one keeps
  # the stored countdown: it cannot place its own observation. On the weekly
  # window such a poll is rejected before any merge
  # (`invalid_relative_weekly_observation?/3`), so the 5 h primary carries it.
  test "primary: a same-cycle poll with a malformed countdown keeps the stored countdown" do
    identity = identity!()
    reset_at = DateTime.add(@evaluation_at, 6_000, :second)
    first_at = DateTime.add(@evaluation_at, -120, :second)
    second_at = DateTime.add(first_at, 60, :second)

    first = poll!(identity, "primary", first_at, 20, reset_at)
    second = record!(identity, window_attrs("primary", "codex_usage_api", second_at, 21, reset_at, %{"reset_at_source" => "explicit", "reset_after_seconds" => "soon", "limit_window_seconds" => 18_000}), second_at)

    assert second.id == first.id
    assert DateTime.compare(second.reset_at, reset_at) == :eq
    assert DateTime.compare(second.observed_at, second_at) == :eq
    assert Decimal.equal?(second.used_percent, Decimal.new(21))
    assert second.metadata["reset_after_seconds"] == DateTime.diff(reset_at, first_at, :second)
  end

  # The same on the relative-claim merge: a newer response-header claim whose
  # countdown is not a valid one keeps the stored countdown.
  test "codex_response_headers: a newer same-reset claim with a malformed countdown keeps the stored countdown" do
    identity = identity!()
    reset_at = DateTime.add(@evaluation_at, 432_000, :second)
    stored_at = DateTime.add(@evaluation_at, -120, :second)
    newer_at = DateTime.add(stored_at, 60, :second)

    stored = record!(identity, relative_attrs("codex_response_headers", stored_at, 20, reset_at), stored_at)
    merged = record!(identity, window_attrs("secondary", "codex_response_headers", newer_at, 21, reset_at, %{"reset_after_seconds" => "soon"}), newer_at)

    assert merged.id == stored.id
    assert DateTime.compare(merged.observed_at, newer_at) == :eq
    assert Decimal.equal?(merged.used_percent, Decimal.new(21))
    assert merged.metadata["reset_after_seconds"] == DateTime.diff(reset_at, stored_at, :second)
  end

  for source <- ["codex_response_headers", "codex_usage_api"] do
    @tag source: source
    test "#{source}: same-reset relative claims 60 s apart leave the stored countdown 60 s lower each time", %{source: source} do
      identity = identity!()
      reset_at = DateTime.add(@evaluation_at, 432_000, :second)
      first_at = DateTime.add(@evaluation_at, -120, :second)
      second_at = DateTime.add(first_at, 60, :second)
      third_at = DateTime.add(second_at, 60, :second)

      rows = for {at, percent} <- [{first_at, 20}, {second_at, 21}, {third_at, 22}], do: record!(identity, relative_attrs(source, at, percent, reset_at), at)

      assert rows |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1
      assert Enum.all?(rows, &(DateTime.compare(&1.reset_at, reset_at) == :eq))
      assert Enum.map(rows, & &1.metadata["reset_after_seconds"]) == Enum.map([first_at, second_at, third_at], &DateTime.diff(reset_at, &1, :second))
      assert Decimal.equal?(List.last(rows).used_percent, Decimal.new(22))
    end
  end

  # A response-header claim observed before the stored row, for the same
  # reset, still raises the used percent, but its countdown is older than the
  # stored one and must not replace it.
  test "codex_response_headers: an older same-reset claim keeps the stored countdown" do
    identity = identity!()
    reset_at = DateTime.add(@evaluation_at, 432_000, :second)
    stored_at = DateTime.add(@evaluation_at, -60, :second)
    older_at = DateTime.add(stored_at, -30, :second)

    stored = record!(identity, relative_attrs("codex_response_headers", stored_at, 20, reset_at), stored_at)
    merged = record!(identity, relative_attrs("codex_response_headers", older_at, 25, reset_at), older_at)

    assert merged.id == stored.id
    assert Decimal.equal?(merged.used_percent, Decimal.new(25))
    assert DateTime.compare(merged.observed_at, stored_at) == :eq
    assert merged.metadata["reset_after_seconds"] == DateTime.diff(reset_at, stored_at, :second)
  end

  defp record!(identity, attrs, observed_at) do
    assert {:ok, row} = EvidenceStore.record_evidence(identity, attrs, observed_at, @evaluation_at)
    row
  end

  defp relative_attrs(source, observed_at, percent, reset_at) do
    window_attrs("secondary", source, observed_at, percent, reset_at, %{"reset_after_seconds" => DateTime.diff(reset_at, observed_at, :second)})
  end

  defp window_attrs(kind, source, observed_at, percent, reset_at, metadata) do
    %{
      quota_key: "account",
      window_kind: kind,
      window_minutes: if(kind == "primary", do: 300, else: 10_080),
      used_percent: Decimal.new(percent),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: source,
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      metadata: metadata
    }
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
