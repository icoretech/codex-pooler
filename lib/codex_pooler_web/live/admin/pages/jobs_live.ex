defmodule CodexPoolerWeb.Admin.JobsLive do
  use CodexPoolerWeb, :admin_live_view

  import CodexPoolerWeb.Admin.JobsPresentation, only: [worker_cards: 2]

  alias CodexPooler.Events
  alias CodexPooler.Jobs
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.JobFilterForm
  alias CodexPoolerWeb.Admin.JobsPageComponents.DetailDrawer
  alias CodexPoolerWeb.Admin.JobsPageComponents.Explorer
  alias CodexPoolerWeb.Admin.JobsPageComponents.Filters
  alias CodexPoolerWeb.Admin.JobsPageComponents.WorkerCards
  alias CodexPoolerWeb.Admin.JobsReadModel
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.DateTimeDisplay

  @jobs_reload_debounce_ms 1_000
  @jobs_fallback_refresh_ms 5_000
  @worker_failure_job_id_param "failure_job_id"

  @impl true
  def mount(_params, _session, socket) do
    empty_page_state = JobsReadModel.load(nil)

    socket =
      socket
      |> assign(
        page_title: "Jobs",
        owner_authorized?: Pools.owner?(socket.assigns.current_scope),
        jobs_reload_timer: nil,
        jobs_page_loaded?: false,
        subscribed_pool_ids: MapSet.new()
      )
      |> assign(
        :datetime_preferences,
        DateTimeDisplay.preferences_for_user(socket.assigns.current_scope.user)
      )
      |> assign_page_state(empty_page_state, %{})
      |> assign(:jobs_page_loaded?, false)

    if socket.assigns.owner_authorized? do
      {:ok, maybe_start_connected_refresh(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      if selection_only_params_change?(socket, params) do
        assign_selection_state(socket, params)
      else
        load_jobs_page(socket, params)
      end
      |> maybe_clear_missing_selected_job()
      |> maybe_clear_missing_selected_worker_failure()

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

  def handle_event("toggle_worker_failure", %{"job-id" => job_id}, socket) do
    failure_job_id = normalized_positive_integer(job_id)

    {:noreply,
     push_patch(socket,
       to:
         ~p"/admin/jobs?#{toggle_worker_failure_query_params(socket.assigns.current_params, socket.assigns.selected_worker_failure_job_id, failure_job_id)}"
     )}
  end

  def handle_event("close_worker_failure", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/admin/jobs?#{close_worker_failure_query_params(socket.assigns.current_params)}"
     )}
  end

  def handle_event("enqueue_worker_group", %{"id" => worker_group}, socket) do
    if socket.assigns.owner_authorized? do
      case Jobs.enqueue_worker_group_now(worker_group) do
        {:ok, result} ->
          {level, message} = enqueue_worker_group_flash(socket, worker_group, result)

          {:noreply,
           socket
           |> put_flash(level, message)
           |> refresh_jobs()}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, enqueue_worker_group_error(socket, worker_group, reason))}
      end
    else
      {:noreply, put_flash(socket, :error, "System jobs require owner access")}
    end
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

            <div
              :if={@owner_authorized?}
              id="admin-jobs-worker-grid"
              class="grid items-start gap-4 xl:grid-cols-2 2xl:grid-cols-3"
            >
              <WorkerCards.job_worker_card
                :for={card <- @worker_cards}
                card={card}
                datetime_preferences={@datetime_preferences}
                selected_failure_job_id={@selected_worker_failure_job_id}
              />
            </div>

            <Filters.job_filters
              :if={@owner_authorized?}
              filter_form={@filter_form}
              filters={@filters}
              filter_options={@filter_options}
              filter_errors={@filter_errors}
            />

            <Explorer.jobs_explorer
              :if={@owner_authorized?}
              explorer={@explorer}
              current_params={@current_params}
              datetime_preferences={@datetime_preferences}
            />
          </section>
        </div>

        <DetailDrawer.job_detail_drawer
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

  defp maybe_clear_missing_selected_worker_failure(socket) do
    if socket.assigns.owner_authorized? &&
         Map.has_key?(socket.assigns.current_params, @worker_failure_job_id_param) &&
         is_nil(socket.assigns.selected_worker_failure_job_id) do
      push_patch(socket,
        to: ~p"/admin/jobs?#{close_worker_failure_query_params(socket.assigns.current_params)}"
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
    worker_cards =
      worker_cards(page_state.worker_jobs_by_group, socket.assigns.datetime_preferences)

    selected_worker_failure_job_id = selected_worker_failure_job_id(params, worker_cards)

    assign(socket,
      current_params: params,
      overview: page_state.overview,
      explorer: page_state.explorer,
      filters: page_state.filters,
      form_values: page_state.form_values,
      filter_options: page_state.filter_options,
      filter_form: JobFilterForm.filter_form(page_state.form_values, page_state.filter_warnings),
      filter_warnings: page_state.filter_warnings,
      filter_errors: page_state.filter_warnings,
      selected_job: page_state.selected_job,
      selected_worker_failure_job_id: selected_worker_failure_job_id,
      jobs: page_state.explorer.items,
      worker_cards: worker_cards,
      jobs_page_loaded?: true
    )
  end

  defp enqueue_worker_group_flash(socket, worker_group, %{
         inserted: inserted,
         conflicts: conflicts,
         errors: errors
       }) do
    title = worker_group_title(socket, worker_group)
    inserted_count = length(inserted)
    conflicts_count = length(conflicts)
    errors_count = length(errors)

    cond do
      errors_count > 0 ->
        {:error,
         "#{title} enqueue partially failed: #{inserted_count} queued, #{conflicts_count} already queued, #{errors_count} failed"}

      inserted_count == 1 and conflicts_count == 0 ->
        {:info, "#{title} queued"}

      inserted_count == 0 and conflicts_count > 0 ->
        {:info, "#{title} already queued"}

      inserted_count == 0 and conflicts_count == 0 ->
        {:info, enqueue_worker_group_empty_message(socket, worker_group)}

      true ->
        {:info,
         "#{title} enqueue requested: #{inserted_count} queued, #{conflicts_count} already queued"}
    end
  end

  defp enqueue_worker_group_flash(socket, worker_group, %{conflict?: true}) do
    {:info, "#{worker_group_title(socket, worker_group)} already queued"}
  end

  defp enqueue_worker_group_flash(socket, worker_group, %Oban.Job{}) do
    {:info, "#{worker_group_title(socket, worker_group)} queued"}
  end

  defp enqueue_worker_group_empty_message(socket, worker_group) do
    title = worker_group_title(socket, worker_group)

    case worker_group_key(worker_group) do
      "catalog_sync" -> "#{title} has no active pools to sync"
      "account_reconciliation" -> "#{title} has no active assignments to reconcile"
      "alert_evaluation" -> "#{title} has no active alert rules to evaluate"
      _worker_group -> "#{title} has no work to enqueue"
    end
  end

  defp enqueue_worker_group_error(socket, worker_group, :worker_group_requires_target) do
    "#{worker_group_title(socket, worker_group)} requires a target"
  end

  defp enqueue_worker_group_error(_socket, _worker_group, :unknown_worker_group) do
    "Unknown worker group"
  end

  defp enqueue_worker_group_error(socket, worker_group, _reason) do
    "#{worker_group_title(socket, worker_group)} could not be queued"
  end

  defp worker_group_title(socket, worker_group) do
    worker_group_id = worker_group_id(worker_group)
    worker_group_key = String.replace(worker_group_id, "-", "_")

    Enum.find_value(
      socket.assigns.worker_cards,
      fallback_worker_group_title(worker_group),
      fn card ->
        if card.id == worker_group_id or Atom.to_string(card.key) == worker_group_key do
          card.title
        end
      end
    )
  end

  defp worker_group_id(worker_group) when is_atom(worker_group) do
    worker_group
    |> Atom.to_string()
    |> worker_group_id()
  end

  defp worker_group_id(worker_group) when is_binary(worker_group) do
    String.replace(worker_group, "_", "-")
  end

  defp worker_group_key(worker_group) do
    worker_group
    |> to_string()
    |> String.replace("-", "_")
  end

  defp fallback_worker_group_title(worker_group) do
    worker_group
    |> to_string()
    |> String.replace("-", "_")
    |> String.split("_", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp selection_only_params_change?(socket, params) do
    socket.assigns.owner_authorized? and socket.assigns.jobs_page_loaded? and
      projection_query_params(params) == projection_query_params(socket.assigns.current_params)
  end

  defp projection_query_params(params) do
    params
    |> JobFilterForm.query_params()
    |> Map.delete("job_id")
  end

  defp assign_selection_state(socket, params) do
    {filters, form_values, filter_warnings} = JobFilterForm.parse_filters(params)

    assign(socket,
      current_params: params,
      filters: filters,
      form_values: form_values,
      filter_form: JobFilterForm.filter_form(form_values, filter_warnings),
      filter_warnings: filter_warnings,
      filter_errors: filter_warnings,
      selected_job: selected_job(filters.job_id, socket.assigns.explorer.items),
      selected_worker_failure_job_id:
        selected_worker_failure_job_id(params, socket.assigns.worker_cards)
    )
  end

  defp selected_job(nil, _items), do: nil
  defp selected_job(job_id, items), do: Enum.find(items, &(&1.id == job_id))

  defp selected_worker_failure_job_id(params, worker_cards) do
    params
    |> Map.get(@worker_failure_job_id_param)
    |> normalized_positive_integer()
    |> case do
      nil -> nil
      job_id -> if visible_worker_failure_marker?(worker_cards, job_id), do: job_id
    end
  end

  defp visible_worker_failure_marker?(worker_cards, job_id) do
    Enum.any?(worker_cards, fn card ->
      Enum.any?(card.visible_failure_markers, &(&1.id == job_id))
    end)
  end

  defp toggle_worker_failure_query_params(
         params,
         selected_failure_job_id,
         selected_failure_job_id
       ) do
    close_worker_failure_query_params(params)
  end

  defp toggle_worker_failure_query_params(params, _selected_failure_job_id, failure_job_id) do
    params
    |> JobFilterForm.query_params()
    |> maybe_put_worker_failure_job_id(failure_job_id)
  end

  defp close_worker_failure_query_params(params) do
    params
    |> JobFilterForm.query_params()
    |> Map.delete(@worker_failure_job_id_param)
  end

  defp maybe_put_worker_failure_job_id(params, nil), do: params

  defp maybe_put_worker_failure_job_id(params, job_id),
    do: Map.put(params, @worker_failure_job_id_param, Integer.to_string(job_id))

  defp normalized_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp normalized_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _invalid -> nil
    end
  end

  defp normalized_positive_integer(_value), do: nil

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
