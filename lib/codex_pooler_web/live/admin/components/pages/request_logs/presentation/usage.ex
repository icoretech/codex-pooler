defmodule CodexPoolerWeb.Admin.RequestLogsPresentation.Usage do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.RequestLogsPresentation.Metrics

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
    cached = cached_input_tokens(assigns.request_log)

    assigns =
      assigns
      |> assign(:token_amount, amount)
      |> assign(:token_suffix, suffix)
      |> assign(:composition, Metrics.token_composition(assigns.request_log.token_counts))
      |> assign(:cache_rate, Metrics.cache_rate_label(assigns.request_log.token_counts))
      |> assign(:cached_label, cached_label(assigns.request_log, cached))

    ~H"""
    <div data-role="token-lines" class="request-log-lines grid min-w-0 gap-1">
      <%= if usage_line_applicable?(@request_log) do %>
        <span
          data-role="usage-token-line"
          class="flex min-w-0 items-center gap-2 whitespace-nowrap tabular-nums text-base-content max-lg:justify-end"
          title={token_totals_title(@request_log)}
        >
          <span :if={@composition} data-role="token-bar" role="img" aria-label={@composition.title} title={@composition.title} class="hidden h-2 min-w-6 flex-1 overflow-hidden rounded-xs lg:flex">
            <span :for={segment <- @composition.segments} data-role={segment_role(segment.key)} data-token-count={segment.count} aria-hidden="true" class={["h-full min-w-0 basis-0", segment_color(segment.key)]} style={"flex-grow: #{segment.count}"}></span>
          </span>
          <span :if={!@composition} data-role="token-breakdown-unavailable" class="hidden min-w-0 flex-1 text-[11px] text-base-content/45 lg:block" title="Token breakdown is incomplete or inconsistent; recorded totals are shown unchanged">
            breakdown n/a
          </span>
          <span
            data-role="token-totals"
            class="min-w-0 truncate lg:w-10 lg:shrink-0"
          >{@token_amount}<span :if={@token_suffix} class="text-base-content/60">{@token_suffix}</span></span>
        </span>
        <span
          id={"#{@prefix}-#{@request_log.id}-cached-tokens"}
          data-role="cached-tokens"
          class="flex min-w-0 flex-wrap items-center gap-x-1 text-[11px] tabular-nums text-base-content/55 max-lg:justify-end"
          title={usage_cached_line_title(@request_log)}
        >
          <span class="whitespace-nowrap">{@cached_label}</span>
          <span :if={@cache_rate} data-role="cache-rate" class="whitespace-nowrap max-lg:w-full max-lg:text-right" title="Cached input tokens divided by all input tokens">
            <span aria-hidden="true" class="hidden lg:inline">· </span>{@cache_rate} of input
          </span>
        </span>
      <% else %>
        <span
          data-role="usage-placeholder"
          class="items-center whitespace-nowrap text-base-content/45 max-lg:hidden lg:flex"
        >
          —
        </span>
      <% end %>
    </div>
    """
  end

  def token_composition_legend(assigns) do
    ~H"""
    <div id="request-log-token-legend" class="hidden flex-wrap items-center justify-end gap-x-4 gap-y-1 border-b border-base-300 bg-base-200/30 px-3 py-2 text-[11px] text-base-content/65 lg:flex">
      <span>Each bar = 100% of request tokens</span>
      <span :for={{key, label} <- [cached_input: "Cached input", uncached_input: "Uncached input", output: "Output"]} class="inline-flex items-center gap-1.5">
        <span aria-hidden="true" class={["size-2 rounded-xs", segment_color(key)]}></span>{label}
      </span>
    </div>
    """
  end

  defp segment_role(:cached_input), do: "cached-token-bar"
  defp segment_role(:uncached_input), do: "uncached-token-bar"
  defp segment_role(:output), do: "output-token-bar"

  defp segment_color(:cached_input), do: "bg-info"
  defp segment_color(:uncached_input), do: "bg-info/25"
  defp segment_color(:output), do: "bg-success"

  defp cached_input_tokens(%{token_counts: %{cached_input_tokens: cached}}), do: cached
  defp cached_input_tokens(_log), do: nil

  defp cached_label(_log, 0), do: "0 cached"
  defp cached_label(log, cached) when is_integer(cached) and cached > 0, do: format_cached_token_breakdown(log)
  defp cached_label(_log, _cached), do: "cache n/a"

  attr :request_log, :map, required: true
  attr :prefix, :string, required: true

  def request_log_cost_lines(assigns) do
    {symbol, amount} = cost_parts(format_usage_cost(assigns.request_log.cost))
    assigns = assigns |> assign(:cost_symbol, symbol) |> assign(:cost_amount, amount)

    ~H"""
    <div data-role="cost-lines" class="request-log-lines grid min-w-0 justify-end gap-1">
      <%= if usage_line_applicable?(@request_log) do %>
        <span
          data-role="usage-cost-line"
          class="flex min-w-0 items-center justify-end whitespace-nowrap tabular-nums text-base-content"
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
          class="flex min-w-0 items-center justify-end gap-1 whitespace-nowrap text-[11px] tabular-nums text-base-content/55"
          title={compression_savings_title(@request_log)}
        >
          <.icon name="hero-arrows-pointing-in" class="size-3 shrink-0" />
          <span class="sr-only">compression</span>
          <span class="truncate">{compression_line}</span>
        </span>
      <% else %>
        <span
          data-role="cost-placeholder"
          class="items-center justify-end whitespace-nowrap text-base-content/45 max-lg:hidden lg:flex"
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
