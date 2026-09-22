defmodule CodexPooler.Gateway.Runtime.DuplicateTurnTelemetryTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.Runtime.DuplicateTurnTelemetry

  setup do
    test_pid = self()
    handler_id = "duplicate-turn-telemetry-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        DuplicateTurnTelemetry.event(),
        fn _event, measurements, metadata, _config ->
          if self() == test_pid, do: send(test_pid, {:refused, measurements, metadata})
        end,
        nil
      )

    :ok
  end

  test "normalizes the refusing stage and transport to closed label sets" do
    assert :ok = DuplicateTurnTelemetry.emit_refused("runtime_replay_preflight", "websocket")
    assert_received {:refused, %{count: 1}, %{stage: "runtime_replay_preflight", transport: "websocket"}}

    for transport <- ["http_json", "http_sse", "http_compact_json"] do
      assert :ok = DuplicateTurnTelemetry.emit_refused("native_http_turn_claim", transport)
      assert_received {:refused, %{count: 1}, %{stage: "native_http_turn_claim", transport: "http"}}
    end

    assert :ok = DuplicateTurnTelemetry.emit_refused("codex-session-4711", nil)
    assert_received {:refused, %{count: 1}, %{stage: "unknown", transport: "unknown"}}
  end

  test "a raising handler never turns the refusal into another failure" do
    handler_id = "duplicate-turn-telemetry-raising-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        DuplicateTurnTelemetry.event(),
        fn _event, _measurements, _metadata, _config -> raise "handler failure" end,
        nil
      )

    ExUnit.CaptureLog.capture_log(fn ->
      assert :ok = DuplicateTurnTelemetry.emit_refused("client_retry_claim", "websocket")
    end)
  end
end
