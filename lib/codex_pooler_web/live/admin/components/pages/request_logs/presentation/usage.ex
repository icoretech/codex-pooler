defmodule CodexPoolerWeb.Admin.RequestLogsPresentation.Usage do
  @moduledoc false

  use CodexPoolerWeb, :html

  import CodexPoolerWeb.Admin.RequestLogsDisplay,
    only: [
      cached_cost_title: 1,
      format_cached_input_cost_summary: 1,
      format_cached_token_breakdown: 1,
      format_errors: 2,
      format_token_totals: 1,
      format_total_cost: 1,
      format_usage_cost: 1,
      speed_tier_label: 1,
      speed_tier_mode: 1,
      token_totals_title: 1,
      usage_cached_line_title: 1,
      usage_cost_line_title: 1,
      usage_line_applicable?: 1
    ]

  attr :request_log, :map, required: true
  attr :prefix, :string, required: true
  attr :datetime_preferences, :map, required: true
  attr :show_errors, :boolean, default: false

  def request_log_usage_lines(assigns) do
    ~H"""
    <div data-role="token-lines" class="grid gap-0.5 leading-tight">
      <%= if usage_line_applicable?(@request_log) do %>
        <span
          data-role="usage-token-line"
          class="block whitespace-nowrap"
          title={usage_cached_line_title(@request_log)}
        >
          <span
            data-role="token-totals"
            class="whitespace-nowrap"
            title={token_totals_title(@request_log)}
          >
            {format_token_totals(@request_log)}
          </span>
          <span
            id={"#{@prefix}-#{@request_log.id}-cached-tokens"}
            data-role="cached-tokens"
            class="whitespace-nowrap pl-1 text-base-content/50"
            title={usage_cached_line_title(@request_log)}
          >
            {format_cached_token_breakdown(@request_log) || "—"}
          </span>
        </span>
        <span
          data-role="usage-cost-line"
          class="block whitespace-nowrap text-base-content/70"
          title={usage_cost_line_title(@request_log)}
        >
          <span
            data-role="cost"
            class="whitespace-nowrap"
            title={format_total_cost(@request_log.cost)}
          >
            {format_usage_cost(@request_log.cost)}
          </span>
          <span
            id={"#{@prefix}-#{@request_log.id}-cached-cost"}
            data-role="cached-cost"
            class="whitespace-nowrap pl-1 text-base-content/50"
            title={cached_cost_title(@request_log)}
          >
            {format_cached_input_cost_summary(@request_log) || "(cached n/a)"}
          </span>
        </span>
      <% else %>
        <span
          data-role="usage-placeholder"
          class="block whitespace-nowrap text-base-content/55"
          title={format_total_cost(@request_log.cost)}
        >
          —
        </span>
      <% end %>
      <span
        :for={error <- format_errors(@request_log, @datetime_preferences)}
        :if={@show_errors}
        data-role="error-line"
        class="block text-base-content/65"
      >
        {error}
      </span>
    </div>
    """
  end

  attr :request_log, :map, required: true

  def speed_tier_indicator(assigns) do
    assigns = assign(assigns, :mode, speed_tier_mode(assigns.request_log))

    ~H"""
    <span
      :if={@mode}
      data-role="fast-mode-indicator"
      data-speed-tier={@mode}
      class="ml-1 inline-flex items-center"
    >
      <.icon name="hero-bolt" class="size-3.5" />
      <.icon :if={@mode == :ultrafast} name="hero-bolt" class="-ml-1 size-3.5" />
      <span class="sr-only">{speed_tier_label(@mode)}</span>
    </span>
    """
  end
end
