defmodule CodexPooler.Accounting.LedgerEntry do
  @moduledoc false
  use CodexPooler.Schema

  @type t :: %__MODULE__{}

  schema "ledger_entries" do
    field :request_id, :binary_id
    field :attempt_id, :binary_id
    field :pricing_snapshot_id, :binary_id
    field :pool_id, :binary_id
    field :api_key_id, :binary_id
    field :pool_upstream_assignment_id, :binary_id
    field :upstream_identity_id, :binary_id
    field :model_id, :binary_id
    field :entry_kind, :string
    field :amount_status, :string
    field :usage_status, :string
    field :transport, :string
    field :currency_code, :string
    field :input_tokens, :integer
    field :cached_input_tokens, :integer
    field :cache_write_tokens, :integer
    field :output_tokens, :integer
    field :reasoning_tokens, :integer
    field :total_tokens, :integer
    field :request_count, :integer
    field :estimated_cost_micros, :decimal
    field :settled_cost_micros, :decimal
    field :correction_of_entry_id, :binary_id
    field :source_event_id, :string
    field :occurred_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :details, :map
  end
end
