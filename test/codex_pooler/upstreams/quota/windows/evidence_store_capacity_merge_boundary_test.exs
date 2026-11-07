defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStoreCapacityMergeBoundaryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows.{CycleConfirmation, EvidenceStore}

  @at ~U[2026-11-01 10:00:00.000000Z]

  test "an inferred runtime reading preserves the measured capacity and reset while advancing its observation" do
    identity = identity!()
    reset = DateTime.add(@at, 3_600)
    first = record!(identity, %{source: "codex_response_headers", window_minutes: 300, active_limit: 100, credits: 70, used_percent: Decimal.new(40), reset_at: reset})
    later = DateTime.add(@at, 60)

    merged = record!(identity, %{source: "codex_response_headers", source_precision: "inferred", window_minutes: 300, active_limit: 200, credits: 180, used_percent: Decimal.new(10), reset_at: nil}, later)

    assert merged.id == first.id
    assert merged.active_limit == 100
    assert merged.credits == 70
    assert merged.reset_at == reset
    assert Decimal.equal?(merged.used_percent, 40)
    assert merged.observed_at == later
    assert merged.last_sync_at == later
  end

  test "a measured percentage enriches resetless capacity without erasing the last valid balance" do
    identity = identity!()
    first = record!(identity, %{used_percent: nil, active_limit: 100, credits: 75, reset_at: nil})
    later = DateTime.add(@at, 60)
    reset = DateTime.add(@at, 28, :day)

    merged = record!(identity, %{used_percent: Decimal.new(30), reset_at: reset}, later)

    assert merged.id == first.id
    assert merged.active_limit == 100
    assert merged.credits == 75
    assert merged.reset_at == reset
    assert Decimal.equal?(merged.used_percent, 30)
  end

  test "an incomplete capacity observation cannot erase a previously measured reset" do
    identity = identity!()
    reset = DateTime.add(@at, 28, :day)
    first = record!(identity, %{used_percent: nil, active_limit: 100, credits: 75, reset_at: reset})

    merged = record!(identity, %{used_percent: Decimal.new(30), reset_at: nil}, DateTime.add(@at, 60))

    assert merged.id == first.id
    assert merged.reset_at == reset
    assert merged.active_limit == 100
    assert merged.credits == 75
    assert Decimal.equal?(merged.used_percent, 30)
  end

  test "a changed credit-only reanchor restarts confirmation instead of adopting either unconfirmed reset" do
    identity = identity!()
    original_reset = DateTime.add(@at, 28, :day)
    first = record!(identity, %{active_limit: 1_000, credits: 800, used_percent: Decimal.new(20), reset_at: original_reset})
    candidate_reset = DateTime.add(@at, 12, :day)
    changed_reset = DateTime.add(@at, 14, :day)

    pending = record!(identity, %{credits: 400, used_percent: Decimal.new(100), reset_at: candidate_reset}, DateTime.add(@at, 60))
    assert pending.reset_at == original_reset
    assert {:ok, %{reset_at: ^candidate_reset}} = EvidenceStore.parse_candidate(pending.metadata)

    changed_at = DateTime.add(@at, 120)
    restarted = record!(identity, %{credits: 350, used_percent: Decimal.new(100), reset_at: changed_reset}, changed_at)
    assert restarted.id == first.id
    assert restarted.reset_at == original_reset
    assert restarted.active_limit == 1_000
    assert restarted.credits == 350
    assert {:ok, %{reset_at: ^changed_reset, observed_at: ^changed_at}} = EvidenceStore.parse_candidate(restarted.metadata)

    accepted = record!(identity, %{credits: 300, used_percent: Decimal.new(100), reset_at: changed_reset}, DateTime.add(@at, 180))
    assert accepted.reset_at == changed_reset
    assert accepted.active_limit == 1_000
    assert accepted.credits == 300
    assert :none = EvidenceStore.parse_candidate(accepted.metadata)
  end

  test "a permitted lower relative reading needs a second observation before replacing same-cycle usage" do
    identity = identity!()
    reset = DateTime.add(@at, 28, :day)
    first = record!(identity, %{used_percent: Decimal.new(35), reset_at: reset})
    candidate_at = DateTime.add(@at, 60)
    candidate_attrs = %{used_percent: Decimal.new(20), reset_at: reset, metadata: %{"reset_after_seconds" => DateTime.diff(reset, candidate_at), "rate_limit_allowed" => true, "rate_limit_reached" => false}}

    pending = record!(identity, candidate_attrs, candidate_at)
    assert pending.id == first.id
    assert Decimal.equal?(pending.used_percent, 35)
    assert {:ok, %{used_percent: candidate_percent, observed_at: ^candidate_at}} = EvidenceStore.parse_candidate(pending.metadata)
    assert Decimal.equal?(candidate_percent, 20)

    repeated = record!(identity, candidate_attrs, candidate_at)
    assert Decimal.equal?(repeated.used_percent, 35)

    accepted_at = DateTime.add(@at, 120)
    accepted_attrs = put_in(candidate_attrs, [:metadata, "reset_after_seconds"], DateTime.diff(reset, accepted_at))
    accepted = record!(identity, accepted_attrs, accepted_at)
    assert accepted.id == first.id
    assert Decimal.equal?(accepted.used_percent, 20)
    assert accepted.reset_at == reset
    assert :none = EvidenceStore.parse_candidate(accepted.metadata)
  end

  for {incoming, expected} <- [{20, 35}, {40, 40}] do
    test "relative forward drift at #{incoming}% keeps the known reset and applies only stronger pressure" do
      identity = identity!()
      reset = DateTime.add(@at, 28, :day)
      first = record!(identity, %{used_percent: Decimal.new(35), reset_at: reset})
      later = DateTime.add(@at, 60)
      incoming_reset = DateTime.add(reset, 60)
      metadata = %{"reset_at_source" => "relative", "reset_after_seconds" => DateTime.diff(incoming_reset, later)}

      merged = record!(identity, %{used_percent: Decimal.new(unquote(incoming)), reset_at: incoming_reset, metadata: metadata}, later)

      assert merged.id == first.id
      assert merged.reset_at == reset
      assert Decimal.equal?(merged.used_percent, unquote(expected))
      refute Map.has_key?(merged.metadata, "__quota_confirmed_candidate_v1")
    end
  end

  test "a complete explicit correction retains an existing runtime allowance instead of replacing it" do
    identity = identity!()
    relative_reset = DateTime.add(@at, 3_600)
    first = record!(identity, %{source: "codex_rate_limit_event", window_minutes: 300, active_limit: 100, credits: 70, used_percent: Decimal.new(30), reset_at: relative_reset, metadata: %{"reset_after_seconds" => 3_600}})
    later = DateTime.add(@at, 60)
    explicit_reset = DateTime.add(@at, 3_300)

    corrected = record!(identity, %{source: "codex_rate_limit_event", window_minutes: 300, active_limit: 200, credits: 180, used_percent: Decimal.new(40), reset_at: explicit_reset, metadata: %{"reset_at_source" => "explicit"}}, later)

    assert corrected.id == first.id
    assert corrected.active_limit == 100
    assert corrected.credits == 70
    assert corrected.reset_at == explicit_reset
    assert Decimal.equal?(corrected.used_percent, 40)
    refute Map.has_key?(corrected.metadata, "reset_after_seconds")
  end

  test "an exhausted correction can introduce the first observed allowance" do
    identity = identity!()
    first = record!(identity, %{active_limit: nil, credits: nil, used_percent: Decimal.new(20), metadata: %{"reset_after_seconds" => 28 * 86_400}})
    later = DateTime.add(@at, 60)
    reset = DateTime.add(@at, 25, :day)

    corrected = record!(identity, %{active_limit: 100, credits: 0, used_percent: Decimal.new(100), reset_at: reset, metadata: %{"reset_at_source" => "explicit"}}, later)

    assert corrected.id == first.id
    assert corrected.active_limit == 100
    assert corrected.credits == 0
    assert corrected.reset_at == reset
    assert Decimal.equal?(corrected.used_percent, 100)
  end

  test "a capacity-only observation without percentage does not manufacture percent usage" do
    identity = identity!()
    first = record!(identity, %{used_percent: nil, active_limit: nil, credits: 50, reset_at: nil, source: "local_reconciliation"})
    later = DateTime.add(@at, 60)
    reset = DateTime.add(@at, 28, :day)

    enriched = record!(identity, %{used_percent: nil, active_limit: nil, credits: 80, reset_at: reset, source: "local_reconciliation"}, later)

    assert enriched.id == first.id
    assert enriched.credits == 80
    assert enriched.active_limit == nil
    assert enriched.used_percent == nil
    assert enriched.reset_at == reset
  end

  test "an explicit capacity-only correction retains an unknown percentage" do
    identity = identity!()
    first = record!(identity, %{active_limit: 100, credits: 70, metadata: %{"reset_after_seconds" => 28 * 86_400}})
    reset = DateTime.add(@at, 25, :day)

    corrected = record!(identity, %{active_limit: 120, credits: 90, used_percent: nil, reset_at: reset, metadata: %{"reset_at_source" => "explicit"}}, DateTime.add(@at, 60))

    assert corrected.id == first.id
    assert corrected.active_limit == 120
    assert corrected.credits == 90
    assert corrected.used_percent == nil
    assert corrected.reset_at == reset
    refute Map.has_key?(corrected.metadata, "reset_after_seconds")
  end

  test "an explicit correction keeps a credit balance without inventing an allowance" do
    identity = identity!()
    first = record!(identity, %{credits: 20, used_percent: Decimal.new(5), metadata: %{"reset_after_seconds" => 28 * 86_400}})
    reset = DateTime.add(@at, 25, :day)

    corrected = record!(identity, %{credits: 30, used_percent: Decimal.new(10), reset_at: reset, metadata: %{"reset_at_source" => "explicit"}}, DateTime.add(@at, 60))

    assert corrected.id == first.id
    assert corrected.active_limit == nil
    assert corrected.credits == 30
    assert Decimal.equal?(corrected.used_percent, 10)
    assert corrected.reset_at == reset
  end

  test "a measured allowance corrects a weaker zero despite an earlier reset" do
    identity = identity!()
    old_reset = DateTime.add(@at, 28, :day)
    first = record!(identity, %{used_percent: Decimal.new(0), reset_at: old_reset})
    corrected_reset = DateTime.add(old_reset, -300)

    corrected = record!(identity, %{active_limit: 100, credits: 75, used_percent: Decimal.new(25), reset_at: corrected_reset}, DateTime.add(@at, 60))

    assert corrected.id == first.id
    assert corrected.active_limit == 100
    assert corrected.credits == 75
    assert Decimal.equal?(corrected.used_percent, 25)
    assert corrected.reset_at == corrected_reset
  end

  test "a runtime percentage enriches a capacity-only reading without losing its balance" do
    identity = identity!()
    first = record!(identity, %{source: "codex_response_headers", window_minutes: 300, used_percent: nil, active_limit: 100, credits: 75})
    later = DateTime.add(@at, 60)

    measured = record!(identity, %{source: "codex_response_headers", window_minutes: 300, used_percent: Decimal.new(30)}, later)

    assert measured.id == first.id
    assert Decimal.equal?(measured.used_percent, 30)
    assert measured.active_limit == 100
    assert measured.credits == 75
    assert measured.observed_at == later
  end

  test "a weak zero refreshes capacity-only evidence without claiming a measured percentage" do
    identity = identity!()
    first = record!(identity, %{used_percent: nil, active_limit: 100, credits: 75})
    later = DateTime.add(@at, 60)

    refreshed = record!(identity, %{used_percent: Decimal.new(0)}, later)

    assert refreshed.id == first.id
    assert refreshed.used_percent == nil
    assert refreshed.active_limit == 100
    assert refreshed.credits == 75
    assert refreshed.reset_at == first.reset_at
    assert refreshed.observed_at == later
  end

  test "a weaker zero with a later reset keeps the known allowance and current reset" do
    identity = identity!()
    first = record!(identity, %{used_percent: nil, active_limit: 100, credits: 75})
    later = DateTime.add(@at, 60)

    refreshed = record!(identity, %{used_percent: Decimal.new(0), reset_at: DateTime.add(first.reset_at, 600)}, later)

    assert refreshed.id == first.id
    assert Decimal.equal?(refreshed.used_percent, 0)
    assert refreshed.active_limit == 100
    assert refreshed.credits == 75
    assert refreshed.reset_at == first.reset_at
    assert refreshed.observed_at == later
  end

  test "a reset-only later receipt cannot erase a measured percentage or current allowance" do
    identity = identity!()
    first = record!(identity, %{used_percent: Decimal.new(35), active_limit: 100, credits: 65})
    later = DateTime.add(@at, 60)

    refreshed = record!(identity, %{used_percent: nil, reset_at: DateTime.add(first.reset_at, 600)}, later)

    assert refreshed.id == first.id
    assert Decimal.equal?(refreshed.used_percent, 35)
    assert refreshed.active_limit == 100
    assert refreshed.credits == 65
    assert refreshed.reset_at == first.reset_at
    assert refreshed.observed_at == later
  end

  for allowance <- [0, 120] do
    test "an explicit #{allowance} allowance is not replaced by the preserved previous allowance" do
      identity = identity!()
      first = record!(identity, %{used_percent: Decimal.new(35), active_limit: 100, credits: 65})
      later = DateTime.add(@at, 60)

      observed = record!(identity, %{used_percent: nil, active_limit: unquote(allowance), reset_at: DateTime.add(first.reset_at, 600)}, later)

      assert observed.id == first.id
      assert observed.active_limit == unquote(allowance)
      assert Repo.reload!(first).active_limit == unquote(allowance)
    end
  end

  test "a relative reset-only receipt keeps known quota across a small forward drift" do
    identity = identity!()
    first = record!(identity, %{used_percent: Decimal.new(35), active_limit: 100, credits: 65})
    later = DateTime.add(@at, 60)
    incoming_reset = DateTime.add(first.reset_at, 60)
    metadata = %{"reset_at_source" => "relative", "reset_after_seconds" => DateTime.diff(incoming_reset, later)}

    observed = record!(identity, %{used_percent: nil, reset_at: incoming_reset, metadata: metadata}, later)

    assert observed.id == first.id
    assert observed.active_limit == 100
    assert observed.credits == 65
    assert Decimal.equal?(observed.used_percent, 35)
    assert observed.reset_at == first.reset_at
    assert observed.observed_at == later
  end

  test "an incoming floating reset marker survives an accepted explicit correction" do
    identity = identity!()
    first = record!(identity, %{metadata: %{"reset_after_seconds" => 28 * 86_400}})
    later = DateTime.add(@at, 60)
    reset = DateTime.add(@at, 25, :day)

    observed = record!(identity, %{used_percent: Decimal.new(30), reset_at: reset, metadata: %{"reset_at_source" => "explicit", "reset_state" => "floating"}}, later)

    assert observed.id == first.id
    assert observed.reset_at == reset
    assert Decimal.equal?(observed.used_percent, 30)
    assert observed.metadata["reset_state"] == "floating"
    refute Map.has_key?(observed.metadata, "reset_after_seconds")
    refute CycleConfirmation.selector_valid?(observed, later)
  end

  test "a resetless runtime zero cannot replace the known measured capacity" do
    identity = identity!()
    first = record!(identity, %{source: "codex_response_headers", used_percent: Decimal.new(40), active_limit: 100, credits: 60})

    observed = record!(identity, %{source: "codex_response_headers", used_percent: Decimal.new(0), reset_at: nil}, DateTime.add(@at, 60))

    assert observed.id == first.id
    assert Decimal.equal?(observed.used_percent, 40)
    assert observed.active_limit == 100
    assert observed.credits == 60
    assert observed.reset_at == first.reset_at
    assert observed.observed_at == first.observed_at
  end

  test "provider evidence for another meter cannot authorize a runtime percentage rollback" do
    identity = identity!()
    first = record!(identity, %{source: "codex_response_headers", used_percent: Decimal.new(40), active_limit: 100, credits: 60})
    record!(identity, %{quota_key: "separate-meter", quota_scope: "feature", quota_family: "separate-meter", used_percent: Decimal.new(10), active_limit: 100, credits: 90})

    observed = record!(identity, %{source: "codex_response_headers", used_percent: Decimal.new(0)}, DateTime.add(@at, 60))

    assert observed.id == first.id
    assert Decimal.equal?(observed.used_percent, 40)
    assert observed.active_limit == 100
    assert observed.credits == 60
    assert observed.reset_at == first.reset_at
  end

  test "an expired lower candidate must earn a fresh confirming pair" do
    identity = identity!()
    first = record!(identity, %{used_percent: Decimal.new(35)})
    candidate_at = DateTime.add(@at, 60)
    candidate_attrs = relative_reading(20, first.reset_at, candidate_at)
    pending = record!(identity, candidate_attrs, candidate_at)
    assert {:ok, %{observed_at: ^candidate_at}} = EvidenceStore.parse_candidate(pending.metadata)

    refreshed_at = DateTime.add(@at, 1_000)
    restarted = record!(identity, relative_reading(20, first.reset_at, refreshed_at), refreshed_at)
    assert restarted.id == first.id
    assert Decimal.equal?(restarted.used_percent, 35)
    assert {:ok, %{observed_at: ^refreshed_at}} = EvidenceStore.parse_candidate(restarted.metadata)

    confirmed_at = DateTime.add(refreshed_at, 60)
    confirmed = record!(identity, relative_reading(20, first.reset_at, confirmed_at), confirmed_at)
    assert Decimal.equal?(confirmed.used_percent, 20)
    assert confirmed.reset_at == first.reset_at
    assert :none = EvidenceStore.parse_candidate(confirmed.metadata)
  end

  test "an unverified earlier reset cannot correct an observed relative window" do
    identity = identity!()
    first = record!(identity, %{source: "local_reconciliation", used_percent: Decimal.new(35), active_limit: 100, credits: 65, metadata: %{"reset_after_seconds" => 28 * 86_400}})
    later = DateTime.add(@at, 60)

    rejected = record!(identity, %{source: "local_reconciliation", source_precision: "unknown", used_percent: Decimal.new(50), active_limit: 100, credits: 50, reset_at: DateTime.add(first.reset_at, -3_600)}, later)

    assert rejected.id == first.id
    assert rejected.source_precision == "observed"
    assert rejected.reset_at == first.reset_at
    assert Decimal.equal?(rejected.used_percent, 35)
    assert rejected.credits == 65
    assert rejected.observed_at == first.observed_at
  end

  test "a feature-meter zero cannot erase its freshly measured capacity" do
    identity = identity!()
    descriptor = %{quota_key: "sample-feature", quota_scope: "feature", quota_family: "sample-feature", source: "codex_response_headers"}
    first = record!(identity, Map.merge(descriptor, %{used_percent: Decimal.new(35), active_limit: 100, credits: 65}))

    rejected = record!(identity, Map.merge(descriptor, %{used_percent: Decimal.new(0)}), DateTime.add(@at, 60))

    assert rejected.id == first.id
    assert rejected.quota_scope == "feature"
    assert Decimal.equal?(rejected.used_percent, 35)
    assert rejected.active_limit == 100
    assert rejected.credits == 65
    assert rejected.reset_at == first.reset_at
  end

  test "unknown evidence quality cannot replace a fresh measured balance" do
    identity = identity!()
    first = record!(identity, %{source: "local_reconciliation", used_percent: nil, credits: 80, active_limit: nil})

    rejected = record!(identity, %{source: "local_reconciliation", freshness_state: "unknown", used_percent: nil, credits: 90, active_limit: nil}, DateTime.add(@at, 60))

    assert rejected.id == first.id
    assert rejected.credits == 80
    assert rejected.observed_at == first.observed_at
    assert rejected.freshness_state == "fresh"
    assert Repo.reload!(first).credits == 80
  end

  defp identity! do
    active_upstream_assignment_fixture(pool_fixture(), %{metadata: %{"credential_epoch" => 4}}).identity
  end

  defp relative_reading(used_percent, reset, observed_at) do
    %{
      used_percent: Decimal.new(used_percent),
      reset_at: reset,
      metadata: %{"reset_after_seconds" => DateTime.diff(reset, observed_at), "rate_limit_allowed" => true, "rate_limit_reached" => false}
    }
  end

  defp record!(identity, overrides, at \\ @at) do
    attrs = %{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "primary",
      window_minutes: 43_200,
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      observed_at: at,
      last_sync_at: at,
      reset_at: DateTime.add(@at, 28, :day),
      active_limit: nil,
      credits: nil,
      used_percent: Decimal.new(20),
      metadata: %{}
    }

    assert {:ok, row} = EvidenceStore.record_evidence(identity, Map.merge(attrs, overrides), at, at)
    row
  end
end
