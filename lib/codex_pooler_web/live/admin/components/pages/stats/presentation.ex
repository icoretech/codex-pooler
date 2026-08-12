defmodule CodexPoolerWeb.Admin.StatsPresentation do
  @moduledoc """
  Presentation components and chart models for the admin stats dashboard.
  """

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.Format
  alias CodexPoolerWeb.Admin.UpstreamNaming

  @leaderboard_limit 10

  attr :id, :string, required: true
  attr :dashboard, :map, required: true

  def kpi_strip(assigns) do
    ~H"""
    <AdminComponents.metric_strip
      id={@id}
      class="grid min-w-0 grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-4 min-[1900px]:grid-cols-8 max-sm:[&_[data-role=metric-card-value]]:text-xs max-sm:[&_[data-role=metric-card-value]]:whitespace-nowrap"
    >
      <AdminComponents.metric_card
        id="stats-kpi-requests"
        icon="hero-arrow-path-rounded-square"
        label="Requests"
        value={format_integer(@dashboard.kpis.requests.value)}
        description={request_summary(@dashboard.kpis.requests)}
        tone={request_tone(@dashboard.kpis.requests)}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-success-rate"
        icon="hero-check-circle"
        label="Success rate"
        value={format_percent(@dashboard.kpis.success_rate.value)}
        description="Completed"
        tone={success_rate_tone(@dashboard.kpis.success_rate.value)}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-tokens"
        icon="hero-cpu-chip"
        label="Tokens"
        value={Format.token_count(@dashboard.kpis.tokens.total_tokens)}
        description="Input and output combined"
        tone={:primary}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-tokens-per-sec"
        icon="hero-bolt"
        label="Throughput"
        value={format_float(@dashboard.kpis.tokens_per_second.value)}
        description="Tokens per second"
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-cost"
        icon="hero-currency-dollar"
        label="Cost"
        value={format_cost(@dashboard.kpis.settled_cost)}
        description={cost_status_label(@dashboard.kpis.settled_cost.status)}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-avg-latency"
        icon="hero-clock"
        label="Latency"
        value={format_latency(@dashboard.kpis.average_latency_ms.value)}
        description="Mean response time"
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-active-sessions"
        icon="hero-computer-desktop"
        label="Active sessions"
        value={format_integer(@dashboard.kpis.active_sessions.value)}
        description={turn_summary(@dashboard.kpis.turns)}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-cache-rate"
        icon="hero-circle-stack"
        label="Cache rate"
        value={format_percent(@dashboard.kpis.cache_rate.value)}
        description={cache_rate_summary(@dashboard.kpis.cache_rate)}
        compact_mobile
      />
    </AdminComponents.metric_strip>
    """
  end

  attr :rows, :list, required: true
  attr :sort, :atom, default: :tokens, values: [:tokens, :cost]
  attr :window_label, :string, default: nil

  def top_api_keys_table(assigns) do
    ranked = leaderboard_ranking(assigns.rows, assigns.sort)

    assigns =
      assigns
      |> assign(:podium, Enum.take(ranked, 3))
      |> assign(:runners, Enum.drop(ranked, 3))

    ~H"""
    <AdminComponents.admin_surface
      id="stats-api-key-surface"
      title="Leaderboard"
      description={leaderboard_description(@sort, @window_label)}
    >
      <:header_actions>
        <div
          class="flex shrink-0 items-center gap-0.5 rounded-full border border-base-300 bg-base-200/60 p-0.5"
          role="group"
          aria-label="Leaderboard ranking"
        >
          <button
            :for={{label, sort} <- [{"Tokens", :tokens}, {"Cost", :cost}]}
            id={"stats-api-key-sort-#{sort}"}
            type="button"
            class={leaderboard_sort_button_class(@sort == sort)}
            aria-pressed={to_string(@sort == sort)}
            phx-click="set_leaderboard_sort"
            phx-value-sort={Atom.to_string(sort)}
          >
            {label}
          </button>
        </div>
      </:header_actions>
      <p
        :if={@rows == []}
        id="stats-api-key-empty-card"
        class="px-4 py-10 text-center text-sm text-base-content/60"
      >
        No settled API-key usage for this period.
      </p>

      <ol
        :if={@podium != []}
        id="stats-api-key-podium"
        class="grid list-none gap-2 p-3 sm:grid-cols-3 sm:items-end sm:gap-3 sm:p-4"
      >
        <li
          :for={{row, index} <- Enum.with_index(@podium)}
          id={"stats-api-key-podium-#{index + 1}"}
          data-role="leaderboard-podium-place"
          class={podium_place_class(index + 1)}
        >
          <div class="grid min-w-0 gap-2 p-3">
            <div class="flex justify-center">
              <span class={podium_medallion_class(index + 1)} aria-label={"Rank #{index + 1}"}>
                <.icon :if={index == 0} name="hero-trophy" class="size-4" />
                <span :if={index > 0} class="text-sm font-bold">{index + 1}</span>
              </span>
            </div>
            <div class="min-w-0">
              <p class="truncate text-sm font-semibold text-base-content" title={row.display_name}>
                {row.display_name || "API key not recorded"}
              </p>
              <p class="truncate text-xs text-base-content/55">
                {row.pool_name || "Pool not available"}
              </p>
            </div>
            <p class="text-lg font-bold tabular-nums leading-tight text-base-content">
              <%= if @sort == :cost do %>
                {format_micros(row.settled_cost_micros)}
              <% else %>
                {Format.token_count(row.total_tokens)}
                <span class="text-xs font-medium text-base-content/50">tokens</span>
              <% end %>
            </p>
            <p class="text-[11px] leading-4 text-base-content/55">
              <%= if @sort == :cost do %>
                {format_integer(row.requests)} req · {Format.token_count(row.total_tokens)} tokens
              <% else %>
                {format_integer(row.requests)} req · {format_micros(row.settled_cost_micros)}
              <% end %>
            </p>
          </div>
          <div class={podium_step_class(index + 1)} aria-hidden="true">
            <span class="text-2xl font-extrabold opacity-25">{index + 1}</span>
          </div>
          <div class="h-1.5 rounded-b-sm bg-base-300" aria-hidden="true"></div>
        </li>
      </ol>

      <ol
        :if={@runners != []}
        id="stats-api-key-runners"
        class="list-none divide-y divide-base-300/70 border-t border-base-300/70"
      >
        <li
          :for={{row, index} <- Enum.with_index(@runners)}
          id={"stats-api-key-row-#{index + 3}"}
          data-role="leaderboard-runner-row"
          class="flex min-w-0 items-center gap-3 px-4 py-2.5"
        >
          <span class="grid size-6 shrink-0 place-items-center rounded-full bg-base-200 font-mono text-xs font-semibold tabular-nums text-base-content/60">
            {index + 4}
          </span>
          <div class="grid min-w-0 flex-1">
            <p class="truncate text-sm font-medium text-base-content">
              {row.display_name || "API key not recorded"}
            </p>
            <p class="truncate text-xs text-base-content/50">
              {row.pool_name || "Pool not available"}
            </p>
          </div>
          <div class="grid shrink-0 justify-items-end gap-0.5 text-right">
            <span class="font-mono text-sm font-semibold tabular-nums text-base-content">
              <%= if @sort == :cost do %>
                {format_micros(row.settled_cost_micros)}
              <% else %>
                {Format.token_count(row.total_tokens)}
                <span class="text-[11px] font-medium text-base-content/50">tokens</span>
              <% end %>
            </span>
            <span class="text-[11px] leading-4 tabular-nums text-base-content/50">
              <%= if @sort == :cost do %>
                {format_integer(row.requests)} req · {Format.token_count(row.total_tokens)} tokens
              <% else %>
                {format_integer(row.requests)} req · {format_micros(row.settled_cost_micros)}
              <% end %>
            </span>
          </div>
        </li>
      </ol>
    </AdminComponents.admin_surface>
    """
  end

  defp leaderboard_ranking(rows, :cost) do
    rows
    |> Enum.sort_by(&{&1.settled_cost_micros, &1.total_tokens}, :desc)
    |> Enum.take(@leaderboard_limit)
  end

  defp leaderboard_ranking(rows, _sort) do
    rows
    |> Enum.sort_by(&{&1.total_tokens, &1.requests}, :desc)
    |> Enum.take(@leaderboard_limit)
  end

  defp leaderboard_description(sort, window_label) do
    "#{leaderboard_ranking_label(sort)} in the #{leaderboard_window_label(window_label)}"
  end

  defp leaderboard_ranking_label(:cost), do: "Top API keys by settled cost"
  defp leaderboard_ranking_label(_sort), do: "Top API keys by token usage"

  defp leaderboard_window_label(label) when is_binary(label) and label != "",
    do: String.downcase(label)

  defp leaderboard_window_label(_label), do: "selected window"

  # Segmented pill: the active option reads as a raised thumb, the inactive
  # ones stay muted text. Both carry a border so the thumb never shifts layout.
  defp leaderboard_sort_button_class(active?) do
    [
      "cursor-pointer rounded-full border px-2.5 py-0.5 text-[11px] font-medium leading-4 transition-colors",
      "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
      if(active?,
        do: "border-base-300 bg-base-100 text-base-content",
        else: "border-transparent text-base-content/45 hover:text-base-content/75"
      )
    ]
  end

  @podium_place_base "grid min-w-0 text-center"

  defp podium_place_class(1), do: [@podium_place_base, "sm:order-2"]
  defp podium_place_class(2), do: [@podium_place_base, "sm:order-1"]
  defp podium_place_class(3), do: [@podium_place_base, "sm:order-3"]

  @podium_step_base "grid place-items-center rounded-t-lg border border-b-0"

  defp podium_step_class(1),
    do: [
      @podium_step_base,
      "h-21 border-(--codex-rank-gold)/45 bg-(--codex-rank-gold)/10 text-(--codex-rank-gold-ink)"
    ]

  defp podium_step_class(2),
    do: [@podium_step_base, "h-14 border-base-300 bg-base-content/4 text-base-content"]

  defp podium_step_class(3),
    do: [
      @podium_step_base,
      "h-9 border-(--codex-rank-bronze)/45 bg-(--codex-rank-bronze)/8 text-(--codex-rank-bronze-ink)"
    ]

  @podium_medallion_base "grid size-9 shrink-0 place-items-center rounded-full border"

  defp podium_medallion_class(1),
    do: [
      @podium_medallion_base,
      "border-(--codex-rank-gold)/60 bg-(--codex-rank-gold)/20 text-(--codex-rank-gold-ink)"
    ]

  defp podium_medallion_class(2),
    do: [@podium_medallion_base, "border-base-300 bg-base-200 text-base-content/60"]

  defp podium_medallion_class(3),
    do: [
      @podium_medallion_base,
      "border-(--codex-rank-bronze)/50 bg-(--codex-rank-bronze)/16 text-(--codex-rank-bronze-ink)"
    ]

  attr :rows, :list, required: true
  attr :scope_label, :string, required: true
  attr :window_label, :string, required: true

  def upstream_traffic_distribution(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="stats-upstream-surface"
      title="Traffic distribution"
      description={traffic_distribution_description(@scope_label, @window_label)}
    >
      <ol
        :if={@rows != []}
        id="stats-upstream-lanes"
        class="list-none divide-y divide-base-300/70"
      >
        <li
          :for={{row, rank} <- Enum.with_index(@rows, 1)}
          id={"stats-upstream-lane-#{rank}"}
          data-role="upstream-traffic-lane"
          data-leader={(rank == 1 and row.requests > 0) && "true"}
          class={[
            "grid min-w-0 gap-3 px-4 py-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center",
            (rank == 1 and row.requests > 0) && "bg-primary/5"
          ]}
        >
          <div class="grid min-w-0 gap-2">
            <div class="flex min-w-0 items-baseline justify-between gap-3">
              <h3
                class="min-w-0 truncate text-sm font-semibold text-base-content"
                title={upstream_label(row)}
              >
                {upstream_label(row)}
              </h3>
              <span
                data-role="upstream-traffic-share"
                class={[
                  "shrink-0 text-xs font-semibold tabular-nums text-base-content/70",
                  (rank == 1 and row.requests > 0) && "text-primary"
                ]}
              >
                {format_traffic_share(row.traffic_share_percent)}
              </span>
            </div>
            <progress
              id={"stats-upstream-rail-#{rank}"}
              data-role="upstream-traffic-rail"
              class={[
                "progress h-1.5 w-full",
                (rank == 1 and row.requests > 0) && "progress-primary"
              ]}
              max="100"
              value={format_traffic_share_value(row.traffic_share_percent)}
              aria-label={"#{upstream_label(row)} traffic share"}
              aria-valuetext={"#{format_traffic_share(row.traffic_share_percent)} of accounted requests"}
            >
              {format_traffic_share(row.traffic_share_percent)}
            </progress>
          </div>

          <dl class="grid grid-cols-3 gap-3 text-right text-xs sm:min-w-64">
            <div class="min-w-0">
              <dt class="text-base-content/50">Requests</dt>
              <dd
                data-role="upstream-requests"
                class="truncate font-semibold tabular-nums text-base-content"
              >
                {format_integer(row.requests)}
              </dd>
            </div>
            <div class="min-w-0">
              <dt class="text-base-content/50">Tokens</dt>
              <dd
                data-role="upstream-tokens"
                class="truncate font-semibold tabular-nums text-base-content"
              >
                {Format.token_count(row.total_tokens)}
              </dd>
            </div>
            <div class="min-w-0">
              <dt class="truncate text-base-content/50">Settled cost</dt>
              <dd
                data-role="upstream-settled-cost"
                class="truncate font-semibold tabular-nums text-base-content"
              >
                {format_micros(row.settled_cost_micros)}
              </dd>
            </div>
          </dl>
        </li>
      </ol>

      <div :if={@rows == []} class="p-4">
        <AdminComponents.empty_state
          id="stats-upstream-empty-state"
          title="No upstream identities"
          description="No upstream identities are visible in this scope."
          icon="hero-server-stack"
        />
      </div>
    </AdminComponents.admin_surface>
    """
  end

  defp request_summary(%{succeeded: succeeded, failed: failed}),
    do: "#{format_integer(succeeded)} succeeded · #{format_integer(failed)} failed"

  defp cache_rate_summary(%{input_tokens: 0}), do: "No input tokens"
  defp cache_rate_summary(%{cached_input_tokens: 0}), do: "No cached input"

  defp cache_rate_summary(cache_rate) do
    "#{Format.token_count(cache_rate.cached_input_tokens)} of #{Format.token_count(cache_rate.input_tokens)} input cached"
  end

  defp turn_summary(turns),
    do: "#{format_integer(turns.value)} turns · #{format_integer(turns.in_progress)} in progress"

  defp request_tone(%{failed: failed}) when failed > 0, do: :warning
  defp request_tone(_requests), do: :neutral

  defp success_rate_tone(nil), do: :neutral
  defp success_rate_tone(value) when value >= 95.0, do: :success
  defp success_rate_tone(value) when value >= 50.0, do: :warning
  defp success_rate_tone(_value), do: :error

  defp traffic_distribution_description(scope_label, window_label) do
    "Share of accounted requests across #{scope_label} in the #{String.downcase(window_label)}."
  end

  # `row.upstream_label` is already `identity.account_label`, selected by the
  # quota projection's existing join, so naming the lane costs no extra query.
  defp upstream_label(row), do: UpstreamNaming.account_name(%{account_label: row.upstream_label})

  defp format_traffic_share(value), do: "#{format_traffic_share_value(value)}%"

  defp format_traffic_share_value(value) when is_number(value),
    do: :erlang.float_to_binary(value / 1, decimals: 1)

  defp format_cost(%{usd: %Decimal{} = usd}), do: Format.money_precise(usd)
  defp format_cost(%{status: "unpriced"}), do: "unpriced"
  defp format_cost(%{status: "unavailable"}), do: "unavailable"
  defp format_cost(%{status: status}), do: status || "unavailable"

  defp cost_status_label("settled"), do: "Settled usage cost"
  defp cost_status_label("unpriced"), do: "No settled cost"
  defp cost_status_label("unavailable"), do: "No usage"
  defp cost_status_label(status), do: humanize(status)

  defp format_micros(nil), do: "unavailable"
  defp format_micros(micros) when is_integer(micros), do: Format.money_precise_from_micros(micros)

  defp format_percent(nil), do: "not available"
  defp format_percent(value), do: "#{format_float(value)}%"

  defp format_latency(nil), do: "not available"
  defp format_latency(value), do: "#{format_integer(value)} ms"

  defp format_float(nil), do: "not available"
  defp format_float(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_float(value) when is_integer(value), do: Integer.to_string(value)

  defp format_integer(nil), do: "0"
  defp format_integer(value) when is_integer(value), do: Integer.to_string(value)
  defp format_integer(value) when is_float(value), do: format_float(value)

  defp humanize(nil), do: nil

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace(["_", "."], " ")
    |> String.trim()
    |> String.capitalize()
  end
end
