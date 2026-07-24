defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.SavedResetComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.Formatting, as: ResetFormatting
  alias CodexPoolerWeb.DateTimeDisplay

  @shine_stagger_seconds 1.2

  attr :id, :string, required: true
  attr :saved_resets, :map, required: true
  attr :datetime_preferences, :map, required: true
  attr :empty_label, :string, default: "Expiration dates not reported"

  def saved_reset_expiration_table(assigns) do
    assigns =
      assign(
        assigns,
        :rows,
        expiration_rows(assigns.saved_resets, assigns.datetime_preferences, DateTime.utc_now())
      )

    ~H"""
    <p
      :if={@rows == []}
      id={"#{@id}-empty"}
      data-role="saved-reset-expiration-empty"
      class="text-xs leading-5 text-base-content/60"
    >
      {@empty_label}
    </p>
    <ul
      :if={@rows != []}
      id={@id}
      data-role="saved-reset-expiration-list"
      class="grid gap-3.5"
    >
      <li
        :for={row <- @rows}
        id={"#{@id}-row-#{row.index}"}
        data-role="saved-reset-expiration-row"
        class="grid gap-1.5"
      >
        <div class="flex items-baseline justify-between gap-3">
          <p
            id={"#{@id}-date-#{row.index}"}
            data-role="saved-reset-expiration-date"
            class="min-w-0 truncate text-sm font-semibold leading-5 text-base-content"
            title={row.title}
          >
            {row.date_label}
            <span :if={row.time_label} class="ml-0.5 text-xs font-normal text-base-content/55">
              {row.time_label}
            </span>
          </p>
          <p
            id={"#{@id}-time-left-#{row.index}"}
            data-role="saved-reset-expiration-time-left"
            class={[
              "inline-flex shrink-0 items-center gap-1 text-xs font-medium leading-4 tabular-nums",
              if(row.expired?, do: "text-base-content/50", else: "text-(--color-reset-bank)")
            ]}
          >
            <.icon name="hero-clock" class="size-3 shrink-0" />
            <span>{row.time_left_label}</span>
          </p>
        </div>
        <%!-- The date line's 20px box leaves ~1px more air under the glyphs
        than the meter title's 16px box; tuck the bar so the ink-to-bar
        rhythm matches the banked-resets meter above. --%>
        <div
          :if={row.life_percent}
          id={"#{@id}-life-#{row.index}"}
          data-role="saved-reset-expiration-life"
          class="-mt-px h-1.5 overflow-hidden rounded-full bg-base-300/70"
        >
          <span
            class="saved-reset-life-fill block h-full rounded-full bg-(--color-reset-bank)/80"
            style={"width: #{row.life_percent}%; --shine-delay: #{row.shine_delay}s"}
          ></span>
        </div>
        <div class="flex items-baseline justify-between gap-3 text-[11px] leading-4 text-base-content/60">
          <span
            id={"#{@id}-first-seen-#{row.index}"}
            data-role="saved-reset-expiration-first-seen"
            class="min-w-0 truncate"
            title={row.source_title}
          >
            {row.source_label} {row.source_date_label}
          </span>
          <span
            :if={row.held_label}
            id={"#{@id}-held-#{row.index}"}
            data-role="saved-reset-expiration-held"
            class="shrink-0 tabular-nums"
          >
            held {row.held_label}
          </span>
        </div>
      </li>
    </ul>
    """
  end

  attr :form, :any, required: true

  def saved_reset_policy_fields(assigns) do
    threshold_field = assigns.form[:quota_threshold_percent]

    threshold_errors =
      if Phoenix.Component.used_input?(threshold_field) do
        Enum.map(threshold_field.errors, &translate_error/1)
      else
        []
      end

    assigns =
      assigns
      |> assign(:trigger_mode, to_string(assigns.form[:trigger_mode].value || "blocked"))
      |> assign(:policy_enabled?, assigns.form[:auto_redeem_enabled].value in [true, "true"])
      |> assign(:threshold_errors, threshold_errors)

    ~H"""
    <div
      data-role="saved-reset-policy-tunables"
      class={["grid gap-4 transition-opacity", !@policy_enabled? && "opacity-55"]}
    >
      <fieldset id="saved-reset-policy-trigger-mode" class="grid items-stretch gap-2.5 md:grid-cols-2">
        <legend class="sr-only">When automatic redemption can start</legend>
        <label
          id="saved-reset-policy-trigger-blocked"
          data-role="saved-reset-policy-trigger-card"
          class={trigger_card_class(@trigger_mode == "blocked")}
        >
          <input
            id="saved-reset-policy-trigger-mode-blocked"
            type="radio"
            name="saved_reset_policy[trigger_mode]"
            value="blocked"
            checked={@trigger_mode == "blocked"}
            class="radio radio-primary radio-sm mt-0.5"
          />
          <span class="grid gap-1">
            <span class="text-sm font-semibold leading-5 text-base-content">
              Blocked or expiring
            </span>
            <span class="text-xs leading-5 text-base-content/60">
              Waits for weekly quota exhaustion. A reset expiring within 24 hours may be rescued early once this account has weekly usage.
            </span>
          </span>
        </label>
        <label
          id="saved-reset-policy-trigger-threshold"
          data-role="saved-reset-policy-trigger-card"
          class={trigger_card_class(@trigger_mode == "threshold")}
        >
          <input
            id="saved-reset-policy-trigger-mode-threshold"
            type="radio"
            name="saved_reset_policy[trigger_mode]"
            value="threshold"
            checked={@trigger_mode == "threshold"}
            class="radio radio-primary radio-sm mt-0.5"
          />
          <span class="grid gap-1">
            <span class="text-sm font-semibold leading-5 text-base-content">Near limit</span>
            <span class="text-xs leading-5 text-base-content/60">
              Starts earlier: once every eligible account in the Pool reaches
              <input
                id="saved-reset-policy-quota-threshold-percent"
                type="number"
                name="saved_reset_policy[quota_threshold_percent]"
                value={
                  Phoenix.HTML.Form.normalize_value(
                    "number",
                    @form[:quota_threshold_percent].value
                  )
                }
                min="1"
                max="100"
                step="1"
                class={[
                  "input input-xs mx-0.5 inline-block w-14 border-base-300 bg-base-100 px-1.5 text-center text-xs font-semibold tabular-nums",
                  @threshold_errors != [] && "input-error"
                ]}
              />% of the weekly quota window.
            </span>
            <span
              :for={message <- @threshold_errors}
              class="flex items-center gap-1.5 text-xs text-error"
            >
              <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
              {message}
            </span>
          </span>
        </label>
      </fieldset>

      <div class="grid items-start gap-4 border-t border-base-300/50 pt-4 md:grid-cols-2">
        <div class="grid gap-1">
          <.input
            field={@form[:min_blocked_minutes]}
            type="number"
            id="saved-reset-policy-min-blocked-minutes"
            name="saved_reset_policy[min_blocked_minutes]"
            label="Natural reset buffer"
            min="0"
          />
          <p class="text-xs leading-5 text-base-content/65">
            Do not spend a saved reset when the weekly quota will reset naturally within this many minutes.
          </p>
        </div>
        <div class="grid gap-1">
          <.input
            field={@form[:keep_credits]}
            type="number"
            id="saved-reset-policy-keep-credits"
            name="saved_reset_policy[keep_credits]"
            label="Resets to keep"
            min="0"
          />
          <p class="text-xs leading-5 text-base-content/65">
            Automatic redemption stops when the available reset count is at or below this reserve.
          </p>
        </div>
      </div>
    </div>
    """
  end

  # Same selection anatomy as the API-key policy mode cards, sized down for
  # the dense policy panels. Selection is server-rendered from the form value
  # (both forms phx-change validate); the app.css :has(:checked) rule doubles
  # it client-side so the tint moves before the round trip lands.
  defp trigger_card_class(selected?) do
    [
      "flex cursor-pointer items-start gap-3 rounded-box border p-3 transition-colors hover:bg-base-200",
      if(selected?,
        do: "border-primary bg-primary/10",
        else: "border-base-300 bg-base-100"
      )
    ]
  end

  defp expiration_rows(saved_resets, datetime_preferences, now) do
    available_expiration_rows =
      saved_resets
      |> Map.get(:available_expirations, [])
      |> available_expiration_rows(datetime_preferences, now)

    if available_expiration_rows == [] do
      legacy_expiration_rows(saved_resets, datetime_preferences, now)
    else
      available_expiration_rows
    end
  end

  defp available_expiration_rows(rows, datetime_preferences, now) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      available_expiration_row(row, index, datetime_preferences, now)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp available_expiration_rows(_rows, _datetime_preferences, _now), do: []

  defp legacy_expiration_rows(saved_resets, datetime_preferences, now) do
    case Map.get(saved_resets, :available_expires_at, []) do
      values when is_list(values) ->
        values
        |> Enum.with_index()
        |> Enum.map(fn {value, index} ->
          expiration_row(value, index, datetime_preferences, now)
        end)

      _invalid ->
        []
    end
  end

  defp available_expiration_row(
         %{expires_at: value, first_seen_at: first_seen_at} = source,
         index,
         datetime_preferences,
         now
       ) do
    value
    |> expiration_row(index, datetime_preferences, now)
    |> merge_expiration_source(
      Map.get(source, :granted_at),
      first_seen_at,
      datetime_preferences,
      now
    )
  end

  defp available_expiration_row(
         %{"expires_at" => value, "first_seen_at" => first_seen_at} = source,
         index,
         datetime_preferences,
         now
       ) do
    value
    |> expiration_row(index, datetime_preferences, now)
    |> merge_expiration_source(
      Map.get(source, "granted_at"),
      first_seen_at,
      datetime_preferences,
      now
    )
  end

  defp available_expiration_row(_row, _index, _datetime_preferences, _now), do: nil

  defp expiration_row(value, index, datetime_preferences, now) do
    case ResetFormatting.parse_datetime(value) do
      %DateTime{} = expires_at ->
        parts = DateTimeDisplay.format_datetime_parts(expires_at, datetime_preferences)
        seconds_until_expiration = DateTime.diff(expires_at, now, :second)

        %{
          index: index,
          expires_at: expires_at,
          date_label: parts.date,
          time_label: parts.time,
          title: DateTimeDisplay.format_datetime(expires_at, datetime_preferences),
          expired?: seconds_until_expiration <= 0,
          time_left_label: time_left_label(seconds_until_expiration),
          source_label: "seen",
          source_date_label: "not recorded",
          source_title: nil,
          held_label: nil,
          life_percent: nil,
          shine_delay: shine_delay(index)
        }

      nil ->
        %{
          index: index,
          expires_at: nil,
          date_label: "unknown time",
          time_label: nil,
          title: to_string(value),
          expired?: false,
          time_left_label: "unknown",
          source_label: "seen",
          source_date_label: "not recorded",
          source_title: nil,
          held_label: nil,
          life_percent: nil,
          shine_delay: shine_delay(index)
        }
    end
  end

  defp merge_expiration_source(
         row,
         granted_at_value,
         first_seen_at_value,
         datetime_preferences,
         now
       ) do
    case ResetFormatting.parse_datetime(granted_at_value) do
      %DateTime{} = granted_at ->
        merge_source(row, granted_at, "banked", datetime_preferences, now)

      nil ->
        case ResetFormatting.parse_datetime(first_seen_at_value) do
          %DateTime{} = first_seen_at ->
            merge_source(row, first_seen_at, "seen", datetime_preferences, now)

          nil ->
            row
        end
    end
  end

  defp merge_source(row, source_at, source_label, datetime_preferences, now) do
    parts = DateTimeDisplay.format_datetime_parts(source_at, datetime_preferences)
    fraction = life_fraction(source_at, row.expires_at, now)

    %{
      row
      | source_label: source_label,
        source_date_label: parts.date,
        source_title: DateTimeDisplay.format_datetime(source_at, datetime_preferences),
        held_label: held_label(DateTime.diff(now, source_at, :second)),
        life_percent: fraction && Float.round(fraction * 100, 1)
    }
  end

  defp life_fraction(%DateTime{} = source_at, %DateTime{} = expires_at, now) do
    total_seconds = DateTime.diff(expires_at, source_at, :second)

    if total_seconds > 0 do
      (DateTime.diff(expires_at, now, :second) / total_seconds)
      |> min(1.0)
      |> max(0.0)
    end
  end

  defp life_fraction(_source_at, _expires_at, _now), do: nil

  defp time_left_label(seconds) when seconds > 0 do
    precise_duration_label(seconds)
  end

  defp time_left_label(_seconds), do: "expired"

  defp precise_duration_label(seconds) when seconds >= 60 do
    total_minutes = div(seconds, 60)
    days = div(total_minutes, 1_440)
    hours = total_minutes |> rem(1_440) |> div(60)
    minutes = rem(total_minutes, 60)

    [{days, "d"}, {hours, "h"}, {minutes, "m"}]
    |> Enum.drop_while(fn {value, _unit} -> value == 0 end)
    |> Enum.map_join(" ", fn {value, unit} -> "#{value}#{unit}" end)
  end

  defp precise_duration_label(_seconds), do: "<1m"

  defp held_label(seconds) when seconds >= 86_400, do: "#{div(seconds, 86_400)}d"
  defp held_label(seconds) when seconds >= 3_600, do: "#{div(seconds, 3_600)}h"
  defp held_label(seconds) when seconds >= 60, do: "#{div(seconds, 60)}m"
  defp held_label(seconds) when seconds >= 0, do: "<1m"
  defp held_label(_seconds), do: nil

  defp shine_delay(index), do: Float.round(index * @shine_stagger_seconds, 1)
end
