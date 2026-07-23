defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.QuotaLimitRow do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :id, :string, required: true
  attr :limit, :map, required: true

  def quota_limit_row(assigns) do
    ~H"""
    <div id={@id} data-role="upstream-limit-chart" class="grid min-w-0 gap-1.5">
      <div class="flex min-w-0 items-center justify-between gap-3 text-xs">
        <span data-role="upstream-limit-title" class="min-w-0 truncate font-medium text-base-content">
          {@limit.label}
        </span>
        <span class={[quota_limit_percent_class(@limit), "shrink-0"]}>{@limit.percent_label}</span>
      </div>
      <progress
        id={"#{@id}-progress"}
        data-role="upstream-limit-progress"
        aria-label={"#{@limit.label} remaining #{@limit.percent_label}"}
        class={quota_limit_progress_class(@limit)}
        value={@limit.percent_value}
        max="100"
      >
        {@limit.percent_label}
      </progress>
      <div
        :if={quota_limit_details?(@limit)}
        class="flex items-center justify-between gap-3 text-[11px] text-base-content/60"
      >
        <span :if={@limit.count_label} id={"#{@id}-count"} class="tabular-nums">
          {@limit.count_label}
        </span>
        <span :if={is_nil(@limit.count_label)} aria-hidden="true"></span>
        <span
          :if={@limit.reset_label}
          id={"#{@id}-reset"}
          data-countdown-at={countdown_at(@limit)}
          data-countdown-state={countdown_state(@limit)}
          phx-hook={countdown_hook(@limit)}
          class="inline-flex items-baseline gap-1"
          title={@limit.reset_title}
        >
          <%!-- Anchor the icon to the text baseline, not the line box: the
          box center shifts per engine, the baseline doesn't. Bottom-on-
          baseline puts the 12px icon ~2px high of the glyph ink center. --%>
          <.icon name="hero-clock" class="size-3 translate-y-0.5" />
          <span data-role="relative-countdown-value">{strip_in_prefix(@limit.reset_label)}</span>
        </span>
      </div>
    </div>
    """
  end

  # The clock icon already says "time until"; the label's "in " prefix is
  # redundant next to it.
  defp strip_in_prefix("in " <> rest), do: rest
  defp strip_in_prefix(label), do: label

  defp countdown_at(%{reset_semantics: :anchored, reset_at: %DateTime{} = reset_at}),
    do: DateTime.to_iso8601(reset_at)

  defp countdown_at(_limit), do: nil

  defp countdown_state(%{reset_semantics: :anchored}), do: "running"
  defp countdown_state(%{reset_semantics: :floating}), do: "waiting"
  defp countdown_state(_limit), do: "unknown"

  defp countdown_hook(%{reset_semantics: :anchored, reset_at: %DateTime{}}),
    do: "RelativeCountdown"

  defp countdown_hook(_limit), do: nil

  defp quota_limit_details?(%{count_label: count_label, reset_label: reset_label}) do
    present_string?(count_label) or present_string?(reset_label)
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp quota_limit_percent_class(%{percent: %Decimal{} = percent}) do
    cond do
      Decimal.compare(percent, Decimal.new(70)) != :lt -> "tabular-nums font-medium text-success"
      Decimal.compare(percent, Decimal.new(30)) != :lt -> "tabular-nums font-medium text-warning"
      true -> "tabular-nums font-medium text-error"
    end
  end

  defp quota_limit_percent_class(_limit), do: "tabular-nums font-medium text-base-content/50"

  defp quota_limit_progress_class(%{percent: %Decimal{} = percent} = limit) do
    tone_class =
      cond do
        Decimal.compare(percent, Decimal.new(70)) != :lt -> "progress-success"
        Decimal.compare(percent, Decimal.new(30)) != :lt -> "progress-warning"
        true -> "progress-error"
      end

    "progress admin-live-progress #{tone_class}#{credit_backed_class(limit)} h-1.5 w-full"
  end

  defp quota_limit_progress_class(limit),
    do: "progress admin-live-progress progress-neutral#{credit_backed_class(limit)} h-1.5 w-full"

  defp credit_backed_class(%{credit_backed: true}), do: " progress-striped"
  defp credit_backed_class(_limit), do: ""
end
