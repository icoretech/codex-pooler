defmodule CodexPooler.Repo.Migrations.MakeRequestsPoolRequestedModelIndexPartial do
  use Ecto.Migration

  alias CodexPooler.Release.MigrationLockBudget

  # `requests_pool_requested_model_idx (pool_id, requested_model)` served only the
  # request-log model filter, but as a full index it also competed for every query
  # that filters `requests` by Pool alone. On a small `requests` table the planner
  # chose it for the API-key Observatory aggregate, reading the Pool's whole
  # history instead of the key's window through the (api_key_id, pool_id,
  # admitted_at) index. A partial index whose predicate is the filter's own row
  # condition (no blank model, no endpoint path) can only be used by a query that
  # states that condition, so the model filter keeps its index-backed steps and
  # the Observatory never sees it. Both indexes are built and dropped
  # CONCURRENTLY; a build a previous run left INVALID is dropped and rebuilt.

  @disable_ddl_transaction true

  @partial %{
    name: "requests_pool_listed_model_idx",
    create: """
    CREATE INDEX CONCURRENTLY requests_pool_listed_model_idx
    ON public.requests (pool_id, requested_model)
    WHERE requested_model > '' AND requested_model NOT LIKE '/%'
    """,
    definition: "CREATE INDEX requests_pool_listed_model_idx ON public.requests USING btree (pool_id, requested_model) WHERE ((requested_model > ''::text) AND (requested_model !~~ '/%'::text))"
  }

  @full %{
    name: "requests_pool_requested_model_idx",
    create: """
    CREATE INDEX CONCURRENTLY requests_pool_requested_model_idx
    ON public.requests (pool_id, requested_model)
    """,
    definition: "CREATE INDEX requests_pool_requested_model_idx ON public.requests USING btree (pool_id, requested_model)"
  }

  def change do
    execute(
      fn -> with_lock_budget(fn -> replace_index(@full, @partial) end) end,
      fn -> with_lock_budget(fn -> replace_index(@partial, @full) end) end
    )
  end

  # The replacement is valid before the old index goes, so the model filter
  # always has one index to step through.
  defp replace_index(old, new) do
    converge_index(new)
    drop_index(old)
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
