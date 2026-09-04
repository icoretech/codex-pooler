defmodule CodexPooler.Accounting.Attempt do
  @moduledoc """
  Accounting-owned upstream attempt lifecycle row.
  """
  use CodexPooler.Schema

  @type t :: %__MODULE__{}

  schema "attempts" do
    field :request_id, :binary_id
    field :attempt_number, :integer
    field :pool_upstream_assignment_id, :binary_id
    field :upstream_identity_id, :binary_id
    field :pricing_snapshot_id, :binary_id
    field :model_id, :binary_id
    field :upstream_model_id, :string
    field :transport, :string
    field :status, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :upstream_status_code, :integer
    field :retryable, :boolean
    field :network_error_code, :string
    field :error_message, :string
    field :latency_ms, :integer
    field :usage_status, :string
    field :response_metadata, :map
    field :replay_generation, :integer, default: 0
  end
end
