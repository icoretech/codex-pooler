defmodule CodexPooler.Gateway.Routing.CircuitHealthAlertsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.CircuitHealth

  setup do
    previous_settings = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      settings: %OperationalSettings{
        circuit_open_seconds: 60,
        circuit_half_open_probe_limit: 1
      }
    )

    on_exit(fn ->
      if previous_settings do
        Application.put_env(:codex_pooler, OperationalSettings, previous_settings)
      else
        Application.delete_env(:codex_pooler, OperationalSettings)
      end
    end)
  end

  test "alert-facing blocked reasons stay inside the bounded routing vocabulary" do
    observed_at = ~U[2026-05-30 09:20:00Z]
    settings = CircuitHealth.settings()

    scenarios = [
      {%RoutingCircuitState{
         status: "open",
         next_probe_at: DateTime.add(observed_at, 60, :second)
       }, "open_cooldown"},
      {%RoutingCircuitState{status: "open", next_probe_at: nil}, "open_no_probe"},
      {%RoutingCircuitState{
         status: "half_open",
         metadata: %{"probe_in_flight_count" => 1},
         updated_at: observed_at
       }, "probe_saturated"},
      {%RoutingCircuitState{
         status: "half_open",
         metadata: %{"probe_in_flight_count" => 0},
         updated_at: observed_at
       }, nil}
    ]

    assert Enum.map(scenarios, fn {state, expected} ->
             {CircuitHealth.blocked_reason(state, settings, observed_at), expected}
           end) == Enum.map(scenarios, fn {_state, expected} -> {expected, expected} end)
  end
end
