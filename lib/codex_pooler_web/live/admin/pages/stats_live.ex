defmodule CodexPoolerWeb.Admin.StatsLive do
  use CodexPoolerWeb, :live_view

  alias CodexPooler.Admin.Stats
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.Admin.StatsPresentation
  alias CodexPoolerWeb.Admin.StatsPresentation.Charts, as: StatsCharts

  @stats_reload_debounce_ms 1_000
  @stats_event_topics ~w(request_logs usage upstreams job_status model_sync)

  @window_options [
    {"Last 1 hour", "1h"},
    {"Last 5 hours", "5h"},
    {"Last 24 hours", "24h"},
    {"Last 7 days", "7d"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Admin stats",
       dashboard: nil,
       filter_form: to_form(%{"pool_id" => "", "window" => "24h"}, as: :filters),
       filter_error: nil,
       pool_filter_options: all_pool_filter_options(),
       subscribed_pool_ids: MapSet.new()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_dashboard(socket, params)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filter_params}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/stats?#{query_params(filter_params)}")}
  end

  def handle_event("select_pool_filter", %{"pool-id" => pool_id}, socket) do
    params = socket.assigns.filter_form.params |> Map.put("pool_id", pool_id)

    {:noreply, push_patch(socket, to: ~p"/admin/stats?#{query_params(params)}")}
  end

  def handle_event("select_window_filter", %{"window" => window}, socket) do
    params = socket.assigns.filter_form.params |> Map.put("window", window)

    {:noreply, push_patch(socket, to: ~p"/admin/stats?#{query_params(params)}")}
  end

  @impl true
  def handle_info({Events, %{pool_id: pool_id, topics: topics}}, socket) do
    if stats_event?(topics) and MapSet.member?(socket.assigns.subscribed_pool_ids, pool_id) do
      {:noreply, schedule_stats_reload(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:reload_stats_dashboard, socket) do
    notify_stats_reload(:reloaded)

    {:noreply,
     socket
     |> assign(:stats_reload_timer, nil)
     |> load_dashboard(socket.assigns.current_params)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminComponents.admin_shell flash={@flash} current_scope={@current_scope} active_nav={:stats}>
      <section id="admin-stats" class="grid min-w-0 gap-6">
        <AdminComponents.page_header
          id="stats-page-header"
          title="Usage"
          description="Usage, cost, latency, sessions, and quota for the current scope."
        />

        <AdminComponents.filter_form id="stats-filter-form" for={@filter_form} phx-submit="filter">
          <div class="grid gap-2">
            <input
              type="hidden"
              id="stats-pool-filter"
              name="filters[pool_id]"
              value={@filter_form.params["pool_id"] || ""}
            />
            <details
              id="stats-pool-filter-control"
              class="dropdown w-full"
              phx-click-away={JS.remove_attribute("open", to: "#stats-pool-filter-control")}
            >
              <summary
                data-role="pool-filter-trigger"
                aria-label="Scope"
                class="select select-bordered flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal"
              >
                <% selected_pool =
                  selected_pool_filter_option(
                    @pool_filter_options,
                    @filter_form.params["pool_id"]
                  ) %>
                <.icon
                  name={selected_pool.icon}
                  class="size-4 shrink-0 text-base-content/60"
                />
                <span class="truncate">{selected_pool.label}</span>
              </summary>
              <ul
                data-role="pool-filter-menu"
                class="menu dropdown-content z-[60] mt-1 max-h-80 w-full flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 !transition-none ![scale:100%] shadow-xl"
              >
                <li :for={option <- @pool_filter_options}>
                  <button
                    type="button"
                    phx-click="select_pool_filter"
                    phx-value-pool-id={option.value}
                    data-role="pool-filter-option"
                    data-pool-id={option.value}
                    class={[
                      "flex items-center gap-2 text-sm",
                      option.value == (@filter_form.params["pool_id"] || "") && "active"
                    ]}
                    aria-current={option.value == (@filter_form.params["pool_id"] || "") && "true"}
                  >
                    <.icon name={option.icon} class="size-4 shrink-0" />
                    <span class="truncate">{option.label}</span>
                    <span
                      :if={option.strategy_label}
                      class="ml-auto shrink-0 text-[0.68rem] text-base-content/50"
                    >
                      {option.strategy_label}
                    </span>
                  </button>
                </li>
              </ul>
            </details>
          </div>
          <div class="grid gap-2">
            <input
              type="hidden"
              id="stats-time-filter"
              name="filters[window]"
              value={@filter_form.params["window"] || "24h"}
            />
            <details
              id="stats-time-filter-control"
              class="dropdown w-full"
              phx-click-away={JS.remove_attribute("open", to: "#stats-time-filter-control")}
            >
              <summary
                data-role="window-filter-trigger"
                aria-label="Range"
                class="select select-bordered flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal"
              >
                <.icon name="hero-clock" class="size-4 shrink-0 text-base-content/60" />
                <span class="truncate">{selected_window_filter_label(@filter_form)}</span>
              </summary>
              <ul
                data-role="window-filter-menu"
                class="menu dropdown-content z-[60] mt-1 max-h-80 w-full flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 !transition-none ![scale:100%] shadow-xl"
              >
                <li :for={{label, window} <- window_options()}>
                  <button
                    type="button"
                    phx-click="select_window_filter"
                    phx-value-window={window}
                    data-role="window-filter-option"
                    data-window={window}
                    class={[
                      "flex items-center gap-2 text-sm",
                      window == (@filter_form.params["window"] || "24h") && "active"
                    ]}
                    aria-current={window == (@filter_form.params["window"] || "24h") && "true"}
                  >
                    <.icon name="hero-clock" class="size-4 shrink-0" />
                    <span>{label}</span>
                  </button>
                </li>
              </ul>
            </details>
          </div>
        </AdminComponents.filter_form>

        <div :if={@filter_error} id="stats-filter-error" class="alert alert-warning items-start">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <div>
            <p class="font-semibold">Filters were not applied</p>
            <p class="text-sm">{@filter_error.message}</p>
          </div>
        </div>

        <%= if @dashboard do %>
          <StatsPresentation.kpi_strip id="stats-kpis" dashboard={@dashboard} />

          <StatsCharts.traffic_charts
            requests={@dashboard.charts.requests}
            tokens={@dashboard.charts.tokens}
          />

          <section class="grid min-w-0 gap-4 xl:grid-cols-2">
            <StatsPresentation.top_api_keys_table rows={@dashboard.tables.top_api_keys} />
            <StatsPresentation.upstreams_table rows={@dashboard.tables.upstreams} />
          </section>
        <% else %>
          <AdminComponents.empty_state
            id="stats-dashboard-error"
            title="Stats are not available"
            description="Change filters or sign in with an operator account that can manage pools."
            icon="hero-chart-bar"
          />
        <% end %>
      </section>
    </AdminComponents.admin_shell>
    """
  end

  defp load_dashboard(socket, params) do
    filters = stats_filters(params)

    case Stats.build_dashboard(socket.assigns.current_scope, filters) do
      {:ok, dashboard} ->
        socket
        |> reconcile_pool_subscriptions(dashboard)
        |> assign(
          dashboard: dashboard,
          filter_form: stats_filter_form(dashboard.filters),
          filter_error: nil,
          pool_filter_options: pool_filter_options(dashboard),
          current_params: params
        )

      {:error, error} ->
        socket
        |> reconcile_pool_subscriptions(nil)
        |> assign(
          dashboard: nil,
          filter_form: stats_filter_form(filters),
          filter_error: error,
          pool_filter_options: all_pool_filter_options(),
          current_params: params
        )
    end
  end

  defp reconcile_pool_subscriptions(socket, dashboard) do
    if connected?(socket) do
      {socket, stale_pool_ids} =
        PoolEventSubscriptions.reconcile(socket, dashboard_pool_ids(dashboard))

      socket
      |> PoolEventSubscriptions.maybe_cancel_timer_on_stale(
        stale_pool_ids,
        &cancel_stats_reload_timer/1
      )
    else
      socket
    end
  end

  defp dashboard_pool_ids(nil), do: MapSet.new()

  defp dashboard_pool_ids(%{selected_pool: %{id: pool_id}}) when is_binary(pool_id),
    do: MapSet.new([pool_id])

  defp dashboard_pool_ids(%{filters: %{pool_options: pool_options}}) do
    pool_options
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp schedule_stats_reload(socket) do
    if is_reference(socket.assigns[:stats_reload_timer]) do
      socket
    else
      schedule_new_stats_reload(socket)
    end
  end

  defp schedule_new_stats_reload(socket) do
    timer = Process.send_after(self(), :reload_stats_dashboard, @stats_reload_debounce_ms)
    notify_stats_reload(:scheduled)
    assign(socket, :stats_reload_timer, timer)
  end

  defp cancel_stats_reload_timer(socket) do
    if is_reference(socket.assigns[:stats_reload_timer]) do
      Process.cancel_timer(socket.assigns.stats_reload_timer, async: false, info: false)
    end

    assign(socket, :stats_reload_timer, nil)
  end

  defp stats_event?(topics) when is_list(topics),
    do: Enum.any?(topics, &(&1 in @stats_event_topics))

  defp stats_event?(_topics), do: false

  defp notify_stats_reload(stage) do
    :telemetry.execute(
      [:codex_pooler, :admin, :stats_live, :reload],
      %{},
      %{stage: stage, pid: self()}
    )
  end

  defp stats_filters(params) do
    params = Map.new(params)

    %{
      "pool_id" => params |> Map.get("pool_id") |> blank_to_nil(),
      "window" => normalize_window(Map.get(params, "window"))
    }
  end

  defp stats_filter_form(filters) do
    filters
    |> filter_form_values()
    |> to_form(as: :filters)
  end

  defp filter_form_values(filters) do
    %{
      "pool_id" => Map.get(filters, :pool_id) || Map.get(filters, "pool_id") || "",
      "window" => Map.get(filters, :window) || Map.get(filters, "window") || "24h"
    }
  end

  defp query_params(filter_params) do
    filter_params
    |> Map.take(~w(pool_id window))
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Enum.sort_by(fn {key, _value} -> query_param_order(key) end)
  end

  defp query_param_order("pool_id"), do: 0
  defp query_param_order("window"), do: 1
  defp query_param_order(_key), do: 2

  defp pool_filter_options(%{filters: %{pool_options: pool_options}}) do
    settings_by_pool_id =
      pool_options
      |> Enum.map(& &1.id)
      |> Pools.routing_settings_by_pool_ids()

    pool_options =
      pool_options
      |> Enum.map(fn pool ->
        strategy = Map.fetch!(settings_by_pool_id, pool.id).routing_strategy

        %{
          label: pool.name,
          value: pool.id,
          icon: AdminBadges.routing_strategy_icon(strategy),
          strategy_label: AdminBadges.routing_strategy_label(strategy)
        }
      end)

    all_pool_filter_options() ++ pool_options
  end

  defp all_pool_filter_options do
    [%{label: "All Pools", value: "", icon: "hero-server-stack", strategy_label: nil}]
  end

  defp selected_pool_filter_option(options, pool_id) do
    Enum.find(options, &(&1.value == (pool_id || ""))) || hd(all_pool_filter_options())
  end

  defp window_options, do: @window_options

  defp selected_window_filter_label(filter_form) do
    selected_window = filter_form.params["window"] || "24h"

    window_options()
    |> Enum.find_value("Last 24 hours", fn {label, window} ->
      if window == selected_window, do: label
    end)
  end

  defp normalize_window(window) when window in ["1h", "5h", "24h", "7d"], do: window
  defp normalize_window(_window), do: "24h"

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""
end
