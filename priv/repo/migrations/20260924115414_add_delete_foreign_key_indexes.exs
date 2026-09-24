defmodule CodexPooler.Repo.Migrations.AddDeleteForeignKeyIndexes do
  use Ecto.Migration

  alias CodexPooler.Release.MigrationLockBudget

  # Deleting a Pool, an upstream assignment, an API key, an upstream identity or a Codex session
  # runs one foreign key query per deleted parent row and per foreign key that points at it (a
  # cascading DELETE, a SET NULL UPDATE or a NO ACTION check). These foreign keys had no index with
  # the key column first, so each such query read its whole child table: an archived Pool with two
  # assignments and two keys spent ten seconds reading the ledger twice for
  # `ledger_entries.pool_upstream_assignment_id` and ran past the 15 s query timeout on a
  # production-sized database (findings#206 row 206-550). One single-column index per foreign key
  # turns each of those queries into an index lookup. A nullable key column indexes only its
  # non-null rows, which are all a foreign key query can match. Built CONCURRENTLY while the
  # previous release serves traffic, one lock budget per index; a build a previous run left
  # INVALID is dropped and rebuilt.

  @disable_ddl_transaction true

  # {table, column, nullable?}
  @foreign_keys [
    {"api_key_policy_bindings", "api_key_id", false},
    {"audit_events", "request_id", true},
    {"bridge_affinities", "api_key_id", false},
    {"bridge_affinities", "pool_id", false},
    {"bridge_affinities", "upstream_identity_id", true},
    {"bridge_demotions", "api_key_id", false},
    {"bridge_demotions", "last_request_id", true},
    {"bridge_demotions", "pool_upstream_assignment_id", false},
    {"bridge_demotions", "upstream_identity_id", true},
    {"bridge_owner_leases", "api_key_id", false},
    {"bridge_owner_leases", "codex_session_id", false},
    {"bridge_owner_leases", "pool_id", false},
    {"bridge_owner_leases", "pool_upstream_assignment_id", true},
    {"bridge_session_aliases", "api_key_id", false},
    {"bridge_session_aliases", "pool_id", false},
    {"codex_files", "api_key_id", false},
    {"codex_files", "request_id", true},
    {"codex_sessions", "api_key_id", true},
    {"codex_sessions", "pool_upstream_assignment_id", true},
    {"daily_rollups", "api_key_id", true},
    {"daily_rollups", "pool_id", true},
    {"daily_rollups", "pool_upstream_assignment_id", true},
    {"daily_rollups", "upstream_identity_id", true},
    {"encrypted_secrets", "upstream_identity_id", false},
    {"gateway_idempotency_keys", "api_key_id", false},
    {"gateway_idempotency_keys", "codex_file_id", true},
    {"gateway_idempotency_keys", "pool_id", false},
    {"gateway_idempotency_keys", "request_id", true},
    {"invite_acceptances", "pool_upstream_assignment_id", true},
    {"invite_acceptances", "upstream_identity_id", false},
    {"ledger_entries", "pool_upstream_assignment_id", true},
    {"ledger_entries", "upstream_identity_id", true},
    {"models", "last_sync_run_id", true},
    {"operator_pool_assignments", "pool_id", false},
    {"request_log_facts", "latest_pool_upstream_assignment_id", true},
    {"request_replay_entitlements", "api_key_id", false},
    {"request_replay_entitlements", "pool_id", false},
    {"routing_circuit_states", "api_key_id", true},
    {"routing_circuit_states", "upstream_identity_id", true},
    {"upstream_oauth_flows", "result_upstream_identity_id", true}
  ]

  def change do
    execute(
      fn -> Enum.each(indexes(), fn index -> with_lock_budget(fn -> converge_index(index) end) end) end,
      fn -> indexes() |> Enum.reverse() |> Enum.each(fn index -> with_lock_budget(fn -> drop_index(index) end) end) end
    )
  end

  defp indexes, do: Enum.map(@foreign_keys, &index/1)

  defp index({table, column, nullable?}) do
    name = "#{table}_#{column}_fk_idx"
    predicate = if nullable?, do: " WHERE #{column} IS NOT NULL", else: ""
    definition_predicate = if nullable?, do: " WHERE (#{column} IS NOT NULL)", else: ""

    %{
      name: name,
      create: "CREATE INDEX CONCURRENTLY #{name} ON public.#{table} (#{column})#{predicate}",
      definition: "CREATE INDEX #{name} ON public.#{table} USING btree (#{column})#{definition_predicate}"
    }
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

  # Table and row lock waits keep ten seconds; each concurrent build's wait for older transactions
  # gets the helper's longer budget and names the blocking sessions when it runs out.
  defp with_lock_budget(fun), do: MigrationLockBudget.run(repo(), fun)
end
