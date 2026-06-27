defmodule CodexPooler.Admin.Stats.Charts do
  @moduledoc false

  alias CodexPooler.Admin.Stats.Aggregates
  alias CodexPooler.Admin.Stats.Buckets

  @succeeded "succeeded"
  @failed_statuses ~w(failed rejected interrupted cancelled)

  @spec request_series([map()], map()) :: [map()]
  def request_series(requests, normalized) do
    buckets = Buckets.labels(normalized)
    grouped = Enum.group_by(requests, &Buckets.label(&1.admitted_at, normalized.window))

    Enum.map(buckets, fn label ->
      rows = Map.get(grouped, label, [])

      %{
        bucket: label,
        requests: length(rows),
        succeeded: Enum.count(rows, &(&1.status == @succeeded)),
        failed: Enum.count(rows, &(&1.status in @failed_statuses))
      }
    end)
  end

  @spec token_series([map()], map()) :: [map()]
  def token_series(settlements, normalized) do
    buckets = Buckets.labels(normalized)
    grouped = Enum.group_by(settlements, &Buckets.label(&1.occurred_at, normalized.window))

    Enum.map(buckets, fn label ->
      entries = Map.get(grouped, label, [])

      input_tokens = Aggregates.sum_integer(entries, :input_tokens)
      cached_input_tokens = Aggregates.sum_integer(entries, :cached_input_tokens)

      %{
        bucket: label,
        input_tokens: input_tokens,
        cached_input_tokens: cached_input_tokens,
        uncached_input_tokens: max(input_tokens - cached_input_tokens, 0),
        output_tokens: Aggregates.sum_integer(entries, :output_tokens),
        reasoning_tokens: Aggregates.sum_integer(entries, :reasoning_tokens),
        total_tokens: Aggregates.sum_integer(entries, :total_tokens)
      }
    end)
  end

  @spec cost_series([map()], map()) :: [map()]
  def cost_series(settlements, normalized) do
    buckets = Buckets.labels(normalized)
    grouped = Enum.group_by(settlements, &Buckets.label(&1.occurred_at, normalized.window))

    Enum.map(buckets, fn label ->
      entries = Map.get(grouped, label, [])

      %{
        bucket: label,
        settled_cost_micros: Aggregates.sum_decimal_integer(entries, :settled_cost_micros)
      }
    end)
  end

  @spec model_usage_series([map()], map()) :: [map()]
  def model_usage_series(rows, normalized) do
    buckets = Buckets.labels(normalized)
    bucket_set = MapSet.new(buckets)

    bucketed_rows =
      rows
      |> Enum.map(&normalize_model_usage_bucket(&1, normalized.window))
      |> Enum.filter(&(&1.bucket in bucket_set and &1.model_code != ""))
      |> aggregate_model_usage_rows()

    ranked_models =
      bucketed_rows
      |> model_usage_totals()
      |> Enum.filter(&(&1.total_tokens > 0))
      |> Enum.sort_by(fn row -> {-row.total_tokens, -row.request_count, row.model_code} end)

    top_model_codes =
      ranked_models
      |> Enum.take(5)
      |> Enum.map(& &1.model_code)

    other_model_codes =
      ranked_models
      |> Enum.drop(5)
      |> Enum.map(& &1.model_code)

    top_rows =
      Enum.flat_map(top_model_codes, fn model_code ->
        model_usage_rows_for_model(bucketed_rows, buckets, model_code)
      end)

    case other_model_codes do
      [] ->
        top_rows

      _other_model_codes ->
        top_rows ++ model_usage_rows_for_other(bucketed_rows, buckets, other_model_codes)
    end
  end

  defp normalize_model_usage_bucket(row, window) do
    %{
      bucket: Buckets.model_usage_bucket_label(row.bucket, window),
      model_code: row.model_code || "",
      request_count: model_usage_integer(row, :request_count),
      input_tokens: model_usage_integer(row, :input_tokens),
      cached_input_tokens: model_usage_integer(row, :cached_input_tokens),
      output_tokens: model_usage_integer(row, :output_tokens),
      reasoning_tokens: model_usage_integer(row, :reasoning_tokens),
      total_tokens: model_usage_integer(row, :total_tokens),
      estimated_cost_micros: model_usage_integer(row, :estimated_cost_micros),
      settled_cost_micros: model_usage_integer(row, :settled_cost_micros)
    }
  end

  defp model_usage_integer(row, field), do: Map.get(row, field) || 0

  defp aggregate_model_usage_rows(rows) do
    rows
    |> Enum.group_by(&{&1.model_code, &1.bucket})
    |> Map.new(fn {{model_code, bucket}, bucket_rows} ->
      {{model_code, bucket}, aggregate_model_usage_row(model_code, bucket, bucket_rows)}
    end)
  end

  defp model_usage_totals(bucketed_rows) do
    bucketed_rows
    |> Map.values()
    |> Enum.group_by(& &1.model_code)
    |> Enum.map(fn {model_code, rows} ->
      %{
        model_code: model_code,
        request_count: Aggregates.sum_integer(rows, :request_count),
        total_tokens: Aggregates.sum_integer(rows, :total_tokens)
      }
    end)
  end

  defp model_usage_rows_for_model(bucketed_rows, buckets, model_code) do
    Enum.map(buckets, fn bucket ->
      Map.get(bucketed_rows, {model_code, bucket}, empty_model_usage_row(model_code, bucket))
    end)
  end

  defp model_usage_rows_for_other(bucketed_rows, buckets, other_model_codes) do
    other_model_codes = MapSet.new(other_model_codes)

    Enum.map(buckets, fn bucket ->
      rows =
        bucketed_rows
        |> Map.values()
        |> Enum.filter(&(&1.bucket == bucket and &1.model_code in other_model_codes))

      aggregate_model_usage_row("Other", bucket, rows)
    end)
  end

  defp aggregate_model_usage_row(model_code, bucket, rows) do
    %{
      bucket: bucket,
      model_code: model_code,
      request_count: Aggregates.sum_integer(rows, :request_count),
      input_tokens: Aggregates.sum_integer(rows, :input_tokens),
      cached_input_tokens: Aggregates.sum_integer(rows, :cached_input_tokens),
      output_tokens: Aggregates.sum_integer(rows, :output_tokens),
      reasoning_tokens: Aggregates.sum_integer(rows, :reasoning_tokens),
      total_tokens: Aggregates.sum_integer(rows, :total_tokens),
      estimated_cost_micros: Aggregates.sum_integer(rows, :estimated_cost_micros),
      settled_cost_micros: Aggregates.sum_integer(rows, :settled_cost_micros)
    }
  end

  defp empty_model_usage_row(model_code, bucket) do
    aggregate_model_usage_row(model_code, bucket, [])
  end
end
