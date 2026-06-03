defmodule CodexPoolerWeb.Admin.PoolListComponents do
  @moduledoc """
  Pool inventory, filter, action menu, delete dialog, and inspector shell components.
  """

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolForm
  alias CodexPoolerWeb.Admin.PoolInspectorComponents
  alias CodexPoolerWeb.Admin.PoolsReadModel

  alias Phoenix.LiveView.JS

  attr :deleting_pool, :any, default: nil
  attr :delete_form, Phoenix.HTML.Form, required: true
  attr :delete_form_version, :integer, required: true
  attr :pool_filter_form, Phoenix.HTML.Form, required: true
  attr :pools, :list, required: true
  attr :selected_pool_row, :any, default: nil
  attr :selected_pool_tab, :string, required: true
  attr :can_manage_pools?, :boolean, required: true
  attr :datetime_preferences, :map, required: true

  def pool_inventory(assigns) do
    ~H"""
    <.pool_delete_dialog
      deleting_pool={@deleting_pool}
      delete_form={@delete_form}
      delete_form_version={@delete_form_version}
    />

    <div id="pool-details-drawer-root" class="drawer drawer-end">
      <input
        id="pool-details-drawer"
        type="checkbox"
        class="drawer-toggle"
        checked={@selected_pool_row != nil}
      />

      <div class="drawer-content min-w-0">
        <section
          id="pool-inventory-surface"
          class="grid min-w-0 gap-4 overflow-visible"
        >
          <.pool_filter_form form={@pool_filter_form} />

          <AdminComponents.empty_state
            :if={@pools == []}
            id="pool-empty-state"
            title={if @can_manage_pools?, do: "No Pools Found", else: "No assigned Pools"}
            description={pool_empty_description(@can_manage_pools?)}
            icon="hero-server-stack"
          >
            <:actions>
              <AdminComponents.action_button
                :if={@can_manage_pools?}
                id="pool-empty-create-action"
                icon="hero-plus"
                label="Create Pool"
                phx-click="open_create_pool"
                variant={:primary}
              />
            </:actions>
          </AdminComponents.empty_state>

          <.pool_grid
            :if={@pools != []}
            pools={@pools}
            selected_pool_row={@selected_pool_row}
            can_manage_pools?={@can_manage_pools?}
          />
        </section>
      </div>

      <div class="drawer-side z-[70]">
        <label
          for="pool-details-drawer"
          aria-label="close Pool details"
          class="drawer-overlay"
          phx-click="close_pool_inspector"
        >
        </label>
        <PoolInspectorComponents.pool_inspector
          :if={@selected_pool_row}
          pool_row={@selected_pool_row}
          selected_tab={@selected_pool_tab}
          datetime_preferences={@datetime_preferences}
        />
      </div>
    </div>
    """
  end

  attr :deleting_pool, :any, default: nil
  attr :delete_form, Phoenix.HTML.Form, required: true
  attr :delete_form_version, :integer, required: true

  defp pool_delete_dialog(assigns) do
    ~H"""
    <dialog :if={@deleting_pool} id="pool-delete-dialog" class="modal" open>
      <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-error">Hard delete</p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Delete archived Pool</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            Hard deletion is available only for archived Pools and requires the exact slug confirmation.
          </p>
        </div>

        <.form
          id="pool-delete-form"
          for={@delete_form}
          phx-submit="confirm_delete_pool"
          autocomplete="off"
          class="grid gap-5 p-6"
        >
          <.input field={@delete_form[:id]} type="hidden" />
          <div class="alert alert-warning items-start">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <div class="grid gap-1">
              <p class="font-semibold">This removes {@deleting_pool.name} permanently.</p>
              <p class="text-sm">
                Type <span class="break-all font-semibold">{@deleting_pool.slug}</span> to confirm.
              </p>
            </div>
          </div>
          <.input
            field={@delete_form[:confirmation_slug]}
            id={"pool_delete_confirmation_slug_#{@delete_form_version}"}
            type="text"
            label="Confirm slug"
            placeholder={@deleting_pool.slug}
            required
          />
          <div class="modal-action mt-0">
            <AdminComponents.action_button
              id="pool-delete-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_delete"
            />
            <AdminComponents.action_button
              id="pool-delete-submit"
              icon="hero-trash"
              label="Delete Pool"
              type="submit"
              variant={:danger}
              phx-click={
                JS.dispatch("blur", to: "#pool_delete_confirmation_slug_#{@delete_form_version}")
              }
              disabled={@deleting_pool.status != "archived"}
            />
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_delete">close</button>
      </form>
    </dialog>
    """
  end

  defp pool_empty_description(true),
    do: "Create the first Pool before connecting upstreams or issuing API keys."

  defp pool_empty_description(false),
    do: "Ask an instance owner to assign you to a Pool before managing Pool-scoped resources."

  attr :form, Phoenix.HTML.Form, required: true

  defp pool_filter_form(assigns) do
    ~H"""
    <AdminComponents.filter_form
      id="pool-filter-form"
      for={@form}
      phx-change="filter_pools"
      phx-submit="filter_pools"
      autocomplete="off"
    >
      <.pool_query_filter_input field={@form[:query]} />
      <.pool_status_filter_dropdown
        selected_value={@form[:status].value}
        selected={selected_pool_status_filter_option(@form[:status].value)}
      />
    </AdminComponents.filter_form>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp pool_query_filter_input(assigns) do
    assigns = assign(assigns, :value, pool_query_filter_value(assigns.field))

    ~H"""
    <div class="grid gap-2">
      <label for={@field.id} class="sr-only">Search</label>
      <div class="input input-bordered flex min-h-10 w-full items-center gap-2">
        <input
          id={@field.id}
          name={@field.name}
          type="text"
          value={@value}
          placeholder="Search pools..."
          class="peer grow text-sm font-normal"
        />
        <button
          id="pool-filter-query-clear"
          type="button"
          class="grid size-6 shrink-0 place-items-center rounded-full text-base-content/50 transition-colors hover:bg-base-200 hover:text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary peer-placeholder-shown:hidden"
          phx-click="clear_pool_query_filter"
          aria-label="Clear pool search"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :selected_value, :string, required: true
  attr :selected, :map, required: true

  defp pool_status_filter_dropdown(assigns) do
    ~H"""
    <div class="grid gap-2">
      <label for="pool-status-filter" class="sr-only">Status</label>
      <input
        type="hidden"
        id="pool_filters_status"
        name="pool_filters[status]"
        value={@selected_value}
      />
      <details
        id="pool-status-filter"
        class="dropdown w-full"
        phx-click-away={JS.remove_attribute("open", to: "#pool-status-filter")}
      >
        <summary
          data-role="status-filter-trigger"
          class="select select-bordered flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal"
        >
          <.icon name={@selected.icon} class={["size-4 shrink-0", @selected.icon_class]} />
          <span class="truncate">{@selected.label}</span>
        </summary>
        <ul
          data-role="status-filter-menu"
          class="menu dropdown-content z-[60] mt-1 max-h-80 w-full flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 !transition-none ![scale:100%] shadow-xl"
        >
          <li :for={option <- pool_status_filter_options()}>
            <button
              type="button"
              phx-click="select_pool_status_filter"
              phx-value-status={option.value}
              data-role="status-filter-option"
              data-status={option.value}
              class={[
                "flex items-center gap-2 text-sm",
                option.value == @selected_value && "active"
              ]}
              aria-current={option.value == @selected_value && "true"}
            >
              <span data-role="status-filter-icon" class="shrink-0">
                <.icon name={option.icon} class={["size-4", option.icon_class]} />
              </span>
              <span class="truncate">{option.label}</span>
            </button>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  defp selected_pool_status_filter_option(status) do
    Enum.find(pool_status_filter_options(), &(&1.value == status)) ||
      all_pool_status_filter_option()
  end

  defp pool_status_filter_options do
    [
      all_pool_status_filter_option(),
      %{
        label: "Active",
        value: "active",
        icon: "hero-check-circle",
        icon_class: "text-success"
      },
      %{
        label: "Disabled",
        value: "disabled",
        icon: "hero-pause-circle",
        icon_class: "text-warning"
      },
      %{
        label: "Archived",
        value: "archived",
        icon: "hero-archive-box",
        icon_class: "text-error"
      }
    ]
  end

  defp all_pool_status_filter_option do
    %{
      label: "Status: All",
      value: "all",
      icon: "hero-server-stack",
      icon_class: "text-base-content/60"
    }
  end

  defp pool_query_filter_value(%{value: value}) when is_binary(value), do: value
  defp pool_query_filter_value(_field), do: ""

  attr :pools, :list, required: true
  attr :selected_pool_row, :any, default: nil
  attr :can_manage_pools?, :boolean, required: true

  defp pool_grid(assigns) do
    ~H"""
    <div
      id="pools-grid"
      class="grid min-w-0 gap-3 overflow-visible lg:grid-cols-2 2xl:grid-cols-3 [@media(width>=112rem)]:grid-cols-4"
    >
      <.pool_card
        :for={pool_row <- @pools}
        pool_row={pool_row}
        selected_pool_row={@selected_pool_row}
        can_manage_pools?={@can_manage_pools?}
      />
    </div>
    """
  end

  attr :pool_row, :map, required: true
  attr :selected_pool_row, :any, default: nil
  attr :can_manage_pools?, :boolean, required: true

  defp pool_card(assigns) do
    ~H"""
    <article
      id={"pool-row-#{@pool_row.pool.id}"}
      class={[
        "pool-redesign-audit",
        @selected_pool_row && @selected_pool_row.pool.id == @pool_row.pool.id && "is-selected"
      ]}
    >
      <div class="audit-row audit-row-v2">
        <div class="audit-command-line">
          <div class="audit-identity">
            <button
              id={"inspect-pool-#{@pool_row.pool.id}"}
              type="button"
              class="audit-name text-left text-base-content transition-colors hover:text-primary"
              phx-click="select_pool"
              phx-value-id={@pool_row.pool.id}
            >
              {@pool_row.pool.name}
            </button>
            <p id={"pool-row-#{@pool_row.pool.id}-id"} class="audit-id">
              {@pool_row.pool.id}
            </p>
          </div>
          <div class="audit-states">
            <span
              id={"pool-row-#{@pool_row.pool.id}-status"}
              class={AdminBadges.lifecycle_chip_class(@pool_row.pool.status)}
            >
              {@pool_row.pool.status}
            </span>
            <span
              id={"pool-row-#{@pool_row.pool.id}-routing-strategy"}
              class={routing_strategy_class()}
            >
              {AdminBadges.routing_strategy_label(@pool_row.routing_strategy)}
            </span>
          </div>
          <.pool_action_menu pool_row={@pool_row} can_manage_pools?={@can_manage_pools?} />
        </div>
      </div>
      <.pool_activity_panel pool_row={@pool_row} />
      <footer
        class="pool-card-metrics border-t border-base-300 bg-base-200/20 px-4 py-2.5"
        data-role="pool-card-metrics"
      >
        <dl class="grid min-w-0 grid-cols-4 divide-x divide-base-300/70 text-xs leading-5">
          <div class="min-w-0 pr-3" data-role="pool-upstream-count-cell">
            <dt class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/35">
              Upstreams
            </dt>
            <dd
              id={"pool-row-#{@pool_row.pool.id}-upstream-account-count"}
              class="truncate text-base-content/60"
            >
              {@pool_row.upstream_count}
            </dd>
          </div>
          <div class="min-w-0 px-3" data-role="pool-api-key-count-cell">
            <dt class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/35">
              Keys
            </dt>
            <dd
              id={"pool-row-#{@pool_row.pool.id}-api-key-count"}
              class="truncate text-base-content/60"
            >
              {@pool_row.api_key_count}
            </dd>
          </div>
          <div class="min-w-0 px-3" data-role="pool-request-count-cell">
            <dt class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/35">
              Requests
            </dt>
            <dd
              id={"pool-row-#{@pool_row.pool.id}-request-count-5h"}
              class="truncate text-base-content/60"
            >
              {PoolsReadModel.format_metric_integer(@pool_row.request_count_5h)}
            </dd>
          </div>
          <div class="min-w-0 pl-3" data-role="pool-tps-cell">
            <dt class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/35">
              TPS
            </dt>
            <dd
              id={"pool-row-#{@pool_row.pool.id}-tokens-per-sec"}
              class="truncate text-base-content/60"
            >
              {PoolsReadModel.format_metric_float(@pool_row.tokens_per_second)}
            </dd>
          </div>
        </dl>
      </footer>
    </article>
    """
  end

  attr :pool_row, :map, required: true

  defp pool_activity_panel(assigns) do
    assigns =
      assign(assigns, :traffic_histogram_card, pool_traffic_histogram_card(assigns.pool_row))

    ~H"""
    <div
      id={"pool-row-#{@pool_row.pool.id}-activity"}
      data-role="pool-activity-panel"
      class="pool-activity-panel"
    >
      <section
        id={"pool-row-#{@pool_row.pool.id}-traffic-histogram"}
        data-role="pool-traffic-histogram"
        class="pool-token-histogram"
      >
        <div class="pool-token-histogram-header">
          <div class="grid gap-1">
            <h3>{@traffic_histogram_card.title}</h3>
            <p>{@traffic_histogram_card.description}</p>
          </div>
          <span id={"pool-row-#{@pool_row.pool.id}-traffic-histogram-total"}>
            {@traffic_histogram_card.total_label}
          </span>
        </div>
        <div
          :if={!@traffic_histogram_card.empty?}
          id={"pool-row-#{@pool_row.pool.id}-traffic-histogram-plot"}
          class="pool-token-histogram-plot admin-apex-bar-chart"
          phx-hook="ApexTimeSeriesChart"
          phx-update="ignore"
          role="img"
          aria-label={@traffic_histogram_card.aria_label}
          data-chart-categories={@traffic_histogram_card.categories}
          data-chart-series={@traffic_histogram_card.series}
          data-chart-units={@traffic_histogram_card.units}
          data-chart-yaxis={@traffic_histogram_card.yaxis}
          data-chart-height="84"
          data-chart-colors={@traffic_histogram_card.colors}
          data-chart-compact="true"
        >
        </div>
        <div
          :if={@traffic_histogram_card.empty?}
          class="pool-activity-empty-state"
          data-role="pool-traffic-empty-state"
        >
          <span class="pool-activity-empty-state-icon" aria-hidden="true">
            <.icon name="hero-chart-bar" class="size-4" />
          </span>
          <p class="pool-activity-empty-copy">No traffic in the last 24h</p>
        </div>
        <ul class="sr-only">
          <li :for={point <- @traffic_histogram_card.points}>
            {point.label}: {point.tokens} tokens, {point.requests} requests
          </li>
        </ul>
      </section>
    </div>
    """
  end

  attr :pool_row, :map, required: true
  attr :can_manage_pools?, :boolean, required: true

  defp pool_action_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end shrink-0">
      <button
        id={"pool-actions-menu-#{@pool_row.pool.id}"}
        type="button"
        class="btn btn-ghost btn-sm btn-square"
        tabindex="0"
        aria-label={"Actions for #{@pool_row.pool.name}"}
      >
        <.icon name="hero-ellipsis-vertical" class="size-5" />
      </button>
      <ul
        tabindex="0"
        class="menu dropdown-content z-20 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-xl"
      >
        <li>
          <AdminComponents.dropdown_action_item
            id={"edit-pool-#{@pool_row.pool.id}"}
            icon="hero-pencil-square"
            label="Edit"
            phx-click="edit_pool"
            phx-value-id={@pool_row.pool.id}
            disabled={!@can_manage_pools?}
          />
        </li>
        <li>
          <AdminComponents.dropdown_action_item
            id={"delete-pool-#{@pool_row.pool.id}"}
            icon="hero-trash"
            label="Delete"
            variant={:danger}
            phx-click="delete_pool"
            phx-value-id={@pool_row.pool.id}
            disabled={!@can_manage_pools? || @pool_row.pool.status != "archived"}
            title={PoolForm.delete_title(@pool_row.pool)}
          />
        </li>
      </ul>
    </div>
    """
  end

  defp routing_strategy_class do
    "#{AdminBadges.metadata_chip_class(:neutral)} whitespace-nowrap"
  end

  defp pool_traffic_histogram_card(pool_row) do
    token_points =
      Map.get(pool_row, :token_histogram_24h, [])

    request_points =
      pool_row
      |> Map.get(:request_histogram_24h, [])
      |> Map.new(fn point -> {Map.get(point, :bucket), max(Map.get(point, :requests, 0), 0)} end)

    points =
      Enum.map(token_points, fn point ->
        bucket = Map.get(point, :bucket)

        %{
          label: format_chart_bucket(bucket),
          tokens: max(Map.get(point, :total_tokens, 0), 0),
          requests: Map.get(request_points, bucket, 0)
        }
      end)

    token_values = Enum.map(points, & &1.tokens)
    request_values = Enum.map(points, & &1.requests)
    token_total = Enum.sum(token_values)
    request_total = Enum.sum(request_values)

    %{
      title: "Traffic 24h",
      description: "Tokens and requests by hour",
      total_label:
        "#{format_token_count(token_total)} tokens / #{format_request_count(request_total)}",
      categories: Jason.encode!(Enum.map(points, & &1.label)),
      series:
        Jason.encode!([
          %{name: "Tokens", type: "column", data: token_values},
          %{name: "Requests", type: "line", data: request_values}
        ]),
      units: Jason.encode!(["tokens", "requests"]),
      yaxis:
        Jason.encode!([
          %{seriesName: "Tokens", title: "tokens"},
          %{seriesName: "Requests", title: "requests", opposite: true}
        ]),
      colors: Jason.encode!(["var(--color-primary)", "var(--color-info)"]),
      points: points,
      empty?: token_total == 0 and request_total == 0,
      aria_label:
        "Traffic in the last 24 hours: #{format_token_count(token_total)} tokens and #{format_request_count(request_total)}"
    }
  end

  defp format_chart_bucket(<<_date::binary-size(10), "T", hour::binary-size(2), ":00:00Z">>),
    do: hour <> ":00"

  defp format_chart_bucket(bucket), do: to_string(bucket)

  defp format_token_count(value) when is_integer(value), do: format_integer(value)
  defp format_token_count(value) when is_float(value), do: value |> round() |> format_integer()

  defp format_request_count(1), do: "1 request"
  defp format_request_count(value) when is_integer(value), do: "#{format_integer(value)} requests"

  defp format_request_count(value) when is_float(value),
    do: value |> round() |> format_request_count()

  defp format_integer(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(",", &Enum.join/1)
  end
end
