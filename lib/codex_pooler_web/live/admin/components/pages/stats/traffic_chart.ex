defmodule CodexPoolerWeb.Admin.StatsPresentation.TrafficChart do
  @moduledoc false

  alias CodexPoolerWeb.Admin.Format
  alias CodexPoolerWeb.Admin.StatsPresentation.BucketLabel

  @model_colors [
    "var(--color-primary)",
    "var(--color-secondary)",
    "var(--color-info)",
    "var(--color-success)",
    "var(--color-warning)"
  ]

  @spec build([map()], [map()], [map()]) :: map()
  def build(request_rows, token_rows, model_usage_rows) do
    requests_by_label =
      Map.new(request_rows, fn row ->
        {BucketLabel.format(row.bucket), max(row.requests || 0, 0)}
      end)

    tokens_by_label =
      Map.new(token_rows, fn row ->
        {BucketLabel.format(row.bucket), max(row.total_tokens || 0, 0)}
      end)

    labels =
      (Enum.map(request_rows, &BucketLabel.format(&1.bucket)) ++
         Enum.map(token_rows, &BucketLabel.format(&1.bucket)) ++
         Enum.map(model_usage_rows, &BucketLabel.format(&1.bucket)))
      |> Enum.uniq()

    request_values = Enum.map(labels, &Map.get(requests_by_label, &1, 0))
    model_series = model_series(model_usage_rows, labels)

    {column_series, token_values, token_axis_series, colors} =
      series_config(model_series, labels, tokens_by_label)

    points =
      labels
      |> Enum.zip(Enum.zip(token_values, request_values))
      |> Enum.map(fn {label, {tokens, requests}} ->
        %{label: label, tokens: tokens, requests: requests}
      end)

    token_total = Enum.sum(token_values)
    request_total = Enum.sum(request_values)
    series = column_series ++ [%{name: "Requests", type: "line", data: request_values}]

    %{
      categories: Jason.encode!(labels),
      series: Jason.encode!(series),
      units: Jason.encode!(List.duplicate("tokens", length(column_series)) ++ ["requests"]),
      value_kinds: Jason.encode!(List.duplicate("tokens", length(column_series)) ++ ["integer"]),
      yaxis:
        Jason.encode!([
          %{seriesName: token_axis_series, title: "tokens", valueKind: "tokens"},
          %{seriesName: "Requests", title: "requests", opposite: true, valueKind: "integer"}
        ]),
      colors: Jason.encode!(colors),
      points: points,
      total_label:
        "#{Format.token_count(token_total)} tokens / #{Format.integer(request_total)} requests"
    }
  end

  @spec description([map()]) :: String.t()
  def description(points) do
    token_total = Enum.reduce(points, 0, &(&1.tokens + &2))
    request_total = Enum.reduce(points, 0, &(&1.requests + &2))

    "#{length(points)} time buckets with #{token_total} total tokens and #{request_total} total requests. Requests counts every admitted request status. Other models, when present, combines positive-token usage outside the top five."
  end

  defp series_config([], labels, tokens_by_label) do
    token_values = Enum.map(labels, &Map.get(tokens_by_label, &1, 0))

    {[%{name: "Tokens", type: "column", data: token_values}], token_values, "Tokens",
     ["var(--color-primary)", "var(--admin-chart-requests)"]}
  end

  defp series_config(model_series, _labels, _tokens_by_label) do
    token_values = model_series |> Enum.map(& &1.data) |> Enum.zip_with(&Enum.sum/1)
    model_names = Enum.map(model_series, & &1.name)

    {model_series, token_values, model_names,
     model_series_colors(model_series) ++ ["var(--admin-chart-requests)"]}
  end

  defp model_series(model_usage_rows, labels) do
    model_codes = model_usage_rows |> Enum.map(& &1.model_code) |> Enum.uniq()

    rows_by_model_and_label =
      Map.new(model_usage_rows, fn row ->
        {{row.model_code, BucketLabel.format(row.bucket)}, row}
      end)

    model_codes
    |> Enum.map(fn model_code ->
      data =
        Enum.map(labels, fn label ->
          rows_by_model_and_label
          |> Map.get({model_code, label}, %{})
          |> chart_value(:total_tokens)
        end)

      %{name: series_name(model_code), type: "column", data: data}
    end)
    |> Enum.filter(fn series -> Enum.any?(series.data, &(&1 > 0)) end)
  end

  defp series_name(nil), do: ""
  defp series_name("Other"), do: "Other models"

  defp series_name(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp model_series_colors(model_series) do
    model_series
    |> Enum.with_index()
    |> Enum.map(fn
      {%{name: "Other models"}, _index} ->
        "var(--admin-chart-other-models)"

      {_series, index} ->
        Enum.at(@model_colors, index, "var(--color-accent)")
    end)
  end

  defp chart_value(row, key), do: max(Map.get(row, key) || 0, 0)
end
