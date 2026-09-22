defmodule CodexPooler.Repo.Migrations.AddAccountingQueryIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true

  @indexes [
    {"ledger_entries_api_key_known_settlement_occurred_idx",
     """
     CREATE INDEX CONCURRENTLY ledger_entries_api_key_known_settlement_occurred_idx
     ON public.ledger_entries (api_key_id, occurred_at)
     WHERE entry_kind = 'settlement' AND usage_status = 'usage_known'
     """, "CREATE INDEX ledger_entries_api_key_known_settlement_occurred_idx ON public.ledger_entries USING btree (api_key_id, occurred_at) WHERE ((entry_kind = 'settlement'::text) AND (usage_status = 'usage_known'::text))"},
    {"attempts_open_started_idx",
     """
     CREATE INDEX CONCURRENTLY attempts_open_started_idx
     ON public.attempts (started_at, id)
     WHERE status IN ('queued', 'in_progress')
     """, "CREATE INDEX attempts_open_started_idx ON public.attempts USING btree (started_at, id) WHERE (status = ANY (ARRAY['queued'::text, 'in_progress'::text]))"}
  ]

  def up do
    with_lock_budget(fn -> Enum.each(@indexes, &converge_index/1) end)
  end

  def down do
    with_lock_budget(fn ->
      Enum.each(@indexes, fn {name, _create_sql, _definition} ->
        repo().query!("DROP INDEX CONCURRENTLY IF EXISTS public.#{name}", [],
          log: false,
          timeout: :infinity
        )
      end)
    end)
  end

  defp converge_index({name, create_sql, definition}) do
    case index_state(name) do
      [[true, true, ^definition]] ->
        :ok

      state
      when state in [
             [],
             [[false, false, definition]],
             [[false, true, definition]],
             [[true, false, definition]]
           ] ->
        drop_unusable_index(name, state)
        repo().query!(create_sql, [], log: false, timeout: :infinity)
        [[true, true, ^definition]] = index_state(name)
        :ok

      _conflicting ->
        raise "conflicting index: #{name}"
    end
  end

  defp index_state(name) do
    repo().query!(
      """
      SELECT i.indisvalid,i.indisready,pg_get_indexdef(c.oid)
      FROM pg_class c LEFT JOIN pg_index i ON i.indexrelid=c.oid
      WHERE c.oid = to_regclass('public.#{name}')
      """,
      [],
      log: false
    ).rows
  end

  defp drop_unusable_index(_name, []), do: :ok

  defp drop_unusable_index(name, _state) do
    repo().query!("DROP INDEX CONCURRENTLY public.#{name}", [],
      log: false,
      timeout: :infinity
    )
  end

  # Table and row lock waits keep ten seconds; the concurrent build's wait for older transactions
  # gets the helper's longer budget and names the blocking sessions when it runs out.
  defp with_lock_budget(fun) do
    execute(fn -> CodexPooler.Release.MigrationLockBudget.run(repo(), fun) end)
  end
end
