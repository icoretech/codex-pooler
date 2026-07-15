defmodule CodexPoolerWeb.Admin.PoolListComponents do
  @moduledoc """
  Pool inventory, filter, action menu, and delete dialog components.
  """

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.Format
  alias CodexPoolerWeb.Admin.PoolForm
  alias CodexPoolerWeb.Admin.PoolsReadModel

  alias Phoenix.LiveView.JS

  attr :deleting_pool, :any, default: nil
  attr :delete_form, Phoenix.HTML.Form, required: true
  attr :delete_form_version, :integer, required: true
  attr :pool_filter_form, Phoenix.HTML.Form, required: true
  attr :pools, :list, required: true
  attr :can_manage_pools?, :boolean, required: true
  attr :compat_panel_views, :map, default: %{}

  def pool_inventory(assigns) do
    ~H"""
    <.pool_delete_dialog
      deleting_pool={@deleting_pool}
      delete_form={@delete_form}
      delete_form_version={@delete_form_version}
    />

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
        can_manage_pools?={@can_manage_pools?}
        compat_panel_views={@compat_panel_views}
      />
    </section>
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
      <.pool_traffic_window_filter_dropdown
        selected_value={@form[:traffic_window].value}
        selected={selected_pool_traffic_window_filter_option(@form[:traffic_window].value)}
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

  attr :selected_value, :string, required: true
  attr :selected, :map, required: true

  defp pool_traffic_window_filter_dropdown(assigns) do
    ~H"""
    <div class="grid gap-2">
      <label for="pool-traffic-window-filter" class="sr-only">Traffic window</label>
      <input
        type="hidden"
        id="pool_filters_traffic_window"
        name="pool_filters[traffic_window]"
        value={@selected_value}
      />
      <details
        id="pool-traffic-window-filter"
        class="dropdown w-full"
        phx-click-away={JS.remove_attribute("open", to: "#pool-traffic-window-filter")}
      >
        <summary
          data-role="traffic-window-filter-trigger"
          class="select select-bordered flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal"
        >
          <.icon name="hero-clock" class="size-4 shrink-0 text-base-content/60" />
          <span class="truncate">{@selected.label}</span>
        </summary>
        <ul
          data-role="traffic-window-filter-menu"
          class="menu dropdown-content z-[60] mt-1 max-h-80 w-full flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 !transition-none ![scale:100%] shadow-xl"
        >
          <li :for={option <- pool_traffic_window_filter_options()}>
            <button
              type="button"
              phx-click="select_pool_traffic_window_filter"
              phx-value-window={option.value}
              data-role="traffic-window-filter-option"
              data-window={option.value}
              class={[
                "flex items-center gap-2 text-sm",
                option.value == @selected_value && "active"
              ]}
              aria-current={option.value == @selected_value && "true"}
            >
              <.icon name="hero-clock" class="size-4 shrink-0 text-base-content/50" />
              <span class="truncate">{option.label}</span>
            </button>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  defp selected_pool_traffic_window_filter_option(window) do
    Enum.find(pool_traffic_window_filter_options(), &(&1.value == window)) ||
      default_pool_traffic_window_filter_option()
  end

  defp pool_traffic_window_filter_options do
    Enum.map(PoolForm.traffic_window_options(), fn {label, value} ->
      %{label: label, value: value}
    end)
  end

  defp default_pool_traffic_window_filter_option do
    %{label: "Traffic: Last 24 hours", value: "24h"}
  end

  defp pool_query_filter_value(%{value: value}) when is_binary(value), do: value
  defp pool_query_filter_value(_field), do: ""

  attr :pools, :list, required: true
  attr :can_manage_pools?, :boolean, required: true
  attr :compat_panel_views, :map, required: true

  defp pool_grid(assigns) do
    ~H"""
    <div
      id="pools-grid"
      class="grid min-w-0 gap-3 overflow-visible lg:grid-cols-2 2xl:grid-cols-3 [@media(width>=112rem)]:grid-cols-4"
    >
      <.pool_card
        :for={pool_row <- @pools}
        pool_row={pool_row}
        can_manage_pools?={@can_manage_pools?}
        compat_panel_flag={compat_panel_flag(@compat_panel_views, pool_row)}
      />
    </div>
    """
  end

  attr :pool_row, :map, required: true
  attr :can_manage_pools?, :boolean, required: true
  attr :compat_panel_flag, :any, default: nil

  defp pool_card(assigns) do
    ~H"""
    <article id={"pool-row-#{@pool_row.pool.id}"} class="pool-card">
      <div class="min-w-0">
        <div class="pool-card-header">
          <div class="pool-card-header-row">
            <div class="pool-card-identity">
              <div id={"pool-row-#{@pool_row.pool.id}-title-line"} class="pool-card-title-line">
                <h2
                  id={"pool-row-#{@pool_row.pool.id}-name"}
                  class="pool-card-title text-base-content"
                >
                  {@pool_row.pool.name}
                </h2>
              </div>
              <p
                id={"pool-row-#{@pool_row.pool.id}-routing-strategy"}
                class="truncate text-xs leading-4 text-base-content/55"
              >
                {AdminBadges.routing_strategy_label(@pool_row.routing_strategy)}
              </p>
            </div>
            <div id={"pool-row-#{@pool_row.pool.id}-actions"} class="pool-card-actions">
              <.pool_compat_flag_icons pool_row={@pool_row} open_flag={@compat_panel_flag} />
              <span
                id={"pool-row-#{@pool_row.pool.id}-status"}
                class={AdminBadges.lifecycle_chip_class(@pool_row.pool.status)}
              >
                {@pool_row.pool.status}
              </span>
              <.pool_action_menu pool_row={@pool_row} can_manage_pools?={@can_manage_pools?} />
            </div>
          </div>
        </div>
        <.pool_compat_flag_panel
          :if={@compat_panel_flag}
          pool_row={@pool_row}
          flag={@compat_panel_flag}
          enabled={@pool_row.compat_flags[@compat_panel_flag.key] == true}
          can_manage_pools?={@can_manage_pools?}
        />
      </div>
      <.pool_activity_panel pool_row={@pool_row} />
      <footer
        class="pool-card-metrics border-t border-base-300 bg-base-200/20 px-4 py-2.5"
        data-role="pool-card-metrics"
      >
        <dl class="grid min-w-0 grid-cols-2 gap-y-2 text-xs leading-5 sm:grid-cols-4 sm:divide-x sm:divide-base-300/70 sm:gap-y-0">
          <.pool_metric_link
            data_role="pool-upstream-count-cell"
            href={~p"/admin/upstreams?pool_id=#{@pool_row.pool.id}"}
            label="Upstreams"
            value={@pool_row.upstream_count}
            value_id={"pool-row-#{@pool_row.pool.id}-upstream-account-count"}
            wrapper_class="min-w-0 pr-3"
            position={:first}
          />
          <.pool_metric_link
            data_role="pool-api-key-count-cell"
            href={~p"/admin/api-keys?pool_id=#{@pool_row.pool.id}"}
            label="API keys"
            value={@pool_row.api_key_count}
            value_id={"pool-row-#{@pool_row.pool.id}-api-key-count"}
            wrapper_class="min-w-0 pl-3 sm:px-3"
          />
          <.pool_metric_link
            data_role="pool-request-count-cell"
            href={~p"/admin/request-logs?pool_id=#{@pool_row.pool.id}"}
            label={"Req/TPS #{@pool_row.traffic_window_label}"}
            value={
              PoolsReadModel.format_request_throughput(
                @pool_row.request_count,
                @pool_row.tokens_per_second
              )
            }
            value_id={"pool-row-#{@pool_row.pool.id}-request-throughput"}
            wrapper_class="min-w-0 pr-3 sm:px-3"
          >
            <span id={"pool-row-#{@pool_row.pool.id}-request-count"}>
              {PoolsReadModel.format_metric_integer(@pool_row.request_count)}
            </span>
            <span aria-hidden="true"> / </span>
            <span id={"pool-row-#{@pool_row.pool.id}-tokens-per-sec"}>
              {PoolsReadModel.format_metric_rate(@pool_row.tokens_per_second)}
            </span>
          </.pool_metric_link>
          <.pool_metric_link
            data_role="pool-cost-cell"
            href={~p"/admin/stats?pool_id=#{@pool_row.pool.id}"}
            label={"Cost #{@pool_row.traffic_window_label}"}
            value={PoolsReadModel.format_settled_cost_micros(@pool_row.settled_cost_micros)}
            value_id={"pool-row-#{@pool_row.pool.id}-settled-cost"}
            wrapper_class="min-w-0 pl-3"
            position={:last}
          />
        </dl>
      </footer>
    </article>
    """
  end

  attr :data_role, :string, required: true
  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :value_id, :string, required: true
  attr :wrapper_class, :string, required: true
  attr :position, :atom, default: :middle, values: [:first, :middle, :last]
  slot :inner_block

  defp pool_metric_link(assigns) do
    ~H"""
    <div class={["group relative isolate", @wrapper_class]} data-role={@data_role}>
      <dt class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/35 transition-colors group-hover:text-primary/70">
        <.link
          navigate={@href}
          class={footer_metric_link_class(@position)}
          aria-label={"Open #{@label}"}
        >
          <span class="sr-only">{@label}</span>
        </.link>
        <span class="pointer-events-none relative z-30 block max-w-full truncate text-left uppercase">
          {@label}
        </span>
      </dt>
      <dd
        id={@value_id}
        class="pointer-events-none relative z-30 truncate text-base-content/60 transition-colors group-hover:text-base-content/75"
      >
        <%= if @inner_block != [] do %>
          {render_slot(@inner_block)}
        <% else %>
          {@value}
        <% end %>
      </dd>
    </div>
    """
  end

  # Mirrors the upstream card footer triggers: the link overlays the whole
  # cell with a soft primary wash on hover while the visible text sits above
  # it. The cells carry asymmetric divider padding, so each position needs its
  # own horizontal insets to read symmetric against dividers and card edges.
  defp footer_metric_link_class(position) do
    [
      "absolute -inset-y-1.5 z-20 cursor-pointer rounded border border-transparent transition-colors",
      "hover:border-primary/25 hover:bg-primary/5 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
      footer_metric_link_position_class(position)
    ]
  end

  defp footer_metric_link_position_class(:first), do: "-left-3 right-1"
  defp footer_metric_link_position_class(:middle), do: "left-1 right-1"
  defp footer_metric_link_position_class(:last), do: "left-1 -right-3"

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
            <h3>
              <span class="pool-token-histogram-label">Traffic</span>
              <span class="pool-token-histogram-value">
                {@traffic_histogram_card.window_label}
              </span>
            </h3>
          </div>
          <span
            id={"pool-row-#{@pool_row.pool.id}-traffic-histogram-total"}
            class="pool-token-histogram-total"
          >
            <span class="pool-token-histogram-value">
              {@traffic_histogram_card.token_total_label}
            </span>
            <span class="pool-token-histogram-label"> tokens</span>
            <span aria-hidden="true"> / </span>
            <span class="pool-token-histogram-value">
              {@traffic_histogram_card.request_total_label}
            </span>
            <span class="pool-token-histogram-label">
              {" " <> @traffic_histogram_card.request_total_unit}
            </span>
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
          data-chart-legend="false"
        >
        </div>
        <div
          :if={@traffic_histogram_card.empty?}
          class="pool-activity-empty-state"
          data-role="pool-traffic-empty-state"
        >
          <span
            class="pool-activity-empty-state-icon"
            data-role="pool-traffic-empty-icon"
            aria-hidden="true"
          >
            <.icon name="hero-chart-bar" class="size-4" />
          </span>
          <p class="pool-activity-empty-copy">
            No traffic in the last {@traffic_histogram_card.window_label}
          </p>
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
            id={"copy-pool-id-#{@pool_row.pool.id}"}
            icon="hero-clipboard-document"
            label="Copy Pool ID"
            copy_feedback?={true}
            phx-hook="ClipboardCopy"
            phx-update="ignore"
            data-copy-text={@pool_row.pool.id}
            data-copy-label="Copy Pool ID"
            data-copied-label="Copied"
            aria-label={"Copy ID for #{@pool_row.pool.name}"}
          />
        </li>
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

  @compat_flags [
    %{
      key: :v1_compatibility_enabled,
      id_suffix: "v1",
      icon: "hero-code-bracket",
      label: "/v1 compatibility",
      description: "OpenAI-style /v1 compatibility routes."
    },
    %{
      key: :request_compression_enabled,
      id_suffix: "compression",
      icon: "hero-arrows-pointing-in",
      label: "Request compression",
      description: "Shrinks eligible Responses tool outputs before upstream dispatch."
    },
    %{
      key: :upstream_websocket_bridge_enabled,
      id_suffix: "ws-bridge",
      icon: "hero-link",
      label: "Upstream websocket bridge",
      description:
        "Carries public streaming turns upstream over the session's Codex websocket to reuse the provider prompt cache."
    }
  ]

  attr :pool_row, :map, required: true
  attr :open_flag, :any, default: nil

  defp pool_compat_flag_icons(assigns) do
    assigns = assign(assigns, :flags, @compat_flags)

    ~H"""
    <span class="flex shrink-0 items-center gap-px" data-role="pool-compat-flags">
      <button
        :for={flag <- @flags}
        id={"pool-row-#{@pool_row.pool.id}-compat-#{flag.id_suffix}"}
        type="button"
        phx-click="toggle_pool_compat_panel"
        phx-value-pool-id={@pool_row.pool.id}
        phx-value-flag={Atom.to_string(flag.key)}
        aria-expanded={to_string(open_flag?(@open_flag, flag))}
        aria-controls={"pool-row-#{@pool_row.pool.id}-compat-panel"}
        aria-label={compat_flag_state_label(@pool_row, flag)}
        title={compat_flag_state_label(@pool_row, flag)}
        class={compat_flag_trigger_class(@pool_row, flag, @open_flag)}
      >
        <.icon name={flag.icon} class="size-3.5" />
      </button>
    </span>
    """
  end

  attr :pool_row, :map, required: true
  attr :flag, :map, required: true
  attr :enabled, :boolean, required: true
  attr :can_manage_pools?, :boolean, required: true

  defp pool_compat_flag_panel(assigns) do
    ~H"""
    <div
      id={"pool-row-#{@pool_row.pool.id}-compat-panel"}
      data-role="pool-compat-panel"
      class="pool-compat-panel"
    >
      <div class="flex items-center justify-between gap-3">
        <p class="min-w-0 truncate text-sm font-semibold leading-5 text-base-content">
          {@flag.label}
        </p>
        <input
          :if={@can_manage_pools?}
          id={"pool-row-#{@pool_row.pool.id}-compat-#{@flag.id_suffix}-toggle"}
          type="checkbox"
          class="toggle toggle-sm shrink-0"
          checked={@enabled}
          phx-click="toggle_pool_compat_flag"
          phx-value-pool-id={@pool_row.pool.id}
          phx-value-flag={Atom.to_string(@flag.key)}
          aria-label={"Toggle #{@flag.label} for #{@pool_row.pool.name}"}
        />
        <span
          :if={!@can_manage_pools?}
          class={AdminBadges.metadata_chip_class(if(@enabled, do: :success, else: :neutral))}
        >
          {if @enabled, do: "Enabled", else: "Disabled"}
        </span>
      </div>
      <p class="mt-1 text-xs leading-5 text-base-content/60">
        {@flag.description}
      </p>
    </div>
    """
  end

  defp compat_panel_flag(panel_views, %{pool: %{id: pool_id}}) when is_map(panel_views) do
    case Map.get(panel_views, pool_id) do
      nil -> nil
      flag_key -> Enum.find(@compat_flags, &(Atom.to_string(&1.key) == flag_key))
    end
  end

  defp compat_panel_flag(_panel_views, _pool_row), do: nil

  defp open_flag?(%{key: open_key}, %{key: key}), do: open_key == key
  defp open_flag?(_open_flag, _flag), do: false

  defp compat_flag_enabled?(pool_row, flag), do: pool_row.compat_flags[flag.key] == true

  defp compat_flag_state_label(pool_row, flag) do
    state = if compat_flag_enabled?(pool_row, flag), do: "enabled", else: "disabled"
    "#{flag.label}: #{state}"
  end

  defp compat_flag_trigger_class(pool_row, flag, open_flag) do
    [
      "inline-flex size-7 cursor-pointer items-center justify-center rounded-field transition-colors",
      "hover:bg-base-300/60 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
      if(compat_flag_enabled?(pool_row, flag),
        do: "text-base-content/70 hover:text-base-content",
        else: "text-base-content/25 hover:text-base-content/45"
      ),
      open_flag?(open_flag, flag) && "bg-base-300/60"
    ]
  end

  defp pool_traffic_histogram_card(pool_row) do
    window_label = Map.get(pool_row, :traffic_window_label, "24h")

    token_points =
      Map.get(pool_row, :token_histogram, [])

    request_points =
      pool_row
      |> Map.get(:request_histogram, [])
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
      title: "Traffic #{window_label}",
      window_label: window_label,
      token_total_label: Format.token_count(token_total),
      request_total_label: format_integer(request_total),
      request_total_unit: request_total_unit(request_total),
      total_label:
        "#{Format.token_count(token_total)} tokens / #{format_request_count(request_total)}",
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
        "Traffic in the last #{window_label}: #{Format.token_count(token_total)} tokens and #{format_request_count(request_total)}"
    }
  end

  defp format_chart_bucket(<<_date::binary-size(10), "T", hour::binary-size(2), ":00:00Z">>),
    do: hour <> ":00"

  defp format_chart_bucket(bucket), do: to_string(bucket)

  defp request_total_unit(1), do: "request"
  defp request_total_unit(_value), do: "requests"

  defp format_request_count(1), do: "1 request"
  defp format_request_count(value) when is_integer(value), do: "#{format_integer(value)} requests"

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
