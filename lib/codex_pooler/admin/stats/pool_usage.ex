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
          | {:histogram_started_at, DateTime.t()}
          | {:histogram_pool_ids, [Ecto.UUID.t()]}
          | {:traffic_window, String.t() | atom()}
          | {:histogram_window, String.t() | atom()}
  @type pool_usage_summary :: %{
          required(:request_count) => non_neg_integer(),
          required(:tokens_per_second) => number() | nil,
          required(:total_tokens) => non_neg_integer(),
          required(:latency_ms) => non_neg_integer(),
          required(:token_usage) => map(),
          required(:settled_cost_micros) => non_neg_integer()
        }
  @type pool_usage_histogram :: %{
          required(:token_histogram) => [map()],
          required(:request_histogram) => [map()]
        }
  @type pool_usage_metrics :: %{
          required(:request_count) => non_neg_integer(),
          required(:tokens_per_second) => number() | nil,
          required(:total_tokens) => non_neg_integer(),
          required(:latency_ms) => non_neg_integer(),
          required(:token_usage) => map(),
          required(:settled_cost_micros) => non_neg_integer(),
          required(:token_histogram) => [map()],
          required(:request_histogram) => [map()]
        }
  @type pool_usage_result :: %{
          required(:summary_by_pool_id) => %{optional(Ecto.UUID.t()) => pool_usage_summary()},
          required(:histogram_by_pool_id) => %{
            optional(Ecto.UUID.t()) => pool_usage_histogram()
          }
        }

  @spec usage_by_pool_ids([Ecto.UUID.t()], [pool_usage_opt()]) :: pool_usage_result()
  def usage_by_pool_ids(pool_ids, opts) when is_list(pool_ids) and is_list(opts) do
    pool_ids = pool_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()
    histogram_pool_ids = eligible_histogram_pool_ids(pool_ids, opts)
    ended_at = Keyword.get_lazy(opts, :as_of, &now/0)
    window = pool_window(opts)

    started_at =
      Keyword.get(
        opts,
        :started_at,
        pool_default_started_at(ended_at, window)
      )

    histogram_started_at = Keyword.get(opts, :histogram_started_at, started_at)

    %{
      summary_by_pool_id: pool_summaries(pool_ids, started_at, ended_at),
      histogram_by_pool_id:
        pool_histograms(
          histogram_pool_ids,
          histogram_started_at,
          ended_at,
          window
        )
    }
  end

  def usage_by_pool_ids(_pool_ids, _opts),
    do: %{summary_by_pool_id: %{}, histogram_by_pool_id: %{}}

  @spec metrics_by_pool_ids([Ecto.UUID.t()], [pool_usage_opt()]) :: %{
          optional(Ecto.UUID.t()) => pool_usage_metrics()
        }
  def metrics_by_pool_ids(pool_ids, opts) when is_list(pool_ids) and is_list(opts) do
    pool_ids = pool_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()
    result = usage_by_pool_ids(pool_ids, Keyword.put(opts, :histogram_pool_ids, pool_ids))

    Map.new(pool_ids, fn pool_id ->
      {pool_id,
       result.summary_by_pool_id
       |> Map.fetch!(pool_id)
       |> Map.merge(Map.fetch!(result.histogram_by_pool_id, pool_id))}
    end)
  end

  def metrics_by_pool_ids(_pool_ids, _opts), do: %{}

  defp eligible_histogram_pool_ids(pool_ids, opts) do
    authorized_ids = MapSet.new(pool_ids)

    opts
    |> Keyword.get(:histogram_pool_ids, [])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(authorized_ids, &1))
  end

  defp pool_summaries(pool_ids, started_at, ended_at) do
    request_counts = GatewayReadModel.request_counts_by_pool_ids(pool_ids, started_at, ended_at)
    token_totals = AccountingReporting.token_totals_by_pool_ids(pool_ids, started_at, ended_at)
    latency_totals = GatewayReadModel.latency_totals_by_pool_ids(pool_ids, started_at, ended_at)
    token_usage = AccountingReporting.token_usage_by_pool_ids(pool_ids, started_at, ended_at)

    cost_micros =
      AccountingReporting.settled_cost_totals_by_pool_ids(pool_ids, started_at, ended_at)

    Map.new(pool_ids, fn pool_id ->
      total_tokens = Map.get(token_totals, pool_id, 0)
      latency_ms = Map.get(latency_totals, pool_id, 0)

      {pool_id,
       %{
         request_count: Map.get(request_counts, pool_id, 0),
         tokens_per_second: pool_tokens_per_second(total_tokens, latency_ms),
         total_tokens: total_tokens,
         latency_ms: latency_ms,
         token_usage: Map.get(token_usage, pool_id, Aggregates.empty_token_usage()),
         settled_cost_micros: Map.get(cost_micros, pool_id, 0)
       }}
    end)
  end

  defp pool_histograms([], _started_at, _ended_at, _window), do: %{}

  defp pool_histograms(pool_ids, started_at, ended_at, window) do
    settlement_usage_buckets =
      AccountingReporting.settlement_usage_buckets_for_pool_ids(
        pool_ids,
        pool_bucket_granularity(window),
        started_at,
        ended_at
      )

    token_histograms = pool_token_histograms(pool_ids, settlement_usage_buckets, ended_at, window)

    request_histograms =
      pool_request_histograms(
        pool_ids,
        GatewayReadModel.bucketed_request_counts_by_pool_ids(
          pool_ids,
          started_at,
          ended_at,
          pool_bucket_granularity(window)
        ),
        ended_at,
        window
      )

    Map.new(pool_ids, fn pool_id ->
      {pool_id,
       %{
         token_histogram: Map.fetch!(token_histograms, pool_id),
         request_histogram: Map.fetch!(request_histograms, pool_id)
       }}
    end)
  end

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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
