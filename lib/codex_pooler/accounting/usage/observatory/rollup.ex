defmodule CodexPooler.Accounting.Usage.Observatory.Rollup do
  @moduledoc false

  # Folds the single `(bucket_index, model_label)` grid (Queries.grid/2) into the
  # summary, per-bucket, per-model, and bucket-model shapes the presentation
  # consumes. Every grid metric is additive, so summing the grid reproduces the
  # four aggregate reads exactly without re-scanning the window four times. The
  # grid is tiny (<= bucket_count x distinct models), so the fold is in-memory.

  @metric_keys [
    :request_count,
    :succeeded,
    :failed,
    :in_progress,
    :settlement_count,
    :unknown_usage_count,
    :input_tokens,
    :cached_input_tokens,
    :output_tokens,
    :reasoning_tokens,
    :total_tokens,
    :settled_cost_micros,
    :settled_cost_count,
    :estimated_cost_micros,
    :estimated_cost_count,
    :unavailable_cost_count
  ]

  @model_limit 12

  @doc "Derive the summary/buckets/models/model_buckets shapes from the grid rows."
  def fold(grid) do
    rows = Enum.map(grid, &normalize/1)

    %{
      summary: sum_metrics(rows),
      buckets: buckets(rows),
      models: models(rows),
      model_buckets: model_buckets(rows)
    }
  end

  defp buckets(rows) do
    rows
    |> Enum.group_by(& &1.bucket_index)
    |> Enum.map(fn {bucket_index, grouped} ->
      Map.put(sum_metrics(grouped), :bucket_index, bucket_index)
    end)
    |> Enum.sort_by(& &1.bucket_index)
  end

  # Sort mirrors the old models query: desc tokens, desc requests, asc label, top 12.
  defp models(rows) do
    rows
    |> Enum.group_by(& &1.model_label)
    |> Enum.map(fn {label, grouped} ->
      totals = sum_metrics(grouped)

      %{
        label: label,
        request_count: totals.request_count,
        total_tokens: totals.total_tokens,
        settled_cost_micros: totals.settled_cost_micros,
        estimated_cost_micros: totals.estimated_cost_micros
      }
    end)
    |> Enum.sort_by(&{-&1.total_tokens, -&1.request_count, &1.label})
    |> Enum.take(@model_limit)
  end

  defp model_buckets(rows) do
    rows
    |> Enum.map(fn row ->
      %{
        bucket_index: row.bucket_index,
        model_label: row.model_label,
        total_tokens: row.total_tokens
      }
    end)
    |> Enum.sort_by(&{&1.bucket_index, &1.model_label})
  end

  defp sum_metrics(rows) do
    Map.new(@metric_keys, fn key ->
      {key, Enum.reduce(rows, 0, fn row, acc -> acc + Map.fetch!(row, key) end)}
    end)
  end

  defp normalize(row) do
    @metric_keys
    |> Map.new(fn key -> {key, to_integer(Map.get(row, key))} end)
    |> Map.put(:bucket_index, to_integer(Map.get(row, :bucket_index)))
    |> Map.put(:model_label, Map.get(row, :model_label))
  end

  defp to_integer(nil), do: 0
  defp to_integer(%Decimal{} = value), do: value |> Decimal.round(0) |> Decimal.to_integer()
  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_float(value), do: round(value)
end
