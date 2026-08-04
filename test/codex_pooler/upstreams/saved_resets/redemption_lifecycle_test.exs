defmodule CodexPooler.Upstreams.SavedResets.RedemptionLifecycleTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle, as: Lifecycle

  @base ~U[2026-07-14 03:20:30.000000Z]
  @attempt_id "00000000-0000-4000-8000-000000000001"

  defp consumed(phase, opts \\ []) do
    consumed_at = Keyword.get(opts, :consumed_at, @base)

    %{
      "phase" => phase,
      "status" => Lifecycle.legacy_status_for(phase),
      "attempt_id" => Keyword.get(opts, :attempt_id, "attempt-1"),
      "generation" => Keyword.get(opts, :generation, 3),
      "consumed_at" => DateTime.to_iso8601(consumed_at),
      "deadline_at" => DateTime.to_iso8601(Lifecycle.deadline_at(consumed_at))
    }
  end

  describe "phase/1" do
    test "returns the recognized phase" do
      for phase <- Lifecycle.phases() do
        assert Lifecycle.phase(%{"phase" => phase}) == phase
      end
    end

    test "flags an unrecognized phase as :unknown for fail-closed callers" do
      assert Lifecycle.phase(%{"phase" => "teleported"}) == :unknown
    end

    test "returns nil for legacy records without a phase" do
      assert Lifecycle.phase(%{"status" => "redeeming"}) == nil
      assert Lifecycle.phase(%{}) == nil
      assert Lifecycle.phase(nil) == nil
    end
  end

  describe "legacy status projection" do
    test "nonterminal phases project to the legacy redeeming status" do
      assert Lifecycle.legacy_status_for("consuming") == "redeeming"
      assert Lifecycle.legacy_status_for("consumed_pending_probe") == "redeeming"
    end

    test "confirmed phases project to succeeded, blocked phases to failed" do
      assert Lifecycle.legacy_status_for("confirmed_by_upstream") == "succeeded"
      assert Lifecycle.legacy_status_for("confirmed_by_quota") == "succeeded"
      assert Lifecycle.legacy_status_for("reblocked") == "failed"
      assert Lifecycle.legacy_status_for("expired") == "failed"
      assert Lifecycle.legacy_status_for("consume_not_applied") == "failed"
    end
  end

  describe "expired?/2" do
    test "is false within the bounded window and true once it elapses" do
      redemption = consumed("consumed_pending_probe")

      assert Lifecycle.expired?(redemption, DateTime.add(@base, 14, :minute)) == false
      assert Lifecycle.expired?(redemption, DateTime.add(@base, 15, :minute)) == true
      assert Lifecycle.expired?(redemption, DateTime.add(@base, 20, :minute)) == true
    end

    test "falls back to consumed_at + window when deadline_at is absent" do
      redemption = Map.delete(consumed("consumed_pending_probe"), "deadline_at")

      assert Lifecycle.expired?(redemption, DateTime.add(@base, 14, :minute)) == false
      assert Lifecycle.expired?(redemption, DateTime.add(@base, 16, :minute)) == true
    end

    test "is false when no deadline can be derived" do
      refute Lifecycle.expired?(%{"phase" => "consuming"}, @base)
    end
  end

  describe "blocks_new_redemption?/2" do
    test "blocks a consumed pending credit, even past the window" do
      assert Lifecycle.blocks_new_redemption?(consumed("consumed_pending_probe"), @base)

      elapsed = DateTime.add(@base, 30, :minute)
      assert Lifecycle.blocks_new_redemption?(consumed("consumed_pending_probe"), elapsed)
    end

    test "blocks a phase-bearing consuming attempt regardless of age" do
      assert Lifecycle.blocks_new_redemption?(consumed("consuming"), @base)
      assert Lifecycle.blocks_new_redemption?(consumed("consuming"), DateTime.add(@base, 1, :day))
    end

    test "blocks an expired lifecycle so recovery only comes from fresh evidence" do
      assert Lifecycle.blocks_new_redemption?(consumed("expired"), @base)
    end

    test "blocks a reblocked lifecycle after the provider consumed the credit" do
      redemption = put_in(consumed("reblocked"), ["result"], %{"applied" => true})

      assert Lifecycle.blocks_new_redemption?(redemption, @base)
    end

    test "blocks an unrecognized phase" do
      assert Lifecycle.blocks_new_redemption?(%{"phase" => "teleported"}, @base)
    end

    test "does not block settled confirmations, non-consuming reblocks, or legacy records" do
      refute Lifecycle.blocks_new_redemption?(consumed("confirmed_by_quota"), @base)
      refute Lifecycle.blocks_new_redemption?(consumed("reblocked"), @base)
      refute Lifecycle.blocks_new_redemption?(consumed("consume_not_applied"), @base)

      refute Lifecycle.blocks_new_redemption?(
               put_in(consumed("reblocked"), ["result"], %{"applied" => false}),
               @base
             )

      refute Lifecycle.blocks_new_redemption?(%{"status" => "succeeded"}, @base)
      refute Lifecycle.blocks_new_redemption?(%{}, @base)
    end
  end

  describe "routeable?/2" do
    test "confirmed phases are routeable only within their bounded window" do
      for phase <- ~w(confirmed_by_quota confirmed_by_upstream) do
        record = consumed(phase)

        assert Lifecycle.routeable?(record, DateTime.add(@base, 10, :minute))
        # Outside the window the lifecycle grants nothing: routing must rest on
        # quota evidence again, or a past redemption would bypass a later
        # genuine exhaustion forever.
        refute Lifecycle.routeable?(record, DateTime.add(@base, 16, :minute))
        refute Lifecycle.routeable?(record, DateTime.add(@base, 1, :hour))
      end
    end

    test "pending, reblocked, expired, and legacy records are not routeable" do
      refute Lifecycle.routeable?(consumed("consumed_pending_probe"), @base)
      refute Lifecycle.routeable?(consumed("reblocked"), @base)
      refute Lifecycle.routeable?(consumed("expired"), @base)
      refute Lifecycle.routeable?(consumed("consume_not_applied"), @base)
      refute Lifecycle.routeable?(%{"status" => "succeeded"}, @base)
    end
  end

  describe "can_transition?/4 compare-and-set" do
    test "a legacy record may only enter the lifecycle at consuming" do
      assert Lifecycle.can_transition?(%{"generation" => 3}, "consuming", 3, nil)
      refute Lifecycle.can_transition?(%{"generation" => 3}, "consumed_pending_probe", 3, nil)
    end

    test "consuming advances to pending, reblocked, expired, or proven not applied only" do
      from = consumed("consuming")

      assert Lifecycle.can_transition?(from, "consumed_pending_probe", 3, "attempt-1")
      assert Lifecycle.can_transition?(from, "reblocked", 3, "attempt-1")
      assert Lifecycle.can_transition?(from, "expired", 3, "attempt-1")
      refute Lifecycle.can_transition?(from, "consume_not_applied", 3, "attempt-1")

      proven_unspent =
        Map.put(from, "provider_replay", %{"version" => 1, "provider_dispatches" => 0})

      assert Lifecycle.can_transition?(
               proven_unspent,
               "consume_not_applied",
               3,
               "attempt-1"
             )

      refute Lifecycle.can_transition?(
               put_in(proven_unspent, ["provider_replay", "provider_dispatches"], 1),
               "consume_not_applied",
               3,
               "attempt-1"
             )

      refute Lifecycle.can_transition?(
               put_in(proven_unspent, ["provider_replay", "version"], 2),
               "consume_not_applied",
               3,
               "attempt-1"
             )

      refute Lifecycle.can_transition?(from, "confirmed_by_upstream", 3, "attempt-1")
      refute Lifecycle.can_transition?(from, "confirmed_by_quota", 3, "attempt-1")
    end

    test "pending advances to any confirmation, reblock, or expiry" do
      from = consumed("consumed_pending_probe")

      for to <- ~w(confirmed_by_upstream confirmed_by_quota reblocked expired) do
        assert Lifecycle.can_transition?(from, to, 3, "attempt-1")
      end

      refute Lifecycle.can_transition?(from, "consuming", 3, "attempt-1")
      refute Lifecycle.can_transition?(from, "consumed_pending_probe", 3, "attempt-1")
    end

    test "an applied reblocked lifecycle can only confirm from exact valid ownership" do
      from =
        "reblocked"
        |> consumed(attempt_id: @attempt_id)
        |> Map.put("result", %{"code" => "reset", "applied" => true})

      assert Lifecycle.can_transition?(from, "confirmed_by_quota", 3, @attempt_id)

      for invalid <- [
            Map.put(from, "attempt_id", nil),
            Map.put(from, "attempt_id", 123),
            Map.put(from, "attempt_id", "attempt-1"),
            Map.put(from, "generation", nil),
            Map.put(from, "generation", "3"),
            Map.put(from, "consumed_at", nil),
            Map.put(from, "consumed_at", "not-a-date"),
            put_in(from, ["result", "applied"], false),
            Map.delete(from, "result")
          ] do
        refute Lifecycle.can_transition?(
                 invalid,
                 "confirmed_by_quota",
                 invalid["generation"],
                 invalid["attempt_id"]
               )
      end

      refute Lifecycle.can_transition?(from, "confirmed_by_quota", 2, @attempt_id)

      refute Lifecycle.can_transition?(
               from,
               "confirmed_by_quota",
               3,
               "00000000-0000-4000-8000-000000000002"
             )

      for target <- Lifecycle.phases() -- ["confirmed_by_quota"] do
        refute Lifecycle.can_transition?(from, target, 3, @attempt_id)
      end
    end

    test "other settled phases cannot transition further" do
      for terminal <- ~w(confirmed_by_quota consume_not_applied) do
        from = consumed(terminal)

        for to <- Lifecycle.phases() do
          refute Lifecycle.can_transition?(from, to, 3, "attempt-1"),
                 "expected #{terminal} -> #{to} to be rejected"
        end
      end
    end

    test "expired can only settle through fresh evidence" do
      from = consumed("expired")

      assert Lifecycle.can_transition?(from, "confirmed_by_quota", 3, "attempt-1")
      assert Lifecycle.can_transition?(from, "reblocked", 3, "attempt-1")

      for to <- ~w(consuming consumed_pending_probe confirmed_by_upstream expired) do
        refute Lifecycle.can_transition?(from, to, 3, "attempt-1"),
               "expected expired -> #{to} to be rejected"
      end
    end

    test "a stale generation or a mismatched attempt cannot transition (late event)" do
      from = consumed("consumed_pending_probe", generation: 3, attempt_id: "attempt-1")

      refute Lifecycle.can_transition?(from, "confirmed_by_quota", 2, "attempt-1")
      refute Lifecycle.can_transition?(from, "confirmed_by_quota", 3, "attempt-OTHER")
      assert Lifecycle.can_transition?(from, "confirmed_by_quota", 3, "attempt-1")
    end

    test "an unrecognized target phase is rejected" do
      refute Lifecycle.can_transition?(consumed("consuming"), "teleported", 3, "attempt-1")
    end
  end

  describe "consume_not_applied lifecycle" do
    test "is terminal, non-routeable, and non-probe-claimable with an unapplied result" do
      redemption =
        consumed("consume_not_applied")
        |> Map.put("result", %{"code" => "provider_not_dispatched", "applied" => false})

      assert Lifecycle.terminal?("consume_not_applied")
      refute Lifecycle.nonterminal?("consume_not_applied")
      refute Lifecycle.routeable?(redemption, @base)
      refute Lifecycle.probe_claimable?(redemption, @base)
      assert redemption["result"]["applied"] == false
    end
  end
end
