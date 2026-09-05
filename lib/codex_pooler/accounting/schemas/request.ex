defmodule CodexPooler.Accounting.Request do
  @moduledoc """
  Accounting-owned request lifecycle row.
  """
  use CodexPooler.Schema

  @type t :: %__MODULE__{}

  schema "requests" do
    field :pool_id, :binary_id
    field :api_key_id, :binary_id
    field :model_id, :binary_id
    field :requested_model, :string
    field :endpoint, :string
    field :transport, :string
    field :status, :string
    field :usage_status, :string
    field :correlation_id, :string
    field :idempotency_key, :string
    field :client_ip, CodexPooler.Postgres.INET
    field :user_agent, :string
    field :request_metadata, :map
    field :admitted_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :response_status_code, :integer
    field :retry_count, :integer
    field :last_error_code, :string
    field :upstream_account_label, :string
    field :upstream_account_email, :string
    field :upstream_account_plan_label, :string
    field :upstream_account_plan_family, :string
    field :reasoning_effort, :string
    field :service_tier, :string
    field :requested_service_tier, :string
    field :actual_service_tier, :string
    field :native_client_retry_version, :integer
    field :native_client_retry_digest, :binary
    field :native_client_retry_auth_epoch, :integer
  end
end
