defmodule CodexPooler.Accounting.RequestLifecycle.WindowUsage do
  @moduledoc false

  alias CodexPooler.Repo

  @type usage_window :: atom()
  @type windows :: keyword(DateTime.t()) | %{usage_window() => DateTime.t()}
  @type window_usage :: %{
          required(:effective_request_count) => non_neg_integer(),
          required(:known_total_tokens) => non_neg_integer(),
          required(:provisional_total_tokens) => non_neg_integer(),
          required(:pending_total_tokens) => non_neg_integer(),
          required(:effective_total_tokens) => non_neg_integer(),
          required(:effective_cost_micros) => Decimal.t()
        }

  @spec window_usages(Ecto.UUID.t(), windows()) :: %{usage_window() => window_usage()}
  def window_usages(api_key_id, windows),
    do: window_usages(api_key_id, windows, DateTime.utc_now())

  @spec window_usages(Ecto.UUID.t(), windows(), DateTime.t()) ::
          %{usage_window() => window_usage()}
  def window_usages(api_key_id, windows, %DateTime{} = as_of) do
    windows = Enum.reject(windows, fn {_window, since} -> is_nil(since) end)

    if windows == [] do
      %{}
    else
      api_key_id
      |> query_windows(Enum.map(windows, &elem(&1, 1)), as_of)
      |> Map.new(fn [ordinal, known, provisional, admissions, cost, pending] ->
        {window, _since} = Enum.at(windows, ordinal - 1)

        {window,
         %{
           effective_request_count: admissions,
           known_total_tokens: known,
           provisional_total_tokens: provisional,
           pending_total_tokens: pending,
           effective_total_tokens: known + provisional + pending,
           effective_cost_micros: cost
         }}
      end)
    end
  end

  defp query_windows(api_key_id, starts, as_of) do
    # Boundary buckets, excluded edge events and the outstanding set use
    # one PostgreSQL snapshot. A release/settlement ends a reservation by
    # identity, including a voided terminal, never by a signed window delta.
    # Keep the grouped edge facts equivalent to api_key_usage_events without
    # per-request function calls or joins between materialized request sets.
    # OFFSET 0 preserves parameterized range/history scans: flattening these
    # lateral reads can scan retained history even for a tiny excluded edge.
    # Pending tokens are the reserved tokens of the key's live requests
    # (`accepted`/`in_progress`, through `requests_api_key_live_idx`) that no
    # release or settlement ended, read with one aggregate probe of each
    # request's own ledger entries (findings#206, P106): never the key's
    # reservation history (4.6M plain-EXPLAIN cost for the largest production
    # key), and never a finished request's reservation that was not released,
    # which used to add its tokens to every window forever. The lateral
    # aggregate cannot be flattened into a join, so missing or empty planner
    # statistics keep it a parameterized probe.
    %{rows: rows} =
      Repo.query!(
        """
        WITH bounds AS (
          SELECT ordinal, since, $3::timestamptz AS as_of,
            date_trunc('minute', since) AS full_since,
            date_trunc('minute', $3::timestamptz) + interval '1 minute' AS full_until
          FROM unnest($2::timestamptz[]) WITH ORDINALITY AS windows(since, ordinal)
        ), edge_requests AS (
          SELECT e.request_id FROM bounds b CROSS JOIN LATERAL (
            SELECT request_id FROM public.ledger_entries
            WHERE api_key_id = $1::uuid AND occurred_at >= b.full_since AND occurred_at < b.since
            OFFSET 0
          ) e
          WHERE b.full_since < b.since
          UNION
          SELECT request_id FROM public.ledger_entries
          WHERE api_key_id = $1::uuid AND occurred_at > $3::timestamptz
            AND occurred_at < date_trunc('minute', $3::timestamptz) + interval '1 minute'
        ), edge_history AS MATERIALIZED (
          SELECT e.request_id, e.id, e.api_key_id, e.occurred_at, e.created_at, e.entry_kind,
            e.amount_status, e.usage_status, e.total_tokens, e.settled_cost_micros,
            e.attempt_id IS NOT NULL AS has_attempt,
            e.details->>'estimated_from_reserve' = 'true' AS estimated
          FROM edge_requests r CROSS JOIN LATERAL (
            SELECT * FROM public.ledger_entries WHERE request_id = r.request_id OFFSET 0
          ) e
        ), ranked_edges AS (
          SELECT e.*,
            row_number() OVER (PARTITION BY request_id ORDER BY
              CASE WHEN entry_kind = 'reservation' AND amount_status = 'recorded' THEN 0 ELSE 1 END,
              occurred_at, created_at, id) AS reservation_rank,
            row_number() OVER (PARTITION BY request_id ORDER BY
              CASE WHEN amount_status = 'recorded' AND entry_kind = 'settlement' THEN 0
                WHEN amount_status = 'recorded' AND entry_kind = 'release' THEN 1 ELSE 2 END,
              occurred_at, created_at, id) AS terminal_rank
          FROM edge_history e
        ), edge_facts AS MATERIALIZED (
          SELECT request_id,
            max(api_key_id::text) FILTER (WHERE reservation_rank = 1 AND entry_kind = 'reservation'
              AND amount_status = 'recorded')::uuid AS reservation_key,
            max(occurred_at) FILTER (WHERE reservation_rank = 1 AND entry_kind = 'reservation'
              AND amount_status = 'recorded') AS reservation_at,
            max(total_tokens) FILTER (WHERE reservation_rank = 1 AND entry_kind = 'reservation'
              AND amount_status = 'recorded') AS reservation_tokens,
            max(api_key_id::text) FILTER (WHERE terminal_rank = 1 AND entry_kind IN ('settlement','release')
              AND amount_status = 'recorded')::uuid AS api_key_id,
            max(entry_kind) FILTER (WHERE terminal_rank = 1 AND entry_kind IN ('settlement','release')
              AND amount_status = 'recorded') AS entry_kind,
            max(usage_status) FILTER (WHERE terminal_rank = 1) AS usage_status,
            max(total_tokens) FILTER (WHERE terminal_rank = 1) AS total_tokens,
            max(settled_cost_micros) FILTER (WHERE terminal_rank = 1) AS settled_cost_micros,
            bool_or(estimated) FILTER (WHERE terminal_rank = 1) AS estimated,
            min(occurred_at) FILTER (WHERE entry_kind IN ('settlement', 'release')) AS terminal_at,
            bool_or(has_attempt) AS has_attempt,
            bool_or(entry_kind = 'settlement' AND usage_status IN ('usage_known', 'not_applicable')) AS has_known
          FROM ranked_edges e GROUP BY request_id
        ), edge_values AS (
          SELECT reservation_key AS api_key_id, reservation_at AS occurred_at, 0::bigint AS known_total_tokens,
            0::bigint AS provisional_total_tokens, 1::bigint AS admission_count,
            0::numeric AS known_cost_micros FROM edge_facts WHERE reservation_at IS NOT NULL
          UNION ALL
          SELECT t.api_key_id, t.terminal_at,
            CASE WHEN t.entry_kind = 'settlement' AND t.usage_status = 'usage_known'
              THEN COALESCE(t.total_tokens, 0) ELSE 0 END,
            CASE WHEN t.usage_status <> 'not_applicable'
              AND (t.entry_kind = 'release' OR t.usage_status <> 'usage_known')
              AND (t.entry_kind <> 'release' OR NOT t.has_known)
              AND (t.has_attempt OR EXISTS (SELECT 1 FROM public.attempts a WHERE a.request_id = t.request_id)
                OR (t.entry_kind = 'settlement' AND t.estimated))
              THEN COALESCE(t.reservation_tokens, CASE WHEN t.entry_kind = 'settlement'
                AND t.estimated THEN t.total_tokens END, 0)
              ELSE 0 END,
            0::bigint,
            CASE WHEN t.entry_kind = 'settlement' AND t.usage_status = 'usage_known'
              THEN COALESCE(t.settled_cost_micros, 0) ELSE 0 END
          FROM edge_facts t WHERE t.entry_kind IS NOT NULL
        ), edge_events AS (
          SELECT b.ordinal, v.* FROM edge_values v
          CROSS JOIN bounds b
          WHERE v.api_key_id = $1::uuid AND v.occurred_at >= b.full_since AND v.occurred_at < b.full_until
            AND (v.occurred_at < b.since OR v.occurred_at > b.as_of)
        ), components AS (
          SELECT ordinal, -known_total_tokens AS known_total_tokens,
            -provisional_total_tokens AS provisional_total_tokens, -admission_count AS admission_count,
            -known_cost_micros AS known_cost_micros
          FROM edge_events
          UNION ALL
          SELECT b.ordinal, k.known_total_tokens, k.provisional_total_tokens, k.admission_count, k.known_cost_micros
          FROM public.api_key_usage_buckets k CROSS JOIN bounds b
          WHERE k.api_key_id = $1::uuid AND k.bucket_started_at >= b.full_since
            AND k.bucket_started_at < b.full_until
        ), pending AS MATERIALIZED (
          SELECT COALESCE(SUM(held.tokens), 0)::bigint AS tokens
          FROM public.requests q CROSS JOIN LATERAL (
            SELECT SUM(e.total_tokens) FILTER (WHERE e.entry_kind = 'reservation'
                AND e.amount_status = 'recorded' AND e.occurred_at <= $3::timestamptz) AS tokens
            FROM public.ledger_entries e WHERE e.request_id = q.id
            HAVING count(*) FILTER (WHERE e.entry_kind = 'reservation'
                AND e.amount_status = 'recorded' AND e.occurred_at <= $3::timestamptz) > 0
              AND count(*) FILTER (WHERE e.entry_kind IN ('release', 'settlement')) = 0
          ) held
          WHERE q.api_key_id = $1::uuid AND q.status IN ('accepted', 'in_progress')
        )
        SELECT b.ordinal, COALESCE(SUM(known_total_tokens), 0)::bigint,
          COALESCE(SUM(provisional_total_tokens), 0)::bigint,
          COALESCE(SUM(admission_count), 0)::bigint,
          COALESCE(SUM(known_cost_micros), 0), (SELECT tokens FROM pending)
        FROM bounds b LEFT JOIN components c ON c.ordinal = b.ordinal
        GROUP BY b.ordinal ORDER BY b.ordinal
        """,
        [Ecto.UUID.dump!(api_key_id), starts, as_of]
      )

    rows
  end
end
