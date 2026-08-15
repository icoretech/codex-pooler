defmodule CodexPooler.Accounting.DailyRollupCoverage do
  @moduledoc false
  use CodexPooler.Schema

  @contract_version 2

  @primary_key {:rollup_date, :date, autogenerate: false}
  @type t :: %__MODULE__{}

  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  schema "daily_rollup_coverages" do
    field :contract_version, :integer
    field :completed_at, :utc_datetime_usec
    field :mutation_version, :integer
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
