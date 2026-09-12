defmodule CodexPooler.Gateway.Routing.AffinityTelemetryTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Routing.AffinityTelemetry

  @event [:codex_pooler, :gateway, :routing, :affinity, :stale_write]

  test "owns the complete bounded operation and affinity-kind vocabularies" do
    assert AffinityTelemetry.event() == @event
    assert AffinityTelemetry.operations() == ~w(success_upsert miss_update)

    assert AffinityTelemetry.affinity_kinds() ==
             ~w(codex_session idempotency_key request_correlation)
  end

  test "emits one bounded count and names no node" do
    attach()

    assert :ok = AffinityTelemetry.emit_stale_write("success_upsert", "request_correlation")

    assert_receive {@event, %{count: 1}, metadata}
    assert metadata == %{operation: "success_upsert", affinity_kind: "request_correlation"}

    # Per-replica attribution is the scrape target's pod label, not a payload
    # field: a node name here would be both unbounded and the wrong layer.
    refute Map.has_key?(metadata, :node)
    refute Map.has_key?(metadata, :instance)
  end

  test "normalizes labels that are not in the vocabulary rather than exporting them" do
    attach()

    assert :ok = AffinityTelemetry.emit_stale_write(:miss_update, :codex_session)

    assert_receive {@event, %{count: 1},
                    %{operation: "miss_update", affinity_kind: "codex_session"}}

    assert :ok = AffinityTelemetry.emit_stale_write("pool-4711", <<0xFF>>)
    assert_receive {@event, %{count: 1}, %{operation: "unknown", affinity_kind: "unknown"}}

    assert :ok = AffinityTelemetry.emit_stale_write(nil, nil)
    assert_receive {@event, %{count: 1}, %{operation: "unknown", affinity_kind: "unknown"}}
  end

  # The property that outranks the metric: both callers sit after a turn has
  # already settled, so nothing a handler does may propagate back to them.
  test "a handler that raises, throws or exits still yields :ok" do
    for failure <- [
          fn -> raise "handler exploded" end,
          fn -> throw(:handler_threw) end,
          fn -> exit(:handler_exited) end
        ] do
      handler_id = "affinity-telemetry-failing-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          @event,
          fn _event, _measurements, _metadata, _config -> failure.() end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = AffinityTelemetry.emit_stale_write("success_upsert", "request_correlation")
      end)
    end
  end

  defp attach do
    parent = self()
    handler_id = "affinity-telemetry-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn event, measurements, metadata, _config ->
          send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end
end
