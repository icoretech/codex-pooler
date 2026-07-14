defmodule CodexPooler.Repo.Migrations.ScopeDailyApiKeyRollupsByPool do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # A failed CREATE INDEX CONCURRENTLY can leave an invalid index behind.
    # Remove the staging name first so a migration retry rebuilds it instead
    # of letting IF NOT EXISTS silently accept an unusable index.
    execute("DROP INDEX CONCURRENTLY IF EXISTS public.daily_rollups_api_key_pool_uq")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY daily_rollups_api_key_pool_uq
    ON public.daily_rollups USING btree (rollup_date, pool_id, api_key_id)
    WHERE dimension_kind = 'api_key'::text
    """)

    execute("DROP INDEX CONCURRENTLY IF EXISTS public.daily_rollups_api_key_uq")

    execute("ALTER INDEX public.daily_rollups_api_key_pool_uq RENAME TO daily_rollups_api_key_uq")
  end

  def down do
    raise Ecto.MigrationError,
          "daily API-key rollups cannot be collapsed across pools without losing attribution"
  end
end
