defmodule CodexPoolerWeb.Observatory.Components.Telemetry do
  use Phoenix.Component

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges

  attr :overview, :map, required: true
  attr :models, :list, required: true

  def telemetry(assigns) do
    ~H"""
    <section
      id="observatory-overview"
      class="observatory-card overflow-hidden"
      aria-labelledby="observatory-overview-title"
    >
      <h2 id="observatory-overview-title" class="sr-only">Usage overview</h2>

      <dl id="observatory-overview-facts" class="divide-y divide-base-300/70">
        <div id="observatory-fact-success" class="observatory-fact observatory-fact-lead">
          <dt class="observatory-fact-label">Success rate</dt>
          <dd class="observatory-fact-value-row">
            <span class="observatory-fact-value font-mono tabular-nums">
              {text(@overview, :success_rate, :label, "Unavailable")}
            </span>
            <span
              id="observatory-success-trend"
              data-role="observatory-trend"
              data-direction={trend_direction(@overview, :success_rate)}
              class={[
                "observatory-trend font-mono tabular-nums",
                trend_class(@overview, :success_rate)
              ]}
            >
              {trend_text(@overview, :success_rate)}
            </span>
          </dd>
          <dd class="observatory-fact-detail">
            {text(@overview, :success_rate, :detail, "No details available")}
          </dd>
          <dd
            id="observatory-success-minibar"
            class="observatory-minibar"
            role="progressbar"
            aria-label="Success rate"
            aria-valuemin="0"
            aria-valuemax="100"
            aria-valuenow={number_value(@overview, :success_rate, :minibar)}
          >
            <span
              class="block h-full bg-success"
              style={"width: #{percent(@overview, :success_rate, :minibar)}%"}
            ></span>
          </dd>
        </div>

        <div id="observatory-fact-cache" class="observatory-fact">
          <dt class="observatory-fact-label">Cache rate</dt>
          <dd class="observatory-fact-value-row">
            <span class="observatory-fact-value font-mono tabular-nums">
              {text(@overview, :cache_rate, :label, "Unavailable")}
            </span>
            <span
              id="observatory-cache-trend"
              data-role="observatory-trend"
              data-direction={trend_direction(@overview, :cache_rate)}
              class={["observatory-trend font-mono tabular-nums", trend_class(@overview, :cache_rate)]}
            >
              {trend_text(@overview, :cache_rate)}
            </span>
          </dd>
          <dd class="observatory-fact-detail">
            {text(@overview, :cache_rate, :detail, "No cache details available")}
          </dd>
        </div>

        <div id="observatory-fact-cost" class="observatory-fact">
          <dt class="observatory-fact-label">Cost</dt>
          <dd class="flex flex-wrap items-center justify-between gap-2">
            <span class="observatory-fact-value font-mono tabular-nums">
              {text(@overview, :cost, :settled, :label, "Unavailable")}
            </span>
            <span
              id="observatory-cost-settled"
              class={[
                AdminBadges.metadata_chip_class(:neutral),
                "observatory-metadata-chip uppercase !px-2 !py-0.5"
              ]}
            >
              settled
            </span>
          </dd>
          <dd class="observatory-fact-detail">
            {text(@overview, :cost, :detail, "Cost details unavailable")}
          </dd>
        </div>

        <div id="observatory-fact-throughput" class="observatory-fact">
          <dt class="observatory-fact-label">Throughput</dt>
          <dd class="observatory-fact-value-row">
            <span class="observatory-fact-value font-mono tabular-nums">
              {text(@overview, :throughput, :p50_label, "Unavailable")}
            </span>
            <span
              id="observatory-throughput-trend"
              data-role="observatory-trend"
              data-direction={trend_direction(@overview, :throughput)}
              class={["observatory-trend font-mono tabular-nums", trend_class(@overview, :throughput)]}
            >
              {trend_text(@overview, :throughput)}
            </span>
          </dd>
          <dd class="observatory-fact-detail">Median settled token rate</dd>
        </div>

        <div id="observatory-fact-latency" class="observatory-fact">
          <dt class="observatory-fact-label">Latency</dt>
          <dd class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <span class="observatory-fact-value font-mono tabular-nums">
              P50 {text(@overview, :latency, :p50_label, "Unavailable")}
            </span>
            <span class="text-sm font-mono tabular-nums text-base-content/60">
              P95 {text(@overview, :latency, :p95_label, "Unavailable")}
            </span>
          </dd>
          <dd class="observatory-fact-detail">
            {text(@overview, :latency, :detail, "Latency details unavailable")}
          </dd>
        </div>
      </dl>
    </section>

    <section
      id="observatory-models"
      class="observatory-card mt-4 overflow-hidden"
      aria-labelledby="observatory-models-title"
    >
      <header class="border-b border-base-300 bg-base-200/35 px-4 py-3">
        <h2 id="observatory-models-title" class="text-base font-semibold">Models</h2>
        <p class="text-xs leading-5 text-base-content/60">Settled tokens</p>
      </header>
      <ol class="grid gap-0.5 px-4 py-2">
        <li
          :for={{model, rank} <- ranked_models(@models)}
          id={"observatory-model-#{rank}"}
          data-role="observatory-model-row"
          class="observatory-model-row grid min-w-0 items-center gap-3 py-1.5"
        >
          <span class="min-w-0 truncate text-xs font-medium">{safe_model_label(model)}</span>
          <div
            data-role="observatory-model-bar"
            class="h-1.5 min-w-0 overflow-hidden rounded-full bg-base-300"
            role="progressbar"
            aria-label={"Model #{rank} share"}
            aria-valuemin="0"
            aria-valuemax="100"
            aria-valuenow={bar_percent(model)}
          >
            <span
              class={["block h-full rounded-full", tone_class(Map.get(model, :tone))]}
              style={"width: #{bar_percent(model)}%"}
            ></span>
          </div>
          <span class="text-right text-xs font-mono tabular-nums text-base-content/75">
            {safe_model_tokens(model)}
          </span>
        </li>
      </ol>
    </section>
    """
  end

  defp ranked_models(models) do
    models
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&bar_percent/1, :desc)
    |> Enum.with_index(1)
  end

  defp safe_model_label(model), do: text(model, :label, "Unnamed model")
  defp safe_model_tokens(model), do: text(model, :token_label, "No token data")

  defp text(map, key, fallback) when is_map(map), do: scalar(Map.get(map, key), fallback)
  defp text(_map, _key, fallback), do: fallback

  defp text(map, parent, key, fallback) when is_map(map) do
    map
    |> Map.get(parent, %{})
    |> text(key, fallback)
  end

  defp text(map, parent, child, key, fallback) when is_map(map) do
    map
    |> Map.get(parent, %{})
    |> Map.get(child, %{})
    |> text(key, fallback)
  end

  defp scalar(value, _fallback) when is_binary(value), do: value
  defp scalar(value, _fallback) when is_number(value), do: to_string(value)
  defp scalar(_value, fallback), do: fallback

  defp trend_value(map, parent) when is_map(map) do
    map
    |> Map.get(parent, %{})
    |> Map.get(:trend, %{})
  end

  defp trend_value(_map, _parent), do: %{}

  defp trend_text(map, parent),
    do: scalar(Map.get(trend_value(map, parent), :label), "not available")

  defp trend_class(map, parent) do
    case Map.get(trend_value(map, parent), :tone) do
      :success -> "text-success"
      :error -> "text-error"
      _tone -> "text-base-content/45"
    end
  end

  defp trend_direction(map, parent) do
    case Map.get(trend_value(map, parent), :direction) do
      direction when direction in [:up, :down, :flat, :unavailable] -> Atom.to_string(direction)
      _direction -> "unavailable"
    end
  end

  defp number_value(map, parent, key) do
    map
    |> numeric_value(parent, key)
    |> round()
  end

  defp percent(map, parent, key), do: numeric_value(map, parent, key) |> format_percent()

  defp numeric_value(map, parent, key) when is_map(map) do
    map
    |> Map.get(parent, %{})
    |> Map.get(key, 0)
    |> clamp_percent()
  end

  defp numeric_value(_map, _parent, _key), do: 0

  defp bar_percent(model) when is_map(model) do
    model
    |> Map.get(:bar_percent, 0)
    |> clamp_percent()
    |> format_percent()
  end

  defp bar_percent(_model), do: 0

  defp clamp_percent(value) when is_integer(value), do: value |> max(0) |> min(100)

  defp clamp_percent(value) when is_float(value) do
    cond do
      value < 0 -> 0
      value > 100 -> 100
      true -> value
    end
  end

  defp clamp_percent(_value), do: 0

  defp format_percent(value) when is_float(value) do
    value
    |> Float.round(1)
    |> then(fn rounded -> if rounded == trunc(rounded), do: trunc(rounded), else: rounded end)
  end

  defp format_percent(value), do: value

  defp tone_class(:primary), do: "bg-primary"
  defp tone_class(:info), do: "bg-info"
  defp tone_class(:success), do: "bg-success"
  defp tone_class(:warning), do: "bg-warning"
  defp tone_class(:error), do: "bg-error"
  defp tone_class(_tone), do: "bg-neutral"
end
