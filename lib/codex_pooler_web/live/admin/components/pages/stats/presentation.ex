defmodule CodexPoolerWeb.Admin.StatsPresentation do
  @moduledoc """
  Presentation components and chart models for the admin stats dashboard.
  """

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.Format

  @default_quota_state_presentation %{tone: :neutral, label: nil}
  @quota_state_presentations %{
    available: %{tone: :success, label: "Available"},
    partial: %{tone: :warning, label: "Partial"},
    weekly_only_evidence: %{tone: :warning, label: "Weekly evidence only"},
    missing_evidence: %{tone: :error, label: "Missing evidence"},
    exhausted: %{tone: :error, label: "Exhausted"},
    unknown: %{tone: :neutral, label: "Unknown"},
    empty: %{tone: :neutral, label: "No upstream accounts"}
  }

  attr :id, :string, required: true
  attr :dashboard, :map, required: true

  def kpi_strip(assigns) do
    ~H"""
    <section
      id={@id}
      class="grid min-w-0 grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-4 min-[1900px]:grid-cols-8"
      aria-label="Page metrics"
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
        description={token_summary(@dashboard.kpis.tokens)}
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
        id="stats-kpi-quota-health"
        icon="hero-shield-check"
        label="Quota"
        value={quota_state_label(@dashboard.kpis.quota_health.state)}
        description={quota_summary(@dashboard.kpis.quota_health)}
        tone={quota_tone(@dashboard.kpis.quota_health.state)}
        compact_mobile
      />
    </section>
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
          class={podium_cell_class(index + 1)}
        >
          <div class="flex justify-center">
            <span class={podium_medallion_class(index + 1)} aria-label={"Rank #{index + 1}"}>
              <.icon :if={index == 0} name="hero-trophy" class="size-4" />
              <span :if={index > 0} class="font-mono text-sm font-bold">{index + 1}</span>
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
          <p class="font-mono text-lg font-semibold tabular-nums leading-tight text-base-content">
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
    |> Enum.take(5)
  end

  defp leaderboard_ranking(rows, _sort) do
    rows
    |> Enum.sort_by(&{&1.total_tokens, &1.requests}, :desc)
    |> Enum.take(5)
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

  @podium_cell_base "grid h-full min-w-0 content-start gap-2 rounded-box border p-3 text-center"

  defp podium_cell_class(1),
    do: [
      @podium_cell_base,
      "sm:order-2 sm:py-5",
      "border-[oklch(0.78_0.13_85_/_0.45)] bg-[oklch(0.78_0.13_85_/_0.07)]"
    ]

  defp podium_cell_class(2),
    do: [@podium_cell_base, "sm:order-1", "border-base-300 bg-base-200/30"]

  defp podium_cell_class(3),
    do: [@podium_cell_base, "sm:order-3", "border-base-300 bg-base-200/30"]

  @podium_medallion_base "grid size-9 shrink-0 place-items-center rounded-full border"

  defp podium_medallion_class(1),
    do: [
      @podium_medallion_base,
      "border-[oklch(0.78_0.13_85_/_0.6)] bg-[oklch(0.78_0.13_85_/_0.2)] text-[oklch(0.62_0.13_85)]"
    ]

  defp podium_medallion_class(2),
    do: [@podium_medallion_base, "border-base-300 bg-base-200 text-base-content/60"]

  defp podium_medallion_class(3),
    do: [
      @podium_medallion_base,
      "border-[oklch(0.62_0.11_55_/_0.5)] bg-[oklch(0.62_0.11_55_/_0.16)] text-[oklch(0.55_0.11_55)]"
    ]

  attr :rows, :list, required: true

  def upstreams_table(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="stats-upstream-surface"
      title="Upstream usage"
    >
      <div class="divide-y divide-base-300 md:hidden">
        <p
          :if={@rows == []}
          id="stats-upstream-empty-card"
          class="px-3 py-4 text-center text-sm text-base-content/60"
        >
          No upstream assignments in this scope.
        </p>
        <article
          :for={{row, index} <- Enum.with_index(@rows)}
          id={"stats-upstream-card-#{index}"}
          class="grid gap-2 px-3 py-3"
        >
          <div class="flex min-w-0 items-start justify-between gap-3">
            <h3 class="min-w-0 truncate text-sm font-semibold text-base-content">
              {row.assignment_label || row.upstream_label || "upstream account"}
            </h3>
            <span class={AdminBadges.status_chip_class(row.status)}>
              {row.status || "unknown"}
            </span>
          </div>
          <dl class="grid grid-cols-2 gap-2 text-xs">
            <div>
              <dt class="text-base-content/50">Requests</dt>
              <dd class="font-semibold tabular-nums">
                {format_integer(row.requests)}
              </dd>
            </div>
            <div>
              <dt class="text-base-content/50">Tokens</dt>
              <dd class="font-semibold tabular-nums">
                {Format.token_count(row.total_tokens)}
              </dd>
            </div>
          </dl>
        </article>
      </div>
      <div class="hidden overflow-x-auto md:block">
        <table id="stats-upstream-table" class="table table-zebra table-sm">
          <thead>
            <tr>
              <th>Upstream</th>
              <th class="text-center">Status</th>
              <th class="text-right">Requests</th>
              <th class="text-right">Tokens</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@rows == []} id="stats-upstream-empty-row">
              <td colspan="4" class="text-center text-sm text-base-content/60">
                No upstream assignments in this scope.
              </td>
            </tr>
            <tr :for={{row, index} <- Enum.with_index(@rows)} id={"stats-upstream-row-#{index}"}>
              <td class="min-w-56">
                <div class="grid gap-1">
                  <span class="font-semibold">
                    {row.assignment_label || row.upstream_label || "upstream account"}
                  </span>
                </div>
              </td>
              <td class="text-center">
                <span class={AdminBadges.status_chip_class(row.status)}>
                  {row.status || "unknown"}
                </span>
              </td>
              <td class="text-right tabular-nums">
                {format_integer(row.requests)}
              </td>
              <td class="text-right tabular-nums">
                {Format.token_count(row.total_tokens)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </AdminComponents.admin_surface>
    """
  end

  defp request_summary(%{succeeded: succeeded, failed: failed}),
    do: "#{format_integer(succeeded)} succeeded · #{format_integer(failed)} failed"

  defp token_summary(tokens),
    do:
      "#{Format.token_count(tokens.input_tokens)} input · #{Format.token_count(tokens.cached_input_tokens)} cached · #{Format.token_count(tokens.output_tokens)} output"

  defp turn_summary(turns),
    do: "#{format_integer(turns.value)} turns · #{format_integer(turns.in_progress)} in progress"

  defp quota_summary(%{total: 0}), do: "No upstream accounts"

  defp quota_summary(%{state: :weekly_only_evidence, weekly_only_evidence: count}),
    do: "#{format_integer(count)} account with weekly evidence only"

  defp quota_summary(quota),
    do:
      "#{format_integer(quota.available)} usable · #{format_integer(quota.missing_evidence)} missing quota"

  defp request_tone(%{failed: failed}) when failed > 0, do: :warning
  defp request_tone(_requests), do: :neutral

  defp success_rate_tone(nil), do: :neutral
  defp success_rate_tone(value) when value >= 95.0, do: :success
  defp success_rate_tone(value) when value >= 50.0, do: :warning
  defp success_rate_tone(_value), do: :error

  defp quota_tone(state), do: quota_state_presentation(state).tone

  defp quota_state_label(state) do
    case quota_state_presentation(state).label do
      nil -> humanize(state)
      label -> label
    end
  end

  defp quota_state_presentation(state),
    do: Map.get(@quota_state_presentations, state, @default_quota_state_presentation)

  defp format_cost(%{usd: %Decimal{} = usd}), do: Format.money(usd)
  defp format_cost(%{status: "unpriced"}), do: "unpriced"
  defp format_cost(%{status: "unavailable"}), do: "unavailable"
  defp format_cost(%{status: status}), do: status || "unavailable"

  defp cost_status_label("settled"), do: "Settled usage cost"
  defp cost_status_label("unpriced"), do: "No settled cost"
  defp cost_status_label("unavailable"), do: "No usage"
  defp cost_status_label(status), do: humanize(status)

  defp format_micros(nil), do: "unavailable"
  defp format_micros(micros) when is_integer(micros), do: Format.money_from_micros(micros)

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
