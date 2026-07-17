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
            title={row.banked_title}
          >
            banked {row.banked_label}
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
         %{expires_at: value, first_seen_at: first_seen_at},
         index,
         datetime_preferences,
         now
       ) do
    value
    |> expiration_row(index, datetime_preferences, now)
    |> merge_first_seen(first_seen_at, datetime_preferences, now)
  end

  defp available_expiration_row(
         %{"expires_at" => value, "first_seen_at" => first_seen_at},
         index,
         datetime_preferences,
         now
       ) do
    value
    |> expiration_row(index, datetime_preferences, now)
    |> merge_first_seen(first_seen_at, datetime_preferences, now)
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
          banked_label: "not recorded",
          banked_title: nil,
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
          banked_label: "not recorded",
          banked_title: nil,
          held_label: nil,
          life_percent: nil,
          shine_delay: shine_delay(index)
        }
    end
  end

  defp merge_first_seen(row, first_seen_value, datetime_preferences, now) do
    case ResetFormatting.parse_datetime(first_seen_value) do
      %DateTime{} = first_seen_at ->
        parts = DateTimeDisplay.format_datetime_parts(first_seen_at, datetime_preferences)
        fraction = life_fraction(first_seen_at, row.expires_at, now)

        %{
          row
          | banked_label: parts.date,
            banked_title: DateTimeDisplay.format_datetime(first_seen_at, datetime_preferences),
            held_label: held_label(DateTime.diff(now, first_seen_at, :second)),
            life_percent: fraction && Float.round(fraction * 100, 1)
        }

      nil ->
        row
    end
  end

  defp life_fraction(%DateTime{} = first_seen_at, %DateTime{} = expires_at, now) do
    total_seconds = DateTime.diff(expires_at, first_seen_at, :second)

    if total_seconds > 0 do
      (DateTime.diff(expires_at, now, :second) / total_seconds)
      |> min(1.0)
      |> max(0.0)
    end
  end

  defp life_fraction(_first_seen_at, _expires_at, _now), do: nil

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
