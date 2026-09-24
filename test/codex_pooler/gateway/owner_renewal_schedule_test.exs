defmodule CodexPooler.Gateway.OwnerRenewalScheduleTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OwnerRenewalSchedule

  test "bounds HTTP renewal cadence by one third of the owner ttl" do
    assert OwnerRenewalSchedule.base_interval_ms(15_000, 45_000) == 15_000
    assert OwnerRenewalSchedule.base_interval_ms(60_000, 9_000) == 3_000
    assert OwnerRenewalSchedule.base_interval_ms(1, 1) == 1
  end

  test "bounds a renewal setting by one third of the effective lease ttl" do
    assert OwnerRenewalSchedule.maximum_renewal_seconds(45) == 15
    assert OwnerRenewalSchedule.maximum_renewal_seconds(24) == 8
    assert OwnerRenewalSchedule.maximum_renewal_seconds(25) == 8
    assert OwnerRenewalSchedule.maximum_renewal_seconds(2) == 1

    # The default pair is unchanged; a renewal at or above the ttl is lowered.
    assert OwnerRenewalSchedule.effective_renewal_seconds(15, 45, 15) == 15
    assert OwnerRenewalSchedule.effective_renewal_seconds(16, 45, 15) == 15
    assert OwnerRenewalSchedule.effective_renewal_seconds(45, 45, 15) == 15
    assert OwnerRenewalSchedule.effective_renewal_seconds(30, 24, 15) == 8
    assert OwnerRenewalSchedule.effective_renewal_seconds(5, 24, 15) == 5
    assert OwnerRenewalSchedule.effective_renewal_seconds(nil, 24, 15) == 8
    assert OwnerRenewalSchedule.effective_renewal_seconds(0, 45, 15) == 15

    # Seconds never exceed the millisecond cadence cap either path applies.
    for ttl <- 24..200, renewal <- [1, 8, 15, 60, 600] do
      effective = OwnerRenewalSchedule.effective_renewal_seconds(renewal, ttl, 15)
      assert OwnerRenewalSchedule.base_interval_ms(effective * 1_000, ttl * 1_000) == effective * 1_000
    end
  end

  test "uses the websocket 80 to 100 percent renewal window" do
    for _ <- 1..100 do
      assert OwnerRenewalSchedule.staggered_delay(10_000) in 8_000..10_000
    end

    assert OwnerRenewalSchedule.staggered_delay(1) == 1
  end

  test "clamps injected renewal delays to the configured interval" do
    assert OwnerRenewalSchedule.bounded_delay(1, 10_000) == 1
    assert OwnerRenewalSchedule.bounded_delay(10_000, 10_000) == 10_000
    assert OwnerRenewalSchedule.bounded_delay(0, 10_000) == 10_000
    assert OwnerRenewalSchedule.bounded_delay(10_001, 10_000) == 10_000
  end
end
