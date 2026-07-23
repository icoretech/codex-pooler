defmodule CodexPooler.Upstreams.SavedResets.RedemptionLifecycleLatchTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle

  @now ~U[2026-07-23 12:00:00.000000Z]
  @inside_window @now |> DateTime.add(-5, :minute) |> DateTime.to_iso8601()
  @cooldown_boundary @now |> DateTime.add(-30, :minute) |> DateTime.to_iso8601()
  @outside_window @now |> DateTime.add(-40, :minute) |> DateTime.to_iso8601()

  defp record(overrides) do
    Map.merge(
      %{
        "status" => "succeeded",
        "phase" => "confirmed_by_upstream",
        "trigger_kind" => "gateway_auto",
        "generation" => 2,
        "attempt_id" => "attempt",
        "started_at" => @inside_window,
        "consumed_at" => @inside_window,
        "result" => %{"code" => "reset", "applied" => true}
      },
      overrides
    )
  end

  # Pre-lifecycle writers persisted status/trigger/started_at/result only —
  # never phase, consumed_at, or deadline_at.
  defp legacy_record(started_at) do
    record(%{"started_at" => started_at})
    |> Map.drop(["phase", "consumed_at", "deadline_at"])
  end

  describe "gateway_auto_latch/2" do
    test "spent credit without quota convergence blocks regardless of age or trigger" do
      for phase <- ["consumed_pending_probe", "confirmed_by_upstream", "reblocked", "expired"],
          trigger <- ["gateway_auto", "admin_manual"],
          consumed_at <- [@inside_window, @outside_window] do
        assert RedemptionLifecycle.gateway_auto_latch(
                 record(%{
                   "phase" => phase,
                   "trigger_kind" => trigger,
                   "consumed_at" => consumed_at
                 }),
                 @now
               ) == :blocked_awaiting_quota
      end
    end

    test "unknown phases stay fail-closed" do
      assert RedemptionLifecycle.gateway_auto_latch(record(%{"phase" => "brand-new"}), @now) ==
               :blocked_awaiting_quota
    end

    test "quota convergence cools down inside the window and clears after it" do
      converged = record(%{"phase" => "confirmed_by_quota"})

      assert RedemptionLifecycle.gateway_auto_latch(converged, @now) == :cooldown

      assert RedemptionLifecycle.gateway_auto_latch(
               record(%{"phase" => "confirmed_by_quota", "consumed_at" => @outside_window}),
               @now
             ) == :clear
    end

    test "the cooldown boundary is exclusive: exactly the cooldown age clears" do
      assert RedemptionLifecycle.gateway_auto_latch(
               record(%{"phase" => "confirmed_by_quota", "consumed_at" => @cooldown_boundary}),
               @now
             ) == :clear
    end

    test "an unapplied overwrite keeps the carried consume cooldown" do
      carried_claim =
        record(%{
          "status" => "redeeming",
          "phase" => "consuming",
          "result" => nil,
          "consumed_at" => nil,
          "last_applied_consume_at" => @inside_window
        })

      assert RedemptionLifecycle.gateway_auto_latch(carried_claim, @now) == :cooldown

      carried_failed =
        record(%{
          "status" => "failed",
          "phase" => nil,
          "result" => %{"code" => "http_5xx", "applied" => false},
          "consumed_at" => nil,
          "last_applied_consume_at" => @inside_window
        })

      assert RedemptionLifecycle.gateway_auto_latch(carried_failed, @now) == :cooldown

      assert RedemptionLifecycle.gateway_auto_latch(
               record(%{
                 "status" => "failed",
                 "phase" => nil,
                 "result" => %{"code" => "http_5xx", "applied" => false},
                 "consumed_at" => nil,
                 "last_applied_consume_at" => @outside_window
               }),
               @now
             ) == :clear
    end

    test "a grossly future-dated consume timestamp fails open instead of latching" do
      slightly_future = @now |> DateTime.add(30, :second) |> DateTime.to_iso8601()
      far_future = @now |> DateTime.add(10, :minute) |> DateTime.to_iso8601()

      assert RedemptionLifecycle.gateway_auto_latch(
               record(%{"phase" => "confirmed_by_quota", "consumed_at" => slightly_future}),
               @now
             ) == :cooldown

      assert RedemptionLifecycle.gateway_auto_latch(
               record(%{"phase" => "confirmed_by_quota", "consumed_at" => far_future}),
               @now
             ) == :clear
    end

    test "a manual applied consume arms the automatic latch too" do
      manual = record(%{"phase" => "confirmed_by_quota", "trigger_kind" => "admin_manual"})

      assert RedemptionLifecycle.gateway_auto_latch(manual, @now) == :cooldown
    end

    test "legacy records without a phase or consumed_at floor on started_at" do
      assert RedemptionLifecycle.gateway_auto_latch(legacy_record(@inside_window), @now) ==
               :cooldown

      assert RedemptionLifecycle.gateway_auto_latch(legacy_record(@outside_window), @now) ==
               :clear
    end

    test "a legacy record without any timestamps never latches" do
      legacy =
        record(%{})
        |> Map.drop(["phase", "consumed_at", "started_at"])

      assert RedemptionLifecycle.gateway_auto_latch(legacy, @now) == :clear
    end

    test "a malformed consumed_at falls back to started_at" do
      assert RedemptionLifecycle.gateway_auto_latch(
               record(%{
                 "phase" => "confirmed_by_quota",
                 "consumed_at" => "not-a-date",
                 "started_at" => @inside_window
               }),
               @now
             ) == :cooldown
    end

    test "unapplied, consuming, and absent records latch nothing" do
      assert RedemptionLifecycle.gateway_auto_latch(nil, @now) == :clear

      assert RedemptionLifecycle.gateway_auto_latch(
               record(%{"result" => %{"code" => "noop", "applied" => false}}),
               @now
             ) == :clear

      assert RedemptionLifecycle.gateway_auto_latch(
               record(%{"phase" => "consuming", "result" => %{}}),
               @now
             ) == :clear
    end
  end

  describe "applied_consume?/1" do
    test "requires an applied result and ignores the trigger" do
      assert RedemptionLifecycle.applied_consume?(record(%{}))
      assert RedemptionLifecycle.applied_consume?(record(%{"trigger_kind" => "admin_manual"}))

      refute RedemptionLifecycle.applied_consume?(record(%{"result" => %{"applied" => false}}))
      refute RedemptionLifecycle.applied_consume?(nil)
    end
  end
end
