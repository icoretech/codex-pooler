defmodule CodexPooler.Gateway.Persistence.BridgeOwnerLease do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  alias CodexPooler.Gateway.Persistence.StatusVocabulary.OwnerLease, as: OwnerLeaseStatus

  @statuses OwnerLeaseStatus.statuses()

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type status :: String.t()

  schema "bridge_owner_leases" do
    field :codex_session_id, :binary_id
    field :pool_id, :binary_id
    field :api_key_id, :binary_id
    field :pool_upstream_assignment_id, :binary_id
    field :owner_instance_id, :string
    field :lease_token, :binary_id
    field :status, :string
    field :acquired_at, :utc_datetime_usec
    field :renewed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :released_at, :utc_datetime_usec
    field :metadata, :map
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(lease, attrs) do
    lease
    |> cast(attrs, [
      :codex_session_id,
      :pool_id,
      :api_key_id,
      :pool_upstream_assignment_id,
      :owner_instance_id,
      :lease_token,
      :status,
      :acquired_at,
      :renewed_at,
      :expires_at,
      :released_at,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> validate_required([
      :codex_session_id,
      :pool_id,
      :api_key_id,
      :owner_instance_id,
      :lease_token,
      :status,
      :acquired_at,
      :renewed_at,
      :expires_at,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> validate_inclusion(:status, @statuses)
  end

  @spec statuses() :: [status()]
  defdelegate statuses(), to: OwnerLeaseStatus

  @spec active_status() :: status()
  defdelegate active_status(), to: OwnerLeaseStatus

  @spec expired_status() :: status()
  defdelegate expired_status(), to: OwnerLeaseStatus

  @spec released_status() :: status()
  defdelegate released_status(), to: OwnerLeaseStatus
end
