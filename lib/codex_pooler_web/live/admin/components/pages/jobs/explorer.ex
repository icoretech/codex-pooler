defmodule CodexPoolerWeb.Admin.JobsPageComponents.Explorer do
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
    <section
      id="admin-jobs-explorer"
      class="grid min-w-0 gap-3"
    >
      <header class="sr-only">
        <h2>Jobs explorer</h2>
        <p>
          Global background job records from the current filters. Completed jobs stay hidden unless the visibility filter includes them.
        </p>
      </header>

      <p
        id="admin-jobs-explorer-total"
        data-role="explorer-total"
        class="sr-only"
      >
        {explorer_total(@explorer)}
      </p>

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
        class="hidden overflow-x-auto rounded-box border border-base-300 bg-base-100 shadow-sm lg:block"
      >
        <table
          id="admin-jobs-explorer-table"
          class="table table-sm admin-log-table min-w-[72rem]"
        >
          <colgroup>
            <col style="width: 24rem;" />
            <col style="width: 18rem;" />
            <col style="width: 13rem;" />
            <col style="width: 5rem;" />
            <col style="width: 14rem;" />
          </colgroup>
          <caption class="sr-only">
            Jobs explorer, {explorer_total(@explorer)}
          </caption>
          <thead>
            <tr>
              <th class="whitespace-nowrap">Job</th>
              <th class="whitespace-nowrap">Target</th>
              <th class="whitespace-nowrap">Last event</th>
              <th class="whitespace-nowrap">Attempts</th>
              <th class="whitespace-nowrap">Failure</th>
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
        class="grid gap-3 lg:hidden"
      >
        <.job_card
          :for={job <- @explorer.items}
          job={job}
          datetime_preferences={@datetime_preferences}
        />
      </div>

      <footer class="border-t border-base-300/70 py-3">
        <nav
          id="admin-jobs-explorer-pagination"
          class="grid gap-3 text-sm sm:grid-cols-[auto_minmax(0,1fr)_auto] sm:items-center"
          aria-label="Jobs explorer pagination"
        >
          <p data-role="pagination-status" class="text-base-content/60">
            Page {@current_page} of {@total_pages}
          </p>
          <p
            id="admin-jobs-explorer-range"
            data-role="explorer-range"
            class="text-center tabular-nums text-base-content/70"
          >
            {explorer_range(@explorer)}
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
      </footer>
    </section>
    """
  end

  attr :job, :map, required: true
  attr :datetime_preferences, :map, required: true

  defp job_table_row(assigns) do
    ~H"""
    <tr
      id={"job-#{@job.id}"}
      data-role="job-row"
      data-density="compact"
      data-job-id={@job.id}
      phx-click="open_job"
      phx-value-job-id={@job.id}
      class="cursor-pointer transition-colors hover:bg-base-200/80"
    >
      <td class="min-w-0 align-middle">
        <.job_compact_identity job={@job} />
      </td>
      <td class="min-w-0 align-middle">
        <.job_target_summary job={@job} />
      </td>
      <td class="whitespace-nowrap align-middle text-base-content/70">
        <.job_event job={@job} datetime_preferences={@datetime_preferences} />
      </td>
      <td
        class="align-middle tabular-nums text-base-content/75"
        data-role="attempts"
      >
        {format_attempts(@job)}
      </td>
      <td class="min-w-0 align-middle">
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
        <span data-role="attempts" class="tabular-nums">{format_attempts(@job)}</span>
      </div>
      <.job_timeline job={@job} datetime_preferences={@datetime_preferences} />
      <.job_failure job={@job} />
    </article>
    """
  end

  attr :job, :map, required: true

  defp job_compact_identity(assigns) do
    ~H"""
    <div class="grid min-w-0 gap-0.5">
      <span
        data-role="worker"
        class="truncate text-[0.82rem] font-semibold leading-tight text-base-content"
        title={safe_text(@job.worker)}
      >
        {safe_text(@job.worker)}
      </span>
      <span
        data-role="job-meta"
        class="flex min-w-0 flex-wrap items-baseline gap-x-1.5 gap-y-0.5 leading-tight text-base-content/50"
        title={"Job ##{@job.id} · Queue #{safe_text(@job.queue)} · #{job_state_label(@job.state)}"}
      >
        <span class="shrink-0">#{@job.id}</span>
        <span aria-hidden="true">·</span>
        <span data-role="queue" class="shrink-0">Queue {safe_text(@job.queue)}</span>
        <span aria-hidden="true">·</span>
        <span data-role="state-label" class={job_state_text_class(@job.state)}>
          {job_state_label(@job.state)}
        </span>
      </span>
    </div>
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
    <div class="min-w-0 text-base-content/70">
      <div
        :if={target = job_target(@job)}
        data-role="job-target"
        class="grid min-w-0 gap-0.5 leading-tight"
      >
        <span
          data-role="target-primary"
          class="min-w-0 truncate font-medium text-base-content/80"
          title={target.primary_title}
        >
          {target.primary}
        </span>
        <span
          :if={target.secondary}
          data-role="target-secondary"
          class="min-w-0 truncate text-base-content/55"
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

  defp job_event(assigns) do
    assigns = assign(assigns, event: job_event_summary(assigns.job, assigns.datetime_preferences))

    ~H"""
    <div data-role="job-event" class="grid min-w-0 gap-0.5">
      <span
        data-role="job-event-label"
        class="font-semibold uppercase leading-tight text-base-content/45"
      >
        {@event.label}
      </span>
      <span
        data-role="job-event-time"
        class="truncate leading-tight tabular-nums text-base-content/70"
        title={@event.timestamp}
      >
        {@event.timestamp}
      </span>
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
    <div
      :if={failure = job_failure_summary(@job)}
      data-role="failure-details"
      class="flex min-w-0 items-center gap-1 text-[0.72rem] leading-tight text-error"
      title={failure.message}
    >
      <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0" />
      <span data-role="failure-title" class="min-w-0 truncate">{failure.title}</span>
      <span data-role="failure-message" class="sr-only">
        {failure.message}
      </span>
    </div>
    <span
      :if={!job_failure_summary(@job)}
      data-role="failure-empty"
      class="text-[0.72rem] text-base-content/45"
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

  defp job_state_text_class(state) do
    state
    |> job_state_badge_class()
    |> String.split()
    |> Enum.filter(&String.starts_with?(&1, "text-"))
    |> Enum.concat(["font-semibold"])
    |> Enum.join(" ")
  end

  defp job_event_summary(job, datetime_preferences) do
    job
    |> job_event_candidates()
    |> Enum.find(fn {_label, value} -> match?(%DateTime{}, value) end)
    |> case do
      {label, %DateTime{} = datetime} ->
        %{label: label, timestamp: format_job_timestamp(datetime, datetime_preferences)}

      nil ->
        %{label: "Observed", timestamp: "-"}
    end
  end

  defp job_event_candidates(%{state: "completed"} = job) do
    [
      {"Completed", job.completed_at},
      {"Attempted", job.attempted_at},
      {"Inserted", job.inserted_at}
    ]
  end

  defp job_event_candidates(%{state: "discarded"} = job) do
    [
      {"Discarded", job.discarded_at},
      {"Attempted", job.attempted_at},
      {"Inserted", job.inserted_at}
    ]
  end

  defp job_event_candidates(%{state: "cancelled"} = job) do
    [
      {"Cancelled", job.cancelled_at},
      {"Attempted", job.attempted_at},
      {"Inserted", job.inserted_at}
    ]
  end

  defp job_event_candidates(%{state: state} = job) when state in ["scheduled", "retryable"] do
    [
      {"Scheduled", job.scheduled_at},
      {"Attempted", job.attempted_at},
      {"Inserted", job.inserted_at}
    ]
  end

  defp job_event_candidates(%{state: "executing"} = job) do
    [
      {"Attempted", job.attempted_at},
      {"Scheduled", job.scheduled_at},
      {"Inserted", job.inserted_at}
    ]
  end

  defp job_event_candidates(job) do
    [
      {"Scheduled", job.scheduled_at},
      {"Attempted", job.attempted_at},
      {"Inserted", job.inserted_at}
    ]
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
