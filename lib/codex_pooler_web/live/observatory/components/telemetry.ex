defmodule CodexPoolerWeb.Observatory.Components.Telemetry do
  use Phoenix.Component

  alias CodexPoolerWeb.Observatory.Components.Section

  attr :overview, :map, required: true
  attr :models, :list, required: true
  attr :window, :string, default: nil

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
            <span class="observatory-fact-value font-mono tabular-nums">{text(
              @overview,
              :success_rate,
              :measure,
              :value,
              "Unavailable"
            )}<span class="observatory-fact-unit">{text(@overview, :success_rate, :measure, :unit, "")}</span></span>
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
            <span class="observatory-fact-value font-mono tabular-nums">{text(
              @overview,
              :cache_rate,
              :measure,
              :value,
              "Unavailable"
            )}<span class="observatory-fact-unit">{text(@overview, :cache_rate, :measure, :unit, "")}</span></span>
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
          <dd class="observatory-fact-value font-mono tabular-nums">
            {text(@overview, :cost, :settled, :label, "Unavailable")}
          </dd>
          <dd class="observatory-fact-detail">
            {text(@overview, :cost, :detail, "Cost details unavailable")}
          </dd>
        </div>

        <div id="observatory-fact-tokens" class="observatory-fact">
          <dt class="observatory-fact-label">Tokens</dt>
          <dd class="observatory-fact-value font-mono tabular-nums">
            {text(@overview, :tokens, :value, "Unavailable")}
          </dd>
          <dd class="observatory-fact-detail">
            {text(@overview, :tokens, :detail, "No token details available")}
          </dd>
        </div>
      </dl>
    </section>

    <section
      id="observatory-models"
      class="mt-6 grid gap-4"
      aria-labelledby="observatory-models-title"
    >
      <Section.divider id="observatory-models-title" label="Model Distribution" suffix={@window} />
      <ol class="grid gap-3.5">
        <li
          :for={{model, rank} <- ranked_models(@models)}
          id={"observatory-model-#{rank}"}
          data-role="observatory-model-row"
          class="grid min-w-0 gap-1.5"
        >
          <div class="flex min-w-0 items-baseline justify-between gap-3">
            <span class="min-w-0 truncate text-sm font-semibold leading-5 text-base-content">
              {safe_model_label(model)}
              <span class="ml-0.5 text-xs font-normal text-base-content/55">
                {model_requests(model)}
              </span>
            </span>
            <span
              class="shrink-0 text-xs font-medium leading-4 tabular-nums"
              style={"color: #{model_color(model)}"}
            >
              {model_share(model)}
            </span>
          </div>
          <div
            data-role="observatory-model-bar"
            class="-mt-px h-1.5 overflow-hidden rounded-full bg-base-300/70"
            role="progressbar"
            aria-label={"Model #{rank} share"}
            aria-valuemin="0"
            aria-valuemax="100"
            aria-valuenow={bar_percent(model)}
          >
            <span
              class="saved-reset-life-fill block h-full rounded-full"
              style={"width: #{bar_percent(model)}%; background-color: #{model_color(model)}; --shine-delay: #{model_shine_delay(model)}s"}
            ></span>
          </div>
          <div class="flex items-baseline justify-between gap-3">
            <span
              class="observatory-metric min-w-0 truncate tabular-nums"
              style={"color: #{model_color(model)}"}
            >{safe_model_tokens(model)}<span class="text-base-content/45"> tks</span></span>
            <span
              class="observatory-metric shrink-0 tabular-nums"
              style={"color: #{model_color(model)}"}
            ><span class="text-base-content/45">$</span>{model_cost(model)}</span>
          </div>
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
  defp model_requests(model), do: text(model, :requests_label, "No request data")
  defp model_share(model), do: text(model, :share_label, "—")
  defp model_cost(model), do: text(model, :cost_label, "—")

  defp model_color(model) when is_map(model),
    do: Map.get(model, :color, "var(--color-base-content)")

  defp model_color(_model), do: "var(--color-base-content)"

  defp model_shine_delay(model) when is_map(model) do
    case Map.get(model, :shine_delay) do
      value when is_number(value) -> value
      _value -> 0
    end
  end

  defp model_shine_delay(_model), do: 0

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
end
