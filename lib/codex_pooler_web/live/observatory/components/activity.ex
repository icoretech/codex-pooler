defmodule CodexPoolerWeb.Observatory.Components.Activity do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Observatory.Components.Section

  attr :traffic, :map, required: true
  attr :outcomes, :list, required: true
  attr :window, :string, default: nil
  attr :traffic_mode, :atom, default: :interval, values: [:interval, :cumulative]

  @spec activity(map()) :: Phoenix.LiveView.Rendered.t()
  def activity(assigns) do
    ~H"""
    <div id="observatory-activity" class="grid min-w-0 gap-8">
      <.traffic_panel traffic={@traffic} window={@window} traffic_mode={@traffic_mode} />
      <.outcomes_panel outcomes={@outcomes} />
    </div>
    """
  end

  attr :traffic, :map, required: true
  attr :window, :string, default: nil
  attr :traffic_mode, :atom, default: :interval, values: [:interval, :cumulative]

  @spec traffic_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def traffic_panel(assigns) do
    ~H"""
    <section
      id="observatory-traffic"
      class="grid min-w-0 gap-4"
      aria-labelledby="observatory-traffic-heading"
    >
      <Section.divider id="observatory-traffic-heading" label={gettext("Traffic")} suffix={@window} />
      <div class="flex justify-end">
        <div
          id="observatory-traffic-mode-control"
          class="observatory-segmented-control"
          role="group"
          aria-label={gettext("Traffic chart mode")}
        >
          <button
            :for={{label, mode} <- [{gettext("Interval"), "interval"}, {gettext("Cumulative"), "cumulative"}]}
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
      </div>

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
          data-chart-unit-label={gettext("tokens")}
          data-chart-unit-labels={Map.get(@traffic.chart, :unit_labels)}
          data-chart-default-series-label={gettext("Value")}
          data-chart-series-label={gettext("Series %{index}", index: "%{index}")}
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
          data-chart-cumulative-description={gettext("Showing cumulative running totals through each time bucket.")}
          data-chart-interval-description={gettext("Showing interval values for each time bucket.")}
        >
        </div>
      </div>

      <p id="observatory-traffic-title" class="sr-only">{gettext("Traffic over time")}</p>
      <p id="observatory-traffic-desc" class="sr-only">
        {gettext("Token activity by model, with cost, shown for each time bucket.")}
      </p>
      <p id="observatory-traffic-mode-description" class="sr-only" aria-live="polite">
        {if @traffic_mode == :cumulative do
          gettext("Showing cumulative running totals through each time bucket.")
        else
          gettext("Showing interval values for each time bucket.")
        end}
      </p>
      <ul
        id="observatory-traffic-interval-values"
        class="sr-only"
        data-chart-source="interval"
        aria-label={gettext("Underlying interval values for Traffic over time")}
      >
        <li :for={row <- @traffic.fallback.rows}>
          {gettext("%{time}: %{tokens}, %{cost}", time: row.label, tokens: row.total_label, cost: row.cost_label)}
        </li>
      </ul>
      <div id="observatory-traffic-table-fallback" class="sr-only">
        <table>
          <caption>{gettext("Traffic by time bucket")}</caption>
          <thead>
            <tr>
              <th scope="col">{gettext("Time")}</th>
              <th scope="col">{gettext("Tokens")}</th>
              <th scope="col">{gettext("Cost")}</th>
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
        <p id="observatory-traffic-fallback-total">{gettext("Total: %{total}", total: @traffic.fallback.total_label)}</p>
      </div>
    </section>
    """
  end

  attr :outcomes, :list, required: true
  attr :has_more, :boolean, default: false
  attr :loading_more, :boolean, default: false
  attr :load_error, :boolean, default: false

  @spec outcomes_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def outcomes_panel(assigns) do
    assigns = assign(assigns, :visible_outcomes, assigns.outcomes |> List.wrap() |> group_unattributed())

    ~H"""
    <section
      id="observatory-outcomes"
      class="grid min-w-0 gap-4"
      aria-labelledby="observatory-outcomes-heading"
    >
      <Section.divider id="observatory-outcomes-heading" label={gettext("Recent outcomes")} suffix={gettext("Last 60 minutes")} />
      <div id="observatory-outcomes-scroll" class="overflow-x-auto">
        <table id="observatory-outcomes-table" class="table table-sm min-w-160">
          <caption class="sr-only">{gettext("Recent request outcomes")}</caption>
          <colgroup>
            <col class="observatory-outcome-time" />
            <col class="observatory-outcome-model" />
            <col class="observatory-outcome-endpoint" />
            <col class="observatory-outcome-client" />
            <col class="observatory-outcome-status" />
            <col class="observatory-outcome-tokens-column" />
            <col class="observatory-outcome-cost" />
          </colgroup>
          <thead>
            <tr>
              <th scope="col">{gettext("Time")}</th>
              <th scope="col">{gettext("Model")}</th>
              <th scope="col">{gettext("Activity")}</th>
              <th scope="col" class="observatory-outcome-client">{gettext("Client")}</th>
              <th scope="col" class="text-center">{gettext("Status")}</th>
              <th scope="col" class="text-right">{gettext("Tokens · Cache")}</th>
              <th scope="col" class="text-right">{gettext("Cost")}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={outcome <- @visible_outcomes}
              data-role="observatory-outcome-row"
              data-status={status_data_status(outcome.status.data_status)}
              class="align-middle"
            >
              <td
                data-label={gettext("Time")}
                class="truncate text-xs tabular-nums text-base-content/70"
                title={outcome.timestamp}
              >
                {outcome.timestamp}
              </td>
              <th
                :if={!Map.has_key?(outcome, :count)}
                scope="row"
                data-label={gettext("Model")}
                class="max-w-64 font-normal"
              >
                <div class="flex min-w-0 items-center gap-2">
                  <span class="flex min-w-0 items-baseline gap-1 text-sm leading-4">
                    <span :if={Map.get(outcome, :model_color)} data-role="model-swatch" aria-hidden="true" class="size-2 shrink-0 self-center rounded-xs" style={"background-color: #{outcome.model_color}"}></span>
                    <span data-role="outcome-model" class={["min-w-0 truncate", if(outcome.model == gettext("Not applicable"), do: "text-xs font-normal text-base-content/55", else: "font-semibold")]} title={outcome.model}>{outcome.model}</span>
                    <span
                      :if={Map.get(outcome, :effort)}
                      data-role="outcome-effort"
                      class="shrink-0 text-xs text-base-content/70"
                    >· {outcome.effort}</span>
                  </span>
                  <span
                    :if={Map.get(outcome, :speed_level)}
                    data-role="outcome-speed"
                    data-speed-level={outcome.speed_level}
                    class="inline-flex shrink-0 items-center gap-px text-warning"
                    title={speed_title(outcome.speed_level)}
                  >
                    <.icon
                      :for={n <- 1..3}
                      name={if n <= outcome.speed_level, do: "hero-bolt-solid", else: "hero-bolt"}
                      class={["size-3", n > outcome.speed_level && "opacity-30"]}
                    />
                    <span class="sr-only">{speed_title(outcome.speed_level)}</span>
                  </span>
                </div>
              </th>
              <th
                :if={Map.has_key?(outcome, :count)}
                scope="row"
                data-label={gettext("Model")}
                data-role="observatory-outcome-group"
                class="max-w-56 truncate text-xs font-normal text-base-content/55"
              >
                {ngettext("%{model} · %{count} request", "%{model} · %{count} requests", outcome.count, model: outcome.model, count: outcome.count)}
              </th>
              <td data-label={gettext("Activity")} class="truncate text-xs text-base-content/70" title={activity_label(outcome.endpoint)}>{activity_label(outcome.endpoint)}</td>
              <td data-label={gettext("Client")} class="observatory-outcome-client max-w-40 text-xs text-base-content/70">
                <.client client={Map.get(outcome, :client)} />
              </td>
              <td data-label={gettext("Status")} class="text-center">
                <span
                  class={[
                    AdminBadges.status_chip_class(status_for_tone(outcome.status.tone)),
                    "observatory-outcome-status-chip observatory-metadata-chip max-w-full truncate !px-2 !py-0.5"
                  ]}
                  data-role="outcome-status"
                  data-status={status_data_status(outcome.status.data_status)}
                  role="status"
                  title={outcome.status.label}
                  aria-label={outcome.status.label}
                >
                  <.icon name={outcome_status_icon(outcome.status.label)} class="observatory-outcome-status-icon hidden size-4" />
                  <span class="observatory-outcome-status-label">{outcome.status.label}</span>
                </span>
              </td>
              <td data-label={gettext("Tokens · Cache")} class="whitespace-nowrap text-right tabular-nums">
                <div class="observatory-outcome-tokens flex items-center justify-end gap-2">
                  <span class="flex items-center justify-end gap-2 text-sm leading-4">
                    <span data-role="outcome-tokens" class="text-right font-semibold">{outcome.tokens.label}</span>
                  </span>
                  <span
                    :if={Map.get(outcome.tokens, :cache_percentage_label)}
                    data-role="outcome-cached"
                    class="text-xs text-base-content/70"
                  >
                    {outcome.tokens.cache_percentage_label}
                  </span>
                </div>
              </td>
              <td data-label={gettext("Cost")} class="whitespace-nowrap text-right text-sm tabular-nums">
                <span data-role="outcome-cost" class="font-semibold">{outcome.cost.label}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p :if={@visible_outcomes == []} id="observatory-outcomes-empty" class="py-4 text-center text-sm text-base-content/70">
        {gettext("No requests in the last 60 minutes")}
      </p>
      <div :if={@has_more or @load_error} class="flex flex-wrap items-center justify-center gap-3">
        <p :if={@load_error} id="observatory-outcomes-load-error" role="status" class="text-xs text-error">
          {gettext("Older requests could not be loaded. Try again.")}
        </p>
        <button id="observatory-outcomes-load-more" type="button" class="btn btn-ghost btn-sm" phx-click="load-more-outcomes" disabled={@loading_more}>
          {if @loading_more, do: gettext("Loading requests…"), else: gettext("Load older requests")}
        </button>
      </div>
    </section>
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

  defp outcome_status_icon(label) do
    cond do
      label == gettext("Succeeded") -> "hero-check-circle"
      label == gettext("Client cancelled") -> "hero-no-symbol"
      label == gettext("In progress") -> "hero-arrow-path"
      label == gettext("Accepted") -> "hero-clock"
      true -> "hero-exclamation-triangle"
    end
  end

  defp speed_title(3), do: gettext("Ultrafast")
  defp speed_title(2), do: gettext("Fast (priority tier)")
  defp speed_title(_level), do: gettext("Normal speed")

  attr :client, :map, default: nil

  defp client(%{client: nil} = assigns) do
    ~H"""
    <span data-role="outcome-client">{gettext("Unknown client")}</span>
    """
  end

  defp client(assigns) do
    ~H"""
    <span data-role="outcome-client" data-client-kind={@client.kind} class="inline-flex max-w-full items-center gap-1.5 whitespace-nowrap">
      <span aria-hidden="true" class="inline-flex shrink-0">
        <%= case @client.logo do %>
          <% %{format: :svg, asset: asset} -> %>
            <span class="request-client-logo" style={"mask-image: url(#{~p"/images/client-logos/#{asset}"})"}></span>
          <% %{format: :png, asset: asset} -> %>
            <img class="request-client-logo-image" src={~p"/images/client-logos/#{asset}"} width="14" height="14" alt="" />
          <% nil -> %>
            <.icon name={@client.icon} class="size-3.5" />
        <% end %>
      </span>
      <span class="truncate">{@client.label}</span>
    </span>
    """
  end

  # Requests that name no model and move no tokens (model listings and the
  # like) would otherwise fill the table; consecutive identical ones become
  # one row that shows the newest time and how many were folded in.
  defp group_unattributed(outcomes) do
    outcomes
    |> Enum.chunk_while(
      nil,
      fn outcome, acc ->
        cond do
          not unattributed?(outcome) -> flush(acc, [outcome])
          acc && same_group?(acc, outcome) -> {:cont, %{acc | count: acc.count + 1}}
          true -> flush(acc, [], start_group(outcome))
        end
      end,
      fn acc -> {:cont, List.wrap(acc), nil} end
    )
    |> List.flatten()
    |> Enum.map(fn
      %{count: 1} = outcome -> Map.delete(outcome, :count)
      outcome -> outcome
    end)
  end

  defp flush(nil, rows), do: {:cont, rows, nil}
  defp flush(acc, rows), do: {:cont, [acc | rows], nil}
  defp flush(nil, rows, next), do: {:cont, rows, next}
  defp flush(acc, rows, next), do: {:cont, [acc | rows], next}

  defp unattributed?(outcome), do: outcome.model in [gettext("Unknown model"), gettext("Not applicable")] and outcome.endpoint not in ["responses", "chat_completions", "completions", "compaction", "audio", "embeddings"] and get_in(outcome, [:tokens, :total]) == 0

  defp same_group?(group, outcome), do: group.model == outcome.model and group.endpoint == outcome.endpoint and group.status == outcome.status and Map.get(group, :client) == Map.get(outcome, :client)

  defp activity_label(endpoint) do
    case endpoint do
      "models" -> gettext("Catalog")
      "usage" -> gettext("Usage")
      "files" -> gettext("Files")
      "audio" -> gettext("Transcription")
      "compaction" -> gettext("Compaction")
      generation when generation in ["responses", "chat_completions", "completions"] -> gettext("Generation")
      "embeddings" -> gettext("Embeddings")
      _ -> gettext("Other")
    end
  end

  defp start_group(outcome), do: Map.put(outcome, :count, 1)
end
