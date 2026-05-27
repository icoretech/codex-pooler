defmodule CodexPoolerWeb.Admin.Components.Shell do
  @moduledoc false

  use CodexPoolerWeb, :html

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

  slot :inner_block, required: true

  def admin_shell(assigns) do
    assigns =
      assigns
      |> assign(:admin_nav_items, @admin_nav_items)
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
                  aria-label="Admin page live updates: connecting"
                  data-ws-button
                >
                  <span data-ws-icon>
                    <.icon name="hero-wifi" class="size-5 text-base-content/45" />
                  </span>
                  <span class="sr-only" data-ws-label>Admin page live updates: connecting</span>
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
                        Browser admin UI only. Codex API websocket health is separate.
                      </p>
                    </div>
                    <dl class="grid gap-2 text-xs">
                      <div class="flex items-center justify-between gap-3">
                        <dt class="text-base-content/50">Status</dt>
                        <dd
                          class="max-w-40 text-right font-mono font-semibold text-base-content/70"
                          data-ws-state
                        >
                          connecting
                        </dd>
                      </div>
                      <div class="flex items-center justify-between gap-3">
                        <dt class="text-base-content/50">Transport</dt>
                        <dd class="font-mono text-base-content/80" data-ws-transport>pending</dd>
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
          <div class="mb-6 flex justify-center px-3 text-center md:flex-col md:items-start md:gap-1 md:px-4 md:text-left">
            <OperatorComponents.operator_avatar
              id="admin-sidebar-operator-avatar"
              operator={@current_scope.user}
              status={@current_scope.user.status}
              class="md:hidden"
            />
            <div id="admin-sidebar-operator-label" class="hidden min-w-0 md:block">
              <p class="text-sm font-semibold uppercase tracking-wide text-primary">
                operator
              </p>
              <p class="mt-1 max-w-full truncate text-xs font-medium uppercase tracking-wide text-base-content/50">
                {@admin_identity}
              </p>
            </div>
          </div>

          <nav
            id="admin-nav"
            aria-label="Admin workflow navigation"
            class="flex flex-1 flex-col gap-1"
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

          <div id="admin-sidebar-footer" class="mt-auto grid gap-1">
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
