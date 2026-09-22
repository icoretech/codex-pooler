defmodule CodexPooler.Repo.Migrations.ScopeCodexSessionKeyPerApiKey do
  use Ecto.Migration

  # A Codex session is scoped to `(pool_id, api_key_id, session_key)`. The
  # uniqueness that backs the session start was `(pool_id, lower(session_key))`,
  # so two API keys of one Pool that send the same window or session header had
  # to share a row: a plain transport re-owned the other key's session and owner
  # forwarding refused the second key until the first key's lease lapsed. The
  # new index is strictly looser than the old one, so building it cannot fail on
  # existing rows, and no row is rewritten. Rolling back rebuilds the old index,
  # which fails while two keys hold a reconnectable session on the same key.

  @disable_ddl_transaction true

  @new_name "codex_sessions_pool_api_key_session_key_uq"
  @new_create_sql """
  CREATE UNIQUE INDEX CONCURRENTLY codex_sessions_pool_api_key_session_key_uq
  ON public.codex_sessions (pool_id, api_key_id, lower(session_key))
  WHERE (status = ANY (ARRAY['active'::text, 'interrupted'::text]))
  """
  @new_definition "CREATE UNIQUE INDEX codex_sessions_pool_api_key_session_key_uq ON public.codex_sessions USING btree (pool_id, api_key_id, lower(session_key)) WHERE (status = ANY (ARRAY['active'::text, 'interrupted'::text]))"

  @old_name "codex_sessions_pool_session_key_uq"
  @old_create_sql """
  CREATE UNIQUE INDEX CONCURRENTLY codex_sessions_pool_session_key_uq
  ON public.codex_sessions (pool_id, lower(session_key))
  WHERE (status = ANY (ARRAY['active'::text, 'interrupted'::text]))
  """
  @old_definition "CREATE UNIQUE INDEX codex_sessions_pool_session_key_uq ON public.codex_sessions USING btree (pool_id, lower(session_key)) WHERE (status = ANY (ARRAY['active'::text, 'interrupted'::text]))"

  def change do
    execute(
      fn ->
        with_lock_budget(fn ->
          converge_index(@new_name, @new_create_sql, @new_definition)
          drop_index(@old_name)
        end)
      end,
      fn ->
        with_lock_budget(fn ->
          converge_index(@old_name, @old_create_sql, @old_definition)
          drop_index(@new_name)
        end)
      end
    )
  end

  defp converge_index(name, create_sql, definition) do
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
        if state != [], do: drop_index(name)
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
      WHERE c.oid=to_regclass('public.#{name}')
      """,
      [],
      log: false
    ).rows
  end

  defp drop_index(name) do
    repo().query!("DROP INDEX CONCURRENTLY IF EXISTS public.#{name}", [],
      log: false,
      timeout: :infinity
    )
  end

  # Table and row lock waits keep ten seconds; the concurrent build's wait for older transactions
  # gets the helper's longer budget and names the blocking sessions when it runs out.
  defp with_lock_budget(fun), do: CodexPooler.Release.MigrationLockBudget.run(repo(), fun)
end
