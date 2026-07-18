defmodule CodexPooler.Accounting.RequestLogFact do
  @moduledoc """
  Accounting-owned 1:1 request-log facts projection row.
  """
  use CodexPooler.Schema

  @primary_key {:request_id, :binary_id, autogenerate: false}
  @type t :: %__MODULE__{}

  schema "request_log_facts" do
    field :latest_attempt_id, :binary_id
    field :latest_attempt_number, :integer
    field :latest_attempt_status, :string
    field :latest_attempt_retryable, :boolean
    field :latest_upstream_status_code, :integer
    field :latest_pool_upstream_assignment_id, :binary_id
    field :latest_upstream_identity_id, :binary_id
    field :latest_network_error_code, :string
    field :latest_latency_ms, :integer
    field :latest_settlement_entry_id, :binary_id
    field :latest_settlement_usage_status, :string
    field :latest_settlement_pricing_status, :string
    field :latest_input_tokens, :integer
    field :latest_cached_input_tokens, :integer
    field :latest_cache_write_tokens, :integer
    field :latest_output_tokens, :integer
    field :latest_reasoning_tokens, :integer
    field :latest_total_tokens, :integer
    field :latest_settled_cost_micros, :integer
    field :latest_estimated_cost_micros, :integer
    field :latest_cached_input_cost_micros, :integer
    field :latest_cached_input_token_micros, :integer
    field :latest_settlement_occurred_at, :utc_datetime_usec
    field :latest_settlement_created_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
