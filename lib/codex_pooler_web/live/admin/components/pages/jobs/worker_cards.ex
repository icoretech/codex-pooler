defmodule CodexPoolerWeb.Admin.JobWorkerCards do
  @moduledoc false

  use CodexPoolerWeb, :html

  import CodexPoolerWeb.Admin.JobsPresentation

  attr :card, :map, required: true
  attr :datetime_preferences, :map, required: true

  def job_worker_card(assigns) do
    ~H"""
    <article
      id={"job-worker-card-#{@card.id}"}
      class="grid min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100 shadow-sm"
    >
      <.job_worker_card_header card={@card} />

      <%= if @card.key == :account_reconciliation do %>
        <.account_reconciliation_activity card={@card} datetime_preferences={@datetime_preferences} />
      <% else %>
        <.worker_activity_strip card={@card} />
        <.job_failure_dialog
          :for={marker <- @card.failure_markers}
          marker={marker}
          datetime_preferences={@datetime_preferences}
        />
        <.worker_schedule_facts card={@card} datetime_preferences={@datetime_preferences} />
      <% end %>
    </article>
    """
  end

  defp job_worker_card_header(assigns) do
    ~H"""
    <header class="grid min-w-0 gap-4 px-5 pb-4 pt-5 sm:grid-cols-[minmax(0,1fr)_auto]">
      <div class="flex min-w-0 items-start gap-3">
        <span class="grid size-10 shrink-0 place-items-center rounded-box border border-base-300 bg-base-200 text-base-content/70">
          <.icon name={@card.icon} class="size-5" />
        </span>
        <div class="grid min-w-0 gap-1">
          <h2 class="truncate text-base font-semibold text-base-content">{@card.title}</h2>
          <p class="text-sm leading-6 text-base-content/60">{@card.description}</p>
        </div>
      </div>

      <div class="flex flex-wrap items-start gap-2 sm:justify-end">
        <span
          data-role="state-icon"
          title={@card.state_label}
          aria-label={"State: #{@card.state_label}"}
          class={[
            "inline-flex shrink-0 items-center gap-2 rounded-box border px-2.5 py-1 text-xs font-semibold",
            job_state_badge_class(@card.state)
          ]}
        >
          <span
            :if={@card.live_state}
            data-role="worker-live-dot"
            class="size-2 rounded-full bg-current motion-safe:animate-pulse"
          />
          <.icon :if={!@card.live_state} name={job_state_icon(@card.state)} class="size-4" />
          <span>{@card.state_label}</span>
        </span>
      </div>
    </header>
    """
  end

  attr :card, :map, required: true
  attr :datetime_preferences, :map, required: true

  defp account_reconciliation_activity(assigns) do
    ~H"""
    <section class="job-target-board" data-role="worker-activity-strip">
      <div class="target-band">
        <div class="target-copy">
          <span class="target-kicker">Live targets</span>
          <strong class="target-title">Account fan-out slots are always visible</strong>
          <span class="target-subcopy">
            Empty slots stay reserved until workers claim upstream assignments.
          </span>
        </div>
        <div class="target-stack" aria-label="Account reconciliation targets">
          <span
            :for={marker <- @card.active_markers}
            id={"job-activity-#{marker.id}"}
            class="target-avatar"
            data-live
            data-role="active-worker-marker"
            title={marker.title}
            aria-label={marker.title}
            data-has-image={marker.avatar_url && "true"}
          >
            <img
              :if={marker.avatar_url}
              src={marker.avatar_url}
              alt=""
              loading="lazy"
              referrerpolicy="no-referrer"
              aria-hidden="true"
            />
            <span :if={!marker.avatar_url} data-role="target-initial">{marker.glyph}</span>
          </span>
          <button
            :for={marker <- @card.failure_markers}
            id={"job-failure-#{marker.id}"}
            type="button"
            class="target-avatar"
            data-failed
            data-role="failed-worker-marker"
            title={marker.title}
            aria-label={marker.title}
            onclick={"document.getElementById('job-failure-dialog-#{marker.id}').showModal()"}
            data-has-image={marker.avatar_url && "true"}
          >
            <img
              :if={marker.avatar_url}
              src={marker.avatar_url}
              alt=""
              loading="lazy"
              referrerpolicy="no-referrer"
              aria-hidden="true"
            />
            <span :if={!marker.avatar_url} data-role="target-initial">{marker.glyph}</span>
          </button>
          <span
            :for={slot <- 1..3}
            :if={@card.active_markers == [] and @card.failure_markers == []}
            class="target-avatar"
            title={"Reserved target slot #{slot}"}
          >
            <.icon name="hero-user-circle" class="size-4" />
          </span>
        </div>
      </div>

      <.job_failure_dialog
        :for={marker <- @card.failure_markers}
        marker={marker}
        datetime_preferences={@datetime_preferences}
      />

      <div class="target-schedule">
        <div class="next-run">
          <span class="target-label">Next run</span>
          <strong data-role="next-run" title={@card.next_run_title}>
            {@card.next_run}
          </strong>
          <span class="target-subcopy">{@card.cadence_label}</span>
        </div>
        <dl class="run-facts">
          <div class="run-fact">
            <dt class="target-label">Last run</dt>
            <dd>{format_job_timestamp(@card.last_seen_at, @datetime_preferences)}</dd>
          </div>
          <div class="run-fact">
            <dt class="target-label">Last success</dt>
            <dd>{format_job_timestamp(@card.last_success_at, @datetime_preferences)}</dd>
          </div>
          <div class="run-fact">
            <dt class="target-label">Last failure</dt>
            <dd>{format_job_timestamp(@card.last_failure_at, @datetime_preferences)}</dd>
          </div>
          <div class="run-fact">
            <dt class="target-label">Attempts</dt>
            <dd>{@card.attempts}</dd>
          </div>
        </dl>
      </div>
    </section>
    """
  end

  defp worker_activity_strip(assigns) do
    ~H"""
    <section
      :if={@card.active_markers != [] or @card.failure_markers != []}
      data-role="worker-activity-strip"
      class="border-t border-base-300 bg-base-200/35 px-5 py-3"
    >
      <div class="flex min-w-0 flex-wrap items-center justify-between gap-3">
        <span class="text-xs font-medium text-base-content/60">{@card.activity_label}</span>

        <div class="flex min-w-0 flex-wrap items-center gap-1.5">
          <span
            :for={marker <- @card.active_markers}
            id={"job-activity-#{marker.id}"}
            data-role="active-worker-marker"
            aria-label={marker.title}
            title={marker.title}
            class="relative grid size-8 shrink-0 place-items-center overflow-hidden rounded-full border border-info/50 bg-info/10 text-[0.6875rem] font-semibold leading-none text-info shadow-sm"
          >
            <img
              :if={marker.avatar_url}
              src={marker.avatar_url}
              alt=""
              class="size-full rounded-full object-cover"
              loading="lazy"
              referrerpolicy="no-referrer"
              aria-hidden="true"
            />
            <span :if={!marker.avatar_url} data-role="target-initial">{marker.glyph}</span>
            <span
              data-role="target-live-indicator"
              class="absolute -bottom-0.5 -right-0.5 size-2.5 rounded-full bg-info ring-2 ring-base-100 motion-safe:animate-pulse"
            />
          </span>

          <button
            :for={marker <- @card.failure_markers}
            id={"job-failure-#{marker.id}"}
            type="button"
            data-role="failed-worker-marker"
            aria-label={marker.title}
            title={marker.title}
            class="relative grid size-8 shrink-0 place-items-center overflow-hidden rounded-full border border-error/60 bg-error/10 text-[0.6875rem] font-semibold leading-none text-error shadow-sm transition-colors hover:bg-error/15 focus:outline-none focus:ring-2 focus:ring-error/40"
            onclick={"document.getElementById('job-failure-dialog-#{marker.id}').showModal()"}
          >
            <img
              :if={marker.avatar_url}
              src={marker.avatar_url}
              alt=""
              class="size-full rounded-full object-cover"
              loading="lazy"
              referrerpolicy="no-referrer"
              aria-hidden="true"
            />
            <span :if={!marker.avatar_url} data-role="target-initial">{marker.glyph}</span>
            <span class="absolute -bottom-0.5 -right-0.5 grid size-3.5 place-items-center rounded-full bg-error text-error-content ring-2 ring-base-100">
              <.icon name="hero-exclamation-triangle" class="size-2.5" />
            </span>
          </button>
        </div>
      </div>
    </section>
    """
  end

  attr :marker, :map, required: true
  attr :datetime_preferences, :map, required: true

  defp job_failure_dialog(assigns) do
    ~H"""
    <dialog id={"job-failure-dialog-#{@marker.id}"} data-role="failed-worker-dialog" class="modal">
      <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <header class="border-b border-base-300 px-5 py-4">
          <p class="text-xs font-semibold uppercase text-error">Job failure</p>
          <h3 class="mt-1 text-lg font-semibold text-base-content">
            {@marker.target_label}
          </h3>
          <p class="mt-1 text-xs text-base-content/60">{@marker.worker_label}</p>
        </header>
        <div class="grid gap-3 px-5 py-4 text-sm">
          <p class="font-semibold text-error">{@marker.failure.title}</p>
          <p data-role="failure-message" class="leading-relaxed text-base-content/70">
            {@marker.failure.message}
          </p>
          <dl class="grid gap-2 text-xs text-base-content/60 sm:grid-cols-2">
            <div>
              <dt>Last failure</dt>
              <dd class="tabular-nums text-base-content">
                {format_job_timestamp(@marker.failed_at, @datetime_preferences)}
              </dd>
            </div>
            <div>
              <dt>Attempts</dt>
              <dd class="tabular-nums text-base-content">{@marker.attempts}</dd>
            </div>
          </dl>
        </div>
        <form method="dialog" class="modal-action mt-0 border-t border-base-300 px-5 py-4">
          <button class="btn btn-sm">Close</button>
        </form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button>close</button>
      </form>
    </dialog>
    """
  end

  attr :card, :map, required: true
  attr :datetime_preferences, :map, required: true

  defp worker_schedule_facts(assigns) do
    ~H"""
    <section class="grid gap-4 border-t border-base-300 px-5 py-4 md:grid-cols-[minmax(8rem,0.8fr)_minmax(0,1.2fr)]">
      <div class="grid content-start gap-1">
        <span class="text-xs text-base-content/50">Next run</span>
        <strong
          data-role="next-run"
          class="text-lg font-semibold leading-tight text-base-content"
          title={@card.next_run_title}
        >
          {@card.next_run}
        </strong>
        <span
          :if={@card.cadence_label != @card.next_run}
          class="truncate text-xs text-base-content/50"
          title={@card.cadence_label}
        >
          {@card.cadence_label}
        </span>
      </div>

      <dl class="grid grid-cols-2 gap-x-5 gap-y-3 text-xs sm:grid-cols-4">
        <div class="grid min-w-0 gap-1">
          <dt class="text-base-content/50">Last run</dt>
          <dd class="font-semibold tabular-nums text-base-content">
            {format_job_timestamp(@card.last_seen_at, @datetime_preferences)}
          </dd>
        </div>
        <div class="grid min-w-0 gap-1">
          <dt class="text-base-content/50">Last success</dt>
          <dd class="font-semibold tabular-nums text-base-content">
            {format_job_timestamp(@card.last_success_at, @datetime_preferences)}
          </dd>
        </div>
        <div class="grid min-w-0 gap-1">
          <dt class="text-base-content/50">Last failure</dt>
          <dd class="font-semibold tabular-nums text-base-content">
            {format_job_timestamp(@card.last_failure_at, @datetime_preferences)}
          </dd>
        </div>
        <div class="grid min-w-0 gap-1">
          <dt class="text-base-content/50">Attempts</dt>
          <dd class="font-semibold tabular-nums text-base-content">{@card.attempts}</dd>
        </div>
      </dl>
    </section>
    """
  end
end
