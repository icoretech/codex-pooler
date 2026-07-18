defmodule CodexPooler.Accounting.Usage.Observatory.Presentation do
  @moduledoc false

  def build(window, summary, sparse_buckets, models, outcomes, model_buckets \\ []) do
    summary = normalize_row(summary)
    normalized_buckets = buckets(window, sparse_buckets)

    %{
      window: Map.take(window, [:key, :started_at, :ended_at, :bucket_seconds, :bucket_count]),
      totals: totals(summary),
      accounting: accounting(summary),
      buckets: normalized_buckets,
      model_buckets: model_bucket_rows(model_buckets),
      trends: trends(normalized_buckets),
      models: model_distribution(models, summary.total_tokens),
      outcomes: Enum.map(outcomes, &outcome/1)
    }
  end

  defp model_bucket_rows(rows) when is_list(rows) do
    Enum.map(rows, fn row ->
      %{
        bucket_index: integer(Map.get(row, :bucket_index)),
        label: Map.get(row, :model_label),
        total_tokens: integer(Map.get(row, :total_tokens))
      }
    end)
  end

  defp model_bucket_rows(_rows), do: []

  defp totals(row) do
    %{
      requests: request_counts(row),
      tokens: token_counts(row),
      cache_rate_percent: percentage(row.cached_input_tokens, row.input_tokens),
      cost: cost(row)
    }
  end

  defp request_counts(row) do
    %{
      total: integer(row.request_count),
      succeeded: integer(row.succeeded),
      failed: integer(row.failed),
      in_progress: integer(row.in_progress)
    }
  end

  defp token_counts(row) do
    %{
      input: integer(row.input_tokens),
      cached_input: integer(row.cached_input_tokens),
      output: integer(row.output_tokens),
      reasoning: integer(row.reasoning_tokens),
      total: integer(row.total_tokens)
    }
  end

  defp cost(row) do
    settled_count = integer(row.settled_cost_count)
    estimated_count = integer(row.estimated_cost_count)
    unavailable_count = integer(row.unavailable_cost_count)

    %{
      settled: money("settled", integer(row.settled_cost_micros), settled_count),
      estimated: money("estimated", integer(row.estimated_cost_micros), estimated_count),
      unavailable_requests: unavailable_count,
      confidence: cost_confidence(integer(row.request_count), estimated_count, unavailable_count)
    }
  end

  defp money(label, micros, count) when count > 0, do: %{status: label, micros: micros}
  defp money(_label, _micros, _count), do: %{status: "unavailable", micros: 0}

  defp cost_confidence(0, _estimated, _unavailable), do: "unavailable"
  defp cost_confidence(_requests, _estimated, unavailable) when unavailable > 0, do: "partial"
  defp cost_confidence(_requests, estimated, _unavailable) when estimated > 0, do: "estimated"
  defp cost_confidence(_requests, _estimated, _unavailable), do: "settled"

  defp accounting(row) do
    requests = integer(row.request_count)
    settlements = integer(row.settlement_count)
    missing = max(requests - settlements, 0)
    unknown = integer(row.unknown_usage_count)

    %{
      status: accounting_status(requests, missing, unknown),
      source: "recorded_ledger",
      recorded_settlements: settlements,
      missing_settlements: missing,
      unknown_usage: unknown,
      late_rollup_policy: "ledger_authoritative"
    }
  end

  defp accounting_status(0, _missing, _unknown), do: "missing"
  defp accounting_status(_requests, missing, _unknown) when missing > 0, do: "partial"
  defp accounting_status(_requests, _missing, unknown) when unknown > 0, do: "partial"
  defp accounting_status(_requests, _missing, _unknown), do: "complete"

  defp buckets(window, sparse_buckets) do
    rows = Map.new(sparse_buckets, &{&1.bucket_index, normalize_row(&1)})

    for index <- 0..(window.bucket_count - 1) do
      started_at = DateTime.add(window.started_at, index * window.bucket_seconds, :second)
      row = Map.get(rows, index, normalize_row(%{}))

      %{
        bucket_index: index,
        started_at: started_at,
        ended_at: DateTime.add(started_at, window.bucket_seconds, :second),
        requests: request_counts(row),
        tokens: token_counts(row),
        cost: cost(row)
      }
    end
  end

  defp trends(rows) do
    {previous, current} = half_windows(rows)

    %{
      success_rate: ratio_trend(previous, current, [:requests, :succeeded], [:requests, :total]),
      cache_rate: ratio_trend(previous, current, [:tokens, :cached_input], [:tokens, :input])
    }
  end

  defp half_windows(rows) do
    half_count = div(length(rows), 2)

    if half_count > 0 do
      {Enum.take(rows, half_count), Enum.take(rows, -half_count)}
    else
      {[], []}
    end
  end

  defp ratio_trend(previous, current, numerator_path, denominator_path) do
    previous_rate =
      percentage(sum_path(previous, numerator_path), sum_path(previous, denominator_path))

    current_rate =
      percentage(sum_path(current, numerator_path), sum_path(current, denominator_path))

    %{
      current: current_rate,
      previous: previous_rate,
      delta: difference(current_rate, previous_rate)
    }
  end

  defp sum_path(rows, path),
    do: Enum.reduce(rows, 0, fn row, total -> total + integer(get_in(row, path)) end)

  defp difference(current, previous) when is_number(current) and is_number(previous),
    do: Float.round(current - previous, 1)

  defp difference(_current, _previous), do: nil

  defp model_distribution(rows, total_tokens) do
    Enum.map(rows, fn row ->
      %{
        label: row.label,
        request_count: integer(row.request_count),
        total_tokens: integer(row.total_tokens),
        share_percent: percentage(row.total_tokens, total_tokens),
        cost_micros:
          integer(Map.get(row, :settled_cost_micros)) +
            integer(Map.get(row, :estimated_cost_micros))
      }
    end)
  end

  defp outcome(row) do
    cost =
      cond do
        integer(row.settled_cost_available) > 0 ->
          %{status: "settled", micros: integer(row.settled_cost_micros)}

        integer(row.estimated_cost_available) > 0 ->
          %{status: "estimated", micros: integer(row.estimated_cost_micros)}

        true ->
          %{status: "unavailable", micros: 0}
      end

    %{
      timestamp: row.timestamp,
      model: row.model,
      endpoint_class: row.endpoint_class,
      status: row.status,
      code: row.code,
      response_status_code: row.response_status_code,
      total_tokens: integer(row.total_tokens),
      cost: cost
    }
  end

  defp normalize_row(row) do
    defaults = %{
      request_count: 0,
      succeeded: 0,
      failed: 0,
      in_progress: 0,
      settlement_count: 0,
      unknown_usage_count: 0,
      input_tokens: 0,
      cached_input_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 0,
      settled_cost_micros: 0,
      settled_cost_count: 0,
      estimated_cost_micros: 0,
      estimated_cost_count: 0,
      unavailable_cost_count: 0
    }

    Map.merge(defaults, row || %{})
  end

  defp percentage(part, total) do
    total = integer(total)

    if total == 0 do
      nil
    else
      Float.round(integer(part) * 100 / total, 1)
    end
  end

  defp integer(%Decimal{} = value), do: value |> Decimal.round(0) |> Decimal.to_integer()
  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: round(value)
  defp integer(_value), do: 0
end
