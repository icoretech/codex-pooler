defmodule CodexPooler.Alerts.Schemas.AlertDeliveryAttempt do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @statuses ~w(pending sent retryable failed discarded)
  @fixed_max_attempts 5

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type status :: String.t()

  schema "alert_delivery_attempts" do
    field :incident_id, :binary_id
    field :channel_id, :binary_id
    field :attempt_number, :integer
    field :max_attempts, :integer, default: @fixed_max_attempts
    field :status, :string, default: "pending"
    field :scheduled_at, :utc_datetime_usec
    field :attempted_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :next_retry_at, :utc_datetime_usec
    field :response_status_code, :integer
    field :retryable, :boolean, default: false
    field :failure_code, :string
    field :failure_message, :string
    field :response_metadata, :map, default: %{}
    field :failure_metadata, :map, default: %{}
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :incident_id,
      :channel_id,
      :attempt_number,
      :max_attempts,
      :status,
      :scheduled_at,
      :attempted_at,
      :completed_at,
      :next_retry_at,
      :response_status_code,
      :retryable,
      :failure_code,
      :failure_message,
      :response_metadata,
      :failure_metadata,
      :created_at,
      :updated_at
    ])
    |> update_change(:failure_code, &trim_optional_string/1)
    |> update_change(:failure_message, &trim_optional_string/1)
    |> validate_required([
      :incident_id,
      :channel_id,
      :attempt_number,
      :max_attempts,
      :status,
      :scheduled_at,
      :retryable,
      :response_metadata,
      :failure_metadata,
      :created_at,
      :updated_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempt_number,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @fixed_max_attempts
    )
    |> validate_number(:max_attempts, equal_to: @fixed_max_attempts)
    |> check_constraint(:status, name: :alert_delivery_attempts_status_check)
    |> check_constraint(:max_attempts, name: :alert_delivery_attempts_max_attempts_check)
    |> check_constraint(:attempt_number, name: :alert_delivery_attempts_attempt_number_check)
    |> check_constraint(:response_metadata,
      name: :alert_delivery_attempts_response_metadata_shape_check
    )
    |> check_constraint(:failure_metadata,
      name: :alert_delivery_attempts_failure_metadata_shape_check
    )
    |> unique_constraint(:attempt_number,
      name: :alert_delivery_attempts_incident_channel_attempt_uq
    )
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec fixed_max_attempts() :: pos_integer()
  def fixed_max_attempts, do: @fixed_max_attempts

  @spec pending_status() :: status()
  def pending_status, do: "pending"

  @spec sent_status() :: status()
  def sent_status, do: "sent"

  @spec retryable_status() :: status()
  def retryable_status, do: "retryable"

  @spec failed_status() :: status()
  def failed_status, do: "failed"

  @spec discarded_status() :: status()
  def discarded_status, do: "discarded"

  defp trim_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_optional_string(value), do: value
end
