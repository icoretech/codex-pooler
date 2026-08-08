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
  attr :saved_reset_confirmation, :map, default: nil
  attr :class, :any, default: nil
  attr :now, :any, default: nil

  def saved_reset_meter(assigns) do
    confirmation =
      saved_reset_confirmation(assigns.saved_reset_confirmation, assigns.saved_resets)

    now = assigns.now || DateTime.utc_now()

    assigns =
      assigns
      |> assign(:segments, saved_reset_meter_segments(assigns.saved_resets))
      |> assign(:meter_max, saved_reset_meter_max(assigns.saved_resets))
      |> assign(:meter_value, saved_reset_meter_value(assigns.saved_resets))
      |> assign(
        :meter_label,
        saved_reset_meter_label(assigns.saved_resets, confirmation)
      )
      |> assign(:meter_count_label, saved_reset_meter_count_label(assigns.saved_resets))
      |> assign(:meter_reset_label, saved_reset_meter_reset_label(assigns.saved_resets, now))
      |> assign(:meter_policy_active, saved_reset_policy_active?(assigns.saved_reset_policy))
      |> assign(:confirmation, confirmation)

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
          data-confirmation-state={segment.index == 1 && @confirmation && @confirmation.state}
          aria-hidden="true"
          title={segment.index == 1 && @confirmation && @confirmation.title}
          class={[
            saved_reset_meter_segment_class(segment, @saved_reset_policy),
            segment.index == 1 && @confirmation &&
              saved_reset_confirmation_segment_class(@confirmation)
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
      <div
        :if={@confirmation}
        id={"#{@id}-confirmation"}
        data-role="upstream-saved-reset-confirmation"
        data-confirmation-state={@confirmation.state}
        role="status"
        aria-label={@confirmation.title}
        title={@confirmation.title}
        class="relative z-20 grid gap-2 rounded-box border border-base-300 bg-base-200/45 px-3 py-2 text-[11px] text-base-content/70"
      >
        <div class="flex min-w-0 items-center justify-between gap-3">
          <span
            data-role="upstream-saved-reset-confirmation-state"
            data-confirmation-state={@confirmation.state}
            class={[
              "min-w-0 truncate font-semibold",
              saved_reset_confirmation_state_class(@confirmation)
            ]}
          >
            {@confirmation.state_label}
          </span>
          <span
            data-role="upstream-saved-reset-routing-pause"
            data-routing-paused={to_string(@confirmation.routing_paused?)}
            class="shrink-0 font-medium"
          >
            {@confirmation.routing_label}
          </span>
        </div>
        <p data-role="upstream-saved-reset-confirmation-summary" class="leading-4">
          {@confirmation.summary}
        </p>
        <dl class="grid grid-cols-2 gap-x-3 gap-y-1">
          <div class="min-w-0">
            <dt class="font-medium text-base-content/50">Consumed</dt>
            <dd data-role="upstream-saved-reset-consumed-at" class="truncate">
              {@confirmation.consumed_at}
            </dd>
          </div>
          <div class="min-w-0">
            <dt class="font-medium text-base-content/50">Deadline</dt>
            <dd data-role="upstream-saved-reset-deadline" class="truncate">
              {@confirmation.deadline_at}
            </dd>
          </div>
          <div class="min-w-0">
            <dt class="font-medium text-base-content/50">Challenged evidence</dt>
            <dd
              data-role="upstream-saved-reset-challenged-evidence"
              data-evidence-state={@confirmation.evidence_state}
              class="truncate"
            >
              {@confirmation.evidence_label}
            </dd>
          </div>
          <div class="min-w-0">
            <dt class="font-medium text-base-content/50">Additional blocker</dt>
            <dd
              data-role="upstream-saved-reset-additional-blocker"
              data-blocker-state={@confirmation.blocker_state}
              class="truncate"
            >
              {@confirmation.blocker_label}
            </dd>
          </div>
        </dl>
        <p data-role="upstream-saved-reset-single-consume" class="leading-4 text-base-content/60">
          This confirmation never consumes a second saved reset.
        </p>
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

  defp saved_reset_meter_label(saved_resets, %{title: confirmation_title}),
    do: "#{saved_reset_meter_label(saved_resets)} · #{confirmation_title}"

  defp saved_reset_meter_label(saved_resets, nil),
    do: saved_reset_meter_label(saved_resets)

  defp saved_reset_meter_label(%{label: label}) when is_binary(label) and label != "",
    do: label

  defp saved_reset_meter_label(saved_resets),
    do: "#{saved_reset_meter_value(saved_resets)} saved resets"

  defp saved_reset_confirmation(
         %{
           confirmation_state: confirmation_state,
           challenged_evidence_state: evidence_state,
           additional_account_blocker_state: blocker_state
         },
         saved_resets
       )
       when confirmation_state in [
              :awaiting_confirmation,
              :confirmed,
              :not_applied,
              :confirmation_expired
            ] and
              evidence_state in [:absent, :exhausted, :candidate_progressing, :usable] and
              blocker_state in [
                :none,
                :reset_missing,
                :expired,
                :not_fresh,
                :exhausted,
                :unknown_unusable
              ] do
    lifecycle = bounded_lifecycle(saved_resets)
    state_label = confirmation_state_label(confirmation_state)
    evidence_label = confirmation_evidence_label(evidence_state)
    blocker_label = confirmation_blocker_label(blocker_state)
    routing_paused? = confirmation_state == :awaiting_confirmation
    routing_label = if routing_paused?, do: "Routing paused", else: "Routing pause released"
    consumed_at = lifecycle_value(lifecycle, :consumed_at)
    deadline_at = lifecycle_value(lifecycle, :deadline_at)

    %{
      state: confirmation_state,
      state_label: state_label,
      summary: confirmation_state_summary(confirmation_state),
      evidence_state: evidence_state,
      evidence_label: evidence_label,
      blocker_state: blocker_state,
      blocker_label: blocker_label,
      routing_paused?: routing_paused?,
      routing_label: routing_label,
      consumed_at: consumed_at,
      deadline_at: deadline_at,
      title:
        confirmation_title(
          state_label,
          consumed_at,
          deadline_at,
          evidence_label,
          blocker_label,
          routing_label
        )
    }
  end

  defp saved_reset_confirmation(nil, _saved_resets), do: nil

  defp saved_reset_confirmation(_confirmation, _saved_resets) do
    %{
      state: :unavailable,
      state_label: "Confirmation details unavailable",
      summary: "The confirmation snapshot could not be safely displayed.",
      evidence_state: :unavailable,
      evidence_label: "Unavailable",
      blocker_state: :unavailable,
      blocker_label: "Unavailable",
      routing_paused?: true,
      routing_label: "Routing paused",
      consumed_at: "Not reported",
      deadline_at: "Not reported",
      title:
        "Confirmation details unavailable. Routing paused. This confirmation never consumes a second saved reset."
    }
  end

  defp bounded_lifecycle(%{reset_lifecycle: %{phase: phase} = lifecycle})
       when phase in [
              "consuming",
              "consumed_pending_probe",
              "confirmed_by_upstream",
              "confirmed_by_quota",
              "reblocked",
              "expired",
              "consume_not_applied"
            ],
       do: lifecycle

  defp bounded_lifecycle(_saved_resets), do: %{}

  defp lifecycle_value(lifecycle, key) do
    case Map.get(lifecycle, key) do
      value when is_binary(value) and value != "" -> value
      _value -> "Not reported"
    end
  end

  defp confirmation_state_label(:awaiting_confirmation), do: "Awaiting confirmation"
  defp confirmation_state_label(:confirmed), do: "Confirmed"
  defp confirmation_state_label(:not_applied), do: "Not applied"
  defp confirmation_state_label(:confirmation_expired), do: "Confirmation expired"

  defp confirmation_state_summary(:awaiting_confirmation),
    do: "Reset consumed; confirmation is still pending."

  defp confirmation_state_summary(:confirmed), do: "Reset application confirmed."
  defp confirmation_state_summary(:not_applied), do: "The saved reset was not applied."

  defp confirmation_state_summary(:confirmation_expired),
    do: "The confirmation window ended without proof of a usable reset."

  defp confirmation_evidence_label(:absent), do: "Absent"
  defp confirmation_evidence_label(:exhausted), do: "Exhausted"
  defp confirmation_evidence_label(:candidate_progressing), do: "Candidate progressing"
  defp confirmation_evidence_label(:usable), do: "Usable"

  defp confirmation_blocker_label(:none), do: "None"
  defp confirmation_blocker_label(:reset_missing), do: "Reset missing"
  defp confirmation_blocker_label(:expired), do: "Expired"
  defp confirmation_blocker_label(:not_fresh), do: "Not fresh"
  defp confirmation_blocker_label(:exhausted), do: "Exhausted"
  defp confirmation_blocker_label(:unknown_unusable), do: "Unknown or unusable"

  defp confirmation_title(
         state_label,
         consumed_at,
         deadline_at,
         evidence_label,
         blocker_label,
         routing_label
       ) do
    "#{state_label}. Consumed #{consumed_at}. Deadline #{deadline_at}. " <>
      "Challenged evidence #{evidence_label}. Additional blocker #{blocker_label}. " <>
      "#{routing_label}. This confirmation never consumes a second saved reset."
  end

  defp saved_reset_confirmation_segment_class(%{state: :awaiting_confirmation}),
    do: "animate-pulse !bg-(--color-reset-bank)/80 motion-reduce:animate-none"

  defp saved_reset_confirmation_segment_class(%{state: :confirmed}),
    do: "!bg-success/80"

  defp saved_reset_confirmation_segment_class(%{state: :not_applied}),
    do: "!bg-error/70"

  defp saved_reset_confirmation_segment_class(%{state: :confirmation_expired}),
    do: "!bg-warning/70"

  defp saved_reset_confirmation_segment_class(_confirmation), do: "!bg-base-300/70"

  defp saved_reset_confirmation_state_class(%{state: :confirmed}), do: "text-success"
  defp saved_reset_confirmation_state_class(%{state: :not_applied}), do: "text-error"

  defp saved_reset_confirmation_state_class(%{state: :confirmation_expired}),
    do: "text-warning"

  defp saved_reset_confirmation_state_class(%{state: :awaiting_confirmation}),
    do: "text-(--color-reset-bank)"

  defp saved_reset_confirmation_state_class(_confirmation), do: "text-base-content/60"

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
