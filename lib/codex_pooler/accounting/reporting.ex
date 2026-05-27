defmodule CodexPooler.Accounting.Reporting do
  @moduledoc """
  Read-only accounting projections for admin/reporting surfaces.
  """

  import Ecto.Query

  alias CodexPooler.Accounting.{DailyRollup, LedgerEntry}
  alias CodexPooler.Repo

  @settlement "settlement"
  @recorded "recorded"

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
          input_tokens: entry.input_tokens,
          cached_input_tokens: entry.cached_input_tokens,
          output_tokens: entry.output_tokens,
          reasoning_tokens: entry.reasoning_tokens,
          total_tokens: entry.total_tokens,
          estimated_cost_micros: entry.estimated_cost_micros,
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
        select: {entry.pool_id, sum(entry.total_tokens)}
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
        select: {entry.upstream_identity_id, sum(entry.total_tokens)}
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
             cached_input_tokens: sum(entry.cached_input_tokens),
             input_tokens: sum(entry.input_tokens),
             output_tokens: sum(entry.output_tokens),
             reasoning_tokens: sum(entry.reasoning_tokens),
             total_tokens: sum(entry.total_tokens)
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
          estimated_cost_micros: rollup.estimated_cost_micros
        }
    )
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

  defp non_negative_integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer()

  defp non_negative_integer(value) when is_integer(value), do: max(value, 0)
  defp non_negative_integer(value) when is_float(value), do: max(round(value), 0)
  defp non_negative_integer(_value), do: 0
end
