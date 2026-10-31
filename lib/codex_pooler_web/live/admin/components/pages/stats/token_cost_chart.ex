defmodule CodexPoolerWeb.Admin.StatsPresentation.TokenCostChart do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

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
    input_label = gettext("Input")
    cached_input_label = gettext("Cached input")
    output_label = gettext("Output (standard)")
    reasoning_label = gettext("Reasoning")
    cost_label = gettext("Cost")

    %{
      categories: CodexPooler.JSON.encode!(labels),
      series:
        CodexPooler.JSON.encode!([
          %{name: input_label, type: "column", data: input_values},
          %{name: cached_input_label, type: "column", data: cached_input_values},
          %{name: output_label, type: "column", data: standard_output_values},
          %{name: reasoning_label, type: "column", data: reasoning_values},
          %{name: cost_label, type: "line", data: cost_values}
        ]),
      units: CodexPooler.JSON.encode!(["tokens", "tokens", "tokens", "tokens", "USD"]),
      unit_labels: CodexPooler.JSON.encode!([gettext("tokens"), gettext("tokens"), gettext("tokens"), gettext("tokens"), "USD"]),
      value_kinds: CodexPooler.JSON.encode!(["tokens", "tokens", "tokens", "tokens", "usd"]),
      yaxis:
        CodexPooler.JSON.encode!([
          %{
            seriesName: [input_label, cached_input_label, output_label, reasoning_label],
            title: gettext("tokens"),
            valueKind: "tokens"
          },
          %{seriesName: cost_label, title: gettext("cost"), opposite: true, valueKind: "usd"}
        ]),
      colors:
        CodexPooler.JSON.encode!([
          "var(--color-primary)",
          "var(--color-secondary)",
          "var(--color-info)",
          "var(--color-warning)",
          "var(--color-success)"
        ]),
      points: points,
      total_label:
        gettext("%{tokens} / %{cost}",
          tokens: ngettext("%{tokens} token", "%{tokens} tokens", token_total, tokens: Format.token_count(token_total)),
          cost: Format.money_from_micros(cost_total)
        )
    }
  end

  @spec description([map()]) :: String.t()
  def description(points) do
    token_total = Enum.reduce(points, 0, &(&1.total_tokens + &2))
    cost_total = Enum.reduce(points, 0, &(&1.cost_micros + &2))

    tokens = ngettext("%{count} total token", "%{count} total tokens", token_total)

    ngettext("%{count} time bucket with %{tokens} and %{cost} total cost.", "%{count} time buckets with %{tokens} and %{cost} total cost.", length(points),
      tokens: tokens,
      cost: Format.money_from_micros(cost_total)
    )
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
