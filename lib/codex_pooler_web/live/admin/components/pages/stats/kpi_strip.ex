defmodule CodexPoolerWeb.Admin.StatsPresentation.KpiStrip do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.Format

  attr :id, :string, required: true
  attr :dashboard, :map, required: true

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
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

  defp format_cost(%{usd: %Decimal{} = usd}), do: Format.money_precise(usd)
  defp format_cost(%{status: "unpriced"}), do: "unpriced"
  defp format_cost(%{status: "unavailable"}), do: "unavailable"
  defp format_cost(%{status: status}), do: status || "unavailable"

  defp cost_status_label("settled"), do: "Settled usage cost"
  defp cost_status_label("unpriced"), do: "No settled cost"
  defp cost_status_label("unavailable"), do: "No usage"
  defp cost_status_label(status), do: humanize(status)

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
