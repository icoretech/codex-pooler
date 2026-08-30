defmodule CodexPooler.Gateway.Transports.Websocket.NativeCompactionAuthorizationObservationTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAuthorizationObservation

  @event [:codex_pooler, :gateway, :native_compaction, :authorization_transition]

  test "emits only the closed transition and topology vocabulary" do
    handler_id = "native-compaction-observation-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:observed, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    for transition <- NativeCompactionAuthorizationObservation.transitions(),
        topology <- NativeCompactionAuthorizationObservation.topologies() do
      assert :ok = NativeCompactionAuthorizationObservation.emit(transition, topology)

      assert_receive {:observed, @event, %{count: 1},
                      %{transition: ^transition, topology: ^topology}}
    end

    assert :ignored = NativeCompactionAuthorizationObservation.emit(:unknown, :direct)
    assert :ignored = NativeCompactionAuthorizationObservation.emit(:compact_reserved, :unknown)
    refute_received {:observed, @event, _measurements, _metadata}
  end
end
