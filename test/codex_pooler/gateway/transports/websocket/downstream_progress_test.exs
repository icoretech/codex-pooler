defmodule CodexPooler.Gateway.Transports.Websocket.DownstreamProgressTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Websocket.DownstreamProgress

  test "pending authority caps the remote wait while output keeps its normal budget" do
    :ok = DownstreamProgress.notify_pending(self(), 100)
    budget = DownstreamProgress.drain_budget(1_000)
    assert budget > 0 and budget <= 100
    :ok = DownstreamProgress.notify_pending(self(), 2_000)
    assert DownstreamProgress.drain_budget(1_000) == 1_000
    :ok = DownstreamProgress.notify_pending(self(), 100)
    :ok = DownstreamProgress.notify(self())
    assert DownstreamProgress.drain_budget(1_000) == 1_000
    assert DownstreamProgress.drain_budget(1_000) == nil
  end

  test "an expired pending notice cannot extend the owner wait" do
    send(self(), {DownstreamProgress, :pending_delivered, System.monotonic_time(:millisecond) - 1})
    assert DownstreamProgress.drain_budget(1_000) == nil
  end
end
