defmodule CodexPooler.Upstreams.SavedResets.RedemptionLifecycleTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle, as: Lifecycle

  @base ~U[2026-07-14 03:20:30.000000Z]

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
    test "blocks while consuming or pending, even past the window" do
      assert Lifecycle.blocks_new_redemption?(consumed("consuming"), @base)
      assert Lifecycle.blocks_new_redemption?(consumed("consumed_pending_probe"), @base)

      elapsed = DateTime.add(@base, 30, :minute)
      assert Lifecycle.blocks_new_redemption?(consumed("consumed_pending_probe"), elapsed)
    end

    test "blocks an expired lifecycle so recovery only comes from fresh evidence" do
      assert Lifecycle.blocks_new_redemption?(consumed("expired"), @base)
    end

    test "blocks an unrecognized phase" do
      assert Lifecycle.blocks_new_redemption?(%{"phase" => "teleported"}, @base)
    end

    test "does not block settled confirmations or legacy records" do
      refute Lifecycle.blocks_new_redemption?(consumed("confirmed_by_quota"), @base)
      refute Lifecycle.blocks_new_redemption?(consumed("reblocked"), @base)
      refute Lifecycle.blocks_new_redemption?(%{"status" => "succeeded"}, @base)
      refute Lifecycle.blocks_new_redemption?(%{}, @base)
    end
  end

  describe "routeable?/2" do
    test "quota-confirmed is routeable, upstream-confirmed only within the window" do
      assert Lifecycle.routeable?(consumed("confirmed_by_quota"), DateTime.add(@base, 1, :hour))

      probe = consumed("confirmed_by_upstream")
      assert Lifecycle.routeable?(probe, DateTime.add(@base, 10, :minute))
      refute Lifecycle.routeable?(probe, DateTime.add(@base, 16, :minute))
    end

    test "pending, reblocked, expired, and legacy records are not routeable" do
      refute Lifecycle.routeable?(consumed("consumed_pending_probe"), @base)
      refute Lifecycle.routeable?(consumed("reblocked"), @base)
      refute Lifecycle.routeable?(consumed("expired"), @base)
      refute Lifecycle.routeable?(%{"status" => "succeeded"}, @base)
    end
  end

  describe "can_transition?/4 compare-and-set" do
    test "a legacy record may only enter the lifecycle at consuming" do
      assert Lifecycle.can_transition?(%{"generation" => 3}, "consuming", 3, nil)
      refute Lifecycle.can_transition?(%{"generation" => 3}, "consumed_pending_probe", 3, nil)
    end

    test "consuming advances to pending, reblocked, or expired only" do
      from = consumed("consuming")

      assert Lifecycle.can_transition?(from, "consumed_pending_probe", 3, "attempt-1")
      assert Lifecycle.can_transition?(from, "reblocked", 3, "attempt-1")
      assert Lifecycle.can_transition?(from, "expired", 3, "attempt-1")
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

    test "terminal phases cannot transition further" do
      for terminal <- ~w(confirmed_by_quota reblocked expired) do
        from = consumed(terminal)

        for to <- Lifecycle.phases() do
          refute Lifecycle.can_transition?(from, to, 3, "attempt-1"),
                 "expected #{terminal} -> #{to} to be rejected"
        end
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
end
