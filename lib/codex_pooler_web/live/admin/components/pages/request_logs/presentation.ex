defmodule CodexPoolerWeb.Admin.RequestLogsPresentation do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.LogPagination
  alias CodexPoolerWeb.Admin.RequestLogsPresentation.Usage

  import CodexPoolerWeb.Admin.RequestLogsDisplay,
    only: [
      format_api_key: 1,
      format_datetime: 2,
      format_errors: 2,
      format_latency_title: 1,
      format_model_details_title: 1,
      format_model_name: 1,
      format_model_reasoning: 1,
      format_model_service_tier: 1,
      format_record_id: 1,
      format_requested_tier_detail: 1,
      format_requested_reasoning_detail: 1,
      format_route_latency: 1,
      format_route_metadata: 1,
      format_total: 1,
      format_transport_route: 1,
      format_upstream_account_label: 1,
      protocol_badge_class: 1,
      protocol_label: 1,
      protocol_title: 1,
      request_status_icon: 1,
      request_status_icon_class: 1,
      status_label: 1,
      user_agent_display: 1
    ]

  attr :request_logs, :map, required: true
  attr :current_params, :map, required: true
  attr :datetime_preferences, :map, required: true

  def request_logs_table(assigns) do
    ~H"""
    <div
      id="admin-request-logs"
      class={[
        "min-w-0",
        (@request_logs.items != [] or @request_logs.total > 0) &&
          "rounded-box border border-base-300 bg-base-100 shadow-sm"
      ]}
    >
      <AdminComponents.empty_state
        :if={@request_logs.items == []}
        id="request-log-empty-state"
        title="No request logs"
        description="Send a request through a Pool or adjust the filters to find existing log rows."
        icon="hero-document-magnifying-glass"
      />

      <LogPagination.controls
        page={@request_logs}
        base_path="/admin/request-logs"
        current_params={@current_params}
        id_prefix="admin-request-logs-pagination-top"
        range_id="admin-request-logs-range-top"
        range_role="request-logs-range"
        label="Request logs"
        placement={:top}
        show_border={@request_logs.items != []}
      />

      <div :if={@request_logs.items != []} class="hidden overflow-x-auto md:block">
        <table class="table table-sm admin-log-table min-w-[76rem]">
          <colgroup>
            <col style="width: 2.5rem; min-width: 2.5rem; max-width: 2.5rem;" />
            <col style="width: 10.5rem;" />
            <col style="width: 11rem;" />
            <col style="width: 4rem;" />
            <col style="width: 12rem;" />
            <col style="width: 6rem;" />
            <col style="width: 14rem;" />
            <col style="width: 14rem;" />
            <col style="width: 5rem;" />
          </colgroup>
          <thead>
            <tr>
              <th
                class="w-10 min-w-10 max-w-10 text-center"
                style="padding-left: 0; padding-right: 0;"
                aria-label="Request status"
              >
              </th>
              <th
                class="whitespace-nowrap"
                style="padding-left: 0; padding-right: 0.5rem;"
              >
                Timestamp
              </th>
              <th class="whitespace-nowrap">Upstream account</th>
              <th class="whitespace-nowrap text-center">Plan</th>
              <th class="whitespace-nowrap">Model / API Key</th>
              <th class="whitespace-nowrap text-center">Transport</th>
              <th class="whitespace-nowrap">Route</th>
              <th class="whitespace-nowrap">Usage</th>
              <th class="whitespace-nowrap">Errors</th>
            </tr>
          </thead>
          <tbody id="request-logs-table">
            <tr
              :for={request_log <- @request_logs.items}
              id={"request-log-row-#{request_log.id}"}
              class="transition-colors hover:bg-base-200/80"
            >
              <td
                class="w-10 min-w-10 max-w-10 align-middle text-center"
                style="padding-left: 0; padding-right: 0;"
              >
                <.request_log_status_cell request_log={request_log} />
              </td>
              <td
                class="whitespace-nowrap align-middle text-base-content/70"
                style="padding-left: 0; padding-right: 0.5rem;"
              >
                <.request_log_timestamp_cell
                  request_log={request_log}
                  datetime_preferences={@datetime_preferences}
                  prefix="request-log"
                />
              </td>
              <td class="align-middle">
                <.request_log_upstream_identity_cell request_log={request_log} />
              </td>
              <td class="align-middle text-center">
                <AdminBadges.plan_badge
                  id={"request-log-#{request_log.id}-plan-badge"}
                  data-role="plan-badge"
                  label={request_log.upstream_account_plan_label}
                  family={request_log.upstream_account_plan_family}
                  placeholder="—"
                  variant={:metadata}
                  class="justify-center"
                  title="upstream account plan"
                />
              </td>
              <td class="align-middle">
                <.request_log_model_cell request_log={request_log} prefix="request-log" />
              </td>
              <td class="align-middle text-center">
                <.request_log_protocol_badge request_log={request_log} prefix="request-log" />
              </td>
              <td class="align-middle">
                <.request_log_route_cell request_log={request_log} prefix="request-log" />
              </td>
              <td class="align-middle">
                <Usage.request_log_usage_lines
                  request_log={request_log}
                  prefix="request-log"
                  datetime_preferences={@datetime_preferences}
                />
              </td>
              <td class="align-middle">
                <span
                  id={"request-log-#{request_log.id}-errors"}
                  data-role="errors"
                  class="grid gap-0.5 text-base-content/65"
                >
                  <span
                    :for={error <- format_errors(request_log, @datetime_preferences)}
                    data-role="error-line"
                    class="block"
                  >
                    {error}
                  </span>
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div
        :if={@request_logs.items != []}
        id="mobile-request-logs-table"
        class="overflow-x-auto md:hidden"
      >
        <table class="table table-sm admin-log-table min-w-[68rem]">
          <colgroup>
            <col style="width: 2.5rem; min-width: 2.5rem; max-width: 2.5rem;" />
            <col style="width: 10.5rem; min-width: 10.5rem;" />
            <col style="width: 12rem; min-width: 12rem;" />
            <col style="width: 12rem; min-width: 12rem;" />
            <col style="width: 6.5rem; min-width: 6.5rem;" />
            <col style="width: 14rem; min-width: 14rem;" />
            <col style="width: 13rem; min-width: 13rem;" />
          </colgroup>
          <thead>
            <tr>
              <th
                class="w-10 min-w-10 max-w-10 text-center"
                style="padding-left: 0; padding-right: 0;"
                aria-label="Request status"
              >
              </th>
              <th
                class="whitespace-nowrap"
                style="padding-left: 0; padding-right: 0.5rem;"
              >
                Time
              </th>
              <th class="whitespace-nowrap">Request</th>
              <th class="whitespace-nowrap">Model / API Key</th>
              <th class="whitespace-nowrap text-center">Transport</th>
              <th class="whitespace-nowrap">Route</th>
              <th class="whitespace-nowrap">Usage</th>
            </tr>
          </thead>
          <tbody id="mobile-request-logs-table-body">
            <tr
              :for={request_log <- @request_logs.items}
              id={"mobile-request-log-row-#{request_log.id}"}
              class="transition-colors hover:bg-base-200/80"
            >
              <td
                class="w-10 min-w-10 max-w-10 align-middle text-center"
                style="padding-left: 0; padding-right: 0;"
              >
                <.request_log_status_cell request_log={request_log} />
              </td>
              <td
                class="whitespace-nowrap align-middle text-base-content/70"
                style="padding-left: 0; padding-right: 0.5rem;"
              >
                <.request_log_timestamp_cell
                  request_log={request_log}
                  datetime_preferences={@datetime_preferences}
                  prefix="mobile-request-log"
                />
              </td>
              <td class="align-middle">
                <.request_log_upstream_identity_cell
                  request_log={request_log}
                  compact
                  show_plan
                  plan_badge_id={"mobile-request-log-#{request_log.id}-plan-badge"}
                />
              </td>
              <td class="align-middle">
                <.request_log_model_cell request_log={request_log} prefix="mobile-request-log" />
              </td>
              <td class="align-middle text-center">
                <.request_log_protocol_badge
                  request_log={request_log}
                  prefix="mobile-request-log"
                />
              </td>
              <td class="align-middle">
                <.request_log_route_cell request_log={request_log} prefix="mobile-request-log" />
              </td>
              <td class="align-middle">
                <Usage.request_log_usage_lines
                  request_log={request_log}
                  prefix="mobile-request-log"
                  datetime_preferences={@datetime_preferences}
                  show_errors
                />
              </td>
            </tr>
          </tbody>
          <caption class="caption-bottom px-3 py-3 text-left text-xs text-base-content/60">
            {format_total(@request_logs.total)} matching sanitized request logs · Swipe sideways for more columns
          </caption>
        </table>
      </div>

      <LogPagination.controls
        page={@request_logs}
        base_path="/admin/request-logs"
        current_params={@current_params}
        id_prefix="admin-request-logs-pagination"
        range_id="admin-request-logs-range"
        range_role="request-logs-range"
        label="Request logs"
        placement={:bottom}
        show_border={@request_logs.items != []}
      />
    </div>
    """
  end

  attr :request_log, :map, required: true
  attr :compact, :boolean, default: false
  attr :show_plan, :boolean, default: false
  attr :plan_badge_id, :string, default: nil

  def request_log_upstream_identity_cell(assigns) do
    ~H"""
    <div class="grid gap-0.5 leading-tight">
      <span
        data-role="upstream-account"
        class={[
          "font-semibold text-base-content",
          @compact && "truncate"
        ]}
        title={@compact && format_upstream_account_label(@request_log)}
      >
        {format_upstream_account_label(@request_log)}
      </span>
      <span
        data-role="pool-name"
        class={[
          "inline-flex max-w-full items-center gap-1.5 text-base-content/45",
          @compact && "truncate"
        ]}
        title={@compact && @request_log.pool_name}
      >
        <span
          data-role="pool-icon"
          class="grid size-3 shrink-0 place-items-center text-base-content/35"
        >
          <.icon name="hero-server-stack" class="size-3" />
        </span>
        <span class="truncate">{@request_log.pool_name}</span>
      </span>
      <AdminBadges.plan_badge
        :if={@show_plan}
        id={@plan_badge_id}
        data-role="plan-badge"
        label={@request_log.upstream_account_plan_label}
        family={@request_log.upstream_account_plan_family}
        placeholder="—"
        variant={:metadata}
        class="justify-center"
        title="upstream account plan"
      />
    </div>
    """
  end

  attr :request_log, :map, required: true

  def request_log_status_cell(assigns) do
    ~H"""
    <span
      data-role="status-icon"
      title={status_label(@request_log.status || "unknown")}
      aria-label={"Status: #{status_label(@request_log.status || "unknown")}"}
    >
      <.icon
        name={request_status_icon(@request_log.status)}
        class={request_status_icon_class(@request_log.status)}
      />
    </span>
    """
  end

  attr :request_log, :map, required: true
  attr :datetime_preferences, :map, required: true
  attr :prefix, :string, required: true

  def request_log_timestamp_cell(assigns) do
    ~H"""
    <button
      id={"#{@prefix}-#{@request_log.id}-open-details"}
      type="button"
      data-role="open-request-log-details"
      phx-click="open_request_log"
      phx-value-request-id={@request_log.id}
      class="group grid max-w-full gap-0.5 rounded-field text-left leading-tight transition-colors hover:text-primary focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
      aria-label={"Inspect request #{format_record_id(@request_log.id) || @request_log.id}"}
    >
      <span data-role="timestamp-datetime" class="block whitespace-nowrap">
        {format_datetime(@request_log.admitted_at, @datetime_preferences)}
      </span>
      <span class="inline-flex min-w-0 items-center gap-1 text-base-content/45 group-hover:text-primary/80">
        <span
          :if={record_id = format_record_id(@request_log.id)}
          data-role="record-id"
          class="block truncate"
          title={@request_log.id}
        >
          {record_id}
        </span>
        <.icon name="hero-magnifying-glass" class="size-3 shrink-0" />
      </span>
    </button>
    """
  end

  attr :request_log, :map, required: true
  attr :prefix, :string, required: true

  def request_log_model_cell(assigns) do
    ~H"""
    <div class="grid gap-0.5 leading-tight">
      <span
        id={"#{@prefix}-#{@request_log.id}-model-details"}
        data-role="model-details"
        class="block truncate whitespace-nowrap text-base-content/60"
        title={format_model_details_title(@request_log)}
      >
        <span data-role="model-name" class="font-semibold text-base-content">
          {format_model_name(@request_log)}
        </span>
        <span
          :if={reasoning = format_model_reasoning(@request_log)}
          data-role="model-reasoning"
          class="ml-1 font-normal text-base-content/60"
        >
          {reasoning}
        </span>
        <span
          :if={detail = format_requested_reasoning_detail(@request_log)}
          id={"#{@prefix}-#{@request_log.id}-requested-reasoning"}
          data-role="requested-reasoning"
          class="ml-1 font-normal text-base-content/60"
        >
          {detail}
        </span>
        <span
          :if={tier = format_model_service_tier(@request_log)}
          data-role="model-service-tier"
          class="ml-1 font-normal text-base-content/60"
        >
          <span>/</span> {tier}
        </span>
        <span
          :if={detail = format_requested_tier_detail(@request_log)}
          id={"#{@prefix}-#{@request_log.id}-requested-tier"}
          class="ml-1 font-normal text-base-content/60"
        >
          {detail}
        </span>
      </span>
      <span
        data-role="api-key"
        class="inline-flex max-w-full items-center gap-1.5 truncate text-base-content/60"
        title={format_api_key(@request_log)}
      >
        <span
          data-role="api-key-icon"
          class="grid size-3 shrink-0 place-items-center text-base-content/40"
        >
          <.icon name="hero-key" class="size-3" />
        </span>
        <span class="truncate">{format_api_key(@request_log)}</span>
      </span>
    </div>
    """
  end

  attr :request_log, :map, required: true
  attr :prefix, :string, required: true

  def request_log_protocol_badge(assigns) do
    ~H"""
    <span
      id={"#{@prefix}-#{@request_log.id}-protocol"}
      data-role="protocol-badge"
      class={protocol_badge_class(@request_log.transport)}
      title={protocol_title(@request_log)}
    >
      {protocol_label(@request_log.transport)}
      <Usage.speed_tier_indicator request_log={@request_log} />
    </span>
    """
  end

  attr :request_log, :map, required: true
  attr :prefix, :string, required: true

  def request_log_route_cell(assigns) do
    ~H"""
    <div class="grid gap-0.5 leading-tight">
      <span class="inline-flex items-baseline gap-1 whitespace-nowrap text-base-content/60">
        <span id={"#{@prefix}-#{@request_log.id}-route"} data-role="route" class="whitespace-nowrap">
          {format_transport_route(@request_log)}
        </span>
        <span
          :if={latency = format_route_latency(@request_log.latency_ms)}
          id={"#{@prefix}-#{@request_log.id}-latency"}
          data-role="latency"
          class="inline-flex shrink-0 whitespace-nowrap"
          title={format_latency_title(@request_log.latency_ms)}
        >
          {latency}
        </span>
      </span>
      <span
        :if={route_metadata = format_route_metadata(@request_log)}
        id={"#{@prefix}-#{@request_log.id}-route-metadata"}
        data-role="route-metadata"
        class="whitespace-nowrap text-base-content/45"
      >
        {route_metadata}
      </span>
      <span
        :if={user_agent = user_agent_display(@request_log)}
        id={"#{@prefix}-#{@request_log.id}-user-agent"}
        data-role="user-agent"
        data-client-kind={user_agent.kind}
        class="inline-flex max-w-full items-center gap-1 whitespace-nowrap text-base-content/45"
        title={user_agent.title}
      >
        <.icon
          name={user_agent.icon}
          class={user_agent.icon_class}
        />
        <span data-role="user-agent-text" class="truncate">{user_agent.text}</span>
      </span>
    </div>
    """
  end
end
