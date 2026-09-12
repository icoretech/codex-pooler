defmodule CodexPooler.Gateway.Transports.Streaming.PreparedFrameCapabilityLifetimeTest do
  @moduledoc """
  Findings #169: the capability behind a prepared websocket frame is a GenServer
  whose reclaim bound is its own process timeout, and nothing refreshed it. A
  frame that waits between sealing and dispatch — queued behind an in-flight
  turn, or held across an owner handoff — therefore lost its capability while it
  waited, and the dispatch that followed reported the frame's provenance as
  invalid rather than the frame as merely late.

  The bound is not a freshness or replay bound: the post-consume replies
  deliberately return without a timeout so a second dispatch answers `:consumed`
  rather than `:invalid`, which already leaves the redeem window open for the
  sealing process's whole life. It reclaims a capability nothing will use again.
  Parking says the frame is still reachable, so the timer refreshes instead of
  firing and abandonment falls to the owner monitor.

  The timeout is driven here by delivering the exact message an OTP receive
  timeout delivers, so the 30 s bound is exercised at its real value without
  waiting it out.
  """

  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame.Capability

  # Absence of a process exit; the exit itself is immediate when it happens.
  @absence_budget_ms 100

  test "an unparked capability is reclaimed when its timeout fires" do
    capability = Capability.issue()
    token = frame_token()
    assert :ok = Capability.seal(capability, token)

    monitor = Process.monitor(capability.server)
    send(capability.server, :timeout)

    assert_receive {:DOWN, ^monitor, :process, _server, :normal}, 1_000
    assert {:error, :invalid} = Capability.validate(capability, token)
  end

  test "a parked capability refreshes the timeout and keeps verifying its frame" do
    capability = Capability.issue()
    token = frame_token()
    assert :ok = Capability.seal(capability, token)
    assert :ok = Capability.park(capability)

    monitor = Process.monitor(capability.server)
    send(capability.server, :timeout)

    refute_receive {:DOWN, ^monitor, :process, _server, _reason}, @absence_budget_ms
    assert :ok = Capability.validate(capability, token)
    assert {:ok, nil} = Capability.consume_for_dispatch(capability, token)
  end

  test "parking does not weaken the frame binding" do
    capability = Capability.issue()
    sealed_token = frame_token()
    other_token = frame_token()
    assert :ok = Capability.seal(capability, sealed_token)
    assert :ok = Capability.park(capability)

    assert {:error, :invalid} = Capability.validate(capability, other_token)
    assert {:error, :invalid} = Capability.consume(capability, other_token)
    assert :ok = Capability.validate(capability, sealed_token)
  end

  test "a parked capability is still reclaimed when the process that sealed it exits" do
    test_process = self()

    sealer =
      spawn(fn ->
        capability = Capability.issue()
        token = frame_token()
        :ok = Capability.seal(capability, token)
        :ok = Capability.park(capability)
        send(test_process, {:sealed, capability, token})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:sealed, capability, token}, 1_000
    monitor = Process.monitor(capability.server)

    send(sealer, :stop)

    assert_receive {:DOWN, ^monitor, :process, _server, :normal}, 1_000
    assert {:error, :invalid} = Capability.validate(capability, token)
  end

  defp frame_token, do: "prepared-frame-token-#{System.unique_integer([:positive])}"
end
