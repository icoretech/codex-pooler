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
end
