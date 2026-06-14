defmodule CodexPoolerWeb.Admin.StatsPresentation.Charts do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Format

  attr :requests, :list, required: true
  attr :tokens, :list, required: true
  attr :costs, :list, required: true
  attr :model_usage, :list, default: []

  def traffic_charts(assigns) do
    model_usage = Map.get(assigns, :model_usage, [])

    assigns =
      assigns
      |> assign(:traffic_chart, traffic_chart_model(assigns.requests, assigns.tokens))
      |> assign(:token_cost_chart, token_cost_chart_model(assigns.tokens, assigns.costs))
      |> assign(:model_usage_chart, model_usage_chart_model(model_usage))

    ~H"""
    <section class="grid min-w-0 gap-3 lg:gap-4 2xl:grid-cols-2">
      <section
        id="stats-traffic-chart"
        class="min-w-0 rounded-box border border-base-300 bg-base-100 p-3 shadow-sm sm:p-4 2xl:col-span-2"
      >
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div class="grid gap-1">
            <h2 id="stats-traffic-chart-heading" class="text-base font-semibold text-base-content">
              Traffic over time
            </h2>
          </div>
          <span
            id="stats-traffic-chart-total"
            class="text-right text-xs font-semibold tabular-nums sm:text-sm"
          >
            {@traffic_chart.total_label}
          </span>
        </div>
        <div
          id="stats-traffic-chart-scroll"
          class="mt-3 min-w-0 overflow-x-auto overscroll-x-contain pb-1"
          data-role="chart-scroll-region"
        >
          <div
            id="stats-traffic-chart-plot"
            class="admin-apex-bar-chart admin-chart-mobile-wide w-full"
            phx-hook="ApexTimeSeriesChart"
            phx-update="ignore"
            role="img"
            aria-labelledby="stats-traffic-chart-title stats-traffic-chart-desc"
            data-chart-categories={@traffic_chart.categories}
            data-chart-series={@traffic_chart.series}
            data-chart-unit="tokens"
            data-chart-units={@traffic_chart.units}
            data-chart-value-kinds={@traffic_chart.value_kinds}
            data-chart-yaxis={@traffic_chart.yaxis}
            data-chart-height="260"
            data-chart-colors={@traffic_chart.colors}
            data-chart-labels="true"
            data-chart-legend="false"
          >
          </div>
        </div>
        <p id="stats-traffic-chart-title" class="sr-only">Traffic over time</p>
        <p id="stats-traffic-chart-desc" class="sr-only">
          {traffic_chart_description(@traffic_chart.points)}
        </p>
        <ul class="sr-only">
          <li :for={point <- @traffic_chart.points}>
            {point.label}: {point.tokens} tokens, {point.requests} requests
          </li>
        </ul>
      </section>

      <section
        id="stats-token-cost-chart"
        class="min-w-0 rounded-box border border-base-300 bg-base-100 p-3 shadow-sm sm:p-4"
      >
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div class="grid gap-1">
            <h2 id="stats-token-cost-chart-heading" class="text-base font-semibold text-base-content">
              Tokens vs cost
            </h2>
          </div>
          <span
            id="stats-token-cost-chart-total"
            class="text-right text-xs font-semibold tabular-nums sm:text-sm"
          >
            {@token_cost_chart.total_label}
          </span>
        </div>
        <div
          id="stats-token-cost-chart-scroll"
          class="mt-3 min-w-0 overflow-x-auto overscroll-x-contain pb-1"
          data-role="chart-scroll-region"
        >
          <div
            id="stats-token-cost-chart-plot"
            class="admin-apex-bar-chart admin-chart-mobile-wide w-full"
            phx-hook="ApexTimeSeriesChart"
            phx-update="ignore"
            role="img"
            aria-labelledby="stats-token-cost-chart-title stats-token-cost-chart-desc"
            data-chart-categories={@token_cost_chart.categories}
            data-chart-series={@token_cost_chart.series}
            data-chart-unit="tokens"
            data-chart-units={@token_cost_chart.units}
            data-chart-value-kinds={@token_cost_chart.value_kinds}
            data-chart-yaxis={@token_cost_chart.yaxis}
            data-chart-bar-radius="0"
            data-chart-height="260"
            data-chart-colors={@token_cost_chart.colors}
            data-chart-labels="true"
            data-chart-legend="false"
            data-chart-stacked="true"
          >
          </div>
        </div>
        <p id="stats-token-cost-chart-title" class="sr-only">Tokens vs cost</p>
        <p id="stats-token-cost-chart-desc" class="sr-only">
          {token_cost_chart_description(@token_cost_chart.points)}
        </p>
        <ul class="sr-only">
          <li :for={point <- @token_cost_chart.points}>
            {point.label}: {point.total_tokens} tokens, {point.cached_input_tokens} cached input tokens, {Format.money_from_micros(
              point.cost_micros
            )} cost
          </li>
        </ul>
      </section>

      <section
        id="stats-model-usage-chart"
        class="min-w-0 rounded-box border border-base-300 bg-base-100 p-3 shadow-sm sm:p-4"
      >
        <div class="flex flex-wrap items-start justify-between gap-2">
          <div class="grid gap-1">
            <h2 id="stats-model-usage-chart-heading" class="text-base font-semibold text-base-content">
              Model usage
            </h2>
          </div>
          <span
            id="stats-model-usage-chart-total"
            class="text-right text-xs font-semibold tabular-nums sm:text-sm"
          >
            {@model_usage_chart.total_label}
          </span>
        </div>
        <div
          id="stats-model-usage-chart-scroll"
          class="mt-3 min-w-0 overflow-x-auto overscroll-x-contain pb-1"
          data-role="chart-scroll-region"
        >
          <div class={["relative", @model_usage_chart.points == [] && "min-h-[260px]"]}>
            <div
              id="stats-model-usage-chart-plot"
              class={[
                "admin-apex-bar-chart admin-chart-mobile-wide w-full",
                @model_usage_chart.points == [] && "absolute inset-0 pointer-events-none opacity-0"
              ]}
              phx-hook="ApexTimeSeriesChart"
              phx-update="ignore"
              role="img"
              aria-labelledby="stats-model-usage-chart-title stats-model-usage-chart-desc"
              data-chart-categories={@model_usage_chart.categories}
              data-chart-series={@model_usage_chart.series}
              data-chart-unit="tokens"
              data-chart-units={@model_usage_chart.units}
              data-chart-value-kinds={@model_usage_chart.value_kinds}
              data-chart-yaxis={@model_usage_chart.yaxis}
              data-chart-bar-radius="0"
              data-chart-height="260"
              data-chart-colors={@model_usage_chart.colors}
              data-chart-labels="true"
              data-chart-legend="false"
              data-chart-safe-tooltip="true"
              data-chart-stacked="true"
            >
            </div>
            <div
              :if={@model_usage_chart.points == []}
              id="stats-model-usage-chart-empty"
              class="absolute inset-0 grid place-items-center rounded-box border border-dashed border-base-300 bg-base-200/40 px-4 text-center"
            >
              <div class="grid justify-items-center gap-2 text-sm text-base-content/60">
                <.icon name="hero-chart-bar" class="size-6 text-base-content/35" />
                <p class="font-medium text-base-content/70">No model usage in this range</p>
              </div>
            </div>
          </div>
        </div>
        <p id="stats-model-usage-chart-title" class="sr-only">Model usage</p>
        <p id="stats-model-usage-chart-desc" class="sr-only">
          {model_usage_chart_description(@model_usage_chart.points)}
        </p>
        <ul class="sr-only">
          <li :for={point <- @model_usage_chart.points}>
            {point.label}: {point.total_tokens} tokens for {point.model_code}
          </li>
        </ul>
      </section>
    </section>
    """
  end

  defp traffic_chart_description(points) do
    token_total = Enum.reduce(points, 0, &(&1.tokens + &2))
    request_total = Enum.reduce(points, 0, &(&1.requests + &2))

    "#{length(points)} time buckets with #{token_total} total tokens and #{request_total} total requests."
  end

  defp token_cost_chart_description(points) do
    token_total = Enum.reduce(points, 0, &(&1.total_tokens + &2))
    cost_total = Enum.reduce(points, 0, &(&1.cost_micros + &2))

    "#{length(points)} time buckets with #{token_total} total tokens and #{Format.money_from_micros(cost_total)} total cost."
  end

  defp model_usage_chart_description(points) do
    token_total = Enum.reduce(points, 0, &(&1.total_tokens + &2))
    model_count = points |> Enum.map(& &1.model_code) |> Enum.uniq() |> length()

    "#{model_count} models with #{token_total} total tokens."
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
      value_kinds: Jason.encode!(["tokens", "integer"]),
      yaxis:
        Jason.encode!([
          %{seriesName: "Tokens", title: "tokens", valueKind: "tokens"},
          %{seriesName: "Requests", title: "requests", opposite: true, valueKind: "integer"}
        ]),
      colors: Jason.encode!(["var(--color-primary)", "var(--color-info)"]),
      points: points,
      total_label:
        "#{Format.token_count(token_total)} tokens / #{Format.integer(request_total)} requests"
    }
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

        %{
          label: label,
          input_tokens: chart_value(token_row, :uncached_input_tokens),
          cached_input_tokens: chart_value(token_row, :cached_input_tokens),
          output_tokens: chart_value(token_row, :output_tokens),
          reasoning_tokens: chart_value(token_row, :reasoning_tokens),
          total_tokens: chart_value(token_row, :total_tokens),
          cost_micros: cost_micros,
          cost_usd: micros_to_usd(cost_micros)
        }
      end)

    input_values = Enum.map(points, & &1.input_tokens)
    cached_input_values = Enum.map(points, & &1.cached_input_tokens)
    output_values = Enum.map(points, & &1.output_tokens)
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
          %{name: "Output", type: "column", data: output_values},
          %{name: "Reasoning", type: "column", data: reasoning_values},
          %{name: "Cost", type: "line", data: cost_values}
        ]),
      units: Jason.encode!(["tokens", "tokens", "tokens", "tokens", "USD"]),
      value_kinds: Jason.encode!(["tokens", "tokens", "tokens", "tokens", "usd"]),
      yaxis:
        Jason.encode!([
          %{
            seriesName: ["Input", "Cached input", "Output", "Reasoning"],
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

  defp model_usage_chart_model(model_usage_rows) do
    labels = model_usage_rows |> Enum.map(&format_bucket(&1.bucket)) |> Enum.uniq()
    model_codes = model_usage_rows |> Enum.map(& &1.model_code) |> Enum.uniq()

    rows_by_model_and_label =
      Map.new(model_usage_rows, fn row -> {{row.model_code, format_bucket(row.bucket)}, row} end)

    chart_labels =
      Map.new(model_codes, fn model_code -> {model_code, chart_series_name(model_code)} end)

    series =
      Enum.map(model_codes, fn model_code ->
        values =
          Enum.map(labels, fn label ->
            rows_by_model_and_label
            |> Map.get({model_code, label}, %{})
            |> chart_value(:total_tokens)
          end)

        %{name: Map.fetch!(chart_labels, model_code), type: "column", data: values}
      end)

    points =
      Enum.flat_map(model_codes, fn model_code ->
        Enum.map(labels, fn label ->
          row = Map.get(rows_by_model_and_label, {model_code, label}, %{})

          %{
            label: label,
            model_code: model_code,
            total_tokens: chart_value(row, :total_tokens)
          }
        end)
      end)

    token_total = points |> Enum.map(& &1.total_tokens) |> Enum.sum()

    %{
      categories: Jason.encode!(labels),
      series: Jason.encode!(series),
      units: Jason.encode!(Enum.map(model_codes, fn _model_code -> "tokens" end)),
      value_kinds: Jason.encode!(Enum.map(model_codes, fn _model_code -> "tokens" end)),
      yaxis:
        Jason.encode!([
          %{
            seriesName: Enum.map(model_codes, &Map.fetch!(chart_labels, &1)),
            title: "tokens",
            valueKind: "tokens"
          }
        ]),
      colors:
        Jason.encode!([
          "var(--color-primary)",
          "var(--color-secondary)",
          "var(--color-info)",
          "var(--color-success)",
          "var(--color-warning)",
          "var(--color-accent)"
        ]),
      points: points,
      total_label: "#{Format.token_count(token_total)} tokens"
    }
  end

  defp chart_series_name(nil), do: ""

  defp chart_series_name(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp chart_value(row, key), do: max(Map.get(row, key) || 0, 0)

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
