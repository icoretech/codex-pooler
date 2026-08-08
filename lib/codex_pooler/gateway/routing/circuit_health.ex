defmodule CodexPooler.Gateway.Routing.CircuitHealth do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Circuit, as: CircuitStatus
  alias CodexPooler.Repo

  @circuit_probe_in_flight_key "probe_in_flight_count"
  @saved_reset_recovery_key "saved_reset_recovery"
  @saved_reset_recovery_version 1
  @open_status CircuitStatus.open_status()
  @half_open_status CircuitStatus.half_open_status()

  @type saved_reset_recovery :: %{
          required(String.t()) => boolean() | pos_integer() | String.t()
        }

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

  @spec blocked_reason(
          RoutingCircuitState.t() | nil,
          OperationalSettings.t(),
          DateTime.t()
        ) :: String.t() | nil
  def blocked_reason(
        %RoutingCircuitState{status: @open_status, next_probe_at: %DateTime{} = next_probe_at},
        _settings,
        now
      ) do
    if DateTime.compare(next_probe_at, now) == :gt, do: "open_cooldown"
  end

  def blocked_reason(%RoutingCircuitState{status: @open_status}, _settings, _now),
    do: "open_no_probe"

  def blocked_reason(%RoutingCircuitState{status: @half_open_status} = state, settings, now) do
    if blocked?(state, settings, now), do: "probe_saturated"
  end

  def blocked_reason(_state, _settings, _now), do: nil

  @spec active_circuits(Ecto.UUID.t() | nil) :: [RoutingCircuitState.t()]
  def active_circuits(pool_id) do
    Repo.all(
      from state in RoutingCircuitState,
        where:
          state.pool_id == ^pool_id and is_nil(state.api_key_id) and
            state.status in [@open_status, @half_open_status],
        order_by: [
          asc: state.pool_upstream_assignment_id,
          asc: state.model_identifier,
          asc: state.route_class
        ]
    )
  end

  @spec settings() :: OperationalSettings.t()
  def settings, do: OperationalSettings.current()

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

  def probe_metadata(_state, count), do: %{@circuit_probe_in_flight_key => max(count, 0)}

  @spec saved_reset_recovery(RoutingCircuitState.t()) :: saved_reset_recovery() | nil
  def saved_reset_recovery(%RoutingCircuitState{metadata: metadata} = state)
      when is_map(metadata) do
    case Map.get(metadata, @saved_reset_recovery_key) do
      %{
        "version" => @saved_reset_recovery_version,
        "attempted" => attempted,
        "since_success_at" => since_success_at
      } = marker
      when map_size(marker) == 3 and is_boolean(attempted) and is_binary(since_success_at) ->
        if since_success_at == success_stamp(state), do: marker

      _marker ->
        nil
    end
  end

  def saved_reset_recovery(%RoutingCircuitState{}), do: nil

  @spec valid_saved_reset_recovery?(RoutingCircuitState.t()) :: boolean()
  def valid_saved_reset_recovery?(%RoutingCircuitState{} = state),
    do: not is_nil(saved_reset_recovery(state))

  @spec saved_reset_recovery_attempted?(RoutingCircuitState.t()) :: boolean()
  def saved_reset_recovery_attempted?(%RoutingCircuitState{} = state) do
    match?(%{"attempted" => true}, saved_reset_recovery(state))
  end

  @spec put_saved_reset_recovery(
          RoutingCircuitState.t() | nil,
          boolean(),
          map()
        ) :: map()
  def put_saved_reset_recovery(state, attempted, metadata)
      when (is_struct(state, RoutingCircuitState) or is_nil(state)) and is_boolean(attempted) and
             is_map(metadata) do
    Map.put(metadata, @saved_reset_recovery_key, %{
      "version" => @saved_reset_recovery_version,
      "attempted" => attempted,
      "since_success_at" => success_stamp(state)
    })
  end

  @spec preserve_saved_reset_recovery(RoutingCircuitState.t() | nil, map()) :: map()
  def preserve_saved_reset_recovery(%RoutingCircuitState{metadata: state_metadata}, metadata)
      when is_map(state_metadata) and is_map(metadata) do
    case Map.fetch(state_metadata, @saved_reset_recovery_key) do
      {:ok, marker} -> Map.put(metadata, @saved_reset_recovery_key, marker)
      :error -> Map.delete(metadata, @saved_reset_recovery_key)
    end
  end

  def preserve_saved_reset_recovery(_state, metadata) when is_map(metadata),
    do: Map.delete(metadata, @saved_reset_recovery_key)

  @spec clear_saved_reset_recovery(map()) :: map()
  def clear_saved_reset_recovery(metadata) when is_map(metadata),
    do: Map.delete(metadata, @saved_reset_recovery_key)

  defp success_stamp(%RoutingCircuitState{last_success_at: %DateTime{} = last_success_at}),
    do: DateTime.to_iso8601(last_success_at)

  defp success_stamp(%RoutingCircuitState{}), do: "never"
  defp success_stamp(nil), do: "never"
end
