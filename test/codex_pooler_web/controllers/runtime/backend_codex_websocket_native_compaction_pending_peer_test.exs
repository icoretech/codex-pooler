defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketNativeCompactionPendingPeerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [start_shared_bridge_peer!: 0]
  alias CodexPoolerWeb.Runtime.NativeCompactionPendingScenario

  @moduletag capture_log: true

  setup_all do
    %{peer_node: start_shared_bridge_peer!()}
  end

  for mode <- ["full", "lite"], form <- [:anchored, :full_history] do
    @tag slow: "held native compact on a real peer exceeds the client's text-only idle watchdog"
    test "#{mode} peer #{form}: pending text preserves one compact and its same-socket continuation", %{peer_node: peer} do
      assert :ok = NativeCompactionPendingScenario.run!(unquote(mode), :peer, unquote(form), peer_node: peer)
    end
  end

  for mode <- ["full", "lite"], form <- [:anchored, :full_history] do
    @tag pending_negative: true, slow: "the actual 4 s source receive timeout must survive peer pending-control renewal"
    test "#{mode} peer #{form}: pending controls preserve the source receive timeout", %{peer_node: peer} do
      assert :ok = NativeCompactionPendingScenario.run!(unquote(mode), :peer, unquote(form), peer_node: peer, outcome: :timeout)
    end
  end

  @tag pending_source_progress: true, pending_cadence: :sparse, slow: "real collected source frames renew receive authority across the peer's 3.6 s forwarding budget"
  test "full peer anchored: source progress between pending pulses preserves compact and same-socket continuation", %{peer_node: peer} do
    assert :ok = NativeCompactionPendingScenario.run!("full", :peer, :anchored, peer_node: peer, outcome: :source_progress)
  end

  @tag pending_source_progress: true, pending_cadence: :fast, slow: "same real 4 s source stream controls for peer forwarding with frequent pending authority"
  test "full peer anchored: fast pending pulses preserve the same progressing compact and continuation", %{peer_node: peer} do
    assert :ok = NativeCompactionPendingScenario.run!("full", :peer, :anchored, peer_node: peer, outcome: :source_progress, pending_interval_ms: 100)
  end
end
