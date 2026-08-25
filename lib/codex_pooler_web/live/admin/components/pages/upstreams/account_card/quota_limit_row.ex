defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.QuotaLimitRow do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :id, :string, required: true
  attr :limit, :map, required: true

  def quota_limit_row(assigns) do
    ~H"""
    <div
      id={@id}
      data-role="upstream-limit-chart"
      data-evidence-state={quota_limit_evidence_state(@limit)}
      data-meter-state={quota_limit_meter_state(@limit)}
      class="grid min-w-0 gap-1.5"
    >
      <div class="flex min-w-0 items-center justify-between gap-3 text-xs">
        <span data-role="upstream-limit-title" class="min-w-0 truncate font-medium text-base-content">
          {@limit.label}
        </span>
        <span class={[quota_limit_percent_class(@limit), "shrink-0"]}>{@limit.percent_label}</span>
      </div>
      <progress
        id={"#{@id}-progress"}
        data-role="upstream-limit-progress"
        data-evidence-state={quota_limit_evidence_state(@limit)}
        data-meter-state={quota_limit_meter_state(@limit)}
        aria-label={quota_limit_progress_label(@limit)}
        title={quota_limit_progress_title(@limit)}
        class={quota_limit_progress_class(@limit)}
        value={if is_nil(@limit.percent), do: nil, else: @limit.percent_value}
        max="100"
      >
        {@limit.percent_label}
      </progress>
      <div
        :if={quota_limit_details?(@limit)}
        class="flex items-center justify-between gap-3 text-[11px] text-base-content/60"
      >
        <span
          :if={@limit.count_label}
          id={"#{@id}-count"}
          class="tabular-nums"
          aria-label={Map.get(@limit, :count_title)}
          title={Map.get(@limit, :count_title)}
        >
          {@limit.count_label}
        </span>
        <span :if={is_nil(@limit.count_label)} aria-hidden="true"></span>
        <span
          :if={quota_limit_reset_visible?(@limit)}
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

  defp quota_limit_details?(limit) do
    count_label = Map.get(limit, :count_label)

    reset_label =
      if quota_limit_reset_visible?(limit), do: Map.get(limit, :reset_label), else: nil

    present_string?(count_label) or present_string?(reset_label)
  end

  defp quota_limit_reset_visible?(%{reset_display_state: state})
       when state in [:absent, :unconfirmed],
       do: false

  defp quota_limit_reset_visible?(limit), do: present_string?(Map.get(limit, :reset_label))

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

    "progress admin-live-progress #{tone_class}#{credit_burning_class(limit)} h-1.5 w-full"
  end

  defp quota_limit_progress_class(limit),
    do:
      "progress admin-live-progress admin-static-unknown-progress progress-neutral#{credit_burning_class(limit)} h-1.5 w-full"

  defp credit_burning_class(%{burning_credits: true}), do: " progress-striped"
  defp credit_burning_class(_limit), do: ""

  defp quota_limit_progress_label(%{burning_credits: true} = limit),
    do: "#{limit.label} credit balance remaining #{limit.percent_label}; credits in use"

  defp quota_limit_progress_label(%{count_title: count_title} = limit)
       when is_binary(count_title),
       do: "#{limit.label} included Codex quota remaining #{limit.percent_label}"

  defp quota_limit_progress_label(limit),
    do: "#{limit.label} remaining #{limit.percent_label}"

  defp quota_limit_progress_title(%{burning_credits: true}),
    do: "Striped while credits are being consumed after included Codex quota is exhausted."

  defp quota_limit_progress_title(_limit), do: nil

  defp quota_limit_evidence_state(%{evidence_state: state})
       when state in [:fresh, :stale, :unknown],
       do: Atom.to_string(state)

  defp quota_limit_evidence_state(%{evidence_state: state})
       when state in ["fresh", "stale", "unknown"],
       do: state

  defp quota_limit_evidence_state(_limit), do: "fresh"

  defp quota_limit_meter_state(%{meter_state: state})
       when state in [:current, :historical, :historical_exhausted, :unknown],
       do: Atom.to_string(state)

  defp quota_limit_meter_state(%{meter_state: state})
       when state in ["current", "historical", "historical_exhausted", "unknown"],
       do: state

  defp quota_limit_meter_state(_limit), do: "current"
end
