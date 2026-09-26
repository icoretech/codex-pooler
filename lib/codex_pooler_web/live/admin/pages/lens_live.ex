defmodule CodexPoolerWeb.Admin.LensLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.LensFilterForm
  alias CodexPoolerWeb.Admin.LensFilters
  alias CodexPoolerWeb.Admin.LensPresentation
  alias CodexPoolerWeb.Admin.LensReadModel
  alias CodexPoolerWeb.Admin.LiveUpdatesHooks
  alias CodexPoolerWeb.Admin.NotificationCenterHooks
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.Admin.PoolFilterComponents

  @reload_debounce_ms 1_000
  @event_topics ~w(request_logs pools upstreams model_sync)

  @impl true
  def mount(_params, _session, socket) do
    filters = LensFilterForm.values(%{})

    {:ok,
     socket
     |> assign(page_title: "Lens", params: filters, history: nil, history_loading?: true, history_error?: false, history_generation: 0, history_running?: false, history_rerun?: false, history_load_reason: :initial, history_reload_timer: nil, subscribed_pool_ids: MapSet.new(), filter_form: to_form(filters, as: :filters), pool_options: PoolFilterComponents.all_pool_filter_options(), model_options: LensFilterForm.model_options([], ""))
     |> NotificationCenterHooks.follow_viewer_visibility()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = LensFilterForm.values(params)

    if filters != socket.assigns.params or socket.assigns.history_generation == 0 do
      {:noreply, socket |> assign(history: nil, params: filters, filter_form: to_form(filters, as: :filters)) |> request_history(:filter)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    {:noreply, patch_filters(socket, Map.merge(socket.assigns.params, params))}
  end

  def handle_event("select_pool_filter", %{"pool-id" => pool_id}, socket),
    do: {:noreply, patch_filters(socket, Map.put(socket.assigns.params, "pool_id", pool_id))}

  def handle_event("select_filter", %{"field" => field, "filter-value" => value}, socket) when field in ~w(window sent_model evidence),
    do: {:noreply, patch_filters(socket, Map.put(socket.assigns.params, field, value))}

  def handle_event("retry", _params, socket), do: {:noreply, request_history(socket, :manual)}

  @impl true
  def handle_info({Events, %{pool_id: pool_id, topics: topics}}, socket) do
    if MapSet.member?(socket.assigns.subscribed_pool_ids, pool_id) and Enum.any?(topics, &(&1 in @event_topics)) do
      {:noreply, schedule_reload(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:reload_lens, socket) do
    socket = assign(socket, :history_reload_timer, nil)
    LiveUpdatesHooks.unless_paused(socket, &request_history(&1, :event))
  end

  def handle_info(:live_updates_resumed, socket),
    do: {:noreply, socket |> cancel_reload() |> request_history(:event)}

  def handle_info({NotificationCenterHooks, :viewer_visibility_changed}, socket) do
    pool_id = socket.assigns.params["pool_id"]
    was_visible = Enum.any?(socket.assigns.pool_options, &(&1.value == pool_id))
    lost_pool = pool_id != "" and was_visible and not Pools.owner?(socket.assigns.current_scope) and pool_id not in socket.assigns.current_scope.assigned_pool_ids

    socket =
      socket
      |> assign(history: nil, pool_options: PoolFilterComponents.all_pool_filter_options(), model_options: LensFilterForm.model_options([], ""))
      |> reconcile_subscriptions(MapSet.new())

    if lost_pool do
      filters = Map.merge(socket.assigns.params, %{"pool_id" => "", "upstream_identity_id" => ""})
      {:noreply, socket |> assign(params: filters, filter_form: to_form(filters, as: :filters)) |> request_history(:visibility) |> patch_filters(filters)}
    else
      {:noreply, request_history(socket, :visibility)}
    end
  end

  @impl true
  def handle_async({:lens_history, generation}, result, socket) do
    socket = assign(socket, :history_running?, false)

    cond do
      generation != socket.assigns.history_generation ->
        {:noreply, maybe_start_history(socket)}

      socket.assigns.history_load_reason == :event and LiveUpdatesHooks.paused?(socket) ->
        {:noreply, socket |> assign(history_loading?: false, history_rerun?: false) |> LiveUpdatesHooks.hold()}

      true ->
        {:noreply, apply_history(socket, result)}
    end
  end

  defp patch_filters(socket, params), do: push_patch(socket, to: ~p"/admin/lens?#{LensFilterForm.values(params)}")

  defp request_history(socket, reason) do
    socket
    |> cancel_reload()
    |> assign(history_generation: socket.assigns.history_generation + 1, history_load_reason: reason, history_loading?: true, history_error?: false, history_rerun?: true)
    |> maybe_start_history()
  end

  defp maybe_start_history(socket) do
    cond do
      not connected?(socket) or not socket.assigns.history_rerun? or socket.assigns.history_running? ->
        socket

      socket.assigns.history_load_reason == :event and LiveUpdatesHooks.paused?(socket) ->
        socket |> assign(history_loading?: false, history_rerun?: false) |> LiveUpdatesHooks.hold()

      true ->
        scope = socket.assigns.current_scope
        params = socket.assigns.params
        generation = socket.assigns.history_generation

        socket
        |> assign(history_running?: true, history_rerun?: false)
        |> start_async({:lens_history, generation}, fn -> LensReadModel.load(scope, params) end)
    end
  end

  defp apply_history(socket, {:ok, result}) do
    socket
    |> assign(history: result.history, history_loading?: false, history_rerun?: false, history_error?: false, pool_options: result.pool_options, model_options: result.model_options)
    |> reconcile_subscriptions(result.pool_ids)
  end

  defp apply_history(socket, {:exit, _reason}),
    do: assign(socket, history_loading?: false, history_rerun?: false, history_error?: true)

  defp reconcile_subscriptions(socket, pool_ids) do
    {socket, _stale} = PoolEventSubscriptions.reconcile(socket, pool_ids, @event_topics)
    socket
  end

  defp schedule_reload(%{assigns: %{history_reload_timer: timer}} = socket) when is_reference(timer), do: socket
  defp schedule_reload(socket), do: assign(socket, :history_reload_timer, Process.send_after(self(), :reload_lens, @reload_debounce_ms))

  defp cancel_reload(socket) do
    if is_reference(socket.assigns.history_reload_timer), do: Process.cancel_timer(socket.assigns.history_reload_timer, async: false, info: false)
    assign(socket, :history_reload_timer, nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminComponents.admin_shell flash={@flash} current_scope={@current_scope} active_nav={:lens} alert_notification_center={@alert_notification_center} openai_status_aggregate={@openai_status_aggregate}>
      <section id="admin-model-history" class="grid min-w-0 gap-6" aria-busy={to_string(@history_loading?)}>
        <AdminComponents.page_header id="model-history-header" title="Lens" description="Find responses where the provider reports a different model than the one sent, or changes the model name during the response.">
          <:actions>
            <.link id="lens-guide-link" href="https://docs.codex-pooler.com/operators/lens/" target="_blank" rel="noopener noreferrer" class="btn btn-ghost btn-sm gap-1.5"><.icon name="hero-book-open" class="size-4" /><span class="admin-control-label">Lens guide</span></.link>
          </:actions>
        </AdminComponents.page_header>
        <LensFilters.filters form={@filter_form} pool_options={@pool_options} model_options={@model_options} />
        <details id="lens-signal-help" class="text-sm text-base-content/70">
          <summary class="cursor-pointer font-medium">What do these model differences mean?</summary>
          <div class="mt-3 grid gap-2">
            <p><strong class="text-base-content">Different from sent:</strong> Pooler sent model A, but the provider first reported model B.</p>
            <p><strong class="text-base-content">Name changed in response:</strong> the provider reported model A, then model B during the same attempt. This can happen even if the first name matched what Pooler sent.</p>
            <p>One request may have several attempts after a retry. These signals count attempts, and one attempt can have both. The goal is to spot a different model, regardless of its quality. The evidence is the model name reported by the provider.</p>
          </div>
        </details>
        <div :if={@history_error? && @history} class="grid gap-3">
          <AdminComponents.extended_notice id="lens-refresh-error" title="Lens could not update" description="The previous snapshot is still displayed. Retry to load the current data." icon="hero-exclamation-triangle" tone={:warning} role="alert" />
          <div><.retry_button /></div>
        </div>
        <LensPresentation.history :if={@history} history={@history} />
        <AdminComponents.empty_state :if={!@history} id={if @history_error?, do: "lens-error", else: "lens-loading"} title={if @history_error?, do: "Lens could not be loaded", else: "Loading Lens"} description={if @history_error?, do: "Retry to load model declarations for the selected filters.", else: "Loading model declarations and charts for the selected filters."} icon={if @history_error?, do: "hero-exclamation-triangle", else: "hero-arrow-path"} loading?={!@history_error?}>
          <:actions :if={@history_error?}><.retry_button /></:actions>
        </AdminComponents.empty_state>
      </section>
    </AdminComponents.admin_shell>
    """
  end

  defp retry_button(assigns) do
    ~H"""
    <button id="lens-retry" type="button" phx-click="retry" class="btn btn-sm gap-1.5">
      <.icon name="hero-arrow-path" class="size-4" /><span class="admin-control-label">Retry</span>
    </button>
    """
  end
end
