defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketPreTurnCompactionCutPeerTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [start_shared_bridge_peer!: 0]

  alias CodexPoolerWeb.Runtime.PreTurnCompactionCutScenario, as: Scenario

  # The admitted native compaction cut of
  # `backend_codex_websocket_pre_turn_compaction_cut_test.exs` (findings#206
  # rows 206-310, 206-330, 206-436, 206-455), Full pre-turn and mid-turn, with
  # owner forwarding on and the session's owner and its provider connection on
  # a second VM sharing the committed database, the socket on this node, as
  # when a production turn lands on the other web pod (findings#206 row
  # 206-334). The module boots that VM once: booting it and warming its first
  # turn took one to three seconds of every test, and on a busy machine pushed
  # the queued arms past the six-second budget (findings#206 row 206-539).
  # Each test starts its own session's owner on it and stops it when it ends.
  setup_all do
    %{peer_node: start_shared_bridge_peer!()}
  end

  for {shape, cut} <- [{:pre_turn, :observed_cut}, {:pre_turn, :observed_cut_exited}, {:mid_turn, :observed_cut}] do
    @tag mode: "full", shape: shape, topology: :peer, cut: cut
    test "full #{shape} peer admitted compaction #{cut} with the closed socket's cleanup held: the released client's first websocket retry is served",
         %{mode: mode, shape: shape, topology: topology, cut: cut, peer_node: peer_node} do
      assert Scenario.run_scenario(mode, shape, topology, cut, :on_arrival, peer_node: peer_node) == Scenario.expected(cut, topology)
    end
  end

  # The first retry's take-over cannot see the cut compaction settle within
  # its two-second wait (the settlement is held): refused once, then served
  # (findings#206 row 206-580, seen on this mid-turn arm under load).
  for shape <- [:pre_turn, :mid_turn] do
    @tag mode: "full", shape: shape, topology: :peer, cut: :observed_cut_settlement_held
    test "full #{shape} peer admitted compaction whose settlement outlasts the take-over wait: the first retry is refused and the next is served",
         %{mode: mode, shape: shape, topology: topology, cut: cut, peer_node: peer_node} do
      assert Scenario.run_scenario(mode, shape, topology, cut, :on_arrival, peer_node: peer_node) == Scenario.expected(cut, topology)
    end
  end

  for shape <- [:pre_turn, :mid_turn], cut <- [:unobserved_cut, :observed_cut] do
    @tag mode: "full", shape: shape, topology: :peer, cut: cut, dispatch: :queued
    test "full #{shape} peer compaction queued behind the settling turn, #{cut}: the owner keys it and no resend is a second generation while it runs",
         %{mode: mode, shape: shape, topology: topology, cut: cut, peer_node: peer_node} do
      assert Scenario.run_scenario(mode, shape, topology, cut, :queued, peer_node: peer_node) == Scenario.expected(cut, topology)
    end
  end

  for cut <- [:no_cut, :before_output, :after_output, :after_completion, :unobserved_cut] do
    @tag mode: "full", shape: :pre_turn, topology: :peer, cut: cut
    test "full pre_turn peer admitted compaction #{cut}: the released client's retries buy the compaction once per request and the turn completes",
         %{mode: mode, shape: shape, topology: topology, cut: cut, peer_node: peer_node} do
      assert Scenario.run_scenario(mode, shape, topology, cut, :on_arrival, peer_node: peer_node) == Scenario.expected(cut, topology)
    end
  end
end
