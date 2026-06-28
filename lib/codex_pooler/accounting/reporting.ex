defmodule CodexPooler.Accounting.Reporting do
  @moduledoc """
  Read-only accounting projections for admin/reporting surfaces.
  """

  import Ecto.Query

  alias CodexPooler.Accounting.{DailyRollup, HourlyModelUsageRollup, LedgerEntry}
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Repo

  @settlement "settlement"
  @recorded "recorded"
  @usage_known "usage_known"
  @model_dimension "model"
  @unknown_model_code "Unknown model"

  @type model_usage_source :: :hourly_model_usage_rollups | :daily_model_rollups
  @type model_usage_bucket :: %{
          required(:bucket) => Date.t() | DateTime.t(),
          required(:model_code) => String.t(),
          required(:request_count) => non_neg_integer(),
          required(:input_tokens) => non_neg_integer(),
          required(:cached_input_tokens) => non_neg_integer(),
          required(:output_tokens) => non_neg_integer(),
          required(:reasoning_tokens) => non_neg_integer(),
          required(:total_tokens) => non_neg_integer(),
          required(:estimated_cost_micros) => non_neg_integer(),
          required(:settled_cost_micros) => non_neg_integer()
        }
  @type model_usage_bucket_result :: %{
          required(:source) => model_usage_source(),
          required(:rows) => [model_usage_bucket()]
        }

  @spec settlements_for_pool_ids([Ecto.UUID.t()], DateTime.t(), DateTime.t()) :: [map()]
  def settlements_for_pool_ids([], _started_at, _ended_at), do: []

  def settlements_for_pool_ids(pool_ids, started_at, ended_at) do
    Repo.all(
      from entry in LedgerEntry,
        where:
          entry.pool_id in ^pool_ids and entry.entry_kind == ^@settlement and
            entry.amount_status == ^@recorded and entry.occurred_at >= ^started_at and
            entry.occurred_at <= ^ended_at,
        order_by: [desc: entry.occurred_at, desc: entry.created_at],
        select: %{
          pool_id: entry.pool_id,
          api_key_id: entry.api_key_id,
          upstream_identity_id: entry.upstream_identity_id,
          request_count: entry.request_count,
          input_tokens:
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE 0 END",
              entry.usage_status,
              ^@usage_known,
              entry.input_tokens
            ),
          cached_input_tokens:
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE 0 END",
              entry.usage_status,
              ^@usage_known,
              entry.cached_input_tokens
            ),
          output_tokens:
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE 0 END",
              entry.usage_status,
              ^@usage_known,
              entry.output_tokens
            ),
          reasoning_tokens:
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE 0 END",
              entry.usage_status,
              ^@usage_known,
              entry.reasoning_tokens
            ),
          total_tokens:
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE 0 END",
              entry.usage_status,
              ^@usage_known,
              entry.total_tokens
            ),
          estimated_cost_micros:
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE 0 END",
              entry.usage_status,
              ^@usage_known,
              entry.estimated_cost_micros
            ),
          settled_cost_micros:
            fragment(
              "CASE WHEN ? = ? THEN ? ELSE 0 END",
              entry.usage_status,
              ^@usage_known,
              entry.settled_cost_micros
            ),
          occurred_at: entry.occurred_at
        }
    )
  end

  @spec token_totals_by_pool_ids([Ecto.UUID.t()], DateTime.t(), DateTime.t()) :: %{
          optional(Ecto.UUID.t()) => non_neg_integer()
        }
  def token_totals_by_pool_ids([], _started_at, _ended_at), do: %{}

  def token_totals_by_pool_ids(pool_ids, started_at, ended_at) do
    Repo.all(
      from entry in LedgerEntry,
        where:
          entry.pool_id in ^pool_ids and entry.entry_kind == ^@settlement and
            entry.amount_status == ^@recorded and entry.occurred_at >= ^started_at and
            entry.occurred_at <= ^ended_at,
        group_by: entry.pool_id,
        select:
          {entry.pool_id,
           sum(
             fragment(
               "CASE WHEN ? = ? THEN ? ELSE 0 END",
               entry.usage_status,
               ^@usage_known,
               entry.total_tokens
             )
           )}
    )
    |> Map.new(fn {pool_id, total} -> {pool_id, non_negative_integer(total)} end)
  end

  @spec token_totals_by_upstream_identity_ids([Ecto.UUID.t()], DateTime.t(), DateTime.t()) :: %{
          optional(Ecto.UUID.t()) => non_neg_integer()
        }
  def token_totals_by_upstream_identity_ids([], _started_at, _ended_at), do: %{}

  def token_totals_by_upstream_identity_ids(upstream_identity_ids, started_at, ended_at) do
    Repo.all(
      from entry in LedgerEntry,
        where:
          entry.upstream_identity_id in ^upstream_identity_ids and
            entry.entry_kind == ^@settlement and entry.amount_status == ^@recorded and
            entry.occurred_at >= ^started_at and entry.occurred_at <= ^ended_at,
        group_by: entry.upstream_identity_id,
        select:
          {entry.upstream_identity_id,
           sum(
             fragment(
               "CASE WHEN ? = ? THEN ? ELSE 0 END",
               entry.usage_status,
               ^@usage_known,
               entry.total_tokens
             )
           )}
    )
    |> Map.new(fn {upstream_identity_id, total} ->
      {upstream_identity_id, non_negative_integer(total)}
    end)
  end

  @spec token_usage_by_pool_ids([Ecto.UUID.t()], DateTime.t(), DateTime.t()) :: %{
          optional(Ecto.UUID.t()) => map()
        }
  def token_usage_by_pool_ids([], _started_at, _ended_at), do: %{}

  def token_usage_by_pool_ids(pool_ids, started_at, ended_at) do
    Repo.all(
      from entry in LedgerEntry,
        where:
          entry.pool_id in ^pool_ids and entry.entry_kind == ^@settlement and
            entry.amount_status == ^@recorded and entry.occurred_at >= ^started_at and
            entry.occurred_at <= ^ended_at,
        group_by: entry.pool_id,
        select:
          {entry.pool_id,
           %{
             cached_input_tokens:
               sum(
                 fragment(
                   "CASE WHEN ? = ? THEN ? ELSE 0 END",
                   entry.usage_status,
                   ^@usage_known,
                   entry.cached_input_tokens
                 )
               ),
             input_tokens:
               sum(
                 fragment(
                   "CASE WHEN ? = ? THEN ? ELSE 0 END",
                   entry.usage_status,
                   ^@usage_known,
                   entry.input_tokens
                 )
               ),
             output_tokens:
               sum(
                 fragment(
                   "CASE WHEN ? = ? THEN ? ELSE 0 END",
                   entry.usage_status,
                   ^@usage_known,
                   entry.output_tokens
                 )
               ),
             reasoning_tokens:
               sum(
                 fragment(
                   "CASE WHEN ? = ? THEN ? ELSE 0 END",
                   entry.usage_status,
                   ^@usage_known,
                   entry.reasoning_tokens
                 )
               ),
             total_tokens:
               sum(
                 fragment(
                   "CASE WHEN ? = ? THEN ? ELSE 0 END",
                   entry.usage_status,
                   ^@usage_known,
                   entry.total_tokens
                 )
               )
           }}
    )
    |> Map.new(fn {pool_id, usage} -> {pool_id, normalize_token_usage(usage)} end)
  end

  @spec daily_rollups_for_pool_ids([Ecto.UUID.t()], DateTime.t(), DateTime.t()) :: [map()]
  def daily_rollups_for_pool_ids([], _started_at, _ended_at), do: []

  def daily_rollups_for_pool_ids(pool_ids, started_at, ended_at) do
    start_date = DateTime.to_date(started_at)
    end_date = DateTime.to_date(ended_at)

    Repo.all(
      from rollup in DailyRollup,
        where:
          rollup.pool_id in ^pool_ids and rollup.rollup_date >= ^start_date and
            rollup.rollup_date <= ^end_date,
        order_by: [desc: rollup.rollup_date, asc: rollup.dimension_kind],
        select: %{
          rollup_date: rollup.rollup_date,
          dimension_kind: rollup.dimension_kind,
          pool_id: rollup.pool_id,
          request_count: rollup.request_count,
          success_count: rollup.success_count,
          failure_count: rollup.failure_count,
          total_tokens: rollup.total_tokens,
          estimated_cost_micros: rollup.estimated_cost_micros,
          settled_cost_micros: rollup.settled_cost_micros
        }
    )
  end

  @spec model_usage_buckets_for_pool_ids(
          [Ecto.UUID.t()],
          atom(),
          DateTime.t(),
          DateTime.t()
        ) :: model_usage_bucket_result()
  def model_usage_buckets_for_pool_ids(pool_ids, window, started_at, ended_at)

  def model_usage_buckets_for_pool_ids([], window, _started_at, _ended_at),
    do: %{source: model_usage_source(window), rows: []}

  def model_usage_buckets_for_pool_ids(pool_ids, :seven_days, started_at, ended_at) do
    start_date = DateTime.to_date(started_at)
    end_date = DateTime.to_date(ended_at)

    rows =
      Repo.all(
        from rollup in DailyRollup,
          left_join: model in Model,
          on: model.id == rollup.model_id and model.pool_id == rollup.pool_id,
          where:
            rollup.pool_id in ^pool_ids and rollup.dimension_kind == ^@model_dimension and
              not is_nil(rollup.model_id) and rollup.rollup_date >= ^start_date and
              rollup.rollup_date <= ^end_date,
          order_by: [asc: rollup.rollup_date, asc: model.exposed_model_id],
          select: %{
            bucket: rollup.rollup_date,
            model_code:
              fragment(
                "COALESCE(NULLIF(BTRIM(?), ''), ?)",
                model.exposed_model_id,
                ^@unknown_model_code
              ),
            request_count: rollup.request_count,
            input_tokens: rollup.input_tokens,
            cached_input_tokens: rollup.cached_input_tokens,
            output_tokens: rollup.output_tokens,
            reasoning_tokens: rollup.reasoning_tokens,
            total_tokens: rollup.total_tokens,
            estimated_cost_micros: rollup.estimated_cost_micros,
            settled_cost_micros: rollup.settled_cost_micros
          }
      )
      |> Enum.map(&normalize_model_usage_bucket/1)

    %{source: :daily_model_rollups, rows: rows}
  end

  def model_usage_buckets_for_pool_ids(pool_ids, _window, started_at, ended_at) do
    rows =
      Repo.all(
        from rollup in HourlyModelUsageRollup,
          where:
            rollup.pool_id in ^pool_ids and rollup.bucket_started_at > ^started_at and
              rollup.bucket_started_at <= ^ended_at,
          order_by: [asc: rollup.bucket_started_at, asc: rollup.model_code],
          select: %{
            bucket: rollup.bucket_started_at,
            model_code: rollup.model_code,
            request_count: rollup.request_count,
            input_tokens: rollup.input_tokens,
            cached_input_tokens: rollup.cached_input_tokens,
            output_tokens: rollup.output_tokens,
            reasoning_tokens: rollup.reasoning_tokens,
            total_tokens: rollup.total_tokens,
            estimated_cost_micros: rollup.estimated_cost_micros,
            settled_cost_micros: rollup.settled_cost_micros
          }
      )
      |> Enum.map(&normalize_model_usage_bucket/1)

    %{source: :hourly_model_usage_rollups, rows: rows}
  end

  defp normalize_token_usage(usage) when is_map(usage) do
    %{
      cached_input_tokens: non_negative_integer(usage.cached_input_tokens),
      input_tokens: non_negative_integer(usage.input_tokens),
      output_tokens: non_negative_integer(usage.output_tokens),
      reasoning_tokens: non_negative_integer(usage.reasoning_tokens),
      total_tokens: non_negative_integer(usage.total_tokens)
    }
  end

  defp normalize_model_usage_bucket(row) do
    %{
      bucket: row.bucket,
      model_code: normalize_model_code(row.model_code),
      request_count: non_negative_integer(row.request_count),
      input_tokens: non_negative_integer(row.input_tokens),
      cached_input_tokens: non_negative_integer(row.cached_input_tokens),
      output_tokens: non_negative_integer(row.output_tokens),
      reasoning_tokens: non_negative_integer(row.reasoning_tokens),
      total_tokens: non_negative_integer(row.total_tokens),
      estimated_cost_micros: non_negative_integer(row.estimated_cost_micros),
      settled_cost_micros: non_negative_integer(row.settled_cost_micros)
    }
  end

  defp model_usage_source(:seven_days), do: :daily_model_rollups
  defp model_usage_source(_window), do: :hourly_model_usage_rollups

  defp normalize_model_code(model_code) when is_binary(model_code) do
    case String.trim(model_code) do
      "" -> @unknown_model_code
      trimmed -> trimmed
    end
  end

  defp normalize_model_code(_model_code), do: @unknown_model_code

  defp non_negative_integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer()

  defp non_negative_integer(value) when is_integer(value), do: max(value, 0)
  defp non_negative_integer(value) when is_float(value), do: max(round(value), 0)
  defp non_negative_integer(_value), do: 0
end
