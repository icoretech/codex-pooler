defmodule CodexPooler.Pools.OperatorPoolAssignment do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @statuses ~w(active revoked)

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type status :: String.t()

  schema "operator_pool_assignments" do
    field :user_id, :binary_id
    field :pool_id, :binary_id
    field :status, :string
    field :created_by_user_id, :binary_id
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :user_id,
      :pool_id,
      :status,
      :created_by_user_id,
      :created_at,
      :updated_at,
      :revoked_at
    ])
    |> validate_required([:user_id, :pool_id, :status, :created_at, :updated_at])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:pool_id, name: :operator_pool_assignments_user_pool_active_uq)
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec active_status() :: status()
  def active_status, do: "active"

  @spec revoked_status() :: status()
  def revoked_status, do: "revoked"
end
