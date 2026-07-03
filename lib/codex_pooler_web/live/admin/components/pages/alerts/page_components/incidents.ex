defmodule CodexPoolerWeb.Admin.AlertsPageComponents.Incidents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.Alerts.Schemas.AlertIncident
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolFilterComponents

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

  def incidents_section(assigns) do
    ~H"""
    <div
      :if={@selected_tab == "incidents"}
      id="alerts-incidents-section"
      class="grid min-w-0 gap-4"
    >
      <AdminComponents.admin_surface
        id="alerts-incidents-filters"
        title="Incident filters"
        description="Filter persisted alert incidents without exposing hidden Pool impact or raw evidence keys."
        overflow={:visible}
      >
        <AdminComponents.filter_form
          id="alerts-incidents-filter-form"
          for={@incident_filter_form}
          phx-submit="filter_incidents"
          compact
          mobile_single_column
        >
          <PoolFilterComponents.pool_filter_dropdown
            id="alerts-incident-pool-filter"
            label="Impacted Pool"
            hidden_id="alerts-incident-pool-id"
            event="select_incident_pool_filter"
            selected_value={@incident_filter_values["pool_id"] || ""}
            options={@incident_pool_filter_options}
          />
          <.input
            id="alerts-incident-severity-filter"
            field={@incident_filter_form[:severity]}
            type="select"
            label="Severity"
            options={option_tuples(@incident_severity_filter_options)}
          />
          <.input
            id="alerts-incident-state-filter"
            field={@incident_filter_form[:state]}
            type="select"
            label="State"
            options={option_tuples(@incident_state_filter_options)}
          />
          <:advanced>
            <.input
              id="alerts-incident-rule-filter"
              field={@incident_filter_form[:rule_id]}
              type="select"
              label="Rule"
              options={option_tuples(@incident_rule_filter_options)}
            />
            <.input
              id="alerts-incident-channel-filter"
              field={@incident_filter_form[:channel_id]}
              type="select"
              label="Channel"
              options={option_tuples(@incident_channel_filter_options)}
            />
          </:advanced>
          <:actions>
            <AdminComponents.action_button
              id="alerts-incidents-filter-submit"
              icon="hero-funnel"
              label="Apply"
              type="submit"
              variant={:primary}
            />
            <.link
              id="alerts-incidents-filter-clear"
              patch={~p"/admin/alerts?#{%{"tab" => "incidents"}}"}
              class="btn btn-secondary btn-sm"
            >
              Clear
            </.link>
          </:actions>
        </AdminComponents.filter_form>

        <div
          :if={@incident_filter_errors != []}
          id="alerts-incidents-filter-errors"
          class="mt-3 grid gap-2"
        >
          <p
            :for={error <- @incident_filter_errors}
            id={"alerts-incidents-filter-error-#{error.field}"}
            class="text-sm text-error"
          >
            {error.message}
          </p>
        </div>
      </AdminComponents.admin_surface>

      <AdminComponents.admin_surface
        id="alerts-incidents-list"
        title="Incidents"
        description="Recent alert incidents projected through the current operator's Pool visibility."
        count={incident_count_label(@incident_total_count, @incident_page_size)}
        overflow={:visible}
      >
        <AdminComponents.empty_state
          :if={@incidents == []}
          id="alerts-incidents-empty-state"
          title="No alert incidents"
          description="No visible alert incidents match the selected filters."
          icon="hero-bell-alert"
        />

        <div
          :if={@incidents != []}
          id="alerts-incident-table-scroll-region"
          class="hidden overflow-x-auto lg:block"
        >
          <table id="alerts-incident-table" class="table min-w-[84rem]">
            <thead>
              <tr>
                <th>Incident</th>
                <th>Impacted Pools</th>
                <th class="text-center">Severity</th>
                <th class="text-center">State</th>
                <th>Delivery</th>
                <th class="text-right">Last seen</th>
                <th class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={incident <- @incidents}
                id={"alert-incident-#{incident.id}"}
                class="text-sm transition-colors hover:bg-base-200/80"
                data-role="alert-incident-row"
                data-alert-anchor-id={"alert-incident-#{incident.id}"}
              >
                <td class="min-w-72">
                  <div class="grid min-w-0 gap-1">
                    <span
                      id={"alert-incident-row-#{incident.id}-reason"}
                      data-role="incident-reason"
                      class="font-semibold text-base-content"
                    >
                      {incident.reason_title}
                    </span>
                    <span
                      id={"alert-incident-row-#{incident.id}-kind"}
                      data-role="incident-kind"
                      class="text-xs text-base-content/60"
                    >
                      {incident.rule_kind_label}
                    </span>
                    <span
                      id={"alert-incident-row-#{incident.id}-detail"}
                      data-role="incident-detail"
                      class="text-xs leading-5 text-base-content/55"
                    >
                      {incident.reason_detail}
                    </span>
                  </div>
                </td>
                <td class="min-w-64">
                  <.impacted_pool_list
                    incident={incident}
                    prefix="alert-incident-row"
                  />
                </td>
                <td class="text-center">
                  <span
                    id={"alert-incident-row-#{incident.id}-severity"}
                    data-role="incident-severity"
                    class={severity_chip_class(incident.severity)}
                  >
                    {incident.severity_label}
                  </span>
                </td>
                <td class="text-center">
                  <span
                    id={"alert-incident-row-#{incident.id}-state"}
                    data-role="incident-state"
                    class={AdminBadges.status_chip_class(incident.state)}
                  >
                    {incident.state_label}
                  </span>
                </td>
                <td
                  id={"alert-incident-row-#{incident.id}-delivery"}
                  class="min-w-64 text-xs text-base-content/70"
                >
                  <.incident_delivery_summary
                    incident={incident}
                    prefix="alert-incident-row"
                  />
                </td>
                <td
                  id={"alert-incident-row-#{incident.id}-last-seen"}
                  class="text-right font-mono text-xs tabular-nums text-base-content/60"
                >
                  {format_datetime(incident.last_seen_at)}
                </td>
                <td class="text-right">
                  <.incident_action_controls
                    incident={incident}
                    prefix="alert-incident"
                  />
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@incidents != []} id="alerts-incident-cards" class="grid gap-3 lg:hidden">
          <article
            :for={incident <- @incidents}
            id={"alert-incident-card-#{incident.id}"}
            class="rounded-box border border-base-300 bg-base-100 p-4 shadow-sm"
          >
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div class="grid min-w-0 gap-1">
                <h3
                  id={"alert-incident-card-#{incident.id}-reason"}
                  class="font-semibold text-base-content"
                >
                  {incident.reason_title}
                </h3>
                <p
                  id={"alert-incident-card-#{incident.id}-kind"}
                  class="text-xs text-base-content/60"
                >
                  {incident.rule_kind_label}
                </p>
              </div>
              <div class="flex flex-wrap gap-2">
                <span
                  id={"alert-incident-card-#{incident.id}-severity"}
                  data-role="incident-severity"
                  class={severity_chip_class(incident.severity)}
                >
                  {incident.severity_label}
                </span>
                <span
                  id={"alert-incident-card-#{incident.id}-state"}
                  data-role="incident-state"
                  class={AdminBadges.status_chip_class(incident.state)}
                >
                  {incident.state_label}
                </span>
              </div>
            </div>
            <p
              id={"alert-incident-card-#{incident.id}-detail"}
              class="mt-3 text-sm leading-6 text-base-content/65"
            >
              {incident.reason_detail}
            </p>
            <div class="mt-3 grid gap-3 text-sm">
              <.impacted_pool_list
                incident={incident}
                prefix="alert-incident-card"
              />
              <div
                id={"alert-incident-card-#{incident.id}-delivery"}
                class="text-xs text-base-content/70"
              >
                <.incident_delivery_summary
                  incident={incident}
                  prefix="alert-incident-card"
                />
              </div>
              <p
                id={"alert-incident-card-#{incident.id}-last-seen"}
                class="font-mono text-xs text-base-content/55"
              >
                Last seen {format_datetime(incident.last_seen_at)}
              </p>
              <.incident_action_controls
                incident={incident}
                prefix="alert-incident-card"
              />
            </div>
          </article>
        </div>
      </AdminComponents.admin_surface>
    </div>
    """
  end

  defp option_tuples(options), do: Enum.map(options, &{&1.label, &1.value})

  defp incident_count_label(0, _page_size), do: "0 incidents"
  defp incident_count_label(1, _page_size), do: "1 incident"

  defp incident_count_label(total, page_size) when total > page_size,
    do: "#{page_size} of #{total} incidents"

  defp incident_count_label(total, _page_size), do: "#{total} incidents"

  attr :incident, :map, required: true
  attr :prefix, :string, required: true

  def impacted_pool_list(assigns) do
    ~H"""
    <div
      id={"#{@prefix}-#{@incident.id}-impacted-pools"}
      data-role="incident-impacted-pools"
      class="grid gap-1"
    >
      <p
        :if={@incident.impacted_pools == []}
        id={"#{@prefix}-#{@incident.id}-no-visible-impacted-pools"}
        data-role="incident-no-visible-impacted-pools"
        class="text-xs text-base-content/55"
      >
        No visible impacted Pools
      </p>
      <ul :if={@incident.impacted_pools != []} class="grid gap-1">
        <li
          :for={pool <- @incident.impacted_pools}
          id={"#{@prefix}-#{@incident.id}-impacted-pool-#{pool.id}"}
          data-role="incident-impacted-pool"
          class="grid min-w-0 gap-0.5"
        >
          <span data-role="incident-impacted-pool-name" class="truncate font-medium text-base-content">
            {pool.name}
          </span>
        </li>
      </ul>
      <p
        :if={@incident.hidden_impacted_pool_count > 0}
        id={"#{@prefix}-#{@incident.id}-hidden-pool-count"}
        data-role="incident-hidden-pool-count"
        class="text-xs font-medium text-warning"
      >
        {hidden_pool_count_label(@incident.hidden_impacted_pool_count)}
      </p>
    </div>
    """
  end

  attr :incident, :map, required: true
  attr :prefix, :string, required: true

  def incident_action_controls(assigns) do
    ~H"""
    <div id={"#{@prefix}-#{@incident.id}-actions"} class="flex flex-wrap justify-end gap-2">
      <AdminComponents.action_button
        :if={@incident.state == AlertIncident.open_state()}
        id={incident_action_id(@prefix, @incident.id, "acknowledge")}
        icon="hero-hand-raised"
        label="Acknowledge"
        phx-click="acknowledge_incident"
        phx-value-id={@incident.id}
      />
      <AdminComponents.action_button
        :if={@incident.state != AlertIncident.resolved_state()}
        id={incident_action_id(@prefix, @incident.id, "resolve")}
        icon="hero-check-circle"
        label="Resolve"
        phx-click="resolve_incident"
        phx-value-id={@incident.id}
        variant={:primary}
      />
      <span
        :if={@incident.state == AlertIncident.resolved_state()}
        id={"#{@prefix}-#{@incident.id}-actions-resolved"}
        class="text-xs font-medium text-base-content/50"
      >
        No pending actions
      </span>
    </div>
    """
  end

  attr :incident, :map, required: true
  attr :prefix, :string, required: true

  def incident_delivery_summary(assigns) do
    ~H"""
    <div class="grid gap-2">
      <p id={"#{@prefix}-#{@incident.id}-delivery-label"} data-role="incident-delivery-label">
        {@incident.delivery_summary.label}
      </p>
      <ul
        :if={@incident.delivery_summary.attempts != []}
        id={"#{@prefix}-#{@incident.id}-delivery-attempts"}
        data-role="incident-delivery-attempts"
        class="grid gap-2"
      >
        <li
          :for={attempt <- @incident.delivery_summary.attempts}
          id={"#{@prefix}-#{@incident.id}-delivery-attempt-#{attempt.id}"}
          data-role="incident-delivery-attempt"
          class="rounded-box border border-base-300 bg-base-200/60 p-2"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <span
              data-role="incident-delivery-attempt-channel"
              class="font-medium text-base-content/80"
            >
              {attempt.channel_label}
            </span>
            <span
              data-role="incident-delivery-attempt-status"
              class={AdminBadges.status_chip_class(attempt.status)}
            >
              {attempt.status_label}
            </span>
          </div>
          <p
            id={"#{@prefix}-#{@incident.id}-delivery-attempt-#{attempt.id}-meta"}
            data-role="incident-delivery-attempt-meta"
            class="mt-1 font-mono text-[0.68rem] text-base-content/55"
          >
            Attempt {attempt.attempt_number}/{attempt.max_attempts} · {format_datetime(
              attempt.attempted_at || attempt.completed_at
            )}
          </p>
          <dl
            :if={attempt.details != []}
            id={"#{@prefix}-#{@incident.id}-delivery-attempt-#{attempt.id}-details"}
            data-role="incident-delivery-attempt-details"
            class="mt-2 grid gap-1 text-[0.68rem]"
          >
            <div :for={detail <- attempt.details} class="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
              <dt class="text-base-content/45">{detail.label}</dt>
              <dd class="min-w-0 break-words font-mono text-base-content/65">{detail.value}</dd>
            </div>
          </dl>
        </li>
      </ul>
    </div>
    """
  end

  def severity_chip_class("critical"), do: AdminBadges.status_chip_class("open")
  def severity_chip_class("warning"), do: AdminBadges.status_chip_class("paused")
  def severity_chip_class("info"), do: AdminBadges.status_chip_class("pending")
  def severity_chip_class(_severity), do: AdminBadges.status_chip_class(nil)

  def format_datetime(nil), do: "not recorded"

  def format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp hidden_pool_count_label(1), do: "1 hidden impacted Pool"
  defp hidden_pool_count_label(count), do: "#{count} hidden impacted Pools"

  defp incident_action_id("alert-incident-card", incident_id, action),
    do: "alert-incident-card-#{action}-#{incident_id}"

  defp incident_action_id(_prefix, incident_id, action),
    do: "alert-incident-#{action}-#{incident_id}"
end
