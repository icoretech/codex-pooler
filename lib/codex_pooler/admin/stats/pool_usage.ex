defmodule CodexPooler.Admin.Stats.PoolUsage do
  @moduledoc false

  alias CodexPooler.Accounting.Reporting, as: AccountingReporting
  alias CodexPooler.Admin.GatewayReadModel
  alias CodexPooler.Admin.Stats.Aggregates
  alias CodexPooler.Admin.Stats.Buckets

  @pool_default_window :twenty_four_hours
  @rollup_fallback_event [:codex_pooler, :admin, :pool_usage, :rollup_fallback]
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
          | {:force_raw, boolean()}
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
          },
          required(:source) => :daily_rollups_with_raw_tail | :raw_fallback
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

    if window == :seven_days and
         supported_rollup_bounds?(started_at, histogram_started_at, ended_at) and
         not Keyword.get(opts, :force_raw, false) do
      case seven_day_usage(pool_ids, histogram_pool_ids, started_at, ended_at) do
        {:ok, result} ->
          result

        {:fallback, reason} ->
          emit_rollup_fallback(reason, pool_ids, histogram_pool_ids)

          raw_usage(
            pool_ids,
            histogram_pool_ids,
            started_at,
            histogram_started_at,
            ended_at,
            window
          )
      end
    else
      raw_usage(pool_ids, histogram_pool_ids, started_at, histogram_started_at, ended_at, window)
    end
  end

  def usage_by_pool_ids(_pool_ids, _opts),
    do: %{summary_by_pool_id: %{}, histogram_by_pool_id: %{}, source: :raw_fallback}

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

  defp raw_usage(pool_ids, histogram_pool_ids, started_at, histogram_started_at, ended_at, window) do
    %{
      summary_by_pool_id: pool_summaries(pool_ids, started_at, ended_at),
      histogram_by_pool_id:
        pool_histograms(histogram_pool_ids, histogram_started_at, ended_at, window),
      source: :raw_fallback
    }
  end

  defp supported_rollup_bounds?(started_at, histogram_started_at, ended_at) do
    started_at == pool_default_started_at(ended_at, :seven_days) and
      histogram_started_at == started_at
  end

  defp seven_day_usage(pool_ids, histogram_pool_ids, started_at, ended_at) do
    today = DateTime.to_date(ended_at)
    completed_dates = Date.range(Date.add(today, -6), Date.add(today, -1)) |> Enum.to_list()
    current_day_started_at = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")

    case AccountingReporting.covered_pool_daily_usage_snapshot(pool_ids, completed_dates) do
      {:ok, rollups} ->
        tail_settlements =
          AccountingReporting.settlement_usage_buckets_for_pool_ids(
            pool_ids,
            :day,
            current_day_started_at,
            ended_at
          )

        tail_request_counts =
          GatewayReadModel.request_counts_by_pool_ids(
            pool_ids,
            current_day_started_at,
            ended_at
          )

        latency_totals =
          GatewayReadModel.latency_totals_by_pool_ids(pool_ids, started_at, ended_at)

        tail_request_buckets =
          if histogram_pool_ids == [] do
            []
          else
            GatewayReadModel.bucketed_request_counts_by_pool_ids(
              histogram_pool_ids,
              current_day_started_at,
              ended_at,
              :day
            )
          end

        {:ok,
         build_seven_day_usage(
           pool_ids,
           histogram_pool_ids,
           completed_dates,
           today,
           rollups,
           %{
             latency_totals: latency_totals,
             request_buckets: tail_request_buckets,
             request_counts: tail_request_counts,
             settlements: tail_settlements
           }
         )}

      {:fallback, :incomplete_coverage} ->
        {:fallback, :incomplete_coverage}

      {:error, :unavailable} ->
        {:fallback, :reporting_unavailable}
    end
  end

  defp emit_rollup_fallback(reason, pool_ids, histogram_pool_ids) do
    :telemetry.execute(
      @rollup_fallback_event,
      %{count: 1},
      %{
        reason: reason,
        pool_count: length(pool_ids),
        histogram_pool_count: length(histogram_pool_ids)
      }
    )
  end

  defp build_seven_day_usage(
         pool_ids,
         histogram_pool_ids,
         completed_dates,
         today,
         rollups,
         tail
       ) do
    rollups_by_key = Map.new(rollups, &{{&1.pool_id, &1.rollup_date}, &1})
    settlements_by_pool = Enum.group_by(tail.settlements, & &1.pool_id)
    request_buckets_by_pool = Enum.group_by(tail.request_buckets, & &1.pool_id)
    labels = Enum.map(completed_dates ++ [today], &Date.to_iso8601/1)

    summary_by_pool_id =
      Map.new(pool_ids, fn pool_id ->
        completed_rows =
          Enum.map(completed_dates, fn date ->
            Map.get(rollups_by_key, {pool_id, date}, empty_daily_rollup(pool_id, date))
          end)

        tail_rows = Map.get(settlements_by_pool, pool_id, [])
        usage = sum_daily_usage(completed_rows, tail_rows)
        latency_ms = Map.get(tail.latency_totals, pool_id, 0)

        {pool_id,
         %{
           request_count:
             sum_admitted_requests(completed_rows) + Map.get(tail.request_counts, pool_id, 0),
           tokens_per_second: pool_tokens_per_second(usage.total_tokens, latency_ms),
           total_tokens: usage.total_tokens,
           latency_ms: latency_ms,
           token_usage:
             Map.take(usage, [
               :cached_input_tokens,
               :input_tokens,
               :output_tokens,
               :reasoning_tokens,
               :total_tokens
             ]),
           settled_cost_micros: usage.settled_cost_micros
         }}
      end)

    histogram_by_pool_id =
      Map.new(histogram_pool_ids, fn pool_id ->
        completed_rows =
          Enum.map(completed_dates, fn date ->
            Map.get(rollups_by_key, {pool_id, date}, empty_daily_rollup(pool_id, date))
          end)

        tail_rows = Map.get(settlements_by_pool, pool_id, [])
        tail_request_rows = Map.get(request_buckets_by_pool, pool_id, [])

        token_by_label =
          Map.new(tail_rows, &{Date.to_iso8601(DateTime.to_date(&1.bucket)), &1.total_tokens})

        request_by_label =
          Map.new(tail_request_rows, &{Date.to_iso8601(DateTime.to_date(&1.bucket)), &1.requests})

        rollup_by_date = Map.new(completed_rows, &{Date.to_iso8601(&1.rollup_date), &1})

        {pool_id,
         %{
           token_histogram:
             Enum.map(labels, fn label ->
               row = Map.get(rollup_by_date, label)

               %{
                 bucket: label,
                 total_tokens:
                   Map.get(token_by_label, label, 0) +
                     non_negative(Map.get(row || %{}, :total_tokens, 0))
               }
             end),
           request_histogram:
             Enum.map(labels, fn label ->
               row = Map.get(rollup_by_date, label)

               %{
                 bucket: label,
                 requests:
                   Map.get(request_by_label, label, 0) +
                     non_negative(Map.get(row || %{}, :admitted_request_count, 0))
               }
             end)
         }}
      end)

    %{
      summary_by_pool_id: summary_by_pool_id,
      histogram_by_pool_id: histogram_by_pool_id,
      source: :daily_rollups_with_raw_tail
    }
  end

  defp sum_daily_usage(completed_rows, tail_rows) do
    completed_rows
    |> Enum.reduce(empty_usage_with_cost(), &add_daily_rollup_usage/2)
    |> then(fn acc -> Enum.reduce(tail_rows, acc, &add_tail_usage/2) end)
  end

  defp empty_usage_with_cost, do: Map.put(Aggregates.empty_token_usage(), :settled_cost_micros, 0)

  defp add_daily_rollup_usage(row, acc) do
    acc
    |> add_usage_fields(row)
    |> Map.update!(
      :settled_cost_micros,
      &(&1 + decimal_integer(Map.get(row, :rounded_settled_cost_micros)))
    )
  end

  defp add_tail_usage(row, acc) do
    acc
    |> add_usage_fields(row)
    |> Map.update!(:settled_cost_micros, &(&1 + non_negative(Map.get(row, :settled_cost_micros))))
  end

  defp add_usage_fields(acc, row) do
    Enum.reduce(
      [:cached_input_tokens, :input_tokens, :output_tokens, :reasoning_tokens, :total_tokens],
      acc,
      fn field, acc -> Map.update!(acc, field, &(&1 + non_negative(Map.get(row, field)))) end
    )
  end

  defp sum_admitted_requests(rows),
    do: Enum.reduce(rows, 0, &(&2 + non_negative(Map.get(&1, :admitted_request_count))))

  defp empty_daily_rollup(pool_id, date) do
    %{
      pool_id: pool_id,
      rollup_date: date,
      admitted_request_count: 0,
      input_tokens: 0,
      cached_input_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 0,
      rounded_settled_cost_micros: 0
    }
  end

  defp decimal_integer(%Decimal{} = value), do: value |> Decimal.round(0) |> Decimal.to_integer()
  defp decimal_integer(value), do: non_negative(value)
  defp non_negative(value) when is_integer(value), do: max(value, 0)
  defp non_negative(value) when is_float(value), do: max(round(value), 0)
  defp non_negative(_value), do: 0

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
