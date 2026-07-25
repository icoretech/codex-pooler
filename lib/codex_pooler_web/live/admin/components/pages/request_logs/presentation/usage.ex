defmodule CodexPoolerWeb.Admin.RequestLogsPresentation.Usage do
  @moduledoc false

  use CodexPoolerWeb, :html

  import CodexPoolerWeb.Admin.RequestLogsDisplay,
    only: [
      compression_savings_line: 1,
      compression_savings_reason: 1,
      compression_savings_status: 1,
      compression_savings_title: 1,
      compression_savings_unit: 1,
      format_cached_token_breakdown: 1,
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

  def request_log_token_lines(assigns) do
    ~H"""
    <div data-role="token-lines" class="grid min-w-0 gap-0.5">
      <%= if usage_line_applicable?(@request_log) do %>
        <span
          data-role="usage-token-line"
          class="flex h-5 min-w-0 items-center justify-end whitespace-nowrap tabular-nums text-base-content"
          title={token_totals_title(@request_log)}
        >
          <span data-role="token-totals" class="min-w-0 truncate">
            {format_token_totals(@request_log)}
          </span>
        </span>
        <span
          :if={cached = format_cached_token_breakdown(@request_log)}
          id={"#{@prefix}-#{@request_log.id}-cached-tokens"}
          data-role="cached-tokens"
          class="flex h-5 items-center justify-end whitespace-nowrap tabular-nums text-base-content/45"
          title={usage_cached_line_title(@request_log)}
        >
          {cached}
        </span>
      <% else %>
        <span
          data-role="usage-placeholder"
          class="h-5 items-center justify-end whitespace-nowrap text-base-content/45 max-md:hidden md:flex"
        >
          —
        </span>
      <% end %>
    </div>
    """
  end

  attr :request_log, :map, required: true
  attr :prefix, :string, required: true

  def request_log_cost_lines(assigns) do
    ~H"""
    <div data-role="cost-lines" class="grid min-w-0 justify-end gap-0.5">
      <%= if usage_line_applicable?(@request_log) do %>
        <span
          data-role="usage-cost-line"
          class="flex h-5 min-w-0 items-center justify-end whitespace-nowrap font-semibold tabular-nums text-base-content"
          title={usage_cost_line_title(@request_log)}
        >
          <span
            data-role="cost"
            class="whitespace-nowrap"
            title={format_total_cost(@request_log.cost)}
          >
            {format_usage_cost(@request_log.cost)}
          </span>
        </span>
        <span
          :if={compression_line = compression_savings_line(@request_log)}
          id={"#{@prefix}-#{@request_log.id}-compression-savings"}
          data-role="compression-savings"
          data-compression-unit={compression_savings_unit(@request_log)}
          data-compression-status={compression_savings_status(@request_log)}
          data-compression-reason={compression_savings_reason(@request_log)}
          class="flex h-5 min-w-0 items-center justify-end gap-1 whitespace-nowrap tabular-nums text-base-content/45"
          title={compression_savings_title(@request_log)}
        >
          <.icon name="hero-arrows-pointing-in" class="size-3 shrink-0" />
          <span class="sr-only">compression</span>
          <span class="truncate">{compression_line}</span>
        </span>
      <% else %>
        <span
          data-role="cost-placeholder"
          class="h-5 items-center justify-end whitespace-nowrap text-base-content/45 max-md:hidden md:flex"
          title={format_total_cost(@request_log.cost)}
        >
          —
        </span>
      <% end %>
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
      <span class="sr-only">{speed_tier_label(@mode)}</span>
    </span>
    """
  end
end
