defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.SavedResetMeter do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.Formatting, as: ResetFormatting
  alias CodexPoolerWeb.RelativeTime

  attr :id, :string, required: true
  attr :identity_id, :string, required: true
  attr :saved_resets, :map, required: true
  attr :saved_reset_policy, :map, required: true
  attr :disabled, :boolean, default: false

  @spec saved_reset_count_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def saved_reset_count_badge(%{saved_resets: %{reported?: true, available_count: count}} = assigns)
      when is_integer(count) and count > 0 do
    assigns =
      assigns
      |> assign(:badge_class, saved_reset_count_badge_class(assigns.saved_reset_policy))
      |> assign(:badge_icon_class, saved_reset_count_badge_icon_class(assigns.saved_reset_policy))
      |> assign(:aria_label, saved_reset_count_badge_aria_label(assigns.saved_resets))

    ~H"""
    <button
      id={@id}
      type="button"
      data-role="upstream-saved-reset-count-badge"
      class={@badge_class}
      aria-label={@aria_label}
      aria-controls="saved-reset-policy-dialog"
      aria-haspopup="dialog"
      phx-click="open_saved_reset_policy"
      phx-value-id={@identity_id}
      disabled={@disabled}
    >
      <.icon name="hero-building-library-micro" class={@badge_icon_class} />
      <span>{@saved_resets.available_count}</span>
    </button>
    """
  end

  def saved_reset_count_badge(assigns) do
    ~H"""
    """
  end

  attr :id, :string, required: true
  attr :identity_id, :string, default: nil
  attr :saved_resets, :map, required: true
  attr :saved_reset_policy, :map, required: true
  attr :class, :any, default: nil
  attr :now, :any, default: nil

  # The latest reset receipt lives in the bank dialog and the cockpit (`SavedResetOperation`); the meter
  # shows inventory and policy only.
  @spec saved_reset_meter(map()) :: Phoenix.LiveView.Rendered.t()
  def saved_reset_meter(assigns) do
    now = assigns.now || DateTime.utc_now()

    assigns =
      assigns
      |> assign(:segments, saved_reset_meter_segments(assigns.saved_resets))
      |> assign(:meter_max, saved_reset_meter_max(assigns.saved_resets))
      |> assign(:meter_value, saved_reset_meter_value(assigns.saved_resets))
      |> assign(:meter_label, saved_reset_meter_label(assigns.saved_resets))
      |> assign(:meter_count_label, saved_reset_meter_count_label(assigns.saved_resets))
      |> assign(:meter_reset_label, saved_reset_meter_reset_label(assigns.saved_resets, now))
      |> assign(:meter_policy_active, saved_reset_policy_active?(assigns.saved_reset_policy))

    ~H"""
    <div id={@id} data-role="upstream-saved-reset-meter" class={["relative grid gap-1.5", @class]}>
      <button
        :if={@identity_id}
        id={"#{@id}-open"}
        type="button"
        data-role="upstream-saved-reset-meter-open"
        class="saved-reset-open-gloss absolute -inset-x-2 -inset-y-1.5 z-10 cursor-pointer rounded border border-transparent transition-colors hover:border-(--color-reset-bank)/25 hover:bg-(--color-reset-bank)/5 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        aria-label={saved_reset_count_badge_aria_label(@saved_resets)}
        aria-controls="saved-reset-policy-dialog"
        aria-haspopup="dialog"
        phx-click="open_saved_reset_policy"
        phx-value-id={@identity_id}
      >
        <span class="sr-only">{gettext("Open saved reset bank")}</span>
      </button>
      <div class="flex min-w-0 items-center justify-between gap-3 text-xs">
        <span
          data-role="upstream-saved-reset-meter-title"
          class="min-w-0 truncate font-medium text-base-content"
        >
          {gettext("Banked Resets")}
        </span>
        <span
          data-role="upstream-saved-reset-meter-count"
          class={saved_reset_meter_count_class(@saved_reset_policy)}
        >
          {@meter_count_label}
        </span>
      </div>
      <div
        id={"#{@id}-bar"}
        role="meter"
        aria-valuemin="0"
        aria-valuemax={@meter_max}
        aria-valuenow={@meter_value}
        aria-label={@meter_label}
        class="grid grid-cols-5 gap-1"
      >
        <span
          :for={segment <- @segments}
          id={"#{@id}-segment-#{segment.index}"}
          data-role="upstream-saved-reset-meter-segment"
          aria-hidden="true"
          class={saved_reset_meter_segment_class(segment, @saved_reset_policy)}
        ></span>
      </div>
      <div class="flex items-center justify-between gap-3 text-[11px] text-base-content/60">
        <span
          id={"#{@id}-policy"}
          data-role="upstream-saved-reset-meter-policy"
          class="min-w-0 truncate"
        >
          <span :if={@meter_policy_active} class="font-medium text-(--color-reset-bank)">{gettext("Auto redeem active")}</span>
          <span :if={!@meter_policy_active}>{gettext("Auto redeem inactive")}</span>
        </span>
        <span
          :if={@meter_reset_label}
          id={"#{@id}-reset"}
          class="inline-flex shrink-0 items-baseline gap-1"
          title={@saved_resets.next_expires_title}
        >
          <.icon name="hero-clock" class="size-3 shrink-0 translate-y-0.5" />
          <span class="truncate">{@meter_reset_label}</span>
        </span>
      </div>
    </div>
    """
  end

  defp saved_reset_count_badge_class(policy), do: saved_reset_count_badge_tone_class(policy)

  defp saved_reset_count_badge_tone_class(%{enabled?: true}) do
    [
      saved_reset_count_badge_base_class(),
      "border-success/40 bg-success/15 text-success hover:bg-success/20 dark:border-success/60 dark:bg-success/20 dark:text-success"
    ]
  end

  defp saved_reset_count_badge_tone_class(_policy) do
    [
      saved_reset_count_badge_base_class(),
      "border-(--color-reset-bank)/40 bg-(--color-reset-bank)/10 text-(--color-reset-bank) hover:bg-(--color-reset-bank)/15"
    ]
  end

  defp saved_reset_count_badge_base_class do
    "inline-flex cursor-pointer items-center rounded-full border px-2.5 py-1 text-xs font-medium leading-none transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary disabled:cursor-default disabled:opacity-70 gap-1.5 self-center whitespace-nowrap tabular-nums"
  end

  defp saved_reset_count_badge_icon_class(%{enabled?: true}) do
    "size-3.5 shrink-0 [mask-size:contain] text-current"
  end

  defp saved_reset_count_badge_icon_class(_policy) do
    "size-3.5 shrink-0 [mask-size:contain] text-(--color-reset-bank)"
  end

  defp saved_reset_count_badge_aria_label(saved_resets),
    do: gettext("Open saved reset bank: %{label}", label: saved_resets.label)

  defp saved_reset_meter_segments(saved_resets) do
    filled_count = min(saved_reset_meter_value(saved_resets), 5)

    Enum.map(1..5, fn index ->
      %{index: index, filled?: index <= filled_count}
    end)
  end

  defp saved_reset_meter_value(%{available_count: count}) when is_integer(count) and count >= 0,
    do: count

  defp saved_reset_meter_value(_saved_resets), do: 0

  defp saved_reset_meter_max(saved_resets), do: max(saved_reset_meter_value(saved_resets), 5)

  defp saved_reset_meter_label(%{label: label}) when is_binary(label) and label != "",
    do: label

  defp saved_reset_meter_label(saved_resets),
    do: ngettext("%{count} saved reset", "%{count} saved resets", saved_reset_meter_value(saved_resets))

  defp saved_reset_meter_count_label(%{available_count: count})
       when is_integer(count) and count >= 0,
       do: "x#{count}"

  defp saved_reset_meter_count_label(saved_resets),
    do: "x#{saved_reset_meter_value(saved_resets)}"

  defp saved_reset_meter_reset_label(%{next_expires_at: expires_at}, now) do
    case ResetFormatting.parse_datetime(expires_at) do
      %DateTime{} = expires_at -> reset_time_left_label(expires_at, now)
      nil -> nil
    end
  end

  defp saved_reset_meter_reset_label(_saved_resets, _now), do: nil

  defp reset_time_left_label(%DateTime{} = expires_at, %DateTime{} = now) do
    seconds_until_expiration = RelativeTime.seconds_until(expires_at, now)

    if DateTime.compare(expires_at, now) == :gt do
      ResetFormatting.format_reset_duration(seconds_until_expiration)
    else
      gettext("expired")
    end
  end

  defp saved_reset_policy_active?(%{enabled?: true}), do: true
  defp saved_reset_policy_active?(_policy), do: false

  defp saved_reset_meter_count_class(_policy),
    do: "shrink-0 tabular-nums font-medium text-(--color-reset-bank)"

  defp saved_reset_meter_segment_class(%{filled?: true}, _policy),
    do: "h-1.5 rounded-full bg-(--color-reset-bank)/80"

  defp saved_reset_meter_segment_class(_segment, _policy),
    do: "h-1.5 rounded-full bg-base-300/70"
end
