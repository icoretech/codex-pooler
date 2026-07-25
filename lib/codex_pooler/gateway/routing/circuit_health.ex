defmodule CodexPooler.Gateway.Routing.CircuitHealth do
  @moduledoc false

  alias CodexPooler.Gateway.Persistence.RoutingCircuitState

  @circuit_probe_in_flight_key "probe_in_flight_count"
  @open_status RoutingCircuitState.open_status()
  @half_open_status RoutingCircuitState.half_open_status()

  @spec blocked?(
          RoutingCircuitState.t() | nil,
          CodexPooler.Gateway.OperationalSettings.t(),
          DateTime.t()
        ) :: boolean()
  def blocked?(
        %RoutingCircuitState{status: @open_status, next_probe_at: %DateTime{} = next_probe_at},
        _settings,
        now
      ) do
    DateTime.compare(next_probe_at, now) == :gt
  end

  def blocked?(%RoutingCircuitState{status: @open_status}, _settings, _now), do: true

  def blocked?(%RoutingCircuitState{status: @half_open_status} = state, settings, now) do
    probe_in_flight_count(state) >= settings.circuit_half_open_probe_limit and
      not probe_stale?(state, settings, now)
  end

  def blocked?(_state, _settings, _now), do: false

  def probe_stale?(
        %RoutingCircuitState{status: @half_open_status, updated_at: %DateTime{} = updated_at},
        settings,
        now
      ) do
    DateTime.diff(now, updated_at, :second) >= settings.circuit_open_seconds
  end

  def probe_stale?(_state, _settings, _now), do: false

  def probe_in_flight_count(%RoutingCircuitState{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, @circuit_probe_in_flight_key) do
      value when is_integer(value) and value > 0 -> value
      _value -> 0
    end
  end

  def probe_in_flight_count(_state), do: 0

  def probe_metadata(%RoutingCircuitState{metadata: metadata}, count) when is_map(metadata) do
    Map.put(metadata, @circuit_probe_in_flight_key, max(count, 0))
  end

  def probe_metadata(_state, count),
    do: %{@circuit_probe_in_flight_key => max(count, 0)}
end
