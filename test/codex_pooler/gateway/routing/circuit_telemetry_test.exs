defmodule CodexPooler.Gateway.Routing.CircuitTelemetryTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.CircuitTelemetry

  @event [:codex_pooler, :gateway, :routing, :circuit, :transition]

  test "owns the complete bounded transition and reason vocabularies" do
    assert CircuitTelemetry.transitions() == ~w(
             closed_to_open
             open_to_half_open
             open_to_closed
             half_open_to_closed
             half_open_to_open
           )

    assert CircuitTelemetry.reason_classes() == ~w(
             upstream_status
             retryable_upstream_status
             upstream_5xx
             upstream_rate_limited
             upstream_unauthorized
             upstream_network_error
             upstream_model_unavailable
             upstream_stream_error
             stream_idle_timeout
             upstream_response_too_large
             invalid_upstream_base_url
             client_disconnected
             none
             unknown
           )
  end

  test "emits bounded tags and keeps circuit detail in metadata" do
    parent = self()
    handler_id = "circuit-telemetry-test-#{System.unique_integer([:positive])}"

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

    state = %RoutingCircuitState{
      pool_id: Ecto.UUID.generate(),
      pool_upstream_assignment_id: Ecto.UUID.generate(),
      upstream_identity_id: Ecto.UUID.generate(),
      model_identifier: "synthetic-model",
      route_class: "proxy_stream",
      status: "open",
      reason_code: "upstream_network_error",
      failure_count: 3
    }

    assert :ok = CircuitTelemetry.emit_transition("closed", "open", state, [])

    assert_receive {@event, %{count: 1}, metadata}
    assert metadata.transition == "closed_to_open"
    assert metadata.from_status == "closed"
    assert metadata.to_status == "open"
    assert metadata.route_class == "proxy_stream"
    assert metadata.reason_class == "upstream_network_error"
    assert metadata.reason_code == "upstream_network_error"
    assert metadata.failure_count == 3
    assert metadata.pool_id == state.pool_id
    assert metadata.pool_upstream_assignment_id == state.pool_upstream_assignment_id
    assert metadata.upstream_identity_id == state.upstream_identity_id
    assert metadata.model_identifier == "synthetic-model"
  end

  test "classifies absent and unbounded reasons without creating new reason classes" do
    assert emitted_reason_class(nil) == "none"
    assert emitted_reason_class(:upstream_rate_limited) == "upstream_rate_limited"
    assert emitted_reason_class(:retryable_upstream_status) == "retryable_upstream_status"
    assert emitted_reason_class("provider free text") == "unknown"
    assert emitted_reason_class(String.duplicate("x", 80)) == "unknown"
  end

  test "emits unknown for an unrecognised status pair" do
    parent = self()
    handler_id = "circuit-transition-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn _event, _measurements, metadata, _config ->
          send(parent, {handler_id, metadata.transition})
        end,
        nil
      )

    try do
      assert :ok =
               CircuitTelemetry.emit_transition(
                 "open",
                 "deleted",
                 %RoutingCircuitState{route_class: "proxy_stream"},
                 []
               )

      assert_receive {^handler_id, "unknown"}
    after
      :telemetry.detach(handler_id)
    end
  end

  test "never raises after a committed write when event metadata is malformed" do
    assert :ok =
             CircuitTelemetry.emit_transition(
               "closed",
               "open",
               %RoutingCircuitState{route_class: %{unexpected: :shape}},
               %{unexpected: :options}
             )
  end

  defp emitted_reason_class(reason_code) do
    parent = self()
    handler_id = "circuit-reason-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn _event, _measurements, metadata, _config ->
          send(parent, {handler_id, metadata.reason_class})
        end,
        nil
      )

    try do
      assert :ok =
               CircuitTelemetry.emit_transition(
                 "half_open",
                 "open",
                 %RoutingCircuitState{route_class: "proxy_stream"},
                 reason_code: reason_code
               )

      assert_receive {^handler_id, reason_class}
      reason_class
    after
      :telemetry.detach(handler_id)
    end
  end
end
