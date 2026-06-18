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

  def top_api_keys_table(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="stats-api-key-surface"
      title="Leaderboard"
    >
      <div class="divide-y divide-base-300 md:hidden">
        <p
          :if={@rows == []}
          id="stats-api-key-empty-card"
          class="px-3 py-4 text-center text-sm text-base-content/60"
        >
          No settled API-key usage for this period.
        </p>
        <article
          :for={{row, index} <- Enum.with_index(@rows)}
          id={"stats-api-key-card-#{index}"}
          class="grid gap-2 px-3 py-3"
        >
          <div class="flex min-w-0 items-start justify-between gap-3">
            <div class="grid min-w-0 gap-1">
              <h3 class="truncate text-sm font-semibold text-base-content">
                {row.display_name || "API key not recorded"}
              </h3>
              <p class="truncate text-xs text-base-content/60">
                {row.pool_name || "Pool not available"}
              </p>
            </div>
            <span class="shrink-0 text-sm font-semibold tabular-nums">
              {format_micros(row.settled_cost_micros)}
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
        <table id="stats-api-key-table" class="table table-zebra table-sm">
          <thead>
            <tr>
              <th>API key</th>
              <th>Pool</th>
              <th class="text-right">Requests</th>
              <th class="text-right">Tokens</th>
              <th class="text-right">Cost</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@rows == []} id="stats-api-key-empty-row">
              <td colspan="5" class="text-center text-sm text-base-content/60">
                No settled API-key usage for this period.
              </td>
            </tr>
            <tr :for={{row, index} <- Enum.with_index(@rows)} id={"stats-api-key-row-#{index}"}>
              <td class="min-w-44 font-semibold">
                {row.display_name || "API key not recorded"}
              </td>
              <td class="min-w-36 text-base-content/80">
                {row.pool_name || "Pool not available"}
              </td>
              <td class="text-right tabular-nums">
                {format_integer(row.requests)}
              </td>
              <td class="text-right tabular-nums">
                {Format.token_count(row.total_tokens)}
              </td>
              <td class="text-right tabular-nums">
                {format_micros(row.settled_cost_micros)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </AdminComponents.admin_surface>
    """
  end

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
