defmodule CodexPoolerWeb.Admin.StatsPresentation.Charts do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Format
  alias CodexPoolerWeb.Admin.StatsPresentation.{TokenCostChart, TrafficChart}

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
        TrafficChart.build(assigns.requests, assigns.tokens, model_usage)
      )
      |> assign(:token_cost_chart, TokenCostChart.build(assigns.tokens, assigns.costs))

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
          {TrafficChart.description(@traffic_chart.points)}
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
          {TokenCostChart.description(@token_cost_chart.points)}
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
end
