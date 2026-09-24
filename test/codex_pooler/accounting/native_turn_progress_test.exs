defmodule CodexPooler.Accounting.NativeTurnProgressTest do
  # findings#206 rows 206-412/206-423: a later request of a turn is re-keyed
  # only against a holder that recorded its position, and only when the request
  # is further along the turn than that holder. A row that recorded none
  # (written before these releases, or by a socket that could not know its
  # history) must keep the bare claim and today's refusal.
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.NativeTurnProgress
  alias CodexPooler.Accounting.Request

  @progress :crypto.hash(:sha256, "p92-progress")

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

  describe "advances?/2 (findings#206 row 206-423)" do
    @pivot :crypto.hash(:sha256, "p94-pivot")
    @later_pivot :crypto.hash(:sha256, "p94-later-pivot")

    test "more user messages after the same compaction point, or none, is further along" do
      assert NativeTurnProgress.advances?({nil, 2}, {nil, 3})
      assert NativeTurnProgress.advances?({@pivot, 1}, {@pivot, 2})
    end

    test "a compaction point the holder did not end on is further along, whatever the count" do
      assert NativeTurnProgress.advances?({nil, 5}, {@pivot, 1})
      assert NativeTurnProgress.advances?({@pivot, 3}, {@later_pivot, 0})
    end

    test "the same position, fewer user messages, or a compaction point gone is not" do
      refute NativeTurnProgress.advances?({nil, 2}, {nil, 2})
      refute NativeTurnProgress.advances?({nil, 2}, {nil, 1})
      refute NativeTurnProgress.advances?({@pivot, 2}, {@pivot, 1})
      refute NativeTurnProgress.advances?({@pivot, 1}, {nil, 4})
    end

    test "a holder or a request without a position is not ordered" do
      refute NativeTurnProgress.advances?(nil, {nil, 3})
      refute NativeTurnProgress.advances?({nil, 1}, nil)
    end
  end

  describe "recorded_position/1" do
    test "reads the position a row of this release recorded beside its digest" do
      digest = NativeTurnProgress.encode(@progress)
      pivot = :crypto.hash(:sha256, "p94-recorded-pivot")

      assert NativeTurnProgress.recorded_position(websocket_row(%{"version" => 1, "digest" => digest, "user_messages" => 2})) == {nil, 2}

      assert NativeTurnProgress.recorded_position(%Request{
               transport: "http_sse",
               request_metadata: %{"native_http_turn_progress" => %{"version" => 1, "digest" => digest, "user_messages" => 1, "pivot" => NativeTurnProgress.encode(pivot)}}
             }) == {pivot, 1}
    end

    test "a row of the previous release (digest alone), no digest, or a malformed position is not ordered" do
      digest = NativeTurnProgress.encode(@progress)

      for recorded <- [
            %{"version" => 1, "digest" => digest},
            %{"version" => 1, "user_messages" => 2},
            %{"version" => 1, "digest" => digest, "user_messages" => -1},
            %{"version" => 1, "digest" => digest, "user_messages" => 2, "pivot" => "invalid"}
          ] do
        assert NativeTurnProgress.recorded_position(websocket_row(recorded)) == nil
      end

      assert NativeTurnProgress.recorded_position(nil) == nil
      assert NativeTurnProgress.recorded_position(%Request{transport: "websocket", request_metadata: %{}}) == nil
    end
  end

  defp websocket_row(recorded), do: %Request{transport: "websocket", request_metadata: %{"native_turn_progress" => recorded}}
end
