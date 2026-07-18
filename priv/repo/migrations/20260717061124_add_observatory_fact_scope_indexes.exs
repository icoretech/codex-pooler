defmodule CodexPooler.Repo.Migrations.AddObservatoryFactScopeIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY requests_api_key_pool_admitted_idx
    ON requests (api_key_id, pool_id, admitted_at DESC)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY ledger_entries_api_key_pool_settlement_occurred_idx
    ON ledger_entries (api_key_id, pool_id, occurred_at DESC)
    WHERE entry_kind = 'settlement' AND amount_status = 'recorded'
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS ledger_entries_api_key_pool_settlement_occurred_idx
    """)

    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS requests_api_key_pool_admitted_idx
    """)
  end
end
