defmodule CodexPoolerWeb.Admin.RequestLogsPresentation do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
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
      translated_origin: 1,
      protocol_badge_class: 1,
      protocol_label: 1,
      protocol_title: 1,
      request_status_icon: 1,
      status_label: 1,
      user_agent_display: 1
    ]

  attr :request_logs, :map, required: true
  attr :datetime_preferences, :map, required: true

  def request_logs_table(assigns) do
    ~H"""
    <div
      id="admin-request-logs"
      class={[
        "min-w-0",
        @request_logs.items != [] &&
          "overflow-hidden rounded-box border border-base-300 bg-base-100"
      ]}
    >
      <AdminComponents.empty_state
        :if={@request_logs.items == []}
        id="request-log-empty-state"
        title="No request logs"
        description="Send a request through a Pool or adjust the filters to find existing log rows."
        icon="hero-document-magnifying-glass"
      />

      <div :if={@request_logs.items != []} class="overflow-x-auto">
        <table class="admin-status-tick table table-sm admin-log-table min-w-[70rem]">
          <colgroup>
            <col style="width: 11rem;" />
            <col style="width: 11rem;" />
            <col style="width: 13rem;" />
            <col />
            <col style="width: 10rem;" />
            <col style="width: 10rem;" />
          </colgroup>
          <thead>
            <tr>
              <th class="whitespace-nowrap">Request</th>
              <th class="whitespace-nowrap">Upstream</th>
              <th class="whitespace-nowrap">Model / API key</th>
              <th class="whitespace-nowrap">Route</th>
              <th class="whitespace-nowrap">Usage</th>
              <th class="whitespace-nowrap">Outcome</th>
            </tr>
          </thead>
          <tbody id="request-logs-table">
            <tr
              :for={request_log <- @request_logs.items}
              id={"request-log-row-#{request_log.id}"}
              data-status={request_log.status}
              data-tone={request_log_tone(request_log.status)}
              phx-click="open_request_log"
              phx-value-request-id={request_log.id}
              class="group/request-log cursor-pointer transition-colors hover:bg-base-200/80"
            >
              <td class="whitespace-nowrap align-middle text-base-content/70">
                <.request_log_timestamp_cell
                  request_log={request_log}
                  datetime_preferences={@datetime_preferences}
                  prefix="request-log"
                />
              </td>
              <td class="align-middle">
                <.request_log_upstream_identity_cell
                  request_log={request_log}
                  plan_badge_id={"request-log-#{request_log.id}-plan-badge"}
                />
              </td>
              <td class="align-middle">
                <.request_log_model_cell request_log={request_log} prefix="request-log" />
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
                <.request_log_outcome_cell
                  request_log={request_log}
                  datetime_preferences={@datetime_preferences}
                />
              </td>
            </tr>
          </tbody>
          <caption class="caption-bottom border-t border-base-300/70 px-3 py-2.5 text-left text-xs text-base-content/60">
            {format_total(@request_logs.total)} matching sanitized request logs<span class="lg:hidden"> · Swipe sideways for more columns</span>
          </caption>
        </table>
      </div>
    </div>
    """
  end

  attr :request_log, :map, required: true
  attr :plan_badge_id, :string, default: nil

  def request_log_upstream_identity_cell(assigns) do
    ~H"""
    <div class="grid min-w-0 gap-0.5">
      <span class="flex h-5 min-w-0 items-center gap-1.5">
        <span
          data-role="upstream-account"
          class="min-w-0 truncate font-semibold text-base-content"
          title={format_upstream_account_label(@request_log)}
        >
          {format_upstream_account_label(@request_log)}
        </span>
        <AdminBadges.plan_badge
          id={@plan_badge_id}
          data-role="plan-badge"
          label={@request_log.upstream_account_plan_label}
          family={@request_log.upstream_account_plan_family}
          placeholder="—"
          class="max-w-[8rem] shrink-0 truncate !px-2 !py-0.5 !text-[10px]"
          title="upstream account plan"
        />
      </span>
      <span
        data-role="pool-name"
        class="flex h-5 min-w-0 items-center gap-1.5 text-base-content/45"
        title={@request_log.pool_name}
      >
        <span
          data-role="pool-icon"
          class="grid size-3 shrink-0 place-items-center text-base-content/35"
        >
          <.icon name="hero-server-stack" class="size-3" />
        </span>
        <span class="truncate">{@request_log.pool_name}</span>
      </span>
    </div>
    """
  end

  attr :request_log, :map, required: true
  attr :datetime_preferences, :map, required: true

  def request_log_outcome_cell(assigns) do
    errors = format_errors(assigns.request_log, assigns.datetime_preferences)

    assigns =
      assigns
      |> assign(:errors, Enum.take(errors, 2))
      |> assign(:errors_title, Enum.join(errors, "; "))

    ~H"""
    <span
      id={"request-log-#{@request_log.id}-errors"}
      data-role="errors"
      class="grid min-w-0 gap-0.5 text-base-content/65"
      title={@errors_title}
    >
      <span
        :for={error <- @errors}
        data-role="error-line"
        class="block h-5 min-w-0 truncate leading-5"
      >
        {error}
      </span>
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
      class="group grid max-w-full gap-0.5 rounded-field text-left transition-colors hover:text-primary focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary group-hover/request-log:text-primary"
      aria-label={"Inspect request #{format_record_id(@request_log.id) || @request_log.id}"}
    >
      <span
        data-role="timestamp-datetime"
        class="flex h-5 items-center whitespace-nowrap font-semibold tabular-nums"
      >
        {format_datetime(@request_log.admitted_at, @datetime_preferences)}
      </span>
      <span
        data-role="status-label"
        class={[
          "flex h-5 min-w-0 items-center gap-1 whitespace-nowrap font-semibold",
          status_text_class(@request_log.status)
        ]}
      >
        <span class="sr-only">{"Status: "}</span>
        <.icon
          :if={@request_log.status == "in_progress"}
          name={request_status_icon(@request_log.status)}
          class="size-3 shrink-0"
        />
        {status_label(@request_log.status || "unknown")}
      </span>
    </button>
    """
  end

  attr :request_log, :map, required: true
  attr :prefix, :string, required: true

  def request_log_model_cell(assigns) do
    ~H"""
    <div class="grid min-w-0 gap-0.5">
      <span
        id={"#{@prefix}-#{@request_log.id}-model-details"}
        data-role="model-details"
        class="block h-5 min-w-0 truncate whitespace-nowrap leading-5 text-base-content/60"
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
        class="flex h-5 min-w-0 items-center gap-1.5 text-base-content/60"
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
    <div class="grid min-w-0 gap-0.5">
      <span class="flex h-5 min-w-0 items-center gap-2 text-base-content/60">
        <span
          id={"#{@prefix}-#{@request_log.id}-route"}
          data-role="route"
          class="min-w-0 truncate"
          title={format_transport_route(@request_log)}
        >
          {format_transport_route(@request_log)}
        </span>
        <span
          :if={latency = format_route_latency(@request_log.latency_ms)}
          id={"#{@prefix}-#{@request_log.id}-latency"}
          data-role="latency"
          class="inline-flex shrink-0 whitespace-nowrap text-base-content/45"
          title={format_latency_title(@request_log.latency_ms)}
        >
          {latency}
        </span>
      </span>
      <span class="flex h-5 min-w-0 items-center gap-2">
        <.request_log_protocol_badge request_log={@request_log} prefix={@prefix} />
        <span
          :if={origin = translated_origin(@request_log)}
          id={"#{@prefix}-#{@request_log.id}-route-origin"}
          data-role="route-origin"
          class="flex min-w-0 shrink-[2] items-center gap-1 whitespace-nowrap text-base-content/45"
          title={"translated from #{origin}"}
        >
          <.icon name="hero-arrows-right-left" class="size-3 shrink-0" />
          <span class="truncate">{origin}</span>
        </span>
        <span
          :if={user_agent = user_agent_display(@request_log)}
          id={"#{@prefix}-#{@request_log.id}-user-agent"}
          data-role="user-agent"
          data-client-kind={user_agent.kind}
          class="flex min-w-0 shrink-[2] items-center gap-1 whitespace-nowrap text-base-content/45"
          title={user_agent.title}
        >
          <.icon
            name={user_agent.icon}
            class={user_agent.icon_class}
          />
          <span data-role="user-agent-text" class="truncate">{user_agent.text}</span>
        </span>
        <span
          :if={route_metadata = format_route_metadata(@request_log)}
          id={"#{@prefix}-#{@request_log.id}-route-metadata"}
          data-role="route-metadata"
          class="min-w-0 truncate whitespace-nowrap text-base-content/40"
          title={route_metadata}
        >
          {route_metadata}
        </span>
      </span>
    </div>
    """
  end

  # The status is written under the timestamp, in the tone the tick reinforces.
  defp status_text_class(status) do
    case request_log_tone(status) do
      "success" -> "text-success"
      "error" -> "text-error"
      "warning" -> "text-warning"
      "info" -> "text-info"
      _neutral -> "text-base-content/55"
    end
  end

  # Tone for the shared status tick (see .admin-status-tick in app.css). The
  # row still spells its status out; the rail only reinforces it.
  defp request_log_tone("succeeded"), do: "success"
  defp request_log_tone(status) when status in ["failed", "rejected"], do: "error"
  defp request_log_tone("cancelled"), do: "warning"
  defp request_log_tone("in_progress"), do: "info"
  defp request_log_tone(_status), do: nil
end
