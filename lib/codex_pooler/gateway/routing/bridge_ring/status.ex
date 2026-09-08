defmodule CodexPooler.Gateway.Routing.BridgeRing.Status do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Gateway.Persistence.{BridgeAffinity, BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Gateway.Routing.BridgeRing
  alias CodexPooler.Pools.{Pool, RoutingSettings}
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPooler.Repo

  @default_strategy "bridge_ring"
  @default_ring_size 3

  @spec routing_status(Pool.t() | Ecto.UUID.t() | term()) :: BridgeRing.routing_status()
  def routing_status(%Pool{} = pool), do: routing_status(pool.id)

  def routing_status(pool_id) when is_binary(pool_id) do
    settings = PoolRouting.get_routing_settings(pool_id) || default_settings(pool_id)
    active_affinity_status = BridgeAffinity.active_status()
    active_demotion_status = BridgeDemotion.active_status()

    active_circuit_statuses = [
      RoutingCircuitState.open_status(),
      RoutingCircuitState.half_open_status()
    ]

    now = DateTime.utc_now()

    active_affinity_count =
      Repo.aggregate(
        from(affinity in BridgeAffinity,
          where: affinity.pool_id == ^pool_id and affinity.status == ^active_affinity_status,
          where: is_nil(affinity.expires_at) or affinity.expires_at > ^now
        ),
        :count,
        :id
      )

    active_demotions =
      Repo.all(
        from demotion in BridgeDemotion,
          where: demotion.pool_id == ^pool_id and demotion.status == ^active_demotion_status,
          order_by: [desc: demotion.updated_at],
          limit: 20
      )

    active_circuits =
      Repo.all(
        from circuit in RoutingCircuitState,
          where: circuit.pool_id == ^pool_id and circuit.status in ^active_circuit_statuses,
          order_by: [desc: circuit.updated_at],
          limit: 20
      )

    %{
      settings: settings,
      active_affinity_count: active_affinity_count,
      active_demotion_count: length(active_demotions),
      active_circuit_count: length(active_circuits),
      recent_demotions: active_demotions,
      recent_circuits: active_circuits
    }
  end

  def routing_status(_pool_id) do
    %{
      settings: nil,
      active_affinity_count: 0,
      active_demotion_count: 0,
      active_circuit_count: 0,
      recent_demotions: [],
      recent_circuits: []
    }
  end

  defp default_settings(pool_id) do
    %RoutingSettings{
      pool_id: pool_id,
      routing_strategy: @default_strategy,
      bridge_ring_size: @default_ring_size,
      sticky_websocket_sessions: true,
      sticky_http_sessions: false,
      metadata: %{}
    }
  end
end
