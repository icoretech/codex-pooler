defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketNativeCompactionPendingTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPoolerWeb.Runtime.NativeCompactionPendingScenario

  @moduletag capture_log: true

  for mode <- ["full", "lite"], topology <- [:direct, :local], form <- [:anchored, :full_history] do
    @tag pending_topology: topology, pending_mode: mode, pending_form: form
    @tag slow: "held native compact exceeds the client's text-only idle watchdog"
    test "#{mode} #{topology} #{form}: pending text preserves one compact and its same-socket continuation" do
      assert :ok = NativeCompactionPendingScenario.run!(unquote(mode), unquote(topology), unquote(form))
    end
  end

  for topology <- [:direct, :local], outcome <- [:timeout, :client_close, :frozen_source, :drain] do
    @tag pending_negative: true, slow: "observe the actual receive timeout, frozen source watchdog, or drain settlement"
    test "#{topology}: pending controls stop at #{outcome}" do
      assert :ok = NativeCompactionPendingScenario.run!("full", unquote(topology), :anchored, outcome: unquote(outcome))
    end
  end

  @tag slow: "the actual downstream idle deadline closes a client that ignores pending-control Pings"
  test "pending text does not renew the server idle deadline without a client Pong" do
    assert :ok = NativeCompactionPendingScenario.run!("full", :direct, :anchored, outcome: :ignore_pong)
  end
end
