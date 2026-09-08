defmodule CodexPooler.Gateway.OwnerRenewalScheduleTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OwnerRenewalSchedule

  test "bounds HTTP renewal cadence by one third of the owner ttl" do
    assert OwnerRenewalSchedule.base_interval_ms(15_000, 45_000) == 15_000
    assert OwnerRenewalSchedule.base_interval_ms(60_000, 9_000) == 3_000
    assert OwnerRenewalSchedule.base_interval_ms(1, 1) == 1
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
