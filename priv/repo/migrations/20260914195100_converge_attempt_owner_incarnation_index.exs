defmodule CodexPooler.Repo.Migrations.ConvergeAttemptOwnerIncarnationIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @definition "CREATE INDEX attempts_open_owner_incarnation_idx ON public.attempts USING btree (owner_instance_id, owner_instance_boot_id, started_at) WHERE ((status = ANY (ARRAY['queued'::text, 'in_progress'::text])) AND (owner_instance_boot_id IS NOT NULL))"

  def up do
    with_lock_budget(fn ->
      case repo().query!(
             """
             SELECT i.indisvalid,i.indisready,pg_get_indexdef(c.oid)
             FROM pg_class c LEFT JOIN pg_index i ON i.indexrelid=c.oid
             WHERE c.oid = to_regclass('public.attempts_open_owner_incarnation_idx')
             """,
             [],
             log: false
           ).rows do
        [[true, true, @definition]] ->
          :ok

        state
        when state in [
               [],
               [[false, false, @definition]],
               [[false, true, @definition]],
               [[true, false, @definition]]
             ] ->
          drop_invalid_index(state)

          repo().query!(
            """
            CREATE INDEX CONCURRENTLY attempts_open_owner_incarnation_idx
            ON public.attempts (owner_instance_id, owner_instance_boot_id, started_at)
            WHERE status IN ('queued', 'in_progress') AND owner_instance_boot_id IS NOT NULL
            """,
            [],
            log: false,
            timeout: :infinity
          )

        _ ->
          raise "conflicting index: attempts_open_owner_incarnation_idx"
      end

      [[true, true, @definition]] =
        repo().query!(
          "SELECT indisvalid,indisready,pg_get_indexdef(indexrelid) FROM pg_index WHERE indexrelid='public.attempts_open_owner_incarnation_idx'::regclass",
          [],
          log: false
        ).rows

      # A database stopped between the two historical ownership migrations may
      # still carry the superseded index from an earlier prerelease.
      case repo().query!(
             "SELECT pg_get_indexdef(to_regclass('public.attempts_open_owner_instance_idx'))",
             [],
             log: false
           ).rows do
        [[nil]] ->
          :ok

        [
          [
            "CREATE INDEX attempts_open_owner_instance_idx ON public.attempts USING btree (owner_instance_id, started_at) WHERE ((status = ANY (ARRAY['queued'::text, 'in_progress'::text])) AND (owner_instance_id IS NOT NULL))"
          ]
        ] ->
          repo().query!("DROP INDEX CONCURRENTLY public.attempts_open_owner_instance_idx", [],
            log: false,
            timeout: :infinity
          )

        _ ->
          raise "conflicting index: attempts_open_owner_instance_idx"
      end
    end)
  end

  def down do
    # This index may predate this migration on an already-upgraded database.
    # Its owning column migration removes it during a complete rollback.
    :ok
  end

  defp drop_invalid_index([]), do: :ok

  defp drop_invalid_index(_state) do
    repo().query!("DROP INDEX CONCURRENTLY public.attempts_open_owner_incarnation_idx", [],
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
