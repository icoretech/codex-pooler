defmodule CodexPooler.Repo.Migrations.AddLedgerEntriesApiKeyRecordedOccurredIndex do
  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX ledger_entries_api_key_recorded_occurred_idx
    ON public.ledger_entries USING btree (api_key_id, occurred_at DESC)
    WHERE amount_status = 'recorded'
    """)
  end

  def down do
    execute("""
    DROP INDEX IF EXISTS public.ledger_entries_api_key_recorded_occurred_idx
    """)
  end
end
