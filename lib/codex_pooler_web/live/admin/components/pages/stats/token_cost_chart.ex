defmodule CodexPoolerWeb.Admin.StatsPresentation.TokenCostChart do
  @moduledoc false

  alias CodexPoolerWeb.Admin.Format
  alias CodexPoolerWeb.Admin.StatsPresentation.BucketLabel

  @spec build([map()], [map()]) :: map()
  def build(token_rows, cost_rows) do
    tokens_by_label = Map.new(token_rows, fn row -> {BucketLabel.format(row.bucket), row} end)

    cost_by_label =
      Map.new(cost_rows, fn row ->
        {BucketLabel.format(row.bucket), max(row.settled_cost_micros || 0, 0)}
      end)

    labels =
      (Enum.map(token_rows, &BucketLabel.format(&1.bucket)) ++
         Enum.map(cost_rows, &BucketLabel.format(&1.bucket)))
      |> Enum.uniq()

    points = Enum.map(labels, &point(&1, tokens_by_label, cost_by_label))
    input_values = Enum.map(points, & &1.input_tokens)
    cached_input_values = Enum.map(points, & &1.cached_input_tokens)
    standard_output_values = Enum.map(points, & &1.standard_output_tokens)
    reasoning_values = Enum.map(points, & &1.reasoning_tokens)
    cost_values = Enum.map(points, & &1.cost_usd)
    token_total = points |> Enum.map(& &1.total_tokens) |> Enum.sum()
    cost_total = points |> Enum.map(& &1.cost_micros) |> Enum.sum()

    %{
      categories: Jason.encode!(labels),
      series:
        Jason.encode!([
          %{name: "Input", type: "column", data: input_values},
          %{name: "Cached input", type: "column", data: cached_input_values},
          %{name: "Output (standard)", type: "column", data: standard_output_values},
          %{name: "Reasoning", type: "column", data: reasoning_values},
          %{name: "Cost", type: "line", data: cost_values}
        ]),
      units: Jason.encode!(["tokens", "tokens", "tokens", "tokens", "USD"]),
      value_kinds: Jason.encode!(["tokens", "tokens", "tokens", "tokens", "usd"]),
      yaxis:
        Jason.encode!([
          %{
            seriesName: ["Input", "Cached input", "Output (standard)", "Reasoning"],
            title: "tokens",
            valueKind: "tokens"
          },
          %{seriesName: "Cost", title: "cost", opposite: true, valueKind: "usd"}
        ]),
      colors:
        Jason.encode!([
          "var(--color-primary)",
          "var(--color-secondary)",
          "var(--color-info)",
          "var(--color-warning)",
          "var(--color-success)"
        ]),
      points: points,
      total_label:
        "#{Format.token_count(token_total)} tokens / #{Format.money_from_micros(cost_total)}"
    }
  end

  @spec description([map()]) :: String.t()
  def description(points) do
    token_total = Enum.reduce(points, 0, &(&1.total_tokens + &2))
    cost_total = Enum.reduce(points, 0, &(&1.cost_micros + &2))

    "#{length(points)} time buckets with #{token_total} total tokens and #{Format.money_from_micros(cost_total)} total cost."
  end

  defp point(label, tokens_by_label, cost_by_label) do
    token_row = Map.get(tokens_by_label, label, %{})
    cost_micros = Map.get(cost_by_label, label, 0)
    output_tokens = chart_value(token_row, :output_tokens)
    reasoning_tokens = min(chart_value(token_row, :reasoning_tokens), output_tokens)

    %{
      label: label,
      input_tokens: chart_value(token_row, :uncached_input_tokens),
      cached_input_tokens: chart_value(token_row, :cached_input_tokens),
      output_tokens: output_tokens,
      standard_output_tokens: output_tokens - reasoning_tokens,
      reasoning_tokens: reasoning_tokens,
      total_tokens: chart_value(token_row, :total_tokens),
      cost_micros: cost_micros,
      cost_usd: cost_micros / 1_000_000
    }
  end

  defp chart_value(row, key), do: max(Map.get(row, key) || 0, 0)
end
