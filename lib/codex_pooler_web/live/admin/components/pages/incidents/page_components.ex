defmodule CodexPoolerWeb.Admin.IncidentsPageComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.DateTimeDisplay

  attr :page, :map, required: true
  attr :datetime_preferences, :map, required: true

  def incidents_content(assigns) do
    ~H"""
    <section
      id="admin-incidents-status-summary"
      class="order-2 grid gap-3 rounded-box border border-base-300 bg-base-100 p-4 sm:p-5"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="grid gap-1">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">Status feed</p>
          <p class="text-sm text-base-content/70">
            Metadata from the public status feed, refreshed by the pooler.
          </p>
        </div>
        <span
          id="admin-incidents-feed-state"
          data-state={feed_state(@page)}
          class="badge badge-sm border-0 bg-base-300 text-base-content/70"
        >
          {feed_state_label(@page)}
        </span>
      </div>

      <div
        :if={@page.stale?}
        id="admin-incidents-stale"
        role="status"
        class="rounded-box border border-warning/40 bg-warning/15 px-3 py-2 text-sm text-base-content"
      >
        {stale_copy(@page.last_success_at, @datetime_preferences)}
      </div>

      <div
        :if={@page.last_error_code}
        id="admin-incidents-feed-error"
        role="status"
        class="rounded-box border border-error/30 bg-error/10 px-3 py-2 text-sm text-base-content"
      >
        The latest OpenAI status fetch failed. Showing the last known incident data.
      </div>

      <div
        :if={!@page.available?}
        id="admin-incidents-feed-unavailable"
        role="status"
        class="rounded-box border border-warning/30 bg-warning/10 px-3 py-2 text-sm text-warning-content"
      >
        The status feed is not available yet. The first successful refresh is still pending.
        The feed is checked automatically every five minutes.
      </div>
    </section>

    <section id="admin-incidents-active-section" class="order-1 grid gap-3">
      <div class="flex items-baseline justify-between gap-3">
        <h2 class="text-xl font-semibold">Active incidents</h2>
        <span id="admin-incidents-active-count" class="text-sm text-base-content/60">{length(
          @page.active
        )}</span>
      </div>
      <AdminComponents.empty_state
        :if={@page.active == []}
        id="admin-incidents-active-empty"
        title="No active incidents"
        description="The status feed has no currently active incidents."
        icon="hero-check-circle"
      />
      <.incident_table
        id="admin-incidents-active-desktop"
        rows={@page.active}
        datetime_preferences={@datetime_preferences}
        surface="active-desktop"
      />
      <.incident_cards
        id="admin-incidents-active-mobile"
        rows={@page.active}
        datetime_preferences={@datetime_preferences}
        surface="active-mobile"
      />
    </section>

    <section id="admin-incidents-history-section" class="order-3 grid gap-3">
      <div class="flex items-baseline justify-between gap-3">
        <h2 class="text-xl font-semibold">Incident history</h2>
        <span id="admin-incidents-history-count" class="text-sm text-base-content/60">{@page.history_total}</span>
      </div>
      <AdminComponents.empty_state
        :if={@page.history == []}
        id="admin-incidents-history-empty"
        title="No incident history"
        description="Resolved and retired incidents will appear here."
        icon="hero-clock"
      />
      <.incident_table
        id="admin-incidents-history-desktop"
        rows={@page.history}
        datetime_preferences={@datetime_preferences}
        surface="history-desktop"
      />
      <.incident_cards
        id="admin-incidents-history-mobile"
        rows={@page.history}
        datetime_preferences={@datetime_preferences}
        surface="history-mobile"
      />
      <p
        :if={@page.history_overflow > 0}
        id="admin-incidents-history-overflow"
        class="text-sm text-base-content/60"
      >
        +{@page.history_overflow} more historical incidents are retained.
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :datetime_preferences, :map, required: true
  attr :surface, :string, required: true

  defp incident_table(assigns) do
    ~H"""
    <div
      id={@id}
      class="hidden overflow-x-auto rounded-box border border-base-300 bg-base-100 md:block"
    >
      <table class="table table-sm">
        <thead>
          <tr>
            <th>Incident</th>
            <th>Status</th>
            <th>Component</th>
            <th>Updated</th>
            <th>Source</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={row <- @rows}
            id={"#{@id}-row-#{row.id}"}
            data-role="openai-incident-row"
            data-incident-id={row.id}
          >
            <td class="max-w-xl">
              <div class="grid gap-1">
                <p class="font-semibold">{row.title}</p>
                <p :if={row.summary != ""} class="line-clamp-2 text-xs leading-5 text-base-content/60">
                  {row.summary}
                </p>
                <p class="text-xs text-base-content/50">
                  First seen {format_datetime(row.first_seen_at, @datetime_preferences)}
                </p>
              </div>
            </td>
            <td><.status_badge row={row} surface={@surface} /></td>
            <td class="text-sm text-base-content/70">{row.component}</td>
            <td class="whitespace-nowrap text-sm text-base-content/70">
              <div class="grid gap-1">
                <span>{format_datetime(row.last_seen_at, @datetime_preferences)}</span>
                <span :if={row.resolved_at}>
                  Resolved {format_datetime(row.resolved_at, @datetime_preferences)}
                </span>
                <span :if={row.retired_at}>
                  Retired {format_datetime(row.retired_at, @datetime_preferences)}
                </span>
              </div>
            </td>
            <td>
              <a
                :if={row.link}
                id={"#{@id}-source-#{row.id}"}
                data-role="incident-source-link"
                href={row.link}
                target="_blank"
                rel="noopener noreferrer"
                class="link link-primary text-sm"
              >View source</a>
              <span :if={!row.link} class="text-sm text-base-content/50">Unavailable</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :datetime_preferences, :map, required: true
  attr :surface, :string, required: true

  defp incident_cards(assigns) do
    ~H"""
    <div id={@id} class="grid gap-3 md:hidden">
      <article
        :for={row <- @rows}
        id={"#{@id}-card-#{row.id}"}
        data-role="openai-incident-card"
        data-incident-id={row.id}
        class="grid gap-3 rounded-box border border-base-300 bg-base-100 p-4"
      >
        <div class="flex items-start justify-between gap-3">
          <h3 class="font-semibold">{row.title}</h3>
          <.status_badge row={row} surface={@surface} />
        </div>
        <p :if={row.summary != ""} class="text-sm leading-5 text-base-content/70">{row.summary}</p>
        <dl class="grid gap-2 text-sm">
          <div class="flex justify-between gap-3">
            <dt class="text-base-content/50">Component</dt><dd class="text-right text-base-content/80">
              {row.component}
            </dd>
          </div>
          <div class="flex justify-between gap-3">
            <dt class="text-base-content/50">Updated</dt><dd class="text-right text-base-content/80">
              {format_datetime(row.last_seen_at, @datetime_preferences)}
            </dd>
          </div>
          <div class="flex justify-between gap-3">
            <dt class="text-base-content/50">First seen</dt><dd class="text-right text-base-content/80">
              {format_datetime(row.first_seen_at, @datetime_preferences)}
            </dd>
          </div>
          <div :if={row.resolved_at} class="flex justify-between gap-3">
            <dt class="text-base-content/50">Resolved</dt><dd class="text-right text-base-content/80">
              {format_datetime(row.resolved_at, @datetime_preferences)}
            </dd>
          </div>
          <div :if={row.retired_at} class="flex justify-between gap-3">
            <dt class="text-base-content/50">Retired</dt><dd class="text-right text-base-content/80">
              {format_datetime(row.retired_at, @datetime_preferences)}
            </dd>
          </div>
        </dl>
        <a
          :if={row.link}
          id={"#{@id}-source-#{row.id}"}
          data-role="incident-source-link"
          href={row.link}
          target="_blank"
          rel="noopener noreferrer"
          class="link link-primary text-sm"
        >View source</a>
      </article>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :surface, :string, required: true

  defp status_badge(assigns) do
    ~H"""
    <span
      id={"openai-incident-status-#{@surface}-#{@row.id}"}
      data-role="incident-status"
      data-status={@row.status_key}
      class={["badge badge-sm border-0", status_class(@row.status_key)]}
    >{@row.status}</span>
    """
  end

  defp status_class(:resolved), do: "bg-success/15 text-success"
  defp status_class(:monitoring), do: "bg-info/15 text-info"
  defp status_class(:identified), do: "bg-warning/15 text-warning"
  defp status_class(:investigating), do: "bg-error/15 text-error"
  defp status_class(:retired), do: "bg-base-300 text-base-content/70"
  defp status_class(_), do: "bg-base-300 text-base-content/70"

  defp feed_state(%{available?: false}), do: "unavailable"
  defp feed_state(%{last_error_code: code}) when is_binary(code), do: "error"
  defp feed_state(%{stale?: true}), do: "stale"
  defp feed_state(_), do: "current"

  defp feed_state_label(%{available?: false}), do: "Unavailable"
  defp feed_state_label(%{last_error_code: code}) when is_binary(code), do: "Last fetch failed"
  defp feed_state_label(%{stale?: true}), do: "Stale"
  defp feed_state_label(_), do: "Current"

  defp format_datetime(nil, _preferences), do: "not recorded"

  defp format_datetime(datetime, preferences),
    do: DateTimeDisplay.format_datetime(datetime, preferences)

  defp stale_copy(nil, _preferences),
    do: "Status data may be out of date. No successful refresh has been recorded yet."

  defp stale_copy(timestamp, preferences),
    do:
      "Status data may be out of date. The last successful fetch was #{format_datetime(timestamp, preferences)}."
end
