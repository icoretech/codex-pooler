defmodule CodexPoolerWeb.Admin.StatsPresentation.Charts do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Format

  @model_colors [
    "var(--color-primary)",
    "var(--color-secondary)",
    "var(--color-info)",
    "var(--color-success)",
    "var(--color-warning)"
  ]

  attr :requests, :list, required: true
  attr :tokens, :list, required: true
  attr :costs, :list, required: true
  attr :model_usage, :list, default: []

  def traffic_charts(assigns) do
    model_usage = Map.get(assigns, :model_usage, [])

    assigns =
      assigns
      |> assign(
        :traffic_chart,
        traffic_chart_model(assigns.requests, assigns.tokens, model_usage)
      )
      |> assign(:token_cost_chart, token_cost_chart_model(assigns.tokens, assigns.costs))

    ~H"""
    <section id="stats-traffic-charts" class="grid min-w-0 gap-3 lg:gap-4 xl:grid-cols-2">
      <section
        id="stats-traffic-chart"
        class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100"
      >
        <header class="flex flex-wrap items-center justify-between gap-2 border-b border-base-300 bg-base-200/35 px-4 py-3">
          <div data-role="chart-heading-group" class="min-w-0">
            <h2
              id="stats-traffic-chart-heading"
              class="text-base font-semibold leading-5 text-base-content"
            >
              Traffic over time
            </h2>
            <span
              id="stats-traffic-chart-total"
              class="mt-0.5 block text-xs font-medium tabular-nums text-base-content/70"
            >
              {@traffic_chart.total_label}
            </span>
          </div>
          <.chart_mode_control chart_id="stats-traffic-chart" label="Traffic chart mode" />
        </header>
        <div
          id="stats-traffic-chart-scroll"
          class="min-w-0 overflow-x-auto overscroll-x-contain p-3 pb-2 sm:p-4 sm:pb-2"
          data-role="chart-scroll-region"
        >
          <div
            id="stats-traffic-chart-plot"
            class="admin-apex-bar-chart admin-chart-mobile-wide w-full"
            phx-hook="ApexTimeSeriesChart"
            phx-update="ignore"
            role="group"
            aria-labelledby="stats-traffic-chart-title"
            aria-describedby="stats-traffic-chart-desc stats-traffic-chart-mode-description"
            data-chart-categories={@traffic_chart.categories}
            data-chart-series={@traffic_chart.series}
            data-chart-unit="tokens"
            data-chart-units={@traffic_chart.units}
            data-chart-value-kinds={@traffic_chart.value_kinds}
            data-chart-yaxis={@traffic_chart.yaxis}
            data-chart-height="292"
            data-chart-colors={@traffic_chart.colors}
            data-chart-legend="always"
            data-chart-safe-tooltip="true"
            data-chart-stacked="true"
            data-chart-bar-radius="0"
            data-chart-zoom="false"
            data-chart-wheel-scroll="page"
            data-chart-mode-control="stats-traffic-chart-mode-control"
            data-chart-mode-description="stats-traffic-chart-mode-description"
          >
          </div>
        </div>
        <p id="stats-traffic-chart-title" class="sr-only">Traffic over time</p>
        <p id="stats-traffic-chart-desc" class="sr-only">
          {traffic_chart_description(@traffic_chart.points)}
        </p>
        <p id="stats-traffic-chart-mode-description" class="sr-only" aria-live="polite">
          Showing interval values for each time bucket.
        </p>
        <ul
          id="stats-traffic-chart-interval-values"
          class="sr-only"
          data-chart-source="interval"
          aria-label="Underlying interval values for Traffic over time"
        >
          <li :for={point <- @traffic_chart.points}>
            {point.label}: {point.tokens} tokens, {point.requests} requests
          </li>
        </ul>
      </section>

      <section
        id="stats-token-cost-chart"
        class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100"
      >
        <header class="flex flex-wrap items-center justify-between gap-2 border-b border-base-300 bg-base-200/35 px-4 py-3">
          <div data-role="chart-heading-group" class="min-w-0">
            <h2
              id="stats-token-cost-chart-heading"
              class="text-base font-semibold leading-5 text-base-content"
            >
              Tokens vs cost
            </h2>
            <span
              id="stats-token-cost-chart-total"
              class="mt-0.5 block text-xs font-medium tabular-nums text-base-content/70"
            >
              {@token_cost_chart.total_label}
            </span>
          </div>
          <.chart_mode_control chart_id="stats-token-cost-chart" label="Tokens vs cost chart mode" />
        </header>
        <div
          id="stats-token-cost-chart-scroll"
          class="min-w-0 overflow-x-auto overscroll-x-contain p-3 pb-2 sm:p-4 sm:pb-2"
          data-role="chart-scroll-region"
        >
          <div
            id="stats-token-cost-chart-plot"
            class="admin-apex-bar-chart admin-chart-mobile-wide w-full"
            phx-hook="ApexTimeSeriesChart"
            phx-update="ignore"
            role="group"
            aria-labelledby="stats-token-cost-chart-title"
            aria-describedby="stats-token-cost-chart-desc stats-token-cost-chart-mode-description"
            data-chart-categories={@token_cost_chart.categories}
            data-chart-series={@token_cost_chart.series}
            data-chart-unit="tokens"
            data-chart-units={@token_cost_chart.units}
            data-chart-value-kinds={@token_cost_chart.value_kinds}
            data-chart-yaxis={@token_cost_chart.yaxis}
            data-chart-bar-radius="0"
            data-chart-height="292"
            data-chart-colors={@token_cost_chart.colors}
            data-chart-legend="true"
            data-chart-stacked="true"
            data-chart-zoom="false"
            data-chart-wheel-scroll="page"
            data-chart-mode-control="stats-token-cost-chart-mode-control"
            data-chart-mode-description="stats-token-cost-chart-mode-description"
          >
          </div>
        </div>
        <p id="stats-token-cost-chart-title" class="sr-only">Tokens vs cost</p>
        <p id="stats-token-cost-chart-desc" class="sr-only">
          {token_cost_chart_description(@token_cost_chart.points)}
        </p>
        <p id="stats-token-cost-chart-mode-description" class="sr-only" aria-live="polite">
          Showing interval values for each time bucket.
        </p>
        <ul
          id="stats-token-cost-chart-interval-values"
          class="sr-only"
          data-chart-source="interval"
          aria-label="Underlying interval values for Tokens vs cost"
        >
          <li :for={point <- @token_cost_chart.points}>
            {point.label}: {point.total_tokens} tokens, {point.cached_input_tokens} cached input tokens, {point.standard_output_tokens} standard output tokens, {point.reasoning_tokens} reasoning tokens, {Format.money_from_micros(
              point.cost_micros
            )} cost
          </li>
        </ul>
      </section>
    </section>
    """
  end

  attr :chart_id, :string, required: true
  attr :label, :string, required: true

  defp chart_mode_control(assigns) do
    assigns = assign(assigns, :modes, [{"Interval", "interval"}, {"Cumulative", "cumulative"}])

    ~H"""
    <div
      id={"#{@chart_id}-mode-control"}
      class="flex shrink-0 items-center gap-0.5 rounded-full border border-base-300 bg-base-200/60 p-0.5"
      role="group"
      aria-label={@label}
    >
      <button
        :for={{label, mode} <- @modes}
        id={"#{@chart_id}-mode-#{mode}"}
        type="button"
        class="cursor-pointer rounded-full border border-transparent px-2.5 py-0.5 text-[11px] font-medium leading-4 text-base-content/70 transition-colors hover:text-base-content aria-pressed:border-base-300 aria-pressed:bg-base-100 aria-pressed:text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        data-chart-mode={mode}
        aria-controls={"#{@chart_id}-plot"}
        aria-pressed={to_string(mode == "interval")}
        phx-click={JS.dispatch("chart:set-mode", to: "##{@chart_id}-plot", detail: %{mode: mode})}
      >
        {label}
      </button>
    </div>
    """
  end

  defp traffic_chart_description(points) do
    token_total = Enum.reduce(points, 0, &(&1.tokens + &2))
    request_total = Enum.reduce(points, 0, &(&1.requests + &2))

    "#{length(points)} time buckets with #{token_total} total tokens and #{request_total} total requests. Requests counts every admitted request status. Other models, when present, combines positive-token usage outside the top five."
  end

  defp token_cost_chart_description(points) do
    token_total = Enum.reduce(points, 0, &(&1.total_tokens + &2))
    cost_total = Enum.reduce(points, 0, &(&1.cost_micros + &2))

    "#{length(points)} time buckets with #{token_total} total tokens and #{Format.money_from_micros(cost_total)} total cost."
  end

  defp traffic_chart_model(request_rows, token_rows, model_usage_rows) do
    requests_by_label =
      Map.new(request_rows, fn row -> {format_bucket(row.bucket), max(row.requests || 0, 0)} end)

    tokens_by_label =
      Map.new(token_rows, fn row -> {format_bucket(row.bucket), max(row.total_tokens || 0, 0)} end)

    labels =
      (Enum.map(request_rows, &format_bucket(&1.bucket)) ++
         Enum.map(token_rows, &format_bucket(&1.bucket)) ++
         Enum.map(model_usage_rows, &format_bucket(&1.bucket)))
      |> Enum.uniq()

    request_values = Enum.map(labels, &Map.get(requests_by_label, &1, 0))
    model_series = model_traffic_series(model_usage_rows, labels)

    {column_series, token_values, token_axis_series, colors} =
      case model_series do
        [] ->
          token_values = Enum.map(labels, &Map.get(tokens_by_label, &1, 0))

          {[%{name: "Tokens", type: "column", data: token_values}], token_values, "Tokens",
           ["var(--color-primary)", "var(--admin-chart-requests)"]}

        model_series ->
          token_values = model_series |> Enum.map(& &1.data) |> Enum.zip_with(&Enum.sum/1)
          model_names = Enum.map(model_series, & &1.name)

          {model_series, token_values, model_names,
           model_series_colors(model_series) ++ ["var(--admin-chart-requests)"]}
      end

    points =
      labels
      |> Enum.zip(Enum.zip(token_values, request_values))
      |> Enum.map(fn {label, {tokens, requests}} ->
        %{
          label: label,
          tokens: tokens,
          requests: requests
        }
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

  defp model_traffic_series(model_usage_rows, labels) do
    model_codes = model_usage_rows |> Enum.map(& &1.model_code) |> Enum.uniq()

    rows_by_model_and_label =
      Map.new(model_usage_rows, fn row -> {{row.model_code, format_bucket(row.bucket)}, row} end)

    model_codes
    |> Enum.map(fn model_code ->
      data =
        Enum.map(labels, fn label ->
          rows_by_model_and_label
          |> Map.get({model_code, label}, %{})
          |> chart_value(:total_tokens)
        end)

      %{name: chart_series_name(model_code), type: "column", data: data}
    end)
    |> Enum.filter(fn series -> Enum.any?(series.data, &(&1 > 0)) end)
  end

  defp token_cost_chart_model(token_rows, cost_rows) do
    tokens_by_label = Map.new(token_rows, fn row -> {format_bucket(row.bucket), row} end)

    cost_by_label =
      Map.new(cost_rows, fn row ->
        {format_bucket(row.bucket), max(row.settled_cost_micros || 0, 0)}
      end)

    labels =
      (Enum.map(token_rows, &format_bucket(&1.bucket)) ++
         Enum.map(cost_rows, &format_bucket(&1.bucket)))
      |> Enum.uniq()

    points =
      Enum.map(labels, fn label ->
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
          cost_usd: micros_to_usd(cost_micros)
        }
      end)

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

  defp chart_series_name(nil), do: ""
  defp chart_series_name("Other"), do: "Other models"

  defp chart_series_name(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp chart_value(row, key), do: max(Map.get(row, key) || 0, 0)

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

  defp micros_to_usd(micros) when is_integer(micros) do
    micros / 1_000_000
  end

  defp format_bucket(<<date::binary-size(10), "T", hour::binary-size(2), ":00:00Z">>),
    do: String.slice(date, 5, 5) <> " " <> hour <> ":00"

  defp format_bucket(
         <<_year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2)>>
       ),
       do: month <> "-" <> day

  defp format_bucket(bucket), do: to_string(bucket)
end
