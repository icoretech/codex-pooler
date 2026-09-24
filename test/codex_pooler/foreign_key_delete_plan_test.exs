defmodule CodexPooler.ForeignKeyDeletePlanTest do
  # Deleting a Pool, an upstream assignment, an API key, an upstream identity or a Codex session
  # runs one referential-integrity query per deleted parent row and per foreign key that points at
  # it: a cascading DELETE, a SET NULL UPDATE or a NO ACTION existence check on the child table.
  # Without an index whose leading column is the foreign key column, each of those queries reads
  # the whole child table, and a Pool delete on a production-sized database ran past its 15 s
  # timeout reading the ledger once per assignment (findings#206 row 206-550). This test follows
  # every cascade from those parents through the catalog and plans each query the way PostgreSQL's
  # foreign key triggers issue it, so a foreign key added later without an index fails here.
  use CodexPooler.DataCase, async: true

  alias CodexPooler.Repo

  @delete_roots ~w(pools pool_upstream_assignments api_keys upstream_identities codex_sessions)

  # The foreign keys the production delete was measured spending its time in; the closure must keep
  # finding them, so the test cannot pass by following nothing.
  @measured_culprits ~w(
    ledger_entries_pool_upstream_assignment_id_fkey
    bridge_session_aliases_api_key_id_fkey
    request_log_facts_latest_pool_upstream_assignment_id_fkey
    codex_sessions_pool_upstream_assignment_id_fkey
    codex_sessions_api_key_id_fkey
    bridge_owner_leases_pool_upstream_assignment_id_fkey
    bridge_owner_leases_api_key_id_fkey
  )

  test "every foreign key a Pool, assignment, key, identity or session delete reaches is looked up through an index" do
    foreign_keys = Enum.flat_map(@delete_roots, &delete_closure_foreign_keys/1) |> Enum.uniq_by(& &1.name)
    names = MapSet.new(foreign_keys, & &1.name)

    for culprit <- @measured_culprits, do: assert(culprit in names, "#{culprit} is no longer reached by the delete closure")

    unindexed = Enum.reject(foreign_keys, &index_lookup?/1)

    assert unindexed == [],
           "foreign keys reached by a delete read their whole child table:\n" <>
             Enum.map_join(unindexed, "\n", &describe/1)
  end

  test "the lookup check recognises a foreign key without an index" do
    # A temporary table cannot reference a permanent one; the planned query needs only the column.
    Repo.query!("CREATE TEMPORARY TABLE fk_plan_probe (id uuid PRIMARY KEY, pool_id uuid) ON COMMIT DROP")

    probe = %{name: "fk_plan_probe_pool_id_fkey", child: "fk_plan_probe", parent: "pools", columns: ["pool_id"], action: "c"}

    refute index_lookup?(probe)
    Repo.query!("CREATE INDEX ON fk_plan_probe (pool_id)")
    assert index_lookup?(probe)
  end

  # Every table whose rows a delete of `root` removes by cascade, then every foreign key that points
  # at one of those tables, whatever its ON DELETE action.
  defp delete_closure_foreign_keys(root) do
    Repo.query!(
      """
      WITH RECURSIVE deleted(table_oid) AS (
        SELECT to_regclass($1)::oid
        UNION
        SELECT c.conrelid
        FROM pg_constraint c
        JOIN deleted d ON c.confrelid = d.table_oid
        WHERE c.contype = 'f' AND c.confdeltype = 'c'
      )
      SELECT c.conname,
             child.relname,
             parent.relname,
             ARRAY(SELECT a.attname::text
                   FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, position)
                   JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
                   ORDER BY k.position),
             c.confdeltype::text
      FROM pg_constraint c
      JOIN pg_class child ON child.oid = c.conrelid
      JOIN pg_class parent ON parent.oid = c.confrelid
      WHERE c.contype = 'f' AND c.confrelid IN (SELECT table_oid FROM deleted)
      ORDER BY c.conname
      """,
      [root]
    ).rows
    |> Enum.map(fn [name, child, parent, columns, action] ->
      %{name: name, child: child, parent: parent, columns: columns, action: action}
    end)
  end

  # Plans the query PostgreSQL's foreign key trigger runs for one deleted parent row, as a generic
  # plan with sequential scans priced out: a plan that still reads the child table sequentially
  # has no index to use.
  defp index_lookup?(%{child: child} = foreign_key) do
    Repo.query!("SET LOCAL enable_seqscan = off")

    %{rows: [[document]]} = Repo.query!("EXPLAIN (GENERIC_PLAN, FORMAT JSON) " <> trigger_query(foreign_key), [], query_type: :text)

    [%{"Plan" => plan}] = CodexPooler.JSON.decode!(document)
    scans = plan |> plan_nodes() |> Enum.filter(&(&1["Relation Name"] == child and &1["Node Type"] != "ModifyTable"))

    scans != [] and Enum.all?(scans, &(&1["Node Type"] in ["Index Scan", "Index Only Scan", "Bitmap Heap Scan"]))
  after
    Repo.query!("SET LOCAL enable_seqscan = on")
  end

  defp trigger_query(%{child: child, columns: columns, action: action}) do
    where =
      columns
      |> Enum.with_index(1)
      |> Enum.map_join(" AND ", fn {column, position} -> "$#{position} = #{quote_name(column)}" end)

    case action do
      "c" -> "DELETE FROM ONLY #{quote_name(child)} WHERE #{where}"
      "n" -> "UPDATE ONLY #{quote_name(child)} SET #{Enum.map_join(columns, ", ", &"#{quote_name(&1)} = NULL")} WHERE #{where}"
      "d" -> "UPDATE ONLY #{quote_name(child)} SET #{Enum.map_join(columns, ", ", &"#{quote_name(&1)} = DEFAULT")} WHERE #{where}"
      _no_action_or_restrict -> "SELECT 1 FROM ONLY #{quote_name(child)} x WHERE #{where} FOR KEY SHARE OF x"
    end
  end

  defp plan_nodes(node), do: [node | Enum.flat_map(Map.get(node, "Plans", []), &plan_nodes/1)]

  defp quote_name(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")

  defp describe(%{name: name, child: child, parent: parent, columns: columns, action: action}) do
    "  #{child}(#{Enum.join(columns, ", ")}) -> #{parent} ON DELETE #{action_name(action)} (#{name})"
  end

  defp action_name("c"), do: "CASCADE"
  defp action_name("n"), do: "SET NULL"
  defp action_name("d"), do: "SET DEFAULT"
  defp action_name("r"), do: "RESTRICT"
  defp action_name("a"), do: "NO ACTION"
end
