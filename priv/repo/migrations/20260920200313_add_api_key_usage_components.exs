defmodule CodexPooler.Repo.Migrations.AddApiKeyUsageComponents do
  use Ecto.Migration

  @disable_ddl_transaction true

  @indexes [
    {"ledger_entries_reservation_key_occurred_idx", "(api_key_id, occurred_at) INCLUDE (request_id, total_tokens) WHERE ((entry_kind = 'reservation'::text) AND (amount_status = 'recorded'::text))"},
    {"ledger_entries_terminal_request_idx", "(request_id) WHERE (entry_kind = ANY (ARRAY['release'::text, 'settlement'::text]))"},
    {"ledger_entries_key_occurred_idx", "(api_key_id, occurred_at) INCLUDE (request_id)"}
  ]

  def up do
    online(fn ->
      # Only metadata DDL is protected by global locks. No history scan or index
      # build runs in this transaction, and competing writers cause fast failure.
      {:ok, _} =
        repo().transaction(fn ->
          query("LOCK TABLE public.ledger_entries IN SHARE ROW EXCLUSIVE MODE NOWAIT")
          query("LOCK TABLE public.api_key_usage_buckets IN ACCESS EXCLUSIVE MODE NOWAIT")

          query("""
          ALTER TABLE public.api_key_usage_buckets
            ADD COLUMN IF NOT EXISTS known_total_tokens bigint NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS provisional_total_tokens bigint NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS admission_count bigint NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS known_cost_micros numeric(30,9) NOT NULL DEFAULT 0
          """)

          query(events_function())
          query(rebuild_function())
        end)

      Enum.each(@indexes, &converge_index/1)

      {:ok, _} =
        repo().transaction(fn ->
          # Let in-flight legacy writers drain within the five-second budget.
          # No bucket lock is held while acquiring this publication lock.
          query("LOCK TABLE public.ledger_entries IN SHARE ROW EXCLUSIVE MODE")

          query("DROP TRIGGER IF EXISTS ledger_entries_sync_api_key_usage_buckets ON public.ledger_entries")

          for operation <- [:insert, :update, :delete] do
            query(sync_function(operation))

            query("DROP TRIGGER IF EXISTS ledger_entries_usage_components_#{operation} ON public.ledger_entries")

            query(sync_trigger(operation))
          end
        end)

      ensure_event_buckets(nil)
      backfill(nil)
    end)
  end

  def down do
    online(fn ->
      {:ok, _} =
        repo().transaction(fn ->
          query("LOCK TABLE public.ledger_entries IN SHARE ROW EXCLUSIVE MODE NOWAIT")

          for operation <- [:insert, :update, :delete] do
            query("DROP TRIGGER IF EXISTS ledger_entries_usage_components_#{operation} ON public.ledger_entries")

            query("DROP FUNCTION IF EXISTS public.sync_api_key_usage_components_#{operation}()")
          end

          query("DROP TRIGGER IF EXISTS ledger_entries_sync_api_key_usage_buckets ON public.ledger_entries")

          query("CREATE TRIGGER ledger_entries_sync_api_key_usage_buckets AFTER INSERT OR UPDATE OR DELETE ON public.ledger_entries FOR EACH ROW EXECUTE FUNCTION public.sync_api_key_usage_bucket_from_ledger_entry()")
        end)

      Enum.each(@indexes, fn {name, _} ->
        query("DROP INDEX CONCURRENTLY IF EXISTS public.#{name}")
      end)

      query("DROP FUNCTION IF EXISTS public.rebuild_api_key_usage_components()")
      query("DROP FUNCTION IF EXISTS public.api_key_usage_events(public.ledger_entries[])")

      query("ALTER TABLE public.api_key_usage_buckets DROP COLUMN IF EXISTS known_total_tokens, DROP COLUMN IF EXISTS provisional_total_tokens, DROP COLUMN IF EXISTS admission_count, DROP COLUMN IF EXISTS known_cost_micros")
    end)
  end

  # Table and row lock waits keep five seconds; the concurrent index builds' wait for older
  # transactions gets the helper's longer budget and names the blocking sessions when it runs out.
  defp online(fun) do
    execute(fn -> CodexPooler.Release.MigrationLockBudget.run(repo(), fun, lock_wait_ms: 5_000) end)
  end

  defp query(sql, params \\ []), do: repo().query!(sql, params, log: false, timeout: :infinity)

  defp converge_index({name, definition}) do
    expected = "CREATE INDEX #{name} ON public.ledger_entries USING btree #{definition}"

    case query(
           "SELECT i.indisvalid,i.indisready,pg_get_indexdef(c.oid) FROM pg_class c LEFT JOIN pg_index i ON i.indexrelid=c.oid WHERE c.oid=to_regclass($1)",
           ["public." <> name]
         ).rows do
      [[true, true, ^expected]] ->
        :ok

      state
      when state == [] or state == [[false, false, expected]] or
             state == [[false, true, expected]] or state == [[true, false, expected]] ->
        if state != [], do: query("DROP INDEX CONCURRENTLY public.#{name}")
        query("CREATE INDEX CONCURRENTLY #{name} ON public.ledger_entries #{definition}")

      _ ->
        raise "conflicting index: #{name}"
    end
  end

  defp backfill(cursor) do
    {where, params} =
      case cursor do
        nil -> {"", []}
        [key, minute] -> {"WHERE (api_key_id,bucket_started_at) > ($1,$2)", [key, minute]}
      end

    rows =
      query(
        "SELECT api_key_id,bucket_started_at FROM public.api_key_usage_buckets #{where} ORDER BY api_key_id,bucket_started_at LIMIT 100",
        params
      ).rows

    if rows != [] do
      keys = Enum.map(rows, &hd/1)
      minutes = Enum.map(rows, &List.last/1)

      {:ok, _} =
        repo().transaction(fn ->
          query("SET LOCAL statement_timeout='30s'")

          query(
            "SELECT b.api_key_id FROM public.api_key_usage_buckets b JOIN unnest($1::uuid[],$2::timestamp[]) t(k,m) ON b.api_key_id=t.k AND b.bucket_started_at=t.m ORDER BY b.api_key_id,b.bucket_started_at FOR UPDATE OF b",
            [keys, minutes]
          )

          # The second statement gets a fresh READ COMMITTED snapshot after row
          # locks: committed writers are included; waiting writers add their delta
          # after this batch commits. Never combine locking and aggregation.
          # Keep both lookups parameterized: OFFSET 0 fences target-minute
          # flattening, and the lateral aggregate fences request-history joins.
          # A merge join here otherwise rescans retained history for every batch.
          query(
            """
            /* usage_component_backfill */
            WITH targets AS MATERIALIZED (SELECT * FROM unnest($1::uuid[],$2::timestamp[]) t(k,m)),
            requests AS (SELECT DISTINCT e.request_id FROM targets t
              CROSS JOIN LATERAL (SELECT request_id FROM public.ledger_entries
                WHERE api_key_id=t.k AND occurred_at>=t.m AND occurred_at<t.m+interval '1 minute'
                OFFSET 0) e),
            events AS (SELECT v.* FROM requests r
              CROSS JOIN LATERAL (SELECT array_agg(e) entries FROM public.ledger_entries e
                WHERE e.request_id=r.request_id) h
              CROSS JOIN LATERAL public.api_key_usage_events(h.entries) v),
            totals AS (SELECT t.k,t.m,coalesce(sum(v.known_total_tokens),0) known,
              coalesce(sum(v.provisional_total_tokens),0) provisional,
              coalesce(sum(v.admission_count),0) admissions,coalesce(sum(v.known_cost_micros),0) cost
              FROM targets t LEFT JOIN events v ON v.api_key_id=t.k AND date_trunc('minute',v.occurred_at)=t.m GROUP BY t.k,t.m)
            UPDATE public.api_key_usage_buckets b SET known_total_tokens=t.known,
              provisional_total_tokens=t.provisional,admission_count=t.admissions,known_cost_micros=t.cost
            FROM totals t WHERE b.api_key_id=t.k AND b.bucket_started_at=t.m
            """,
            [keys, minutes]
          )
        end)

      backfill(List.last(rows))
    end
  end

  defp ensure_event_buckets(cursor) do
    {where, params} =
      if is_nil(cursor), do: {"", []}, else: {"WHERE request_id > $1", [cursor]}

    requests =
      query(
        "SELECT DISTINCT request_id FROM public.ledger_entries #{where} ORDER BY request_id LIMIT 100",
        params
      ).rows
      |> Enum.map(&hd/1)

    if requests != [] do
      {:ok, _} =
        repo().transaction(fn ->
          query("SET LOCAL statement_timeout='30s'")
          # Historical corrections can attribute an event to a voided original
          # terminal minute omitted by the legacy recorded-only bucket backfill.
          # Create its row without overwriting any concurrent trigger delta. The
          # later locked, fresh-snapshot batch supplies the absolute amounts.
          query(
            """
            /* usage_component_bucket_seed */
            INSERT INTO public.api_key_usage_buckets (api_key_id,bucket_started_at,created_at,updated_at)
            SELECT DISTINCT v.api_key_id,date_trunc('minute',v.occurred_at),
              statement_timestamp(),statement_timestamp()
            FROM (SELECT array_agg(e) entries FROM public.ledger_entries e
              WHERE e.request_id=ANY($1::uuid[]) GROUP BY e.request_id) h
            CROSS JOIN LATERAL public.api_key_usage_events(h.entries) v
            WHERE EXISTS (SELECT 1 FROM public.api_keys k WHERE k.id=v.api_key_id)
            ORDER BY v.api_key_id,date_trunc('minute',v.occurred_at)
            ON CONFLICT (api_key_id,bucket_started_at) DO NOTHING
            """,
            [requests]
          )
        end)

      ensure_event_buckets(List.last(requests))
    end
  end

  # The edge reader and projection share this request-local event definition.
  # Pending is relational authority, never a cumulative bucket balance.
  defp events_function do
    """
    CREATE OR REPLACE FUNCTION public.api_key_usage_events(p_entries public.ledger_entries[])
    RETURNS TABLE(api_key_id uuid, occurred_at timestamptz,
      known_total_tokens bigint, provisional_total_tokens bigint,
      admission_count bigint, known_cost_micros numeric)
    LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $function$
      WITH entries AS MATERIALIZED (SELECT * FROM unnest(p_entries)),
      reservation AS (
        SELECT * FROM entries WHERE entry_kind = 'reservation' AND amount_status = 'recorded'
        ORDER BY occurred_at, created_at, id LIMIT 1
      ), terminal AS (
        SELECT * FROM entries
        WHERE amount_status = 'recorded' AND entry_kind IN ('settlement', 'release')
        ORDER BY CASE WHEN entry_kind = 'settlement' THEN 0 ELSE 1 END,
          occurred_at, created_at, id LIMIT 1
      ), terminal_time AS (
        SELECT min(occurred_at) AS occurred_at FROM entries
        WHERE entry_kind IN ('settlement', 'release')
      )
      SELECT r.api_key_id, r.occurred_at, 0::bigint, 0::bigint, 1::bigint, 0::numeric
      FROM reservation r
      UNION ALL
      SELECT t.api_key_id, tt.occurred_at,
        CASE WHEN t.entry_kind = 'settlement' AND t.usage_status = 'usage_known'
          THEN COALESCE(t.total_tokens, 0) ELSE 0 END,
        CASE WHEN t.usage_status <> 'not_applicable'
          AND (t.entry_kind = 'release' OR t.usage_status <> 'usage_known')
          AND (t.entry_kind <> 'release' OR NOT EXISTS (
            SELECT 1 FROM entries s WHERE s.entry_kind = 'settlement'
              AND s.usage_status IN ('usage_known', 'not_applicable')))
          AND (EXISTS (SELECT 1 FROM entries WHERE attempt_id IS NOT NULL)
            OR EXISTS (SELECT 1 FROM public.attempts a WHERE a.request_id = t.request_id)
            OR (t.entry_kind = 'settlement' AND t.details->>'estimated_from_reserve' = 'true'))
          THEN COALESCE(r.total_tokens,
            CASE WHEN t.entry_kind = 'settlement' AND
              t.details->>'estimated_from_reserve' = 'true' THEN t.total_tokens END, 0)
          ELSE 0 END,
        0::bigint,
        CASE WHEN t.entry_kind = 'settlement' AND t.usage_status = 'usage_known'
          THEN COALESCE(t.settled_cost_micros, 0) ELSE 0 END
      FROM terminal t CROSS JOIN terminal_time tt LEFT JOIN reservation r ON true
    $function$
    """
  end

  defp sync_trigger(operation) do
    transition =
      case operation do
        :insert -> "NEW TABLE AS new_entries"
        :update -> "OLD TABLE AS old_entries NEW TABLE AS new_entries"
        :delete -> "OLD TABLE AS old_entries"
      end

    """
    CREATE TRIGGER ledger_entries_usage_components_#{operation}
    AFTER #{operation |> Atom.to_string() |> String.upcase()} ON public.ledger_entries
    REFERENCING #{transition}
    FOR EACH STATEMENT EXECUTE FUNCTION public.sync_api_key_usage_components_#{operation}()
    """
  end

  defp sync_function(operation) do
    old_rows =
      if operation == :insert,
        do: "SELECT * FROM public.ledger_entries WHERE false",
        else: "SELECT * FROM old_entries"

    new_rows =
      if operation == :delete,
        do: "SELECT * FROM public.ledger_entries WHERE false",
        else: "SELECT * FROM new_entries"

    """
    CREATE OR REPLACE FUNCTION public.sync_api_key_usage_components_#{operation}()
    RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, public AS $function$
    BEGIN
      WITH old_rows AS MATERIALIZED (#{old_rows}),
      new_rows AS MATERIALIZED (#{new_rows}),
      affected AS (SELECT request_id FROM old_rows UNION SELECT request_id FROM new_rows),
      current_rows AS MATERIALIZED (
        SELECT e.* FROM affected a JOIN public.ledger_entries e ON e.request_id = a.request_id
      ), before_rows AS (
        SELECT e.* FROM current_rows e WHERE NOT EXISTS (SELECT 1 FROM new_rows n WHERE n.id = e.id)
        UNION ALL SELECT * FROM old_rows
      ), before_events AS (
        SELECT v.* FROM (SELECT array_agg(e::public.ledger_entries) AS entries FROM before_rows e GROUP BY request_id) r
        CROSS JOIN LATERAL public.api_key_usage_events(r.entries) v
      ), after_events AS (
        SELECT v.* FROM (SELECT array_agg(e::public.ledger_entries) AS entries FROM current_rows e GROUP BY request_id) r
        CROSS JOIN LATERAL public.api_key_usage_events(r.entries) v
      ), deltas AS (
        SELECT api_key_id, occurred_at, 0::bigint AS requests, 0::bigint AS tokens, 0::numeric AS cost,
          -known_total_tokens AS known, -provisional_total_tokens AS provisional,
          -admission_count AS admissions, -known_cost_micros AS known_cost FROM before_events
        UNION ALL SELECT api_key_id, occurred_at, 0, 0, 0,
          known_total_tokens, provisional_total_tokens, admission_count, known_cost_micros FROM after_events
        UNION ALL #{legacy_delta("old_rows", -1)}
        UNION ALL #{legacy_delta("new_rows", 1)}
      ), grouped AS (
        SELECT d.api_key_id, date_trunc('minute', d.occurred_at) AS bucket_started_at,
          SUM(requests) AS requests, SUM(tokens) AS tokens, SUM(cost) AS cost,
          SUM(known) AS known, SUM(provisional) AS provisional,
          SUM(admissions) AS admissions, SUM(known_cost) AS known_cost
        FROM deltas d WHERE EXISTS (SELECT 1 FROM public.api_keys k WHERE k.id = d.api_key_id)
        GROUP BY d.api_key_id, date_trunc('minute', d.occurred_at)
      )
      INSERT INTO public.api_key_usage_buckets AS b
        (api_key_id, bucket_started_at, effective_request_count, effective_total_tokens,
         effective_cost_micros, known_total_tokens, provisional_total_tokens, admission_count,
         known_cost_micros, created_at, updated_at)
      SELECT api_key_id, bucket_started_at, requests, tokens, cost, known, provisional,
        admissions, known_cost, statement_timestamp(), statement_timestamp()
      FROM grouped ORDER BY api_key_id, bucket_started_at
      ON CONFLICT (api_key_id, bucket_started_at) DO UPDATE SET
        effective_request_count = b.effective_request_count + EXCLUDED.effective_request_count,
        effective_total_tokens = b.effective_total_tokens + EXCLUDED.effective_total_tokens,
        effective_cost_micros = b.effective_cost_micros + EXCLUDED.effective_cost_micros,
        known_total_tokens = b.known_total_tokens + EXCLUDED.known_total_tokens,
        provisional_total_tokens = b.provisional_total_tokens + EXCLUDED.provisional_total_tokens,
        admission_count = b.admission_count + EXCLUDED.admission_count,
        known_cost_micros = b.known_cost_micros + EXCLUDED.known_cost_micros,
        updated_at = statement_timestamp();
      RETURN NULL;
    END
    $function$
    """
  end

  defp legacy_delta(rows, sign) do
    """
    SELECT api_key_id, occurred_at,
      #{sign} * CASE WHEN entry_kind = 'release' THEN -request_count ELSE request_count END,
      #{sign} * CASE
        WHEN entry_kind = 'release' THEN -COALESCE(total_tokens, 0)
        WHEN entry_kind = 'settlement' AND usage_status <> 'usage_known' THEN 0
        ELSE COALESCE(total_tokens, 0) END,
      #{sign} * CASE
        WHEN entry_kind = 'release' THEN -estimated_cost_micros
        WHEN entry_kind = 'settlement' AND usage_status = 'usage_known' THEN settled_cost_micros
        WHEN entry_kind = 'settlement' THEN 0 ELSE estimated_cost_micros END,
      0, 0, 0, 0 FROM #{rows} WHERE amount_status = 'recorded'
    """
  end

  defp rebuild_function do
    """
    CREATE OR REPLACE FUNCTION public.rebuild_api_key_usage_components()
    RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, public AS $function$
    BEGIN
      LOCK TABLE public.ledger_entries IN SHARE ROW EXCLUSIVE MODE NOWAIT;
      LOCK TABLE public.api_key_usage_buckets IN ACCESS EXCLUSIVE MODE NOWAIT;
      UPDATE public.api_key_usage_buckets SET known_total_tokens = 0,
        provisional_total_tokens = 0, admission_count = 0, known_cost_micros = 0;
      INSERT INTO public.api_key_usage_buckets AS b
        (api_key_id, bucket_started_at, known_total_tokens, provisional_total_tokens,
         admission_count, known_cost_micros, created_at, updated_at)
      SELECT v.api_key_id, date_trunc('minute', v.occurred_at), SUM(v.known_total_tokens),
        SUM(v.provisional_total_tokens), SUM(v.admission_count), SUM(v.known_cost_micros),
        statement_timestamp(), statement_timestamp()
      FROM (SELECT array_agg(e) AS entries FROM public.ledger_entries e GROUP BY request_id) r
      CROSS JOIN LATERAL public.api_key_usage_events(r.entries) v
      WHERE EXISTS (SELECT 1 FROM public.api_keys k WHERE k.id = v.api_key_id)
      GROUP BY v.api_key_id, date_trunc('minute', v.occurred_at)
      ORDER BY v.api_key_id, date_trunc('minute', v.occurred_at)
      ON CONFLICT (api_key_id, bucket_started_at) DO UPDATE SET
        known_total_tokens = EXCLUDED.known_total_tokens,
        provisional_total_tokens = EXCLUDED.provisional_total_tokens,
        admission_count = EXCLUDED.admission_count, known_cost_micros = EXCLUDED.known_cost_micros;
    END
    $function$
    """
  end
end
