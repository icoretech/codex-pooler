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
    {amount, suffix} = token_parts(format_token_totals(assigns.request_log))
    assigns = assigns |> assign(:token_amount, amount) |> assign(:token_suffix, suffix)

    ~H"""
    <div data-role="token-lines" class="grid min-w-0 gap-0.5">
      <%= if usage_line_applicable?(@request_log) do %>
        <span
          data-role="usage-token-line"
          class="flex h-5 min-w-0 items-center justify-end whitespace-nowrap font-semibold tabular-nums text-base-content"
          title={token_totals_title(@request_log)}
        >
          <span
            data-role="token-totals"
            class="min-w-0 truncate"
          >{@token_amount}<span :if={@token_suffix} class="text-base-content/60">{@token_suffix}</span></span>
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
    {symbol, amount} = cost_parts(format_usage_cost(assigns.request_log.cost))
    assigns = assigns |> assign(:cost_symbol, symbol) |> assign(:cost_amount, amount)

    ~H"""
    <div data-role="cost-lines" class="grid min-w-0 justify-end gap-0.5">
      <%= if usage_line_applicable?(@request_log) do %>
        <span
          data-role="usage-cost-line"
          class="flex h-5 min-w-0 items-center justify-end whitespace-nowrap font-semibold tabular-nums text-base-content"
          title={usage_cost_line_title(@request_log)}
        >
          <%!-- The currency mark and the magnitude suffix are notation, not
          figure: they keep the figure's weight but step back to the tone the
          model's reasoning label uses, so what carries down the column is the
          number itself. --%>
          <span
            data-role="cost"
            class="whitespace-nowrap"
            title={format_total_cost(@request_log.cost)}
          ><span :if={@cost_symbol} class="text-base-content/60">{@cost_symbol}</span>{@cost_amount}</span>
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

  defp cost_parts("$" <> amount), do: {"$", amount}
  defp cost_parts(label), do: {nil, label}

  # Format.token_count/1 appends a single magnitude letter; anything else is a
  # plain count and stays whole.
  defp token_parts(label) do
    case String.split_at(label, -1) do
      {amount, suffix} when suffix in ["k", "M", "B"] -> {amount, suffix}
      _plain -> {label, nil}
    end
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
