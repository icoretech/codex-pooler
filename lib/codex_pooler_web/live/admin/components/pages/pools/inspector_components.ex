defmodule CodexPoolerWeb.Admin.PoolInspectorComponents do
  @moduledoc """
  Pool inspector and usage chart components for the admin Pools surface.
  """

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.DateTimeDisplay

  attr :pool_row, :map, required: true
  attr :selected_tab, :string, required: true
  attr :datetime_preferences, :map, required: true

  def pool_inspector(assigns) do
    ~H"""
    <AdminComponents.object_inspector
      id="pool-inspector"
      title={@pool_row.pool.name}
      subtitle={@pool_row.pool.slug}
      status={@pool_row.pool.status}
      status_class={AdminBadges.lifecycle_chip_class(@pool_row.pool.status)}
      class="flex min-h-full w-full max-w-md flex-col border-l border-base-300 bg-base-100 shadow-2xl"
      close_event="close_pool_inspector"
      close_label="Close Pool details"
      role="dialog"
      aria_modal
    >
      <:tabs>
        <button
          id="pool-inspector-tab-overview"
          type="button"
          class={pool_inspector_tab_class(@selected_tab, "overview")}
          aria-selected={selected_tab_attr(@selected_tab, "overview")}
          phx-click="select_pool_tab"
          phx-value-tab="overview"
        >
          Overview
        </button>
        <button
          id="pool-inspector-tab-upstreams"
          type="button"
          class={pool_inspector_tab_class(@selected_tab, "upstreams")}
          aria-selected={selected_tab_attr(@selected_tab, "upstreams")}
          phx-click="select_pool_tab"
          phx-value-tab="upstreams"
        >
          Upstreams
        </button>
        <button
          id="pool-inspector-tab-api-keys"
          type="button"
          class={pool_inspector_tab_class(@selected_tab, "api_keys")}
          aria-selected={selected_tab_attr(@selected_tab, "api_keys")}
          phx-click="select_pool_tab"
          phx-value-tab="api_keys"
        >
          API keys
        </button>
      </:tabs>

      <section :if={@selected_tab == "overview"} id="pool-inspector-details" class="grid gap-3">
        <h3 class="text-sm font-semibold text-base-content">Details</h3>
        <dl class="grid gap-3 text-sm">
          <div class="flex items-center justify-between gap-3">
            <dt class="text-base-content/55">Status</dt>
            <dd class={AdminBadges.lifecycle_chip_class(@pool_row.pool.status)}>
              {@pool_row.pool.status}
            </dd>
          </div>
          <div class="flex items-center justify-between gap-3">
            <dt class="text-base-content/55">Created</dt>
            <dd class="text-right text-xs text-base-content/70">
              {format_datetime(@pool_row.pool.created_at, @datetime_preferences)}
            </dd>
          </div>
          <div class="flex items-center justify-between gap-3">
            <dt class="text-base-content/55">Routing strategy</dt>
            <dd class={routing_strategy_class()}>
              {AdminBadges.routing_strategy_label(@pool_row.routing_strategy)}
            </dd>
          </div>
          <div class="flex items-start justify-between gap-3">
            <dt class="text-base-content/55">ID</dt>
            <dd class="max-w-48 break-all text-right font-mono text-xs text-base-content/70">
              {@pool_row.pool.id}
            </dd>
          </div>
        </dl>
      </section>

      <section
        :if={@selected_tab == "overview"}
        id="pool-inspector-usage"
        class="grid gap-3 rounded-box border border-base-300 p-3"
      >
        <h3 class="text-sm font-semibold text-base-content">Usage</h3>
        <div class="grid gap-3 text-xs">
          <div class="grid gap-1.5">
            <div class="flex items-center justify-between">
              <span class="text-base-content/60">Upstream accounts</span>
              <span class="font-mono tabular-nums">{@pool_row.upstream_count}</span>
            </div>
            <progress
              class="progress progress-success h-1.5"
              value={@pool_row.upstream_count}
              max="10"
            >
            </progress>
          </div>
          <div class="grid gap-1.5">
            <div class="flex items-center justify-between">
              <span class="text-base-content/60">API keys</span>
              <span class="font-mono tabular-nums">{@pool_row.api_key_count}</span>
            </div>
            <progress class="progress progress-primary h-1.5" value={@pool_row.api_key_count} max="10">
            </progress>
          </div>
        </div>
      </section>

      <section :if={@selected_tab == "upstreams"} id="pool-inspector-upstreams" class="grid gap-3">
        <h3 class="text-sm font-semibold text-base-content">Upstream accounts</h3>
        <p class="text-sm leading-6 text-base-content/70">
          This Pool has {@pool_row.upstream_count} active upstream account assignments.
        </p>
        <.pool_link
          id={"pool-inspector-upstreams-link-#{@pool_row.pool.id}"}
          href={~p"/admin/upstreams?pool_id=#{@pool_row.pool.id}"}
          label="Open upstreams"
        />
      </section>

      <section :if={@selected_tab == "api_keys"} id="pool-inspector-api-keys" class="grid gap-3">
        <h3 class="text-sm font-semibold text-base-content">API keys</h3>
        <p class="text-sm leading-6 text-base-content/70">
          This Pool has {@pool_row.api_key_count} API keys attached.
        </p>
        <.pool_link
          id={"pool-inspector-api-keys-link-#{@pool_row.pool.id}"}
          href={~p"/admin/api-keys?pool_id=#{@pool_row.pool.id}"}
          label="Open API keys"
        />
      </section>

      <:quick_links>
        <div id="pool-inspector-links" class="grid gap-1">
          <h3 class="mb-2 text-sm font-semibold text-base-content">Quick links</h3>
          <.pool_link
            id={"pool-api-keys-link-#{@pool_row.pool.id}"}
            href={~p"/admin/api-keys?pool_id=#{@pool_row.pool.id}"}
            label="API keys"
          />
          <.pool_link
            id={"pool-upstreams-link-#{@pool_row.pool.id}"}
            href={~p"/admin/upstreams?pool_id=#{@pool_row.pool.id}"}
            label="Upstreams"
          />
          <.pool_link
            id={"pool-request-logs-link-#{@pool_row.pool.id}"}
            href={~p"/admin/request-logs?pool_id=#{@pool_row.pool.id}"}
            label="Request logs"
          />
          <.pool_link
            id={"pool-audit-logs-link-#{@pool_row.pool.id}"}
            href={~p"/admin/audit-logs?pool_id=#{@pool_row.pool.id}"}
            label="Audit logs"
          />
        </div>
      </:quick_links>
    </AdminComponents.object_inspector>
    """
  end

  attr :pool_row, :map, required: true

  def pool_token_usage_panel(assigns) do
    assigns = assign(assigns, :token_usage_cards, pool_token_usage_cards(assigns.pool_row))

    ~H"""
    <div
      id={"pool-row-#{@pool_row.pool.id}-quota-charts"}
      data-role="pool-token-usage-panel"
      class="grid min-h-32 min-w-0 gap-2 rounded-box border border-base-300 bg-base-100 p-3 shadow-sm"
    >
      <div class="grid min-w-0 gap-3 sm:grid-cols-2">
        <div
          :for={card <- @token_usage_cards}
          data-role="pool-token-usage-card"
          class="grid min-w-0 grid-cols-[auto_minmax(0,1fr)] items-center gap-3"
        >
          <div
            data-role="pool-token-donut"
            class="grid size-20 shrink-0 place-items-center rounded-full"
            style={"background: #{card.gradient}"}
            role="img"
            aria-label={card.aria_label}
          >
            <div class="grid size-14 place-items-center rounded-full bg-base-100 text-center shadow-inner">
              <span class="text-[0.55rem] font-semibold uppercase tracking-wide text-base-content/45">
                Tokens
              </span>
              <span class="font-mono text-xs font-bold leading-none text-base-content">
                {card.total_label}
              </span>
            </div>
          </div>

          <div class="grid min-w-0 gap-2">
            <div class="grid min-w-0 gap-0.5">
              <h3 class="truncate text-sm font-semibold text-base-content">{card.title}</h3>
              <p class="font-mono text-xs text-base-content/55">{card.total_full_label}</p>
            </div>

            <div class="grid gap-1">
              <div
                :for={segment <- card.segments}
                class="flex min-w-0 items-center justify-between gap-2 text-[0.68rem] text-base-content/60"
              >
                <span class="flex min-w-0 items-center gap-1.5">
                  <span class={["size-2 shrink-0 rounded-full", segment.dot_class]}></span>
                  <span class="truncate">{segment.label}</span>
                </span>
                <span class="font-mono font-semibold tabular-nums text-base-content/80">
                  {segment.value_label}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :href, :string, required: true
  attr :label, :string, required: true

  defp pool_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@href}
      class="flex items-center justify-between gap-3 rounded-box border border-base-300 px-3 py-2 text-sm text-base-content/70 transition-colors hover:border-primary hover:bg-primary/10 hover:text-base-content"
    >
      <span>{@label}</span>
      <.icon name="hero-chevron-right" class="size-4 text-base-content/40" />
    </.link>
    """
  end

  defp pool_inspector_tab_class(selected_tab, tab) do
    [
      "border-b-2 px-3 py-3 text-xs font-semibold transition-colors",
      selected_tab == tab && "border-primary text-base-content",
      selected_tab != tab && "border-transparent text-base-content/55 hover:text-base-content"
    ]
  end

  defp selected_tab_attr(selected_tab, tab) when selected_tab == tab, do: "true"
  defp selected_tab_attr(_selected_tab, _tab), do: "false"

  defp routing_strategy_class do
    "#{AdminBadges.metadata_chip_class(:neutral)} whitespace-nowrap"
  end

  defp format_datetime(nil, _datetime_preferences), do: "not recorded"

  defp format_datetime(%DateTime{} = datetime, datetime_preferences) do
    DateTimeDisplay.format_datetime(datetime, datetime_preferences, missing_label: "not recorded")
  end

  defp numeric_metric_integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer() |> max(0)

  defp numeric_metric_integer(value) when is_integer(value), do: max(value, 0)
  defp numeric_metric_integer(value) when is_float(value), do: max(round(value), 0)
  defp numeric_metric_integer(_value), do: 0

  defp empty_token_usage do
    %{
      cached_input_tokens: 0,
      input_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 0
    }
  end

  defp normalize_token_usage(usage) when is_map(usage) do
    total_tokens = numeric_metric_integer(Map.get(usage, :total_tokens))
    input_tokens = numeric_metric_integer(Map.get(usage, :input_tokens))
    cached_input_tokens = numeric_metric_integer(Map.get(usage, :cached_input_tokens))
    output_tokens = numeric_metric_integer(Map.get(usage, :output_tokens))
    reasoning_tokens = numeric_metric_integer(Map.get(usage, :reasoning_tokens))

    %{
      cached_input_tokens: cached_input_tokens,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      reasoning_tokens: reasoning_tokens,
      total_tokens: max(total_tokens, input_tokens + output_tokens + reasoning_tokens)
    }
  end

  defp pool_token_usage_cards(pool_row) do
    [
      token_usage_card("5h tokens", Map.get(pool_row, :token_usage_5h, empty_token_usage())),
      token_usage_card("7d tokens", Map.get(pool_row, :token_usage_weekly, empty_token_usage()))
    ]
  end

  defp token_usage_card(title, usage) do
    usage = normalize_token_usage(usage || empty_token_usage())
    total_tokens = usage.total_tokens
    uncached_input_tokens = max(usage.input_tokens - usage.cached_input_tokens, 0)

    segments = [
      token_usage_segment("Cached", usage.cached_input_tokens, total_tokens, "bg-info"),
      token_usage_segment("Input", uncached_input_tokens, total_tokens, "bg-success"),
      token_usage_segment("Output", usage.output_tokens, total_tokens, "bg-primary"),
      token_usage_segment(
        "Other",
        max(
          total_tokens - usage.cached_input_tokens - uncached_input_tokens - usage.output_tokens,
          0
        ),
        total_tokens,
        "bg-warning"
      )
    ]

    %{
      title: title,
      total_label: format_compact_number(total_tokens),
      total_full_label: "#{format_grouped_integer(total_tokens)} total",
      gradient: token_usage_gradient(segments),
      segments: segments,
      aria_label: "#{title}: #{format_metric_integer(total_tokens)} total tokens"
    }
  end

  defp token_usage_segment(label, value, total, dot_class) do
    %{
      label: label,
      value: value,
      value_label: format_compact_number(value),
      percent: if(total > 0, do: value / total * 100, else: 0),
      dot_class: dot_class
    }
  end

  defp token_usage_gradient(segments) do
    {stops, cursor} =
      Enum.reduce(segments, {[], 0.0}, fn segment, {stops, cursor} ->
        next_cursor = min(cursor + segment.percent, 100.0)
        color = token_usage_segment_color(segment.dot_class)

        {
          stops ++ ["#{color} #{Float.round(cursor, 2)}% #{Float.round(next_cursor, 2)}%"],
          next_cursor
        }
      end)

    stops =
      if cursor < 100.0,
        do: stops ++ ["hsl(var(--b3)) #{Float.round(cursor, 2)}% 100%"],
        else: stops

    "conic-gradient(#{Enum.join(stops, ", ")})"
  end

  defp token_usage_segment_color("bg-info"), do: "hsl(var(--in))"
  defp token_usage_segment_color("bg-success"), do: "hsl(var(--su))"
  defp token_usage_segment_color("bg-primary"), do: "hsl(var(--p))"
  defp token_usage_segment_color("bg-warning"), do: "hsl(var(--wa))"
  defp token_usage_segment_color(_dot_class), do: "hsl(var(--b3))"

  defp format_metric_integer(value) when is_integer(value), do: Integer.to_string(value)

  defp format_grouped_integer(value) when is_integer(value) do
    value
    |> max(0)
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp format_compact_number(value) when is_integer(value) do
    cond do
      value >= 1_000_000_000 -> "#{compact_decimal(value / 1_000_000_000)}B"
      value >= 1_000_000 -> "#{compact_decimal(value / 1_000_000)}M"
      value >= 1_000 -> "#{compact_decimal(value / 1_000)}K"
      true -> Integer.to_string(value)
    end
  end

  defp compact_decimal(value) do
    rounded = Float.round(value, 1)

    if rounded == Float.round(rounded, 0) do
      Integer.to_string(round(rounded))
    else
      :erlang.float_to_binary(rounded, decimals: 1)
    end
  end
end
