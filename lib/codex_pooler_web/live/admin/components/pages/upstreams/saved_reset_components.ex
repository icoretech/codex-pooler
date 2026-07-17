defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.SavedResetComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.Formatting, as: ResetFormatting
  alias CodexPoolerWeb.DateTimeDisplay

  attr :id, :string, required: true
  attr :saved_resets, :map, required: true
  attr :datetime_preferences, :map, required: true
  attr :compact, :boolean, default: false
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
    <div
      :if={@rows != [] and @compact}
      id={@id}
      data-role="saved-reset-expiration-list-block"
      class="grid gap-1"
    >
      <div
        id={"#{@id}-labels"}
        data-role="saved-reset-expiration-list-labels"
        class="grid grid-cols-[minmax(0,1fr)_auto_auto] gap-x-2 text-xs font-medium leading-4 text-base-content/55"
      >
        <span>Expiration</span>
        <span>Seen</span>
        <span>Left</span>
      </div>
      <dl
        id={"#{@id}-list"}
        data-role="saved-reset-expiration-list"
        class="grid gap-1"
      >
        <div
          :for={row <- @rows}
          id={"#{@id}-row-#{row.index}"}
          data-role="saved-reset-expiration-row"
          class="grid grid-cols-[minmax(0,1fr)_auto_auto] items-baseline gap-x-2 border-t border-base-300/50 pt-1 first:border-t-0 first:pt-0"
        >
          <div class="min-w-0">
            <dt class="sr-only">Expiration Date</dt>
            <dd
              id={"#{@id}-date-#{row.index}"}
              data-role="saved-reset-expiration-date"
              class="truncate text-xs leading-4 text-base-content"
              title={row.expiration_date_title}
            >
              {row.expiration_date_label}
            </dd>
          </div>
          <div class="text-right">
            <dt class="sr-only">First Seen</dt>
            <dd
              id={"#{@id}-first-seen-#{row.index}"}
              data-role="saved-reset-expiration-first-seen"
              class="whitespace-nowrap text-xs leading-4 text-base-content/70"
              title={row.first_seen_title}
            >
              {row.first_seen_label}
            </dd>
          </div>
          <div class="text-right">
            <dt class="sr-only">Time Left</dt>
            <dd
              id={"#{@id}-time-left-#{row.index}"}
              data-role="saved-reset-expiration-time-left"
              class="inline-flex items-center justify-end gap-1 whitespace-nowrap text-xs leading-4 text-base-content/70"
            >
              <.icon name="hero-clock" class="size-3" />
              <span>{row.time_left_label}</span>
            </dd>
          </div>
        </div>
      </dl>
    </div>
    <div
      :if={@rows != [] and not @compact}
      id={@id}
      data-role="saved-reset-expiration-table-block"
      class="grid gap-2"
    >
      <div
        id={"#{@id}-cards"}
        data-role="saved-reset-expiration-card-list"
        class="grid gap-2 md:hidden"
      >
        <article
          :for={row <- @rows}
          id={"#{@id}-card-#{row.index}"}
          data-role="saved-reset-expiration-card"
          class="grid gap-3 rounded-box border border-base-300/70 bg-base-100/80 p-3"
        >
          <div class="flex min-w-0 items-start justify-between gap-3">
            <div class="grid min-w-0 gap-1">
              <p class="text-xs font-semibold text-base-content/55">Expiration</p>
              <p
                id={"#{@id}-card-date-#{row.index}"}
                class="truncate text-sm font-medium text-base-content"
                title={row.expiration_date_title}
              >
                {row.expiration_date_label}
              </p>
            </div>
          </div>
          <div class="grid grid-cols-2 gap-3">
            <div class="grid gap-1">
              <p class="text-xs font-semibold text-base-content/55">First seen</p>
              <p class="truncate text-xs text-base-content/70" title={row.first_seen_title}>
                {row.first_seen_label}
              </p>
            </div>
            <div class="grid gap-1 text-right">
              <p class="text-xs font-semibold text-base-content/55">Time left</p>
              <p class="inline-flex items-center justify-end gap-1 truncate text-xs text-base-content/70">
                <.icon name="hero-clock" class="size-3 shrink-0" />
                <span>{row.time_left_label}</span>
              </p>
            </div>
          </div>
        </article>
      </div>
      <div
        id={"#{@id}-scroll-region"}
        class="hidden overflow-x-auto rounded-box border border-base-300/70 bg-base-100/80 md:block"
      >
        <table
          id={"#{@id}-table"}
          data-role="saved-reset-expiration-table"
          class="w-full min-w-[38rem] border-collapse text-sm"
        >
          <thead class="bg-base-200/50">
            <tr>
              <th class="whitespace-nowrap px-3 py-2 text-left text-xs font-semibold text-base-content/55">
                Expiration Date
              </th>
              <th class="whitespace-nowrap px-3 py-2 text-right text-xs font-semibold text-base-content/55">
                First Seen
              </th>
              <th class="whitespace-nowrap px-3 py-2 text-right text-xs font-semibold text-base-content/55">
                Time Left
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300/60">
            <tr
              :for={row <- @rows}
              id={"#{@id}-row-#{row.index}"}
              data-role="saved-reset-expiration-row"
              class="transition-colors hover:bg-base-200/40"
            >
              <td
                id={"#{@id}-date-#{row.index}"}
                data-role="saved-reset-expiration-date"
                class="whitespace-nowrap px-3 py-2 text-xs text-base-content"
                title={row.expiration_date_title}
              >
                {row.expiration_date_label}
              </td>
              <td
                id={"#{@id}-first-seen-#{row.index}"}
                data-role="saved-reset-expiration-first-seen"
                class="whitespace-nowrap px-3 py-2 text-right text-xs text-base-content/70"
                title={row.first_seen_title}
              >
                {row.first_seen_label}
              </td>
              <td
                id={"#{@id}-time-left-#{row.index}"}
                data-role="saved-reset-expiration-time-left"
                class="whitespace-nowrap px-3 py-2 text-right text-xs text-base-content/70"
              >
                <span class="inline-flex items-center gap-1">
                  <.icon name="hero-clock" class="size-3 shrink-0" />
                  <span>{row.time_left_label}</span>
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
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
    |> Map.merge(first_seen_labels(first_seen_at, datetime_preferences))
  end

  defp available_expiration_row(
         %{"expires_at" => value, "first_seen_at" => first_seen_at},
         index,
         datetime_preferences,
         now
       ) do
    value
    |> expiration_row(index, datetime_preferences, now)
    |> Map.merge(first_seen_labels(first_seen_at, datetime_preferences))
  end

  defp available_expiration_row(_row, _index, _datetime_preferences, _now), do: nil

  defp expiration_row(value, index, datetime_preferences, now) do
    case ResetFormatting.parse_datetime(value) do
      %DateTime{} = expires_at ->
        expiration_date_label = DateTimeDisplay.format_datetime(expires_at, datetime_preferences)

        %{
          index: index,
          expiration_date_label: expiration_date_label,
          expiration_date_title: expiration_date_label,
          first_seen_label: "not recorded",
          first_seen_title: "not recorded",
          time_left_label: time_left_label(expires_at, now)
        }

      nil ->
        %{
          index: index,
          expiration_date_label: "unknown time",
          expiration_date_title: to_string(value),
          first_seen_label: "not recorded",
          first_seen_title: "not recorded",
          time_left_label: "unknown"
        }
    end
  end

  defp first_seen_labels(value, datetime_preferences) do
    case ResetFormatting.parse_datetime(value) do
      %DateTime{} = first_seen_at ->
        first_seen_label = DateTimeDisplay.format_datetime(first_seen_at, datetime_preferences)
        %{first_seen_label: first_seen_label, first_seen_title: first_seen_label}

      nil ->
        %{first_seen_label: "not recorded", first_seen_title: "not recorded"}
    end
  end

  defp time_left_label(%DateTime{} = expires_at, %DateTime{} = now) do
    seconds_until_expiration = DateTime.diff(expires_at, now, :second)

    if seconds_until_expiration > 0 do
      ResetFormatting.format_reset_duration(seconds_until_expiration)
    else
      "expired"
    end
  end
end
