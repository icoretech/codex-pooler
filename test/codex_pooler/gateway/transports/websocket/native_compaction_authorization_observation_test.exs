defmodule CodexPooler.Gateway.Transports.Websocket.NativeCompactionAuthorizationObservationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAuthorizationObservation

  @event [:codex_pooler, :gateway, :native_compaction, :authorization_transition]

  test "rejects raw sixteen-byte lifecycle values instead of encoding their contents as a UUID" do
    raw_lifecycle_id = "PRIVATE_16_BYTES"
    assert byte_size(raw_lifecycle_id) == 16
    assert {:ok, reversible_uuid} = Ecto.UUID.cast(raw_lifecycle_id)

    capability = %NativeCompactionAdmission.Capability{
      phase: :compact,
      binding: %{lifecycle_id: raw_lifecycle_id},
      token: "PRIVATE_TOKEN_SENTINEL",
      control_ref: make_ref(),
      expires_at_ms: 1
    }

    log =
      capture_log(fn ->
        assert :ok =
                 NativeCompactionAuthorizationObservation.log_accounting_rejection(
                   nil,
                   capability,
                   :direct,
                   :invalid_transition
                 )
      end)

    assert log =~ "native_lifecycle_id=none"
    refute log =~ raw_lifecycle_id
    refute log =~ reversible_uuid
  end

  test "final accounting diagnostics retain the expected state and omit malformed private fields" do
    capability = %NativeCompactionAdmission.Capability{
      phase: :final,
      binding: %{lifecycle_id: "PRIVATE_BINDING_SENTINEL"},
      token: "PRIVATE_TOKEN_SENTINEL",
      control_ref: make_ref(),
      expires_at_ms: 1
    }

    log =
      capture_log(fn ->
        assert :ok =
                 NativeCompactionAuthorizationObservation.log_accounting_rejection(
                   %NativeCompactionAdmission{phase: :pending_final},
                   capability,
                   :forwarded,
                   :invalid_transition
                 )
      end)

    assert log =~ "phase=final"
    assert log =~ "current_state=pending_final"
    assert log =~ "expected_state=reserved_final"
    assert log =~ "native_lifecycle_id=none"
    refute log =~ "PRIVATE_BINDING_SENTINEL"
    refute log =~ "PRIVATE_TOKEN_SENTINEL"
  end

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
