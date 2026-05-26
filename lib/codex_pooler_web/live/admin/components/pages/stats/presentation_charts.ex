defmodule CodexPoolerWeb.Admin.StatsPresentation.Charts do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :requests, :list, required: true
  attr :tokens, :list, required: true

  def traffic_charts(assigns) do
    assigns = assign(assigns, :chart, traffic_chart_model(assigns.requests, assigns.tokens))

    ~H"""
    <section class="grid min-w-0 gap-4">
      <section
        id="stats-traffic-chart"
        class="min-w-0 rounded-box border border-base-300 bg-base-100 p-4 shadow-sm"
      >
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div class="grid gap-1">
            <h2 id="stats-traffic-chart-heading" class="text-lg font-semibold text-base-content">
              Traffic over time
            </h2>
            <p id="stats-traffic-chart-summary" class="text-sm leading-6 text-base-content/70">
              Tokens and requests grouped by the selected range.
            </p>
          </div>
          <span id="stats-traffic-chart-total" class="font-mono text-sm font-semibold tabular-nums">
            {@chart.total_label}
          </span>
        </div>
        <div
          id="stats-traffic-chart-plot"
          class="admin-apex-bar-chart mt-4 w-full"
          phx-hook="ApexTimeSeriesChart"
          phx-update="ignore"
          role="img"
          aria-labelledby="stats-traffic-chart-title stats-traffic-chart-desc"
          data-chart-categories={@chart.categories}
          data-chart-series={@chart.series}
          data-chart-unit="tokens"
          data-chart-units={@chart.units}
          data-chart-yaxis={@chart.yaxis}
          data-chart-height="320"
          data-chart-colors={@chart.colors}
          data-chart-labels="true"
        >
        </div>
        <p id="stats-traffic-chart-title" class="sr-only">Traffic over time</p>
        <p id="stats-traffic-chart-desc" class="sr-only">{chart_description(@chart.points)}</p>
        <ul class="sr-only">
          <li :for={point <- @chart.points}>
            {point.label}: {point.tokens} tokens, {point.requests} requests
          </li>
        </ul>
      </section>
    </section>
    """
  end

  defp chart_description(points) do
    token_total = Enum.reduce(points, 0, &(&1.tokens + &2))
    request_total = Enum.reduce(points, 0, &(&1.requests + &2))

    "#{length(points)} time buckets with #{token_total} total tokens and #{request_total} total requests."
  end

  defp traffic_chart_model(request_rows, token_rows) do
    requests_by_label =
      Map.new(request_rows, fn row -> {format_bucket(row.bucket), max(row.requests || 0, 0)} end)

    tokens_by_label =
      Map.new(token_rows, fn row -> {format_bucket(row.bucket), max(row.total_tokens || 0, 0)} end)

    labels =
      (Enum.map(request_rows, &format_bucket(&1.bucket)) ++
         Enum.map(token_rows, &format_bucket(&1.bucket)))
      |> Enum.uniq()

    points =
      Enum.map(labels, fn label ->
        %{
          label: label,
          tokens: Map.get(tokens_by_label, label, 0),
          requests: Map.get(requests_by_label, label, 0)
        }
      end)

    token_values = Enum.map(points, & &1.tokens)
    request_values = Enum.map(points, & &1.requests)
    token_total = Enum.sum(token_values)
    request_total = Enum.sum(request_values)

    %{
      categories: Jason.encode!(labels),
      series:
        Jason.encode!([
          %{name: "Tokens", type: "column", data: token_values},
          %{name: "Requests", type: "line", data: request_values}
        ]),
      units: Jason.encode!(["tokens", "requests"]),
      yaxis:
        Jason.encode!([
          %{seriesName: "Tokens", title: "tokens"},
          %{seriesName: "Requests", title: "requests", opposite: true}
        ]),
      colors: Jason.encode!(["var(--color-primary)", "var(--color-info)"]),
      points: points,
      total_label:
        "#{format_integer(token_total)} tokens / #{format_integer(request_total)} requests"
    }
  end

  defp format_bucket(<<date::binary-size(10), "T", hour::binary-size(2), ":00:00Z">>),
    do: String.slice(date, 5, 5) <> " " <> hour <> ":00"

  defp format_bucket(
         <<_year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2)>>
       ),
       do: month <> "-" <> day

  defp format_bucket(bucket), do: to_string(bucket)

  defp format_integer(value) when is_integer(value), do: Integer.to_string(value)
  defp format_integer(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
end
