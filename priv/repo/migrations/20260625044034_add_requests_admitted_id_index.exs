defmodule CodexPooler.Repo.Migrations.AddRequestsAdmittedIdIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS requests_admitted_id_idx
    ON requests (admitted_at DESC, id DESC)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS requests_admitted_id_idx")
  end
end
