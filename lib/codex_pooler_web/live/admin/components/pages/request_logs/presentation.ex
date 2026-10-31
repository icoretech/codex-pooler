defmodule CodexPoolerWeb.Admin.RequestLogsPresentation do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.LogPagination
  alias CodexPoolerWeb.Admin.RequestLogFilterForm
  alias CodexPoolerWeb.Admin.RequestLogsDisplay.Status
  alias CodexPoolerWeb.Admin.RequestLogsPresentation.Issues
  alias CodexPoolerWeb.Admin.RequestLogsPresentation.Metrics
  alias CodexPoolerWeb.Admin.RequestLogsPresentation.Usage

  import CodexPoolerWeb.Admin.RequestLogsDisplay,
    only: [
      format_api_key: 1,
      format_datetime: 2,
      format_latency_title: 1,
      format_model_details_title: 1,
      format_model_name: 1,
      format_model_reasoning: 1,
      format_model_reasoning_slot: 1,
      format_record_id: 1,
      format_requested_reasoning_detail: 1,
      format_route_latency: 1,
      format_route_metadata: 1,
      format_total: 1,
      format_upstream_account_label: 1,
      model_default_reasoning?: 1,
      speed_level: 1,
      speed_level_title: 1,
      route_paths: 1,
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

  @spec request_logs_table(map()) :: Phoenix.LiveView.Rendered.t()
  def request_logs_table(assigns) do
    assigns =
      assigns
      |> assign(:page, LogPagination.metadata(assigns.request_logs))
      |> assign(:has_issues?, Enum.any?(assigns.request_logs.items, &Issues.has_issues?(&1, assigns.datetime_preferences)))

    ~H"""
    <div id="admin-request-logs" class="grid min-w-0 gap-3">
      <div
        :if={@request_logs.items == [] && @loading? && !@loaded?}
        id="request-log-loading-state-wrapper"
      >
        <AdminComponents.empty_state
          id="request-log-loading-state"
          title={gettext("Loading request logs")}
          description={gettext("Loading the latest requests for the selected filters.")}
          icon="hero-arrow-path"
          loading?={true}
        />
      </div>

      <AdminComponents.empty_state
        :if={@request_logs.items == [] && !@loading? && !@loaded?}
        id="request-log-error-state"
        title={gettext("Request logs are not available")}
        description={gettext("Reload the page or adjust the filters to try again.")}
        icon="hero-exclamation-triangle"
      />

      <AdminComponents.empty_state
        :if={@request_logs.items == [] && @loaded?}
        id="request-log-empty-state"
        title={gettext("No request logs")}
        description={gettext("Send a request through a Pool or adjust the filters to find existing log rows.")}
        icon="hero-document-magnifying-glass"
      />

      <div
        :if={@request_logs.items != []}
        class="overflow-hidden rounded-box border border-base-300 bg-base-100"
      >
        <.request_logs_pagination
          top?={true}
          page={@page}
          datetime_preferences={@datetime_preferences}
          current_params={@current_params}
          pin_at={@pin_at}
          frozen?={@frozen?}
          newer_count={@newer_count}
          newer_count_exact?={@newer_count_exact?}
        />
        <Usage.token_composition_legend />
        <div class="request-log-table-scroll lg:overflow-x-auto">
          <table
            data-ledger-dense
            data-has-issues={to_string(@has_issues?)}
            class="admin-request-explorer admin-ledger-table table table-sm admin-log-table font-sans"
          >
            <%!-- The count is the pager's job; the caption repeats it only for
          assistive tech, which reads it before the rows. --%>
            <caption class="sr-only">
              <%= if Map.get(@request_logs, :total_exact?) == false do %>
                {ngettext("Request logs, %{requests} or more matching sanitized request logs", "Request logs, %{requests} or more matching sanitized request logs", @request_logs.total, requests: format_total(@request_logs.total))}
              <% else %>
                {ngettext("Request logs, %{requests} matching sanitized request log", "Request logs, %{requests} matching sanitized request logs", @request_logs.total, requests: format_total(@request_logs.total))}
              <% end %>
            </caption>
            <%!-- Omit the entire issues track when this page has no signals;
          the same cells reflow as a ledger below lg. --%>
            <colgroup>
              <col class="request-log-time-column" />
              <col class="request-log-model-column" />
              <col class="request-log-attribution-column" />
              <col />
              <col :if={@has_issues?} class="request-log-issues-column" />
              <col class="request-log-tokens-column" />
              <col class="request-log-cost-column" />
            </colgroup>
            <thead>
              <tr>
                <th scope="col" class="whitespace-nowrap">{gettext("Time · Status")}</th>
                <th scope="col" class="whitespace-nowrap">{gettext("Model · Effort · Speed")}</th>
                <th scope="col" class="whitespace-nowrap">{gettext("Upstream · Pool · Key")}</th>
                <th scope="col" class="whitespace-nowrap">{gettext("Endpoint · Transport · Client")}</th>
                <th :if={@has_issues?} id="request-log-issues-heading" scope="col" class="whitespace-nowrap">{gettext("Errors · Warnings")}</th>
                <th scope="col" class="whitespace-nowrap" title={gettext("Each bar shows this request's token composition; cache percentage is calculated over input tokens")}>{gettext("Tokens · Cached")}</th>
                <th scope="col" class="whitespace-nowrap text-right">{gettext("Cost")}</th>
              </tr>
            </thead>
            <tbody id="request-logs-table">
              <%= for request_log <- @request_logs.items do %>
                <tr
                  id={"request-log-row-#{request_log.id}"}
                  data-status={request_log.status}
                  data-display-status={display_status(request_log)}
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
                  <Issues.request_log_issues_cell :if={@has_issues?} request_log={request_log} datetime_preferences={@datetime_preferences} prefix="request-log" />
                  <td class="align-middle max-lg:col-start-2 max-lg:row-start-1 max-lg:sm:col-start-3">
                    <Usage.request_log_token_lines request_log={request_log} prefix="request-log" />
                  </td>
                  <td class="align-middle max-lg:col-start-2 max-lg:row-start-2 max-lg:sm:col-start-3">
                    <Usage.request_log_cost_lines request_log={request_log} prefix="request-log" />
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
        <.request_logs_pagination
          page={@page}
          datetime_preferences={@datetime_preferences}
          current_params={@current_params}
          pin_at={@pin_at}
          frozen?={@frozen?}
          newer_count={@newer_count}
          newer_count_exact?={@newer_count_exact?}
        />
      </div>
    </div>
    """
  end

  attr :top?, :boolean, default: false
  attr :page, :map, required: true
  attr :datetime_preferences, :map, required: true
  attr :current_params, :map, required: true
  attr :pin_at, :any, required: true
  attr :frozen?, :boolean, required: true
  attr :newer_count, :integer, required: true
  attr :newer_count_exact?, :boolean, required: true

  defp request_logs_pagination(assigns) do
    assigns = assign(assigns, :suffix, if(assigns.top?, do: "-top", else: ""))

    ~H"""
    <nav id={"request-log-pagination#{@suffix}"} aria-label={gettext("Request log pagination")} class={["flex min-w-0 flex-wrap items-center gap-x-3 gap-y-2 border-base-300 px-3 py-2 text-xs text-base-content/55", if(@top?, do: "border-b", else: "border-t")]}>
      <span>{gettext("Times %{timezone}", timezone: @datetime_preferences.timezone)}</span>
      <span id={"request-log-pagination#{@suffix}-range"} data-role="pagination-range" class="tabular-nums">{gettext("Showing %{range}", range: @page.range)}</span>
      <span data-role="pagination-status">{gettext("Page %{page} of %{total}", page: @page.current_page, total: @page.total_pages_label)}</span>
      <span :if={@frozen? && @newer_count > 0} data-role="request-log-newer-count" class="tabular-nums">· {if @newer_count_exact?, do: ngettext("%{requests} newer", "%{requests} newer", @newer_count, requests: format_total(@newer_count)), else: ngettext("%{requests}+ newer", "%{requests}+ newer", @newer_count, requests: format_total(@newer_count))}</span>
      <.link :if={@frozen?} id={"request-log-back-to-latest#{@suffix}"} data-role="request-log-back-to-latest" patch={~p"/admin/request-logs?#{RequestLogFilterForm.query_params(@current_params)}"} class="font-semibold text-primary hover:underline">{gettext("Back to latest")}</.link>
      <div class="ml-auto flex items-center gap-1">
        <button :if={request_id = @current_params["selected_request_id"]} id={"request-log-open-selected#{@suffix}"} type="button" phx-click="open_request_log" phx-value-request-id={request_id} class="btn btn-xs">
          {gettext("Open request %{id}", id: format_record_id(request_id))} <.icon name="hero-arrow-top-right-on-square" class="size-3" />
        </button>
        <.page_button id={"request-log-pagination#{@suffix}-prev"} label={gettext("Previous")} icon="hero-chevron-left" path={page_path(@current_params, @page.current_page - 1, @pin_at)} enabled={@page.has_previous_page} />
        <.page_button id={"request-log-pagination#{@suffix}-next"} label={gettext("Next")} icon="hero-chevron-right" path={page_path(@current_params, @page.current_page + 1, @pin_at)} enabled={@page.has_next_page} />
      </div>
    </nav>
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

  @spec request_log_attribution_cell(map()) :: Phoenix.LiveView.Rendered.t()
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
      <span data-role="upstream-plan-line" class={["flex min-w-0 items-baseline gap-1 font-sans text-xs font-normal leading-4", !@account_named? && "max-lg:hidden"]}>
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
          class="max-w-[50%] shrink-0 truncate whitespace-nowrap text-base-content/50"
          title={gettext("Upstream account plan: %{plan}", plan: @plan_label)}
        >
          <span :if={@account_named? && @plan_label != "—"} data-role="upstream-plan-separator" aria-hidden="true">·</span>{" "}<span data-role="plan-name" class={AdminBadges.plan_text_class(@request_log.upstream_account_plan_label || @request_log.upstream_account_plan_family)}>{@plan_label}</span>
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
    case Enum.find([log.upstream_account_plan_label, log.upstream_account_plan_family], &(is_binary(&1) and String.trim(&1) != "")) do
      nil -> "—"
      label -> AdminBadges.plan_badge_label(label)
    end
  end

  attr :request_log, :map, required: true
  attr :datetime_preferences, :map, required: true
  attr :prefix, :string, required: true

  @spec request_log_timestamp_cell(map()) :: Phoenix.LiveView.Rendered.t()
  def request_log_timestamp_cell(assigns) do
    assigns =
      assigns
      |> assign(:latency, format_route_latency(assigns.request_log.latency_ms))
      |> assign(:display_status, display_status(assigns.request_log))

    ~H"""
    <button
      id={"#{@prefix}-#{@request_log.id}-open-details"}
      type="button"
      data-role="open-request-log-details"
      phx-click="open_request_log"
      phx-value-request-id={@request_log.id}
      class="request-log-lines group grid max-w-full gap-1 rounded-field text-left transition-colors hover:text-primary focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary group-hover/request-log:text-primary"
      aria-label={inspect_request_label(@request_log, @datetime_preferences, @latency)}
    >
      <span
        data-role="timestamp-datetime"
        class="block min-w-0 whitespace-normal break-words font-sans text-xs font-normal leading-4 tabular-nums text-base-content"
        title={format_datetime(@request_log.admitted_at, @datetime_preferences)}
      >
        {format_datetime(@request_log.admitted_at, @datetime_preferences)}
      </span>
      <span
        data-role="status-label"
        title={Status.status_description(@display_status)}
        class="flex min-w-0 items-center gap-1 whitespace-nowrap text-[11px]"
      >
        <span class="sr-only">{gettext("Status:")}</span>
        <span data-role="status-icon" data-status={@display_status} aria-hidden="true" class={["inline-flex size-3 shrink-0 items-center justify-center", status_text_class(@display_status)]}>
          <.icon name={request_status_icon(@display_status)} class="size-3" />
        </span>
        <span class="admin-control-label">
          <span data-role="status-text" class={status_text_class(@display_status)}>{status_label(@display_status || "unknown")}</span><span
            :if={@latency}
            id={"#{@prefix}-#{@request_log.id}-latency"}
            data-role="latency"
            class="font-normal tabular-nums text-base-content/45"
            title={format_latency_title(@request_log.latency_ms)}
          >{" "}{gettext("in %{latency}", latency: @latency)}</span>
        </span>
      </span>
    </button>
    """
  end

  defp inspect_request_label(log, preferences, nil), do: gettext("Inspect request %{id}, %{time}, %{status}", id: format_record_id(log.id) || log.id, time: format_datetime(log.admitted_at, preferences), status: status_label(display_status(log) || "unknown"))
  defp inspect_request_label(log, preferences, latency), do: gettext("Inspect request %{id}, %{time}, %{status} in %{latency}", id: format_record_id(log.id) || log.id, time: format_datetime(log.admitted_at, preferences), status: status_label(display_status(log) || "unknown"), latency: latency)

  attr :request_log, :map, required: true
  attr :prefix, :string, required: true

  @spec request_log_model_cell(map()) :: Phoenix.LiveView.Rendered.t()
  def request_log_model_cell(assigns) do
    assigns = assign(assigns, :model_known?, format_model_name(assigns.request_log) not in ["—", "-"])

    ~H"""
    <span
      id={"#{@prefix}-#{@request_log.id}-model-details"}
      data-role="model-details"
      class="request-log-lines grid min-w-0 gap-1"
      title={format_model_details_title(@request_log)}
    >
      <span data-role="model-identity-line" class="inline-flex min-w-0 max-w-full items-baseline gap-1 align-middle font-sans text-xs font-normal leading-4 text-base-content lg:flex">
        <span :if={@model_known?} data-role="model-swatch" aria-hidden="true" class="size-2 shrink-0 self-center rounded-xs" style={"background-color: #{Metrics.model_color(format_model_name(@request_log))}"}></span>
        <span
          data-role="model-name"
          class={["min-w-0 truncate whitespace-nowrap", if(@model_known?, do: "text-base-content", else: "text-base-content/45")]}
        >
          {if @model_known?, do: format_model_name(@request_log), else: gettext("— no model")}
        </span>
        <span :if={@model_known? && format_model_reasoning_slot(@request_log)} data-role="model-effort" class="shrink-0 whitespace-nowrap text-base-content/60">
          <span data-role="model-reasoning-separator" aria-hidden="true">·</span>{" "}
          <span :if={reasoning = format_model_reasoning(@request_log)} data-role="model-reasoning">{reasoning}</span>
          <span
            :if={model_default_reasoning?(@request_log)}
            id={"#{@prefix}-#{@request_log.id}-reasoning-default"}
            data-role="model-reasoning-default"
            class="text-base-content/45"
            title={gettext("No reasoning effort recorded; the backend used the model default")}
          >
            {gettext("default")}
          </span>
        </span>
      </span>
      <span :if={@model_known?} data-role="model-context-line" class="min-w-0 truncate whitespace-nowrap pl-3.5 text-[11px] text-base-content/55">
        <span data-role="model-speed" data-speed-level={speed_level(@request_log)} class="-ml-3.5 mr-1 inline-flex items-center gap-px align-middle text-warning" title={speed_level_title(@request_log)}>
          <.icon :for={n <- 1..3} name={if n <= speed_level(@request_log), do: "hero-bolt-solid", else: "hero-bolt"} class={["size-3", n > speed_level(@request_log) && "opacity-30"]} />
          <span class="sr-only">{speed_level_title(@request_log)}</span>
        </span>
        <span
          :if={detail = format_requested_reasoning_detail(@request_log)}
          id={"#{@prefix}-#{@request_log.id}-requested-reasoning"}
          data-role="requested-reasoning"
        >
          {detail}
        </span>
      </span>
    </span>
    """
  end

  attr :request_log, :map, required: true
  attr :prefix, :string, required: true

  @spec request_log_protocol_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def request_log_protocol_badge(assigns) do
    ~H"""
    <span
      id={"#{@prefix}-#{@request_log.id}-protocol"}
      data-role="protocol-badge"
      class={protocol_badge_class(@request_log.transport)}
      title={protocol_title(@request_log)}
    >
      {protocol_label(@request_log.transport)}
    </span>
    """
  end

  attr :request_log, :map, required: true
  attr :prefix, :string, required: true

  @spec request_log_route_cell(map()) :: Phoenix.LiveView.Rendered.t()
  def request_log_route_cell(assigns) do
    assigns = assign(assigns, :route_paths, route_paths(assigns.request_log))

    ~H"""
    <div class="request-log-lines grid min-w-0 gap-1">
      <span data-role="route-paths-line" class="flex min-w-0 items-center gap-1 whitespace-nowrap text-base-content/80" title={if @route_paths.source, do: gettext("Translated from %{source} to %{destination}", source: @route_paths.source, destination: @route_paths.destination)}>
        <span
          :if={@route_paths.source}
          id={"#{@prefix}-#{@request_log.id}-route-origin"}
          data-role="route-origin"
          class="min-w-0 max-w-[50%] shrink-0 truncate"
          title={gettext("Client endpoint: %{endpoint}", endpoint: @route_paths.source)}
        >
          {@route_paths.source}
        </span>
        <span :if={@route_paths.source} data-role="route-translation" class="inline-flex shrink-0 items-center text-base-content/55">
          <.icon name="hero-arrows-right-left" class="size-3" />
          <span class="sr-only">{gettext("translated to")}</span>
        </span>
        <span
          id={"#{@prefix}-#{@request_log.id}-route"}
          data-role="route"
          class="min-w-0 truncate"
          title={@route_paths.destination}
        >
          {@route_paths.destination}
        </span>
      </span>
      <span data-role="route-context-line" class="flex min-w-0 items-center gap-1.5 whitespace-nowrap text-[11px]">
        <.request_log_protocol_badge request_log={@request_log} prefix={@prefix} />
        <span
          :if={user_agent = user_agent_display(@request_log)}
          id={"#{@prefix}-#{@request_log.id}-user-agent"}
          data-role="user-agent"
          data-client-kind={user_agent.kind}
          class="flex min-w-0 items-center gap-1 whitespace-nowrap text-base-content/55"
          title={user_agent.title}
        >
          <.request_log_user_agent_icon user_agent={user_agent} />
          <span data-role="user-agent-text" class="truncate">{user_agent.text}</span>
        </span>
        <span
          :if={route_metadata = format_route_metadata(@request_log)}
          id={"#{@prefix}-#{@request_log.id}-route-metadata"}
          data-role="route-metadata"
          class="min-w-0 max-w-full truncate whitespace-nowrap text-base-content/40"
          title={route_metadata}
        >
          {route_metadata}
        </span>
      </span>
    </div>
    """
  end

  attr :user_agent, :map, required: true

  @spec request_log_user_agent_icon(map()) :: Phoenix.LiveView.Rendered.t()
  def request_log_user_agent_icon(assigns) do
    ~H"""
    <span data-role="user-agent-icon" aria-hidden="true" class="inline-flex shrink-0">
      <%= case @user_agent.logo do %>
        <% %{format: :svg, asset: asset} -> %>
          <span data-role="user-agent-logo" data-logo={asset} class="request-client-logo" style={"mask-image: url(#{~p"/images/client-logos/#{asset}"})"}></span>
        <% %{format: :png, asset: asset} -> %>
          <img data-role="user-agent-logo" data-logo={asset} class="request-client-logo-image" src={~p"/images/client-logos/#{asset}"} width="14" height="14" alt="" />
        <% nil -> %>
          <.icon name={@user_agent.icon} class={@user_agent.icon_class} />
      <% end %>
    </span>
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

  # The status a row shows: a client cancellation is recorded `failed` and
  # shown as its own class (`RequestOutcome`); rows built without the read
  # model's `display_status` show their recorded status.
  defp display_status(request_log), do: Map.get(request_log, :display_status) || request_log.status

  # Status icons, labels and failure details share one tone vocabulary.
  defp request_log_tone("succeeded"), do: "success"
  defp request_log_tone(status) when status in ["failed", "rejected"], do: "error"
  defp request_log_tone("client_cancelled"), do: "warning"
  defp request_log_tone(status) when status in ["accepted", "in_progress"], do: "info"
  defp request_log_tone(_status), do: nil
end
