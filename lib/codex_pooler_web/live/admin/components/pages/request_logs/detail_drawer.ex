defmodule CodexPoolerWeb.Admin.RequestLogDetailDrawer do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.RequestLogDetailDrawer.Attempts
  alias CodexPoolerWeb.Admin.RequestLogDetailDrawer.Format
  alias CodexPoolerWeb.Admin.RequestLogDetailDrawer.Rows

  attr :selected_request_log, :map, default: nil
  attr :datetime_preferences, :map, required: true

  @spec request_log_detail_drawer(map()) :: Phoenix.LiveView.Rendered.t()
  def request_log_detail_drawer(assigns) do
    ~H"""
    <div class="drawer-side z-[70]" data-role="request-log-detail-drawer-side">
      <label
        for="request-log-detail-drawer"
        aria-label={gettext("Close request details")}
        class="drawer-overlay"
        phx-click="close_request_log"
      ></label>

      <AdminComponents.object_inspector
        id="request-log-detail-sidebar"
        title={Format.request_log_title(@selected_request_log)}
        subtitle={Format.request_log_subtitle(@selected_request_log)}
        status={Format.request_log_status(@selected_request_log)}
        status_class={Format.request_log_status_class(@selected_request_log)}
        close_event="close_request_log"
        close_label={gettext("Close request details")}
        role="dialog"
        aria_modal={true}
        class="flex min-h-full w-full max-w-2xl flex-col overflow-hidden border-l border-base-300 bg-base-100 shadow-2xl"
      >
        <%= if @selected_request_log do %>
          <section id="request-log-detail-outcome" class="grid gap-3">
            <.section_heading title={gettext("Final outcome")} />
            <dl class="grid gap-2 text-sm sm:grid-cols-2">
              <.detail_row
                :for={row <- Rows.final_outcome_rows(@selected_request_log, @datetime_preferences)}
                row={row}
              />
            </dl>
          </section>

          <section
            :if={Rows.compaction_bridge_rows(@selected_request_log) != []}
            id="request-log-detail-compaction-bridge"
            class="grid gap-3"
          >
            <.section_heading title={gettext("Compaction bridge")} />
            <dl class="grid gap-2 text-sm sm:grid-cols-2">
              <.detail_row
                :for={row <- Rows.compaction_bridge_rows(@selected_request_log)}
                row={row}
              />
            </dl>
          </section>

          <section id="request-log-detail-attempts" class="grid gap-3">
            <.section_heading title={gettext("Attempts timeline")} />
            <div
              :if={Attempts.debug_attempts(@selected_request_log) == []}
              class="text-sm text-base-content/60"
            >
              {gettext("No upstream attempts recorded.")}
            </div>
            <div
              :for={attempt <- Attempts.debug_attempts(@selected_request_log)}
              id={"request-log-detail-attempt-#{attempt.attempt_number}"}
              data-role="request-log-detail-attempt"
              class="grid gap-3 rounded-box border border-base-300 bg-base-200/35 px-3 py-3"
            >
              <div class="flex min-w-0 flex-wrap items-center gap-2">
                <span class="font-semibold text-base-content">
                  {gettext("Attempt %{number}", number: Format.safe_text(attempt.attempt_number))}
                </span>
                <span class={Format.status_chip_class(attempt.status)}>
                  {Format.safe_text(Format.request_log_status(attempt))}
                </span>
                <span
                  :if={attempt.final}
                  class={AdminBadges.metadata_chip_class(:primary)}
                >
                  {gettext("final")}
                </span>
                <span
                  :if={attempt.retryable}
                  class={AdminBadges.metadata_chip_class(:warning)}
                >
                  {gettext("retryable")}
                </span>
              </div>
              <dl class="grid gap-2 text-sm sm:grid-cols-2">
                <.detail_row :for={row <- Attempts.attempt_rows(attempt)} row={row} />
              </dl>
            </div>
          </section>

          <section id="request-log-detail-transport-failures" class="grid gap-3">
            <.section_heading title={gettext("Transport failure diagnostics")} />
            <div
              :if={Attempts.transport_failure_attempts(@selected_request_log) == []}
              class="rounded-box border border-base-300 bg-base-200/35 px-3 py-3 text-sm text-base-content/60"
            >
              {gettext("No compact transport failure metadata recorded.")}
            </div>
            <div
              :for={attempt <- Attempts.transport_failure_attempts(@selected_request_log)}
              id={"request-log-detail-transport-failure-#{attempt.attempt_number}"}
              data-role="transport-failure"
              class="grid gap-3 rounded-box border border-error/20 bg-error/5 px-3 py-3"
            >
              <p class="text-sm font-semibold text-error">
                {gettext("Attempt %{number}", number: Format.safe_text(attempt.attempt_number))}
              </p>
              <dl class="grid gap-2 text-sm sm:grid-cols-2">
                <.detail_row :for={row <- Attempts.transport_failure_rows(attempt)} row={row} />
              </dl>
            </div>
          </section>

          <section id="request-log-detail-routing" class="grid gap-3">
            <.section_heading title={gettext("Routing summary")} />
            <dl class="grid gap-2 text-sm sm:grid-cols-2">
              <.detail_row
                :for={row <- Rows.routing_rows(@selected_request_log)}
                row={row}
              />
            </dl>
          </section>

          <section id="request-log-detail-usage" class="grid gap-3">
            <.section_heading title={gettext("Usage and cost")} />
            <dl class="grid gap-2 text-sm sm:grid-cols-2">
              <.detail_row
                :for={row <- Rows.usage_rows(@selected_request_log)}
                row={row}
              />
            </dl>
          </section>

          <section id="request-log-detail-continuity" class="grid gap-3">
            <.section_heading title={gettext("Continuity and debug summary")} />
            <dl class="grid gap-2 text-sm sm:grid-cols-2">
              <.detail_row
                :for={row <- Rows.continuity_rows(@selected_request_log, @datetime_preferences)}
                row={row}
              />
            </dl>
          </section>

          <section id="request-log-detail-sanitized-metadata" class="grid gap-3">
            <.section_heading title={gettext("Sanitized metadata")} />
            <dl class="grid gap-2 text-sm sm:grid-cols-2">
              <.detail_row
                :for={row <- Rows.sanitized_metadata_rows(@selected_request_log)}
                row={row}
              />
            </dl>
          </section>
        <% else %>
          <div class="grid min-h-64 place-items-center text-center text-sm text-base-content/60">
            {gettext("Select a request to inspect sanitized diagnostics.")}
          </div>
        <% end %>
      </AdminComponents.object_inspector>
    </div>
    """
  end

  attr :title, :string, required: true

  defp section_heading(assigns) do
    ~H"""
    <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/45">{@title}</h3>
    """
  end

  attr :row, :map, required: true

  defp detail_row(assigns) do
    ~H"""
    <div
      id={@row.id}
      data-role={@row[:role] || "request-log-detail-field"}
      class="grid min-w-0 gap-1 rounded-box bg-base-200/60 px-3 py-2"
    >
      <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
        {@row.label}
      </dt>
      <dd class={["min-w-0 [overflow-wrap:anywhere] text-base-content/80", @row[:mono] && "font-mono text-xs tabular-nums"]}>
        {Format.safe_text(@row.value)}
      </dd>
    </div>
    """
  end
end
