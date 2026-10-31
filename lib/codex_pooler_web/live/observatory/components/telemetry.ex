defmodule CodexPoolerWeb.Observatory.Components.Telemetry do
  use Phoenix.Component
  use Gettext, backend: CodexPoolerWeb.Gettext

  import CodexPoolerWeb.CoreComponents, only: [icon: 1]

  alias CodexPoolerWeb.Observatory.Components.Section

  attr :overview, :map, required: true
  attr :models, :list, required: true
  attr :window, :string, default: nil

  @spec telemetry(map()) :: Phoenix.LiveView.Rendered.t()
  def telemetry(assigns) do
    ~H"""
    <.overview_strip overview={@overview} />
    <div class="mt-6">
      <.model_distribution models={@models} window={@window} />
    </div>
    """
  end

  attr :overview, :map, required: true

  @spec overview_strip(map()) :: Phoenix.LiveView.Rendered.t()
  def overview_strip(assigns) do
    ~H"""
    <section id="observatory-overview" aria-labelledby="observatory-overview-title">
      <h2 id="observatory-overview-title" class="sr-only">{gettext("Usage overview")}</h2>

      <dl id="observatory-overview-facts" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <div id="observatory-fact-success" class="observatory-kpi">
          <dt class="observatory-kpi-label">
            <span class="observatory-kpi-icon bg-success/15 text-success">
              <.icon name="hero-check-circle" class="size-4" />
            </span>
            {gettext("Success rate")} <.grade_badge id="observatory-success-grade" grade={Map.get(Map.get(@overview, :success_rate, %{}), :grade)} />
          </dt>
          <dd class="observatory-kpi-value-row">
            <span class="observatory-kpi-value">{text(
              @overview,
              :success_rate,
              :measure,
              :value,
              gettext("Unavailable")
            )}<span class="observatory-kpi-unit">{text(@overview, :success_rate, :measure, :unit, "")}</span></span>
            <span
              :if={trend_direction(@overview, :success_rate) != "unavailable"}
              id="observatory-success-trend"
              data-role="observatory-trend"
              data-direction={trend_direction(@overview, :success_rate)}
              class={["observatory-trend tabular-nums", trend_class(@overview, :success_rate)]}
            >
              {trend_text(@overview, :success_rate)}
            </span>
          </dd>
          <dd class="observatory-kpi-detail">
            {text(@overview, :success_rate, :detail, gettext("No details available"))}
          </dd>
        </div>

        <div id="observatory-fact-cache" class="observatory-kpi">
          <dt class="observatory-kpi-label">
            <span class="observatory-kpi-icon bg-info/15 text-info">
              <.icon name="hero-circle-stack" class="size-4" />
            </span>
            {gettext("Cache rate")} <.grade_badge id="observatory-cache-grade" grade={Map.get(Map.get(@overview, :cache_rate, %{}), :grade)} />
          </dt>
          <dd class="observatory-kpi-value-row">
            <span class="observatory-kpi-value">{text(
              @overview,
              :cache_rate,
              :measure,
              :value,
              gettext("Unavailable")
            )}<span class="observatory-kpi-unit">{text(@overview, :cache_rate, :measure, :unit, "")}</span></span>
            <span
              :if={trend_direction(@overview, :cache_rate) != "unavailable"}
              id="observatory-cache-trend"
              data-role="observatory-trend"
              data-direction={trend_direction(@overview, :cache_rate)}
              class={["observatory-trend tabular-nums", trend_class(@overview, :cache_rate)]}
            >
              {trend_text(@overview, :cache_rate)}
            </span>
          </dd>
          <dd class="observatory-kpi-detail">
            {text(@overview, :cache_rate, :detail, gettext("No cache details available"))}
          </dd>
        </div>

        <div id="observatory-fact-cost" class="observatory-kpi">
          <dt class="observatory-kpi-label">
            <span class="observatory-kpi-icon bg-primary/15 text-primary">
              <.icon name="hero-banknotes" class="size-4" />
            </span>
            {gettext("Cost")}
          </dt>
          <dd class="observatory-kpi-value-row">
            <span class="observatory-kpi-value">{text(@overview, :cost, :settled, :label, gettext("Unavailable"))}</span>
          </dd>
          <dd class="observatory-kpi-detail">
            {text(@overview, :cost, :detail, gettext("Cost details unavailable"))}
          </dd>
        </div>

        <div id="observatory-fact-tokens" class="observatory-kpi">
          <dt class="observatory-kpi-label">
            <span class="observatory-kpi-icon bg-base-200 text-base-content/70">
              <.icon name="hero-chart-bar" class="size-4" />
            </span>
            {gettext("Tokens")}
          </dt>
          <dd class="observatory-kpi-value-row">
            <span class="observatory-kpi-value">{text(@overview, :tokens, :value, gettext("Unavailable"))}</span>
          </dd>
          <dd class="observatory-kpi-detail">
            {text(@overview, :tokens, :detail, gettext("No token details available"))}
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :grade, :any, default: nil

  defp grade_badge(%{grade: %{label: _label, tone: _tone}} = assigns) do
    ~H"""
    <span
      id={@id}
      data-role="observatory-grade"
      data-tone={@grade.tone}
      class={[
        "ml-auto inline-flex h-4.5 items-center whitespace-nowrap rounded-full px-2 text-[10px] font-semibold uppercase leading-none tracking-[0.04em]",
        grade_class(@grade.tone)
      ]}
    >
      {@grade.label}
    </span>
    """
  end

  defp grade_badge(assigns), do: ~H""

  defp grade_class(:success), do: "bg-success/15 text-success"
  defp grade_class(:info), do: "bg-info/15 text-info"
  defp grade_class(:warning), do: "bg-warning/15 text-warning"
  defp grade_class(:error), do: "bg-error/15 text-error"
  defp grade_class(_tone), do: "bg-base-300 text-base-content/70"

  attr :models, :list, required: true
  attr :window, :string, default: nil

  @spec model_distribution(map()) :: Phoenix.LiveView.Rendered.t()
  def model_distribution(assigns) do
    ~H"""
    <section
      id="observatory-models"
      class="grid min-w-0 content-start gap-4"
      aria-labelledby="observatory-models-title"
    >
      <Section.divider id="observatory-models-title" label={gettext("Model Distribution")} suffix={@window} />
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
              <span class="ml-0.5 text-xs font-normal text-base-content/70">
                {model_requests(model)}
              </span>
            </span>
            <span class="shrink-0 text-xs font-medium leading-4 tabular-nums text-base-content">
              {model_share(model)}
            </span>
          </div>
          <div
            data-role="observatory-model-bar"
            class="-mt-px h-1.5 overflow-hidden rounded-full bg-base-300/70"
            role="progressbar"
            aria-label={gettext("Model %{rank} share", rank: rank)}
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
            <span class="observatory-metric min-w-0 truncate tabular-nums text-base-content">{safe_model_tokens(model)}<span class="text-base-content/70"> tks</span></span>
            <span class="observatory-metric shrink-0 tabular-nums text-base-content"><span class="text-base-content/70">$</span>{model_cost(model)}</span>
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

  defp safe_model_label(model), do: text(model, :label, gettext("Unnamed model"))
  defp safe_model_tokens(model), do: text(model, :token_label, gettext("No token data"))
  defp model_requests(model), do: text(model, :requests_label, gettext("No request data"))
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
    do: scalar(Map.get(trend_value(map, parent), :label), gettext("not available"))

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
