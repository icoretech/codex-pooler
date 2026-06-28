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
        class="grid grid-cols-[minmax(0,1fr)_auto] gap-x-2 text-xs font-medium leading-4 text-base-content/55"
      >
        <span>Expiration</span>
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
          class="grid grid-cols-[minmax(0,1fr)_auto] items-baseline gap-x-2 border-t border-base-300/50 pt-1 first:border-t-0 first:pt-0"
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
        id={"#{@id}-scroll-region"}
        class="overflow-x-auto rounded-box border border-base-300 bg-base-100"
      >
        <table
          id={"#{@id}-table"}
          data-role="saved-reset-expiration-table"
          class="table table-sm w-full"
        >
          <thead>
            <tr>
              <th class="whitespace-nowrap text-xs font-semibold text-base-content/55">
                Expiration Date
              </th>
              <th class="whitespace-nowrap text-right text-xs font-semibold text-base-content/55">
                Time Left
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @rows}
              id={"#{@id}-row-#{row.index}"}
              data-role="saved-reset-expiration-row"
            >
              <td
                id={"#{@id}-date-#{row.index}"}
                data-role="saved-reset-expiration-date"
                class="whitespace-nowrap text-xs text-base-content"
                title={row.expiration_date_title}
              >
                {row.expiration_date_label}
              </td>
              <td
                id={"#{@id}-time-left-#{row.index}"}
                data-role="saved-reset-expiration-time-left"
                class="whitespace-nowrap text-right text-xs text-base-content/70"
              >
                {row.time_left_label}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp expiration_rows(saved_resets, datetime_preferences, now) do
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

  defp expiration_row(value, index, datetime_preferences, now) do
    case ResetFormatting.parse_datetime(value) do
      %DateTime{} = expires_at ->
        expiration_date_label = DateTimeDisplay.format_datetime(expires_at, datetime_preferences)

        %{
          index: index,
          expiration_date_label: expiration_date_label,
          expiration_date_title: expiration_date_label,
          time_left_label: time_left_label(expires_at, now)
        }

      nil ->
        %{
          index: index,
          expiration_date_label: "unknown time",
          expiration_date_title: to_string(value),
          time_left_label: "unknown"
        }
    end
  end

  defp time_left_label(%DateTime{} = expires_at, %DateTime{} = now) do
    seconds_until_expiration = DateTime.diff(expires_at, now, :second)

    if seconds_until_expiration > 0 do
      "in #{ResetFormatting.format_reset_duration(seconds_until_expiration)}"
    else
      "expired"
    end
  end
end
