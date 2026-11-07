defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStoreResetClockBoundaryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore

  @at ~U[2026-11-01 10:00:00.000000Z]
  @weekly_seconds 604_800
  @idle_key "__quota_primary_idle_display_v1"

  test "an incomplete zero receipt preserves an established floating primary display without renewing quota" do
    identity = identity!()
    floating = floating_primary!(identity)
    observed_at = DateTime.add(@at, 300, :second)

    retained = record!(identity, primary(observed_at, nil, %{}), observed_at)

    assert retained.metadata["reset_state"] == "floating"
    assert retained.metadata[@idle_key] == floating.metadata[@idle_key]
    assert retained.reset_at == floating.reset_at
    assert retained.observed_at == floating.observed_at
    assert retained.last_sync_at == floating.last_sync_at
    assert Decimal.equal?(retained.used_percent, 0)
  end

  for {state, offset} <- [{"candidate", 0}, {"floating", 240}] do
    test "replayed provider time preserves #{state} primary display proof without advancing it" do
      identity = identity!()

      previous =
        case unquote(state) do
          "candidate" -> record!(identity, idle_primary(@at), @at)
          "floating" -> floating_primary!(identity)
        end

      provider_at = DateTime.add(@at, unquote(offset), :second)
      observed_at = DateTime.add(provider_at, 1, :second)
      reset_at = DateTime.add(provider_at, 18_000, :second)
      replay = primary(observed_at, reset_at, idle_metadata())

      retained = record!(identity, replay, observed_at)

      assert retained.metadata[@idle_key] == previous.metadata[@idle_key]
      assert retained.metadata[@idle_key]["state"] == unquote(state)
      assert retained.metadata["reset_state"] == previous.metadata["reset_state"]
      assert retained.reset_at == previous.reset_at
    end
  end

  test "an expired fixed model reset candidate must restart rather than adopting its old observation span" do
    identity = identity!()
    original = record!(identity, model_weekly(@at), @at)
    first_at = DateTime.add(@at, 60, :second)
    fixed_reset = DateTime.add(@at, @weekly_seconds - 600, :second)
    pending = record!(identity, model_weekly(first_at, fixed_reset), first_at)
    assert {:ok, %{observed_at: ^first_at}} = EvidenceStore.parse_candidate(pending.metadata)
    observed_at = DateTime.add(first_at, 901, :second)

    restarted = record!(identity, model_weekly(observed_at, fixed_reset), observed_at)

    assert {:ok, %{observed_at: ^observed_at, reset_at: ^fixed_reset}} = EvidenceStore.parse_candidate(restarted.metadata)
    assert restarted.reset_at == original.reset_at
    assert restarted.observed_at == original.observed_at
    refute restarted.metadata["reset_state"] == "anchored"
  end

  test "a live sliding model reset candidate retains its first clock below the confirmation interval" do
    identity = identity!()
    original = record!(identity, model_weekly(@at), @at)
    first_at = DateTime.add(@at, 60, :second)
    pending = record!(identity, model_weekly(first_at), first_at)
    assert {:ok, first_candidate} = EvidenceStore.parse_candidate(pending.metadata)
    observed_at = DateTime.add(first_at, 179, :second)

    retained = record!(identity, model_weekly(observed_at), observed_at)

    assert EvidenceStore.parse_candidate(retained.metadata) == {:ok, first_candidate}
    assert retained.observed_at == original.observed_at
    assert retained.reset_at == original.reset_at
    refute retained.metadata["reset_state"] == "floating"
  end

  for source <- ["codex_rate_limit_event", "local_reconciliation"] do
    test "a live equivalent account anchor advances #{source} zero evidence without creating a candidate" do
      identity = identity!()
      reset_at = DateTime.add(@at, @weekly_seconds, :second)
      record!(identity, account_weekly(@at, reset_at, unquote(source)), @at)
      observed_at = DateTime.add(@at, 60, :second)
      advanced_reset = DateTime.add(reset_at, 60, :second)

      advanced = record!(identity, account_weekly(observed_at, advanced_reset, unquote(source)), observed_at)

      assert advanced.source == unquote(source)
      assert advanced.observed_at == observed_at
      assert advanced.last_sync_at == observed_at
      assert advanced.reset_at == advanced_reset
      assert Decimal.equal?(advanced.used_percent, 0)
      assert advanced.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(observed_at)
      assert :none = EvidenceStore.parse_candidate(advanced.metadata)
    end
  end

  test "a resetless partial weekly reading is not erased by an unproved fixed zero cycle" do
    identity = identity!()
    original = record!(identity, account_usage(@at, nil, 86), @at)
    first_at = DateTime.add(@at, 10, :second)
    reset_at = DateTime.add(first_at, @weekly_seconds, :second)
    pending = record!(identity, account_usage(first_at, reset_at, 0), first_at)
    assert {:ok, _candidate} = EvidenceStore.parse_candidate(pending.metadata)
    observed_at = DateTime.add(first_at, 180, :second)

    retained = record!(identity, account_usage(observed_at, reset_at, 0), observed_at)

    assert retained.id == original.id
    assert Decimal.equal?(retained.used_percent, 86)
    assert retained.reset_at == nil
    assert retained.observed_at == original.observed_at
    assert {:ok, %{observed_at: ^observed_at}} = EvidenceStore.parse_candidate(retained.metadata)
  end

  test "a stale weekly candidate cannot borrow a fresher provider clock from its delayed receipt" do
    identity = identity!()
    old_reset = DateTime.add(@at, 5, :day)
    record!(identity, account_usage(@at, old_reset, 86), @at)
    first_at = DateTime.add(@at, 10, :second)
    provider_at = DateTime.add(first_at, 60, :second)
    reset_at = DateTime.add(provider_at, @weekly_seconds, :second)
    delayed = account_usage(first_at, reset_at, 0) |> Map.update!(:metadata, &Map.put(&1, "reset_after_seconds", @weekly_seconds))
    pending = record!(identity, delayed, provider_at)
    assert {:ok, %{observed_at: ^first_at}} = EvidenceStore.parse_candidate(pending.metadata)
    observed_at = DateTime.add(first_at, 901, :second)

    retained = record!(identity, account_usage(observed_at, reset_at, 0), observed_at)

    assert Decimal.equal?(retained.used_percent, 86)
    assert retained.reset_at == old_reset
    assert {:ok, %{observed_at: ^observed_at}} = EvidenceStore.parse_candidate(retained.metadata)
  end

  test "a stale lower same-cycle usage candidate restarts instead of replacing the canonical percentage" do
    identity = identity!()
    reset_at = DateTime.add(@at, 5, :day)
    original = record!(identity, account_usage(@at, reset_at, 35), @at)
    first_at = DateTime.add(@at, 60, :second)
    pending = record!(identity, account_usage(first_at, reset_at, 20), first_at)
    assert {:ok, %{observed_at: ^first_at}} = EvidenceStore.parse_candidate(pending.metadata)
    observed_at = DateTime.add(first_at, 901, :second)

    retained = record!(identity, account_usage(observed_at, reset_at, 20), observed_at)

    assert retained.id == original.id
    assert Decimal.equal?(retained.used_percent, 35)
    assert retained.reset_at == reset_at
    assert retained.observed_at == original.observed_at
    assert {:ok, %{observed_at: ^observed_at, used_percent: used}} = EvidenceStore.parse_candidate(retained.metadata)
    assert Decimal.equal?(used, 20)
  end

  defp identity! do
    active_upstream_assignment_fixture(pool_fixture(), %{metadata: %{"credential_epoch" => 4}}).identity
  end

  defp floating_primary!(identity) do
    Enum.reduce([0, 60, 240], nil, fn seconds, _previous ->
      observed_at = DateTime.add(@at, seconds, :second)
      record!(identity, idle_primary(observed_at), observed_at)
    end)
    |> tap(fn row -> assert row.metadata["reset_state"] == "floating" end)
  end

  defp idle_primary(observed_at), do: primary(observed_at, DateTime.add(observed_at, 18_000, :second), idle_metadata())

  defp idle_metadata do
    %{"reset_after_seconds" => 18_000, "limit_window_seconds" => 18_000, "rate_limit_allowed" => false, "rate_limit_reached" => true}
  end

  defp primary(observed_at, reset_at, metadata) do
    base(observed_at, reset_at, metadata)
    |> Map.merge(%{quota_key: "account", quota_scope: "account", quota_family: "account", window_kind: "primary", window_minutes: 300})
  end

  defp model_weekly(observed_at, reset_at \\ nil) do
    reset_at = reset_at || DateTime.add(observed_at, @weekly_seconds, :second)

    base(observed_at, reset_at, %{"reset_after_seconds" => DateTime.diff(reset_at, observed_at, :second), "limit_window_seconds" => @weekly_seconds})
    |> Map.merge(%{quota_key: "sample_model", quota_scope: "model", quota_family: "codex_model", model: "sample-model", window_kind: "secondary", window_minutes: 10_080})
  end

  defp account_weekly(observed_at, reset_at, source) do
    metadata = if reset_at, do: %{"reset_after_seconds" => DateTime.diff(reset_at, observed_at, :second), "limit_window_seconds" => @weekly_seconds}, else: %{}

    base(observed_at, reset_at, metadata)
    |> Map.merge(%{source: source, quota_key: "account", quota_scope: "account", quota_family: "account", window_kind: "secondary", window_minutes: 10_080})
  end

  defp account_usage(observed_at, reset_at, used_percent) do
    account_weekly(observed_at, reset_at, "codex_usage_api")
    |> Map.put(:used_percent, Decimal.new(used_percent))
    |> Map.update!(:metadata, &Map.merge(&1, %{"rate_limit_allowed" => true, "rate_limit_reached" => false}))
  end

  defp base(observed_at, reset_at, metadata) do
    %{source: "codex_usage_api", source_precision: "observed", freshness_state: "fresh", used_percent: Decimal.new(0), reset_at: reset_at, observed_at: observed_at, last_sync_at: observed_at, metadata: metadata}
  end

  defp record!(identity, attrs, timestamp) do
    assert {:ok, row} = EvidenceStore.record_evidence(identity, attrs, attrs.observed_at, timestamp)
    row
  end
end
