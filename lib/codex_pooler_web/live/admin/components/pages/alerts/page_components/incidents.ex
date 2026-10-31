defmodule CodexPoolerWeb.Admin.AlertsPageComponents.Incidents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.Alerts.Schemas.AlertIncident
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolFilterComponents
  alias Phoenix.LiveView.JS

  attr :selected_tab, :string, required: true
  attr :incident_filter_form, :any, required: true
  attr :incident_filter_values, :map, required: true
  attr :incident_pool_filter_options, :list, required: true
  attr :incident_severity_filter_options, :list, required: true
  attr :incident_state_filter_options, :list, required: true
  attr :incident_rule_filter_options, :list, required: true
  attr :incident_channel_filter_options, :list, required: true
  attr :incident_filter_errors, :list, required: true
  attr :incidents, :list, required: true
  attr :incident_total_count, :integer, required: true
  attr :incident_page_size, :integer, required: true

  @spec incidents_section(map()) :: Phoenix.LiveView.Rendered.t()
  def incidents_section(assigns) do
    ~H"""
    <div
      :if={@selected_tab == "incidents"}
      id="alerts-incidents-section"
      class="grid min-w-0 gap-4"
    >
      <AdminComponents.filter_form
        id="alerts-incidents-filter-form"
        for={@incident_filter_form}
        phx-change="filter_incidents"
        phx-submit="filter_incidents"
        mobile_single_column
        single_row
        control_size={:default}
      >
        <PoolFilterComponents.pool_filter_dropdown
          id="alerts-incident-pool-filter"
          label={gettext("Impacted Pool")}
          hidden_id="filters_pool_id"
          event="select_incident_pool_filter"
          selected_value={@incident_filter_values["pool_id"] || ""}
          options={@incident_pool_filter_options}
        />
        <.incident_filter_dropdown
          id="alerts-incident-severity-filter"
          label={gettext("Severity")}
          field_name="severity"
          hidden_id="filters_severity"
          role="severity-filter"
          selected_value={@incident_filter_values["severity"] || ""}
          options={@incident_severity_filter_options}
        />
        <.incident_filter_dropdown
          id="alerts-incident-state-filter"
          label={gettext("State")}
          field_name="state"
          hidden_id="filters_state"
          role="state-filter"
          selected_value={@incident_filter_values["state"] || ""}
          options={@incident_state_filter_options}
        />
        <.incident_filter_dropdown
          id="alerts-incident-rule-filter"
          label={gettext("Rule")}
          field_name="rule_id"
          hidden_id="filters_rule_id"
          role="rule-filter"
          selected_value={@incident_filter_values["rule_id"] || ""}
          options={@incident_rule_filter_options}
        />
        <.incident_filter_dropdown
          id="alerts-incident-channel-filter"
          label={gettext("Channel")}
          field_name="channel_id"
          hidden_id="filters_channel_id"
          role="channel-filter"
          selected_value={@incident_filter_values["channel_id"] || ""}
          options={@incident_channel_filter_options}
        />
      </AdminComponents.filter_form>

      <div
        :if={@incident_filter_errors != []}
        id="alerts-incidents-filter-errors"
        class="alert alert-warning items-start"
      >
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <div>
          <p class="font-semibold">{gettext("Some filters were ignored")}</p>
          <ul class="mt-1 list-disc space-y-1 pl-5 text-sm">
            <li
              :for={error <- @incident_filter_errors}
              id={"alerts-incidents-filter-error-#{error.field}"}
            >
              {error.message}
            </li>
          </ul>
        </div>
      </div>

      <AdminComponents.admin_surface
        id="alerts-incidents-list"
        title={gettext("Incidents")}
        description={gettext("Recent alert incidents projected through the current operator's Pool visibility.")}
        count={incident_count_label(@incident_total_count, @incident_page_size)}
        overflow={:visible}
      >
        <AdminComponents.empty_state
          :if={@incidents == []}
          id="alerts-incidents-empty-state"
          title={gettext("No alert incidents")}
          description={gettext("No visible alert incidents match the selected filters.")}
          icon="hero-bell-alert"
        />

        <div
          :if={@incidents != []}
          id="alerts-incident-table-scroll-region"
          class="lg:overflow-x-auto"
        >
          <table
            id="alerts-incident-table"
            class="admin-ledger-table table table-sm admin-log-table lg:min-w-[60rem]"
          >
            <caption class="sr-only">{gettext("Alert incidents")}</caption>
            <colgroup>
              <col />
              <col style="width: 12rem;" />
              <col style="width: 11rem;" />
              <col style="width: 9rem;" />
              <col style="width: 14rem;" />
            </colgroup>
            <thead>
              <tr>
                <th class="whitespace-nowrap">{gettext("Incident")}</th>
                <th class="whitespace-nowrap">{gettext("Status")}</th>
                <th class="whitespace-nowrap">{gettext("Delivery")}</th>
                <th class="whitespace-nowrap">{gettext("Last seen")}</th>
                <th class="whitespace-nowrap text-right">{gettext("Actions")}</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={incident <- @incidents}
                id={"alert-incident-#{incident.id}"}
                class="transition-colors hover:bg-base-200/60"
                data-role="alert-incident-row"
                data-alert-anchor-id={"alert-incident-#{incident.id}"}
              >
                <td class="min-w-0 align-middle max-lg:col-span-2 max-lg:col-start-1 max-lg:row-start-1 max-lg:sm:col-span-1">
                  <div class="grid min-w-0 gap-1">
                    <span
                      id={"alert-incident-row-#{incident.id}-reason"}
                      data-role="incident-reason"
                      class="text-[0.82rem] font-semibold leading-tight text-base-content"
                    >
                      {incident.reason_title}
                    </span>
                    <span
                      id={"alert-incident-row-#{incident.id}-detail"}
                      data-role="incident-detail"
                      title={incident.reason_detail}
                      class="line-clamp-3 text-xs leading-4 text-base-content/55"
                    >
                      {incident.reason_detail}
                    </span>
                    <div class="flex flex-wrap items-center gap-1">
                      <span
                        id={"alert-incident-row-#{incident.id}-kind"}
                        data-role="incident-kind"
                        class="inline-flex h-4.5 items-center whitespace-nowrap rounded-full bg-base-200 px-2 text-[10px] font-medium leading-none text-base-content/65"
                      >
                        {incident.rule_kind_label}
                      </span>
                      <.impacted_pool_list incident={incident} prefix="alert-incident-row" />
                    </div>
                  </div>
                </td>
                <td class="align-middle max-lg:col-span-2 max-lg:col-start-1 max-lg:row-start-2 max-lg:sm:col-span-1 max-lg:sm:col-start-2 max-lg:sm:row-start-1 max-lg:sm:justify-self-end">
                  <div class="flex flex-wrap items-center gap-1 max-lg:sm:justify-end">
                    <span
                      id={"alert-incident-row-#{incident.id}-state"}
                      data-role="incident-state"
                      class={[incident_chip_base(), AdminBadges.status_chip_class(incident.state)]}
                    >
                      <.icon name={state_icon(incident.state)} class="size-3 shrink-0" />{incident.state_label}
                    </span>
                    <span
                      id={"alert-incident-row-#{incident.id}-severity"}
                      data-role="incident-severity"
                      class={[incident_chip_base(), severity_chip_class(incident.severity)]}
                    >
                      <.icon name={severity_icon(incident.severity)} class="size-3 shrink-0" />{incident.severity_label}
                    </span>
                  </div>
                </td>
                <td
                  id={"alert-incident-row-#{incident.id}-delivery"}
                  class="min-w-0 align-middle text-xs max-lg:col-span-2 max-lg:col-start-1 max-lg:row-start-4 max-lg:mt-1 max-lg:sm:col-span-1 max-lg:sm:row-start-3"
                >
                  <.incident_delivery_summary incident={incident} prefix="alert-incident-row" />
                </td>
                <td
                  id={"alert-incident-row-#{incident.id}-last-seen"}
                  class="whitespace-nowrap align-middle text-xs tabular-nums text-base-content/65 max-lg:col-span-2 max-lg:col-start-1 max-lg:row-start-3 max-lg:mt-1 max-lg:sm:col-span-1 max-lg:sm:row-start-2"
                >
                  {format_datetime(incident.last_seen_at)}
                </td>
                <td class="align-middle max-lg:col-span-2 max-lg:col-start-1 max-lg:row-start-5 max-lg:mt-2 max-lg:sm:row-start-4">
                  <.incident_action_controls incident={incident} prefix="alert-incident" />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </AdminComponents.admin_surface>
    </div>
    """
  end

  defp incident_count_label(total, page_size) when total > page_size,
    do: ngettext("%{shown} of %{count} incident", "%{shown} of %{count} incidents", total, shown: page_size)

  defp incident_count_label(total, _page_size),
    do: ngettext("%{count} incident", "%{count} incidents", total)

  attr :incident, :map, required: true
  attr :prefix, :string, required: true

  @spec impacted_pool_list(map()) :: Phoenix.LiveView.Rendered.t()
  def impacted_pool_list(assigns) do
    ~H"""
    <div
      id={"#{@prefix}-#{@incident.id}-impacted-pools"}
      data-role="incident-impacted-pools"
      class="contents"
    >
      <span
        :if={@incident.impacted_pools == []}
        id={"#{@prefix}-#{@incident.id}-no-visible-impacted-pools"}
        data-role="incident-no-visible-impacted-pools"
        class="text-[11px] text-base-content/55"
      >
        {gettext("No visible impacted Pools")}
      </span>
      <span
        :for={pool <- @incident.impacted_pools}
        id={"#{@prefix}-#{@incident.id}-impacted-pool-#{pool.id}"}
        data-role="incident-impacted-pool"
        class="inline-flex h-4.5 max-w-40 items-center rounded-full border border-base-300 px-2 text-[10px] font-medium leading-none text-base-content/70"
      >
        <span data-role="incident-impacted-pool-name" class="truncate">{pool.name}</span>
      </span>
      <span
        :if={@incident.hidden_impacted_pool_count > 0}
        id={"#{@prefix}-#{@incident.id}-hidden-pool-count"}
        data-role="incident-hidden-pool-count"
        class="text-[11px] font-medium text-warning"
      >
        {hidden_pool_count_label(@incident.hidden_impacted_pool_count)}
      </span>
    </div>
    """
  end

  attr :incident, :map, required: true
  attr :prefix, :string, required: true

  @spec incident_action_controls(map()) :: Phoenix.LiveView.Rendered.t()
  def incident_action_controls(assigns) do
    ~H"""
    <div id={"#{@prefix}-#{@incident.id}-actions"} class="flex flex-wrap justify-end gap-2 lg:flex-nowrap">
      <AdminComponents.action_button
        :if={@incident.state == AlertIncident.open_state()}
        id={incident_action_id(@prefix, @incident.id, "acknowledge")}
        icon="hero-hand-raised"
        label={gettext("Acknowledge")}
        phx-click="acknowledge_incident"
        phx-value-id={@incident.id}
      />
      <AdminComponents.action_button
        :if={@incident.state != AlertIncident.resolved_state()}
        id={incident_action_id(@prefix, @incident.id, "resolve")}
        icon="hero-check-circle"
        label={gettext("Resolve")}
        phx-click="resolve_incident"
        phx-value-id={@incident.id}
        variant={:primary}
      />
      <span
        :if={@incident.state == AlertIncident.resolved_state()}
        id={"#{@prefix}-#{@incident.id}-actions-resolved"}
        class="text-xs font-medium text-base-content/50"
      >
        {gettext("No pending actions")}
      </span>
    </div>
    """
  end

  attr :incident, :map, required: true
  attr :prefix, :string, required: true

  @spec incident_delivery_summary(map()) :: Phoenix.LiveView.Rendered.t()
  def incident_delivery_summary(assigns) do
    ~H"""
    <div class="grid gap-1.5">
      <p
        id={"#{@prefix}-#{@incident.id}-delivery-label"}
        data-role="incident-delivery-label"
        class={[@incident.delivery_summary.attempts == [] && "text-base-content/50"]}
      >
        {@incident.delivery_summary.label}
      </p>
      <ul
        :if={@incident.delivery_summary.attempts != []}
        id={"#{@prefix}-#{@incident.id}-delivery-attempts"}
        data-role="incident-delivery-attempts"
        class="grid gap-1.5"
      >
        <li
          :for={attempt <- @incident.delivery_summary.attempts}
          id={"#{@prefix}-#{@incident.id}-delivery-attempt-#{attempt.id}"}
          data-role="incident-delivery-attempt"
          class="grid gap-0.5"
        >
          <div class="flex flex-wrap items-center gap-1.5">
            <span
              data-role="incident-delivery-attempt-channel"
              class="font-medium text-base-content/80"
            >
              {attempt.channel_label}
            </span>
            <span
              data-role="incident-delivery-attempt-status"
              class={[incident_chip_base(), AdminBadges.status_chip_class(attempt.status)]}
            >
              {attempt.status_label}
            </span>
          </div>
          <p
            id={"#{@prefix}-#{@incident.id}-delivery-attempt-#{attempt.id}-meta"}
            data-role="incident-delivery-attempt-meta"
            class="text-[11px] leading-4 tabular-nums text-base-content/55"
          >
            {ngettext("Delivery attempt %{count} · %{time}", "Delivery attempt %{count} · %{time}", attempt.attempt_number, time: format_datetime(attempt.attempted_at || attempt.completed_at))}
          </p>
          <details :if={attempt.details != []} class="text-[11px] leading-4 text-base-content/55">
            <summary class="w-fit cursor-pointer select-none text-base-content/60 hover:text-base-content">
              {gettext("Details")}
            </summary>
            <dl
              id={"#{@prefix}-#{@incident.id}-delivery-attempt-#{attempt.id}-details"}
              data-role="incident-delivery-attempt-details"
              class="mt-1 grid gap-0.5"
            >
              <div
                :for={detail <- attempt.details}
                class="grid grid-cols-[6rem_minmax(0,1fr)] gap-2"
              >
                <dt class="text-base-content/45">{detail.label}</dt>
                <dd class="min-w-0 break-words text-base-content/70">{detail.value}</dd>
              </div>
            </dl>
          </details>
        </li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :field_name, :string, required: true
  attr :hidden_id, :string, required: true
  attr :role, :string, required: true
  attr :selected_value, :string, required: true
  attr :options, :list, required: true

  defp incident_filter_dropdown(assigns) do
    assigns =
      assign(
        assigns,
        :selected,
        selected_incident_filter_option(assigns.options, assigns.selected_value)
      )

    ~H"""
    <div class="grid gap-2">
      <input
        type="hidden"
        id={@hidden_id}
        name={"filters[#{@field_name}]"}
        value={@selected_value}
      />
      <details
        id={@id}
        class="dropdown w-full"
        phx-click-away={JS.remove_attribute("open", to: "##{@id}")}
      >
        <summary
          data-role={"#{@role}-trigger"}
          aria-label={@label}
          class="select flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal"
        >
          <span data-role={"#{@role}-icon"} class="shrink-0">
            <.icon name={@selected.icon} class={["size-4", incident_filter_icon_class(@selected)]} />
          </span>
          <span class="truncate">{@selected.label}</span>
        </summary>
        <ul
          data-role={"#{@role}-menu"}
          class="menu dropdown-content z-[60] mt-1 max-h-80 w-full flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 !transition-none ![scale:100%] shadow-xl"
        >
          <li :for={option <- @options}>
            <button
              type="button"
              phx-click="select_incident_filter"
              phx-value-field={@field_name}
              phx-value-filter-value={option.value}
              data-role={"#{@role}-option"}
              data-filter-value={option.value}
              class={[
                "flex items-center gap-2 text-sm",
                option.value == (@selected_value || "") && "active"
              ]}
              aria-current={option.value == (@selected_value || "") && "true"}
            >
              <span data-role={"#{@role}-icon"} class="shrink-0">
                <.icon name={option.icon} class={["size-4", incident_filter_icon_class(option)]} />
              </span>
              <span class="truncate">{option.label}</span>
            </button>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  defp selected_incident_filter_option(options, selected_value) do
    Enum.find(options, &(&1.value == (selected_value || ""))) || List.first(options)
  end

  defp incident_filter_icon_class(%{value: "critical"}), do: "text-error"
  defp incident_filter_icon_class(%{value: "warning"}), do: "text-warning"
  defp incident_filter_icon_class(%{value: "info"}), do: "text-info"
  defp incident_filter_icon_class(%{value: "open"}), do: "text-error"
  defp incident_filter_icon_class(%{value: "acknowledged"}), do: "text-warning"
  defp incident_filter_icon_class(%{value: "resolved"}), do: "text-success"
  defp incident_filter_icon_class(_option), do: "text-base-content/60"

  def severity_chip_class(severity), do: AdminBadges.alert_severity_chip_class(severity)

  defp incident_chip_base,
    do: "inline-flex h-4.5 items-center gap-1 whitespace-nowrap rounded-full px-2 text-[10px] font-semibold uppercase leading-none tracking-[0.04em]"

  defp state_icon("open"), do: "hero-bell-alert"
  defp state_icon("acknowledged"), do: "hero-hand-raised"
  defp state_icon("resolved"), do: "hero-check-circle"
  defp state_icon(_state), do: "hero-question-mark-circle"

  defp severity_icon("critical"), do: "hero-exclamation-circle"
  defp severity_icon("warning"), do: "hero-exclamation-triangle"
  defp severity_icon("info"), do: "hero-information-circle"
  defp severity_icon(_severity), do: "hero-minus-circle"

  @spec format_datetime(DateTime.t() | nil) :: String.t()
  def format_datetime(nil), do: gettext("not recorded")

  def format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp hidden_pool_count_label(count), do: ngettext("%{count} hidden impacted Pool", "%{count} hidden impacted Pools", count)

  defp incident_action_id("alert-incident-card", incident_id, action),
    do: "alert-incident-card-#{action}-#{incident_id}"

  defp incident_action_id(_prefix, incident_id, action),
    do: "alert-incident-#{action}-#{incident_id}"
end
