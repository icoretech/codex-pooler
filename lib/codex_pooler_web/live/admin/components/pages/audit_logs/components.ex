defmodule CodexPoolerWeb.Admin.AuditLogsComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.AuditLogsComponents.Filters
  alias CodexPoolerWeb.Admin.AuditLogsComponents.Prose
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.LogPagination

  import CodexPoolerWeb.Admin.AuditLogsComponents.Presentation,
    only: [
      actor_link: 1,
      audit_action_icon: 1,
      audit_action_icon_class: 1,
      detail_rows: 1,
      event_summary_rows: 1,
      event_title: 1,
      format_datetime: 2,
      format_total: 1,
      target_link: 1
    ]

  defdelegate audit_log_filters(assigns), to: Filters

  attr :audit_logs, :map, required: true
  attr :pool_names, :map, required: true
  attr :datetime_preferences, :map, required: true
  attr :previous_path, :string, default: nil
  attr :next_path, :string, default: nil

  def audit_prose_ledger(assigns) do
    assigns =
      assigns
      |> assign(:page, LogPagination.metadata(assigns.audit_logs))
      |> assign(
        :day_groups,
        group_events_by_day(assigns.audit_logs.items, assigns.datetime_preferences)
      )

    ~H"""
    <div id="admin-audit-logs-window" class="grid min-w-0 gap-3">
      <LogPagination.pager
        :if={@audit_logs.items != []}
        id="audit-log-pagination"
        label="Audit log pagination"
        page={@page}
        previous_path={@previous_path}
        next_path={@next_path}
      />

      <AdminComponents.empty_state
        :if={@audit_logs.items == []}
        id="audit-log-empty-state"
        icon="hero-clipboard-document-list"
        title="No audit events"
        description={empty_copy()}
      />

      <div :if={@audit_logs.items != []} id="admin-audit-logs" class="grid min-w-0 gap-3">
        <%!-- The pager carries the count and the way to move; this names the
        list and its total for a screen reader before the sentences, which is
        the one thing the pager cannot do. --%>
        <p class="sr-only">
          Audit logs, {format_total(@audit_logs.total)} matching redacted audit events
        </p>
        <section
          :for={{day, events} <- @day_groups}
          class="min-w-0 rounded-box border border-base-300 bg-base-100 px-4 pt-3 pb-1"
        >
          <p
            data-role="audit-day-break"
            class="mb-1 text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/38"
          >
            {day}
          </p>
          <ol class="min-w-0 list-none">
            <li
              :for={event <- events}
              id={"audit-log-row-#{event.id}"}
              data-role="audit-prose-event"
              class="-mx-4 flex min-w-0 items-start gap-2.5 border-b border-base-300/55 px-4 pt-[9.5px] pb-[6.5px] transition-colors last:border-b-0 hover:bg-base-200/40"
            >
              <button
                type="button"
                data-role="audit-prose-family"
                class="mt-[1.5px] flex shrink-0 cursor-pointer transition-opacity hover:opacity-70"
                aria-label={"Filter by event: #{event_title(event)}"}
                title={"Filter by event: #{event_title(event)}"}
                phx-click="select_action_filter"
                phx-value-action={event.action}
              >
                <.icon
                  name={audit_action_icon(event.action)}
                  class={["size-4", audit_action_icon_class(event.action)]}
                />
              </button>
              <Prose.event_sentence
                event={event}
                pool_names={@pool_names}
                datetime_preferences={@datetime_preferences}
              />
              <button
                type="button"
                id={"audit-log-details-#{event.id}"}
                data-role="audit-prose-details"
                class="flex shrink-0 self-center cursor-pointer text-base-content/25 transition-colors hover:text-primary"
                aria-haspopup="dialog"
                aria-controls="audit-event-details-sidebar"
                aria-label={"Inspect event details for #{event_title(event)}"}
                phx-click="show_audit_event"
                phx-value-id={event.id}
              >
                <.icon name="hero-chevron-right" class="size-4" />
              </button>
            </li>
          </ol>
        </section>
      </div>
    </div>
    """
  end

  defp group_events_by_day(events, datetime_preferences) do
    events
    |> Enum.chunk_by(&event_day_label(&1, datetime_preferences))
    |> Enum.map(fn [first | _rest] = chunk ->
      {event_day_label(first, datetime_preferences), chunk}
    end)
  end

  defp event_day_label(event, datetime_preferences) do
    case CodexPoolerWeb.DateTimeDisplay.format_datetime_parts(
           event.occurred_at,
           datetime_preferences
         ) do
      %{date: date} -> date
      nil -> "Undated"
    end
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

  defp empty_copy do
    "No audit logs yet. Create operator activity or loosen the filters to see redacted audit events."
  end
end
