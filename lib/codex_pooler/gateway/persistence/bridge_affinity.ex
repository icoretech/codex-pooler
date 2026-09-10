defmodule CodexPooler.Gateway.Persistence.BridgeAffinity do
  @moduledoc false
  use CodexPooler.Schema

  @type status :: String.t()
  @type t :: %__MODULE__{}

  schema "bridge_affinities" do
    field :pool_id, :binary_id
    field :api_key_id, :binary_id
    field :model_identifier, :string
    field :affinity_kind, :string
    field :affinity_key_hash, :binary
    field :pool_upstream_assignment_id, :binary_id
    field :upstream_identity_id, :binary_id
    field :generation, :integer, default: 0
    field :expires_at, :utc_datetime_usec
    field :status, :string
    field :last_hit_at, :utc_datetime_usec
    field :last_miss_at, :utc_datetime_usec
    field :metadata, :map
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec active_status() :: status()
  def active_status, do: "active"
end
