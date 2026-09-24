defmodule CodexPooler.Accounting.NativeTurnProgressTest do
  # findings#206 row 206-412: a later request of a turn is re-keyed only
  # against a holder that recorded a DIFFERENT progress digest. A row that
  # recorded none (written before these releases, or by a socket that could not
  # know its history) must keep the bare claim and today's refusal.
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.NativeTurnProgress
  alias CodexPooler.Accounting.Request

  @progress :crypto.hash(:sha256, "p92-progress")
  @other :crypto.hash(:sha256, "p92-other-progress")

  test "a websocket holder's native_turn_progress and a native HTTP holder's native_http_turn_progress are both read" do
    digest = NativeTurnProgress.encode(@progress)

    assert NativeTurnProgress.recorded(%Request{transport: "websocket", request_metadata: %{"native_turn_progress" => %{"version" => 1, "digest" => digest}}}) == digest

    for transport <- ["http_json", "http_sse", "http_compact_json"] do
      assert NativeTurnProgress.recorded(%Request{transport: transport, request_metadata: %{"native_http_turn_progress" => %{"version" => 1, "digest" => digest}}}) == digest
    end
  end

  test "a row without a digest, under the other transport's key, or of another version records nothing" do
    digest = NativeTurnProgress.encode(@progress)

    for request <- [
          nil,
          %Request{transport: "websocket", request_metadata: %{}},
          %Request{transport: "websocket", request_metadata: %{"native_http_turn_progress" => %{"version" => 1, "digest" => digest}}},
          %Request{transport: "http_sse", request_metadata: %{"native_turn_progress" => %{"version" => 1, "digest" => digest}}},
          %Request{transport: "websocket", request_metadata: %{"native_turn_progress" => %{"version" => 2, "digest" => digest}}}
        ] do
      assert NativeTurnProgress.recorded(request) == nil
    end
  end

  test "only a recorded, different digest marks a later request of the turn" do
    recorded = NativeTurnProgress.encode(@progress)

    refute NativeTurnProgress.differs?(recorded, @progress)
    assert NativeTurnProgress.differs?(recorded, @other)
    refute NativeTurnProgress.differs?(nil, @other)
  end
end
