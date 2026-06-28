defmodule CodexPoolerWeb.Admin.JobsPageComponents.DetailDrawer do
  @moduledoc false

  use CodexPoolerWeb, :html

  import CodexPoolerWeb.Admin.JobsPresentation,
    only: [
      format_attempts: 1,
      format_job_timestamp: 2,
      job_failure_summary: 1,
      job_state_badge_class: 1,
      job_state_label: 1,
      job_target: 1
    ]

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  attr :selected_job, :map, default: nil
  attr :datetime_preferences, :map, required: true

  def job_detail_drawer(assigns) do
    ~H"""
    <div class="drawer-side z-[70]" data-role="job-detail-drawer-side">
      <label
        for="job-detail-drawer"
        aria-label="Close job details"
        class="drawer-overlay"
        phx-click="close_job"
      ></label>

      <AdminComponents.object_inspector
        id="job-detail-sidebar"
        title={job_title(@selected_job)}
        subtitle={job_subtitle(@selected_job)}
        status={job_status(@selected_job)}
        status_class={job_status_class(@selected_job)}
        close_event="close_job"
        close_label="Close job details"
        role="dialog"
        aria_modal={true}
        class="flex min-h-full w-full max-w-md flex-col overflow-hidden border-l border-base-300 bg-base-100 shadow-2xl"
      >
        <%= if @selected_job do %>
          <section id="job-detail-metadata" class="grid gap-4">
            <div class="grid gap-2">
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                Metadata
              </p>
              <dl class="grid gap-2 text-sm">
                <.detail_row id="job-detail-job-id" label="Job id" value={@selected_job.id} mono />
                <.detail_row id="job-detail-worker" label="Worker" value={@selected_job.worker} />
                <.detail_row id="job-detail-queue" label="Queue" value={@selected_job.queue} />
                <.detail_row
                  id="job-detail-state"
                  label="State"
                  value={job_state_label(@selected_job.state)}
                />
                <.detail_row
                  id="job-detail-health"
                  label="Health"
                  value={health_label(@selected_job)}
                />
                <.detail_row
                  id="job-detail-attempts"
                  label="Attempts"
                  value={format_attempts(@selected_job)}
                  mono
                />
              </dl>
            </div>

            <div class="grid gap-2">
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                Timeline
              </p>
              <dl class="grid gap-2 text-sm sm:grid-cols-2">
                <.detail_row
                  id="job-detail-inserted-at"
                  label="Inserted"
                  value={format_job_timestamp(@selected_job.inserted_at, @datetime_preferences)}
                  mono
                />
                <.detail_row
                  id="job-detail-scheduled-at"
                  label="Scheduled"
                  value={format_job_timestamp(@selected_job.scheduled_at, @datetime_preferences)}
                  mono
                />
                <.detail_row
                  id="job-detail-attempted-at"
                  label="Attempted"
                  value={format_job_timestamp(@selected_job.attempted_at, @datetime_preferences)}
                  mono
                />
                <.detail_row
                  id="job-detail-completed-at"
                  label="Completed"
                  value={format_job_timestamp(@selected_job.completed_at, @datetime_preferences)}
                  mono
                />
                <.detail_row
                  id="job-detail-discarded-at"
                  label="Discarded"
                  value={format_job_timestamp(@selected_job.discarded_at, @datetime_preferences)}
                  mono
                />
                <.detail_row
                  id="job-detail-cancelled-at"
                  label="Cancelled"
                  value={format_job_timestamp(@selected_job.cancelled_at, @datetime_preferences)}
                  mono
                />
              </dl>
            </div>

            <.target_summary job={@selected_job} />
            <.failure_summary job={@selected_job} />
          </section>
        <% else %>
          <div class="grid min-h-64 place-items-center text-center text-sm text-base-content/60">
            Select a job to inspect its details.
          </div>
        <% end %>
      </AdminComponents.object_inspector>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :mono, :boolean, default: false

  defp detail_row(assigns) do
    ~H"""
    <div id={@id} data-role="job-detail-field" class="grid gap-1 rounded-box bg-base-200/60 px-3 py-2">
      <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/45">{@label}</dt>
      <dd class={["break-words text-base-content/80", @mono && "font-mono text-xs tabular-nums"]}>
        {safe_text(@value)}
      </dd>
    </div>
    """
  end

  attr :job, :map, required: true

  defp target_summary(assigns) do
    assigns = assign(assigns, :target, job_target(assigns.job))

    ~H"""
    <section
      id="job-detail-target-summary"
      class="grid gap-2 rounded-box border border-base-300 bg-base-200/45 px-3 py-3"
    >
      <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">Target summary</p>
      <%= if @target do %>
        <p data-role="target-primary" class="break-words text-sm font-medium text-base-content/85">
          {@target.primary}
        </p>
        <p
          :if={@target.secondary}
          data-role="target-secondary"
          class="break-words text-xs leading-5 text-base-content/65"
        >
          {@target.secondary}
        </p>
      <% else %>
        <p data-role="target-empty" class="text-sm text-base-content/60">System job</p>
      <% end %>
    </section>
    """
  end

  attr :job, :map, required: true

  defp failure_summary(assigns) do
    assigns = assign(assigns, :failure, failure_detail(assigns.job))

    ~H"""
    <section
      id="job-detail-failure-summary"
      class="grid gap-2 rounded-box border border-base-300 bg-base-200/45 px-3 py-3"
    >
      <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
        Latest error summary
      </p>
      <p data-role="failure-title" class="text-sm font-semibold text-error">{@failure.title}</p>
      <p data-role="failure-message" class="break-words text-sm leading-6 text-base-content/75">
        {@failure.message}
      </p>
    </section>
    """
  end

  defp failure_detail(job) do
    case job_failure_summary(job) do
      %{title: title, message: message} when is_binary(title) and is_binary(message) ->
        %{title: title, message: message}

      _missing ->
        %{title: "Failure detail", message: "No diagnostic message recorded."}
    end
  end

  defp health_label(%{attention_state: attention_state}) when is_atom(attention_state) do
    attention_state
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp health_label(%{attention_state: attention_state}) when is_binary(attention_state) do
    attention_state
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp health_label(_job), do: "Unknown"

  defp job_title(%{id: id}), do: "Job ##{id}"
  defp job_title(_job), do: "Job details"

  defp job_subtitle(%{worker: worker}), do: safe_text(worker)
  defp job_subtitle(_job), do: nil

  defp job_status(%{state: state}), do: job_state_label(state)
  defp job_status(_job), do: nil

  defp job_status_class(%{state: state}), do: job_state_badge_class(state)
  defp job_status_class(_job), do: nil

  defp safe_text(value, fallback \\ "-")
  defp safe_text(nil, fallback), do: fallback

  defp safe_text(value, fallback) when is_binary(value),
    do: if(value == "", do: fallback, else: value)

  defp safe_text(value, _fallback) when is_integer(value), do: Integer.to_string(value)
  defp safe_text(value, _fallback), do: to_string(value)
end
