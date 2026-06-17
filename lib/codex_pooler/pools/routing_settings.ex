defmodule CodexPooler.Pools.RoutingSettings do
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type attrs :: map()

  @routing_strategies ~w(bridge_ring deterministic_rotation least_recent_success quota_first)

  @primary_key {:pool_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "pool_routing_settings" do
    field :routing_strategy, :string
    field :bridge_ring_size, :integer
    field :sticky_websocket_sessions, :boolean
    field :sticky_http_sessions, :boolean
    field :prompt_cache_affinity_enabled, :boolean, default: true
    field :v1_compatibility_enabled, :boolean, default: true
    field :request_compression_enabled, :boolean, default: false
    field :metadata, :map
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :pool_id,
      :routing_strategy,
      :bridge_ring_size,
      :sticky_websocket_sessions,
      :sticky_http_sessions,
      :prompt_cache_affinity_enabled,
      :v1_compatibility_enabled,
      :request_compression_enabled,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> validate_required([
      :pool_id,
      :routing_strategy,
      :bridge_ring_size,
      :sticky_websocket_sessions,
      :sticky_http_sessions,
      :prompt_cache_affinity_enabled,
      :v1_compatibility_enabled,
      :request_compression_enabled,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> validate_inclusion(:routing_strategy, @routing_strategies)
    |> validate_number(:bridge_ring_size, greater_than_or_equal_to: 1)
  end

  @spec routing_strategies() :: [String.t()]
  def routing_strategies, do: @routing_strategies
end
