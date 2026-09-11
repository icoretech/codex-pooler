defmodule CodexPooler.Status.Schemas.Dismissal do
  @moduledoc false
  use CodexPooler.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "openai_status_dismissals" do
    field :operator_id, :binary_id
    field :incident_id, :binary_id
    field :incident_revision, :integer
    field :dismissed_at, :utc_datetime_usec
  end

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [:operator_id, :incident_id, :incident_revision, :dismissed_at])
    |> validate_required([:operator_id, :incident_id, :incident_revision, :dismissed_at])
    |> validate_number(:incident_revision, greater_than_or_equal_to: 1)
    |> foreign_key_constraint(:operator_id)
    |> foreign_key_constraint(:incident_id)
    |> unique_constraint(:incident_revision,
      name: :openai_status_dismissals_operator_incident_revision_uq
    )
  end
end
