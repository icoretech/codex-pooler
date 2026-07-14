defmodule CodexPooler.Accounting.Rollups do
  @moduledoc """
  Daily and hourly rollup mutation, rebuild, and read helpers for accounting usage data.
  """

  import Ecto.Query

  alias CodexPooler.Accounting.{DailyRollup, HourlyModelUsageRollup, LedgerEntry, Request}
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Repo

  @entry_settlement "settlement"
  @amount_recorded "recorded"
  @usage_known "usage_known"
  @unknown_model_code "Unknown model"
  @daily_rollup_conflict_targets %{
    "pool" => {:unsafe_fragment, "(rollup_date, pool_id) WHERE dimension_kind = 'pool'"},
    "api_key" =>
      {:unsafe_fragment, "(rollup_date, pool_id, api_key_id) WHERE dimension_kind = 'api_key'"},
    "pool_upstream_assignment" =>
      {:unsafe_fragment,
       "(rollup_date, pool_upstream_assignment_id) WHERE dimension_kind = 'pool_upstream_assignment'"},
    "upstream_identity" =>
      {:unsafe_fragment,
       "(rollup_date, upstream_identity_id) WHERE dimension_kind = 'upstream_identity'"},
    "model" => {:unsafe_fragment, "(rollup_date, model_id) WHERE dimension_kind = 'model'"}
  }

  @daily_rollup_rebuild_sql """
  WITH source AS MATERIALIZED (
    SELECT
      entry.id AS ledger_entry_id,
      entry.occurred_at,
      entry.created_at,
      request.pool_id AS request_pool_id,
      request.api_key_id,
      request.model_id,
      request.status AS request_status,
      COALESCE(request.retry_count, 0) AS retry_count,
      entry.pool_upstream_assignment_id,
      entry.upstream_identity_id,
      CASE
        WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.input_tokens, 0)
        ELSE 0
      END AS input_tokens,
      CASE
        WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.cached_input_tokens, 0)
        ELSE 0
      END AS cached_input_tokens,
      CASE
        WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.output_tokens, 0)
        ELSE 0
      END AS output_tokens,
      CASE
        WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.reasoning_tokens, 0)
        ELSE 0
      END AS reasoning_tokens,
      CASE
        WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.total_tokens, 0)
        ELSE 0
      END AS total_tokens,
      CASE
        WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.estimated_cost_micros, 0::numeric)
        ELSE 0::numeric
      END AS estimated_cost_micros,
      CASE
        WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.settled_cost_micros, 0::numeric)
        ELSE 0::numeric
      END AS settled_cost_micros
    FROM public.ledger_entries AS entry
    INNER JOIN public.requests AS request ON request.id = entry.request_id
    WHERE entry.entry_kind = 'settlement'
      AND entry.amount_status = 'recorded'
      AND entry.occurred_at >= $2
      AND entry.occurred_at < $3
  ),
  dims AS (
    SELECT
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
  ),
  inserted AS (
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
      $1,
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
      $4,
      $4
    FROM dims
    GROUP BY
      dimension_kind,
      rollup_pool_id,
      api_key_id,
      pool_upstream_assignment_id,
      upstream_identity_id,
      model_id
    RETURNING 1
  )
  SELECT
    (SELECT count(*) FROM source)::bigint AS settlement_count,
    (SELECT count(*) FROM inserted)::bigint AS rollup_count
  """

  @hourly_model_usage_rebuild_sql """
  WITH source AS MATERIALIZED (
    SELECT
      date_trunc('hour', entry.occurred_at) AS bucket_started_at,
      entry.id AS ledger_entry_id,
      entry.occurred_at,
      entry.created_at,
      request.pool_id,
      CASE
        WHEN model.id IS NULL THEN NULL::uuid
        ELSE request.model_id
      END AS model_id,
      CASE
        WHEN model.id IS NULL THEN $4::text
        ELSE model.exposed_model_id
      END AS model_code,
      request.status AS request_status,
      COALESCE(request.retry_count, 0) AS retry_count,
      CASE
        WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.input_tokens, 0)
        ELSE 0
      END AS input_tokens,
      CASE
        WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.cached_input_tokens, 0)
        ELSE 0
      END AS cached_input_tokens,
      CASE
        WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.output_tokens, 0)
        ELSE 0
      END AS output_tokens,
      CASE
        WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.reasoning_tokens, 0)
        ELSE 0
      END AS reasoning_tokens,
      CASE
        WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.total_tokens, 0)
        ELSE 0
      END AS total_tokens,
      CASE
        WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.estimated_cost_micros, 0::numeric)
        ELSE 0::numeric
      END AS estimated_cost_micros,
      CASE
        WHEN entry.usage_status = 'usage_known' THEN COALESCE(entry.settled_cost_micros, 0::numeric)
        ELSE 0::numeric
      END AS settled_cost_micros
    FROM public.ledger_entries AS entry
    INNER JOIN public.requests AS request ON request.id = entry.request_id
    LEFT JOIN public.models AS model
      ON model.id = request.model_id
      AND model.pool_id = request.pool_id
    WHERE entry.entry_kind = 'settlement'
      AND entry.amount_status = 'recorded'
      AND request.model_id IS NOT NULL
      AND entry.occurred_at >= $1
      AND entry.occurred_at < $2
  ),
  aggregated AS (
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
      sum(settled_cost_micros) AS settled_cost_micros
    FROM source
    GROUP BY
      bucket_started_at,
      pool_id,
      model_id,
      model_code
  ),
  deleted AS (
    DELETE FROM public.hourly_model_usage_rollups AS rollup
    WHERE rollup.bucket_started_at >= $1
      AND rollup.bucket_started_at < $2
      AND rollup.updated_at <= $3
      AND NOT EXISTS (
        SELECT 1
        FROM aggregated AS aggregated_row
        WHERE aggregated_row.bucket_started_at = rollup.bucket_started_at
          AND aggregated_row.pool_id = rollup.pool_id
          AND aggregated_row.model_code = rollup.model_code
      )
    RETURNING 1
  ),
  upserted AS (
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
      $3,
      $3
    FROM aggregated
    ON CONFLICT (bucket_started_at, pool_id, model_code) DO UPDATE SET
      model_id = EXCLUDED.model_id,
      request_count = EXCLUDED.request_count,
      success_count = EXCLUDED.success_count,
      failure_count = EXCLUDED.failure_count,
      retry_count = EXCLUDED.retry_count,
      input_tokens = EXCLUDED.input_tokens,
      cached_input_tokens = EXCLUDED.cached_input_tokens,
      output_tokens = EXCLUDED.output_tokens,
      reasoning_tokens = EXCLUDED.reasoning_tokens,
      total_tokens = EXCLUDED.total_tokens,
      estimated_cost_micros = EXCLUDED.estimated_cost_micros,
      settled_cost_micros = EXCLUDED.settled_cost_micros,
      updated_at = EXCLUDED.updated_at
    WHERE public.hourly_model_usage_rollups.updated_at <= $3
    RETURNING 1
  )
  SELECT
    (SELECT count(*) FROM source)::bigint AS settlement_count,
    (SELECT count(*) FROM upserted)::bigint AS upserted_count,
    (SELECT count(*) FROM deleted)::bigint AS deleted_count
  """

  @spec accumulate!(Request.t(), LedgerEntry.t()) :: :ok
  def accumulate!(
        %Request{} = request,
        %LedgerEntry{entry_kind: @entry_settlement, amount_status: @amount_recorded} = settlement
      ) do
    delta = rollup_delta(request, settlement)
    date = DateTime.to_date(settlement.occurred_at || now())

    request
    |> daily_rollup_identities(settlement)
    |> Enum.each(&upsert_rollup!(&1, date, delta))

    upsert_hourly_model_usage_rollup!(request, settlement, delta)

    :ok
  end

  def accumulate!(%Request{}, %LedgerEntry{}), do: :ok

  @spec replace!(Request.t(), LedgerEntry.t(), Request.t(), LedgerEntry.t()) :: :ok
  def replace!(
        %Request{} = previous_request,
        %LedgerEntry{} = previous_settlement,
        %Request{} = request,
        %LedgerEntry{} = settlement
      ) do
    subtract!(previous_request, previous_settlement)
    accumulate!(request, settlement)
  end

  defp subtract!(%Request{} = request, %LedgerEntry{} = settlement) do
    delta = rollup_delta(request, settlement)
    date = DateTime.to_date(settlement.occurred_at || now())

    request
    |> daily_rollup_identities(settlement)
    |> Enum.each(&subtract_rollup!(&1, date, delta))

    subtract_hourly_model_usage_rollup!(request, settlement, delta)
  end

  defp daily_rollup_identities(%Request{} = request, %LedgerEntry{} = settlement) do
    [
      %{dimension_kind: "pool", pool_id: request.pool_id},
      %{dimension_kind: "api_key", pool_id: request.pool_id, api_key_id: request.api_key_id},
      pool_upstream_assignment_identity(request, settlement),
      upstream_identity_identity(request, settlement),
      model_identity(request)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp pool_upstream_assignment_identity(%Request{} = request, %LedgerEntry{} = settlement) do
    if settlement.pool_upstream_assignment_id do
      %{
        dimension_kind: "pool_upstream_assignment",
        pool_id: request.pool_id,
        pool_upstream_assignment_id: settlement.pool_upstream_assignment_id
      }
    end
  end

  defp upstream_identity_identity(%Request{} = request, %LedgerEntry{} = settlement) do
    if settlement.upstream_identity_id do
      %{
        dimension_kind: "upstream_identity",
        pool_id: request.pool_id,
        upstream_identity_id: settlement.upstream_identity_id
      }
    end
  end

  defp model_identity(%Request{model_id: model_id, pool_id: pool_id}) when is_binary(model_id) do
    %{dimension_kind: "model", pool_id: pool_id, model_id: model_id}
  end

  defp model_identity(%Request{}), do: nil

  @spec list(term(), keyword()) :: [term()]
  def list(pool_or_id, opts \\ []) do
    date = Keyword.get(opts, :date, Date.utc_today())
    dimension_kind = Keyword.get(opts, :dimension_kind)
    pool_id = id_for(pool_or_id)

    DailyRollup
    |> where([r], r.pool_id == ^pool_id and r.rollup_date == ^date)
    |> maybe_where_dimension(dimension_kind)
    |> order_by([r],
      asc: r.dimension_kind,
      asc: r.api_key_id,
      asc: r.pool_upstream_assignment_id,
      asc: r.upstream_identity_id,
      asc: r.model_id
    )
    |> Repo.all()
  end

  @spec rebuild_for_date(Date.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def rebuild_for_date(%Date{} = date) do
    start_at = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end_at = DateTime.add(start_at, 1, :day)
    now = now()

    Repo.transaction(fn ->
      Repo.delete_all(from r in DailyRollup, where: r.rollup_date == ^date)

      %{rows: [[settlement_count, _rollup_count]]} =
        Repo.query!(@daily_rollup_rebuild_sql, [date, start_at, end_at, now])

      settlement_count
    end)
    |> unwrap_transaction()
  end

  def rebuild_for_date(_date), do: {:error, :invalid_rollup_date}

  @spec rebuild_hourly_model_usage_rollups_for_hour(DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def rebuild_hourly_model_usage_rollups_for_hour(%DateTime{} = bucket_started_at) do
    started_at = hour_bucket(bucket_started_at)

    rebuild_hourly_model_usage_rollups_for_range(
      started_at,
      DateTime.add(started_at, 3_600, :second)
    )
  end

  def rebuild_hourly_model_usage_rollups_for_hour(_bucket_started_at),
    do: {:error, :invalid_hourly_model_usage_rollup_hour}

  @spec rebuild_hourly_model_usage_rollups_for_range(DateTime.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def rebuild_hourly_model_usage_rollups_for_range(
        %DateTime{} = started_at,
        %DateTime{} = ended_at
      ) do
    with {:ok, started_at} <- normalize_hour_boundary(started_at),
         {:ok, ended_at} <- normalize_hour_boundary(ended_at),
         true <- DateTime.compare(started_at, ended_at) == :lt do
      rebuild_started_at = now()

      Repo.transaction(fn ->
        %{rows: [[settlement_count, _upserted_count, _deleted_count]]} =
          Repo.query!(@hourly_model_usage_rebuild_sql, [
            started_at,
            ended_at,
            rebuild_started_at,
            @unknown_model_code
          ])

        settlement_count
      end)
      |> unwrap_transaction()
    else
      _error -> {:error, :invalid_hourly_model_usage_rollup_range}
    end
  end

  def rebuild_hourly_model_usage_rollups_for_range(_started_at, _ended_at),
    do: {:error, :invalid_hourly_model_usage_rollup_range}

  defp upsert_hourly_model_usage_rollup!(request, settlement, delta) do
    case hourly_model_identity(request) do
      nil ->
        :ok

      identity ->
        now = now()
        bucket_started_at = hour_bucket(settlement.occurred_at || now)

        attrs =
          identity
          |> Map.merge(delta)
          |> Map.merge(%{
            bucket_started_at: bucket_started_at,
            pool_id: request.pool_id,
            created_at: now,
            updated_at: now
          })

        Repo.insert_all(HourlyModelUsageRollup, [attrs],
          on_conflict: hourly_model_usage_increment_conflict(delta, identity.model_id, now),
          conflict_target: [:bucket_started_at, :pool_id, :model_code]
        )

        :ok
    end
  end

  defp subtract_hourly_model_usage_rollup!(request, settlement, delta) do
    case hourly_model_identity(request) do
      nil ->
        :ok

      identity ->
        lookup = %{
          bucket_started_at: hour_bucket(settlement.occurred_at || now()),
          pool_id: request.pool_id,
          model_code: identity.model_code
        }

        rollup = Repo.get_by!(HourlyModelUsageRollup, lookup)
        attrs = subtract_rollup_attrs(rollup, delta, now())

        if attrs.request_count == 0 do
          Repo.delete!(rollup)
        else
          rollup |> Ecto.Changeset.change(attrs) |> Repo.update!()
        end

        :ok
    end
  end

  defp hourly_model_usage_increment_conflict(delta, model_id, now) do
    from rollup in HourlyModelUsageRollup,
      update: [
        set: [
          model_id: ^model_id,
          estimated_cost_micros:
            fragment("? + EXCLUDED.estimated_cost_micros", rollup.estimated_cost_micros),
          settled_cost_micros:
            fragment("? + EXCLUDED.settled_cost_micros", rollup.settled_cost_micros),
          updated_at: ^now
        ],
        inc: [
          request_count: ^delta.request_count,
          success_count: ^delta.success_count,
          failure_count: ^delta.failure_count,
          retry_count: ^delta.retry_count,
          input_tokens: ^delta.input_tokens,
          cached_input_tokens: ^delta.cached_input_tokens,
          output_tokens: ^delta.output_tokens,
          reasoning_tokens: ^delta.reasoning_tokens,
          total_tokens: ^delta.total_tokens
        ]
      ]
  end

  defp hourly_model_identity(%Request{model_id: nil}), do: nil

  defp hourly_model_identity(%Request{pool_id: pool_id, model_id: model_id}) do
    case Repo.get_by(Model, id: model_id, pool_id: pool_id) do
      %Model{exposed_model_id: model_code} when is_binary(model_code) ->
        case String.trim(model_code) do
          "" -> %{model_id: nil, model_code: @unknown_model_code}
          code -> %{model_id: model_id, model_code: code}
        end

      nil ->
        %{model_id: nil, model_code: @unknown_model_code}
    end
  end

  defp upsert_rollup!(identity, date, delta) do
    now = now()

    attrs =
      identity
      |> Map.merge(delta)
      |> Map.merge(%{rollup_date: date, created_at: now, updated_at: now})

    Repo.insert_all(DailyRollup, [attrs],
      on_conflict: daily_rollup_increment_conflict(delta, now),
      conflict_target: daily_rollup_conflict_target(identity)
    )

    :ok
  end

  defp daily_rollup_conflict_target(%{dimension_kind: dimension_kind}) do
    Map.fetch!(@daily_rollup_conflict_targets, dimension_kind)
  end

  defp daily_rollup_increment_conflict(delta, now) do
    from rollup in DailyRollup,
      update: [
        set: [
          estimated_cost_micros:
            fragment("? + EXCLUDED.estimated_cost_micros", rollup.estimated_cost_micros),
          settled_cost_micros:
            fragment("? + EXCLUDED.settled_cost_micros", rollup.settled_cost_micros),
          updated_at: ^now
        ],
        inc: [
          request_count: ^delta.request_count,
          success_count: ^delta.success_count,
          failure_count: ^delta.failure_count,
          retry_count: ^delta.retry_count,
          input_tokens: ^delta.input_tokens,
          cached_input_tokens: ^delta.cached_input_tokens,
          output_tokens: ^delta.output_tokens,
          reasoning_tokens: ^delta.reasoning_tokens,
          total_tokens: ^delta.total_tokens
        ]
      ]
  end

  defp subtract_rollup!(identity, date, delta) do
    rollup = Repo.get_by!(DailyRollup, rollup_lookup(identity, date))
    attrs = subtract_rollup_attrs(rollup, delta, now())

    if attrs.request_count == 0 do
      Repo.delete!(rollup)
    else
      rollup |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end
  end

  defp subtract_rollup_attrs(rollup, delta, timestamp) do
    %{
      request_count: rollup.request_count - delta.request_count,
      success_count: rollup.success_count - delta.success_count,
      failure_count: rollup.failure_count - delta.failure_count,
      retry_count: rollup.retry_count - delta.retry_count,
      input_tokens: rollup.input_tokens - delta.input_tokens,
      cached_input_tokens: rollup.cached_input_tokens - delta.cached_input_tokens,
      output_tokens: rollup.output_tokens - delta.output_tokens,
      reasoning_tokens: rollup.reasoning_tokens - delta.reasoning_tokens,
      total_tokens: rollup.total_tokens - delta.total_tokens,
      estimated_cost_micros:
        Decimal.sub(rollup.estimated_cost_micros, delta.estimated_cost_micros),
      settled_cost_micros: Decimal.sub(rollup.settled_cost_micros, delta.settled_cost_micros),
      updated_at: timestamp
    }
  end

  defp rollup_lookup(
         %{dimension_kind: "upstream_identity", upstream_identity_id: upstream_identity_id},
         date
       ) do
    %{
      dimension_kind: "upstream_identity",
      upstream_identity_id: upstream_identity_id,
      rollup_date: date
    }
  end

  defp rollup_lookup(identity, date), do: Map.merge(identity, %{rollup_date: date})

  defp rollup_delta(request, settlement) do
    %{
      request_count: 1,
      success_count: success_count(request),
      failure_count: failure_count(request),
      retry_count: request.retry_count || 0,
      input_tokens: known_usage_integer(settlement, :input_tokens),
      cached_input_tokens: known_usage_integer(settlement, :cached_input_tokens),
      output_tokens: known_usage_integer(settlement, :output_tokens),
      reasoning_tokens: known_usage_integer(settlement, :reasoning_tokens),
      total_tokens: known_usage_integer(settlement, :total_tokens),
      estimated_cost_micros: known_usage_decimal(settlement, :estimated_cost_micros),
      settled_cost_micros: settled_rollup_cost(settlement)
    }
  end

  defp success_count(%Request{status: "succeeded"}), do: 1
  defp success_count(%Request{}), do: 0

  defp failure_count(%Request{status: "succeeded"}), do: 0
  defp failure_count(%Request{}), do: 1

  defp settled_rollup_cost(%LedgerEntry{usage_status: @usage_known, settled_cost_micros: cost}),
    do: cost || Decimal.new(0)

  defp settled_rollup_cost(%LedgerEntry{}), do: Decimal.new(0)

  defp known_usage_integer(%LedgerEntry{usage_status: @usage_known} = settlement, field),
    do: Map.fetch!(settlement, field) || 0

  defp known_usage_integer(%LedgerEntry{}, _field), do: 0

  defp known_usage_decimal(%LedgerEntry{usage_status: @usage_known} = settlement, field),
    do: Map.fetch!(settlement, field) || Decimal.new(0)

  defp known_usage_decimal(%LedgerEntry{}, _field), do: Decimal.new(0)

  defp maybe_where_dimension(query, nil), do: query

  defp maybe_where_dimension(query, dimension_kind),
    do: from(r in query, where: r.dimension_kind == ^dimension_kind)

  defp id_for(%{id: id}), do: id
  defp id_for(id) when is_binary(id), do: id
  defp id_for(_), do: nil

  defp normalize_hour_boundary(%DateTime{} = datetime) do
    datetime = datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:microsecond)

    if hour_boundary?(datetime),
      do: {:ok, datetime},
      else: {:error, :not_hour_boundary}
  end

  defp hour_boundary?(%DateTime{minute: 0, second: 0, microsecond: {0, _precision}}), do: true
  defp hour_boundary?(%DateTime{}), do: false

  defp hour_bucket(%DateTime{} = datetime) do
    datetime = datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:microsecond)
    %{datetime | minute: 0, second: 0, microsecond: {0, 6}}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, value}), do: {:error, value}
end
