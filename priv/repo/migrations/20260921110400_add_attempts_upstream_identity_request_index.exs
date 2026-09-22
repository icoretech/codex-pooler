defmodule CodexPooler.Repo.Migrations.AddAttemptsUpstreamIdentityRequestIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  @name "attempts_upstream_identity_request_idx"
  @create_sql """
  CREATE INDEX CONCURRENTLY attempts_upstream_identity_request_idx
  ON public.attempts (upstream_identity_id, request_id)
  """
  @definition "CREATE INDEX attempts_upstream_identity_request_idx ON public.attempts USING btree (upstream_identity_id, request_id)"

  def change do
    execute(fn -> with_lock_budget(&converge_index/0) end, fn ->
      with_lock_budget(&drop_index/0)
    end)
  end

  defp converge_index do
    case index_state() do
      [[true, true, @definition]] ->
        :ok

      state
      when state in [
             [],
             [[false, false, @definition]],
             [[false, true, @definition]],
             [[true, false, @definition]]
           ] ->
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
    repo().query!("DROP INDEX CONCURRENTLY IF EXISTS public.#{@name}", [],
      log: false,
      timeout: :infinity
    )
  end

  # Table and row lock waits keep ten seconds; the concurrent build's wait for older transactions
  # gets the helper's longer budget and names the blocking sessions when it runs out.
  defp with_lock_budget(fun), do: CodexPooler.Release.MigrationLockBudget.run(repo(), fun)
end
