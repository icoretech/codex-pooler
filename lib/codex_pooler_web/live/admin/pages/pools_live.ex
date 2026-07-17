defmodule CodexPoolerWeb.Admin.PoolsLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.Admin.PoolWorkflow
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.Admin.PoolForm
  alias CodexPoolerWeb.Admin.PoolListComponents
  alias CodexPoolerWeb.Admin.PoolsReadModel
  alias CodexPoolerWeb.Admin.PoolWizardComponents

  @pool_event_topics ["pools", "upstreams", "usage"]
  @pool_traffic_refresh_delay_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Pools",
       pools: [],
       can_manage_pools?: false,
       creating_pool: false,
       editing_pool: nil,
       deleting_pool: nil,
       delete_form_version: 0,
       create_form: PoolForm.create_form(),
       edit_form: nil,
       delete_form: PoolForm.delete_form(),
       pool_wizard_step: "details",
       pool_filters: PoolForm.filter(),
       pool_filter_form: PoolForm.filter_form(),
       pool_compat_panels: %{},
       pool_metrics: PoolsReadModel.empty_metrics(),
       data_load_warnings: [],
       subscribed_pool_events?: false,
       pool_traffic_dirty?: false,
       pool_traffic_refresh_timer: nil,
       pool_traffic_refresh_token: nil,
       traffic_pool_ids: [],
       pool_traffic_usage: nil,
       pool_traffic_loading?: true,
       pool_traffic_running?: false,
       pool_traffic_rerun?: false
     )
     |> load_structural()
     |> start_pool_traffic_load()}
  end

  @impl true
  def handle_event("open_create_pool", _params, socket) do
    case ensure_can_manage_pools(socket) do
      :ok ->
        {:noreply,
         socket
         |> assign(:creating_pool, true)
         |> assign(:create_form, PoolForm.create_form())
         |> assign(:pool_wizard_step, "details")
         |> clear_editing()
         |> clear_deleting()
         |> defer_pool_traffic_refresh()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> close_create_dialog()}
    end
  end

  def handle_event("cancel_create", _params, socket) do
    {:noreply, socket |> close_create_dialog() |> flush_deferred_pool_traffic_refresh()}
  end

  def handle_event("create_pool", %{"pool" => pool_params}, socket) do
    with :ok <- ensure_can_manage_pools(socket),
         {:ok, _pool} <-
           PoolWorkflow.create_pool_with_related_settings(
             socket.assigns.current_scope,
             pool_params
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Pool created")
       |> clear_pool_traffic_refresh()
       |> close_create_dialog()
       |> load_structural()
       |> start_pool_traffic_load()}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(changeset))
         |> assign(:creating_pool, true)
         |> assign(
           :create_form,
           PoolForm.create_form(pool_params, PoolForm.changeset_errors(changeset))
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> assign(:creating_pool, true)
         |> assign(:create_form, PoolForm.create_form(pool_params))}
    end
  end

  def handle_event("edit_pool", %{"id" => pool_id}, socket) do
    case find_pool(socket, pool_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Pool was not found")}

      pool ->
        {:noreply,
         socket
         |> close_create_dialog()
         |> assign(:editing_pool, pool)
         |> assign(:edit_form, PoolForm.edit_form(pool))
         |> assign(:pool_wizard_step, "details")
         |> clear_deleting()
         |> defer_pool_traffic_refresh()}
    end
  end

  def handle_event("pool_wizard_step", %{"step" => step}, socket) do
    {:noreply, assign(socket, :pool_wizard_step, PoolWizardComponents.normalize_step(step))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> clear_editing() |> flush_deferred_pool_traffic_refresh()}
  end

  def handle_event("save_pool", %{"pool_edit" => pool_params}, socket) do
    pool_id = pool_params["id"]

    with :ok <- ensure_can_manage_pools(socket),
         {:ok, _pool} <-
           PoolWorkflow.update_pool_with_related_settings(
             socket.assigns.current_scope,
             pool_id,
             pool_params
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Pool updated")
       |> clear_pool_traffic_refresh()
       |> clear_editing()
       |> load_structural()
       |> start_pool_traffic_load()}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(changeset))
         |> assign(
           :edit_form,
           PoolForm.edit_form(
             socket.assigns.editing_pool,
             pool_params,
             PoolForm.changeset_errors(changeset)
           )
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> assign(:edit_form, PoolForm.edit_form(socket.assigns.editing_pool, pool_params))}
    end
  end

  def handle_event("toggle_pool_compat_panel", %{"pool-id" => pool_id, "flag" => flag}, socket) do
    with {:ok, _label} <- compat_flag_label(flag),
         {:ok, _pool_row} <- fetch_pool_row(socket, pool_id) do
      panels =
        case Map.get(socket.assigns.pool_compat_panels, pool_id) do
          ^flag -> Map.delete(socket.assigns.pool_compat_panels, pool_id)
          _other -> Map.put(socket.assigns.pool_compat_panels, pool_id, flag)
        end

      {:noreply, assign(socket, :pool_compat_panels, panels)}
    else
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("toggle_pool_compat_flag", %{"pool-id" => pool_id, "flag" => flag}, socket) do
    with {:ok, flag_label} <- compat_flag_label(flag),
         :ok <- ensure_can_manage_pools(socket),
         {:ok, pool_row} <- fetch_pool_row(socket, pool_id),
         enabled? = pool_row.compat_flags[String.to_existing_atom(flag)] != true,
         {:ok, _settings} <-
           PoolRouting.update_routing_settings(
             socket.assigns.current_scope,
             pool_row.pool,
             %{flag => enabled?}
           ) do
      state_label = if enabled?, do: "enabled", else: "disabled"

      {:noreply,
       socket
       |> put_flash(:info, "#{flag_label} #{state_label} on #{pool_row.pool.name}")
       |> load_structural()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> load_structural()}
    end
  end

  def handle_event("delete_pool", %{"id" => pool_id}, socket) do
    case find_pool(socket, pool_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Pool was not found")}

      pool ->
        {:noreply,
         socket
         |> close_create_dialog()
         |> clear_editing()
         |> assign(:deleting_pool, pool)
         |> assign(:delete_form, PoolForm.delete_form(pool))
         |> update(:delete_form_version, &(&1 + 1))
         |> defer_pool_traffic_refresh()}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, socket |> clear_deleting() |> flush_deferred_pool_traffic_refresh()}
  end

  def handle_event("confirm_delete_pool", %{"pool_delete" => pool_params}, socket) do
    pool_id = pool_params["id"]
    confirmation_slug = pool_params["confirmation_slug"]

    with :ok <- ensure_can_manage_pools(socket),
         {:ok, _pool} <-
           Pools.delete_archived_pool(socket.assigns.current_scope, pool_id, confirmation_slug) do
      {:noreply,
       socket
       |> put_flash(:info, "Pool deleted")
       |> clear_pool_traffic_refresh()
       |> clear_deleting()
       |> load_structural()
       |> start_pool_traffic_load()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> assign(:delete_form, PoolForm.delete_form(socket.assigns.deleting_pool))
         |> update(:delete_form_version, &(&1 + 1))}
    end
  end

  def handle_event("filter_pools", %{"pool_filters" => filter_params}, socket) do
    {:noreply, apply_pool_filters(socket, PoolForm.filter(filter_params))}
  end

  def handle_event("clear_pool_query_filter", _params, socket) do
    filters = PoolForm.filter(Map.put(socket.assigns.pool_filters, "query", ""))

    {:noreply, apply_pool_filters(socket, filters)}
  end

  def handle_event("select_pool_status_filter", %{"status" => status}, socket) do
    filters = PoolForm.filter(Map.put(socket.assigns.pool_filters, "status", status))

    {:noreply, apply_pool_filters(socket, filters)}
  end

  def handle_event("select_pool_traffic_window_filter", %{"window" => window}, socket) do
    filters = PoolForm.filter(Map.put(socket.assigns.pool_filters, "traffic_window", window))

    {:noreply, apply_pool_filters(socket, filters)}
  end

  @impl true
  def handle_info({Events, %{pool_id: pool_id, topics: topics}}, socket) do
    case pool_event_kind(topics, pool_id) do
      :lifecycle -> {:noreply, reload_pools_or_defer(socket)}
      :usage -> {:noreply, schedule_pool_traffic_refresh(socket)}
      :ignore -> {:noreply, socket}
    end
  end

  def handle_info({:refresh_pool_traffic, refresh_token}, socket) do
    if socket.assigns.pool_traffic_refresh_token == refresh_token do
      {:noreply,
       socket
       |> clear_pool_traffic_refresh()
       |> start_pool_traffic_load()}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:pool_traffic, {:ok, traffic}, socket) do
    socket = assign(socket, :pool_traffic_running?, false)

    if traffic.traffic_window == current_traffic_window(socket) do
      socket =
        socket
        |> assign(pool_traffic_usage: traffic.usage_by_pool_id, pool_traffic_loading?: false)
        |> apply_pool_traffic()

      if socket.assigns.pool_traffic_rerun? do
        {:noreply, start_pool_traffic_load(socket)}
      else
        {:noreply, socket}
      end
    else
      # The traffic window changed while this result was in flight; the stale
      # aggregate must not merge, so discard it and load the current window.
      {:noreply, start_pool_traffic_load(socket)}
    end
  end

  def handle_async(:pool_traffic, {:exit, _reason}, socket) do
    socket = assign(socket, :pool_traffic_running?, false)

    if socket.assigns.pool_traffic_rerun? do
      {:noreply, start_pool_traffic_load(socket)}
    else
      # Without merged usage the structural zeros are placeholders, not data:
      # keep the loading affordance instead of presenting them as settled.
      {:noreply,
       assign(socket, :pool_traffic_loading?, is_nil(socket.assigns.pool_traffic_usage))}
    end
  end

  defp pool_event_kind(topics, pool_id) when is_list(topics) and is_binary(pool_id) do
    case Events.validate_topics(topics) do
      {:ok, topics} ->
        cond do
          Enum.any?(topics, &(&1 in ["pools", "upstreams"])) -> :lifecycle
          "usage" in topics -> :usage
          true -> :ignore
        end

      {:error, :invalid_topics} ->
        :ignore
    end
  end

  defp pool_event_kind(_topics, _pool_id), do: :ignore

  @impl true
  def render(assigns) do
    ~H"""
    <AdminComponents.admin_shell
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:pools}
      alert_notification_center={@alert_notification_center}
    >
      <section id="admin-pools-live" class="grid min-w-0 gap-6">
        <AdminComponents.page_header
          id="pool-page-header"
          title="Pools"
          description="Create and manage the Pools that group API keys, upstream accounts, routing policy, and logs."
        >
          <:actions>
            <AdminComponents.action_button
              :if={@can_manage_pools?}
              id="pools-page-create-action"
              icon="hero-plus"
              label="Create Pool"
              phx-click="open_create_pool"
              size={:md}
              variant={:primary}
            />
          </:actions>
        </AdminComponents.page_header>

        <div
          :for={warning <- @data_load_warnings}
          id={"pool-data-load-warning-#{warning.id}"}
          class="alert alert-warning items-start"
        >
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <div class="grid gap-1">
            <p class="font-semibold">{warning.title}</p>
            <p class="text-sm">{warning.message}</p>
          </div>
        </div>

        <AdminComponents.metric_strip id="pool-metrics" compact_mobile>
          <AdminComponents.metric_card
            id="pool-metric-total"
            icon="hero-server-stack"
            label="Total pools"
            value={@pool_metrics.total_count}
            compact_mobile
          />
          <AdminComponents.metric_card
            id="pool-metric-upstreams"
            icon="hero-cloud-arrow-up"
            label="Upstream accounts"
            value={@pool_metrics.upstream_count}
            tone={:primary}
            compact_mobile
          />
          <AdminComponents.metric_card
            id="pool-metric-api-keys"
            icon="hero-key"
            label="API keys"
            value={@pool_metrics.api_key_count}
            compact_mobile
          />
          <AdminComponents.metric_card
            id="pool-metric-requests"
            icon="hero-arrow-path"
            label={"Requests #{@pool_metrics.traffic_window_label}"}
            value={
              pool_traffic_metric_value(
                @pool_traffic_loading?,
                PoolsReadModel.format_metric_integer(@pool_metrics.request_count)
              )
            }
            compact_mobile
          />
          <AdminComponents.metric_card
            id="pool-metric-tokens-per-sec"
            icon="hero-bolt"
            label={"TPS #{@pool_metrics.traffic_window_label}"}
            value={
              pool_traffic_metric_value(
                @pool_traffic_loading?,
                PoolsReadModel.format_metric_rate(@pool_metrics.tokens_per_second)
              )
            }
            tone={:primary}
            compact_mobile
          />
        </AdminComponents.metric_strip>

        <PoolWizardComponents.pool_wizard
          :if={@can_manage_pools? && @creating_pool}
          mode={:create}
          form={@create_form}
          current_step={@pool_wizard_step}
          upstream_options={@upstream_identity_options}
          api_key_options={@api_key_options}
        />

        <PoolWizardComponents.pool_wizard
          :if={@editing_pool}
          mode={:edit}
          form={@edit_form}
          current_step={@pool_wizard_step}
          upstream_options={
            PoolForm.edit_upstream_identity_options(@editing_pool, @upstream_identity_options)
          }
          api_key_options={@api_key_options}
        />

        <PoolListComponents.pool_inventory
          deleting_pool={@deleting_pool}
          delete_form={@delete_form}
          delete_form_version={@delete_form_version}
          pool_filter_form={@pool_filter_form}
          pools={@pools}
          can_manage_pools?={@can_manage_pools?}
          compat_panel_views={@pool_compat_panels}
        />
      </section>
    </AdminComponents.admin_shell>
    """
  end

  defp load_structural(socket) do
    page_state =
      PoolsReadModel.load_structural(
        socket.assigns.current_scope,
        socket.assigns.pool_filters
      )

    socket
    |> assign(page_state)
    |> maybe_subscribe_pool_events(page_state.pools)
    |> apply_pool_traffic()
  end

  defp apply_pool_filters(socket, filters) do
    previous_window = current_traffic_window(socket)

    socket =
      socket
      |> assign(:pool_filters, filters)
      |> assign(:pool_filter_form, PoolForm.filter_form(filters))

    if current_traffic_window(socket) == previous_window do
      load_structural(socket)
    else
      socket
      |> assign(pool_traffic_usage: nil, pool_traffic_loading?: true)
      |> load_structural()
      |> start_pool_traffic_load()
    end
  end

  # The traffic aggregate is the expensive read; running it on this process
  # would queue clicks and dialog opens behind it. One task at a time: extra
  # requests while one is in flight coalesce into a single re-run.
  defp start_pool_traffic_load(socket) do
    cond do
      not connected?(socket) ->
        socket

      socket.assigns.pool_traffic_running? ->
        assign(socket, :pool_traffic_rerun?, true)

      true ->
        pool_ids = socket.assigns.traffic_pool_ids
        traffic_window = current_traffic_window(socket)

        socket
        |> assign(pool_traffic_running?: true, pool_traffic_rerun?: false)
        |> start_async(:pool_traffic, fn ->
          PoolsReadModel.traffic_metrics(pool_ids, traffic_window)
        end)
    end
  end

  defp apply_pool_traffic(socket) do
    case socket.assigns.pool_traffic_usage do
      nil ->
        socket

      usage_by_pool_id ->
        {pools, pool_metrics} =
          PoolsReadModel.merge_traffic(
            socket.assigns.pools,
            socket.assigns.pool_metrics,
            usage_by_pool_id,
            socket.assigns.traffic_pool_ids
          )

        assign(socket, pools: pools, pool_metrics: pool_metrics)
    end
  end

  defp current_traffic_window(socket),
    do: Map.get(socket.assigns.pool_filters, "traffic_window", "24h")

  defp maybe_subscribe_pool_events(socket, pool_rows) do
    pool_rows
    |> Enum.map(& &1.pool.id)
    |> MapSet.new()
    |> then(fn target_pool_ids ->
      {socket, _stale_pool_ids} =
        PoolEventSubscriptions.reconcile(socket, target_pool_ids, @pool_event_topics)

      socket
    end)
  end

  defp ensure_can_manage_pools(socket) do
    if Pools.can_manage_pools?(socket.assigns.current_scope) do
      :ok
    else
      {:error, %{message: "Pool management is not available for this session"}}
    end
  end

  defp find_pool(socket, pool_id) when is_binary(pool_id) do
    socket.assigns.pools
    |> Enum.find(&(&1.pool.id == pool_id))
    |> case do
      nil -> nil
      pool_row -> pool_row.pool
    end
  end

  defp find_pool(_socket, _pool_id), do: nil

  @compat_flag_labels %{
    "v1_compatibility_enabled" => "/v1 compatibility",
    "request_compression_enabled" => "Request compression",
    "upstream_websocket_bridge_enabled" => "Upstream websocket bridge"
  }

  defp compat_flag_label(flag) do
    case Map.fetch(@compat_flag_labels, flag) do
      {:ok, label} -> {:ok, label}
      :error -> {:error, %{message: "unsupported pool option"}}
    end
  end

  defp fetch_pool_row(socket, pool_id) when is_binary(pool_id) do
    socket.assigns.pools
    |> Enum.find(&(&1.pool.id == pool_id))
    |> case do
      nil -> {:error, %{message: "Pool was not found"}}
      pool_row -> {:ok, pool_row}
    end
  end

  defp fetch_pool_row(_socket, _pool_id), do: {:error, %{message: "Pool was not found"}}

  defp close_create_dialog(socket) do
    assign(socket,
      creating_pool: false,
      create_form: PoolForm.create_form()
    )
  end

  defp clear_editing(socket), do: assign(socket, editing_pool: nil, edit_form: nil)

  defp clear_deleting(socket),
    do: assign(socket, deleting_pool: nil, delete_form: PoolForm.delete_form())

  # Lifecycle events must not rebuild the option assigns while a pool dialog
  # is open: the create/edit checkbox selections live only in the client DOM
  # (submit-only forms), so a re-render reverts un-submitted ticks. Mark the
  # page stale instead and let the dialog-close flush reload it.
  defp reload_pools_or_defer(socket) do
    if pool_dialog_open?(socket) do
      socket
      |> assign(:pool_traffic_dirty?, true)
      |> cancel_pool_traffic_refresh_timer()
    else
      socket
      |> load_structural()
      |> start_pool_traffic_load()
    end
  end

  defp schedule_pool_traffic_refresh(socket) do
    socket = assign(socket, :pool_traffic_dirty?, true)

    if pool_dialog_open?(socket) do
      cancel_pool_traffic_refresh_timer(socket)
    else
      case socket.assigns.pool_traffic_refresh_timer do
        timer_ref when is_reference(timer_ref) ->
          socket

        nil ->
          refresh_token = make_ref()

          timer_ref =
            Process.send_after(
              self(),
              {:refresh_pool_traffic, refresh_token},
              @pool_traffic_refresh_delay_ms
            )

          assign(socket,
            pool_traffic_refresh_timer: timer_ref,
            pool_traffic_refresh_token: refresh_token
          )
      end
    end
  end

  defp defer_pool_traffic_refresh(socket) do
    if socket.assigns.pool_traffic_dirty? do
      cancel_pool_traffic_refresh_timer(socket)
    else
      socket
    end
  end

  defp flush_deferred_pool_traffic_refresh(socket) do
    if socket.assigns.pool_traffic_dirty? and not pool_dialog_open?(socket) do
      socket
      |> clear_pool_traffic_refresh()
      |> load_structural()
      |> start_pool_traffic_load()
    else
      socket
    end
  end

  defp clear_pool_traffic_refresh(socket) do
    socket
    |> cancel_pool_traffic_refresh_timer()
    |> assign(
      pool_traffic_dirty?: false,
      pool_traffic_refresh_timer: nil,
      pool_traffic_refresh_token: nil
    )
  end

  defp cancel_pool_traffic_refresh_timer(socket) do
    if is_reference(socket.assigns.pool_traffic_refresh_timer) do
      Process.cancel_timer(socket.assigns.pool_traffic_refresh_timer, async: false, info: false)
    end

    assign(socket, pool_traffic_refresh_timer: nil, pool_traffic_refresh_token: nil)
  end

  defp pool_traffic_metric_value(true = _loading?, _value), do: "…"
  defp pool_traffic_metric_value(false = _loading?, value), do: value

  defp pool_dialog_open?(socket) do
    socket.assigns.creating_pool or not is_nil(socket.assigns.editing_pool) or
      not is_nil(socket.assigns.deleting_pool)
  end

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> List.first()
    |> case do
      nil -> "Pool action failed"
      message -> message
    end
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(_reason), do: "Pool action failed"
end
