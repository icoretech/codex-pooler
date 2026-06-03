defmodule CodexPoolerWeb.Admin.JobsLive do
  use CodexPoolerWeb, :admin_live_view

  import CodexPoolerWeb.Admin.JobsPresentation, only: [worker_cards: 2]

  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.JobDetailDrawer
  alias CodexPoolerWeb.Admin.JobExplorer
  alias CodexPoolerWeb.Admin.JobFilterForm
  alias CodexPoolerWeb.Admin.JobFilters
  alias CodexPoolerWeb.Admin.JobOverview
  alias CodexPoolerWeb.Admin.JobsReadModel
  alias CodexPoolerWeb.Admin.JobWorkerCards
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.DateTimeDisplay

  @jobs_reload_debounce_ms 1_000
  @jobs_fallback_refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    empty_page_state = JobsReadModel.load(nil)

    socket =
      socket
      |> assign(
        page_title: "Jobs",
        owner_authorized?: Pools.owner?(socket.assigns.current_scope),
        jobs_reload_timer: nil,
        subscribed_pool_ids: MapSet.new()
      )
      |> assign(
        :datetime_preferences,
        DateTimeDisplay.preferences_for_user(socket.assigns.current_scope.user)
      )
      |> assign_page_state(empty_page_state, %{})

    if socket.assigns.owner_authorized? do
      {:ok, maybe_start_connected_refresh(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> load_jobs_page(params)
      |> maybe_clear_missing_selected_job()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"filters" => filter_params}, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/admin/jobs?#{JobFilterForm.query_params(filter_params)}")}
  end

  def handle_event("select_attention_filter", %{"attention" => attention}, socket) do
    {:noreply, patch_filter(socket, "attention", attention)}
  end

  def handle_event("select_state_filter", %{"state" => state}, socket) do
    {:noreply, patch_filter(socket, "state", state)}
  end

  def handle_event("select_worker_filter", %{"worker" => worker}, socket) do
    {:noreply, patch_filter(socket, "worker", worker)}
  end

  def handle_event("select_queue_filter", %{"queue" => queue}, socket) do
    {:noreply, patch_filter(socket, "queue", queue)}
  end

  def handle_event("select_target_kind_filter", %{"target-kind" => target_kind}, socket) do
    socket =
      if target_kind == "" do
        patch_filters(socket, %{"target_kind" => "", "target_id" => ""})
      else
        patch_filter(socket, "target_kind", target_kind)
      end

    {:noreply, socket}
  end

  def handle_event("select_show_completed_filter", %{"show-completed" => show_completed}, socket) do
    {:noreply, patch_filter(socket, "show_completed", show_completed)}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/admin/jobs?#{JobFilterForm.clear_filter_query_params(socket.assigns.current_params)}"
     )}
  end

  def handle_event("open_job", %{"job-id" => job_id}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/admin/jobs?#{JobFilterForm.open_job_query_params(socket.assigns.current_params, job_id)}"
     )}
  end

  def handle_event("close_job", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/admin/jobs?#{JobFilterForm.close_job_query_params(socket.assigns.current_params)}"
     )}
  end

  @impl true
  def handle_info({Events, %{pool_id: pool_id, topics: topics}}, socket) do
    if job_status_event?(topics) and MapSet.member?(socket.assigns.subscribed_pool_ids, pool_id) do
      {:noreply, schedule_jobs_reload(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_jobs, socket) do
    {:noreply, refresh_jobs(socket)}
  end

  def handle_info(:fallback_refresh_jobs, socket) do
    schedule_fallback_refresh()
    {:noreply, refresh_jobs(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminComponents.admin_shell
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:jobs}
      alert_notification_center={@alert_notification_center}
    >
      <div id="job-detail-drawer-root" class="drawer drawer-end">
        <input
          id="job-detail-drawer"
          type="checkbox"
          class="drawer-toggle"
          checked={@selected_job != nil}
        />

        <div class="drawer-content min-w-0">
          <section id="admin-jobs-page" class="grid min-w-0 gap-6">
            <AdminComponents.page_header
              id="admin-jobs-page-header"
              title="System Jobs"
              description="Monitor background work and quickly check whether jobs are queued, running, completed, or need attention."
            />

            <AdminComponents.empty_state
              :if={!@owner_authorized?}
              id="admin-jobs-owner-denied"
              title="System jobs require owner access"
              description="Only instance owners can inspect global background job state."
              icon="hero-lock-closed"
            />

            <JobOverview.jobs_overview
              :if={@owner_authorized?}
              overview={@overview}
              hotspots={@hotspots}
            />

            <JobFilters.job_filters
              :if={@owner_authorized?}
              filter_form={@filter_form}
              filters={@filters}
              filter_options={@filter_options}
              filter_errors={@filter_errors}
            />

            <JobExplorer.jobs_explorer
              :if={@owner_authorized?}
              explorer={@explorer}
              current_params={@current_params}
              datetime_preferences={@datetime_preferences}
            />

            <div
              :if={@owner_authorized?}
              id="admin-jobs-worker-grid"
              class="grid gap-4 xl:grid-cols-2"
            >
              <JobWorkerCards.job_worker_card
                :for={card <- @worker_cards}
                card={card}
                datetime_preferences={@datetime_preferences}
              />
            </div>
          </section>
        </div>

        <JobDetailDrawer.job_detail_drawer
          selected_job={@selected_job}
          datetime_preferences={@datetime_preferences}
        />
      </div>
    </AdminComponents.admin_shell>
    """
  end

  defp maybe_clear_missing_selected_job(socket) do
    if (socket.assigns.owner_authorized? and socket.assigns.filters.job_id) &&
         is_nil(socket.assigns.selected_job) do
      push_patch(socket,
        to: ~p"/admin/jobs?#{JobFilterForm.close_job_query_params(socket.assigns.current_params)}"
      )
    else
      socket
    end
  end

  defp patch_filter(socket, field, value) do
    patch_filters(socket, %{field => value})
  end

  defp patch_filters(socket, updates) do
    params = Map.merge(socket.assigns.form_values, updates)
    push_patch(socket, to: ~p"/admin/jobs?#{JobFilterForm.query_params(params)}")
  end

  defp maybe_start_connected_refresh(socket) do
    if socket.assigns.owner_authorized? and connected?(socket) do
      schedule_fallback_refresh()
      reconcile_pool_subscriptions(socket)
    else
      socket
    end
  end

  defp refresh_jobs(socket) do
    if socket.assigns.owner_authorized? do
      socket
      |> cancel_jobs_reload_timer()
      |> assign(:jobs_reload_timer, nil)
      |> load_jobs_page(socket.assigns.current_params)
      |> reconcile_pool_subscriptions()
    else
      socket
    end
  end

  defp load_jobs_page(socket, params) do
    params = jobs_params(socket, params)

    socket.assigns.current_scope
    |> JobsReadModel.load(params: params)
    |> then(&assign_page_state(socket, &1, params))
  end

  defp assign_page_state(socket, page_state, params) do
    assign(socket,
      current_params: params,
      overview: page_state.overview,
      hotspots: page_state.hotspots,
      explorer: page_state.explorer,
      filters: page_state.filters,
      form_values: page_state.form_values,
      filter_options: page_state.filter_options,
      filter_form: JobFilterForm.filter_form(page_state.form_values, page_state.filter_warnings),
      filter_warnings: page_state.filter_warnings,
      filter_errors: page_state.filter_warnings,
      selected_job: page_state.selected_job,
      jobs: page_state.explorer.items,
      worker_cards:
        worker_cards(page_state.worker_jobs_by_group, socket.assigns.datetime_preferences)
    )
  end

  defp jobs_params(socket, params) do
    if socket.assigns.owner_authorized?, do: params, else: %{}
  end

  defp reconcile_pool_subscriptions(socket) do
    if socket.assigns.owner_authorized? and connected?(socket) do
      socket.assigns.current_scope
      |> Pools.list_visible_pools()
      |> PoolEventSubscriptions.pool_id_set()
      |> then(fn target_pool_ids ->
        {socket, _stale_pool_ids} = PoolEventSubscriptions.reconcile(socket, target_pool_ids)
        socket
      end)
    else
      socket
    end
  end

  defp schedule_jobs_reload(socket) do
    if is_reference(socket.assigns.jobs_reload_timer) do
      socket
    else
      timer = Process.send_after(self(), :refresh_jobs, @jobs_reload_debounce_ms)
      assign(socket, :jobs_reload_timer, timer)
    end
  end

  defp cancel_jobs_reload_timer(socket) do
    if is_reference(socket.assigns.jobs_reload_timer) do
      Process.cancel_timer(socket.assigns.jobs_reload_timer, async: false, info: false)
    end

    socket
  end

  defp schedule_fallback_refresh do
    Process.send_after(self(), :fallback_refresh_jobs, @jobs_fallback_refresh_ms)
    :ok
  end

  defp job_status_event?(topics) when is_list(topics), do: "job_status" in topics
  defp job_status_event?(_topics), do: false
end
