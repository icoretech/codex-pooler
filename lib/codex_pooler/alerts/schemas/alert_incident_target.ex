defmodule CodexPooler.Alerts.Schemas.AlertIncidentTarget do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type attrs :: map()

  schema "alert_incident_targets" do
    field :incident_id, :binary_id
    field :rule_id, :binary_id
    field :pool_id, :binary_id
    field :first_matched_at, :utc_datetime_usec
    field :last_matched_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(target, attrs) do
    target
    |> cast(attrs, [
      :incident_id,
      :rule_id,
      :pool_id,
      :first_matched_at,
      :last_matched_at,
      :resolved_at,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> validate_required([
      :incident_id,
      :rule_id,
      :pool_id,
      :first_matched_at,
      :last_matched_at,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> check_constraint(:metadata, name: :alert_incident_targets_metadata_shape_check)
    |> unique_constraint(:pool_id, name: :alert_incident_targets_incident_rule_pool_uq)
  end
end
