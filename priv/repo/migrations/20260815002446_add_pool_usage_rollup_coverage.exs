defmodule CodexPooler.Repo.Migrations.AddPoolUsageRollupCoverage do
  use Ecto.Migration

  def change do
    alter table(:daily_rollups) do
      add :admitted_request_count, :bigint, null: false, default: 0
      add :rounded_settled_cost_micros, :decimal, precision: 30, scale: 0, null: false, default: 0
    end

    create constraint(:daily_rollups, :daily_rollups_admitted_request_count_check,
             check: "admitted_request_count >= 0"
           )

    create constraint(:daily_rollups, :daily_rollups_rounded_settled_cost_micros_check,
             check: "rounded_settled_cost_micros >= 0"
           )

    create table(:daily_rollup_coverages, primary_key: false) do
      add :rollup_date, :date, primary_key: true, null: false
      add :contract_version, :integer, null: false
      add :completed_at, :utc_datetime_usec, null: false
      timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
    end

    create constraint(:daily_rollup_coverages, :daily_rollup_coverages_contract_version_check,
             check: "contract_version > 0"
           )
  end
end
