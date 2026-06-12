defmodule CodexPoolerWeb.Admin.PoolsLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.Admin.PoolWorkflow
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.Admin.PoolForm
  alias CodexPoolerWeb.Admin.PoolListComponents
  alias CodexPoolerWeb.Admin.PoolsReadModel
  alias CodexPoolerWeb.Admin.PoolWizardComponents

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
       pool_metrics: PoolsReadModel.empty_metrics(),
       data_load_warnings: [],
       subscribed_pool_events?: false
     )
     |> load_pools()}
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
         |> clear_deleting()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> close_create_dialog()}
    end
  end

  def handle_event("cancel_create", _params, socket) do
    {:noreply, close_create_dialog(socket)}
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
       |> close_create_dialog()
       |> load_pools()}
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
         |> clear_deleting()}
    end
  end

  def handle_event("pool_wizard_step", %{"step" => step}, socket) do
    {:noreply, assign(socket, :pool_wizard_step, PoolWizardComponents.normalize_step(step))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, clear_editing(socket)}
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
       |> clear_editing()
       |> load_pools()}
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
         |> update(:delete_form_version, &(&1 + 1))}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, clear_deleting(socket)}
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
       |> clear_deleting()
       |> load_pools()}
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
    filters = PoolForm.filter(filter_params)

    {:noreply,
     socket
     |> assign(:pool_filters, filters)
     |> assign(:pool_filter_form, PoolForm.filter_form(filters))
     |> load_pools()}
  end

  def handle_event("clear_pool_query_filter", _params, socket) do
    filters = PoolForm.filter(Map.put(socket.assigns.pool_filters, "query", ""))

    {:noreply,
     socket
     |> assign(:pool_filters, filters)
     |> assign(:pool_filter_form, PoolForm.filter_form(filters))
     |> load_pools()}
  end

  def handle_event("select_pool_status_filter", %{"status" => status}, socket) do
    filters = PoolForm.filter(Map.put(socket.assigns.pool_filters, "status", status))

    {:noreply,
     socket
     |> assign(:pool_filters, filters)
     |> assign(:pool_filter_form, PoolForm.filter_form(filters))
     |> load_pools()}
  end

  @impl true
  def handle_info({Events, %{pool_id: pool_id, topics: topics}}, socket) do
    if pool_event_refresh?(topics, pool_id) do
      {:noreply, load_pools(socket)}
    else
      {:noreply, socket}
    end
  end

  defp pool_event_refresh?(topics, pool_id) when is_list(topics) and is_binary(pool_id) do
    Enum.any?(topics, &(&1 in ["pools", "upstreams", "usage", "request_logs"]))
  end

  defp pool_event_refresh?(_topics, _pool_id), do: false

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
            label="Requests 5h"
            value={PoolsReadModel.format_metric_integer(@pool_metrics.request_count_5h)}
            compact_mobile
          />
          <AdminComponents.metric_card
            id="pool-metric-tokens-per-sec"
            icon="hero-bolt"
            label="TPS 5h"
            value={PoolsReadModel.format_metric_rate(@pool_metrics.tokens_per_second)}
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
        />
      </section>
    </AdminComponents.admin_shell>
    """
  end

  defp load_pools(socket) do
    page_state =
      PoolsReadModel.load(
        socket.assigns.current_scope,
        socket.assigns.pool_filters
      )

    socket
    |> assign(page_state)
    |> maybe_subscribe_pool_events(page_state.pools)
  end

  defp maybe_subscribe_pool_events(socket, pool_rows) do
    pool_rows
    |> Enum.map(& &1.pool.id)
    |> MapSet.new()
    |> then(fn target_pool_ids ->
      {socket, _stale_pool_ids} = PoolEventSubscriptions.reconcile(socket, target_pool_ids)
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

  defp close_create_dialog(socket) do
    assign(socket,
      creating_pool: false,
      create_form: PoolForm.create_form()
    )
  end

  defp clear_editing(socket), do: assign(socket, editing_pool: nil, edit_form: nil)

  defp clear_deleting(socket),
    do: assign(socket, deleting_pool: nil, delete_form: PoolForm.delete_form())

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
