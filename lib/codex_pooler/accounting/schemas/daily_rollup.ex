defmodule CodexPooler.Accounting.DailyRollup do
  @moduledoc false
  use CodexPooler.Schema

  @type t :: %__MODULE__{}

  schema "daily_rollups" do
    field :rollup_date, :date
    field :dimension_kind, :string
    field :pool_id, :binary_id
    field :api_key_id, :binary_id
    field :pool_upstream_assignment_id, :binary_id
    field :upstream_identity_id, :binary_id
    field :model_id, :binary_id
    field :request_count, :integer
    field :admitted_request_count, :integer
    field :success_count, :integer
    field :failure_count, :integer
    field :retry_count, :integer
    field :input_tokens, :integer
    field :cached_input_tokens, :integer
    field :output_tokens, :integer
    field :reasoning_tokens, :integer
    field :total_tokens, :integer
    field :estimated_cost_micros, :decimal
    field :settled_cost_micros, :decimal
    field :rounded_settled_cost_micros, :decimal
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
