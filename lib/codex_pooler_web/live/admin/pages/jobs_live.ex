defmodule CodexPoolerWeb.Admin.JobsLive do
  use CodexPoolerWeb, :live_view

  import CodexPoolerWeb.Admin.JobsPresentation

  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.JobsReadModel
  alias CodexPoolerWeb.Admin.JobWorkerCards
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions

  @jobs_reload_debounce_ms 1_000
  @jobs_fallback_refresh_ms 5_000
  @recent_jobs_limit 15

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Jobs",
        owner_authorized?: Pools.owner?(socket.assigns.current_scope),
        jobs: [],
        worker_cards: worker_cards(%{}),
        recent_jobs: [],
        jobs_reload_timer: nil,
        subscribed_pool_ids: MapSet.new()
      )

    if socket.assigns.owner_authorized? do
      {:ok, socket |> refresh_jobs() |> maybe_start_connected_refresh()}
    else
      {:ok, socket}
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
    <AdminComponents.admin_shell flash={@flash} current_scope={@current_scope} active_nav={:jobs}>
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

        <div :if={@owner_authorized?} id="admin-jobs-worker-grid" class="grid gap-4 xl:grid-cols-2">
          <JobWorkerCards.job_worker_card :for={card <- @worker_cards} card={card} />
        </div>

        <.recent_jobs_surface :if={@owner_authorized?} recent_jobs={@recent_jobs} />
      </section>
    </AdminComponents.admin_shell>
    """
  end

  defp recent_jobs_surface(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="admin-jobs-surface"
      title="Recent activity"
      description="Newest background job records, capped for quick scanning."
    >
      <AdminComponents.empty_state
        :if={@recent_jobs == []}
        id="admin-jobs-empty-state"
        title="No jobs recorded"
        description="Background work has not produced any visible job state metadata yet."
        icon="hero-queue-list"
      />

      <ul :if={@recent_jobs != []} id="admin-jobs-recent-activity" class="divide-y divide-base-300">
        <.recent_job_item :for={job <- @recent_jobs} job={job} />
      </ul>
    </AdminComponents.admin_surface>
    """
  end

  defp recent_job_item(assigns) do
    ~H"""
    <li
      id={"job-#{@job.id}"}
      class="grid gap-3 px-4 py-4 text-sm transition-colors hover:bg-base-200/60 lg:grid-cols-[minmax(0,1.25fr)_minmax(0,1fr)_auto]"
    >
      <div class="flex min-w-0 items-start gap-3">
        <span
          data-role="state-icon"
          title={job_state_label(@job.state)}
          aria-label={"State: #{job_state_label(@job.state)}"}
          class="mt-0.5 shrink-0"
        >
          <.icon name={job_state_icon(@job.state)} class={job_state_icon_class(@job.state)} />
        </span>
        <div class="grid min-w-0 gap-1">
          <span
            data-role="worker"
            class="truncate text-xs font-semibold text-base-content/80"
            title={@job.worker || "not recorded"}
          >
            {@job.worker || "not recorded"}
          </span>
          <details
            :if={failure = job_failure_summary(@job)}
            data-role="failure-details"
            class="group text-xs text-base-content/70"
          >
            <summary class="cursor-pointer list-none text-error marker:hidden hover:underline">
              <span class="inline-flex items-center gap-1">
                <.icon name="hero-exclamation-triangle" class="size-3.5" />
                <span>{failure.title}</span>
              </span>
            </summary>
            <p data-role="failure-message" class="mt-1 leading-relaxed text-base-content/70">
              {failure.message}
            </p>
          </details>
        </div>
      </div>

      <div class="min-w-0 text-xs text-base-content/70">
        <div :if={target = job_target(@job)} data-role="job-target" class="grid gap-1 leading-tight">
          <span
            data-role="target-primary"
            class="truncate font-medium text-base-content/80"
            title={target.primary_title}
          >
            {target.primary}
          </span>
          <span
            :if={target.secondary}
            data-role="target-secondary"
            class="truncate text-base-content/60"
            title={target.secondary_title}
          >
            {target.secondary}
          </span>
        </div>
        <span :if={!job_target(@job)} data-role="job-target-empty">-</span>
      </div>

      <div class="grid gap-1 text-xs text-base-content/60 lg:min-w-72">
        <span class="font-semibold tabular-nums text-base-content/80">
          {format_attempts(@job)}
        </span>
        <span data-role="inserted-at">{timestamp_line("Inserted", @job.inserted_at)}</span>
        <span data-role="scheduled-at">{timestamp_line("Scheduled", @job.scheduled_at)}</span>
        <span data-role="attempted-at">{timestamp_line("Attempted", @job.attempted_at)}</span>
        <span data-role="completed-at">{timestamp_line("Completed", @job.completed_at)}</span>
        <span data-role="discarded-at">{timestamp_line("Discarded", @job.discarded_at)}</span>
        <span data-role="cancelled-at">{timestamp_line("Cancelled", @job.cancelled_at)}</span>
      </div>
    </li>
    """
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
      page_state = JobsReadModel.load(socket.assigns.current_scope, limit: @recent_jobs_limit)

      socket
      |> cancel_jobs_reload_timer()
      |> assign(
        jobs: page_state.recent_jobs,
        worker_cards: worker_cards(page_state.worker_jobs_by_group),
        recent_jobs: page_state.recent_jobs,
        jobs_reload_timer: nil
      )
      |> reconcile_pool_subscriptions()
    else
      socket
    end
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
