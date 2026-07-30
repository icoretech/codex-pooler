defmodule CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment do
  @moduledoc """
  Persisted assignment between a pool and an upstream account identity.

  The `CodexPooler.Upstreams.Schemas.*` namespace is intentional for upstream
  database structs so runtime callers can distinguish schemas from the operator
  context facade.
  """
  use CodexPooler.Schema

  import Ecto.Changeset

  alias CodexPooler.Upstreams.StatusVocabulary.Assignment, as: AssignmentStatus

  @statuses AssignmentStatus.statuses()
  @health_statuses AssignmentStatus.health_statuses()
  @eligibility_statuses AssignmentStatus.eligibility_statuses()

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type status :: String.t()
  @type health_status :: String.t()
  @type eligibility_status :: String.t()

  schema "pool_upstream_assignments" do
    field :pool_id, :binary_id
    field :upstream_identity_id, :binary_id
    field :assignment_label, :string
    field :status, :string
    field :health_status, :string
    field :eligibility_status, :string
    field :cooldown_until, :utc_datetime_usec
    field :last_healthcheck_at, :utc_datetime_usec
    field :last_successful_refresh_at, :utc_datetime_usec
    field :last_successful_sync_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec
    field :created_by_user_id, :binary_id
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :metadata, :map
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :pool_id,
      :upstream_identity_id,
      :assignment_label,
      :status,
      :health_status,
      :eligibility_status,
      :cooldown_until,
      :last_healthcheck_at,
      :last_successful_refresh_at,
      :last_successful_sync_at,
      :disabled_at,
      :created_by_user_id,
      :created_at,
      :updated_at,
      :metadata
    ])
    |> update_change(:assignment_label, &String.trim/1)
    |> validate_required([
      :pool_id,
      :upstream_identity_id,
      :assignment_label,
      :status,
      :health_status,
      :eligibility_status,
      :created_at,
      :updated_at,
      :metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:health_status, @health_statuses)
    |> validate_inclusion(:eligibility_status, @eligibility_statuses)
    |> unique_constraint(:upstream_identity_id, name: :pool_upstream_assignments_identity_uq)
  end

  @spec statuses() :: [status()]
  defdelegate statuses(), to: AssignmentStatus

  @spec health_statuses() :: [health_status()]
  defdelegate health_statuses(), to: AssignmentStatus

  @spec eligibility_statuses() :: [eligibility_status()]
  defdelegate eligibility_statuses(), to: AssignmentStatus

  @spec pending_status() :: status()
  defdelegate pending_status(), to: AssignmentStatus

  @spec active_status() :: status()
  defdelegate active_status(), to: AssignmentStatus

  @spec paused_status() :: status()
  defdelegate paused_status(), to: AssignmentStatus

  @spec refresh_due_status() :: status()
  defdelegate refresh_due_status(), to: AssignmentStatus

  @spec refreshing_status() :: status()
  defdelegate refreshing_status(), to: AssignmentStatus

  @spec refresh_failed_status() :: status()
  defdelegate refresh_failed_status(), to: AssignmentStatus

  @spec reauth_required_status() :: status()
  defdelegate reauth_required_status(), to: AssignmentStatus

  @spec deleted_status() :: status()
  defdelegate deleted_status(), to: AssignmentStatus

  @spec disabled_status() :: status()
  defdelegate disabled_status(), to: AssignmentStatus

  @spec errored_status() :: status()
  defdelegate errored_status(), to: AssignmentStatus

  @spec unknown_health_status() :: health_status()
  defdelegate unknown_health_status(), to: AssignmentStatus

  @spec active_health_status() :: health_status()
  defdelegate active_health_status(), to: AssignmentStatus

  @spec cooldown_health_status() :: health_status()
  defdelegate cooldown_health_status(), to: AssignmentStatus

  @spec degraded_health_status() :: health_status()
  defdelegate degraded_health_status(), to: AssignmentStatus

  @spec disabled_health_status() :: health_status()
  defdelegate disabled_health_status(), to: AssignmentStatus

  @spec errored_health_status() :: health_status()
  defdelegate errored_health_status(), to: AssignmentStatus

  @spec eligible_status() :: eligibility_status()
  defdelegate eligible_status(), to: AssignmentStatus

  @spec ineligible_status() :: eligibility_status()
  defdelegate ineligible_status(), to: AssignmentStatus
end
