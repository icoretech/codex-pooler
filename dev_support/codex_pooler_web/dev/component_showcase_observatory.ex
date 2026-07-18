defmodule CodexPoolerWeb.Dev.ComponentShowcaseObservatory do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Dev.ComponentShowcaseStats
  alias CodexPoolerWeb.Observatory.Components.{Activity, States, Telemetry, Toolbar}

  attr :paused, :boolean, required: true
  attr :observatory, :map, required: true

  def observatory_primitives(assigns) do
    ~H"""
    <section id="showcase-observatory-primitives" class="grid min-w-0 gap-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h2 class="text-xl font-bold">Observatory primitives</h2>
        <div id="showcase-observatory-controls" class="flex flex-wrap gap-2">
          <AdminComponents.action_button
            id="showcase-toggle-paused"
            icon={if @paused, do: "hero-play", else: "hero-pause"}
            label={if @paused, do: "Show live", else: "Show paused"}
            phx-click="showcase-toggle-paused"
          />
        </div>
      </div>

      <Toolbar.toolbar
        display_name="Sample key"
        key_prefix="sk-cxp-demo…0042"
        selected_window="24h"
        freshness={if @paused, do: "Updates paused", else: "Updated 0s ago"}
        paused={@paused}
      />

      <div
        id="showcase-observatory-grid"
        class="grid min-w-0 gap-4 observatory-split:grid-cols-[minmax(0,4fr)_minmax(0,8fr)]"
      >
        <aside
          id="showcase-observatory-rail"
          class="min-w-0 observatory-split:sticky observatory-split:top-16 observatory-split:self-start"
        >
          <Telemetry.telemetry overview={@observatory.overview} models={@observatory.models} />
        </aside>
        <div id="showcase-observatory-activity" class="min-w-0">
          <Activity.activity
            traffic={@observatory.traffic}
            outcomes={@observatory.outcomes}
          />
        </div>
      </div>

      <ComponentShowcaseStats.stats_traffic_charts />

      <AdminComponents.admin_surface id="showcase-observatory-states" title="Named states">
        <div class="grid gap-3 p-4 md:grid-cols-2">
          <States.state
            :for={state <- [:loading, :empty, :stale, :error]}
            state={state}
          />
        </div>
      </AdminComponents.admin_surface>

      <AdminComponents.admin_surface id="showcase-native-state-notes" title="Runtime boundaries">
        <dl class="grid gap-3 p-4 text-sm md:grid-cols-3">
          <div id="showcase-note-focus" class="grid gap-1">
            <dt class="font-semibold">Focus and hover</dt>
            <dd class="text-base-content/65">Driven through the real in-app Browser.</dd>
          </div>
          <div id="showcase-note-disconnected" class="grid gap-1">
            <dt class="font-semibold">Disconnected</dt>
            <dd class="text-base-content/65">
              Connection loss surfaces in the freshness pill, not a separate banner.
            </dd>
          </div>
          <div id="showcase-note-domain" class="grid gap-1">
            <dt class="font-semibold">Authenticated composites</dt>
            <dd class="text-base-content/65">
              Cockpit remains on its fixture-backed product route during concurrent work.
            </dd>
          </div>
        </dl>
      </AdminComponents.admin_surface>
    </section>
    """
  end
end
