defmodule CodexPoolerWeb.Admin.Components.Shell do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.OperatorComponents

  @admin_nav_items [
    %{
      key: :pools,
      id: "admin-nav-pools",
      label: "Pools",
      path: "/admin/pools",
      icon: "hero-server-stack"
    },
    %{
      key: :upstreams,
      id: "admin-nav-upstreams",
      label: "Upstreams",
      path: "/admin/upstreams",
      icon: "hero-cloud-arrow-up"
    },
    %{
      key: :api_keys,
      id: "admin-nav-api-keys",
      label: "API keys",
      path: "/admin/api-keys",
      icon: "hero-key"
    },
    %{
      key: :stats,
      id: "admin-nav-stats",
      label: "Stats",
      path: "/admin/stats",
      icon: "hero-chart-pie"
    },
    %{
      key: :operators,
      id: "admin-nav-operators",
      label: "Operators",
      path: "/admin/operators",
      icon: "hero-users"
    },
    %{
      key: :invites,
      id: "admin-nav-invites",
      label: "Invites",
      path: "/admin/invites",
      icon: "hero-envelope"
    },
    %{
      key: :request_logs,
      id: "admin-nav-request-logs",
      label: "Request logs",
      path: "/admin/request-logs",
      icon: "hero-chat-bubble-bottom-center-text"
    },
    %{
      key: :audit_logs,
      id: "admin-nav-audit-logs",
      label: "Audit logs",
      path: "/admin/audit-logs",
      icon: "hero-finger-print"
    },
    %{
      key: :jobs,
      id: "admin-nav-jobs",
      label: "System Jobs",
      path: "/admin/jobs",
      icon: "hero-clock"
    },
    %{
      key: :system,
      id: "admin-nav-system",
      label: "System Settings",
      path: "/admin/system",
      icon: "hero-adjustments-horizontal"
    }
  ]

  @admin_footer_nav_items [
    %{
      key: :alerts,
      id: "admin-nav-alerts",
      label: "Alerts",
      path: "/admin/alerts",
      icon: "hero-bell-alert"
    },
    %{
      key: :settings,
      id: "admin-nav-settings",
      label: "Settings",
      path: "/admin/settings",
      icon: "hero-cog-6-tooth"
    }
  ]

  attr :flash, :map, required: true
  attr :current_scope, :any, required: true
  attr :active_nav, :atom, required: true
  attr :alert_notification_center, :map, required: true

  slot :inner_block, required: true

  def admin_shell(assigns) do
    assigns =
      assigns
      |> assign(:admin_nav_items, admin_nav_items(assigns.current_scope))
      |> assign(:admin_footer_nav_items, @admin_footer_nav_items)
      |> assign(:admin_identity, admin_identity(assigns.current_scope))
      |> assign(:app_version, app_version())

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} auth_surface chrome={:admin}>
      <div id="admin-shell-root" class="h-svh overflow-hidden bg-base-200 text-base-content">
        <header class="fixed inset-x-0 top-0 z-50 border-b border-base-300/70 bg-base-100">
          <div class="flex h-12 items-center justify-between gap-4 px-4">
            <.link
              navigate={~p"/admin/pools"}
              class="flex h-12 shrink-0 items-center font-mono text-lg font-black uppercase leading-none tracking-[-0.04em] text-primary transition-colors hover:text-primary/80"
            >
              CODEX POOLER
            </.link>

            <div class="flex min-w-0 items-center gap-3">
              <a
                href="https://github.com/icoretech/codex-pooler"
                target="_blank"
                rel="noopener noreferrer"
                class="flex h-12 items-center text-xs font-semibold leading-none text-base-content/60 transition-colors hover:text-base-content"
              >
                <span>{@app_version}</span>
              </a>
              <.alert_notification_dropdown center={@alert_notification_center} />
              <div
                id="topbar-connection-indicator"
                class="dropdown dropdown-end"
                data-state="connecting"
                data-transport="pending"
              >
                <button
                  id="admin-websocket-state-button"
                  type="button"
                  tabindex="0"
                  class="btn btn-ghost btn-sm btn-square text-base-content/60"
                  aria-label="Live updates: syncing"
                  data-ws-button
                >
                  <span data-ws-icon>
                    <.icon name="hero-wifi" class="size-5 text-base-content/45" />
                  </span>
                  <span class="sr-only" data-ws-label>Live updates: syncing</span>
                </button>
                <div
                  id="admin-websocket-state-popover"
                  tabindex="0"
                  class="dropdown-content z-50 mt-3 w-72 rounded-box border border-base-300 bg-base-100 p-4 shadow-2xl"
                  data-state="connecting"
                  data-transport="pending"
                  phx-hook="WebSocketState"
                  phx-update="ignore"
                >
                  <div class="grid gap-3">
                    <div>
                      <p class="font-mono text-[0.62rem] font-semibold uppercase tracking-[0.18em] text-primary">
                        live updates
                      </p>
                      <p class="mt-1 text-xs leading-5 text-base-content/60">
                        Changes appear automatically while this page is open. No manual refresh needed.
                      </p>
                    </div>
                    <dl class="grid gap-2 text-xs">
                      <div class="flex items-center justify-between gap-3">
                        <dt class="text-base-content/50">Status</dt>
                        <dd
                          class="max-w-40 text-right font-mono font-semibold text-base-content/70"
                          data-ws-state
                        >
                          Syncing
                        </dd>
                      </div>
                      <div class="flex items-center justify-between gap-3">
                        <dt class="text-base-content/50">Transport</dt>
                        <dd class="font-mono text-base-content/80" data-ws-transport>Pending</dd>
                      </div>
                    </dl>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </header>

        <aside
          class="fixed left-0 top-12 z-40 flex h-[calc(100svh-3rem)] w-16 flex-col border-r border-base-300/70 bg-base-100 py-4 md:w-64"
          aria-label="Admin navigation"
        >
          <div class="mb-6 flex min-w-0 shrink-0 justify-center px-3 text-center md:flex-col md:items-start md:gap-1 md:px-4 md:text-left">
            <OperatorComponents.operator_avatar
              id="admin-sidebar-operator-avatar"
              operator={@current_scope.user}
              status={@current_scope.user.status}
              class="md:hidden"
            />
            <div id="admin-sidebar-operator-label" class="hidden min-w-0 md:block md:w-full">
              <p class="text-sm font-semibold uppercase tracking-wide text-primary">
                operator
              </p>
              <p
                class="mt-1 block w-full min-w-0 truncate text-xs font-medium uppercase tracking-wide text-base-content/50"
                title={@admin_identity}
              >
                {@admin_identity}
              </p>
            </div>
          </div>

          <nav
            id="admin-nav"
            aria-label="Admin workflow navigation"
            class="scrollbar-none flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto overscroll-contain"
          >
            <.link
              :for={item <- @admin_nav_items}
              id={item.id}
              navigate={item.path}
              aria-current={item.key == @active_nav && "page"}
              aria-label={item.label}
              class={admin_nav_item_class(item.key == @active_nav)}
              title={item.label}
            >
              <.icon
                name={item.icon}
                class={[
                  "size-5 shrink-0 transition-colors group-hover:text-primary",
                  item.key == @active_nav && "text-primary"
                ]}
              />
              <span class="hidden md:block">{item.label}</span>
            </.link>
          </nav>

          <div id="admin-sidebar-footer" class="mt-auto grid shrink-0 gap-1">
            <.link
              :for={item <- @admin_footer_nav_items}
              id={item.id}
              navigate={item.path}
              aria-current={item.key == @active_nav && "page"}
              aria-label={item.label}
              class={admin_nav_item_class(item.key == @active_nav)}
              title={item.label}
            >
              <.icon
                name={item.icon}
                class={[
                  "size-5 shrink-0 transition-colors group-hover:text-primary",
                  item.key == @active_nav && "text-primary"
                ]}
              />
              <span class="hidden md:block">{item.label}</span>
            </.link>

            <.link
              id="admin-sidebar-logout"
              href={~p"/logout"}
              method="delete"
              aria-label="Log out"
              class={admin_nav_item_class(false)}
              title="Log out"
            >
              <.icon
                name="hero-arrow-left-on-rectangle"
                class="size-5 shrink-0 transition-colors group-hover:text-primary"
              />
              <span class="hidden md:block">Log out</span>
            </.link>
          </div>
        </aside>

        <main
          id="admin-shell-scroll-region"
          class="relative ml-16 h-full min-h-0 overflow-x-hidden overflow-y-auto bg-base-200 pt-12 md:ml-64"
        >
          <div class="flex min-w-0 flex-col gap-6 p-4 sm:p-6 xl:p-8">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </Layouts.app>
    """
  end

  defp admin_nav_item_class(active?) do
    [
      "group flex w-full items-center justify-center gap-3 border-l-[3px] border-transparent px-3 py-2.5 font-mono text-[0.58rem] font-semibold uppercase tracking-[0.12em] text-base-content/55 opacity-75 outline-none transition-all duration-200 hover:bg-base-300/70 hover:text-base-content hover:opacity-100 focus-visible:border-primary focus-visible:text-base-content md:justify-start md:px-4 md:text-xs",
      active? && "!border-l-primary bg-base-300 text-base-content opacity-100"
    ]
  end

  attr :center, :map, required: true

  defp alert_notification_dropdown(assigns) do
    ~H"""
    <details
      id="admin-notifications-dropdown"
      class="dropdown dropdown-end"
      phx-click-away={JS.remove_attribute("open", to: "#admin-notifications-dropdown")}
    >
      <summary
        id="admin-notifications-button"
        class="btn btn-ghost btn-sm btn-square relative list-none text-base-content/60 [&::-webkit-details-marker]:hidden"
        role="button"
        aria-label={notification_button_label(@center)}
        data-role="admin-notifications-trigger"
      >
        <.icon name="hero-bell" class="size-5" />
        <span class="sr-only">Notifications</span>
        <span
          :if={notification_badge_visible?(@center)}
          id="admin-notifications-badge"
          class="badge badge-error badge-xs absolute -right-1 -top-1 h-5 min-w-5 border-base-100 px-1 text-[0.62rem] font-semibold tabular-nums"
          aria-label={"#{notification_badge_label(@center)} unread notifications"}
        >
          {notification_badge_label(@center)}
        </span>
      </summary>

      <section
        id="admin-notifications-popover"
        class="dropdown-content z-50 mt-3 w-[min(22rem,calc(100vw-2rem))] overflow-hidden rounded-box border border-base-300 bg-base-100 text-left shadow-2xl"
        aria-label="Admin notifications"
      >
        <header class="flex items-start justify-between gap-3 border-b border-base-300 p-4">
          <div class="grid gap-1">
            <p class="text-xs font-semibold uppercase tracking-[0.18em] text-primary">
              notifications
            </p>
            <p class="text-xs leading-5 text-base-content/60">
              Alert incidents visible to this operator.
            </p>
          </div>
          <button
            :if={notification_has_rows?(@center)}
            id="admin-notifications-dismiss-all"
            type="button"
            class="btn btn-ghost btn-xs shrink-0 gap-1 text-base-content/60 hover:text-base-content"
            data-role="admin-notifications-dismiss-all"
            aria-label="Dismiss all notifications"
            phx-click="dismiss_all_alert_notifications"
          >
            <.icon name="hero-check-circle" class="size-4" />
            <span>Dismiss all</span>
          </button>
        </header>

        <ul
          id="admin-notifications-list"
          class="max-h-96 overflow-y-auto overscroll-contain p-2"
          data-role="admin-notifications-list"
        >
          <li
            :if={!notification_has_rows?(@center)}
            class="grid place-items-center rounded-box border border-dashed border-base-300 px-4 py-8 text-center text-sm font-medium text-base-content/55"
          >
            No active notifications
          </li>
          <li :for={row <- notification_rows(@center)} class="py-1">
            <article
              id={notification_row_id(row)}
              class="rounded-box border border-base-300 bg-base-100 p-3 transition-colors hover:bg-base-200/60"
              data-role="admin-notification-row"
              data-alert-anchor-id={notification_anchor_id(row)}
            >
              <div class="flex items-start justify-between gap-3">
                <div class="grid min-w-0 gap-1">
                  <div class="flex min-w-0 flex-wrap items-center gap-2">
                    <span
                      :if={notification_row_unread?(row)}
                      data-role="admin-notification-unread-indicator"
                      class="inline-flex items-center gap-1 rounded-full border border-primary/20 bg-primary/10 px-2 py-0.5 text-[0.65rem] font-semibold leading-none text-primary"
                    >
                      <span class="size-1.5 rounded-full bg-primary" aria-hidden="true"></span> Unread
                    </span>
                    <span
                      id={"#{notification_row_id(row)}-severity"}
                      data-role="admin-notification-severity"
                      class={notification_severity_chip_class(row)}
                    >
                      {notification_severity_label(row)}
                    </span>
                    <span
                      id={"#{notification_row_id(row)}-state"}
                      data-role="admin-notification-state"
                      class={AdminBadges.status_chip_class(notification_state(row))}
                    >
                      {notification_state_label(row)}
                    </span>
                  </div>
                  <h2 class="truncate text-sm font-semibold text-base-content">
                    {notification_title(row)}
                  </h2>
                </div>
                <p class="shrink-0 whitespace-nowrap text-right text-[0.68rem] font-mono text-base-content/50">
                  {notification_timestamp(row)}
                </p>
              </div>

              <div
                :if={notification_impacted_pools(row) != []}
                class="mt-3 flex flex-wrap gap-1.5"
                data-role="admin-notification-pools"
              >
                <span
                  :for={pool <- notification_impacted_pools(row)}
                  class={AdminBadges.metadata_chip_class(:neutral)}
                  data-role="admin-notification-pool-label"
                >
                  {notification_pool_label(pool)}
                </span>
              </div>

              <div class="mt-3 flex flex-wrap justify-end gap-2">
                <button
                  id={"admin-notification-open-#{notification_row_value(row, :id)}"}
                  type="button"
                  class="btn btn-primary btn-xs gap-1"
                  data-role="admin-notification-primary-action"
                  phx-click="open_alert_notification_incident"
                  phx-value-id={notification_row_value(row, :id)}
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
                  <span>View incident</span>
                </button>
                <button
                  :if={notification_row_unread?(row)}
                  id={"admin-notification-mark-read-#{notification_row_value(row, :id)}"}
                  type="button"
                  class="btn btn-secondary btn-xs gap-1"
                  data-role="admin-notification-mark-read"
                  phx-click="mark_alert_notification_read"
                  phx-value-id={notification_row_value(row, :id)}
                >
                  <.icon name="hero-envelope-open" class="size-3.5" />
                  <span>Mark read</span>
                </button>
                <button
                  id={"admin-notification-dismiss-#{notification_row_value(row, :id)}"}
                  type="button"
                  class="btn btn-ghost btn-xs gap-1 text-base-content/60 hover:text-base-content"
                  data-role="admin-notification-dismiss"
                  phx-click="dismiss_alert_notification"
                  phx-value-id={notification_row_value(row, :id)}
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                  <span>Dismiss</span>
                </button>
              </div>
            </article>
          </li>
        </ul>
      </section>
    </details>
    """
  end

  defp notification_button_label(center) do
    case notification_badge_count(center) do
      0 -> "Notifications: no unread notifications"
      _count -> "Notifications: #{notification_badge_label(center)} unread"
    end
  end

  defp notification_badge_visible?(center), do: notification_badge_count(center) > 0

  defp notification_badge_count(%{badge_count: count}) when is_integer(count) and count >= 0,
    do: count

  defp notification_badge_count(_center), do: 0

  defp notification_badge_label(%{badge_label: label}) when is_binary(label), do: label

  defp notification_badge_label(center),
    do: center |> notification_badge_count() |> Integer.to_string()

  defp notification_has_rows?(%{has_rows?: has_rows?}) when is_boolean(has_rows?), do: has_rows?
  defp notification_has_rows?(%{rows: rows}) when is_list(rows), do: rows != []
  defp notification_has_rows?(_center), do: false

  defp notification_rows(%{rows: rows}) when is_list(rows), do: rows
  defp notification_rows(_center), do: []

  defp notification_row_id(%{id: id}), do: "admin-notification-row-#{id}"
  defp notification_row_id(_row), do: "admin-notification-row-unknown"

  defp notification_row_value(row, key) when is_map(row), do: Map.get(row, key)
  defp notification_row_value(_row, _key), do: nil

  defp notification_anchor_id(%{anchor_id: anchor_id}) when is_binary(anchor_id), do: anchor_id
  defp notification_anchor_id(_row), do: nil

  defp notification_row_unread?(%{unread?: unread?}) when is_boolean(unread?), do: unread?
  defp notification_row_unread?(_row), do: false

  defp notification_severity_chip_class(%{severity: "critical"}),
    do: AdminBadges.metadata_chip_class(:error)

  defp notification_severity_chip_class(%{severity: "warning"}),
    do: AdminBadges.metadata_chip_class(:warning)

  defp notification_severity_chip_class(%{severity: "info"}),
    do: AdminBadges.metadata_chip_class(:info)

  defp notification_severity_chip_class(_row), do: AdminBadges.metadata_chip_class(:neutral)

  defp notification_severity_label(%{severity_label: label}) when is_binary(label), do: label
  defp notification_severity_label(_row), do: "Unknown severity"

  defp notification_state(%{state: state}) when is_binary(state), do: state
  defp notification_state(_row), do: nil

  defp notification_state_label(%{state_label: label}) when is_binary(label), do: label
  defp notification_state_label(_row), do: "Unknown state"

  defp notification_title(%{reason_title: title}) when is_binary(title), do: title
  defp notification_title(_row), do: "Alert condition matched"

  defp notification_timestamp(%{last_seen_at: %DateTime{} = datetime}),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp notification_timestamp(_row), do: "not recorded"

  defp notification_impacted_pools(%{impacted_pools: pools}) when is_list(pools), do: pools
  defp notification_impacted_pools(_row), do: []

  defp notification_pool_label(pool) do
    pool
    |> pool_label_value(:name)
    |> blank_to_nil()
    |> case do
      nil -> pool |> pool_label_value(:slug) |> blank_to_nil() || pool_label_value(pool, :id)
      name -> name
    end
  end

  defp pool_label_value(pool, key) when is_map(pool) do
    Map.get(pool, key) || Map.get(pool, Atom.to_string(key))
  end

  defp pool_label_value(_pool, _key), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp admin_nav_items(current_scope) do
    if Pools.owner?(current_scope) do
      @admin_nav_items
    else
      Enum.reject(@admin_nav_items, &(&1.key in [:jobs, :system]))
    end
  end

  defp admin_identity(%{user: %{display_name: display_name, email: email}}) do
    display_name = display_name && String.trim(display_name)

    cond do
      is_binary(display_name) && display_name != "" -> display_name
      is_binary(email) && email != "" -> email
      true -> "operator"
    end
  end

  defp admin_identity(_current_scope), do: "operator"

  defp app_version do
    :codex_pooler
    |> Application.spec(:vsn)
    |> to_string()
  end
end
