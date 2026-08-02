defmodule CodexPooler.Accounting.APIKeyUsageBucket do
  @moduledoc false
  use CodexPooler.Schema

  @primary_key false

  schema "api_key_usage_buckets" do
    field :api_key_id, :binary_id, primary_key: true
    field :bucket_started_at, :utc_datetime_usec, primary_key: true
    field :effective_request_count, :integer
    field :effective_total_tokens, :integer
    field :effective_cost_micros, :decimal
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
