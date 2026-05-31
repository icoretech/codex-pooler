defmodule CodexPooler.Alerts.Schemas.AlertRuleChannel do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type attrs :: map()

  schema "alert_rule_channels" do
    field :alert_rule_id, :binary_id
    field :alert_channel_id, :binary_id
    field :created_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(rule_channel, attrs) do
    rule_channel
    |> cast(attrs, [:alert_rule_id, :alert_channel_id, :created_at])
    |> validate_required([:alert_rule_id, :alert_channel_id, :created_at])
    |> unique_constraint(:alert_channel_id, name: :alert_rule_channels_rule_channel_uq)
  end
end
