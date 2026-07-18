defmodule CodexPooler.Repo.Migrations.AddEstimatedCostToRequestLogFacts do
  use Ecto.Migration

  # The column add is catalog-only, but the backfill rewrites existing rows, so
  # run outside a migration transaction and commit each batch on its own. That
  # keeps locks and bloat bounded on the shared cluster instead of holding one
  # long transaction over the whole table.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @batch_size 5_000

  def up do
    alter table(:request_log_facts) do
      add :latest_estimated_cost_micros, :bigint
    end

    flush()

    backfill(nil)
  end

  def down do
    alter table(:request_log_facts) do
      remove :latest_estimated_cost_micros
    end
  end

  # Denormalize each fact's latest recorded settlement estimated cost, mirroring
  # the ungated live write path (RequestLogFacts.settlement_attrs) and the
  # observatory read, which gates it to non-priced rows. The backfill walks the
  # primary key with a keyset cursor so every row is visited once (a
  # self-limiting IS NULL predicate would re-scan the already-filled prefix each
  # batch), and each batch commits on its own so locks and bloat stay bounded.
  # request_id is carried as text between batches to stay independent of how the
  # driver decodes uuid values.
  defp backfill(after_request_id) do
    %{rows: rows} =
      repo().query!(
        """
        WITH batch AS (
          SELECT request_id
          FROM request_log_facts
          WHERE ($1::text IS NULL OR request_id > $1::text::uuid)
          ORDER BY request_id
          LIMIT #{@batch_size}
        ),
        updated AS (
          UPDATE request_log_facts AS fact
          SET latest_estimated_cost_micros = ROUND(entry.estimated_cost_micros, 0)::bigint
          FROM ledger_entries AS entry, batch
          WHERE fact.request_id = batch.request_id
            AND entry.id = fact.latest_settlement_entry_id
            AND entry.estimated_cost_micros IS NOT NULL
          RETURNING 1
        )
        SELECT request_id::text FROM batch ORDER BY request_id DESC LIMIT 1
        """,
        [after_request_id]
      )

    case rows do
      [] -> :ok
      [[last_request_id]] -> backfill(last_request_id)
    end
  end
end
