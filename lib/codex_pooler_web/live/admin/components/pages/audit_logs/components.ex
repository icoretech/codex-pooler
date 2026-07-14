defmodule CodexPoolerWeb.Admin.AuditLogsComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.AuditLogsComponents.Filters
  alias CodexPoolerWeb.Admin.LogPagination

  import CodexPoolerWeb.Admin.AuditLogsComponents.Presentation,
    only: [
      actor_link: 1,
      detail_rows: 1,
      event_icon: 1,
      event_icon_class: 1,
      event_summary_rows: 1,
      event_title: 1,
      format_actor: 1,
      format_datetime: 2,
      format_total: 1,
      target_label: 1,
      target_link: 1
    ]

  defdelegate audit_log_filters(assigns), to: Filters

  attr :audit_logs, :map, required: true
  attr :current_params, :map, required: true
  attr :datetime_preferences, :map, required: true

  def audit_logs_table(assigns) do
    ~H"""
    <div
      id="admin-audit-logs"
      class="min-w-0 rounded-box border border-base-300 bg-base-100 shadow-sm"
    >
      <LogPagination.controls
        page={@audit_logs}
        base_path="/admin/audit-logs"
        current_params={@current_params}
        id_prefix="admin-audit-logs-pagination-top"
        range_id="admin-audit-logs-range-top"
        range_role="audit-logs-range"
        label="Audit logs"
        placement={:top}
      />

      <div class="hidden overflow-x-auto md:block">
        <table class="table min-w-[58rem] font-sans">
          <colgroup>
            <col style="width: 2.5rem; min-width: 2.5rem; max-width: 2.5rem;" />
            <col class="w-36" />
            <col />
            <col class="w-[22rem]" />
            <col class="w-[24rem]" />
          </colgroup>
          <thead>
            <tr>
              <th
                class="w-10 min-w-10 max-w-10 text-center"
                style="padding-left: 0; padding-right: 0;"
                aria-label="Event type"
              >
              </th>
              <th
                class="whitespace-nowrap"
                style="padding-left: 0; padding-right: 0.75rem;"
              >
                Time
              </th>
              <th class="whitespace-nowrap">Event</th>
              <th class="whitespace-nowrap">Actor</th>
              <th class="whitespace-nowrap">Context</th>
            </tr>
          </thead>
          <tbody id="audit-logs-table">
            <tr
              id="audit-log-empty-state"
              class={[@audit_logs.items != [] && "hidden", "only:table-row"]}
            >
              <td colspan="5" class="py-8 text-center text-sm text-base-content/60">
                No audit logs yet. Create operator activity or loosen the filters to see redacted audit events.
              </td>
            </tr>
            <tr
              :for={event <- @audit_logs.items}
              id={"audit-log-row-#{event.id}"}
              class="text-sm transition-colors hover:bg-base-200/80"
            >
              <td
                class="w-10 min-w-10 max-w-10 align-middle text-center"
                style="padding-left: 0; padding-right: 0;"
              >
                <.icon name={event_icon(event)} class={event_icon_class(event.outcome)} />
              </td>
              <td
                class="whitespace-nowrap align-middle text-sm"
                style="padding-left: 0; padding-right: 0.75rem;"
              >
                <button
                  id={"audit-log-time-#{event.id}"}
                  type="button"
                  class="whitespace-nowrap text-left text-base-content/60 underline-offset-2 transition-colors hover:text-primary hover:underline"
                  aria-haspopup="dialog"
                  aria-controls="audit-event-details-sidebar"
                  phx-click="show_audit_event"
                  phx-value-id={event.id}
                >
                  {format_datetime(event.occurred_at, @datetime_preferences)}
                </button>
              </td>
              <td class="align-middle">
                <span
                  class="block truncate font-medium leading-5 text-base-content"
                  title={event_title(event)}
                >
                  {event_title(event)}
                </span>
              </td>
              <td class="align-middle">
                <.link
                  :if={actor_link(event)}
                  navigate={actor_link(event)}
                  class="block truncate font-medium leading-5 text-primary hover:text-primary/80"
                  title={format_actor(event)}
                >
                  {format_actor(event)}
                </.link>
                <span
                  :if={!actor_link(event)}
                  class="block truncate font-medium leading-5 text-base-content"
                  title={format_actor(event)}
                >
                  {format_actor(event)}
                </span>
              </td>
              <td class="align-middle">
                <div class="flex min-w-0 items-center gap-2 text-sm text-base-content/70">
                  <.link
                    :if={target_link(event)}
                    navigate={target_link(event)}
                    class="truncate leading-5 text-primary hover:text-primary/80"
                    title={target_label(event)}
                  >
                    {target_label(event)}
                  </.link>
                  <span
                    :if={!target_link(event)}
                    class="truncate leading-5 text-base-content"
                    title={target_label(event)}
                  >
                    {target_label(event)}
                  </span>
                </div>
              </td>
            </tr>
          </tbody>
          <caption
            id="audit-log-page-size"
            class="caption-bottom px-4 py-3 text-left text-xs text-base-content/60"
          >
            {format_total(@audit_logs.total)} matching redacted audit events · Hard limit: {@audit_logs.limit} rows
          </caption>
        </table>
      </div>
      <div id="mobile-audit-logs-table" class="overflow-x-auto md:hidden">
        <table class="table table-sm w-[42rem] min-w-[42rem] font-sans">
          <colgroup>
            <col style="width: 2.5rem; min-width: 2.5rem; max-width: 2.5rem;" />
            <col style="width: 9.75rem; min-width: 9.75rem;" />
            <col style="width: 16rem; min-width: 16rem;" />
            <col style="width: 13.75rem; min-width: 13.75rem;" />
          </colgroup>
          <thead>
            <tr>
              <th
                class="w-10 min-w-10 max-w-10 text-center"
                style="padding-left: 0; padding-right: 0;"
                aria-label="Event type"
              >
              </th>
              <th
                class="whitespace-nowrap"
                style="padding-left: 0; padding-right: 0.75rem;"
              >
                Time
              </th>
              <th class="whitespace-nowrap">Event</th>
              <th class="whitespace-nowrap">Actor</th>
            </tr>
          </thead>
          <tbody id="mobile-audit-logs-table-body">
            <tr
              id="mobile-audit-log-empty-state"
              class={[@audit_logs.items != [] && "hidden", "only:table-row"]}
            >
              <td colspan="4" class="py-8 text-center text-sm text-base-content/60">
                No audit logs yet. Create operator activity or loosen the filters to see redacted audit events.
              </td>
            </tr>
            <tr
              :for={event <- @audit_logs.items}
              id={"mobile-audit-log-row-#{event.id}"}
              class="text-sm transition-colors hover:bg-base-200/80"
            >
              <td
                class="w-10 min-w-10 max-w-10 align-middle text-center"
                style="padding-left: 0; padding-right: 0;"
              >
                <.icon name={event_icon(event)} class={event_icon_class(event.outcome)} />
              </td>
              <td
                class="whitespace-nowrap align-middle text-sm"
                style="padding-left: 0; padding-right: 0.75rem;"
              >
                <button
                  id={"mobile-audit-log-time-#{event.id}"}
                  type="button"
                  class="whitespace-nowrap text-left text-primary underline-offset-2 transition-colors hover:text-primary/80 hover:underline"
                  aria-haspopup="dialog"
                  aria-controls="audit-event-details-sidebar"
                  phx-click="show_audit_event"
                  phx-value-id={event.id}
                >
                  {format_datetime(event.occurred_at, @datetime_preferences)}
                </button>
              </td>
              <td class="align-middle">
                <span
                  class="block truncate font-medium leading-5 text-base-content"
                  title={event_title(event)}
                >
                  {event_title(event)}
                </span>
              </td>
              <td class="align-middle">
                <.link
                  :if={actor_link(event)}
                  navigate={actor_link(event)}
                  class="block truncate font-medium leading-5 text-primary hover:text-primary/80"
                  title={format_actor(event)}
                >
                  {format_actor(event)}
                </.link>
                <span
                  :if={!actor_link(event)}
                  class="block truncate font-medium leading-5 text-base-content"
                  title={format_actor(event)}
                >
                  {format_actor(event)}
                </span>
              </td>
            </tr>
          </tbody>
          <caption class="caption-bottom px-3 py-3 text-left text-xs text-base-content/60">
            {format_total(@audit_logs.total)} matching redacted audit events · Open a time for full details
          </caption>
        </table>
      </div>

      <LogPagination.controls
        page={@audit_logs}
        base_path="/admin/audit-logs"
        current_params={@current_params}
        id_prefix="admin-audit-logs-pagination-bottom"
        range_id="admin-audit-logs-range-bottom"
        range_role="audit-logs-range"
        label="Audit logs"
        placement={:bottom}
      />
    </div>
    """
  end

  attr :selected_audit_event, :map, default: nil
  attr :datetime_preferences, :map, required: true

  def audit_event_drawer(assigns) do
    ~H"""
    <div class="drawer-side z-[70]">
      <label
        for="audit-event-details-drawer"
        aria-label="close event details"
        class="drawer-overlay"
        phx-click="close_audit_event"
      ></label>
      <aside
        id="audit-event-details-sidebar"
        class="flex min-h-full w-full max-w-md flex-col border-l border-base-300 bg-base-100 shadow-2xl"
        role="dialog"
        aria-modal="true"
        aria-labelledby="audit-event-details-title"
      >
        <%= if @selected_audit_event do %>
          <header class="shrink-0 border-b border-base-300 px-5 py-4">
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0">
                <p class="text-xs font-semibold uppercase tracking-wide text-primary">
                  Event details
                </p>
                <h2
                  id="audit-event-details-title"
                  class="mt-1 truncate text-lg font-bold text-base-content"
                >
                  {event_title(@selected_audit_event)}
                </h2>
                <p class="mt-1 text-sm text-base-content/60">
                  {format_datetime(@selected_audit_event.occurred_at, @datetime_preferences)}
                </p>
              </div>
              <button
                id="audit-event-details-close"
                type="button"
                class="btn btn-ghost btn-sm btn-square"
                aria-label="Close event details"
                phx-click="close_audit_event"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
            </div>
          </header>

          <section class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
            <dl id="audit-event-detail-summary" class="grid gap-3 text-sm">
              <div
                :for={{label, value} <- event_summary_rows(@selected_audit_event)}
                class="grid gap-1 rounded-box border border-base-300 bg-base-200/50 px-3 py-2"
              >
                <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                  {label}
                </dt>
                <dd class="break-words text-base-content">{value}</dd>
              </div>
            </dl>

            <div id="audit-event-detail-links" class="mt-4 flex flex-wrap gap-2">
              <.link
                :if={actor_link(@selected_audit_event)}
                navigate={actor_link(@selected_audit_event)}
                class="btn btn-outline btn-sm"
              >
                Open operator
              </.link>
              <.link
                :if={target_link(@selected_audit_event)}
                navigate={target_link(@selected_audit_event)}
                class="btn btn-primary btn-sm"
              >
                Open related record
              </.link>
            </div>

            <div id="audit-event-detail-metadata" class="mt-5">
              <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                Sanitized details
              </h3>
              <dl class="mt-2 grid gap-2 text-sm">
                <div
                  :for={{label, value} <- detail_rows(@selected_audit_event.details)}
                  class="grid gap-1 rounded-box bg-base-200/60 px-3 py-2"
                >
                  <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                    {label}
                  </dt>
                  <dd class="break-words text-base-content/80">{value}</dd>
                </div>
                <p
                  :if={detail_rows(@selected_audit_event.details) == []}
                  class="rounded-box bg-base-200/60 px-3 py-2 text-sm text-base-content/60"
                >
                  No extra sanitized details recorded.
                </p>
              </dl>
            </div>
          </section>
        <% else %>
          <div class="grid min-h-full place-items-center p-6 text-center text-sm text-base-content/60">
            Select an event time to inspect its details.
          </div>
        <% end %>
      </aside>
    </div>
    """
  end
end
