defmodule CodexPooler.Upstreams.Quota.Windows.ResetRecoverySelectionTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Quotas.CapacityFacts
  alias CodexPooler.Upstreams.Quota.{AccountQuotaWindow, CapacityAssessment, RoutingQuotaSnapshot}
  alias CodexPooler.Upstreams.Quota.Windows.{CycleConfirmation, ResetRecoverySelection, Routing}

  @now ~U[2026-10-31 12:04:00Z]
  @consumed ~U[2026-10-31 12:00:00Z]

  for {kind, minutes} <- [{"secondary", 10_080}, {"primary", 43_200}] do
    test "confirmed #{minutes}-minute recovery supersedes only its pre-consume exhausted older cycle" do
      snapshot = snapshot(unquote(kind), unquote(minutes))
      [old, witness] = snapshot.raw_windows
      pending = put_in(snapshot.redemption["phase"], "consumed_pending_probe")
      assert selected(pending) == [old]
      refute Routing.eligibility_from_snapshot(pending).eligible?
      refute CycleConfirmation.selector_valid?(witness, @now)

      assert selected(snapshot) == [witness]
      assert Routing.eligibility_from_snapshot(snapshot).eligible?
      assert RoutingQuotaSnapshot.time_visible_raw_windows(snapshot) == [old, witness]
    end
  end

  for used <- [95, 99], {kind, minutes} <- [{"secondary", 10_080}, {"primary", 43_200}] do
    test "confirmed #{minutes}-minute reset replaces preconsume #{used} percent pressure with actual restored quota" do
      snapshot = snapshot(unquote(kind), unquote(minutes))
      [old, witness] = snapshot.raw_windows
      old = %{old | used_percent: Decimal.new(unquote(used))}
      snapshot = %{snapshot | raw_windows: [old, witness]}
      assert selected(%{snapshot | redemption: nil}) == [old]
      assert selected(snapshot) == [witness]
      assert Routing.eligibility_from_snapshot(snapshot).selection.routing_windows == [witness]
      assert RoutingQuotaSnapshot.time_visible_raw_windows(snapshot) == [old, witness]
    end
  end

  test "legacy weekly primary observations and witnesses match without rewriting stored rows" do
    for {old_kind, witness_kind} <- [{"primary", "secondary"}, {"secondary", "primary"}, {"primary", "primary"}] do
      snapshot = snapshot()
      [old, witness] = snapshot.raw_windows
      old = %{old | window_kind: old_kind}
      witness = %{witness | window_kind: witness_kind}
      snapshot = %{snapshot | raw_windows: [old, witness]}
      assert [%{window_kind: "secondary", used_percent: used}] = selected(%{snapshot | redemption: nil})
      assert Decimal.equal?(used, 100)
      assert selected(snapshot) == [%{witness | window_kind: "secondary"}]
      assert Routing.eligibility_from_snapshot(snapshot).eligible?
      assert RoutingQuotaSnapshot.time_visible_raw_windows(snapshot) == [old, witness]
    end
  end

  test "malformed, unapplied, undispatched or unbound lifecycles never supersede exhaustion" do
    for update <- [
          fn s -> %{s | redemption: nil} end,
          &put_in(&1.redemption["phase"], "confirmed_by_upstream"),
          &put_in(&1.redemption["result"], nil),
          &put_in(&1.redemption["result"]["code"], nil),
          &put_in(&1.redemption["result"]["code"], "no_credit"),
          &put_in(&1.redemption["result"]["code"], "consume_outcome_unknown"),
          &put_in(&1.redemption["finished_at"], nil),
          &put_in(&1.redemption["finished_at"], DateTime.to_iso8601(DateTime.add(@now, 1))),
          &put_in(&1.redemption["finished_at"], DateTime.to_iso8601(DateTime.add(@consumed, -1))),
          &put_in(&1.redemption["result"]["applied"], false),
          &put_in(&1.redemption["provider_replay"], nil),
          &put_in(&1.redemption["provider_replay"]["provider_dispatches"], 0),
          &put_in(&1.redemption["included_window_descriptors"], []),
          &put_in(&1.redemption["included_window_descriptors"], nil),
          &put_in(&1.redemption["included_window_descriptors"], [%{"window_kind" => "primary", "window_minutes" => 300}]),
          &put_in(&1.redemption["attempt_id"], "invalid"),
          &put_in(&1.redemption["generation"], 0),
          &put_in(&1.redemption["consumed_at"], DateTime.to_iso8601(DateTime.add(@now, 1)))
        ] do
      unchanged = update.(snapshot())
      assert ResetRecoverySelection.reject_recovered_prior_cycles(unchanged.raw_windows, unchanged) == unchanged.raw_windows
      assert hd(unchanged.raw_windows) in selected(unchanged)
    end
  end

  test "witness must be fresh current-epoch accepted post-consume included usage evidence" do
    for update <- [
          &%{&1 | observed_at: DateTime.add(@now, 1)},
          &%{&1 | observed_at: DateTime.add(@now, -901), last_sync_at: DateTime.add(@now, -901)},
          &%{&1 | observed_at: DateTime.add(@consumed, -1), last_sync_at: DateTime.add(@consumed, -1)},
          &%{&1 | metadata: Map.put(&1.metadata, "credential_epoch", 1)},
          &%{&1 | metadata: Map.delete(&1.metadata, "credential_epoch")},
          &%{&1 | used_percent: Decimal.new(100)},
          &%{&1 | source_precision: "unknown"},
          &%{&1 | source: "codex_response_headers"},
          &%{&1 | reset_at: DateTime.add(@now, 86_400)}
        ] do
      snapshot = snapshot()
      [old, witness] = snapshot.raw_windows
      changed = %{snapshot | raw_windows: [old, update.(witness)]}
      assert ResetRecoverySelection.reject_recovered_prior_cycles(changed.raw_windows, changed) == changed.raw_windows
      assert selected(changed) == selected(%{changed | redemption: nil})
    end
  end

  test "credit-only unknown stale preconsume and old-epoch permissions cannot establish included recovery" do
    for update <- [
          fn _ -> nil end,
          &%{&1 | included_permission: :unknown},
          &%{&1 | included_permission: :exhausted, credit_permission: :available},
          &%{&1 | credential_epoch: 1},
          &%{&1 | observed_at: DateTime.add(@now, 1)},
          &%{&1 | observed_at: DateTime.add(@now, -901)},
          &%{&1 | observed_at: DateTime.add(@consumed, -1)},
          &%{&1 | denial_category: :workspace_limit}
        ] do
      snapshot = snapshot()
      changed = %{snapshot | capacity_facts: update.(snapshot.capacity_facts)}
      assert ResetRecoverySelection.reject_recovered_prior_cycles(changed.raw_windows, changed) == changed.raw_windows
      assert hd(snapshot.raw_windows) in selected(changed)
    end
  end

  test "postconsume refusals and independent primary model feature and workspace blockers remain effective" do
    snapshot = snapshot()
    [old, witness] = snapshot.raw_windows

    for blocker <- [
          %{old | observed_at: @consumed, last_sync_at: @consumed},
          %{old | observed_at: @now, last_sync_at: @now, reset_at: witness.reset_at},
          %{old | window_kind: "primary", window_minutes: 300},
          %{old | quota_key: "model", quota_scope: "model", quota_family: "model", model: "sample-model"},
          %{old | quota_key: "feature", quota_scope: "feature", quota_family: "feature"}
        ] do
      blocker = %{blocker | metadata: Map.put(blocker.metadata, "rate_limit_error_code", "usage_limit_reached")}
      blocked = %{snapshot | raw_windows: [old, witness, blocker]}
      assert blocker in selected(blocked)
      refute CapacityAssessment.assess(blocked).eligible?
    end

    blocked = %{snapshot | capacity_blockers: [%{snapshot.capacity_facts | denial_category: :workspace_limit}]}
    refute CapacityAssessment.assess(blocked).eligible?
  end

  test "same-cycle rounding and missing measurements are not reset supersession" do
    snapshot = snapshot()
    [old, witness] = snapshot.raw_windows

    for preserved <- [
          %{old | used_percent: nil},
          %{old | used_percent: Decimal.new(99), reset_at: witness.reset_at},
          %{old | reset_at: DateTime.add(witness.reset_at, -5)},
          %{old | reset_at: witness.reset_at},
          %{old | reset_at: DateTime.add(witness.reset_at, 1)}
        ] do
      unchanged = %{snapshot | raw_windows: [preserved, witness]}
      assert ResetRecoverySelection.reject_recovered_prior_cycles(unchanged.raw_windows, unchanged) == unchanged.raw_windows
    end
  end

  defp selected(snapshot), do: RoutingQuotaSnapshot.effective_windows(snapshot)

  defp snapshot(kind \\ "secondary", minutes \\ 10_080) do
    old = %AccountQuotaWindow{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: kind,
      window_minutes: minutes,
      source: "codex_rate_limit_event",
      source_precision: "observed",
      freshness_state: "fresh",
      used_percent: Decimal.new(100),
      reset_at: DateTime.add(@now, 86_400),
      observed_at: DateTime.add(@consumed, -1),
      last_sync_at: DateTime.add(@consumed, -1),
      merge_precedence: 100,
      metadata: %{"credential_epoch" => 2}
    }

    witness = %{old | source: "codex_usage_api", used_percent: Decimal.new(0), reset_at: DateTime.add(@now, minutes * 60), observed_at: @now, last_sync_at: @now, metadata: %{"credential_epoch" => 2, "reset_state" => "rolling"}}

    %RoutingQuotaSnapshot{
      upstream_identity_id: Ecto.UUID.generate(),
      raw_windows: [old, witness],
      availability: nil,
      credential_epoch: 2,
      as_of: @now,
      capacity_facts: %CapacityFacts{observed_at: @now, credential_epoch: 2, included_permission: :available, credit_permission: :unavailable, denial_category: :none},
      redemption: %{
        "version" => 1,
        "phase" => "confirmed_by_quota",
        "status" => "succeeded",
        "generation" => 1,
        "attempt_id" => Ecto.UUID.generate(),
        "consumed_at" => DateTime.to_iso8601(@consumed),
        "finished_at" => DateTime.to_iso8601(@now),
        "result" => %{"applied" => true, "code" => "reset"},
        "provider_replay" => %{"version" => 1, "provider_dispatches" => 1},
        "included_window_descriptors" => [%{"window_kind" => kind, "window_minutes" => minutes}]
      }
    }
  end
end
