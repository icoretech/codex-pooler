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
        label={gettext("Requests")}
        value={format_integer(@dashboard.kpis.requests.value)}
        description={request_summary(@dashboard.kpis.requests)}
        tone={request_tone(@dashboard.kpis.requests)}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-success-rate"
        icon="hero-check-circle"
        label={gettext("Success rate")}
        value={format_percent(@dashboard.kpis.success_rate.value)}
        description={success_rate_summary(@dashboard.kpis.success_rate)}
        tone={success_rate_tone(@dashboard.kpis.success_rate.value)}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-tokens"
        icon="hero-cpu-chip"
        label={gettext("Tokens")}
        value={Format.token_count(@dashboard.kpis.tokens.total_tokens)}
        description={gettext("Input and output combined")}
        tone={:primary}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-tokens-per-sec"
        icon="hero-bolt"
        label={gettext("Throughput")}
        value={format_float(@dashboard.kpis.tokens_per_second.value)}
        description={gettext("Tokens per second")}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-cost"
        icon="hero-currency-dollar"
        label={gettext("Cost")}
        value={format_cost(@dashboard.kpis.settled_cost)}
        description={cost_status_label(@dashboard.kpis.settled_cost.status)}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-avg-latency"
        icon="hero-clock"
        label={gettext("Latency")}
        value={format_latency(@dashboard.kpis.average_latency_ms.value)}
        description={gettext("Mean response time")}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-active-sessions"
        icon="hero-computer-desktop"
        label={gettext("Active sessions")}
        value={format_integer(@dashboard.kpis.active_sessions.value)}
        description={turn_summary(@dashboard.kpis.turns)}
        compact_mobile
      />
      <AdminComponents.metric_card
        id="stats-kpi-cache-rate"
        icon="hero-circle-stack"
        label={gettext("Cache rate")}
        value={format_percent(@dashboard.kpis.cache_rate.value)}
        description={cache_rate_summary(@dashboard.kpis.cache_rate)}
        compact_mobile
      />
    </AdminComponents.metric_strip>
    """
  end

  defp request_summary(%{succeeded: succeeded, failed: failed} = requests) do
    succeeded_label = ngettext("%{count} succeeded", "%{count} succeeded", succeeded)
    failed_label = ngettext("%{count} failed", "%{count} failed", failed)

    case Map.get(requests, :client_cancelled, 0) do
      count when is_integer(count) and count > 0 ->
        cancelled_label = ngettext("%{count} client cancelled", "%{count} client cancelled", count)
        gettext("%{succeeded} · %{failed} · %{client_cancelled}", succeeded: succeeded_label, failed: failed_label, client_cancelled: cancelled_label)

      _count ->
        gettext("%{succeeded} · %{failed}", succeeded: succeeded_label, failed: failed_label)
    end
  end

  defp success_rate_summary(%{client_cancelled: count}) when is_integer(count) and count > 0, do: gettext("Completed; excludes client cancellations")
  defp success_rate_summary(_success_rate), do: gettext("Completed")

  defp cache_rate_summary(%{input_tokens: 0}), do: gettext("No input tokens")
  defp cache_rate_summary(%{cached_input_tokens: 0}), do: gettext("No cached input")

  defp cache_rate_summary(cache_rate) do
    ngettext("%{cached} of %{input} input cached", "%{cached} of %{input} input cached", cache_rate.input_tokens,
      input: Format.token_count(cache_rate.input_tokens),
      cached: Format.token_count(cache_rate.cached_input_tokens)
    )
  end

  defp turn_summary(turns) do
    ngettext("%{count} turn · %{in_progress} in progress", "%{count} turns · %{in_progress} in progress", turns.value, in_progress: format_integer(turns.in_progress))
  end

  defp request_tone(%{failed: failed}) when failed > 0, do: :warning
  defp request_tone(_requests), do: :neutral

  defp success_rate_tone(nil), do: :neutral
  defp success_rate_tone(value) when value >= 95.0, do: :success
  defp success_rate_tone(value) when value >= 50.0, do: :warning
  defp success_rate_tone(_value), do: :error

  defp format_cost(%{usd: %Decimal{} = usd}), do: Format.money_precise(usd)
  defp format_cost(%{status: "unpriced"}), do: gettext("unpriced")
  defp format_cost(%{status: "unavailable"}), do: gettext("unavailable")
  defp format_cost(%{status: status}), do: status || gettext("unavailable")

  defp cost_status_label("settled"), do: gettext("Settled usage cost")
  defp cost_status_label("unpriced"), do: gettext("No settled cost")
  defp cost_status_label("unavailable"), do: gettext("No usage")
  defp cost_status_label(status), do: humanize(status)

  defp format_percent(nil), do: gettext("not available")
  defp format_percent(value), do: "#{format_float(value)}%"

  defp format_latency(nil), do: gettext("not available")
  defp format_latency(value), do: "#{format_integer(value)} ms"

  defp format_float(nil), do: gettext("not available")
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
