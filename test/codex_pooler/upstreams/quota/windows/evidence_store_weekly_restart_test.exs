defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStoreWeeklyRestartTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.Accounting.UsageResponses
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.CycleConfirmation
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Quota.Windows.Routing

  # Production shape while the provider's anchored 5h windows are suspended
  # (announced as temporary on 2026-07-13): a restarted weekly account arrives
  # from the usage endpoint as a weak zero (no active limit or credits) whose
  # relative reset is recomputed at response time, so reset_at slides forward in
  # step with each observation. A cached or replayed body keeps a fixed reset_at
  # instead.

  @window_seconds 10_080 * 60

  defp identity!(attrs \\ %{}) do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), attrs)
    identity
  end

  defp exhausted_row!(identity, observed_at, opts \\ []) do
    used_row!(identity, observed_at, "100", opts)
  end

  defp used_row!(identity, observed_at, used_percent, opts \\ []) do
    reset_at = Keyword.get(opts, :reset_at, DateTime.add(observed_at, 5, :day))
    metadata = Keyword.get(opts, :metadata, %{})
    active_limit = Keyword.get(opts, :active_limit)
    credits = Keyword.get(opts, :credits)

    EvidenceStore.record_evidence(
      identity,
      %{
        quota_key: "account",
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new(used_percent),
        reset_at: reset_at,
        observed_at: observed_at,
        last_sync_at: observed_at,
        source: "codex_usage_api",
        source_precision: "observed",
        quota_scope: "account",
        quota_family: "account",
        active_limit: active_limit,
        credits: credits,
        freshness_state: "fresh",
        metadata: metadata
      },
      observed_at,
      observed_at
    )
  end

  defp floating_zero(observed_at, opts \\ []) do
    reset_at = Keyword.get(opts, :reset_at, DateTime.add(observed_at, @window_seconds, :second))
    reset_after_seconds = Keyword.get(opts, :reset_after_seconds, @window_seconds)
    metadata = Keyword.get(opts, :metadata, %{})

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
      metadata: Map.put(metadata, "reset_after_seconds", reset_after_seconds)
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

  defp explicit_account_weekly_zero!(observed_at, reset_at) do
    payload = %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 0,
          "limit_window_seconds" => @window_seconds,
          "reset_at" => DateTime.to_iso8601(reset_at)
        }
      }
    }

    assert {:ok, windows} = Windows.codex_usage_quota_windows_from_payload(payload, observed_at)

    Enum.find(windows, fn window ->
      window.quota_key == "account" and window.window_kind == "secondary"
    end)
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

  test "quota cycle decision logs keep candidate and confirmation diagnostics identifier-free" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    account_label = "Example account label #{System.unique_integer([:positive])}"
    assignment_label = "Example assignment label #{System.unique_integer([:positive])}"

    identity =
      identity!(%{account_label: account_label, assignment_label: assignment_label})

    assert {:ok, _row} = exhausted_row!(identity, t0)

    {log, events} =
      capture_quota_cycle_events(fn ->
        capture_info_log(fn ->
          t1 = DateTime.add(t0, 300, :second)
          assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t1), t1)

          t2 = DateTime.add(t1, 180, :second)
          assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t2), t2)
        end)
      end)

    assert events == [
             {%{count: 1}, %{scope: "account", decision: :candidate, source: "provider_usage"}},
             {%{count: 1},
              %{scope: "account", decision: :anchored_confirmed, source: "provider_usage"}}
           ]

    assert log =~ "quota_cycle_decision decision=candidate reason=candidate_restarted"
    assert log =~ "quota_cycle_decision decision=anchored_confirmed reason=confirmation"
    assert log =~ "scope=account source=provider_usage"
    assert log =~ "candidate_age_s=180"
    refute log =~ "upstream_identity_id"
    refute log =~ account_label
    refute log =~ assignment_label
    refute log =~ identity.id
    refute log =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/

    event_output = inspect(events)
    refute event_output =~ account_label
    refute event_output =~ assignment_label
    refute event_output =~ identity.id
    refute event_output =~ "upstream_identity_id"
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

  test "safe fixed same-anchor observations confirm an exhausted weekly restart" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    fixed_anchor = DateTime.add(t0, 5, :day)

    assert {:ok, _row} =
             exhausted_row!(identity, t0,
               reset_at: fixed_anchor,
               active_limit: 243,
               credits: 0
             )

    candidate_at = DateTime.add(t0, 5, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               safe_fixed_zero(candidate_at, fixed_anchor),
               candidate_at,
               candidate_at
             )

    pending = account_row(identity)
    assert Decimal.equal?(pending.used_percent, Decimal.new("100"))
    assert pending.active_limit == 243
    assert pending.credits == 0
    assert_exhausted_quota_truth(identity, pending, candidate_at)

    assert {:ok, %{observed_at: ^candidate_at}} =
             EvidenceStore.parse_candidate(pending.metadata)

    inside_span_at = DateTime.add(candidate_at, 60, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               safe_fixed_zero(inside_span_at, fixed_anchor),
               inside_span_at,
               inside_span_at
             )

    still_pending = account_row(identity)
    assert Decimal.equal?(still_pending.used_percent, Decimal.new("100"))

    assert {:ok, %{observed_at: ^candidate_at}} =
             EvidenceStore.parse_candidate(still_pending.metadata)

    assert {:ok, %{observed_at: ^candidate_at}} =
             EvidenceStore.parse_candidate_provider_status(still_pending.metadata)

    confirmed_at = DateTime.add(candidate_at, 180, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               safe_fixed_zero(confirmed_at, fixed_anchor),
               confirmed_at,
               confirmed_at
             )

    confirmed = account_row(identity)
    assert Decimal.equal?(confirmed.used_percent, Decimal.new("0"))
    assert confirmed.active_limit == nil
    assert confirmed.credits == nil
    assert DateTime.compare(confirmed.reset_at, fixed_anchor) == :eq
    assert DateTime.compare(confirmed.observed_at, confirmed_at) == :eq
    assert DateTime.compare(confirmed.last_sync_at, confirmed_at) == :eq
    assert confirmed.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(confirmed_at)
    refute Map.has_key?(confirmed.metadata, "__quota_confirmed_candidate_v1")
    refute Map.has_key?(confirmed.metadata, "__quota_candidate_provider_status_v1")
    assert {:ok, _marker} = CycleConfirmation.valid_marker(confirmed)
    assert CycleConfirmation.selector_valid?(confirmed, confirmed_at)
    assert_reset_quota_truth(identity, confirmed, confirmed_at)
  end

  test "same-anchor confirmation retains exact positive incoming capacity" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    fixed_anchor = DateTime.add(t0, 5, :day)
    candidate_at = DateTime.add(t0, 5, :minute)
    confirmed_at = DateTime.add(candidate_at, 180, :second)

    assert {:ok, _row} =
             exhausted_row!(identity, t0,
               reset_at: fixed_anchor,
               active_limit: 243,
               credits: 0
             )

    for observed_at <- [candidate_at, confirmed_at] do
      evidence =
        observed_at
        |> safe_fixed_zero(fixed_anchor)
        |> Map.merge(%{active_limit: 300, credits: 300})

      assert {:ok, _row} =
               EvidenceStore.record_evidence(identity, evidence, observed_at, observed_at)
    end

    confirmed = account_row(identity)
    assert Decimal.equal?(confirmed.used_percent, Decimal.new("0"))
    assert confirmed.active_limit == 300
    assert confirmed.credits == 300
    assert CycleConfirmation.selector_valid?(confirmed, confirmed_at)
  end

  test "fresh matching runtime evidence immediately corroborates a safe same-anchor restart" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    fixed_anchor = DateTime.add(t0, 5, :day)

    assert {:ok, canonical} =
             exhausted_row!(identity, t0,
               reset_at: fixed_anchor,
               active_limit: 243,
               credits: 0
             )

    runtime_at = DateTime.add(t0, 4, :minute)
    runtime_weekly_row!(identity, runtime_at, "0", fixed_anchor)
    accepted_at = DateTime.add(runtime_at, 60, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               safe_fixed_zero(accepted_at, fixed_anchor),
               accepted_at,
               accepted_at
             )

    accepted = Repo.get!(AccountQuotaWindow, canonical.id)
    assert Decimal.equal?(accepted.used_percent, Decimal.new("0"))
    assert accepted.active_limit == nil
    assert accepted.credits == nil
    assert DateTime.compare(accepted.reset_at, fixed_anchor) == :eq
    assert DateTime.compare(accepted.observed_at, accepted_at) == :eq
    assert DateTime.compare(accepted.last_sync_at, accepted_at) == :eq
    assert accepted.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(accepted_at)
    assert accepted.metadata["reset_state"] == "anchored"
    refute Map.has_key?(accepted.metadata, "__quota_confirmed_candidate_v1")
    refute Map.has_key?(accepted.metadata, "__quota_candidate_provider_status_v1")
    assert CycleConfirmation.selector_valid?(accepted, accepted_at)
  end

  test "runtime corroboration cannot clear capacity for unsafe or replayed provider evidence" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    fixed_anchor = DateTime.add(t0, 5, :day)

    cases = [
      {:unsafe,
       fn accepted_at ->
         fixed_zero(
           accepted_at,
           fixed_anchor,
           %{"rate_limit_allowed" => false, "rate_limit_reached" => true}
         )
       end},
      {:replayed,
       fn accepted_at ->
         safe_fixed_zero(accepted_at, fixed_anchor, provider_at: t0)
       end}
    ]

    for {_name, evidence_for} <- cases do
      identity = identity!()

      assert {:ok, canonical} =
               exhausted_row!(identity, t0,
                 reset_at: fixed_anchor,
                 active_limit: 243,
                 credits: 0
               )

      runtime_at = DateTime.add(t0, 4, :minute)
      runtime_weekly_row!(identity, runtime_at, "0", fixed_anchor)
      accepted_at = DateTime.add(runtime_at, 60, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 evidence_for.(accepted_at),
                 accepted_at,
                 accepted_at
               )

      unchanged = Repo.get!(AccountQuotaWindow, canonical.id)
      assert Decimal.equal?(unchanged.used_percent, Decimal.new("100"))
      assert unchanged.active_limit == 243
      assert unchanged.credits == 0
      refute CycleConfirmation.selector_valid?(unchanged, accepted_at)
      assert_exhausted_quota_truth(identity, unchanged, accepted_at)
    end
  end

  test "non-restart same-cycle weak snapshots preserve known capacity" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    fixed_anchor = DateTime.add(t0, 5, :day)

    assert {:ok, canonical} =
             used_row!(identity, t0, "0",
               reset_at: fixed_anchor,
               active_limit: 243,
               credits: 243,
               metadata: %{"reset_after_seconds" => DateTime.diff(fixed_anchor, t0, :second)}
             )

    refreshed_at = DateTime.add(t0, 60, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(refreshed_at,
                 reset_at: fixed_anchor,
                 reset_after_seconds: DateTime.diff(fixed_anchor, refreshed_at, :second)
               ),
               refreshed_at,
               refreshed_at
             )

    refreshed = Repo.get!(AccountQuotaWindow, canonical.id)
    assert Decimal.equal?(refreshed.used_percent, Decimal.new("0"))
    assert refreshed.active_limit == 243
    assert refreshed.credits == 243
    assert DateTime.compare(refreshed.observed_at, refreshed_at) == :eq
    refute Map.has_key?(refreshed.metadata, "__quota_cycle_confirmation_v1")
  end

  test "same-anchor confirmation keeps anchored telemetry and uses a bounded reason" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    fixed_anchor = DateTime.add(t0, 5, :day)
    candidate_at = DateTime.add(t0, 5, :minute)
    confirmed_at = DateTime.add(candidate_at, 180, :second)

    assert {:ok, _row} = exhausted_row!(identity, t0, reset_at: fixed_anchor)

    {_log, events} =
      capture_quota_cycle_events(fn ->
        capture_info_log(fn ->
          assert {:ok, _row} =
                   EvidenceStore.record_evidence(
                     identity,
                     safe_fixed_zero(candidate_at, fixed_anchor),
                     candidate_at,
                     candidate_at
                   )
        end)
      end)

    {log, confirmation_events} =
      capture_quota_cycle_events(fn ->
        capture_info_log(fn ->
          assert {:ok, _row} =
                   EvidenceStore.record_evidence(
                     identity,
                     safe_fixed_zero(confirmed_at, fixed_anchor),
                     confirmed_at,
                     confirmed_at
                   )
        end)
      end)

    assert events == [
             {%{count: 1}, %{scope: "account", decision: :candidate, source: "provider_usage"}}
           ]

    assert confirmation_events == [
             {%{count: 1},
              %{scope: "account", decision: :anchored_confirmed, source: "provider_usage"}}
           ]

    assert log =~ "reason=same_anchor_allowed_confirmation"
    refute log =~ identity.id
  end

  test "same-anchor confirmation requires safe provider status on both observations" do
    statuses = [
      {:missing, %{}},
      {:unsafe_false_false, %{"rate_limit_allowed" => false, "rate_limit_reached" => false}},
      {:limit_reached, %{"rate_limit_allowed" => false, "rate_limit_reached" => true}},
      {:contradictory, %{"rate_limit_allowed" => true, "rate_limit_reached" => true}}
    ]

    for {_name, unsafe_status} <- statuses,
        unsafe_observation <- [:candidate, :confirmation] do
      t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
      identity = identity!()
      fixed_anchor = DateTime.add(t0, 5, :day)
      candidate_at = DateTime.add(t0, 5, :minute)
      confirmed_at = DateTime.add(candidate_at, 180, :second)

      assert {:ok, canonical} =
               exhausted_row!(identity, t0,
                 reset_at: fixed_anchor,
                 active_limit: 243,
                 credits: 0
               )

      candidate_status =
        if unsafe_observation == :candidate, do: unsafe_status, else: safe_status()

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 fixed_zero(candidate_at, fixed_anchor, candidate_status),
                 candidate_at,
                 candidate_at
               )

      confirmation_status =
        if unsafe_observation == :confirmation, do: unsafe_status, else: safe_status()

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 fixed_zero(confirmed_at, fixed_anchor, confirmation_status),
                 confirmed_at,
                 confirmed_at
               )

      persisted = Repo.get!(AccountQuotaWindow, canonical.id)
      assert Decimal.equal?(persisted.used_percent, Decimal.new("100"))
      assert persisted.active_limit == 243
      assert persisted.credits == 0
      refute CycleConfirmation.selector_valid?(persisted, confirmed_at)
      assert_exhausted_quota_truth(identity, persisted, confirmed_at)
    end
  end

  test "same-anchor confirmation rejects replayed, stale, future, and out-of-order evidence" do
    cases = [
      {:replayed_provider_time,
       fn candidate_at, confirmed_at, fixed_anchor ->
         safe_fixed_zero(confirmed_at, fixed_anchor, provider_at: candidate_at)
       end},
      {:stale_provider_time,
       fn candidate_at, confirmed_at, fixed_anchor ->
         safe_fixed_zero(confirmed_at, fixed_anchor,
           provider_at: DateTime.add(candidate_at, -20, :minute)
         )
       end},
      {:future_provider_time,
       fn _candidate_at, confirmed_at, fixed_anchor ->
         safe_fixed_zero(confirmed_at, fixed_anchor,
           provider_at: DateTime.add(confirmed_at, 1, :second)
         )
       end},
      {:future_event_time,
       fn _candidate_at, confirmed_at, fixed_anchor ->
         safe_fixed_zero(DateTime.add(confirmed_at, 1, :second), fixed_anchor,
           provider_at: confirmed_at
         )
       end},
      {:out_of_order_event,
       fn candidate_at, _confirmed_at, fixed_anchor ->
         safe_fixed_zero(candidate_at, fixed_anchor)
       end},
      {:stale_evidence,
       fn _candidate_at, confirmed_at, fixed_anchor ->
         confirmed_at
         |> safe_fixed_zero(fixed_anchor)
         |> Map.put(:freshness_state, "stale")
       end}
    ]

    for {_name, confirmation_for} <- cases do
      t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
      identity = identity!()
      fixed_anchor = DateTime.add(t0, 5, :day)
      candidate_at = DateTime.add(t0, 5, :minute)
      confirmed_at = DateTime.add(candidate_at, 180, :second)

      assert {:ok, canonical} =
               exhausted_row!(identity, t0,
                 reset_at: fixed_anchor,
                 active_limit: 243,
                 credits: 0
               )

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 safe_fixed_zero(candidate_at, fixed_anchor),
                 candidate_at,
                 candidate_at
               )

      confirmation = confirmation_for.(candidate_at, confirmed_at, fixed_anchor)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 confirmation,
                 confirmation.observed_at,
                 confirmed_at
               )

      persisted = Repo.get!(AccountQuotaWindow, canonical.id)
      assert Decimal.equal?(persisted.used_percent, Decimal.new("100"))
      assert persisted.active_limit == 243
      assert persisted.credits == 0
      refute CycleConfirmation.selector_valid?(persisted, confirmed_at)
    end
  end

  test "same-anchor confirmation rejects reset, identity, source, and window mismatches" do
    cases = [
      {:reset,
       fn evidence -> Map.put(evidence, :reset_at, DateTime.add(evidence.reset_at, 301)) end},
      {:identity, fn evidence -> Map.put(evidence, :quota_key, "other_account") end},
      {:source, fn evidence -> Map.put(evidence, :source, "codex_response_headers") end},
      {:window, fn evidence -> Map.put(evidence, :window_kind, "primary") end}
    ]

    for {_name, mismatch} <- cases do
      t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
      identity = identity!()
      fixed_anchor = DateTime.add(t0, 5, :day)
      candidate_at = DateTime.add(t0, 5, :minute)
      confirmed_at = DateTime.add(candidate_at, 180, :second)

      assert {:ok, canonical} = exhausted_row!(identity, t0, reset_at: fixed_anchor)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 safe_fixed_zero(candidate_at, fixed_anchor),
                 candidate_at,
                 candidate_at
               )

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 confirmed_at |> safe_fixed_zero(fixed_anchor) |> mismatch.(),
                 confirmed_at,
                 confirmed_at
               )

      persisted = Repo.get!(AccountQuotaWindow, canonical.id)
      assert Decimal.equal?(persisted.used_percent, Decimal.new("100"))
      refute CycleConfirmation.selector_valid?(persisted, confirmed_at)
    end
  end

  test "same-anchor confirmation cannot clear newer positive or partial pressure" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    fixed_anchor = DateTime.add(t0, 5, :day)
    candidate_at = DateTime.add(t0, 5, :minute)
    confirmed_at = DateTime.add(candidate_at, 180, :second)

    identity = identity!()
    assert {:ok, _row} = exhausted_row!(identity, t0, reset_at: fixed_anchor)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               safe_fixed_zero(candidate_at, fixed_anchor),
               candidate_at,
               candidate_at
             )

    positive_at = DateTime.add(candidate_at, 60, :second)
    assert {:ok, _row} = used_row!(identity, positive_at, "100", reset_at: fixed_anchor)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               safe_fixed_zero(confirmed_at, fixed_anchor),
               confirmed_at,
               confirmed_at
             )

    assert Decimal.equal?(account_row(identity).used_percent, Decimal.new("100"))

    partial_identity = identity!()
    assert {:ok, _row} = used_row!(partial_identity, t0, "31", reset_at: fixed_anchor)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               partial_identity,
               safe_fixed_zero(candidate_at, fixed_anchor),
               candidate_at,
               candidate_at
             )

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               partial_identity,
               safe_fixed_zero(confirmed_at, fixed_anchor),
               confirmed_at,
               confirmed_at
             )

    assert Decimal.equal?(account_row(partial_identity).used_percent, Decimal.new("31"))
  end

  test "matching model weekly rows cannot enter same-anchor account restart admission" do
    assert_scoped_same_anchor_restart_rejected("model", nil)
  end

  test "matching upstream-model weekly rows cannot enter same-anchor account restart admission" do
    assert_scoped_same_anchor_restart_rejected("upstream_model", "example-upstream-model")
  end

  test "a safe restart candidate status survives reload without changing the v1 candidate shape" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = exhausted_row!(identity, t0)

    t1 = DateTime.add(t0, 300, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(t1,
                 metadata: %{
                   "rate_limit_allowed" => true,
                   "rate_limit_reached" => false,
                   "reset_after_seconds" => @window_seconds
                 }
               ),
               t1,
               t1
             )

    row = account_row(identity)
    candidate = row.metadata["__quota_confirmed_candidate_v1"]

    assert map_size(candidate) == 5

    assert row.metadata["__quota_candidate_provider_status_v1"] == %{
             "version" => 1,
             "allowed" => true,
             "limit_reached" => false,
             "observed_at" => DateTime.to_iso8601(t1)
           }

    reloaded = Repo.get!(AccountQuotaWindow, row.id)

    assert {:ok, %{allowed: true, limit_reached: false, observed_at: ^t1}} =
             EvidenceStore.parse_candidate_provider_status(reloaded.metadata)

    assert EvidenceStore.candidate_provider_status_safe?(reloaded.metadata)
  end

  test "candidate provider status rejects legacy, orphaned, malformed, mismatched, and unsafe state" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)

    cases = [
      {:legacy_candidate_without_status, fn metadata, _observed_at -> metadata end},
      {:orphan_status,
       fn metadata, observed_at ->
         metadata
         |> Map.delete("__quota_confirmed_candidate_v1")
         |> Map.put("__quota_candidate_provider_status_v1", safe_candidate_status(observed_at))
       end},
      {:malformed_status,
       fn metadata, observed_at ->
         Map.put(metadata, "__quota_candidate_provider_status_v1", %{
           "version" => 1,
           "allowed" => true,
           "limit_reached" => false,
           "observed_at" => DateTime.to_iso8601(observed_at),
           "extra" => true
         })
       end},
      {:timestamp_mismatch,
       fn metadata, observed_at ->
         Map.put(
           metadata,
           "__quota_candidate_provider_status_v1",
           safe_candidate_status(DateTime.add(observed_at, 1, :second))
         )
       end},
      {:non_boolean_status,
       fn metadata, observed_at ->
         Map.put(metadata, "__quota_candidate_provider_status_v1", %{
           "version" => 1,
           "allowed" => "true",
           "limit_reached" => false,
           "observed_at" => DateTime.to_iso8601(observed_at)
         })
       end},
      {:contradictory_status,
       fn metadata, observed_at ->
         Map.put(metadata, "__quota_candidate_provider_status_v1", %{
           "version" => 1,
           "allowed" => true,
           "limit_reached" => true,
           "observed_at" => DateTime.to_iso8601(observed_at)
         })
       end}
    ]

    for {_case_name, metadata_for} <- cases do
      identity = identity!()
      assert {:ok, _row} = exhausted_row!(identity, t0)
      candidate_at = DateTime.add(t0, 300, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 floating_zero(candidate_at),
                 candidate_at,
                 candidate_at
               )

      row = account_row(identity)

      row
      |> Ecto.Changeset.change(metadata: metadata_for.(row.metadata, candidate_at))
      |> Repo.update!()

      reloaded = Repo.get!(AccountQuotaWindow, row.id)
      assert :none = EvidenceStore.parse_candidate_provider_status(reloaded.metadata)
      refute EvidenceStore.candidate_provider_status_safe?(reloaded.metadata)
    end
  end

  test "a later accepted positive observation clears candidate and provider status state" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_reset = DateTime.add(t0, 5, :day)

    assert {:ok, _row} = exhausted_row!(identity, t0, reset_at: canonical_reset)

    candidate_at = DateTime.add(t0, 300, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(candidate_at,
                 metadata: %{
                   "rate_limit_allowed" => true,
                   "rate_limit_reached" => false,
                   "reset_after_seconds" => @window_seconds
                 }
               ),
               candidate_at,
               candidate_at
             )

    assert {:ok, _row} =
             used_row!(identity, DateTime.add(candidate_at, 60, :second), "100",
               reset_at: canonical_reset
             )

    row = account_row(identity)
    refute Map.has_key?(row.metadata, "__quota_confirmed_candidate_v1")
    refute Map.has_key?(row.metadata, "__quota_candidate_provider_status_v1")
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

  test "a forward-anchored restart without provider timing cannot clear exhaustion" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = exhausted_row!(identity, t0)

    candidate_at = DateTime.add(t0, 5, :minute)
    forward_anchor = DateTime.add(candidate_at, @window_seconds, :second)

    resetless_candidate =
      candidate_at
      |> floating_zero(reset_at: forward_anchor)
      |> Map.put(:metadata, %{})

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               resetless_candidate,
               candidate_at,
               candidate_at
             )

    confirmation_at = DateTime.add(candidate_at, 4, :minute)

    resetless_confirmation =
      confirmation_at
      |> floating_zero(reset_at: forward_anchor)
      |> Map.put(:metadata, %{})

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               resetless_confirmation,
               confirmation_at,
               confirmation_at
             )

    row = account_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("100"))
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  test "sliding live restart observations converge a partially-used weekly account" do
    # A mid-cycle provider reset on an account that was NOT exhausted (e.g. a
    # 31%-used row) must converge through the same candidate proofs instead of
    # waiting days for the old cycle to expire.
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = used_row!(identity, t0, "31")

    t1 = DateTime.add(t0, 300, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t1), t1)
    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("31")) == :eq

    t2 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(t2), t2)
    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
    assert DateTime.compare(row.observed_at, t2) == :eq
  end

  test "a cached fixed-reset zero neither lowers nor keeps refreshing a partially-used row" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    same_cycle_reset = DateTime.add(t0, 5, :day)
    assert {:ok, _row} = used_row!(identity, t0, "31", reset_at: same_cycle_reset)

    # The replayed body keeps the same fixed reset: no sliding, no forward
    # anchor, no expired cycle — quarantined no matter how often it repeats,
    # and it no longer stamps the contradicted row fresh on every replay.
    for minute <- 1..16 do
      observed_at = DateTime.add(t0, minute, :minute)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 floating_zero(observed_at, reset_at: same_cycle_reset),
                 observed_at,
                 observed_at
               )
    end

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("31")) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
    assert Evidence.current_freshness_state(row, DateTime.add(t0, 16, :minute)) == "stale"
  end

  test "a restart candidate expires before a later sliding sequence can confirm it" do
    t0 = DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = used_row!(identity, t0, "31")

    first_candidate_at = DateTime.add(t0, 60, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(first_candidate_at),
               first_candidate_at,
               first_candidate_at
             )

    expired_candidate_at = DateTime.add(first_candidate_at, 16, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(expired_candidate_at),
               expired_candidate_at,
               expired_candidate_at
             )

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("31")) == :eq

    confirmed_at = DateTime.add(expired_candidate_at, 4, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(confirmed_at),
               confirmed_at,
               confirmed_at
             )

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
    assert DateTime.compare(row.observed_at, confirmed_at) == :eq
  end

  test "a fixed forward reset cannot clear a partially-used row without runtime evidence" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = used_row!(identity, t0, "31")

    t1 = DateTime.add(t0, 300, :second)
    forward_anchor = DateTime.add(t1, @window_seconds, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t1, reset_at: forward_anchor), t1)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("31")) == :eq

    t2 = DateTime.add(t1, 240, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t2, reset_at: forward_anchor), t2)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("31")) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  test "an expired partially-used row converges through the candidate span" do
    # Previously an expired non-exhausted row took the single-observation
    # :incoming fast path; the widened chokepoint deliberately trades that
    # immediacy for the same cache-safe confirmation the exhausted family has.
    t0 = DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = used_row!(identity, t0, "31", reset_at: DateTime.add(t0, 1, :hour))

    t1 = DateTime.utc_now() |> DateTime.add(-6, :minute) |> DateTime.truncate(:microsecond)
    anchored_reset = DateTime.add(t1, @window_seconds, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t1, reset_at: anchored_reset), t1)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("31")) == :eq

    t2 = DateTime.add(t1, 240, :second)

    assert {:ok, _row} =
             Windows.record_evidence(identity, floating_zero(t2, reset_at: anchored_reset), t2)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
  end

  test "an anchored idle zero row keeps refreshing through the same-cycle sync" do
    # The chokepoint must NOT capture zero-over-zero observations: an anchored
    # idle account produces identical bodies (fixed reset, no usage), no
    # sliding proof can ever fire, and losing the same-cycle sync would starve
    # the row stale and fail routing closed on a perfectly healthy account.
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    anchored_reset = DateTime.add(t0, 5, :day)

    assert {:ok, _row} =
             used_row!(identity, t0, "0",
               reset_at: anchored_reset,
               metadata: %{
                 "reset_after_seconds" => DateTime.diff(anchored_reset, t0, :second)
               }
             )

    for minute <- 1..16 do
      observed_at = DateTime.add(t0, minute, :minute)
      response_latency_seconds = 180
      persisted_at = DateTime.add(observed_at, response_latency_seconds, :second)

      remaining_seconds =
        DateTime.diff(anchored_reset, observed_at, :second) - response_latency_seconds

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 floating_zero(observed_at,
                   reset_at: anchored_reset,
                   reset_after_seconds: remaining_seconds
                 ),
                 observed_at,
                 persisted_at
               )
    end

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("0")) == :eq
    assert DateTime.compare(row.observed_at, DateTime.add(t0, 16, :minute)) == :eq
    assert Evidence.current_freshness_state(row, DateTime.add(t0, 16, :minute)) == "fresh"
    assert row.freshness_state == "fresh"

    assert %{eligible?: true, routing_state: :weekly_only_probe} =
             Routing.eligibility_from_windows([row], at: row.observed_at)
  end

  test "a bounded idle zero reanchor requires a strictly later provider observation" do
    t0 = DateTime.utc_now() |> DateTime.add(-12, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_reset = DateTime.add(t0, 5, :day)
    canonical_reset_after = DateTime.diff(canonical_reset, t0, :second)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               floating_zero(t0,
                 reset_at: canonical_reset,
                 reset_after_seconds: canonical_reset_after
               ),
               t0
             )

    candidate_at = DateTime.add(t0, 5, :minute)
    drifted_reset = DateTime.add(canonical_reset, 301, :second)
    candidate_reset_after = DateTime.diff(drifted_reset, candidate_at, :second)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               floating_zero(candidate_at,
                 reset_at: drifted_reset,
                 reset_after_seconds: candidate_reset_after
               ),
               candidate_at
             )

    equal_provider_at = DateTime.add(candidate_at, 4, :minute)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               floating_zero(equal_provider_at,
                 reset_at: drifted_reset,
                 reset_after_seconds: candidate_reset_after
               ),
               equal_provider_at
             )

    pending = account_row(identity)
    assert DateTime.compare(pending.reset_at, canonical_reset) == :eq
    assert DateTime.compare(pending.observed_at, t0) == :eq

    advanced_at = DateTime.add(equal_provider_at, 1, :second)
    advanced_reset_after = candidate_reset_after - 1

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               floating_zero(advanced_at,
                 reset_at: drifted_reset,
                 reset_after_seconds: advanced_reset_after
               ),
               advanced_at
             )

    confirmed = account_row(identity)
    assert Decimal.equal?(confirmed.used_percent, Decimal.new("0"))
    assert DateTime.compare(confirmed.reset_at, drifted_reset) == :eq
    assert DateTime.compare(confirmed.observed_at, advanced_at) == :eq

    replayed_at = DateTime.add(advanced_at, 1, :minute)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               floating_zero(replayed_at,
                 reset_at: drifted_reset,
                 reset_after_seconds: advanced_reset_after
               ),
               replayed_at
             )

    replayed = account_row(identity)
    assert DateTime.compare(replayed.reset_at, drifted_reset) == :eq
    assert DateTime.compare(replayed.observed_at, advanced_at) == :eq

    stale_at = DateTime.add(t0, -20, :minute)

    stale_exhausted = %{
      replayed
      | id: Ecto.UUID.generate(),
        used_percent: Decimal.new("100"),
        reset_at: canonical_reset,
        observed_at: stale_at,
        last_sync_at: stale_at,
        freshness_state: "stale",
        metadata: %{}
    }

    result = Routing.eligibility_from_windows([stale_exhausted, replayed], at: replayed_at)

    assert result.eligible?
    assert result.routing_state == :weekly_only_probe
    assert result.selection.secondary == replayed
    refute result.selection.secondary.id == stale_exhausted.id
  end

  test "a cached superseded reset cannot keep an accepted weekly zero fresh" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    new_cycle_reset = DateTime.add(t0, 5, :day)

    assert {:ok, _row} =
             used_row!(identity, t0, "0",
               reset_at: new_cycle_reset,
               metadata: %{
                 "reset_after_seconds" => DateTime.diff(new_cycle_reset, t0, :second)
               }
             )

    # The superseded reset is still future-dated and only two days behind the
    # canonical, so freshness and the broad same-cycle drift bound alone cannot
    # identify the replay. Its fixed reset_after_seconds signature can: it no
    # longer agrees with reset_at - observed_at as wall time advances.
    cached_reset = DateTime.add(t0, 3, :day)

    for minute <- 1..16 do
      observed_at = DateTime.add(t0, minute, :minute)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 floating_zero(observed_at, reset_at: cached_reset),
                 observed_at,
                 observed_at
               )
    end

    row = account_row(identity)
    assert DateTime.compare(row.observed_at, t0) == :eq
    assert Evidence.current_freshness_state(row, DateTime.add(t0, 16, :minute)) == "stale"

    fresh_identity = identity!()
    assert {:ok, _row} = used_row!(fresh_identity, t0, "0", reset_at: new_cycle_reset)

    # Same-cycle backward drift (well inside the window duration) still
    # refreshes when its relative timing agrees with the observation.
    drifted_reset = DateTime.add(new_cycle_reset, -3600, :second)
    observed_at = DateTime.add(t0, 600, :second)
    remaining_seconds = DateTime.diff(drifted_reset, observed_at, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               fresh_identity,
               floating_zero(observed_at,
                 reset_at: drifted_reset,
                 reset_after_seconds: remaining_seconds
               ),
               observed_at,
               observed_at
             )

    row = account_row(fresh_identity)
    assert DateTime.compare(row.observed_at, observed_at) == :eq
    assert row.freshness_state == "fresh"
  end

  test "advancing cached provider timestamps cannot revive stale weekly zero evidence" do
    t0 = DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_reset = DateTime.add(t0, 5, :day)

    assert {:ok, _row} =
             used_row!(identity, t0, "0",
               reset_at: canonical_reset,
               metadata: %{
                 "reset_after_seconds" => DateTime.diff(canonical_reset, t0, :second)
               }
             )

    replayed_at = DateTime.add(t0, 20, :minute)
    cached_provider_at = DateTime.add(t0, 1, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(replayed_at,
                 reset_at: canonical_reset,
                 reset_after_seconds: DateTime.diff(canonical_reset, cached_provider_at, :second)
               ),
               replayed_at,
               replayed_at
             )

    row = account_row(identity)
    assert DateTime.compare(row.observed_at, t0) == :eq
    assert Evidence.current_freshness_state(row, replayed_at) == "stale"
  end

  test "a future provider timestamp cannot poison later weekly zero refreshes" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_reset = DateTime.add(t0, 5, :day)

    assert {:ok, _row} =
             used_row!(identity, t0, "0",
               reset_at: canonical_reset,
               metadata: %{
                 "reset_after_seconds" => DateTime.diff(canonical_reset, t0, :second)
               }
             )

    malformed_at = DateTime.add(t0, 60, :second)
    future_provider_at = DateTime.add(malformed_at, 10, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(malformed_at,
                 reset_at: canonical_reset,
                 reset_after_seconds: DateTime.diff(canonical_reset, future_provider_at, :second)
               ),
               malformed_at,
               malformed_at
             )

    assert DateTime.compare(account_row(identity).observed_at, t0) == :eq

    healthy_at = DateTime.add(t0, 2, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(healthy_at,
                 reset_at: canonical_reset,
                 reset_after_seconds: DateTime.diff(canonical_reset, healthy_at, :second)
               ),
               healthy_at,
               healthy_at
             )

    row = account_row(identity)
    assert DateTime.compare(row.observed_at, healthy_at) == :eq

    assert row.metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(healthy_at)
  end

  test "a valid provider timestamp recovers from an invalid stored liveness marker" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_reset = DateTime.add(t0, 5, :day)
    poisoned_provider_at = DateTime.add(t0, 1, :day)

    assert {:ok, _row} =
             used_row!(identity, t0, "0",
               reset_at: canonical_reset,
               metadata: %{
                 "reset_after_seconds" => DateTime.diff(canonical_reset, t0, :second),
                 "__quota_relative_liveness_v1" => DateTime.to_iso8601(poisoned_provider_at)
               }
             )

    healthy_at = DateTime.add(t0, 60, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(healthy_at,
                 reset_at: canonical_reset,
                 reset_after_seconds: DateTime.diff(canonical_reset, healthy_at, :second)
               ),
               healthy_at,
               healthy_at
             )

    row = account_row(identity)
    assert DateTime.compare(row.observed_at, healthy_at) == :eq

    assert row.metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(healthy_at)
  end

  test "a first weekly row with present invalid relative timing is rejected" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for reset_after_seconds <- [
          "invalid",
          @window_seconds + 20 * 60,
          @window_seconds - 10 * 60
        ] do
      identity = identity!()

      attrs =
        observed_at
        |> floating_zero(reset_after_seconds: reset_after_seconds)
        |> Map.put(:used_percent, Decimal.new("31"))

      assert {:error, %{code: :invalid_relative_weekly_timing}} =
               EvidenceStore.record_evidence(identity, attrs, observed_at, observed_at)

      assert account_row(identity) == nil
    end
  end

  test "a cached explicit weekly zero without relative timing cannot keep the row fresh" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_reset = DateTime.add(t0, 5, :day)
    cached_reset = DateTime.add(t0, 3, :day)

    assert {:ok, _row} =
             used_row!(identity, t0, "0",
               reset_at: canonical_reset,
               metadata: %{
                 "reset_after_seconds" => DateTime.diff(canonical_reset, t0, :second)
               }
             )

    for minute <- 1..16 do
      observed_at = DateTime.add(t0, minute, :minute)
      evidence = explicit_account_weekly_zero!(observed_at, cached_reset)
      refute Map.has_key?(evidence.metadata, "reset_after_seconds")

      assert {:ok, _row} =
               EvidenceStore.record_evidence(identity, evidence, observed_at, observed_at)
    end

    row = account_row(identity)
    assert DateTime.compare(row.observed_at, t0) == :eq
    assert Evidence.current_freshness_state(row, DateTime.add(t0, 16, :minute)) == "stale"
  end

  test "sliding live zeroes keep an accepted weekly zero fresh beyond the ttl" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()

    assert {:ok, _row} =
             used_row!(identity, t0, "0", reset_at: DateTime.add(t0, @window_seconds, :second))

    for minute <- 1..16 do
      observed_at = DateTime.add(t0, minute, :minute)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 floating_zero(observed_at),
                 observed_at,
                 observed_at
               )
    end

    row = account_row(identity)
    assert DateTime.diff(row.observed_at, t0, :minute) >= 12
    assert Evidence.current_freshness_state(row, DateTime.add(t0, 16, :minute)) == "fresh"
  end

  test "sliding live zeroes recover an accepted weekly zero after it becomes stale" do
    t0 = DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()

    assert {:ok, _row} =
             used_row!(identity, t0, "0", reset_at: DateTime.add(t0, @window_seconds, :second))

    stale_at = DateTime.add(t0, 16, :minute)
    assert Evidence.current_freshness_state(account_row(identity), stale_at) == "stale"

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(stale_at),
               stale_at,
               stale_at
             )

    assert DateTime.compare(account_row(identity).observed_at, t0) == :eq

    confirmed_at = DateTime.add(stale_at, 4, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(confirmed_at),
               confirmed_at,
               confirmed_at
             )

    row = account_row(identity)
    assert DateTime.compare(row.observed_at, confirmed_at) == :eq
    assert Evidence.current_freshness_state(row, confirmed_at) == "fresh"
  end

  test "delayed sliding zeroes cannot clear a newer partially-used observation" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_at = DateTime.add(t0, 10, :minute)
    assert {:ok, _row} = used_row!(identity, canonical_at, "31")

    delayed_first_at = DateTime.add(t0, 2, :minute)
    delayed_second_at = DateTime.add(t0, 6, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               delayed_first_at
               |> floating_zero()
               |> Map.put(:active_limit, 100)
               |> Map.put(:credits, 100),
               delayed_first_at,
               canonical_at
             )

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               delayed_second_at
               |> floating_zero()
               |> Map.put(:active_limit, 100)
               |> Map.put(:credits, 100),
               delayed_second_at,
               canonical_at
             )

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("31")) == :eq
    assert DateTime.compare(row.observed_at, canonical_at) == :eq
  end

  test "two stale sliding snapshots cannot confirm an account weekly restart" do
    t0 = DateTime.utc_now() |> DateTime.add(-40, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = used_row!(identity, t0, "31")

    first_replay_at = DateTime.add(t0, 30, :minute)
    first_provider_at = DateTime.add(t0, 1, :minute)
    first_reset = DateTime.add(first_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(first_replay_at,
                 reset_at: first_reset,
                 reset_after_seconds: @window_seconds
               ),
               first_replay_at,
               first_replay_at
             )

    second_replay_at = DateTime.add(first_replay_at, 4, :minute)
    second_provider_at = DateTime.add(first_provider_at, 4, :minute)
    second_reset = DateTime.add(second_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(second_replay_at,
                 reset_at: second_reset,
                 reset_after_seconds: @window_seconds
               ),
               second_replay_at,
               second_replay_at
             )

    row = account_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("31"))
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  test "an invalid second snapshot cannot confirm a valid account restart candidate" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = used_row!(identity, t0, "31")

    candidate_at = DateTime.add(t0, 5, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(candidate_at),
               candidate_at,
               candidate_at
             )

    assert {:ok, _candidate} = EvidenceStore.parse_candidate(account_row(identity).metadata)

    invalid_at = DateTime.add(candidate_at, 4, :minute)
    stale_provider_at = DateTime.add(t0, -20, :minute)
    stale_reset = DateTime.add(stale_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(invalid_at,
                 reset_at: stale_reset,
                 reset_after_seconds: @window_seconds
               ),
               invalid_at,
               invalid_at
             )

    row = account_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("31"))
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  test "advancing account candidates older than canonical provider time cannot rewind it" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_reset = DateTime.add(t0, 5, :day)
    canonical_remaining = DateTime.diff(canonical_reset, t0, :second)

    assert {:ok, _row} =
             used_row!(identity, t0, "31",
               reset_at: canonical_reset,
               metadata: %{"reset_after_seconds" => canonical_remaining}
             )

    first_observed_at = DateTime.add(t0, 60, :second)
    first_provider_at = DateTime.add(t0, -5, :minute)
    first_reset = DateTime.add(first_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(first_observed_at, reset_at: first_reset),
               first_observed_at,
               first_observed_at
             )

    second_observed_at = DateTime.add(first_observed_at, 4, :minute)
    second_provider_at = DateTime.add(first_provider_at, 4, :minute)
    second_reset = DateTime.add(second_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(second_observed_at, reset_at: second_reset),
               second_observed_at,
               second_observed_at
             )

    row = account_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("31"))
    assert DateTime.compare(row.reset_at, canonical_reset) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
    assert row.metadata["reset_after_seconds"] == canonical_remaining
    refute Map.has_key?(row.metadata, "__quota_relative_candidate_liveness_v1")
  end

  test "positive account refresh advances the canonical provider watermark" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_reset = DateTime.add(t0, @window_seconds, :second)

    assert {:ok, _row} =
             used_row!(identity, t0, "31",
               reset_at: canonical_reset,
               metadata: %{"reset_after_seconds" => @window_seconds}
             )

    canonical_provider_at = DateTime.add(t0, 6, :minute)
    canonical_remaining = DateTime.diff(canonical_reset, canonical_provider_at, :second)

    positive_refresh =
      canonical_provider_at
      |> floating_zero(
        reset_at: canonical_reset,
        reset_after_seconds: canonical_remaining
      )
      |> Map.put(:used_percent, Decimal.new("40"))

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               positive_refresh,
               canonical_provider_at,
               canonical_provider_at
             )

    first_observed_at = DateTime.add(canonical_provider_at, 60, :second)
    first_provider_at = DateTime.add(t0, 2, :minute)
    first_reset = DateTime.add(first_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(first_observed_at, reset_at: first_reset),
               first_observed_at,
               first_observed_at
             )

    second_observed_at = DateTime.add(first_observed_at, 3, :minute)
    second_provider_at = DateTime.add(first_provider_at, 3, :minute)
    second_reset = DateTime.add(second_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(second_observed_at, reset_at: second_reset),
               second_observed_at,
               second_observed_at
             )

    row = account_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("40"))
    assert DateTime.compare(row.reset_at, canonical_reset) == :eq
    assert DateTime.compare(row.observed_at, canonical_provider_at) == :eq

    assert row.metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(canonical_provider_at)

    refute Map.has_key?(row.metadata, "__quota_relative_candidate_liveness_v1")
  end

  test "invalid capacity-bearing positive timing cannot stale the canonical watermark" do
    for timing <- [:stale, :future, :malformed] do
      t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
      identity = identity!()
      canonical_reset = DateTime.add(t0, @window_seconds, :second)

      assert {:ok, _row} =
               used_row!(identity, t0, "31",
                 reset_at: canonical_reset,
                 metadata: %{"reset_after_seconds" => @window_seconds}
               )

      invalid_at = DateTime.add(t0, 6, :minute)

      invalid_metadata =
        case timing do
          :stale ->
            stale_provider_at = DateTime.add(t0, -20, :minute)

            %{
              "reset_after_seconds" => DateTime.diff(canonical_reset, stale_provider_at, :second)
            }

          :future ->
            future_provider_at = DateTime.add(invalid_at, 10, :minute)

            %{
              "reset_after_seconds" => DateTime.diff(canonical_reset, future_provider_at, :second)
            }

          :malformed ->
            %{"reset_after_seconds" => "invalid"}
        end

      invalid_positive =
        invalid_at
        |> floating_zero(reset_at: canonical_reset)
        |> Map.merge(%{
          active_limit: 100,
          credits: 60,
          used_percent: Decimal.new("40"),
          metadata: invalid_metadata
        })

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 invalid_positive,
                 invalid_at,
                 invalid_at
               )

      rejected = account_row(identity)
      assert Decimal.equal?(rejected.used_percent, Decimal.new("31"))
      assert DateTime.compare(rejected.observed_at, t0) == :eq

      recovery_at = DateTime.add(invalid_at, 60, :second)
      recovery_remaining = DateTime.diff(canonical_reset, recovery_at, :second)

      valid_positive =
        recovery_at
        |> floating_zero(
          reset_at: canonical_reset,
          reset_after_seconds: recovery_remaining
        )
        |> Map.merge(%{
          active_limit: 100,
          credits: 60,
          used_percent: Decimal.new("40")
        })

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 valid_positive,
                 recovery_at,
                 recovery_at
               )

      first_observed_at = DateTime.add(recovery_at, 60, :second)
      first_provider_at = DateTime.add(t0, 2, :minute)
      first_reset = DateTime.add(first_provider_at, @window_seconds, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 floating_zero(first_observed_at, reset_at: first_reset),
                 first_observed_at,
                 first_observed_at
               )

      second_observed_at = DateTime.add(first_observed_at, 3, :minute)
      second_provider_at = DateTime.add(first_provider_at, 3, :minute)
      second_reset = DateTime.add(second_provider_at, @window_seconds, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 floating_zero(second_observed_at, reset_at: second_reset),
                 second_observed_at,
                 second_observed_at
               )

      row = account_row(identity)
      assert Decimal.equal?(row.used_percent, Decimal.new("40"))
      assert DateTime.compare(row.observed_at, recovery_at) == :eq
      assert row.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(recovery_at)
    end
  end

  test "a restart candidate older than newer positive usage cannot clear it" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = used_row!(identity, t0, "31")

    candidate_at = DateTime.add(t0, 60, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(candidate_at),
               candidate_at,
               candidate_at
             )

    newer_positive_at = DateTime.add(t0, 120, :second)

    resetless_positive =
      newer_positive_at
      |> floating_zero()
      |> Map.put(:used_percent, Decimal.new("40"))
      |> Map.put(:reset_at, nil)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               resetless_positive,
               newer_positive_at,
               newer_positive_at
             )

    positive_row = account_row(identity)
    refute Map.has_key?(positive_row.metadata, "__quota_confirmed_candidate_v1")
    refute Map.has_key?(positive_row.metadata, "__quota_relative_candidate_liveness_v1")

    confirmation_at = DateTime.add(candidate_at, 240, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(confirmation_at),
               confirmation_at,
               confirmation_at
             )

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("40")) == :eq
    assert DateTime.compare(row.observed_at, newer_positive_at) == :eq
  end

  test "a first positive without provider timing blocks provider-older restart candidates" do
    positive_at =
      DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)

    identity = identity!()

    positive =
      positive_at
      |> floating_zero()
      |> Map.put(:used_percent, Decimal.new("70"))
      |> Map.put(:reset_at, nil)
      |> Map.put(:metadata, %{})

    assert {:ok, _row} =
             EvidenceStore.record_evidence(identity, positive, positive_at, positive_at)

    for {provider_delta, observed_delta} <- [{-300, 60}, {-60, 300}] do
      provider_at = DateTime.add(positive_at, provider_delta, :second)
      observed_at = DateTime.add(positive_at, observed_delta, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 floating_zero(observed_at,
                   reset_at: DateTime.add(provider_at, @window_seconds, :second)
                 ),
                 observed_at,
                 observed_at
               )
    end

    row = account_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("70"))
    assert DateTime.compare(row.observed_at, positive_at) == :eq
    assert row.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(positive_at)
  end

  test "a markerless legacy positive blocks provider-older restart candidates" do
    positive_at =
      DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)

    identity = identity!()
    assert {:ok, _row} = used_row!(identity, positive_at, "31")

    legacy_row = account_row(identity)

    legacy_row
    |> Ecto.Changeset.change(metadata: %{})
    |> Repo.update!()

    for {provider_delta, observed_delta} <- [{-300, 60}, {-60, 300}] do
      provider_at = DateTime.add(positive_at, provider_delta, :second)
      observed_at = DateTime.add(positive_at, observed_delta, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 floating_zero(observed_at,
                   reset_at: DateTime.add(provider_at, @window_seconds, :second)
                 ),
                 observed_at,
                 observed_at
               )
    end

    row = account_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("31"))
    assert DateTime.compare(row.observed_at, positive_at) == :eq
    refute Map.has_key?(row.metadata, "__quota_confirmed_candidate_v1")
  end

  test "confirmed account restart stores its provider watermark monotonically" do
    p0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = used_row!(identity, p0, "31")

    p1 = DateTime.add(p0, 5, :minute)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(p1), p1)

    p2 = DateTime.add(p1, 4, :minute)
    assert {:ok, _row} = Windows.record_evidence(identity, floating_zero(p2), p2)

    accepted = account_row(identity)
    assert Decimal.equal?(accepted.used_percent, Decimal.new("0"))
    assert DateTime.compare(accepted.observed_at, p2) == :eq
    assert accepted.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(p2)

    stale_provider_at = DateTime.add(p0, 7, :minute)
    replayed_at = DateTime.add(p2, 60, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               floating_zero(replayed_at,
                 reset_at: DateTime.add(stale_provider_at, @window_seconds, :second)
               ),
               replayed_at,
               replayed_at
             )

    row = account_row(identity)
    assert DateTime.compare(row.observed_at, p2) == :eq
    assert row.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(p2)
  end

  test "an accepted cached positive cannot rewind the provider watermark" do
    base = DateTime.utc_now() |> DateTime.add(-14, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_provider_at = DateTime.add(base, 6, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               canonical_provider_at
               |> floating_zero()
               |> Map.put(:used_percent, Decimal.new("31")),
               canonical_provider_at,
               canonical_provider_at
             )

    cached_positive_at = DateTime.add(base, 7, :minute)

    cached_positive =
      cached_positive_at
      |> floating_zero(reset_at: DateTime.add(base, @window_seconds, :second))
      |> Map.put(:used_percent, Decimal.new("40"))

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               cached_positive,
               cached_positive_at,
               cached_positive_at
             )

    assert account_row(identity).metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(canonical_provider_at)

    for {provider_delta, observed_delta} <- [{60, 8 * 60}, {5 * 60, 12 * 60}] do
      provider_at = DateTime.add(base, provider_delta, :second)
      observed_at = DateTime.add(base, observed_delta, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 floating_zero(observed_at,
                   reset_at: DateTime.add(provider_at, @window_seconds, :second)
                 ),
                 observed_at,
                 observed_at
               )
    end

    row = account_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("40"))
    assert DateTime.compare(row.observed_at, cached_positive_at) == :eq

    assert row.metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(canonical_provider_at)
  end

  test "a cached positive cannot rewind a legacy reset-derived provider watermark" do
    base = DateTime.utc_now() |> DateTime.add(-14, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    legacy_provider_at = DateTime.add(base, 6, :minute)
    legacy_reset_at = DateTime.add(legacy_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             used_row!(identity, legacy_provider_at, "31",
               reset_at: legacy_reset_at,
               metadata: %{"reset_after_seconds" => @window_seconds}
             )

    legacy_row = account_row(identity)

    legacy_row
    |> Ecto.Changeset.change(
      metadata: Map.delete(legacy_row.metadata, "__quota_relative_liveness_v1")
    )
    |> Repo.update!()

    cached_positive_at = DateTime.add(base, 7, :minute)

    cached_positive =
      cached_positive_at
      |> floating_zero(reset_at: DateTime.add(base, @window_seconds, :second))
      |> Map.put(:used_percent, Decimal.new("40"))

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               cached_positive,
               cached_positive_at,
               cached_positive_at
             )

    assert account_row(identity).metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(legacy_provider_at)

    for {provider_delta, observed_delta} <- [{60, 8 * 60}, {5 * 60, 12 * 60}] do
      provider_at = DateTime.add(base, provider_delta, :second)
      observed_at = DateTime.add(base, observed_delta, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 floating_zero(observed_at,
                   reset_at: DateTime.add(provider_at, @window_seconds, :second)
                 ),
                 observed_at,
                 observed_at
               )
    end

    row = account_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("40"))
    assert DateTime.compare(row.observed_at, cached_positive_at) == :eq

    assert row.metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(legacy_provider_at)
  end

  test "provider proof is non-future while generic evidence freshness keeps its skew allowance" do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    cases = [
      {-Evidence.freshness_ttl_seconds(), true},
      {0, true},
      {-Evidence.freshness_ttl_seconds() - 1, false},
      {1, false}
    ]

    for {provider_delta, candidate?} <- cases do
      identity = identity!()
      existing_at = DateTime.add(timestamp, -30, :minute)
      assert {:ok, _row} = used_row!(identity, existing_at, "31")
      provider_at = DateTime.add(timestamp, provider_delta, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 floating_zero(timestamp,
                   reset_at: DateTime.add(provider_at, @window_seconds, :second)
                 ),
                 timestamp,
                 timestamp
               )

      if candidate? do
        assert Map.has_key?(account_row(identity).metadata, "__quota_confirmed_candidate_v1")
      else
        refute Map.has_key?(account_row(identity).metadata, "__quota_confirmed_candidate_v1")
      end
    end

    future_within_skew = %{
      freshness_state: "fresh",
      observed_at: DateTime.add(timestamp, Evidence.future_observed_skew_seconds(), :second),
      reset_at: DateTime.add(timestamp, 1, :day)
    }

    assert Evidence.current_freshness_state(future_within_skew, timestamp) == "fresh"

    future_beyond_skew = %{
      future_within_skew
      | observed_at: DateTime.add(timestamp, Evidence.future_observed_skew_seconds() + 1, :second)
    }

    assert Evidence.current_freshness_state(future_beyond_skew, timestamp) == "stale"
  end

  test "a resetless weekly zero cannot crash or clear a partially-used observation" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = used_row!(identity, t0, "31")
    observed_at = DateTime.add(t0, 5, :minute)

    malformed_zero =
      observed_at
      |> floating_zero()
      |> Map.put(:reset_at, nil)
      |> Map.put(:metadata, "invalid")

    assert {:ok, normalized} = Evidence.new(malformed_zero, observed_at)
    assert normalized.metadata == %{}

    resetless_zero =
      malformed_zero
      |> Map.put(:metadata, %{"reset_after_seconds" => @window_seconds})
      |> Map.put(:active_limit, 100)
      |> Map.put(:credits, 100)

    assert {:ok, _row} = Windows.record_evidence(identity, resetless_zero, observed_at)

    row = account_row(identity)
    assert Decimal.compare(row.used_percent, Decimal.new("31")) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  defp capture_info_log(fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  defp safe_candidate_status(observed_at) do
    %{
      "version" => 1,
      "allowed" => true,
      "limit_reached" => false,
      "observed_at" => DateTime.to_iso8601(observed_at)
    }
  end

  defp assert_exhausted_quota_truth(identity, persisted, as_of) do
    assert Decimal.equal?(persisted.used_percent, Decimal.new("100"))

    assert %{
             eligible?: false,
             routing_state: :blocked,
             exclusions: [%{code: "quota_weekly_exhausted", reason_codes: ["exhausted"]}],
             selection: %{
               secondary: %AccountQuotaWindow{id: persisted_id},
               blocked_windows: [%AccountQuotaWindow{id: blocked_id}]
             }
           } = Windows.routing_quota_eligibility(identity, at: as_of)

    assert persisted_id == persisted.id
    assert blocked_id == persisted.id

    assert %{allowed: false, limit_reached: true, secondary_window: %{used_percent: 100}} =
             codex_rate_limit(identity, as_of)
  end

  defp assert_reset_quota_truth(identity, persisted, as_of) do
    assert Decimal.equal?(persisted.used_percent, Decimal.new("0"))

    assert %{
             eligible?: true,
             routing_state: :weekly_only_probe,
             exclusions: [],
             selection: %{
               secondary: %AccountQuotaWindow{id: persisted_id},
               blocked_windows: []
             }
           } = Windows.routing_quota_eligibility(identity, at: as_of)

    assert persisted_id == persisted.id

    assert %{allowed: true, limit_reached: false, secondary_window: %{used_percent: 0}} =
             codex_rate_limit(identity, as_of)
  end

  defp codex_rate_limit(identity, as_of) do
    identity
    |> Windows.list_quota_windows(as_of)
    |> UsageResponses.account_usage_windows(as_of)
    |> then(fn {primary, secondary} -> UsageResponses.codex_rate_limit(primary, secondary) end)
  end

  defp safe_status do
    %{
      "rate_limit_allowed" => true,
      "rate_limit_reached" => false
    }
  end

  defp fixed_zero(observed_at, fixed_anchor, status, opts \\ []) do
    provider_at = Keyword.get(opts, :provider_at, observed_at)

    floating_zero(observed_at,
      reset_at: fixed_anchor,
      reset_after_seconds: DateTime.diff(fixed_anchor, provider_at, :second),
      metadata: status
    )
  end

  defp safe_fixed_zero(observed_at, fixed_anchor, opts \\ []),
    do: fixed_zero(observed_at, fixed_anchor, safe_status(), opts)

  defp runtime_weekly_row!(identity, observed_at, used_percent, reset_at) do
    attrs = %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(used_percent),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: "codex_rate_limit_event",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      metadata: %{}
    }

    assert {:ok, row} =
             EvidenceStore.record_evidence(identity, attrs, observed_at, observed_at)

    row
  end

  defp assert_scoped_same_anchor_restart_rejected(scope, upstream_model) do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    fixed_anchor = DateTime.add(t0, 5, :day)
    candidate_at = DateTime.add(t0, 5, :minute)
    confirmed_at = DateTime.add(candidate_at, 180, :second)

    scoped_base =
      t0
      |> safe_fixed_zero(fixed_anchor)
      |> Map.merge(%{
        quota_key: "example_model_weekly",
        quota_scope: scope,
        quota_family: "example_model_weekly",
        model: "example-model",
        upstream_model: upstream_model,
        active_limit: 243,
        credits: 0,
        used_percent: Decimal.new("100"),
        metadata: %{
          "reset_after_seconds" => DateTime.diff(fixed_anchor, t0, :second)
        }
      })

    assert {:ok, canonical} = EvidenceStore.record_evidence(identity, scoped_base, t0, t0)
    assert canonical.quota_scope == scope
    assert canonical.upstream_model == upstream_model
    assert Decimal.equal?(canonical.used_percent, Decimal.new("100"))

    for observed_at <- [candidate_at, confirmed_at] do
      scoped_zero = %{
        scoped_base
        | used_percent: Decimal.new("0"),
          active_limit: nil,
          credits: nil,
          observed_at: observed_at,
          last_sync_at: observed_at,
          metadata:
            Map.put(
              safe_status(),
              "reset_after_seconds",
              DateTime.diff(fixed_anchor, observed_at, :second)
            )
      }

      assert {:ok, _row} =
               EvidenceStore.record_evidence(identity, scoped_zero, observed_at, observed_at)
    end

    persisted = Repo.get!(AccountQuotaWindow, canonical.id)
    assert Decimal.equal?(persisted.used_percent, Decimal.new("100"))
    assert persisted.active_limit == 243
    assert persisted.credits == 0
    assert DateTime.compare(persisted.observed_at, t0) == :eq
    assert DateTime.compare(persisted.reset_at, fixed_anchor) == :eq
    assert {:ok, _candidate} = EvidenceStore.parse_candidate(persisted.metadata)
    assert persisted.metadata["reset_state"] == "anchored"
    refute Map.has_key?(persisted.metadata, "__quota_cycle_confirmation_v1")
    refute CycleConfirmation.selector_valid?(persisted, confirmed_at)
  end

  defp capture_quota_cycle_events(fun) when is_function(fun, 0) do
    parent = self()
    handler_id = "weekly-restart-quota-cycle-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :quota, :cycle, :decision],
        fn _event, measurements, metadata, _config ->
          send(parent, {handler_id, measurements, metadata})
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_quota_cycle_events(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_quota_cycle_events(handler_id, events) do
    receive do
      {^handler_id, measurements, metadata} ->
        drain_quota_cycle_events(handler_id, [{measurements, metadata} | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
