defmodule CodexPooler.Repo.Migrations.AddCacheWriteRateToPricingSnapshots do
  use Ecto.Migration

  def up do
    alter table(:pricing_snapshots) do
      add :cache_write_token_micros, :decimal
    end

    create constraint(:pricing_snapshots, :pricing_snapshots_cache_write_token_micros_check,
             check: "cache_write_token_micros IS NULL OR cache_write_token_micros >= 0"
           )

    drop index(:pricing_snapshots, [], name: :pricing_snapshots_version_uq)

    execute("""
    CREATE UNIQUE INDEX pricing_snapshots_version_uq
    ON pricing_snapshots (
      lower(model_identifier),
      price_version,
      COALESCE(config ->> 'service_tier', ''),
      COALESCE(config ->> 'price_bucket', ''),
      COALESCE(config ->> 'importer_format_revision', '')
    )
    """)
  end

  def down do
    drop index(:pricing_snapshots, [], name: :pricing_snapshots_version_uq)

    execute("""
    CREATE UNIQUE INDEX pricing_snapshots_version_uq
    ON pricing_snapshots (
      lower(model_identifier),
      price_version,
      COALESCE(config ->> 'service_tier', ''),
      COALESCE(config ->> 'price_bucket', '')
    )
    """)

    alter table(:pricing_snapshots) do
      remove :cache_write_token_micros
    end
  end
end
