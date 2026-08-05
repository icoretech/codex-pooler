defmodule CodexPoolerWeb.Admin.JobsPageComponents.Explorer do
  @moduledoc false

  use CodexPoolerWeb, :html

  import CodexPoolerWeb.Admin.JobsPresentation

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.JobFilterForm
  alias CodexPoolerWeb.Admin.LogPagination
  alias CodexPoolerWeb.DateTimeDisplay

  attr :explorer, :map, required: true
  attr :current_params, :map, required: true
  attr :datetime_preferences, :map, required: true

  def jobs_explorer(assigns) do
    page = LogPagination.metadata(assigns.explorer)

    assigns =
      assigns
      |> assign(:page, page)
      |> assign(
        :previous_path,
        explorer_page_path(assigns.current_params, page.current_page - 1, page.has_previous_page)
      )
      |> assign(
        :next_path,
        explorer_page_path(assigns.current_params, page.current_page + 1, page.has_next_page)
      )

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

      <LogPagination.pager
        :if={@explorer.items != []}
        id="admin-jobs-explorer-pagination"
        label="Jobs explorer pagination"
        page={@page}
        previous_path={@previous_path}
        next_path={@next_path}
      />

      <AdminComponents.empty_state
        :if={@explorer.items == []}
        id="admin-jobs-empty-state"
        title="No jobs match these filters"
        description="Adjust the filters or include completed jobs to widen the explorer result set."
        icon="hero-queue-list"
      />

      <div
        :if={@explorer.items != []}
        id="admin-jobs-explorer-rows"
        data-role="explorer-rows"
        class="rounded-box border border-base-300 bg-base-100 lg:overflow-x-auto"
      >
        <table
          id="admin-jobs-explorer-table"
          class="admin-ledger-table admin-status-tick table table-sm admin-log-table lg:min-w-[72rem]"
        >
          <%!-- Before the columns, which is where the content model puts it:
          a caption written anywhere else is reparented by the parser rather
          than rendered where it stands. --%>
          <caption class="sr-only">
            Jobs explorer, {explorer_total(@explorer)}
          </caption>
          <colgroup>
            <col style="width: 24rem;" />
            <col style="width: 18rem;" />
            <col style="width: 13rem;" />
            <col style="width: 5rem;" />
            <col style="width: 14rem;" />
          </colgroup>
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
      data-tone={job_state_tone(@job.state)}
      phx-click="open_job"
      phx-value-job-id={@job.id}
      class="group/job cursor-pointer transition-colors hover:bg-base-200/80"
    >
      <td class="min-w-0 align-middle max-lg:col-start-2 max-lg:row-start-1 max-lg:self-baseline">
        <.job_compact_identity job={@job} />
      </td>
      <td class="min-w-0 align-middle max-lg:col-span-2 max-lg:col-start-2 max-lg:row-start-2">
        <.job_target_summary job={@job} />
      </td>
      <td class="whitespace-nowrap align-middle text-base-content/70 max-lg:col-start-3 max-lg:row-start-1 max-lg:self-baseline max-lg:text-right">
        <.job_event job={@job} datetime_preferences={@datetime_preferences} />
      </td>
      <td
        class={[
          "align-middle tabular-nums text-base-content/75",
          "max-lg:col-start-3 max-lg:row-start-2 max-lg:row-end-4 max-lg:self-end",
          "max-lg:text-right max-lg:text-xs max-lg:leading-tight",
          !attempted?(@job) && "max-lg:hidden"
        ]}
        data-role="attempts"
      >
        {format_attempts(@job)}
      </td>
      <td class="min-w-0 align-middle max-lg:col-span-2 max-lg:col-start-2 max-lg:row-start-3 max-lg:mt-1 max-lg:has-[.job-failure-empty]:hidden">
        <.job_failure job={@job} />
      </td>
    </tr>
    """
  end

  attr :job, :map, required: true

  defp job_compact_identity(assigns) do
    ~H"""
    <div class="grid min-w-0 gap-0.5">
      <button
        id={"job-#{@job.id}-open-details"}
        type="button"
        data-role="worker"
        phx-click="open_job"
        phx-value-job-id={@job.id}
        title={safe_text(@job.worker)}
        class="block w-full truncate text-left text-[0.82rem] font-semibold leading-tight text-base-content transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary group-hover/job:text-primary"
      >
        {job_worker_label(@job.worker)}
      </button>
      <span
        data-role="job-meta"
        class="flex min-w-0 flex-wrap items-baseline gap-x-1.5 gap-y-0.5 leading-tight text-base-content/50 max-lg:hidden"
        title={"Job ##{@job.id} · #{job_state_label(@job.state)}"}
      >
        <span class="shrink-0">#{@job.id}</span>
        <span aria-hidden="true">·</span>
        <span data-role="state-label" class={job_state_text_class(@job.state)}>
          {job_state_label(@job.state)}
        </span>
      </span>
    </div>
    """
  end

  attr :job, :map, required: true

  defp job_target_summary(assigns) do
    assigns = assign(assigns, target: job_target(assigns.job))

    ~H"""
    <div class="min-w-0 text-base-content/70">
      <p
        data-role="job-target"
        class="flex min-w-0 items-baseline gap-x-1.5 leading-tight max-lg:text-xs"
      >
        <span class={["shrink-0 lg:hidden", job_state_text_class(@job.state)]}>
          {job_state_label(@job.state)}
        </span>
        <span :if={@target} aria-hidden="true" class="shrink-0 text-base-content/30 lg:hidden">
          ·
        </span>
        <span
          :if={@target}
          data-role="target-primary"
          class="min-w-0 truncate font-medium text-base-content/80"
          title={target_title(@target)}
        >
          {target_primary(@target)}
        </span>
        <span :if={is_nil(@target)} data-role="job-target-empty" class="shrink-0 max-lg:hidden">
          -
        </span>
      </p>
      <span
        :if={target_secondary(@target)}
        data-role="target-secondary"
        class="block min-w-0 truncate leading-tight text-base-content/55 max-lg:hidden"
        title={target_secondary_title(@target)}
      >
        {target_secondary(@target)}
      </span>
    </div>
    """
  end

  defp target_primary(%{primary: primary}), do: primary
  defp target_primary(_target), do: nil

  defp target_title(%{primary_title: title}), do: title
  defp target_title(_target), do: nil

  defp target_secondary(%{secondary: secondary}), do: secondary
  defp target_secondary(_target), do: nil

  defp target_secondary_title(%{secondary_title: title}), do: title
  defp target_secondary_title(_target), do: nil

  defp attempted?(%{attempt: attempt}) when is_integer(attempt) and attempt > 0, do: true
  defp attempted?(_job), do: false

  attr :job, :map, required: true
  attr :datetime_preferences, :map, required: true

  defp job_event(assigns) do
    assigns = assign(assigns, event: job_event_summary(assigns.job, assigns.datetime_preferences))

    ~H"""
    <div data-role="job-event" class="grid min-w-0 gap-0.5">
      <span
        data-role="job-event-label"
        class="font-semibold uppercase leading-tight text-base-content/45 max-lg:hidden"
      >
        {@event.label}
      </span>
      <span
        data-role="job-event-time"
        class="truncate leading-tight tabular-nums text-base-content/70 max-lg:hidden"
        title={@event.timestamp}
      >
        {@event.timestamp}
      </span>
      <span
        :if={@event.clock}
        data-role="job-event-clock"
        class="hidden truncate text-xs leading-tight tabular-nums text-base-content/50 max-lg:block"
        title={@event.timestamp}
      >
        {@event.clock}
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
      class="job-failure-empty text-[0.72rem] text-base-content/45"
    >
      -
    </span>
    """
  end

  # The pager renders a disabled control rather than dropping one, so a boundary
  # is a path this page declines to build rather than a link it hides.
  defp explorer_page_path(_current_params, _page, false = _enabled), do: nil

  defp explorer_page_path(current_params, page, true = _enabled),
    do: ~p"/admin/jobs?#{page_query_params(current_params, page)}"

  defp explorer_total(%{total: 1}), do: "1 job"
  defp explorer_total(%{total: total}), do: "#{total} jobs"

  defp job_event_summary(job, datetime_preferences) do
    job
    |> job_event_candidates()
    |> Enum.find(fn {_label, value} -> match?(%DateTime{}, value) end)
    |> case do
      {label, %DateTime{} = datetime} ->
        %{
          label: label,
          timestamp: format_job_timestamp(datetime, datetime_preferences),
          clock: event_clock(datetime, datetime_preferences)
        }

      nil ->
        %{label: "Observed", timestamp: "-", clock: nil}
    end
  end

  # The ledger line has room for the clock only; the full stamp stays in the
  # title and in the drawer. Honors the operator's format and timezone.
  defp event_clock(datetime, datetime_preferences) do
    case DateTimeDisplay.format_datetime_parts(datetime, datetime_preferences) do
      %{time: time} when is_binary(time) and time != "" -> time
      _no_parts -> nil
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
