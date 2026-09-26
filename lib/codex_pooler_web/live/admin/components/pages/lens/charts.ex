defmodule CodexPoolerWeb.Admin.LensCharts do
  @moduledoc false
  use CodexPoolerWeb, :html
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  attr :history, :map, required: true

  def charts(assigns) do
    assigns =
      assigns
      |> assign(:categories, json(Enum.map(assigns.history.timeline, &Calendar.strftime(&1.bucket, "%m-%d %H:%M"))))
      |> assign(:signals, series(assigns.history.timeline, [{:mismatches, "Different from sent"}, {:conflicts, "Name changed in response"}]))
      |> assign(:largest_pair, Enum.reduce(assigns.history.model_pairs, 1, &max(&1.total, &2)))
      |> assign(:has_signals?, assigns.history.counts.mismatches > 0 or assigns.history.counts.conflicts > 0)

    ~H"""
    <section id="lens-charts" class="grid min-w-0 gap-3 lg:gap-4 xl:grid-cols-2" aria-label="Model observation history">
      <div :if={!@has_signals?} class="xl:col-span-2">
        <AdminComponents.empty_state id="lens-signals-empty" title="No model differences observed" description="The provider did not report a different name from the one sent or change that name during a response. Check the recording details below for missing data." icon="hero-magnifying-glass" />
      </div>
      <.chart
        :if={@has_signals?}
        id="lens-signals"
        title="Reported model differences"
        subtitle={"#{@history.counts.mismatches} different from sent · #{@history.counts.conflicts} name changes within a response"}
        categories={@categories}
        series={@signals}
        colors={json(["var(--color-warning)", "var(--color-error)"])}
      >
        <:actions>
          <.link id="lens-view-mismatches" aria-label="View attempts where the first reported model differs from the model sent" title="View attempts where the first reported model differs from the model sent" patch={~p"/admin/lens?#{Map.put(@history.filters, "evidence", "mismatch")}"} class="btn btn-ghost btn-xs gap-1.5 text-base-content/65">
            <.icon name="hero-arrows-right-left" class="size-3.5 shrink-0 text-warning" /><span class="admin-control-label">Different model</span>
          </.link>
          <.link id="lens-view-conflicts" aria-label="View attempts where the provider changed the model name during one response" title="View attempts where the provider changed the model name during one response" patch={~p"/admin/lens?#{Map.put(@history.filters, "evidence", "conflict")}"} class="btn btn-ghost btn-xs gap-1.5 text-base-content/65">
            <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0 text-error" /><span class="admin-control-label">Name changed</span>
          </.link>
        </:actions>
        <:description>
          Affected attempts per {interval(@history.bucket_seconds)} · UTC. Measures can overlap. The comparison uses the model name sent upstream and the names the provider reported.
        </:description>
        <p :if={@history.counts.collected == 0} id="lens-conflict-coverage-note" class="text-xs text-base-content/60">
          Changes within responses were not recorded in this window. Zero recorded changes does not prove every response kept the same model name.
        </p>
        <ul class="sr-only" id="lens-signal-values">
          <li :for={point <- @history.timeline}>
            {Calendar.strftime(point.bucket, "%m-%d %H:%M")} UTC: {point.mismatches} different from sent among {point.comparable} attempts with both names; {point.conflicts} name changes within a response among {point.observed} attempts recorded with a model name.
          </li>
        </ul>
      </.chart>
      <section :if={@has_signals?} id="lens-models" class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100">
        <header class="grid gap-1 border-b border-base-300 bg-base-200/35 px-4 py-3">
          <h2 class="text-base font-semibold leading-5">Models involved</h2>
          <p class="text-xs text-base-content/70">Top 8 combinations with a different name or a name change during the response</p>
        </header>
        <div class="grid gap-5 p-4">
          <div :for={pair <- @history.model_pairs} data-role="model-pair" class="grid min-w-0 gap-2">
            <div class="flex min-w-0 items-center justify-between gap-3 text-sm">
              <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
                <span class="break-all" title="Sent model">{pair.sent_model || "Unknown sent model"}</span>
                <.icon name="hero-arrow-right" class="size-3.5 shrink-0 text-base-content/45" />
                <span class="break-all font-medium" title="First model name reported by the provider">{pair.first_model || "No model reported"}</span>
              </div>
              <span class="shrink-0 font-semibold tabular-nums">{pair.total}</span>
            </div>
            <div class="h-2 overflow-hidden rounded-full bg-base-200" role="img" aria-label={"#{pair.total} affected attempts: #{pair.mismatches} different from sent, #{pair.conflicts} name changes within a response"}>
              <div class="h-full rounded-full bg-warning/75" style={"width: #{pair.total * 100 / @largest_pair}%"}></div>
            </div>
            <p class="text-xs text-base-content/60">
              {pair.mismatches} different from sent · {pair.conflicts} name changes<span :if={pair.conflicting_model}> · later reported name: <span class="text-base-content">{pair.conflicting_model}</span></span>
            </p>
          </div>
          <p class="text-xs text-base-content/60">Sent model → first reported name. Each bar counts affected attempts once. The provider can report the sent name first, then change it later in the same response.</p>
        </div>
      </section>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :categories, :string, required: true
  attr :series, :string, required: true
  attr :colors, :string, required: true
  attr :stacked, :boolean, default: false
  slot :description, required: true
  slot :actions
  slot :inner_block

  defp chart(assigns) do
    ~H"""
    <section id={@id} class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100">
      <header class="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 border-b border-base-300 bg-base-200/35 px-4 py-3">
        <h2 id={"#{@id}-title"} class="min-w-0 text-base font-semibold leading-5">{@title}</h2>
        <div :if={@actions != []} data-role="chart-header-actions" class="ml-auto flex shrink-0 flex-wrap justify-end gap-1">{render_slot(@actions)}</div>
        <p class="w-full text-xs tabular-nums text-base-content/70">{@subtitle}</p>
      </header>
      <div class="min-w-0 overflow-x-auto overscroll-x-contain p-3 pb-2 sm:p-4 sm:pb-2" data-role="chart-scroll-region">
        <div
          id={"#{@id}-plot"}
          class="admin-apex-bar-chart admin-chart-mobile-wide w-full"
          phx-hook="ApexTimeSeriesChart"
          phx-update="ignore"
          role="group"
          aria-labelledby={"#{@id}-title"}
          aria-describedby={"#{@id}-description"}
          data-chart-categories={@categories}
          data-chart-series={@series}
          data-chart-unit="attempts"
          data-chart-height="260"
          data-chart-colors={@colors}
          data-chart-legend="always"
          data-chart-labels="true"
          data-chart-safe-tooltip="true"
          data-chart-stacked={to_string(@stacked)}
          data-chart-bar-radius="0"
          data-chart-zoom="false"
          data-chart-wheel-scroll="page"
        >
        </div>
      </div>
      <div class="grid gap-2 px-4 pb-4">
        <p id={"#{@id}-description"} class="text-xs text-base-content/60">{render_slot(@description)}</p>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  defp series(points, fields), do: json(Enum.map(fields, fn {key, name} -> %{name: name, type: "column", data: Enum.map(points, &Map.fetch!(&1, key))} end))
  defp interval(300), do: "5 minutes"
  defp interval(21_600), do: "6 hours"
  defp interval(_seconds), do: "hour"
  defp json(value), do: CodexPooler.JSON.encode!(value)
end
