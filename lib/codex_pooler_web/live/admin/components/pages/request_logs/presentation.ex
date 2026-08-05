defmodule CodexPoolerWeb.Admin.RequestLogsPresentation do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.RequestLogFilterForm
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
  attr :current_params, :map, required: true
  attr :pin_at, :any, default: nil
  attr :frozen?, :boolean, default: false
  attr :newer_count, :integer, default: 0

  def request_logs_table(assigns) do
    assigns = assign(assigns, pagination(assigns.request_logs))

    ~H"""
    <div id="admin-request-logs" class="grid min-w-0 gap-3">
      <AdminComponents.empty_state
        :if={@request_logs.items == []}
        id="request-log-empty-state"
        title="No request logs"
        description="Send a request through a Pool or adjust the filters to find existing log rows."
        icon="hero-document-magnifying-glass"
      />

      <%!-- The pager sits above the rows and sticks: fifty records is a long
      way to scroll to reach Next, and on a tablet the entries are taller still.
      One tree, not one at each end. --%>
      <nav
        :if={@request_logs.items != []}
        id="request-log-pagination"
        class="sticky top-0 z-20 -mx-1 bg-base-200 px-1 py-2 text-xs"
        aria-label="Request log pagination"
      >
        <%!-- One row, at every width and in every state. The page number is the
        range said less precisely, so on a phone the range keeps the line and the
        ordinal steps aside rather than stacking a control several rows deep. --%>
        <div class="flex items-center gap-3">
          <p data-role="pagination-status" class="hidden shrink-0 text-base-content/60 sm:block">
            Page {@current_page} of {@total_pages}
          </p>

          <%!-- Behind page one the window is pinned. What arrived since, and the
          way back to live, ride on the range line: the reader needs the count
          and the exit, not a sentence explaining the mechanism. The range is
          what truncates when the row is tight; the way out never does. --%>
          <div class="flex min-w-0 grow items-center gap-2 sm:justify-center">
            <p
              id="request-log-range"
              data-role="pagination-range"
              class="min-w-0 truncate tabular-nums text-base-content/70"
            >
              <span class="hidden sm:inline">Showing </span>{request_log_range(@request_logs)}
            </p>
            <span
              :if={@frozen? && @newer_count > 0}
              data-role="request-log-newer-count"
              class="shrink-0 tabular-nums text-base-content/45"
            >
              · {format_total(@newer_count)} newer
            </span>
            <.link
              :if={@frozen?}
              id="request-log-back-to-latest"
              data-role="request-log-back-to-latest"
              patch={~p"/admin/request-logs?#{RequestLogFilterForm.query_params(@current_params)}"}
              class="shrink-0 font-semibold text-primary hover:underline"
            >
              Back to latest
            </.link>
          </div>

          <div class="join shrink-0">
            <.pagination_link
              id="request-log-pagination-prev"
              label="Previous"
              enabled={@has_previous_page}
              page={@current_page - 1}
              current_params={@current_params}
              pin_at={@pin_at}
            />
            <.pagination_link
              id="request-log-pagination-next"
              label="Next"
              enabled={@has_next_page}
              page={@current_page + 1}
              current_params={@current_params}
              pin_at={@pin_at}
            />
          </div>
        </div>
      </nav>

      <div
        :if={@request_logs.items != []}
        class="rounded-box border border-base-300 bg-base-100 lg:overflow-x-auto"
      >
        <table
          data-ledger-dense
          class="admin-status-tick admin-ledger-table table table-sm admin-log-table lg:min-w-[56rem]"
        >
          <%!-- The count is the footer's job; the caption repeats it only for
          assistive tech, which reads it before the rows. --%>
          <caption class="sr-only">
            Request logs, {format_total(@request_logs.total)} matching sanitized request logs
          </caption>
          <%!-- Transport is the only elastic column: its route, origin and client
          all truncate with the full value in a title, so it is the one that gives
          way when the table has to fit. Everything else keeps a floor.

          The floors only hold because the table carries a min-width equal to
          their sum (8+9+10+17+6+6 = 56rem); without it a narrow container
          compresses every column at once and the elastic column stops being the
          one that gives. Below lg the rows reflow and the floors do not apply. --%>
          <colgroup>
            <col class="w-32" />
            <col class="w-36" />
            <col class="w-40" />
            <col class="min-w-68" />
            <col class="w-24" />
            <col class="w-24" />
          </colgroup>
          <thead>
            <tr>
              <th class="whitespace-nowrap">Request</th>
              <th class="whitespace-nowrap">Model</th>
              <th class="whitespace-nowrap">Attribution</th>
              <th class="whitespace-nowrap">Transport</th>
              <th class="whitespace-nowrap text-right">Tokens</th>
              <th class="whitespace-nowrap text-right">Cost</th>
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
                class="group/request-log cursor-pointer transition-colors hover:bg-base-200/80"
              >
                <td class="whitespace-nowrap align-middle text-base-content/70 max-lg:col-start-2 max-lg:row-start-1">
                  <.request_log_timestamp_cell
                    request_log={request_log}
                    datetime_preferences={@datetime_preferences}
                    prefix="request-log"
                  />
                </td>
                <td class="min-w-0 align-middle max-lg:col-start-2 max-lg:row-start-2">
                  <.request_log_model_cell request_log={request_log} prefix="request-log" />
                </td>
                <%!-- Below lg the row is a ledger entry. On a phone the fields
                stack one per line; from sm up the entry has two content columns
                (see data-ledger-dense in app.css) and attribution and transport
                move beside the identity instead of under it. --%>
                <td class="min-w-0 align-middle max-lg:col-span-2 max-lg:col-start-2 max-lg:row-start-3 max-lg:sm:col-span-1 max-lg:sm:col-start-3 max-lg:sm:row-start-1">
                  <.request_log_attribution_cell
                    request_log={request_log}
                    plan_badge_id={"request-log-#{request_log.id}-plan-badge"}
                  />
                </td>
                <td class="min-w-0 align-middle max-lg:col-span-2 max-lg:col-start-2 max-lg:row-start-4 max-lg:sm:col-span-1 max-lg:sm:col-start-3 max-lg:sm:row-start-2">
                  <.request_log_route_cell request_log={request_log} prefix="request-log" />
                </td>
                <td class="align-middle max-lg:col-start-3 max-lg:row-start-1 max-lg:sm:col-start-4">
                  <Usage.request_log_token_lines request_log={request_log} prefix="request-log" />
                </td>
                <td class="align-middle max-lg:col-start-3 max-lg:row-start-2 max-lg:sm:col-start-4">
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
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :enabled, :boolean, required: true
  attr :page, :integer, required: true
  attr :current_params, :map, required: true
  attr :pin_at, :any, default: nil

  defp pagination_link(assigns) do
    ~H"""
    <.link
      :if={@enabled}
      id={@id}
      data-role="pagination-link"
      patch={~p"/admin/request-logs?#{page_query_params(@current_params, @page, @pin_at)}"}
      class="btn btn-xs join-item"
    >
      {@label}
    </.link>
    <span
      :if={!@enabled}
      id={@id}
      data-role="pagination-link"
      aria-disabled="true"
      class="btn btn-xs join-item btn-disabled"
    >
      {@label}
    </span>
    """
  end

  # Paging is a list control: it carries the filters forward and drops the
  # drawer selection, because the inspected record is not on the page you are
  # moving to. Leaving page one also pins the window it was read at, so the
  # pages behind it stay still; returning to page one drops the pin and the list
  # is live again.
  defp page_query_params(current_params, page, pin_at) do
    filters = RequestLogFilterForm.query_params(current_params)

    if page <= 1 do
      filters
    else
      filters
      |> Map.put("page", Integer.to_string(page))
      |> put_pin(pin_at)
    end
  end

  # The pin is a cursor in the list's sort key — the head row, not the moment it
  # landed — so it travels as both halves or not at all.
  defp put_pin(params, {%DateTime{} = at, id}) when is_binary(id) do
    params
    |> Map.put("as_of", DateTime.to_iso8601(at))
    |> Map.put("as_of_id", id)
  end

  defp put_pin(params, _pin_at), do: params

  defp pagination(%{total: total, limit: limit, offset: offset})
       when is_integer(limit) and limit > 0 do
    %{
      current_page: div(offset, limit) + 1,
      total_pages: max(ceil(total / limit), 1),
      has_previous_page: offset > 0,
      has_next_page: offset + limit < total
    }
  end

  # `request_logs` is declared as a plain map, so a caller can satisfy the attr
  # and still not carry a window. A page of one with nowhere to go beats a
  # FunctionClauseError raised from inside a render.
  defp pagination(_request_logs) do
    %{current_page: 1, total_pages: 1, has_previous_page: false, has_next_page: false}
  end

  defp request_log_range(%{total: 0}), do: "0 of 0"

  defp request_log_range(%{total: total, limit: limit, offset: offset})
       when is_integer(limit) and limit > 0 do
    "#{offset + 1}-#{min(offset + limit, total)} of #{total}"
  end

  defp request_log_range(%{total: total}), do: "#{total}"

  attr :request_log, :map, required: true
  attr :plan_badge_id, :string, default: nil

  def request_log_attribution_cell(assigns) do
    assigns =
      assign(assigns, :account_named?, format_upstream_account_label(assigns.request_log) != "—")

    ~H"""
    <div class="grid min-w-0 gap-0.5">
      <%!-- A rejected request never reached an upstream, so on a phone this line
      would be two dashes taking a whole row. It keeps its place from md up,
      where the column has to line up with its neighbours. --%>
      <span class={["flex h-5 min-w-0 items-center gap-1.5", !@account_named? && "max-lg:hidden"]}>
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
      <span class="flex h-5 min-w-0 items-center gap-2 text-base-content/45">
        <span
          data-role="pool-name"
          class="flex min-w-0 items-center gap-1.5"
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
        <span
          data-role="api-key"
          class="flex min-w-0 items-center gap-1.5"
          title={format_api_key(@request_log)}
        >
          <span
            data-role="api-key-icon"
            class="grid size-3 shrink-0 place-items-center text-base-content/35"
          >
            <.icon name="hero-key" class="size-3" />
          </span>
          <span class="truncate">{format_api_key(@request_log)}</span>
        </span>
      </span>
    </div>
    """
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
      <td colspan="6" class="!border-t-0 !pt-0 align-top max-lg:col-span-3 max-lg:col-start-2">
        <%!-- Reasons run along one line: they are facets of a single failure, not
        separate events, and a line each doubles the height of every failed
        record. No icon either — the tone rail beside them already says this is
        a failure, and a bullet would push the text out of the column its record
        occupies. --%>
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
        <%!-- The duration reads as part of the outcome — "Succeeded in 3.2s" —
        rather than as a figure hanging off the route. Quiet and unbolded so the
        status keeps the line. --%>
        <span
          :if={latency = format_route_latency(@request_log.latency_ms)}
          id={"#{@prefix}-#{@request_log.id}-latency"}
          data-role="latency"
          class="shrink-0 font-normal text-base-content/45"
          title={format_latency_title(@request_log.latency_ms)}
        >
          in {latency}
        </span>
      </span>
    </button>
    """
  end

  attr :request_log, :map, required: true
  attr :prefix, :string, required: true

  def request_log_model_cell(assigns) do
    ~H"""
    <span
      id={"#{@prefix}-#{@request_log.id}-model-details"}
      data-role="model-details"
      class="min-w-0 gap-0.5 max-lg:block max-lg:h-5 max-lg:truncate max-lg:whitespace-nowrap lg:grid"
      title={format_model_details_title(@request_log)}
    >
      <span
        data-role="model-name"
        class="h-5 min-w-0 truncate whitespace-nowrap font-semibold leading-5 text-base-content max-lg:inline lg:block"
      >
        {format_model_name(@request_log)}
      </span>
      <span class="h-5 min-w-0 items-center gap-1 truncate whitespace-nowrap leading-5 text-base-content/60 max-lg:inline lg:flex">
        <span :if={reasoning = format_model_reasoning(@request_log)} data-role="model-reasoning">
          {reasoning}
        </span>
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
        >
          <span>/</span> {tier}
        </span>
        <span
          :if={detail = format_requested_tier_detail(@request_log)}
          id={"#{@prefix}-#{@request_log.id}-requested-tier"}
          class="text-base-content/45"
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
    <div class="grid min-w-0 gap-0.5">
      <%!-- The route repeats on every record and is one tap away in the drawer;
      on a phone it is the line that earns its height least. --%>
      <span class="h-5 min-w-0 items-center gap-2 text-base-content/60 max-lg:hidden lg:flex">
        <span
          id={"#{@prefix}-#{@request_log.id}-route"}
          data-role="route"
          class="min-w-0 truncate"
          title={format_transport_route(@request_log)}
        >
          {format_transport_route(@request_log)}
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
