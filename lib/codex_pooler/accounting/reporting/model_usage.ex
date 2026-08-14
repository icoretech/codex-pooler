defmodule CodexPooler.Accounting.Reporting.ModelUsage do
  @moduledoc false

  alias CodexPooler.Repo

  @unknown_model_code "Unknown model"
  @other_model_code "Other"
  @projection :model_usage_exact_rollups_and_edges

  @query """
  WITH rollup_source AS (
    SELECT
      rollup.bucket_started_at AS bucket,
      COALESCE(NULLIF(BTRIM(rollup.model_code), ''), $7::text) AS model_code,
      rollup.request_count,
      rollup.success_count,
      rollup.failure_count,
      rollup.retry_count,
      rollup.input_tokens,
      rollup.cached_input_tokens,
      rollup.output_tokens,
      rollup.reasoning_tokens,
      rollup.total_tokens,
      rollup.estimated_cost_micros,
      rollup.settled_cost_micros
    FROM public.hourly_model_usage_rollups AS rollup
    WHERE $6::text = 'hour'
      AND rollup.pool_id = ANY($1::uuid[])
      AND rollup.bucket_started_at >= $4
      AND rollup.bucket_started_at < $5

    UNION ALL

    SELECT
      rollup.rollup_date::timestamp AT TIME ZONE 'UTC' AS bucket,
      COALESCE(NULLIF(BTRIM(model.exposed_model_id), ''), $7::text) AS model_code,
      rollup.request_count,
      rollup.success_count,
      rollup.failure_count,
      rollup.retry_count,
      rollup.input_tokens,
      rollup.cached_input_tokens,
      rollup.output_tokens,
      rollup.reasoning_tokens,
      rollup.total_tokens,
      rollup.estimated_cost_micros,
      rollup.settled_cost_micros
    FROM public.daily_rollups AS rollup
    LEFT JOIN public.models AS model
      ON model.id = rollup.model_id
      AND model.pool_id = rollup.pool_id
    WHERE $6::text = 'day'
      AND rollup.pool_id = ANY($1::uuid[])
      AND rollup.dimension_kind = 'model'
      AND rollup.model_id IS NOT NULL
      AND rollup.rollup_date >= ($4 AT TIME ZONE 'UTC')::date
      AND rollup.rollup_date < ($5 AT TIME ZONE 'UTC')::date
  ),
  raw_edge_source AS (
    SELECT
      CASE
        WHEN $6::text = 'day' THEN date_trunc('day', entry.occurred_at)
        ELSE date_trunc('hour', entry.occurred_at)
      END AS bucket,
      COALESCE(NULLIF(BTRIM(model.exposed_model_id), ''), $7::text) AS model_code,
      1::bigint AS request_count,
      CASE WHEN request.status = 'succeeded' THEN 1 ELSE 0 END::bigint AS success_count,
      CASE WHEN request.status = 'succeeded' THEN 0 ELSE 1 END::bigint AS failure_count,
      COALESCE(request.retry_count, 0)::bigint AS retry_count,
      CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.input_tokens, 0) ELSE 0 END::bigint AS input_tokens,
      CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.cached_input_tokens, 0) ELSE 0 END::bigint AS cached_input_tokens,
      CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.output_tokens, 0) ELSE 0 END::bigint AS output_tokens,
      CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.reasoning_tokens, 0) ELSE 0 END::bigint AS reasoning_tokens,
      CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.total_tokens, 0) ELSE 0 END::bigint AS total_tokens,
      CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.estimated_cost_micros, 0::numeric) ELSE 0::numeric END AS estimated_cost_micros,
      CASE WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.settled_cost_micros, 0::numeric) ELSE 0::numeric END AS settled_cost_micros
    FROM public.ledger_entries AS entry
    INNER JOIN public.requests AS request ON request.id = entry.request_id
    LEFT JOIN public.models AS model
      ON model.id = request.model_id
      AND model.pool_id = request.pool_id
    WHERE entry.entry_kind = 'settlement'
      AND entry.amount_status = 'recorded'
      AND request.pool_id = ANY($1::uuid[])
      AND request.model_id IS NOT NULL
      AND (
        (entry.occurred_at >= $2 AND entry.occurred_at < $4)
        OR (entry.occurred_at >= $5 AND entry.occurred_at <= $3)
      )
  ),
  unified AS (
    SELECT * FROM rollup_source
    UNION ALL
    SELECT * FROM raw_edge_source
  ),
  bucketed AS (
    SELECT
      bucket,
      model_code,
      sum(request_count)::bigint AS request_count,
      sum(success_count)::bigint AS success_count,
      sum(failure_count)::bigint AS failure_count,
      sum(retry_count)::bigint AS retry_count,
      sum(input_tokens)::bigint AS input_tokens,
      sum(cached_input_tokens)::bigint AS cached_input_tokens,
      sum(output_tokens)::bigint AS output_tokens,
      sum(reasoning_tokens)::bigint AS reasoning_tokens,
      sum(total_tokens)::bigint AS total_tokens,
      sum(estimated_cost_micros) AS estimated_cost_micros,
      sum(settled_cost_micros) AS settled_cost_micros
    FROM unified
    GROUP BY bucket, model_code
  ),
  ranked_models AS (
    SELECT
      model_code,
      row_number() OVER (
        ORDER BY sum(total_tokens) DESC, sum(request_count) DESC, model_code ASC
      )::bigint AS series_rank
    FROM bucketed
    GROUP BY model_code
    HAVING sum(total_tokens) > 0
  ),
  labeled AS (
    SELECT
      bucketed.bucket,
      CASE WHEN ranked.series_rank <= 5 THEN bucketed.model_code ELSE $8::text END AS model_code,
      CASE WHEN ranked.series_rank <= 5 THEN ranked.series_rank ELSE 6 END::bigint AS series_rank,
      bucketed.request_count,
      bucketed.success_count,
      bucketed.failure_count,
      bucketed.retry_count,
      bucketed.input_tokens,
      bucketed.cached_input_tokens,
      bucketed.output_tokens,
      bucketed.reasoning_tokens,
      bucketed.total_tokens,
      bucketed.estimated_cost_micros,
      bucketed.settled_cost_micros
    FROM bucketed
    INNER JOIN ranked_models AS ranked USING (model_code)
  )
  SELECT
    bucket,
    model_code,
    series_rank,
    sum(request_count)::bigint AS request_count,
    sum(success_count)::bigint AS success_count,
    sum(failure_count)::bigint AS failure_count,
    sum(retry_count)::bigint AS retry_count,
    sum(input_tokens)::bigint AS input_tokens,
    sum(cached_input_tokens)::bigint AS cached_input_tokens,
    sum(output_tokens)::bigint AS output_tokens,
    sum(reasoning_tokens)::bigint AS reasoning_tokens,
    sum(total_tokens)::bigint AS total_tokens,
    sum(estimated_cost_micros) AS estimated_cost_micros,
    sum(settled_cost_micros) AS settled_cost_micros
  FROM labeled
  GROUP BY bucket, model_code, series_rank
  ORDER BY series_rank ASC, model_code ASC, bucket ASC
  """

  @type granularity :: :hour | :day

  @spec query([Ecto.UUID.t()], granularity(), DateTime.t(), DateTime.t()) :: [map()]
  def query(pool_ids, granularity, started_at, ended_at) do
    {sql, params} = statement(pool_ids, granularity, started_at, ended_at)

    %{rows: rows} =
      Repo.query!(sql, params, telemetry_options: [reporting_projection: @projection])

    Enum.map(rows, &row(&1, granularity))
  end

  @doc false
  def statement(pool_ids, granularity, started_at, ended_at) do
    {complete_started_at, complete_ended_at} = complete_bounds(granularity, started_at, ended_at)
    pool_ids = Enum.map(pool_ids, &Ecto.UUID.dump!/1)

    {
      @query,
      [
        pool_ids,
        started_at,
        ended_at,
        complete_started_at,
        complete_ended_at,
        Atom.to_string(granularity),
        @unknown_model_code,
        @other_model_code
      ]
    }
  end

  defp complete_bounds(:hour, started_at, ended_at),
    do: {ceil_hour(started_at), floor_hour(ended_at)}

  defp complete_bounds(:day, started_at, ended_at),
    do: {ceil_day(started_at), floor_day(ended_at)}

  defp floor_hour(datetime) do
    datetime = utc(datetime)
    %{datetime | minute: 0, second: 0, microsecond: {0, 6}}
  end

  defp ceil_hour(datetime) do
    floor = floor_hour(datetime)

    if DateTime.compare(utc(datetime), floor) == :eq,
      do: floor,
      else: DateTime.add(floor, 1, :hour)
  end

  defp floor_day(datetime) do
    datetime = utc(datetime)
    DateTime.new!(DateTime.to_date(datetime), ~T[00:00:00.000000], "Etc/UTC")
  end

  defp ceil_day(datetime) do
    floor = floor_day(datetime)

    if DateTime.compare(utc(datetime), floor) == :eq,
      do: floor,
      else: DateTime.add(floor, 1, :day)
  end

  defp utc(datetime),
    do: datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:microsecond)

  defp row(
         [
           bucket,
           model_code,
           series_rank,
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
           settled_cost_micros
         ],
         granularity
       ) do
    %{
      bucket: bucket(bucket, granularity),
      model_code: model_code,
      series_rank: integer(series_rank),
      request_count: integer(request_count),
      success_count: integer(success_count),
      failure_count: integer(failure_count),
      retry_count: integer(retry_count),
      input_tokens: integer(input_tokens),
      cached_input_tokens: integer(cached_input_tokens),
      output_tokens: integer(output_tokens),
      reasoning_tokens: integer(reasoning_tokens),
      total_tokens: integer(total_tokens),
      estimated_cost_micros: integer(estimated_cost_micros),
      settled_cost_micros: integer(settled_cost_micros)
    }
  end

  defp bucket(%DateTime{} = bucket, :hour), do: bucket
  defp bucket(%DateTime{} = bucket, :day), do: DateTime.to_date(bucket)

  defp integer(%Decimal{} = value), do: value |> Decimal.round(0) |> Decimal.to_integer()
  defp integer(value) when is_integer(value), do: max(value, 0)
end
