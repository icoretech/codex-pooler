defmodule CodexPooler.Repo.Migrations.RepairUnknownUsageAccountingProjections do
  use Ecto.Migration

  def up do
    execute(delete_affected_daily_rollups_sql())
    execute(insert_affected_daily_rollups_sql())
    execute(delete_affected_hourly_model_usage_rollups_sql())
    execute(insert_affected_hourly_model_usage_rollups_sql())
    execute(repair_request_log_facts_sql())
  end

  def down do
    raise Ecto.MigrationError,
          "derived projection repair cannot restore previous poisoned request_log_facts/rollups"
  end

  defp delete_affected_daily_rollups_sql do
    """
    WITH affected_dates AS MATERIALIZED (
      SELECT DISTINCT entry.occurred_at::date AS rollup_date
      FROM public.ledger_entries AS entry
      WHERE entry.entry_kind = 'settlement'
        AND entry.amount_status = 'recorded'
        AND entry.usage_status != 'usage_known'
    )
    DELETE FROM public.daily_rollups AS rollup
    USING affected_dates AS affected
    WHERE rollup.rollup_date = affected.rollup_date
    """
  end

  defp insert_affected_daily_rollups_sql do
    """
    WITH affected_dates AS MATERIALIZED (
      SELECT DISTINCT entry.occurred_at::date AS rollup_date
      FROM public.ledger_entries AS entry
      WHERE entry.entry_kind = 'settlement'
        AND entry.amount_status = 'recorded'
        AND entry.usage_status != 'usage_known'
    ),
    source AS MATERIALIZED (
      SELECT
        entry.id AS ledger_entry_id,
        entry.occurred_at,
        entry.created_at,
        entry.occurred_at::date AS rollup_date,
        request.pool_id AS request_pool_id,
        request.api_key_id,
        request.model_id,
        request.status AS request_status,
        COALESCE(request.retry_count, 0) AS retry_count,
        entry.pool_upstream_assignment_id,
        entry.upstream_identity_id,
        CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.input_tokens, 0) ELSE 0 END AS input_tokens,
        CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.cached_input_tokens, 0) ELSE 0 END AS cached_input_tokens,
        CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.output_tokens, 0) ELSE 0 END AS output_tokens,
        CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.reasoning_tokens, 0) ELSE 0 END AS reasoning_tokens,
        CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.total_tokens, 0) ELSE 0 END AS total_tokens,
        CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.estimated_cost_micros, 0::numeric) ELSE 0::numeric END AS estimated_cost_micros,
        CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.settled_cost_micros, 0::numeric) ELSE 0::numeric END AS settled_cost_micros
      FROM public.ledger_entries AS entry
      INNER JOIN public.requests AS request ON request.id = entry.request_id
      INNER JOIN affected_dates AS affected ON affected.rollup_date = entry.occurred_at::date
      WHERE entry.entry_kind = 'settlement'
        AND entry.amount_status = 'recorded'
    ),
    dims AS (
      SELECT
        rollup_date,
        'pool'::text AS dimension_kind,
        request_pool_id AS rollup_pool_id,
        request_pool_id AS candidate_pool_id,
        NULL::uuid AS api_key_id,
        NULL::uuid AS pool_upstream_assignment_id,
        NULL::uuid AS upstream_identity_id,
        NULL::uuid AS model_id,
        ledger_entry_id,
        occurred_at,
        created_at,
        request_status,
        retry_count,
        input_tokens,
        cached_input_tokens,
        output_tokens,
        reasoning_tokens,
        total_tokens,
        estimated_cost_micros,
        settled_cost_micros
      FROM source

      UNION ALL

      SELECT
        rollup_date,
        'api_key'::text AS dimension_kind,
        request_pool_id AS rollup_pool_id,
        request_pool_id AS candidate_pool_id,
        api_key_id,
        NULL::uuid AS pool_upstream_assignment_id,
        NULL::uuid AS upstream_identity_id,
        NULL::uuid AS model_id,
        ledger_entry_id,
        occurred_at,
        created_at,
        request_status,
        retry_count,
        input_tokens,
        cached_input_tokens,
        output_tokens,
        reasoning_tokens,
        total_tokens,
        estimated_cost_micros,
        settled_cost_micros
      FROM source

      UNION ALL

      SELECT
        rollup_date,
        'pool_upstream_assignment'::text AS dimension_kind,
        request_pool_id AS rollup_pool_id,
        request_pool_id AS candidate_pool_id,
        NULL::uuid AS api_key_id,
        pool_upstream_assignment_id,
        NULL::uuid AS upstream_identity_id,
        NULL::uuid AS model_id,
        ledger_entry_id,
        occurred_at,
        created_at,
        request_status,
        retry_count,
        input_tokens,
        cached_input_tokens,
        output_tokens,
        reasoning_tokens,
        total_tokens,
        estimated_cost_micros,
        settled_cost_micros
      FROM source
      WHERE pool_upstream_assignment_id IS NOT NULL

      UNION ALL

      SELECT
        rollup_date,
        'upstream_identity'::text AS dimension_kind,
        NULL::uuid AS rollup_pool_id,
        request_pool_id AS candidate_pool_id,
        NULL::uuid AS api_key_id,
        NULL::uuid AS pool_upstream_assignment_id,
        upstream_identity_id,
        NULL::uuid AS model_id,
        ledger_entry_id,
        occurred_at,
        created_at,
        request_status,
        retry_count,
        input_tokens,
        cached_input_tokens,
        output_tokens,
        reasoning_tokens,
        total_tokens,
        estimated_cost_micros,
        settled_cost_micros
      FROM source
      WHERE upstream_identity_id IS NOT NULL

      UNION ALL

      SELECT
        rollup_date,
        'model'::text AS dimension_kind,
        request_pool_id AS rollup_pool_id,
        request_pool_id AS candidate_pool_id,
        NULL::uuid AS api_key_id,
        NULL::uuid AS pool_upstream_assignment_id,
        NULL::uuid AS upstream_identity_id,
        model_id,
        ledger_entry_id,
        occurred_at,
        created_at,
        request_status,
        retry_count,
        input_tokens,
        cached_input_tokens,
        output_tokens,
        reasoning_tokens,
        total_tokens,
        estimated_cost_micros,
        settled_cost_micros
      FROM source
      WHERE model_id IS NOT NULL
    )
    INSERT INTO public.daily_rollups (
      rollup_date,
      dimension_kind,
      pool_id,
      api_key_id,
      pool_upstream_assignment_id,
      upstream_identity_id,
      model_id,
      request_count,
      success_count,
      failure_count,
      retry_count,
      input_tokens,
      cached_input_tokens,
      output_tokens,
      reasoning_tokens,
      total_tokens,
      estimated_cost_micros,
      settled_cost_micros,
      created_at,
      updated_at
    )
    SELECT
      rollup_date,
      dimension_kind,
      CASE
        WHEN dimension_kind = 'upstream_identity' THEN
          (array_agg(candidate_pool_id ORDER BY occurred_at ASC, created_at ASC, ledger_entry_id ASC))[1]
        ELSE rollup_pool_id
      END AS pool_id,
      api_key_id,
      pool_upstream_assignment_id,
      upstream_identity_id,
      model_id,
      count(*)::bigint AS request_count,
      sum(CASE WHEN request_status = 'succeeded' THEN 1 ELSE 0 END)::bigint AS success_count,
      sum(CASE WHEN request_status = 'succeeded' THEN 0 ELSE 1 END)::bigint AS failure_count,
      sum(retry_count)::bigint AS retry_count,
      sum(input_tokens)::bigint AS input_tokens,
      sum(cached_input_tokens)::bigint AS cached_input_tokens,
      sum(output_tokens)::bigint AS output_tokens,
      sum(reasoning_tokens)::bigint AS reasoning_tokens,
      sum(total_tokens)::bigint AS total_tokens,
      sum(estimated_cost_micros) AS estimated_cost_micros,
      sum(settled_cost_micros) AS settled_cost_micros,
      NOW(),
      NOW()
    FROM dims
    GROUP BY
      rollup_date,
      dimension_kind,
      rollup_pool_id,
      api_key_id,
      pool_upstream_assignment_id,
      upstream_identity_id,
      model_id
    """
  end

  defp delete_affected_hourly_model_usage_rollups_sql do
    """
    WITH affected_hours AS MATERIALIZED (
      SELECT DISTINCT date_trunc('hour', entry.occurred_at) AS bucket_started_at
      FROM public.ledger_entries AS entry
      INNER JOIN public.requests AS request ON request.id = entry.request_id
      WHERE entry.entry_kind = 'settlement'
        AND entry.amount_status = 'recorded'
        AND entry.usage_status != 'usage_known'
        AND request.model_id IS NOT NULL
    )
    DELETE FROM public.hourly_model_usage_rollups AS rollup
    USING affected_hours AS affected
    WHERE rollup.bucket_started_at = affected.bucket_started_at
    """
  end

  defp insert_affected_hourly_model_usage_rollups_sql do
    """
    WITH affected_hours AS MATERIALIZED (
      SELECT DISTINCT date_trunc('hour', entry.occurred_at) AS bucket_started_at
      FROM public.ledger_entries AS entry
      INNER JOIN public.requests AS request ON request.id = entry.request_id
      WHERE entry.entry_kind = 'settlement'
        AND entry.amount_status = 'recorded'
        AND entry.usage_status != 'usage_known'
        AND request.model_id IS NOT NULL
    ),
    source AS MATERIALIZED (
      SELECT
        date_trunc('hour', entry.occurred_at) AS bucket_started_at,
        request.pool_id,
        CASE WHEN model.id IS NULL THEN NULL::uuid ELSE request.model_id END AS model_id,
        CASE WHEN model.id IS NULL THEN 'Unknown model' ELSE model.exposed_model_id END AS model_code,
        request.status AS request_status,
        COALESCE(request.retry_count, 0) AS retry_count,
        CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.input_tokens, 0) ELSE 0 END AS input_tokens,
        CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.cached_input_tokens, 0) ELSE 0 END AS cached_input_tokens,
        CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.output_tokens, 0) ELSE 0 END AS output_tokens,
        CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.reasoning_tokens, 0) ELSE 0 END AS reasoning_tokens,
        CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.total_tokens, 0) ELSE 0 END AS total_tokens,
        CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.estimated_cost_micros, 0::numeric) ELSE 0::numeric END AS estimated_cost_micros,
        CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.settled_cost_micros, 0::numeric) ELSE 0::numeric END AS settled_cost_micros
      FROM public.ledger_entries AS entry
      INNER JOIN public.requests AS request ON request.id = entry.request_id
      INNER JOIN affected_hours AS affected
        ON affected.bucket_started_at = date_trunc('hour', entry.occurred_at)
      LEFT JOIN public.models AS model
        ON model.id = request.model_id
        AND model.pool_id = request.pool_id
      WHERE entry.entry_kind = 'settlement'
        AND entry.amount_status = 'recorded'
        AND request.model_id IS NOT NULL
    )
    INSERT INTO public.hourly_model_usage_rollups (
      bucket_started_at,
      pool_id,
      model_id,
      model_code,
      request_count,
      success_count,
      failure_count,
      retry_count,
      input_tokens,
      cached_input_tokens,
      output_tokens,
      reasoning_tokens,
      total_tokens,
      estimated_cost_micros,
      settled_cost_micros,
      created_at,
      updated_at
    )
    SELECT
      bucket_started_at,
      pool_id,
      model_id,
      model_code,
      count(*)::bigint AS request_count,
      sum(CASE WHEN request_status = 'succeeded' THEN 1 ELSE 0 END)::bigint AS success_count,
      sum(CASE WHEN request_status = 'succeeded' THEN 0 ELSE 1 END)::bigint AS failure_count,
      sum(retry_count)::bigint AS retry_count,
      sum(input_tokens)::bigint AS input_tokens,
      sum(cached_input_tokens)::bigint AS cached_input_tokens,
      sum(output_tokens)::bigint AS output_tokens,
      sum(reasoning_tokens)::bigint AS reasoning_tokens,
      sum(total_tokens)::bigint AS total_tokens,
      sum(estimated_cost_micros) AS estimated_cost_micros,
      sum(settled_cost_micros) AS settled_cost_micros,
      NOW(),
      NOW()
    FROM source
    GROUP BY
      bucket_started_at,
      pool_id,
      model_id,
      model_code
    """
  end

  defp repair_request_log_facts_sql do
    """
    WITH candidate_requests AS MATERIALIZED (
      SELECT request.id
      FROM public.requests AS request
      JOIN LATERAL (
        SELECT entry.usage_status
        FROM public.ledger_entries AS entry
        WHERE entry.request_id = request.id
          AND entry.entry_kind = 'settlement'
          AND entry.amount_status = 'recorded'
        ORDER BY entry.occurred_at DESC, entry.created_at DESC, entry.id DESC
        LIMIT 1
      ) AS latest_settlement ON latest_settlement.usage_status != 'usage_known'
    ),
    projected AS (
      SELECT request.id AS request_id,
        latest_attempt.id AS latest_attempt_id,
        latest_attempt.attempt_number AS latest_attempt_number,
        latest_attempt.status AS latest_attempt_status,
        latest_attempt.retryable AS latest_attempt_retryable,
        latest_attempt.upstream_status_code AS latest_upstream_status_code,
        latest_attempt.pool_upstream_assignment_id AS latest_pool_upstream_assignment_id,
        latest_attempt.upstream_identity_id AS latest_upstream_identity_id,
        latest_attempt.network_error_code AS latest_network_error_code,
        latest_attempt.latency_ms AS latest_latency_ms,
        latest_settlement.id AS latest_settlement_entry_id,
        latest_settlement.usage_status AS latest_settlement_usage_status,
        latest_settlement.details->>'pricing_status' AS latest_settlement_pricing_status,
        NULL::bigint AS latest_input_tokens,
        NULL::bigint AS latest_cached_input_tokens,
        NULL::bigint AS latest_output_tokens,
        NULL::bigint AS latest_reasoning_tokens,
        NULL::bigint AS latest_total_tokens,
        NULL::bigint AS latest_settled_cost_micros,
        NULL::bigint AS latest_cached_input_cost_micros,
        NULL::bigint AS latest_cached_input_token_micros,
        latest_settlement.occurred_at AS latest_settlement_occurred_at,
        latest_settlement.created_at AS latest_settlement_created_at
      FROM candidate_requests AS request
      LEFT JOIN LATERAL (
        SELECT attempt.id, attempt.attempt_number, attempt.status, attempt.retryable,
          attempt.upstream_status_code, attempt.pool_upstream_assignment_id,
          attempt.upstream_identity_id, attempt.network_error_code, attempt.latency_ms
        FROM public.attempts AS attempt
        WHERE attempt.request_id = request.id
        ORDER BY attempt.attempt_number DESC, attempt.id DESC
        LIMIT 1
      ) AS latest_attempt ON TRUE
      LEFT JOIN LATERAL (
        SELECT entry.id, entry.usage_status, entry.details, entry.occurred_at, entry.created_at
        FROM public.ledger_entries AS entry
        WHERE entry.request_id = request.id
          AND entry.entry_kind = 'settlement'
          AND entry.amount_status = 'recorded'
        ORDER BY entry.occurred_at DESC, entry.created_at DESC, entry.id DESC
        LIMIT 1
      ) AS latest_settlement ON TRUE
    )
    INSERT INTO public.request_log_facts (
      request_id, latest_attempt_id, latest_attempt_number, latest_attempt_status,
      latest_attempt_retryable, latest_upstream_status_code, latest_pool_upstream_assignment_id,
      latest_upstream_identity_id, latest_network_error_code, latest_latency_ms,
      latest_settlement_entry_id, latest_settlement_usage_status, latest_settlement_pricing_status,
      latest_input_tokens, latest_cached_input_tokens, latest_output_tokens, latest_reasoning_tokens,
      latest_total_tokens, latest_settled_cost_micros, latest_cached_input_cost_micros,
      latest_cached_input_token_micros, latest_settlement_occurred_at, latest_settlement_created_at,
      inserted_at, updated_at
    )
    SELECT request_id, latest_attempt_id, latest_attempt_number, latest_attempt_status,
      latest_attempt_retryable, latest_upstream_status_code, latest_pool_upstream_assignment_id,
      latest_upstream_identity_id, latest_network_error_code, latest_latency_ms,
      latest_settlement_entry_id, latest_settlement_usage_status, latest_settlement_pricing_status,
      latest_input_tokens, latest_cached_input_tokens, latest_output_tokens, latest_reasoning_tokens,
      latest_total_tokens, latest_settled_cost_micros, latest_cached_input_cost_micros,
      latest_cached_input_token_micros, latest_settlement_occurred_at, latest_settlement_created_at,
      NOW(), NOW()
    FROM projected
    ON CONFLICT (request_id) DO UPDATE SET
      latest_attempt_id = EXCLUDED.latest_attempt_id,
      latest_attempt_number = EXCLUDED.latest_attempt_number,
      latest_attempt_status = EXCLUDED.latest_attempt_status,
      latest_attempt_retryable = EXCLUDED.latest_attempt_retryable,
      latest_upstream_status_code = EXCLUDED.latest_upstream_status_code,
      latest_pool_upstream_assignment_id = EXCLUDED.latest_pool_upstream_assignment_id,
      latest_upstream_identity_id = EXCLUDED.latest_upstream_identity_id,
      latest_network_error_code = EXCLUDED.latest_network_error_code,
      latest_latency_ms = EXCLUDED.latest_latency_ms,
      latest_settlement_entry_id = EXCLUDED.latest_settlement_entry_id,
      latest_settlement_usage_status = EXCLUDED.latest_settlement_usage_status,
      latest_settlement_pricing_status = EXCLUDED.latest_settlement_pricing_status,
      latest_input_tokens = EXCLUDED.latest_input_tokens,
      latest_cached_input_tokens = EXCLUDED.latest_cached_input_tokens,
      latest_output_tokens = EXCLUDED.latest_output_tokens,
      latest_reasoning_tokens = EXCLUDED.latest_reasoning_tokens,
      latest_total_tokens = EXCLUDED.latest_total_tokens,
      latest_settled_cost_micros = EXCLUDED.latest_settled_cost_micros,
      latest_cached_input_cost_micros = EXCLUDED.latest_cached_input_cost_micros,
      latest_cached_input_token_micros = EXCLUDED.latest_cached_input_token_micros,
      latest_settlement_occurred_at = EXCLUDED.latest_settlement_occurred_at,
      latest_settlement_created_at = EXCLUDED.latest_settlement_created_at,
      updated_at = EXCLUDED.updated_at
    """
  end
end
