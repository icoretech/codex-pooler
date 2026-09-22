defmodule CodexPooler.Repo.Migrations.DropCodexSessionConversationKeyIndex do
  use Ecto.Migration

  # `codex_sessions.conversation_key` has never been set by any runtime path:
  # no caller supplies the option, so every row the application wrote carries
  # NULL and the partial unique index below is empty. Its scope was the whole
  # Pool, while a Codex session is scoped to `(pool_id, api_key_id,
  # session_key)`, so the first path that set it would have made two API keys
  # of one Pool collide. The index goes now, together with the writer. The
  # column and its CHECK stay: `CodexSession` still lists the column, and a
  # release that selects it may serve against this database during a rollout,
  # so dropping it waits for a release whose schema no longer names it.
  # Rolling back rebuilds the index, which cannot fail on rows the application
  # wrote.

  @disable_ddl_transaction true

  @name "codex_sessions_pool_conversation_key_uq"
  @create_sql """
  CREATE UNIQUE INDEX CONCURRENTLY codex_sessions_pool_conversation_key_uq
  ON public.codex_sessions (pool_id, lower(conversation_key))
  WHERE ((conversation_key IS NOT NULL) AND (status = ANY (ARRAY['active'::text, 'interrupted'::text])))
  """
  @definition "CREATE UNIQUE INDEX codex_sessions_pool_conversation_key_uq ON public.codex_sessions USING btree (pool_id, lower(conversation_key)) WHERE ((conversation_key IS NOT NULL) AND (status = ANY (ARRAY['active'::text, 'interrupted'::text])))"

  def up do
    with_lock_budget(fn -> drop_index() end)
  end

  def down do
    with_lock_budget(fn -> converge_index() end)
  end

  defp converge_index do
    case index_state() do
      [[true, true, @definition]] ->
        :ok

      state when state in [[], [[false, false, @definition]], [[false, true, @definition]], [[true, false, @definition]]] ->
        if state != [], do: drop_index()
        repo().query!(@create_sql, [], log: false, timeout: :infinity)
        [[true, true, @definition]] = index_state()
        :ok

      _conflicting ->
        raise "conflicting index: #{@name}"
    end
  end

  defp index_state do
    repo().query!(
      """
      SELECT i.indisvalid,i.indisready,pg_get_indexdef(c.oid)
      FROM pg_class c LEFT JOIN pg_index i ON i.indexrelid=c.oid
      WHERE c.oid=to_regclass('public.#{@name}')
      """,
      [],
      log: false
    ).rows
  end

  defp drop_index do
    repo().query!("DROP INDEX CONCURRENTLY IF EXISTS public.#{@name}", [], log: false, timeout: :infinity)
  end

  # Table and row lock waits keep ten seconds; the concurrent build's wait for older transactions
  # gets the helper's longer budget and names the blocking sessions when it runs out.
  defp with_lock_budget(fun), do: CodexPooler.Release.MigrationLockBudget.run(repo(), fun)
end
