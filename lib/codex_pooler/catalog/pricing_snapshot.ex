defmodule CodexPooler.Catalog.PricingSnapshot do
  @moduledoc false
  use CodexPooler.Schema

  @type t :: %__MODULE__{}

  schema "pricing_snapshots" do
    field :model_identifier, :string
    field :price_version, :string
    field :currency_code, :string
    field :billing_unit, :string
    field :input_token_micros, :decimal
    field :cached_input_token_micros, :decimal
    field :output_token_micros, :decimal
    field :reasoning_token_micros, :decimal
    field :request_base_micros, :decimal
    field :effective_at, :utc_datetime_usec
    field :source_url, :string
    field :captured_at, :utc_datetime_usec
    field :config, :map
  end
end
