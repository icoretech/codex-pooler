defmodule CodexPoolerWeb.Admin.RequestLogsPresentation do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.LogPagination
  alias CodexPoolerWeb.Admin.RequestLogFilterForm
  alias CodexPoolerWeb.Admin.RequestLogsPresentation.Metrics
  alias CodexPoolerWeb.Admin.RequestLogsPresentation.Usage
  alias CodexPoolerWeb.DateTimeDisplay

  import CodexPoolerWeb.Admin.RequestLogsDisplay,
    only: [
      format_api_key: 1,
      format_datetime: 2,
      format_errors: 2,
      format_latency_title: 1,
      format_model_details_title: 1,
      format_model_name: 1,
      format_model_reasoning: 1,
      format_model_reasoning_slot: 1,
      format_model_service_tier: 1,
      format_record_id: 1,
      format_requested_tier_detail: 1,
      format_requested_reasoning_detail: 1,
      format_served_model_detail: 1,
      format_route_latency: 1,
      format_route_metadata: 1,
      format_total: 1,
      format_transport_route: 1,
      format_upstream_account_label: 1,
      model_default_reasoning?: 1,
      translated_origin: 1,
      protocol_badge_class: 1,
      protocol_label: 1,
      protocol_title: 1,
      request_status_icon: 1,
      status_label: 1,
      user_agent_display: 1
    ]

  attr :request_logs, :map, required: true
  attr :loading?, :boolean, default: false
  attr :loaded?, :boolean, default: true
  attr :datetime_preferences, :map, required: true
  attr :current_params, :map, required: true
  attr :pin_at, :any, default: nil
  attr :frozen?, :boolean, default: false
  attr :newer_count, :integer, default: 0
  attr :newer_count_exact?, :boolean, default: true

  def request_logs_table(assigns) do
    assigns = assign(assigns, :page, LogPagination.metadata(assigns.request_logs))

    ~H"""
    <div id="admin-request-logs" class="grid min-w-0 gap-3">
      <div
        :if={@request_logs.items == [] && @loading? && !@loaded?}
        id="request-log-loading-state-wrapper"
      >
        <AdminComponents.empty_state
          id="request-log-loading-state"
          title="Loading request logs"
          description="Loading the latest requests for the selected filters."
          icon="hero-arrow-path"
          loading?={true}
        />
      </div>

      <AdminComponents.empty_state
        :if={@request_logs.items == [] && !@loading? && !@loaded?}
        id="request-log-error-state"
        title="Request logs are not available"
        description="Reload the page or adjust the filters to try again."
        icon="hero-exclamation-triangle"
      />

      <AdminComponents.empty_state
        :if={@request_logs.items == [] && @loaded?}
        id="request-log-empty-state"
        title="No request logs"
        description="Send a request through a Pool or adjust the filters to find existing log rows."
        icon="hero-document-magnifying-glass"
      />

      <div
        :if={@request_logs.items != []}
        class="overflow-hidden rounded-box border border-base-300 bg-base-100"
      >
        <Usage.token_composition_legend />
        <div class="lg:overflow-x-auto">
          <table
            data-ledger-dense
            class="admin-request-explorer admin-ledger-table table table-sm admin-log-table font-sans lg:min-w-[58rem]"
          >
            <%!-- The count is the footer's job; the caption repeats it only for
          assistive tech, which reads it before the rows. --%>
            <caption class="sr-only">
              Request logs, {format_total(@request_logs.total)}{if Map.get(@request_logs, :total_exact?) == false,
                do: " or more"} matching sanitized request logs
            </caption>
            <%!-- Endpoint is the elastic column. The table's floor preserves the
          six groups on desktop; below lg the same cells reflow as a ledger. --%>
            <colgroup>
              <col class="request-log-time-column" />
              <col class="request-log-model-column" />
              <col class="request-log-attribution-column" />
              <col />
              <col class="request-log-tokens-column" />
              <col class="request-log-cost-column" />
            </colgroup>
            <thead>
              <tr>
                <th scope="col" class="whitespace-nowrap">Time · Status</th>
                <th scope="col" class="whitespace-nowrap">Model · Effort · Tier</th>
                <th scope="col" class="whitespace-nowrap">Upstream · Pool · Key</th>
                <th scope="col" class="whitespace-nowrap">Endpoint · Transport · Client</th>
                <th scope="col" class="whitespace-nowrap" title="Each bar shows this request's token composition; cache percentage is calculated over input tokens">Tokens · Cached</th>
                <th scope="col" class="whitespace-nowrap text-right">Cost</th>
              </tr>
            </thead>
            <tbody id="request-logs-table">
              <%= for request_log <- @request_logs.items do %>
                <tr
                  id={"request-log-row-#{request_log.id}"}
                  data-status={request_log.status}
                  data-tone={request_log_tone(request_log.status)}
                  phx-click="open_request_log"
                  phx-value-request-id={request_log.id}
                  class={["group/request-log cursor-pointer transition-colors hover:bg-base-200/80", (request_log.status == "in_progress" || @current_params["selected_request_id"] == request_log.id) && "bg-base-200/60"]}
                >
                  <td class="whitespace-nowrap align-middle text-base-content/70 max-lg:col-start-1 max-lg:row-start-1">
                    <.request_log_timestamp_cell
                      request_log={request_log}
                      datetime_preferences={@datetime_preferences}
                      prefix="request-log"
                    />
                  </td>
                  <td class="min-w-0 align-middle max-lg:col-start-1 max-lg:row-start-2">
                    <.request_log_model_cell request_log={request_log} prefix="request-log" />
                  </td>
                  <%!-- Below lg the row is a ledger entry. On a phone the fields
                stack one per line; from sm up the entry has two content columns
                (see data-ledger-dense in app.css) and attribution and transport
                move beside the identity instead of under it. --%>
                  <td class="min-w-0 align-middle max-lg:col-span-2 max-lg:col-start-1 max-lg:row-start-3 max-lg:sm:col-span-1 max-lg:sm:col-start-2 max-lg:sm:row-start-1">
                    <.request_log_attribution_cell
                      request_log={request_log}
                      plan_badge_id={"request-log-#{request_log.id}-plan-badge"}
                    />
                  </td>
                  <td class="min-w-0 align-middle max-lg:col-span-2 max-lg:col-start-1 max-lg:row-start-4 max-lg:sm:col-span-1 max-lg:sm:col-start-2 max-lg:sm:row-start-2">
                    <.request_log_route_cell request_log={request_log} prefix="request-log" />
                  </td>
                  <td class="align-middle max-lg:col-start-2 max-lg:row-start-1 max-lg:sm:col-start-3">
                    <Usage.request_log_token_lines request_log={request_log} prefix="request-log" />
                  </td>
                  <td class="align-middle max-lg:col-start-2 max-lg:row-start-2 max-lg:sm:col-start-3">
                    <Usage.request_log_cost_lines request_log={request_log} prefix="request-log" />
                  </td>
                </tr>
                <.request_log_failure_row
                  request_log={request_log}
                  datetime_preferences={@datetime_preferences}
                />
              <% end %>
            </tbody>
          </table>
        </div>
        <nav id="request-log-pagination" aria-label="Request log pagination" class="flex flex-wrap items-center gap-x-3 gap-y-2 border-t border-base-300 px-3 py-2 text-xs text-base-content/55">
          <span>Times {@datetime_preferences.timezone}</span>
          <span id="request-log-pagination-range" data-role="pagination-range" class="tabular-nums">Showing {@page.range}</span>
          <span data-role="pagination-status">Page {@page.current_page} of {@page.total_pages_label}</span>
          <span :if={@frozen? && @newer_count > 0} data-role="request-log-newer-count" class="tabular-nums">· {format_total(@newer_count)}{if !@newer_count_exact?, do: "+"} newer</span>
          <.link :if={@frozen?} id="request-log-back-to-latest" data-role="request-log-back-to-latest" patch={~p"/admin/request-logs?#{RequestLogFilterForm.query_params(@current_params)}"} class="font-semibold text-primary hover:underline">Back to latest</.link>
          <div class="ml-auto flex items-center gap-1">
            <button :if={request_id = @current_params["selected_request_id"]} id="request-log-open-selected" type="button" phx-click="open_request_log" phx-value-request-id={request_id} class="btn btn-xs">
              Open request {format_record_id(request_id)} <.icon name="hero-arrow-top-right-on-square" class="size-3" />
            </button>
            <.page_button id="request-log-pagination-prev" label="Previous" icon="hero-chevron-left" path={page_path(@current_params, @page.current_page - 1, @pin_at)} enabled={@page.has_previous_page} />
            <.page_button id="request-log-pagination-next" label="Next" icon="hero-chevron-right" path={page_path(@current_params, @page.current_page + 1, @pin_at)} enabled={@page.has_next_page} />
          </div>
        </nav>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :path, :string, default: nil
  attr :enabled, :boolean, required: true

  defp page_button(assigns) do
    ~H"""
    <.link :if={@enabled && @path} id={@id} patch={@path} data-role="pagination-link" class="btn btn-ghost btn-xs btn-square" aria-label={@label} title={@label}>
      <.icon name={@icon} class="size-3.5" /><span class="sr-only">{@label}</span>
    </.link>
    <span :if={!(@enabled && @path)} id={@id} data-role="pagination-link" class="btn btn-ghost btn-xs btn-square btn-disabled" aria-disabled="true" aria-label={@label}>
      <.icon name={@icon} class="size-3.5" /><span class="sr-only">{@label}</span>
    </span>
    """
  end

  # Paging carries the filters forward and drops the drawer selection, because
  # the inspected record is not on the page you are moving to. Leaving page one
  # pins the window it was read at; returning to page one drops the pin.
  defp page_path(current_params, page, pin_at) do
    filters = RequestLogFilterForm.query_params(current_params)

    params =
      if page <= 1 do
        filters
      else
        filters
        |> Map.put("page", Integer.to_string(page))
        |> put_pin(pin_at)
      end

    if page >= 1, do: ~p"/admin/request-logs?#{params}"
  end

  defp put_pin(params, {%DateTime{} = at, id}) when is_binary(id) do
    params
    |> Map.put("as_of", DateTime.to_iso8601(at))
    |> Map.put("as_of_id", id)
  end

  defp put_pin(params, _pin_at), do: params

  attr :request_log, :map, required: true
  attr :plan_badge_id, :string, default: nil

  def request_log_attribution_cell(assigns) do
    assigns =
      assigns
      |> assign(:account_named?, format_upstream_account_label(assigns.request_log) != "—")
      |> assign(:plan_label, plan_label(assigns.request_log))

    ~H"""
    <div class="request-log-lines grid min-w-0 gap-1">
      <%!-- A rejected request never reached an upstream, so on a phone this line
      would be two dashes taking a whole row. It keeps its place from md up,
      where the column has to line up with its neighbours. --%>
      <span class={["flex min-w-0 items-center gap-1.5", !@account_named? && "max-lg:hidden"]}>
        <span
          data-role="upstream-account"
          class="min-w-0 truncate text-base-content"
          title={format_upstream_account_label(@request_log)}
        >
          {format_upstream_account_label(@request_log)}
        </span>
        <span
          id={@plan_badge_id}
          data-role="plan-badge"
          class="max-w-20 shrink-0 truncate text-[11px] text-base-content/50"
          title={"Upstream account plan: #{@plan_label}"}
        >
          {@plan_label}
          <span :if={@request_log.upstream_account_plan_family} class="sr-only">{@request_log.upstream_account_plan_family}</span>
        </span>
      </span>
      <span class="flex min-w-0 items-center gap-1 text-[11px] text-base-content/55">
        <span
          data-role="pool-name"
          class="min-w-0 truncate"
          title={@request_log.pool_name}
        >
          {@request_log.pool_name}
        </span>
        <span aria-hidden="true" class="shrink-0 text-base-content/35">·</span>
        <span
          data-role="api-key"
          class="min-w-0 truncate"
          title={format_api_key(@request_log)}
        >
          {format_api_key(@request_log)}
        </span>
      </span>
    </div>
    """
  end

  defp plan_label(log) do
    case log.upstream_account_plan_label || log.upstream_account_plan_family do
      nil -> "—"
      label -> AdminBadges.plan_badge_label(label)
    end
  end

  attr :request_log, :map, required: true
  attr :datetime_preferences, :map, required: true

  def request_log_failure_row(assigns) do
    # format_errors/2 answers ["—"] when a request had none; the row exists only
    # when something actually went wrong, so the placeholder is dropped here
    # rather than printed under every healthy record.
    errors =
      assigns.request_log
      |> format_errors(assigns.datetime_preferences)
      |> Enum.reject(&(&1 == "—"))

    assigns =
      assigns
      |> assign(:errors, Enum.take(errors, 2))
      |> assign(:errors_title, Enum.join(errors, "; "))

    ~H"""
    <tr
      :if={@errors != []}
      id={"request-log-row-#{@request_log.id}-errors"}
      data-role="request-log-failure"
      data-tone={request_log_tone(@request_log.status)}
      phx-click="open_request_log"
      phx-value-request-id={@request_log.id}
      class="cursor-pointer transition-colors group-hover/request-log:bg-base-200/80"
    >
      <td colspan="6" class="!border-t-0 !pt-0 align-top max-lg:col-span-2 max-lg:col-start-1 max-lg:sm:col-span-3">
        <%!-- Failure evidence remains directly below its record, aligned with
        the first column. The status icon and label already identify the outcome. --%>
        <span
          id={"request-log-#{@request_log.id}-errors"}
          data-role="errors"
          class={[
            "flex h-5 min-w-0 items-center gap-1.5 truncate text-[0.72rem] leading-5",
            failure_row_text(@request_log.status)
          ]}
          title={@errors_title}
        >
          <span :for={{error, index} <- Enum.with_index(@errors)} class="contents">
            <span :if={index > 0} aria-hidden="true" class="shrink-0 opacity-40">·</span>
            <span data-role="error-line" class="min-w-0 truncate">{error}</span>
          </span>
        </span>
      </td>
    </tr>
    """
  end

  defp failure_row_text(status) do
    case request_log_tone(status) do
      "error" -> "text-error"
      "warning" -> "text-warning"
      _tone -> "text-base-content/65"
    end
  end

  attr :request_log, :map, required: true
  attr :datetime_preferences, :map, required: true
  attr :prefix, :string, required: true

  def request_log_timestamp_cell(assigns) do
    assigns =
      assigns
      |> assign(:timestamp_parts, DateTimeDisplay.format_datetime_parts(assigns.request_log.admitted_at, assigns.datetime_preferences))
      |> assign(:latency, format_route_latency(assigns.request_log.latency_ms))

    ~H"""
    <button
      id={"#{@prefix}-#{@request_log.id}-open-details"}
      type="button"
      data-role="open-request-log-details"
      phx-click="open_request_log"
      phx-value-request-id={@request_log.id}
      class="request-log-lines group grid max-w-full gap-1 rounded-field text-left transition-colors hover:text-primary focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary group-hover/request-log:text-primary"
      aria-label={"Inspect request #{format_record_id(@request_log.id) || @request_log.id}, #{format_datetime(@request_log.admitted_at, @datetime_preferences)}, #{status_label(@request_log.status || "unknown")}#{if @latency, do: " in #{@latency}"}"}
    >
      <span
        data-role="timestamp-datetime"
        class="block min-w-0 truncate tabular-nums text-base-content"
        title={format_datetime(@request_log.admitted_at, @datetime_preferences)}
      >
        <%= if @timestamp_parts do %>
          <span class="sr-only">{@timestamp_parts.date} </span>{@timestamp_parts.time}
        <% else %>
          {format_datetime(@request_log.admitted_at, @datetime_preferences)}
        <% end %>
      </span>
      <span
        data-role="status-label"
        class="flex min-w-0 items-center gap-1 whitespace-nowrap text-[11px]"
      >
        <span class="sr-only">{"Status: "}</span>
        <span data-role="status-icon" data-status={@request_log.status} aria-hidden="true" class={["inline-flex size-3 shrink-0 items-center justify-center", status_text_class(@request_log.status)]}>
          <.icon name={request_status_icon(@request_log.status)} class="size-3" />
        </span>
        <span class="admin-control-label">
          <span data-role="status-text" class={status_text_class(@request_log.status)}>{status_label(@request_log.status || "unknown")}</span><span
            :if={@latency}
            id={"#{@prefix}-#{@request_log.id}-latency"}
            data-role="latency"
            class="font-normal tabular-nums text-base-content/45"
            title={format_latency_title(@request_log.latency_ms)}
          >{" "}in {@latency}</span>
        </span>
      </span>
    </button>
    """
  end

  attr :request_log, :map, required: true
  attr :prefix, :string, required: true

  def request_log_model_cell(assigns) do
    assigns = assign(assigns, :model_known?, format_model_name(assigns.request_log) not in ["—", "-"])

    ~H"""
    <span
      id={"#{@prefix}-#{@request_log.id}-model-details"}
      data-role="model-details"
      class="request-log-lines grid min-w-0 gap-1"
      title={format_model_details_title(@request_log)}
    >
      <span data-role="model-identity-line" class="inline-flex min-w-0 max-w-full items-baseline gap-1.5 align-middle font-sans text-xs font-normal leading-4 text-base-content lg:flex">
        <span :if={@model_known?} data-role="model-swatch" aria-hidden="true" class="size-2 shrink-0 self-center rounded-xs" style={"background-color: #{Metrics.model_color(format_model_name(@request_log))}"}></span>
        <span
          data-role="model-name"
          class="min-w-0 truncate whitespace-nowrap text-base-content"
        >
          {if @model_known?, do: format_model_name(@request_log), else: "— no model"}
        </span>
        <span :if={@model_known? && format_model_reasoning_slot(@request_log)} data-role="model-effort" class="shrink-0 whitespace-nowrap text-base-content/60">
          <span data-role="model-reasoning-separator" aria-hidden="true">·</span>{" "}
          <span :if={reasoning = format_model_reasoning(@request_log)} data-role="model-reasoning">{reasoning}</span>
          <span
            :if={model_default_reasoning?(@request_log)}
            id={"#{@prefix}-#{@request_log.id}-reasoning-default"}
            data-role="model-reasoning-default"
            class="text-base-content/45"
            title="No reasoning effort recorded; the backend used the model default"
          >
            model default
          </span>
        </span>
        <span
          :if={format_served_model_detail(@request_log)}
          id={"#{@prefix}-#{@request_log.id}-served-model"}
          data-role="served-model"
          class="inline-flex min-w-0 items-center gap-1 text-warning"
          title={"Upstream declared model: #{@request_log.served_model}; differs from the model sent upstream"}
          aria-label={"Upstream declared model: #{@request_log.served_model}; differs from the model sent upstream"}
        >
          <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0 text-error" />
          <span class="truncate">{@request_log.served_model}</span>
        </span>
        <span :if={Map.get(@request_log, :model_conflict_attempts, []) != []} data-role="model-declaration-conflict" class="inline-flex shrink-0 text-warning" title={"The provider reported different model names during the same response on attempts #{Enum.join(@request_log.model_conflict_attempts, ", ")}"}>
          <.icon name="hero-exclamation-triangle" class="size-3.5" />
          <span class="sr-only">model name changed · attempts {Enum.join(@request_log.model_conflict_attempts, ", ")}</span>
        </span>
      </span>
      <span :if={@model_known?} data-role="model-context-line" class="min-w-0 truncate whitespace-nowrap pl-3.5 text-[11px] text-base-content/55">
        <span
          :if={detail = format_requested_reasoning_detail(@request_log)}
          id={"#{@prefix}-#{@request_log.id}-requested-reasoning"}
          data-role="requested-reasoning"
        >
          {detail}
        </span>
        <span
          :if={tier = format_model_service_tier(@request_log)}
          data-role="model-service-tier"
          class="text-base-content/45"
          title="Service tier"
        >
          <span :if={format_requested_reasoning_detail(@request_log)} aria-hidden="true">·</span> tier {tier}
        </span>
        <span
          :if={detail = format_requested_tier_detail(@request_log)}
          id={"#{@prefix}-#{@request_log.id}-requested-tier"}
          data-role="requested-service-tier"
          class="text-base-content/45"
          title="Service tier the request asked for; the upstream reported the tier shown before it"
        >
          {detail}
        </span>
      </span>
    </span>
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
    <div class="request-log-lines grid min-w-0 gap-1">
      <span class="flex min-w-0 items-center gap-2 text-base-content/80">
        <span
          id={"#{@prefix}-#{@request_log.id}-route"}
          data-role="route"
          class="min-w-0 truncate"
          title={format_transport_route(@request_log)}
        >
          {format_transport_route(@request_log)}
        </span>
      </span>
      <span class="flex min-w-0 items-center gap-1.5 text-[11px]">
        <.request_log_protocol_badge request_log={@request_log} prefix={@prefix} />
        <span
          :if={origin = translated_origin(@request_log)}
          id={"#{@prefix}-#{@request_log.id}-route-origin"}
          data-role="route-origin"
          class="flex min-w-0 shrink-[2] items-center gap-1 whitespace-nowrap text-base-content/55"
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
          class="min-w-0 truncate whitespace-nowrap text-base-content/55"
          title={user_agent.title}
        >
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

  defp status_text_class(status) do
    case request_log_tone(status) do
      "success" -> "text-success"
      "error" -> "text-error"
      "warning" -> "text-warning"
      "info" -> "text-info"
      _neutral -> "text-base-content/65"
    end
  end

  # Status icons, labels and failure details share one tone vocabulary.
  defp request_log_tone("succeeded"), do: "success"
  defp request_log_tone(status) when status in ["failed", "rejected"], do: "error"
  defp request_log_tone("cancelled"), do: "warning"
  defp request_log_tone("in_progress"), do: "info"
  defp request_log_tone(_status), do: nil
end
