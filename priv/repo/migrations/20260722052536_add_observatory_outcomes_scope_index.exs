defmodule CodexPooler.Repo.Migrations.AddObservatoryOutcomesScopeIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS requests_api_key_pool_admitted_id_idx")

    execute("""
    CREATE INDEX CONCURRENTLY requests_api_key_pool_admitted_id_idx
    ON requests (api_key_id, pool_id, admitted_at DESC, id DESC)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS requests_api_key_pool_admitted_id_idx")
  end
end
