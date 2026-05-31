defmodule CodexPooler.Alerts.Schemas.AlertIncidentReceipt do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type attrs :: map()

  schema "alert_incident_receipts" do
    field :operator_id, :binary_id
    field :incident_id, :binary_id
    field :read_at, :utc_datetime_usec
    field :dismissed_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :operator_id,
      :incident_id,
      :read_at,
      :dismissed_at,
      :created_at,
      :updated_at
    ])
    |> validate_required([:operator_id, :incident_id, :created_at, :updated_at])
    |> foreign_key_constraint(:operator_id)
    |> foreign_key_constraint(:incident_id)
    |> unique_constraint(:incident_id, name: :alert_incident_receipts_operator_incident_uq)
  end
end
