defmodule CodexPoolerWeb.Admin.ApiKeyWizardComponents.Review do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.DateTimeDisplay

  attr :review_sections, :list, required: true
  attr :review_errors, :list, required: true
  attr :usage, :map, required: true
  attr :warnings, :list, default: []
  attr :datetime_preferences, :map, required: true

  def api_key_review_step(assigns) do
    ~H"""
    <section id="api-key-step-review-panel" class="grid min-w-0 gap-5">
      <div class="grid gap-1">
        <h3 class="text-lg font-semibold text-base-content">Review effective policy</h3>
        <p class="text-sm leading-6 text-base-content/65">
          Confirm the normalized policy before saving.
        </p>
      </div>

      <div
        :if={@review_errors != []}
        id="api-key-review-errors"
        class="alert alert-error items-start"
      >
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <div class="grid gap-1">
          <p class="font-semibold">Policy needs attention</p>
          <ul class="list-disc pl-5 text-sm">
            <li :for={error <- @review_errors}>{error}</li>
          </ul>
        </div>
      </div>

      <div
        id="api-key-review-summary"
        class="overflow-hidden rounded-box border border-base-300 bg-base-100"
      >
        <.review_section :for={{title, rows} <- @review_sections} title={title} rows={rows} />
      </div>

      <.api_key_usage_summary
        id="api-key-usage-summary"
        usage={@usage}
        datetime_preferences={@datetime_preferences}
        compact
      />

      <div :if={@warnings != []} id="api-key-review-warnings" class="grid gap-2">
        <div :for={warning <- @warnings} class="alert alert-warning items-start">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>{warning.message}</span>
        </div>
      </div>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true

  defp review_section(assigns) do
    ~H"""
    <section class="grid gap-2 border-t border-base-300 px-4 py-3 first:border-t-0 sm:grid-cols-[9rem_minmax(0,1fr)] sm:gap-4">
      <h4 class="text-sm font-semibold text-base-content">{@title}</h4>
      <dl class="grid gap-2 text-sm">
        <div
          :for={{label, value} <- @rows}
          class="grid gap-1 sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-3"
        >
          <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/50">{label}</dt>
          <dd class="break-words text-base-content/80">{value}</dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :usage, :map, required: true
  attr :compact, :boolean, default: false
  attr :datetime_preferences, :map, required: true

  defp api_key_usage_summary(assigns) do
    assigns =
      assigns
      |> assign(:has_usage?, api_key_usage_present?(assigns.usage))
      |> assign(:limits, api_key_usage_limits(assigns.usage))

    ~H"""
    <section id={@id} class={api_key_usage_summary_class(@compact)}>
      <div class="flex items-start justify-between gap-3">
        <div class="grid gap-1">
          <h4 class={api_key_usage_title_class(@compact)}>Usage</h4>
          <p :if={!@has_usage?} id={"#{@id}-empty"} class="text-sm text-base-content/60">
            No usage recorded yet
          </p>
          <p :if={@has_usage?} id={"#{@id}-totals"} class="text-sm text-base-content/70">
            {format_integer(@usage.request_count)} requests · {format_integer(@usage.total_tokens)} tokens
          </p>
          <p :if={@has_usage?} id={"#{@id}-cost"} class="text-sm text-base-content/70">
            {api_key_usage_cost_summary(@usage)}
          </p>
        </div>
        <span :if={@limits != []} class={AdminBadges.count_chip_class()}>
          {@limits |> length()} limits
        </span>
      </div>

      <div :if={@limits != []} id={"#{@id}-limits"} class="mt-3 grid gap-2">
        <div
          :for={{limit, index} <- Enum.with_index(@limits)}
          id={"#{@id}-limit-#{index}"}
          class="rounded-box border border-base-300 bg-base-200/50 p-3 text-sm"
        >
          <div class="flex flex-wrap items-center justify-between gap-2">
            <span class="font-medium text-base-content">{usage_limit_label(limit)}</span>
            <span class="font-mono text-xs text-base-content/60">
              {usage_limit_window_label(limit)}
            </span>
          </div>
          <div class="mt-2 grid gap-1 text-base-content/70">
            <span>{usage_limit_values(limit)}</span>
            <span :if={limit[:reset_at]} class="font-mono text-xs">
              resets {format_usage_reset(limit[:reset_at], @datetime_preferences)}
            </span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp api_key_usage_present?(usage) do
    usage[:available?] and
      (positive_integer?(usage[:request_count]) or positive_integer?(usage[:total_tokens]) or
         api_key_usage_limits(usage) != [])
  end

  defp api_key_usage_limits(%{limits: limits}) when is_list(limits) do
    Enum.reject(limits, &(Map.get(&1, :limit_type) in ["cost_usd", "cost_microunits"]))
  end

  defp api_key_usage_limits(_usage), do: []

  defp api_key_usage_cost_summary(%{total_cost_usd: %Decimal{} = total_cost_usd}) do
    "Cost $#{Decimal.to_string(total_cost_usd, :normal)}"
  end

  defp api_key_usage_cost_summary(%{total_cost_status: status}) when is_binary(status) do
    "Cost #{status}"
  end

  defp api_key_usage_cost_summary(_usage), do: "Cost unavailable"

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp api_key_usage_summary_class(true) do
    "rounded-box border border-base-300 bg-base-100 p-3"
  end

  defp api_key_usage_summary_class(false) do
    "rounded-box border border-base-300 bg-base-100 p-4"
  end

  defp api_key_usage_title_class(true), do: "text-sm font-semibold text-base-content"
  defp api_key_usage_title_class(false), do: "font-semibold text-base-content"

  defp usage_limit_label(%{limit_type: "request_count"}), do: "Requests"
  defp usage_limit_label(%{limit_type: "total_tokens"}), do: "Tokens"
  defp usage_limit_label(%{limit_type: "credits"}), do: "Credits"

  defp usage_limit_label(%{limit_type: limit_type}) do
    limit_type |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp usage_limit_label(_limit), do: "Limit"

  defp usage_limit_window_label(%{limit_window: window, source: source}) do
    [window, source]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" · ", &(to_string(&1) |> String.replace("_", " ")))
  end

  defp usage_limit_window_label(_limit), do: "configured limit"

  defp usage_limit_values(%{current_value: current, max_value: max, remaining_value: remaining}) do
    "#{format_integer(current)} / #{format_integer(max)} used · #{format_integer(remaining)} remaining"
  end

  defp usage_limit_values(_limit), do: "Usage unavailable"

  defp format_usage_reset(reset_at, datetime_preferences) when is_binary(reset_at) do
    case DateTime.from_iso8601(reset_at) do
      {:ok, datetime, _offset} -> format_datetime(datetime, datetime_preferences)
      _error -> reset_at
    end
  end

  defp format_usage_reset(reset_at, _datetime_preferences), do: to_string(reset_at)

  defp format_datetime(%DateTime{} = datetime, datetime_preferences),
    do: DateTimeDisplay.format_datetime(datetime, datetime_preferences)

  defp format_integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer() |> format_integer()

  defp format_integer(nil), do: "unknown"
  defp format_integer(value), do: value |> to_string() |> blank_to_nil() || "unknown"

  defp blank_to_nil(value) do
    value = String.trim(to_string(value))
    if value == "", do: nil, else: value
  end
end
