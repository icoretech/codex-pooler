defmodule CodexPooler.Admin.Stats.PoolUsage do
  @moduledoc false

  alias CodexPooler.Accounting.Reporting, as: AccountingReporting
  alias CodexPooler.Admin.GatewayReadModel
  alias CodexPooler.Admin.Stats.Aggregates
  alias CodexPooler.Admin.Stats.Buckets

  @pool_default_window :twenty_four_hours
  @pool_windows %{
    "1h" => :one_hour,
    "5h" => :five_hours,
    "24h" => :twenty_four_hours,
    "7d" => :seven_days,
    one_hour: :one_hour,
    five_hours: :five_hours,
    twenty_four_hours: :twenty_four_hours,
    seven_days: :seven_days
  }

  @type pool_usage_opt ::
          {:as_of, DateTime.t()}
          | {:started_at, DateTime.t()}
          | {:weekly_started_at, DateTime.t()}
          | {:histogram_started_at, DateTime.t()}
          | {:traffic_window, String.t() | atom()}
          | {:histogram_window, String.t() | atom()}
  @type pool_usage_metrics :: %{
          required(:request_count) => non_neg_integer(),
          required(:tokens_per_second) => number() | nil,
          required(:total_tokens) => non_neg_integer(),
          required(:latency_ms) => non_neg_integer(),
          required(:token_usage) => map(),
          required(:token_usage_weekly) => map(),
          required(:token_histogram) => [map()],
          required(:request_histogram) => [map()],
          required(:settled_cost_micros) => non_neg_integer()
        }

  @spec metrics_by_pool_ids([Ecto.UUID.t()], [pool_usage_opt()]) :: %{
          optional(Ecto.UUID.t()) => pool_usage_metrics()
        }
  def metrics_by_pool_ids(pool_ids, opts) when is_list(pool_ids) and is_list(opts) do
    pool_ids = pool_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()
    ended_at = Keyword.get_lazy(opts, :as_of, &now/0)
    window = pool_window(opts)

    started_at =
      Keyword.get(
        opts,
        :started_at,
        pool_default_started_at(ended_at, window)
      )

    weekly_started_at = Keyword.get(opts, :weekly_started_at, DateTime.add(ended_at, -7, :day))

    request_counts = GatewayReadModel.request_counts_by_pool_ids(pool_ids, started_at, ended_at)
    token_totals = AccountingReporting.token_totals_by_pool_ids(pool_ids, started_at, ended_at)
    latency_totals = GatewayReadModel.latency_totals_by_pool_ids(pool_ids, started_at, ended_at)
    token_usage = AccountingReporting.token_usage_by_pool_ids(pool_ids, started_at, ended_at)

    token_usage_weekly =
      AccountingReporting.token_usage_by_pool_ids(pool_ids, weekly_started_at, ended_at)

    histogram_started_at =
      Keyword.get(
        opts,
        :histogram_started_at,
        started_at
      )

    settlement_usage_buckets =
      AccountingReporting.settlement_usage_buckets_for_pool_ids(
        pool_ids,
        pool_bucket_granularity(window),
        histogram_started_at,
        ended_at
      )

    token_histograms = pool_token_histograms(pool_ids, settlement_usage_buckets, ended_at, window)
    cost_micros = pool_settled_cost_micros(pool_ids, settlement_usage_buckets)

    request_histograms =
      pool_request_histograms(
        pool_ids,
        GatewayReadModel.bucketed_request_counts_by_pool_ids(
          pool_ids,
          histogram_started_at,
          ended_at,
          pool_bucket_granularity(window)
        ),
        ended_at,
        window
      )

    Enum.into(pool_ids, %{}, fn pool_id ->
      total_tokens = Map.get(token_totals, pool_id, 0)
      latency_ms = Map.get(latency_totals, pool_id, 0)
      tokens_per_second = pool_tokens_per_second(total_tokens, latency_ms)

      {pool_id,
       %{
         request_count: Map.get(request_counts, pool_id, 0),
         tokens_per_second: tokens_per_second,
         total_tokens: total_tokens,
         latency_ms: latency_ms,
         token_usage: Map.get(token_usage, pool_id, Aggregates.empty_token_usage()),
         token_usage_weekly: Map.get(token_usage_weekly, pool_id, Aggregates.empty_token_usage()),
         token_histogram: Map.fetch!(token_histograms, pool_id),
         request_histogram: Map.fetch!(request_histograms, pool_id),
         settled_cost_micros: Map.fetch!(cost_micros, pool_id)
       }}
    end)
  end

  def metrics_by_pool_ids(_pool_ids, _opts), do: %{}

  defp pool_tokens_per_second(total_tokens, latency_ms) when total_tokens > 0 and latency_ms > 0,
    do: Float.round(total_tokens / (latency_ms / 1000), 2)

  defp pool_tokens_per_second(_total_tokens, _latency_ms), do: nil

  defp pool_window(opts) do
    opts
    |> Keyword.get(:traffic_window, Keyword.get(opts, :histogram_window, @pool_default_window))
    |> then(&Map.get(@pool_windows, &1, @pool_default_window))
  end

  defp pool_window_seconds(:one_hour), do: 60 * 60
  defp pool_window_seconds(:five_hours), do: 5 * 60 * 60
  defp pool_window_seconds(:twenty_four_hours), do: 24 * 60 * 60

  defp pool_default_started_at(ended_at, :seven_days) do
    ended_at
    |> DateTime.to_date()
    |> Date.add(-6)
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  defp pool_default_started_at(ended_at, window) do
    DateTime.add(ended_at, -pool_window_seconds(window), :second)
  end

  defp pool_bucket_granularity(:seven_days), do: :day
  defp pool_bucket_granularity(_window), do: :hour

  defp pool_token_histograms(pool_ids, settlements, ended_at, window) do
    labels = Buckets.labels(%{window: window, ended_at: ended_at})

    entries_by_pool_bucket =
      Enum.group_by(settlements, fn settlement ->
        {settlement.pool_id, Buckets.label(settlement.bucket, window)}
      end)

    Map.new(pool_ids, fn pool_id ->
      rows =
        Enum.map(labels, fn label ->
          entries = Map.get(entries_by_pool_bucket, {pool_id, label}, [])

          %{
            bucket: label,
            total_tokens: Aggregates.sum_integer(entries, :total_tokens)
          }
        end)

      {pool_id, rows}
    end)
  end

  defp pool_request_histograms(pool_ids, request_counts, ended_at, window) do
    labels = Buckets.labels(%{window: window, ended_at: ended_at})

    requests_by_pool_bucket =
      Map.new(request_counts, fn row ->
        {{row.pool_id, Buckets.label(row.bucket, window)}, row.requests}
      end)

    Map.new(pool_ids, fn pool_id ->
      rows =
        Enum.map(labels, fn label ->
          %{
            bucket: label,
            requests: Map.get(requests_by_pool_bucket, {pool_id, label}, 0)
          }
        end)

      {pool_id, rows}
    end)
  end

  defp pool_settled_cost_micros(pool_ids, settlements) do
    entries_by_pool_id = Enum.group_by(settlements, & &1.pool_id)

    Map.new(pool_ids, fn pool_id ->
      entries = Map.get(entries_by_pool_id, pool_id, [])
      {pool_id, Aggregates.sum_decimal_integer(entries, :settled_cost_micros)}
    end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
