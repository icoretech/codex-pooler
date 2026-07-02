defmodule CodexPooler.Alerts.Schemas.AlertIncident do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @scope_types ~w(pool upstream_identity)
  @rule_kinds ~w(pool_no_usable_assignments pool_low_usable_assignments pool_all_assignments_in_state upstream_quota_threshold upstream_auth_state upstream_saved_reset_banked_first_seen)
  @severities ~w(info warning critical)
  @states ~w(open acknowledged resolved)

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type scope_type :: String.t()
  @type rule_kind :: String.t()
  @type severity :: String.t()
  @type state :: String.t()

  schema "alert_incidents" do
    field :dedupe_key, :string
    field :scope_type, :string
    field :rule_kind, :string
    field :severity, :string
    field :state, :string, default: "open"
    field :pool_id, :binary_id
    field :upstream_identity_id, :binary_id
    field :occurrence_count, :integer, default: 1
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :acknowledged_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :safe_evidence_snapshot, :map, default: %{}
    field :suppression_metadata, :map, default: %{}
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(incident, attrs) do
    incident
    |> cast(attrs, [
      :dedupe_key,
      :scope_type,
      :rule_kind,
      :severity,
      :state,
      :pool_id,
      :upstream_identity_id,
      :occurrence_count,
      :first_seen_at,
      :last_seen_at,
      :acknowledged_at,
      :resolved_at,
      :safe_evidence_snapshot,
      :suppression_metadata,
      :created_at,
      :updated_at
    ])
    |> update_change(:dedupe_key, &String.trim/1)
    |> validate_required([
      :dedupe_key,
      :scope_type,
      :rule_kind,
      :severity,
      :state,
      :occurrence_count,
      :first_seen_at,
      :last_seen_at,
      :safe_evidence_snapshot,
      :suppression_metadata,
      :created_at,
      :updated_at
    ])
    |> validate_length(:dedupe_key, min: 1)
    |> validate_inclusion(:scope_type, @scope_types)
    |> validate_inclusion(:rule_kind, @rule_kinds)
    |> validate_inclusion(:severity, @severities)
    |> validate_inclusion(:state, @states)
    |> validate_number(:occurrence_count, greater_than: 0)
    |> check_constraint(:scope_type, name: :alert_incidents_scope_type_check)
    |> check_constraint(:scope_type, name: :alert_incidents_scope_target_check)
    |> check_constraint(:rule_kind, name: :alert_incidents_rule_kind_check)
    |> check_constraint(:severity, name: :alert_incidents_severity_check)
    |> check_constraint(:state, name: :alert_incidents_state_check)
    |> check_constraint(:occurrence_count, name: :alert_incidents_occurrence_count_check)
    |> check_constraint(:safe_evidence_snapshot,
      name: :alert_incidents_safe_evidence_snapshot_shape_check
    )
    |> check_constraint(:suppression_metadata,
      name: :alert_incidents_suppression_metadata_shape_check
    )
    |> unique_constraint(:dedupe_key,
      name: :alert_incidents_unresolved_dedupe_key_uq,
      message: "already has an unresolved incident"
    )
  end

  @spec scope_types() :: [scope_type()]
  def scope_types, do: @scope_types

  @spec rule_kinds() :: [rule_kind()]
  def rule_kinds, do: @rule_kinds

  @spec severities() :: [severity()]
  def severities, do: @severities

  @spec states() :: [state()]
  def states, do: @states

  @spec open_state() :: state()
  def open_state, do: "open"

  @spec acknowledged_state() :: state()
  def acknowledged_state, do: "acknowledged"

  @spec resolved_state() :: state()
  def resolved_state, do: "resolved"
end
