defmodule CodexPoolerWeb.Admin.JobsPageComponents.WorkerCards do
  @moduledoc false

  use CodexPoolerWeb, :html

  import CodexPoolerWeb.Admin.JobsPresentation

  alias CodexPoolerWeb.Admin.AvatarComponents
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.JobFilterForm

  attr :card, :map, required: true
  attr :current_params, :map, required: true
  attr :datetime_preferences, :map, required: true
  attr :selected_failure_job_id, :integer, default: nil

  def job_worker_card(assigns) do
    ~H"""
    <article
      id={"job-worker-card-#{@card.id}"}
      class="grid min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100"
    >
      <.job_worker_card_header card={@card} />

      <.worker_activity_strip
        card={@card}
        current_params={@current_params}
        selected_failure_job_id={@selected_failure_job_id}
      />
      <.worker_failure_panel
        :for={{marker, marker_index} <- Enum.with_index(@card.visible_failure_markers)}
        marker={marker}
        latest?={marker_index == 0}
        open?={marker.id == @selected_failure_job_id}
        datetime_preferences={@datetime_preferences}
      />
      <.worker_schedule_facts card={@card} datetime_preferences={@datetime_preferences} />
    </article>
    """
  end

  defp job_worker_card_header(assigns) do
    ~H"""
    <header
      data-role="worker-card-header"
      class="flex flex-row items-center justify-between gap-3 border-b border-base-300 bg-base-200/35 px-4 py-3"
    >
      <div class="min-w-0 flex-1">
        <div data-role="worker-card-title-row" class="flex min-w-0 items-center gap-2.5">
          <.icon name={@card.icon} class="size-5 shrink-0 text-base-content/45" />
          <h2 class="min-w-0 truncate text-base font-semibold leading-5 text-base-content">
            {@card.title}
          </h2>
        </div>
      </div>

      <div
        data-role="worker-card-header-actions"
        class="flex shrink-0 items-center gap-2 self-center"
      >
        <span
          :if={worker_state_badge_visible?(@card.state)}
          data-role="worker-state-badge"
          title={@card.state_label}
          aria-label={"State: #{@card.state_label}"}
          class={[
            worker_state_badge_class(@card.state),
            "shrink-0 gap-1.5 whitespace-nowrap"
          ]}
        >
          <.icon name={job_state_icon(@card.state)} class="size-4" />
          <span>{@card.state_label}</span>
        </span>
        <.worker_card_actions :if={@card.manual_enqueue} card={@card} />
        <span
          :if={!@card.manual_enqueue}
          data-role="worker-card-action-spacer"
          aria-hidden="true"
          class="btn btn-ghost btn-sm btn-square pointer-events-none invisible"
        />
      </div>
    </header>
    """
  end

  attr :card, :map, required: true

  defp worker_card_actions(assigns) do
    ~H"""
    <div
      class="dropdown dropdown-end inline-block shrink-0 self-center"
      data-role="job-worker-card-actions"
    >
      <button
        id={"job-worker-actions-menu-#{@card.id}"}
        type="button"
        class="btn btn-ghost btn-sm btn-square"
        tabindex="0"
        aria-label={"Actions for #{@card.title}"}
      >
        <.icon name="hero-ellipsis-vertical" class="size-5" />
      </button>
      <ul
        tabindex="0"
        class="menu dropdown-content z-20 mt-2 w-60 rounded-box border border-base-300 bg-base-100 p-2 text-left shadow-xl"
      >
        <li>
          <AdminComponents.dropdown_action_item
            id={"enqueue-job-worker-#{@card.id}"}
            icon="hero-play"
            label="Enqueue Now"
            phx-click="enqueue_worker_group"
            phx-value-id={Atom.to_string(@card.key)}
          />
        </li>
      </ul>
    </div>
    """
  end

  defp worker_activity_strip(assigns) do
    ~H"""
    <section
      :if={@card.open_markers != [] or @card.failure_markers != []}
      data-role="worker-activity-strip"
      class="border-t border-base-300 bg-base-200/35 px-5 py-3"
    >
      <div class="flex min-w-0 flex-wrap items-center justify-between gap-3">
        <span class="text-xs font-medium text-base-content/60">{@card.activity_label}</span>

        <div class="flex min-w-0 flex-wrap items-center gap-1.5">
          <span
            :for={marker <- @card.visible_open_markers}
            id={"job-activity-#{marker.id}"}
            data-role="open-worker-marker"
            aria-label={marker.title}
            title={marker.title}
            data-has-avatar={marker.avatar_email && "true"}
            class={[
              "avatar relative size-8 shrink-0 rounded-full text-[0.6875rem] font-semibold leading-none shadow-sm",
              !marker.avatar_email && "avatar-placeholder"
            ]}
          >
            <div class="size-8 rounded-full ring-1 ring-base-300">
              <img
                :if={marker.avatar_email}
                src={AvatarComponents.gravatar_url(marker.avatar_email, size: 64)}
                alt=""
                loading="lazy"
                referrerpolicy="no-referrer"
                aria-hidden="true"
              />
              <span
                :if={!marker.avatar_email}
                data-role="target-initial"
                class="grid size-full place-items-center rounded-full bg-info/10 text-info"
              >
                {marker.glyph}
              </span>
            </div>
          </span>
          <span
            :if={@card.open_marker_overflow_count > 0}
            data-role="open-worker-overflow"
            title={"#{@card.open_marker_overflow_count} more open targets"}
            class="grid size-8 shrink-0 place-items-center rounded-full border border-info/30 bg-info/5 text-[0.6875rem] font-semibold text-info"
          >
            +{@card.open_marker_overflow_count}
          </span>

          <a
            :for={marker <- @card.visible_failure_markers}
            href={failure_marker_path(@current_params, @selected_failure_job_id, marker.id)}
            id={"job-failure-#{marker.id}"}
            data-role="failed-worker-marker"
            aria-controls={"job-failure-panel-#{marker.id}"}
            aria-expanded={to_string(marker.id == @selected_failure_job_id)}
            aria-label={marker.title}
            title={marker.title}
            data-job-id={marker.id}
            data-has-avatar={marker.avatar_email && "true"}
            data-selected={marker.id == @selected_failure_job_id && "true"}
            phx-click="toggle_worker_failure"
            phx-hook="WorkerFailureMarker"
            phx-value-job-id={marker.id}
            class={[
              "avatar avatar-offline relative size-8 shrink-0 rounded-full text-[0.6875rem] font-semibold leading-none shadow-sm transition-opacity hover:opacity-80 focus:outline-none focus:ring-2 focus:ring-error/40",
              marker.id == @selected_failure_job_id &&
                "ring-2 ring-error/50 ring-offset-2 ring-offset-base-100",
              !marker.avatar_email && "avatar-placeholder"
            ]}
          >
            <div class="size-8 rounded-full ring-1 ring-error/40">
              <img
                :if={marker.avatar_email}
                src={AvatarComponents.gravatar_url(marker.avatar_email, size: 64)}
                alt=""
                loading="lazy"
                referrerpolicy="no-referrer"
                aria-hidden="true"
              />
              <span
                :if={!marker.avatar_email}
                data-role="target-initial"
                class="grid size-full place-items-center rounded-full bg-error/10 text-error"
              >
                {marker.glyph}
              </span>
            </div>
          </a>
          <span
            :if={@card.failure_marker_overflow_count > 0}
            data-role="failed-worker-overflow"
            title={"#{@card.failure_marker_overflow_count} more failed targets"}
            class="grid size-8 shrink-0 place-items-center rounded-full border border-error/40 bg-error/5 text-[0.6875rem] font-semibold text-error"
          >
            +{@card.failure_marker_overflow_count}
          </span>
        </div>
      </div>
    </section>
    """
  end

  defp failure_marker_path(params, selected_failure_job_id, selected_failure_job_id) do
    ~p"/admin/jobs?#{JobFilterForm.query_params(params)}"
  end

  defp failure_marker_path(params, _selected_failure_job_id, marker_id) do
    params =
      params
      |> JobFilterForm.query_params()
      |> Map.put("failure_job_id", Integer.to_string(marker_id))

    ~p"/admin/jobs?#{params}"
  end

  attr :marker, :map, required: true
  attr :latest?, :boolean, required: true
  attr :open?, :boolean, required: true
  attr :datetime_preferences, :map, required: true

  defp worker_failure_panel(assigns) do
    ~H"""
    <section
      id={"job-failure-panel-#{@marker.id}"}
      data-role="worker-failure-panel"
      data-open={to_string(@open?)}
      aria-hidden={to_string(!@open?)}
      class={[
        "grid border-t border-error/20 bg-error/5 text-sm transition-[grid-template-rows,opacity] duration-200 ease-out motion-reduce:transition-none",
        @open? && "grid-rows-[1fr] opacity-100",
        !@open? && "grid-rows-[0fr] opacity-0"
      ]}
    >
      <div class="min-h-0 overflow-hidden">
        <div class="grid gap-3 px-4 py-3">
          <div class="flex min-w-0 items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="text-xs font-semibold uppercase text-error">
                {if @latest?, do: "Latest failure", else: "Failure detail"}
              </p>
              <p class="mt-1 truncate font-semibold text-base-content">
                {@marker.target_label}
              </p>
            </div>
            <button
              id={"job-failure-panel-close-#{@marker.id}"}
              type="button"
              data-role="failure-panel-close"
              aria-label="Close failure panel"
              phx-click="close_worker_failure"
              class="grid size-7 shrink-0 place-items-center rounded-full text-base-content/45 transition-colors hover:bg-error/10 hover:text-error focus:outline-none focus:ring-2 focus:ring-error/40"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <div
            data-role="failure-panel-summary"
            class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-start"
          >
            <div class="min-w-0">
              <p class="font-semibold text-error">
                {@marker.failure.title}
              </p>
              <p class="mt-0.5 truncate text-xs text-base-content/60">
                {@marker.worker_label}
              </p>
            </div>
            <dl
              data-role="failure-panel-meta"
              class="grid grid-cols-2 gap-3 text-xs text-base-content/60 sm:min-w-44"
            >
              <div>
                <dt>When</dt>
                <dd class="font-semibold tabular-nums text-base-content">
                  {format_job_timestamp(@marker.failed_at, @datetime_preferences)}
                </dd>
              </div>
              <div>
                <dt>Attempts</dt>
                <dd class="font-semibold tabular-nums text-base-content">
                  {@marker.attempts}
                </dd>
              </div>
            </dl>
          </div>
          <p data-role="failure-message" class="leading-6 text-base-content/70">
            {@marker.failure.message}
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr :card, :map, required: true
  attr :datetime_preferences, :map, required: true

  defp worker_schedule_facts(assigns) do
    ~H"""
    <AdminComponents.card_fact_strip
      facts_role="worker-schedule-grid"
      data-role="worker-schedule-facts"
      data-density="compact"
    >
      <:fact role="next-run-group">
        <AdminComponents.card_fact_label>Next run</AdminComponents.card_fact_label>
        <AdminComponents.card_fact_value>
          <span
            data-role="next-run"
            class="inline-flex max-w-full items-center gap-1 tabular-nums"
            title={@card.next_run_title}
          >
            <.icon name="hero-clock" class="size-3 shrink-0" />
            <span class="truncate">{@card.next_run}</span>
          </span>
        </AdminComponents.card_fact_value>
      </:fact>
      <:fact role="last-run">
        <AdminComponents.card_fact_label>Last run</AdminComponents.card_fact_label>
        <AdminComponents.card_fact_value class="tabular-nums">
          {format_job_timestamp(@card.last_seen_at, @datetime_preferences)}
        </AdminComponents.card_fact_value>
      </:fact>
      <:fact role="schedule">
        <AdminComponents.card_fact_label>Schedule</AdminComponents.card_fact_label>
        <AdminComponents.card_fact_value
          :if={@card.on_demand}
          data-role="cadence-label"
          title={@card.cadence_label}
        >
          On demand
        </AdminComponents.card_fact_value>
        <AdminComponents.card_fact_value
          :if={!@card.on_demand}
          data-role="cadence-label"
          title={@card.cadence_label}
        >
          {@card.cadence_label}
        </AdminComponents.card_fact_value>
      </:fact>
    </AdminComponents.card_fact_strip>
    """
  end

  defp worker_state_badge_class(state) do
    state
    |> worker_state_tone()
    |> AdminBadges.metadata_chip_class()
  end

  defp worker_state_badge_visible?("executing"), do: true
  defp worker_state_badge_visible?(_state), do: false

  defp worker_state_tone(state) do
    case to_string(state || "") do
      state when state in ["completed", "succeeded"] -> :success
      state when state in ["executing", "available", "scheduled"] -> :info
      state when state in ["retryable", "cancelled", "awaiting_first_run"] -> :warning
      state when state in ["discarded", "failed"] -> :error
      _state -> :neutral
    end
  end
end
