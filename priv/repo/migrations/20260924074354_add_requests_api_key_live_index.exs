defmodule CodexPooler.Repo.Migrations.AddRequestsApiKeyLiveIndex do
  use Ecto.Migration

  alias CodexPooler.Release.MigrationLockBudget

  # The `max_active_requests` admission check counts the key's live requests
  # (`LedgerReads.outstanding_reservation_count/1`, findings#206 row 206-461).
  # The partial index holds only requests still `accepted` or `in_progress`, so
  # the check reads the key's open requests whatever the planner statistics say;
  # without it, missing or empty statistics send the query through
  # `requests_api_key_*` and the key's whole request history. Its predicate is
  # the query's own status condition word for word, so no other query can pick
  # it. `status` and `api_key_id` are already indexed, so it costs no HOT
  # update; a finished request leaves it. Built CONCURRENTLY while the previous
  # release serves traffic; a build a previous run left INVALID is dropped and
  # rebuilt.

  @disable_ddl_transaction true

  @index %{
    name: "requests_api_key_live_idx",
    create: """
    CREATE INDEX CONCURRENTLY requests_api_key_live_idx
    ON public.requests (api_key_id)
    WHERE status IN ('accepted', 'in_progress')
    """,
    definition: "CREATE INDEX requests_api_key_live_idx ON public.requests USING btree (api_key_id) WHERE (status = ANY (ARRAY['accepted'::text, 'in_progress'::text]))"
  }

  def change do
    execute(
      fn -> with_lock_budget(fn -> converge_index(@index) end) end,
      fn -> with_lock_budget(fn -> drop_index(@index) end) end
    )
  end

  defp converge_index(%{name: name, create: create, definition: definition} = index) do
    case index_state(name) do
      [[true, true, ^definition]] ->
        :ok

      [] ->
        repo().query!(create, [], log: false, timeout: :infinity)
        [[true, true, ^definition]] = index_state(name)
        :ok

      [[_valid, _ready, ^definition]] ->
        drop_index(index)
        converge_index(index)

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

  defp drop_index(%{name: name}) do
    repo().query!("DROP INDEX CONCURRENTLY IF EXISTS public.#{name}", [],
      log: false,
      timeout: :infinity
    )
  end

  # Table and row lock waits keep ten seconds; the concurrent build's wait for older transactions
  # gets the helper's longer budget and names the blocking sessions when it runs out.
  defp with_lock_budget(fun), do: MigrationLockBudget.run(repo(), fun)
end
