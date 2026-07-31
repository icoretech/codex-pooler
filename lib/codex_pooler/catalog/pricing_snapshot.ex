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
    field :cache_write_token_micros, :decimal
    field :output_token_micros, :decimal
    field :reasoning_token_micros, :decimal
    field :request_base_micros, :decimal
    field :effective_at, :utc_datetime_usec
    field :source_url, :string
    field :captured_at, :utc_datetime_usec
    field :config, :map
  end

  @fields ~w(
    model_identifier price_version currency_code billing_unit input_token_micros
    cached_input_token_micros cache_write_token_micros output_token_micros
    reasoning_token_micros request_base_micros effective_at source_url captured_at config
  )a

  @spec insert_changeset(map()) :: Ecto.Changeset.t()
  def insert_changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> Ecto.Changeset.cast(attrs, @fields)
    |> Ecto.Changeset.validate_required([
      :model_identifier,
      :price_version,
      :currency_code,
      :billing_unit,
      :effective_at,
      :source_url,
      :captured_at,
      :config
    ])
    |> Ecto.Changeset.unique_constraint(:price_version,
      name: :pricing_snapshots_version_uq
    )
  end
end
