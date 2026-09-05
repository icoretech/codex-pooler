defmodule CodexPooler.Gateway.Routing.CircuitHealth do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Circuit, as: CircuitStatus
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @circuit_probe_in_flight_key "probe_in_flight_count"
  @saved_reset_recovery_key "saved_reset_recovery"
  @saved_reset_recovery_version 1
  @closed_status CircuitStatus.closed_status()
  @open_status CircuitStatus.open_status()
  @half_open_status CircuitStatus.half_open_status()

  @type saved_reset_recovery :: %{
          required(String.t()) => boolean() | pos_integer() | String.t()
        }
  @type locked_saved_reset_capacity :: %{
          required(:evaluated_at) => DateTime.t(),
          required(:routable_assignment_ids) => MapSet.t(Ecto.UUID.t()),
          required(:states_by_assignment_id) => %{
            required(Ecto.UUID.t()) => RoutingCircuitState.t() | nil
          }
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

  @spec lock_saved_reset_capacity_fence(map()) ::
          {:ok, locked_saved_reset_capacity()} | :context_mismatch
  def lock_saved_reset_capacity_fence(%{
        gateway_auto_context: %{
          capacity_assignment_ids: assignment_ids,
          capacity_identity_ids: identity_ids,
          quota_scope: %{catalog_model: model_identifier},
          route_class: route_class,
          transient_circuit_exclusions: exclusions
        },
        locked_assignment: %PoolUpstreamAssignment{pool_id: pool_id},
        locked_cohort: locked_cohort,
        timestamp: %DateTime{}
      })
      when is_list(assignment_ids) and is_list(identity_ids) and is_list(exclusions) and
             is_binary(model_identifier) and is_binary(route_class) and is_map(locked_cohort) do
    identity_by_assignment_id = Map.new(Enum.zip(assignment_ids, identity_ids))

    locked_circuits =
      lock_current_capacity_circuits(pool_id, assignment_ids, model_identifier, route_class)

    states_by_assignment_id =
      Enum.reduce(locked_circuits, %{}, fn circuit, states ->
        Map.put_new(states, circuit.pool_upstream_assignment_id, circuit)
      end)

    with true <-
           locked_capacity_rows_match?(
             locked_circuits,
             identity_by_assignment_id,
             locked_cohort,
             pool_id,
             model_identifier,
             route_class
           ),
         true <-
           exclusions_match_latest_states?(
             exclusions,
             states_by_assignment_id,
             model_identifier,
             route_class
           ) do
      states_by_assignment_id =
        Map.new(assignment_ids, fn assignment_id ->
          {assignment_id, Map.get(states_by_assignment_id, assignment_id)}
        end)

      evaluated_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      routable_assignment_ids =
        states_by_assignment_id
        |> Enum.filter(fn {_assignment_id, state} ->
          not blocked?(state, settings(), evaluated_at)
        end)
        |> MapSet.new(&elem(&1, 0))

      {:ok,
       %{
         evaluated_at: evaluated_at,
         routable_assignment_ids: routable_assignment_ids,
         states_by_assignment_id: states_by_assignment_id
       }}
    else
      _mismatch -> :context_mismatch
    end
  end

  defp lock_current_capacity_circuits(pool_id, assignment_ids, model_identifier, route_class) do
    Repo.all(
      from circuit in RoutingCircuitState,
        where:
          circuit.pool_id == ^pool_id and is_nil(circuit.api_key_id) and
            circuit.pool_upstream_assignment_id in ^assignment_ids and
            circuit.model_identifier == ^model_identifier and circuit.route_class == ^route_class,
        order_by: [
          asc: circuit.pool_upstream_assignment_id,
          desc: circuit.updated_at,
          desc: circuit.created_at,
          desc: circuit.id
        ],
        lock: "FOR UPDATE"
    )
  end

  @spec lock_saved_reset_recovery_fence(map()) :: :pending | :clear | :context_mismatch
  def lock_saved_reset_recovery_fence(%{
        gateway_auto_context:
          %{
            transient_circuit_exclusions: exclusions
          } = gateway_auto_context,
        locked_assignment: %PoolUpstreamAssignment{} = locked_assignment,
        locked_cohort: locked_cohort,
        locked_identity: %UpstreamIdentity{} = locked_identity,
        timestamp: %DateTime{} = timestamp,
        usable_sibling_identity_ids: %MapSet{} = usable_sibling_identity_ids
      })
      when is_list(exclusions) and is_map(locked_cohort) do
    circuit_ids =
      exclusions
      |> Enum.map(& &1.routing_circuit_state_id)
      |> Enum.sort()

    locked_circuits =
      Repo.all(
        from circuit in RoutingCircuitState,
          where:
            fragment(
              "? = ANY(?::uuid[])",
              circuit.id,
              ^Enum.map(circuit_ids, &Ecto.UUID.dump!/1)
            ),
          order_by: [asc: circuit.id],
          lock: "FOR UPDATE"
      )

    exclusions_by_circuit_id = Map.new(exclusions, &{&1.routing_circuit_state_id, &1})

    with true <- Enum.map(locked_circuits, & &1.id) == circuit_ids,
         {:ok, locked_siblings} <-
           pair_locked_saved_reset_circuits(
             locked_circuits,
             exclusions_by_circuit_id,
             locked_identity,
             locked_cohort,
             locked_assignment,
             gateway_auto_context
           ) do
      if Enum.any?(
           locked_siblings,
           &saved_reset_recovery_pending_for_usable_sibling?(
             &1,
             usable_sibling_identity_ids,
             timestamp
           )
         ) do
        :pending
      else
        :clear
      end
    else
      _mismatch -> :context_mismatch
    end
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

  defp pair_locked_saved_reset_circuits(
         locked_circuits,
         exclusions_by_circuit_id,
         locked_identity,
         locked_cohort,
         locked_assignment,
         gateway_auto_context
       ) do
    Enum.reduce_while(locked_circuits, {:ok, []}, fn circuit, {:ok, pairs} ->
      exclusion = Map.get(exclusions_by_circuit_id, circuit.id)
      sibling = Map.get(locked_cohort, circuit.upstream_identity_id)

      if locked_saved_reset_circuit_context_matches?(
           circuit,
           exclusion,
           sibling,
           locked_identity,
           locked_assignment,
           gateway_auto_context
         ) do
        {:cont, {:ok, [{circuit, sibling} | pairs]}}
      else
        {:halt, :error}
      end
    end)
  end

  defp locked_saved_reset_circuit_context_matches?(
         %RoutingCircuitState{} = circuit,
         exclusion,
         %UpstreamIdentity{} = sibling,
         %UpstreamIdentity{} = locked_identity,
         %PoolUpstreamAssignment{} = locked_assignment,
         gateway_auto_context
       )
       when is_map(exclusion) do
    circuit.upstream_identity_id == exclusion.upstream_identity_id and
      circuit.upstream_identity_id == sibling.id and
      circuit.upstream_identity_id != locked_identity.id and
      circuit.pool_upstream_assignment_id == exclusion.pool_upstream_assignment_id and
      circuit.pool_id == locked_assignment.pool_id and
      circuit.model_identifier == exclusion.model_identifier and
      circuit.model_identifier == gateway_auto_context.quota_scope.catalog_model and
      circuit.route_class == exclusion.route_class and
      circuit.route_class == gateway_auto_context.route_class
  end

  defp locked_saved_reset_circuit_context_matches?(
         _circuit,
         _exclusion,
         _sibling,
         _locked_identity,
         _locked_assignment,
         _gateway_auto_context
       ),
       do: false

  @spec saved_reset_recovery_pending?(RoutingCircuitState.t() | nil, DateTime.t()) :: boolean()
  def saved_reset_recovery_pending?(
        %RoutingCircuitState{status: status},
        _timestamp
      )
      when status in [@closed_status, @half_open_status],
      do: true

  def saved_reset_recovery_pending?(
        %RoutingCircuitState{status: @open_status, next_probe_at: nil},
        _timestamp
      ),
      do: false

  def saved_reset_recovery_pending?(
        %RoutingCircuitState{status: @open_status, next_probe_at: next_probe_at} = circuit,
        timestamp
      ) do
    DateTime.compare(next_probe_at, timestamp) != :gt or
      not saved_reset_recovery_attempted?(circuit) or
      probe_in_flight_count(circuit) > 0
  end

  def saved_reset_recovery_pending?(%RoutingCircuitState{}, _timestamp), do: true

  def saved_reset_recovery_pending?(nil, _timestamp), do: false

  defp saved_reset_recovery_pending_for_usable_sibling?(
         {circuit, sibling},
         usable_sibling_identity_ids,
         timestamp
       ) do
    MapSet.member?(usable_sibling_identity_ids, sibling.id) and
      saved_reset_recovery_pending?(circuit, timestamp)
  end

  defp success_stamp(%RoutingCircuitState{last_success_at: %DateTime{} = last_success_at}),
    do: DateTime.to_iso8601(last_success_at)

  defp success_stamp(%RoutingCircuitState{}), do: "never"
  defp success_stamp(nil), do: "never"

  defp locked_capacity_rows_match?(
         circuits,
         identity_by_assignment_id,
         locked_cohort,
         pool_id,
         model_identifier,
         route_class
       ) do
    Enum.all?(circuits, fn circuit ->
      expected_identity_id =
        Map.get(identity_by_assignment_id, circuit.pool_upstream_assignment_id)

      is_binary(expected_identity_id) and Map.has_key?(locked_cohort, expected_identity_id) and
        circuit.upstream_identity_id == expected_identity_id and circuit.pool_id == pool_id and
        is_nil(circuit.api_key_id) and circuit.model_identifier == model_identifier and
        circuit.route_class == route_class
    end)
  end

  defp exclusions_match_latest_states?(
         exclusions,
         states_by_assignment_id,
         model_identifier,
         route_class
       ) do
    Enum.all?(exclusions, fn exclusion ->
      case Map.get(states_by_assignment_id, exclusion.pool_upstream_assignment_id) do
        %RoutingCircuitState{} = circuit ->
          circuit.id == exclusion.routing_circuit_state_id and
            circuit.upstream_identity_id == exclusion.upstream_identity_id and
            circuit.model_identifier == model_identifier and
            circuit.model_identifier == exclusion.model_identifier and
            circuit.route_class == route_class and circuit.route_class == exclusion.route_class

        nil ->
          false
      end
    end)
  end
end
