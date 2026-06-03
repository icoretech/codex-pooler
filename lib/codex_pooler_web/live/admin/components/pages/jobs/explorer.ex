defmodule CodexPoolerWeb.Admin.JobExplorer do
  @moduledoc false

  use CodexPoolerWeb, :html

  import CodexPoolerWeb.Admin.JobsPresentation

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.JobFilterForm

  attr :explorer, :map, required: true
  attr :current_params, :map, required: true
  attr :datetime_preferences, :map, required: true

  def jobs_explorer(assigns) do
    assigns = assign(assigns, pagination(assigns.explorer))

    ~H"""
    <AdminComponents.admin_surface
      id="admin-jobs-explorer"
      title="Jobs explorer"
      description="Global background job records from the current filters. Completed jobs stay hidden unless the visibility filter includes them."
      count={explorer_total(@explorer)}
    >
      <:toolbar>
        <div
          id="admin-jobs-explorer-summary"
          class="flex flex-wrap items-center justify-between gap-3 text-sm text-base-content/70"
        >
          <p id="admin-jobs-explorer-total" data-role="explorer-total" class="font-medium">
            {explorer_total(@explorer)}
          </p>
          <p id="admin-jobs-explorer-range" data-role="explorer-range" class="tabular-nums">
            {explorer_range(@explorer)}
          </p>
        </div>
      </:toolbar>

      <AdminComponents.empty_state
        :if={@explorer.items == []}
        id="admin-jobs-empty-state"
        title="No jobs match these filters"
        description="Adjust the filters or include completed jobs to widen the explorer result set."
        icon="hero-queue-list"
      />

      <div
        :if={@explorer.items != []}
        id="admin-jobs-explorer-desktop"
        data-role="explorer-desktop"
        class="hidden overflow-x-auto lg:block"
      >
        <table id="admin-jobs-explorer-table" class="table table-zebra table-sm w-full align-top">
          <thead>
            <tr class="text-xs uppercase tracking-wide text-base-content/60">
              <th class="w-72">Job</th>
              <th>Target</th>
              <th class="w-32">Attempts</th>
              <th class="w-72">Timeline</th>
              <th class="w-64">Failure</th>
            </tr>
          </thead>
          <tbody>
            <.job_table_row
              :for={job <- @explorer.items}
              job={job}
              datetime_preferences={@datetime_preferences}
            />
          </tbody>
        </table>
      </div>

      <div
        :if={@explorer.items != []}
        id="admin-jobs-explorer-mobile"
        data-role="explorer-mobile"
        class="grid gap-3 p-3 lg:hidden"
      >
        <.job_card
          :for={job <- @explorer.items}
          job={job}
          datetime_preferences={@datetime_preferences}
        />
      </div>

      <:footer>
        <nav
          id="admin-jobs-explorer-pagination"
          class="flex flex-wrap items-center justify-between gap-3 text-sm"
          aria-label="Jobs explorer pagination"
        >
          <p data-role="pagination-status" class="text-base-content/60">
            Page {@current_page} of {@total_pages}
          </p>
          <div class="join">
            <.pagination_link
              id="admin-jobs-explorer-pagination-prev"
              label="Previous"
              enabled={@has_previous_page}
              page={@current_page - 1}
              current_params={@current_params}
            />
            <.pagination_link
              id="admin-jobs-explorer-pagination-next"
              label="Next"
              enabled={@has_next_page}
              page={@current_page + 1}
              current_params={@current_params}
            />
          </div>
        </nav>
      </:footer>
    </AdminComponents.admin_surface>
    """
  end

  attr :job, :map, required: true
  attr :datetime_preferences, :map, required: true

  defp job_table_row(assigns) do
    ~H"""
    <tr
      id={"job-#{@job.id}"}
      data-role="job-row"
      data-job-id={@job.id}
      phx-click="open_job"
      phx-value-job-id={@job.id}
      class="cursor-pointer align-top transition-colors hover:bg-base-200/60"
    >
      <td>
        <.job_identity job={@job} />
      </td>
      <td>
        <.job_target_summary job={@job} />
      </td>
      <td class="font-mono text-xs tabular-nums text-base-content/80" data-role="attempts">
        {format_attempts(@job)}
      </td>
      <td>
        <.job_timeline job={@job} datetime_preferences={@datetime_preferences} />
      </td>
      <td>
        <.job_failure job={@job} />
      </td>
    </tr>
    """
  end

  attr :job, :map, required: true
  attr :datetime_preferences, :map, required: true

  defp job_card(assigns) do
    ~H"""
    <article
      id={"job-card-#{@job.id}"}
      data-role="job-card"
      data-job-id={@job.id}
      phx-click="open_job"
      phx-value-job-id={@job.id}
      class="grid cursor-pointer gap-3 rounded-box border border-base-300 bg-base-100 p-4 text-sm shadow-sm transition-colors hover:bg-base-200/60"
    >
      <.job_identity job={@job} />
      <.job_target_summary job={@job} />
      <div class="flex flex-wrap items-center gap-2 text-xs text-base-content/60">
        <span class="font-semibold text-base-content/80">Attempts</span>
        <span data-role="attempts" class="font-mono tabular-nums">{format_attempts(@job)}</span>
      </div>
      <.job_timeline job={@job} datetime_preferences={@datetime_preferences} />
      <.job_failure job={@job} />
    </article>
    """
  end

  attr :job, :map, required: true

  defp job_identity(assigns) do
    ~H"""
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
        <span data-role="state-label" class={job_state_badge_class(@job.state)}>
          {job_state_label(@job.state)}
        </span>
        <span
          data-role="worker"
          class="truncate text-xs font-semibold text-base-content/80"
          title={safe_text(@job.worker)}
        >
          {safe_text(@job.worker)}
        </span>
        <span
          data-role="queue"
          class="truncate text-xs text-base-content/55"
          title={safe_text(@job.queue)}
        >
          Queue {safe_text(@job.queue)}
        </span>
      </div>
    </div>
    """
  end

  attr :job, :map, required: true

  defp job_target_summary(assigns) do
    ~H"""
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
    """
  end

  attr :job, :map, required: true
  attr :datetime_preferences, :map, required: true

  defp job_timeline(assigns) do
    ~H"""
    <div class="grid gap-1 text-xs text-base-content/60">
      <span data-role="inserted-at">
        {timestamp_line("Inserted", @job.inserted_at, @datetime_preferences)}
      </span>
      <span data-role="scheduled-at">
        {timestamp_line("Scheduled", @job.scheduled_at, @datetime_preferences)}
      </span>
      <span data-role="attempted-at">
        {timestamp_line("Attempted", @job.attempted_at, @datetime_preferences)}
      </span>
      <span data-role="completed-at">
        {timestamp_line("Completed", @job.completed_at, @datetime_preferences)}
      </span>
      <span data-role="discarded-at">
        {timestamp_line("Discarded", @job.discarded_at, @datetime_preferences)}
      </span>
      <span data-role="cancelled-at">
        {timestamp_line("Cancelled", @job.cancelled_at, @datetime_preferences)}
      </span>
    </div>
    """
  end

  attr :job, :map, required: true

  defp job_failure(assigns) do
    ~H"""
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
    <span
      :if={!job_failure_summary(@job)}
      data-role="failure-empty"
      class="text-xs text-base-content/45"
    >
      -
    </span>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :enabled, :boolean, required: true
  attr :page, :integer, required: true
  attr :current_params, :map, required: true

  defp pagination_link(assigns) do
    ~H"""
    <.link
      :if={@enabled}
      id={@id}
      data-role="pagination-link"
      patch={~p"/admin/jobs?#{page_query_params(@current_params, @page)}"}
      class="btn btn-sm join-item"
    >
      {@label}
    </.link>
    <span
      :if={!@enabled}
      id={@id}
      data-role="pagination-link"
      aria-disabled="true"
      class="btn btn-sm join-item btn-disabled"
    >
      {@label}
    </span>
    """
  end

  defp pagination(%{total: total, limit: limit, offset: offset}) do
    current_page = div(offset, limit) + 1
    total_pages = max(ceil(total / limit), 1)

    %{
      current_page: current_page,
      total_pages: total_pages,
      has_previous_page: offset > 0,
      has_next_page: offset + limit < total
    }
  end

  defp explorer_total(%{total: 1}), do: "1 job"
  defp explorer_total(%{total: total}), do: "#{total} jobs"

  defp explorer_range(%{total: 0}), do: "Showing 0 of 0"

  defp explorer_range(%{total: total, limit: limit, offset: offset}) do
    first = offset + 1
    last = min(offset + limit, total)
    "Showing #{first}-#{last} of #{total}"
  end

  defp page_query_params(current_params, page) do
    current_params
    |> Map.put("page", Integer.to_string(max(page, 1)))
    |> JobFilterForm.query_params()
  end

  defp safe_text(value, fallback \\ "-")

  defp safe_text(value, fallback) when is_binary(value),
    do: if(value == "", do: fallback, else: value)

  defp safe_text(_value, fallback), do: fallback
end
