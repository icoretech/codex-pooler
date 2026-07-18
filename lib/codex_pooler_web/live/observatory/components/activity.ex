defmodule CodexPoolerWeb.Observatory.Components.Activity do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges

  @max_outcomes 12

  attr :traffic, :map, required: true
  attr :outcomes, :list, required: true
  attr :traffic_mode, :atom, default: :interval, values: [:interval, :cumulative]

  def activity(assigns) do
    assigns =
      assigns
      |> assign(
        :visible_outcomes,
        assigns.outcomes
        |> List.wrap()
        |> Enum.take(@max_outcomes)
      )

    ~H"""
    <div id="observatory-activity" class="grid min-w-0 gap-8">
      <section
        id="observatory-traffic"
        class="grid min-w-0 gap-4"
        aria-labelledby="observatory-traffic-heading"
      >
        <header class="flex flex-wrap items-end justify-between gap-3 border-b border-base-300/50 pb-3">
          <div class="grid min-w-0 gap-1">
            <h2
              id="observatory-traffic-heading"
              class="text-lg font-semibold tracking-tight text-base-content"
            >
              Traffic
            </h2>
            <p class="text-xs tabular-nums text-base-content/55">{@traffic.total_label}</p>
          </div>
          <div
            id="observatory-traffic-mode-control"
            class="observatory-segmented-control"
            role="group"
            aria-label="Traffic chart mode"
          >
            <button
              :for={{label, mode} <- [{"Interval", "interval"}, {"Cumulative", "cumulative"}]}
              id={"observatory-traffic-mode-#{mode}"}
              type="button"
              class="observatory-segmented-button"
              data-chart-mode={mode}
              aria-controls="observatory-traffic-plot"
              aria-pressed={to_string(@traffic_mode == String.to_existing_atom(mode))}
              phx-click={
                JS.dispatch("chart:set-mode",
                  to: "#observatory-traffic-plot",
                  detail: %{mode: mode}
                )
              }
            >
              {label}
            </button>
          </div>
        </header>

        <div
          id="observatory-traffic-scroll"
          class="observatory-chart-scroll min-w-0 overflow-x-auto overscroll-x-contain"
          data-role="chart-scroll-region"
        >
          <div
            id="observatory-traffic-plot"
            class="observatory-chart admin-apex-bar-chart w-full"
            phx-hook="ApexTimeSeriesChart"
            phx-update="ignore"
            role="img"
            aria-labelledby="observatory-traffic-title"
            aria-describedby="observatory-traffic-desc observatory-traffic-mode-description"
            data-chart-categories={@traffic.chart.categories}
            data-chart-series={@traffic.chart.series}
            data-chart-unit="tokens"
            data-chart-units={@traffic.chart.units}
            data-chart-value-kinds={@traffic.chart.value_kinds}
            data-chart-yaxis={@traffic.chart.yaxis}
            data-chart-height="264"
            data-chart-colors={@traffic.chart.colors}
            data-chart-legend="always"
            data-chart-safe-tooltip="true"
            data-chart-stacked="true"
            data-chart-bar-radius="0"
            data-chart-zoom="false"
            data-chart-wheel-scroll="page"
            data-chart-mode-control="observatory-traffic-mode-control"
            data-chart-mode-description="observatory-traffic-mode-description"
          >
          </div>
        </div>

        <p id="observatory-traffic-title" class="sr-only">Traffic over time</p>
        <p id="observatory-traffic-desc" class="sr-only">
          Token activity by model, with cost, shown for each time bucket.
        </p>
        <p id="observatory-traffic-mode-description" class="sr-only" aria-live="polite">
          {if @traffic_mode == :cumulative do
            "Showing cumulative running totals through each time bucket."
          else
            "Showing interval values for each time bucket."
          end}
        </p>
        <ul
          id="observatory-traffic-interval-values"
          class="sr-only"
          data-chart-source="interval"
          aria-label="Underlying interval values for Traffic over time"
        >
          <li :for={row <- @traffic.fallback.rows}>
            {row.label}: {row.total_label}, {row.cost_label}
          </li>
        </ul>
        <div id="observatory-traffic-table-fallback" class="sr-only">
          <table>
            <caption>Traffic by time bucket</caption>
            <thead>
              <tr>
                <th scope="col">Time</th>
                <th scope="col">Tokens</th>
                <th scope="col">Cost</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @traffic.fallback.rows}>
                <th scope="row">{row.label}</th>
                <td>{row.total_label}</td>
                <td>{row.cost_label}</td>
              </tr>
            </tbody>
          </table>
          <p id="observatory-traffic-fallback-total">Total: {@traffic.fallback.total_label}</p>
        </div>
      </section>

      <section
        id="observatory-outcomes"
        class="grid min-w-0 gap-4"
        aria-labelledby="observatory-outcomes-heading"
      >
        <header class="grid min-w-0 gap-1 border-b border-base-300/50 pb-3">
          <h2
            id="observatory-outcomes-heading"
            class="text-lg font-semibold tracking-tight text-base-content"
          >
            Recent outcomes
          </h2>
          <p class="text-xs text-base-content/55">metadata only; request content is not shown.</p>
        </header>
        <div id="observatory-outcomes-scroll" class="overflow-x-auto">
          <table id="observatory-outcomes-table" class="table table-sm min-w-160">
            <caption class="sr-only">Recent request outcomes</caption>
            <thead>
              <tr>
                <th scope="col">Time</th>
                <th scope="col">Model</th>
                <th scope="col">Endpoint</th>
                <th scope="col">Status</th>
                <th scope="col">Latency</th>
                <th scope="col">Tokens</th>
                <th scope="col">Cost</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={outcome <- @visible_outcomes}
                data-role="observatory-outcome-row"
                data-status={status_data_status(outcome.status.data_status)}
                class="align-middle"
              >
                <td class="whitespace-nowrap font-mono text-xs tabular-nums text-base-content/55">
                  {outcome.timestamp}
                </td>
                <th scope="row" class="max-w-40 truncate font-medium">{outcome.model}</th>
                <td class="text-base-content/60">{outcome.endpoint}</td>
                <td>
                  <span
                    class={[
                      AdminBadges.status_chip_class(status_for_tone(outcome.status.tone)),
                      "observatory-metadata-chip whitespace-nowrap !px-2 !py-0.5"
                    ]}
                    data-role="outcome-status"
                    data-status={status_data_status(outcome.status.data_status)}
                    role="status"
                  >
                    {outcome.status.label}
                  </span>
                </td>
                <td class="whitespace-nowrap text-right font-mono text-xs tabular-nums">
                  {outcome.latency.label}
                </td>
                <td class="whitespace-nowrap text-right font-mono text-xs tabular-nums">
                  {outcome.tokens.label}
                </td>
                <td class="whitespace-nowrap text-right font-mono text-xs tabular-nums">
                  {outcome.cost.label}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end

  defp status_data_status("ok"), do: "ok"
  defp status_data_status("warn"), do: "warn"
  defp status_data_status("err"), do: "err"
  defp status_data_status(:ok), do: "ok"
  defp status_data_status(:warn), do: "warn"
  defp status_data_status(:err), do: "err"
  defp status_data_status(_status), do: "unknown"

  defp status_for_tone(:success), do: :succeeded
  defp status_for_tone(:warning), do: :disabled
  defp status_for_tone(:error), do: :failed
  defp status_for_tone(_tone), do: :unknown
end
