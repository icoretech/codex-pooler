defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.SavedResetMeter do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.Formatting, as: ResetFormatting

  attr :id, :string, required: true
  attr :identity_id, :string, required: true
  attr :saved_resets, :map, required: true
  attr :saved_reset_policy, :map, required: true
  attr :disabled, :boolean, default: false

  def saved_reset_count_badge(
        %{saved_resets: %{reported?: true, available_count: count}} = assigns
      )
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
      <.icon name="hero-battery-100" class={@badge_icon_class} />
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

  def saved_reset_meter(assigns) do
    redemption_status = saved_reset_redemption_status(assigns.saved_resets)

    assigns =
      assigns
      |> assign(:segments, saved_reset_meter_segments(assigns.saved_resets))
      |> assign(:meter_max, saved_reset_meter_max(assigns.saved_resets))
      |> assign(:meter_value, saved_reset_meter_value(assigns.saved_resets))
      |> assign(
        :meter_label,
        saved_reset_meter_label(assigns.saved_resets, redemption_status)
      )
      |> assign(:meter_count_label, saved_reset_meter_count_label(assigns.saved_resets))
      |> assign(:meter_reset_label, saved_reset_meter_reset_label(assigns.saved_resets))
      |> assign(:meter_policy_active, saved_reset_policy_active?(assigns.saved_reset_policy))
      |> assign(:redemption_status, redemption_status)

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
        <span class="sr-only">Open saved reset bank</span>
      </button>
      <div class="flex min-w-0 items-center justify-between gap-3 text-xs">
        <span
          data-role="upstream-saved-reset-meter-title"
          class="min-w-0 truncate font-medium text-base-content"
        >
          Banked Resets
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
          data-redemption-phase={segment.index == 1 && @redemption_status && @redemption_status.phase}
          aria-hidden="true"
          title={segment.index == 1 && @redemption_status && @redemption_status.title}
          class={[
            saved_reset_meter_segment_class(segment, @saved_reset_policy),
            segment.index == 1 && @redemption_status &&
              saved_reset_redemption_segment_class(@redemption_status)
          ]}
        ></span>
      </div>
      <div class="flex items-center justify-between gap-3 text-[11px] text-base-content/60">
        <span
          id={"#{@id}-policy"}
          data-role="upstream-saved-reset-meter-policy"
          class="min-w-0 truncate"
        >
          Auto redeem
          <span :if={@meter_policy_active} class="font-medium text-(--color-reset-bank)">
            active
          </span>
          <span :if={!@meter_policy_active}>inactive</span>
          <span
            :if={@redemption_status}
            id={"#{@id}-redemption-status"}
            data-role="upstream-saved-reset-meter-redemption-status"
            class={[
              "font-medium",
              if(@redemption_status.kind == :attention,
                do: "text-warning",
                else: "text-(--color-reset-bank)"
              )
            ]}
          >
            · {@redemption_status.short_label}
          </span>
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
    "size-3 shrink-0 text-current"
  end

  defp saved_reset_count_badge_icon_class(_policy) do
    "size-3 shrink-0 text-(--color-reset-bank)"
  end

  defp saved_reset_count_badge_aria_label(saved_resets),
    do: "Open saved reset bank: #{saved_resets.label}"

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

  defp saved_reset_meter_label(saved_resets, %{title: status_title}),
    do: "#{saved_reset_meter_label(saved_resets)} · #{status_title}"

  defp saved_reset_meter_label(saved_resets, nil),
    do: saved_reset_meter_label(saved_resets)

  defp saved_reset_meter_label(%{label: label}) when is_binary(label) and label != "",
    do: label

  defp saved_reset_meter_label(saved_resets),
    do: "#{saved_reset_meter_value(saved_resets)} saved resets"

  # The redemption lifecycle rides the first meter segment instead of a
  # separate status box: an in-flight spend pulses, a failed or expired
  # confirmation turns the segment warning. Details stay in the tooltip.
  defp saved_reset_redemption_status(saved_resets) do
    case Map.get(saved_resets, :reset_lifecycle) do
      %{phase: phase} = lifecycle when phase in ["consuming", "consumed_pending_probe"] ->
        %{
          kind: :active,
          phase: phase,
          title: saved_reset_redemption_title(lifecycle),
          short_label: saved_reset_redemption_short_label(phase)
        }

      %{phase: phase} = lifecycle when phase in ["reblocked", "expired"] ->
        %{
          kind: :attention,
          phase: phase,
          title: saved_reset_redemption_title(lifecycle),
          short_label: saved_reset_redemption_short_label(phase)
        }

      _lifecycle ->
        nil
    end
  end

  defp saved_reset_redemption_short_label("consuming"), do: "redeeming"
  defp saved_reset_redemption_short_label("consumed_pending_probe"), do: "confirming reset"
  defp saved_reset_redemption_short_label("reblocked"), do: "still blocked"
  defp saved_reset_redemption_short_label("expired"), do: "confirmation expired"

  defp saved_reset_redemption_title(%{label: label, deadline_at: deadline_at})
       when is_binary(deadline_at),
       do: "#{label} · confirmation window until #{deadline_at}"

  defp saved_reset_redemption_title(%{label: label}), do: label

  defp saved_reset_redemption_segment_class(%{kind: :active}),
    do: "animate-pulse !bg-(--color-reset-bank)/80"

  defp saved_reset_redemption_segment_class(%{kind: :attention}), do: "!bg-warning/70"

  defp saved_reset_meter_count_label(%{available_count: count})
       when is_integer(count) and count >= 0,
       do: "x#{count}"

  defp saved_reset_meter_count_label(saved_resets),
    do: "x#{saved_reset_meter_value(saved_resets)}"

  defp saved_reset_meter_reset_label(%{next_expires_at: expires_at}) do
    case ResetFormatting.parse_datetime(expires_at) do
      %DateTime{} = expires_at -> reset_time_left_label(expires_at)
      nil -> nil
    end
  end

  defp saved_reset_meter_reset_label(_saved_resets), do: nil

  defp reset_time_left_label(%DateTime{} = expires_at) do
    seconds_until_expiration = DateTime.diff(expires_at, DateTime.utc_now(), :second)

    if seconds_until_expiration > 0 do
      ResetFormatting.format_reset_duration(seconds_until_expiration)
    else
      "expired"
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
