defmodule CodexPoolerWeb.Admin.UpstreamCockpitComponents.Sections do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.Formatting, as: AccountFormatting
  alias CodexPoolerWeb.Admin.UpstreamCockpitComponents.Formatting
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.ReinviteLink
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.RoutePath
  alias CodexPoolerWeb.DateTimeDisplay

  @doc """
  Routing lanes: a readiness verdict strip plus one row per Pool assignment
  with the assignment → health → quota gate pipeline and the lane's share of
  7-day successes.
  """
  attr :cockpit, :map, required: true
  attr :datetime_preferences, :map, required: true
  attr :request_metrics_loaded?, :boolean, default: true
  attr :request_metrics_loading?, :boolean, default: false
  attr :request_metrics_running?, :boolean, default: false

  @spec readiness_section(map()) :: Phoenix.LiveView.Rendered.t()
  def readiness_section(assigns) do
    ~H"""
    <section
      id="upstream-assignments"
      aria-label={gettext("Routing lanes")}
      aria-busy={to_string(@request_metrics_loading? || @request_metrics_running?)}
      class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100"
    >
      <header class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 bg-base-200/35 px-4 py-3">
        <div class="grid min-w-0 gap-0.5">
          <h2 class="text-base font-semibold leading-5 text-base-content">{gettext("Routing lanes")}</h2>
          <p class="text-xs leading-5 text-base-content/60">
            {gettext("Each Pool assignment must pass assignment → health → quota to receive traffic")}
          </p>
        </div>
        <span class={AdminBadges.count_chip_class()}>
          {ngettext("%{count} lane", "%{count} lanes", @cockpit.assignments.count)}
        </span>
      </header>

      <div
        id="upstream-routing-verdict"
        data-tone={verdict_tone(@cockpit)}
        class={[
          "relative flex items-start gap-3 overflow-hidden border-b border-base-300/60 px-4 py-3",
          verdict_wash_class(verdict_tone(@cockpit))
        ]}
      >
        <.icon
          name={verdict_icon(verdict_tone(@cockpit))}
          class={[
            "pointer-events-none absolute right-3 top-1/2 size-16 -translate-y-1/2",
            verdict_watermark_class(verdict_tone(@cockpit))
          ]}
        />
        <span
          class={[
            "grid size-8 shrink-0 place-items-center rounded-lg",
            verdict_icon_class(verdict_tone(@cockpit))
          ]}
          aria-hidden="true"
        >
          <.icon name={verdict_icon(verdict_tone(@cockpit))} class="size-4.5" />
        </span>
        <div class="grid min-w-0 gap-0.5">
          <p class="text-sm font-semibold leading-5 text-base-content">
            {routing_readiness(@cockpit).label}
          </p>
          <p class="text-xs leading-5 text-base-content/60">
            {routing_readiness(@cockpit).reason}
          </p>
          <p
            :if={@request_metrics_loaded? && request_note(@cockpit.charts.request_health)}
            id="upstream-routing-request-note"
            class="text-xs leading-5 text-base-content/45"
          >
            {request_note(@cockpit.charts.request_health)}
          </p>
        </div>
      </div>

      <div :if={@cockpit.assignments.empty?} class="p-4">
        <AdminComponents.empty_state
          id="upstream-assignments-empty"
          title={gettext("No Pool assignments")}
          description={gettext("Assign this account to a Pool before it can receive traffic.")}
          icon="hero-link-slash"
        />
      </div>
      <div :if={!@cockpit.assignments.empty?} class="divide-y divide-base-300/60">
        <article
          :for={assignment <- @cockpit.assignments.items}
          id={"upstream-assignment-#{assignment.id}"}
          class="grid gap-3 px-4 py-3 lg:grid-cols-[minmax(0,11rem)_minmax(0,1fr)_minmax(0,10rem)] lg:items-center"
        >
          <div class="grid min-w-0 gap-0.5">
            <.link
              id={"upstream-assignment-#{assignment.id}-pool-link"}
              navigate={~p"/admin/pools"}
              class="truncate text-sm font-semibold text-base-content hover:text-primary"
            >
              {assignment.pool_label}
            </.link>
            <p class="flex min-w-0 items-baseline text-[11px] leading-4 text-base-content/50">
              <span
                :if={lane_label(assignment, @cockpit)}
                title={lane_label(assignment, @cockpit)}
                class="min-w-0 truncate"
              >
                {lane_label(assignment, @cockpit)}
              </span>
              <span
                :if={
                  lane_label(assignment, @cockpit) &&
                    reconciled_label(assignment, @datetime_preferences)
                }
                class="shrink-0 px-1"
              >
                ·
              </span>
              <span
                :if={reconciled_label(assignment, @datetime_preferences)}
                class="shrink-0 whitespace-nowrap"
              >
                {reconciled_label(assignment, @datetime_preferences)}
              </span>
            </p>
          </div>
          <div
            id={"upstream-assignment-#{assignment.id}-route"}
            data-role="upstream-assignment-route"
            role="meter"
            aria-valuemin="0"
            aria-valuemax={RoutePath.segment_count()}
            aria-valuenow={RoutePath.ready_count(assignment)}
            aria-label={RoutePath.aria_label(assignment)}
            aria-valuetext={RoutePath.aria_label(assignment)}
            class="route-chevron-flow"
          >
            <span
              :for={segment <- RoutePath.segments(assignment)}
              id={"upstream-assignment-#{assignment.id}-route-#{segment.key}"}
              data-role="upstream-assignment-route-segment"
              title={segment.detail_label}
              class={RoutePath.segment_class(segment)}
            >
              {segment.label}
            </span>
          </div>
          <div class="grid min-w-0 gap-0.5 lg:text-right">
            <span
              data-role="upstream-assignment-share"
              class="text-sm font-semibold tabular-nums text-base-content"
            >
              {lane_share_label(
                @cockpit,
                assignment,
                @request_metrics_loaded?,
                @request_metrics_loading?
              )}
            </span>
            <span class="text-[11px] leading-4 tabular-nums text-base-content/50">
              {lane_share_detail(
                @cockpit,
                assignment,
                @request_metrics_loaded?,
                @request_metrics_loading?
              )}
            </span>
          </div>
        </article>
      </div>
    </section>
    """
  end

  @doc """
  Actions rail: every lifecycle/recovery action, always visible; unavailable
  actions stay disabled with the gating reason as tooltip and hint. Below the
  `sm` breakpoint, where a tooltip cannot be reached on touch, the reason is
  also shown as a line under the action.
  """
  attr :cockpit, :map, required: true
  attr :confirming_saved_reset_redemption, :map, default: nil

  @spec actions_rail(map()) :: Phoenix.LiveView.Rendered.t()
  def actions_rail(assigns) do
    ~H"""
    <section
      id="upstream-actions"
      aria-label={gettext("Account actions")}
      class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100"
    >
      <header class="border-b border-base-300 bg-base-200/35 px-4 py-3">
        <h2 class="text-base font-semibold leading-5 text-base-content">{gettext("Actions")}</h2>
      </header>
      <div class="grid">
        <.rail_action
          id={"cockpit-refresh-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-arrow-path"
          label={gettext("Refresh token")}
          action={@cockpit.actions.refresh_token}
          phx-click="refresh_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.rail_action
          id={"cockpit-oauth-relink-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-link"
          label={gettext("OAuth relink")}
          action={@cockpit.actions.oauth_relink}
          phx-click="open_oauth_relink"
          phx-value-id={@cockpit.identity.id}
        />
        <.rail_action
          id={"cockpit-replace-auth-json-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-document-arrow-up"
          label={gettext("Replace auth.json")}
          action={@cockpit.actions.replace_auth_json}
          phx-click="open_import_auth_json"
          phx-value-id={@cockpit.identity.id}
          phx-value-pool-id={default_pool_id(@cockpit)}
        />
        <.rail_action
          id={"cockpit-pause-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-pause"
          label={gettext("Pause")}
          action={@cockpit.actions.pause}
          phx-click="pause_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.rail_action
          id={"cockpit-reactivate-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-play"
          label={gettext("Reactivate")}
          action={@cockpit.actions.reactivate}
          phx-click="reactivate_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.rail_action
          id={"cockpit-redeem-saved-reset-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-bolt"
          label={gettext("Redeem saved reset")}
          data-saved-reset-action="open-redemption"
          data-server-disabled={to_string(!@cockpit.actions.redeem_saved_reset.available?)}
          action={@cockpit.actions.redeem_saved_reset}
          phx-click="open_saved_reset_redemption_confirmation"
          phx-value-id={@cockpit.identity.id}
          phx-value-pool-id={default_pool_id(@cockpit)}
        />
        <AdminComponents.saved_reset_confirmation
          :if={confirming_saved_reset_redemption?(@confirming_saved_reset_redemption, @cockpit)}
          id="cockpit-saved-reset-redemption-confirmation"
          identity_id={@cockpit.identity.id}
          surface={:cockpit}
          confirm_id="cockpit-saved-reset-redemption-confirm"
          cancel_id="cockpit-saved-reset-redemption-cancel"
          confirm_event={Phoenix.LiveView.JS.push("redeem_saved_reset", value: %{"id" => @cockpit.identity.id, "pool-id" => @confirming_saved_reset_redemption.pool_id})}
          disabled={!@cockpit.actions.redeem_saved_reset.available?}
        />
        <div :if={@cockpit.saved_reset_operation.refreshable? || @cockpit.saved_reset_operation.show_latest_receipt?} class="px-4 py-3">
          <AdminComponents.saved_reset_operation
            identity_id={@cockpit.identity.id}
            surface={:cockpit}
            operation={@cockpit.saved_reset_operation}
            refreshing={Map.get(@cockpit, :saved_reset_status_refreshing?, false)}
          />
        </div>
        <.rail_action
          id={"cockpit-download-reset-calendar-#{@cockpit.identity.id}"}
          icon="hero-calendar-days"
          label={gettext("Download reset calendar")}
          action={@cockpit.actions.download_reset_calendar}
          href={~p"/admin/upstreams/#{@cockpit.identity.id}/saved-reset-expirations.ics"}
        />
        <.rail_action
          id={"cockpit-rename-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-pencil-square"
          label={gettext("Rename")}
          action={@cockpit.actions.rename}
          phx-click="open_rename_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.cockpit_reinvite_link cockpit={@cockpit} />
        <.rail_action
          id={"cockpit-delete-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-trash"
          label={gettext("Delete account…")}
          action={@cockpit.actions.delete}
          variant={:danger}
          phx-click="open_delete_account"
          phx-value-id={@cockpit.identity.id}
        />
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :action, :map, required: true
  attr :href, :string, default: nil
  attr :variant, :atom, default: :neutral, values: [:neutral, :danger]
  attr :rest, :global, include: ~w(phx-click phx-value-id phx-value-pool-id navigate)

  defp rail_action(assigns) do
    if assigns.action.available? && (assigns.href || assigns.rest[:navigate]) do
      ~H"""
      <.link id={@id} href={@href} class={rail_action_class(@variant, @action.available?)} {@rest}>
        <.icon name={@icon} class="size-4 shrink-0" />
        <span class="min-w-0 truncate">{@label}</span>
      </.link>
      """
    else
      assigns =
        assigns
        |> assign(:reason_id, "#{assigns.id}-reason")
        |> assign(:show_reason?, !assigns.action.available? and is_binary(assigns.action.reason))

      ~H"""
      <button
        id={@id}
        type="button"
        class={rail_action_class(@variant, @action.available?)}
        disabled={!@action.available?}
        title={@action.reason}
        aria-describedby={@show_reason? && @reason_id}
        {@rest}
      >
        <.icon name={@icon} class="size-4 shrink-0" />
        <span class="min-w-0 truncate">{@label}</span>
        <span
          :if={!@action.available?}
          class="ml-auto shrink-0 text-[10px] font-normal text-base-content/35"
        >
          {gettext("unavailable")}
        </span>
      </button>
      <%!-- A tooltip cannot be reached on touch, so below `sm` the reason also shows as text under the action. From `sm` it stays in the title only. --%>
      <p
        :if={@show_reason?}
        id={@reason_id}
        data-role="cockpit-action-reason"
        class="-mt-1.5 pr-4 pb-2.5 pl-[42px] text-xs leading-4 text-base-content/60 sm:hidden"
      >
        {@action.reason}
      </p>
      """
    end
  end

  defp rail_action_class(:danger, true) do
    "flex w-full items-center gap-2.5 border-t border-base-300/50 px-4 py-2.5 text-left text-sm font-medium text-error transition-colors first:border-t-0 hover:bg-error/10 focus-visible:outline focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-primary"
  end

  defp rail_action_class(:danger, false) do
    "flex w-full items-center gap-2.5 border-t border-base-300/50 px-4 py-2.5 text-left text-sm font-medium text-error/40 first:border-t-0 disabled:cursor-not-allowed"
  end

  defp rail_action_class(_variant, true) do
    "flex w-full items-center gap-2.5 border-t border-base-300/50 px-4 py-2.5 text-left text-sm font-medium text-base-content/80 transition-colors first:border-t-0 hover:bg-base-200 hover:text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-primary"
  end

  defp rail_action_class(_variant, false) do
    "flex w-full items-center gap-2.5 border-t border-base-300/50 px-4 py-2.5 text-left text-sm font-medium text-base-content/35 first:border-t-0 disabled:cursor-not-allowed"
  end

  attr :cockpit, :map, required: true

  defp cockpit_reinvite_link(assigns) do
    assigns = assign(assigns, :path, ReinviteLink.path_for_cockpit(assigns.cockpit))

    ~H"""
    <.rail_action
      :if={@path}
      id={"cockpit-reinvite-upstream-account-#{@cockpit.identity.id}"}
      icon="hero-user-plus"
      label={gettext("Reinvite account")}
      action={@cockpit.actions.reinvite}
      navigate={@path}
    />
    <.rail_action
      :if={!@path}
      id={"cockpit-reinvite-upstream-account-#{@cockpit.identity.id}"}
      icon="hero-user-plus"
      label={gettext("Reinvite account")}
      action={%{@cockpit.actions.reinvite | available?: false}}
    />
    """
  end

  @doc """
  Recent activity: merged request-failure and audit feed; request evidence
  opens the request-log detail drawer in place.
  """
  attr :cockpit, :map, required: true
  attr :datetime_preferences, :map, required: true
  attr :request_data_loaded?, :boolean, default: true
  attr :request_data_loading?, :boolean, default: false

  @spec recent_events_section(map()) :: Phoenix.LiveView.Rendered.t()
  def recent_events_section(assigns) do
    ~H"""
    <section
      id="upstream-event-summary"
      aria-label={gettext("Recent activity")}
      class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100"
    >
      <header class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 bg-base-200/35 px-4 py-3">
        <div class="grid min-w-0 gap-0.5">
          <h2 class="text-base font-semibold leading-5 text-base-content">{gettext("Recent activity")}</h2>
          <p class="text-xs leading-5 text-base-content/60">
            {gettext("Failed requests and account changes")}
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <span
            :if={@request_data_loading?}
            id="upstream-event-summary-loading"
            class="inline-flex items-center gap-1.5 text-xs text-base-content/55"
            role="status"
          >
            <.icon name="hero-arrow-path" class="admin-loading-icon size-3.5" />
            <span>{gettext("Loading recent activity")}</span>
          </span>
          <.link
            id="upstream-event-summary-request-logs-link"
            href={Formatting.request_logs_path(@cockpit)}
            class="btn btn-ghost btn-xs gap-1.5 text-base-content/65"
          >
            <span class="admin-control-label">{gettext("Request logs")}</span>
            <.icon name="hero-arrow-right" class="size-3" />
          </.link>
          <.link
            id="upstream-event-summary-audit-logs-link"
            href={Formatting.audit_logs_path(@cockpit)}
            class="btn btn-ghost btn-xs gap-1.5 text-base-content/65"
          >
            <span class="admin-control-label">{gettext("Audit logs")}</span>
            <.icon name="hero-arrow-right" class="size-3" />
          </.link>
          <.link
            id="upstream-event-summary-jobs-link"
            href={Formatting.jobs_path(@cockpit)}
            class="btn btn-ghost btn-xs gap-1.5 text-base-content/65"
          >
            <span class="admin-control-label">{gettext("Jobs")}</span>
            <.icon name="hero-arrow-right" class="size-3" />
          </.link>
        </div>
      </header>

      <div :if={@cockpit.recent_events.items != []} id="upstream-event-summary-rows" role="list">
        <article
          :for={event_row <- recent_event_rows(@cockpit.recent_events.items)}
          id={event_row.id}
          data-role="recent-event-row"
          class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 gap-y-1 border-t border-base-300/50 px-4 py-2.5 first:border-t-0 sm:grid-cols-[8.5rem_minmax(0,1fr)_auto_auto]"
          role="listitem"
        >
          <time
            data-role="recent-event-timestamp"
            datetime={DateTime.to_iso8601(event_row.event.timestamp)}
            class="col-span-2 text-[11px] tabular-nums text-base-content/50 sm:col-span-1 sm:text-xs"
          >
            {Formatting.format_event_timestamp(event_row.event.timestamp, @datetime_preferences)}
          </time>
          <div class="grid min-w-0 gap-0.5 sm:flex sm:items-baseline sm:gap-2">
            <h3
              data-role="recent-event-title"
              class="min-w-0 truncate text-sm font-medium text-base-content"
            >
              {event_row.event.title}
            </h3>
            <p
              data-role="recent-event-subtitle"
              class="min-w-0 truncate text-xs leading-5 text-base-content/55"
            >
              {event_row.event.subtitle}
            </p>
          </div>
          <span
            data-role="recent-event-source"
            class={[
              AdminBadges.metadata_chip_class(event_source_tone(event_row.event.source)),
              "!px-2 !py-0.5 !text-[10px] uppercase"
            ]}
          >
            {event_source_label(event_row.event.source)}
          </span>
          <button
            :if={event_row.event.request_id}
            data-role="recent-event-link"
            type="button"
            phx-click="open_request_log"
            phx-value-request-id={event_row.event.request_id}
            title={gettext("Open request evidence")}
            aria-label={gettext("Open request evidence")}
            class="btn btn-ghost btn-xs btn-square justify-self-end text-base-content/45 hover:text-primary"
          >
            <.icon name="hero-magnifying-glass" class="size-3.5" />
          </button>
          <.link
            :if={!event_row.event.request_id && event_row.event.link}
            data-role="recent-event-link"
            href={event_row.event.link}
            title={gettext("Open in audit logs")}
            aria-label={gettext("Open in audit logs")}
            class="btn btn-ghost btn-xs btn-square justify-self-end text-base-content/45 hover:text-primary"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
          </.link>
          <span
            :if={!event_row.event.request_id && !event_row.event.link}
            class="w-6 justify-self-end"
            aria-hidden="true"
          ></span>
        </article>
      </div>

      <div
        :if={!@request_data_loaded? && @request_data_loading? && @cockpit.recent_events.items == []}
        class="p-4"
      >
        <AdminComponents.empty_state
          id="upstream-event-summary-loading-state"
          title={gettext("Loading recent activity")}
          description={gettext("Request and account events will appear here when the current snapshot is ready.")}
          icon="hero-arrow-path"
          loading?={true}
        />
      </div>

      <div
        :if={!@request_data_loaded? && !@request_data_loading? && @cockpit.recent_events.items == []}
        class="p-4"
      >
        <AdminComponents.empty_state
          id="upstream-event-summary-error-state"
          title={gettext("Recent activity is not available")}
          description={gettext("Refresh the account data to try again.")}
          icon="hero-clipboard-document-list"
        />
      </div>

      <div :if={@request_data_loaded? && @cockpit.recent_events.items == []} class="p-4">
        <AdminComponents.empty_state
          id="upstream-event-summary-empty"
          title={gettext("No recent upstream events")}
          description={recent_events_empty_description(@cockpit.recent_events.searched_attempt_limit)}
          icon="hero-clipboard-document-list"
        />
      </div>

      <p
        :if={@request_data_loaded? && @cockpit.recent_events.items != [] && @cockpit.recent_events.searched_attempt_limit}
        id="upstream-event-summary-request-window"
        class="border-t border-base-300/50 px-4 py-2 text-xs leading-5 text-base-content/55"
      >
        {searched_attempts_label(@cockpit.recent_events.searched_attempt_limit)}
      </p>
    </section>
    """
  end

  # The request walk reads a bounded window of each assignment's newest
  # attempts; when older attempts were left unread the page says what was
  # searched instead of implying the whole history is clean.
  defp recent_events_empty_description(nil),
    do: gettext("Request failures and audit activity for this account will appear here.")

  defp recent_events_empty_description(limit),
    do: ngettext("No failed or retried requests in the latest %{attempts} attempt of each Pool assignment and no account changes; older request history is in Request logs.", "No failed or retried requests in the latest %{attempts} attempts of each Pool assignment and no account changes; older request history is in Request logs.", limit, attempts: AccountFormatting.format_integer(limit))

  defp searched_attempts_label(limit),
    do: ngettext("Failed and retried requests are searched in the latest %{attempts} attempt of each Pool assignment; older request history is in Request logs.", "Failed and retried requests are searched in the latest %{attempts} attempts of each Pool assignment; older request history is in Request logs.", limit, attempts: AccountFormatting.format_integer(limit))

  defp routing_readiness(%{header: %{routing_readiness: readiness}}) when is_map(readiness),
    do: readiness

  defp routing_readiness(_cockpit) do
    %{
      state: "unavailable",
      label: gettext("Routing unavailable"),
      tone: :warning,
      reason: gettext("Routing readiness is unavailable for this upstream account.")
    }
  end

  defp verdict_tone(cockpit) do
    case routing_readiness(cockpit) do
      %{tone: tone} when tone in [:success, :warning, :error] -> tone
      _readiness -> :warning
    end
  end

  defp verdict_wash_class(:success), do: "bg-success/5"
  defp verdict_wash_class(:error), do: "bg-error/5"
  defp verdict_wash_class(_tone), do: "bg-warning/5"

  defp verdict_icon_class(:success), do: "bg-success/15 text-success"
  defp verdict_icon_class(:error), do: "bg-error/15 text-error"
  defp verdict_icon_class(_tone), do: "bg-warning/15 text-warning"

  defp verdict_icon(:success), do: "hero-check-circle"
  defp verdict_icon(:error), do: "hero-x-circle"
  defp verdict_icon(_tone), do: "hero-exclamation-triangle"

  defp verdict_watermark_class(:success), do: "text-success/10"
  defp verdict_watermark_class(:error), do: "text-error/10"
  defp verdict_watermark_class(_tone), do: "text-warning/10"

  defp request_note(%{kpis: %{total_requests_24h: 0}}), do: nil

  # Client cancellations are neither failures nor part of the rate's base, so
  # the note counts the requests that ran to an outcome of their own and names
  # the cancellations it left out.
  defp request_note(%{state: state, kpis: %{total_requests_24h: total, client_cancelled_requests_24h: total}})
       when state in ["healthy", "degraded", "failed"],
       do: ngettext("All %{count} request in the last 24h was cancelled by the client", "All %{count} requests in the last 24h were cancelled by the client", total)

  defp request_note(%{state: state, kpis: kpis})
       when state in ["healthy", "degraded", "failed"] do
    cancelled = kpis.client_cancelled_requests_24h
    count = kpis.total_requests_24h - cancelled
    bindings = [failed: kpis.failed_requests_24h, rate: format_rate(kpis.failure_rate_24h), cancelled: cancelled]

    cond do
      state == "healthy" and cancelled > 0 ->
        ngettext("%{failed} of %{count} request failed in the last 24h (%{rate}), within the expected range for upstream calls; %{cancelled} cancelled by the client not counted", "%{failed} of %{count} requests failed in the last 24h (%{rate}), within the expected range for upstream calls; %{cancelled} cancelled by the client not counted", count, bindings)

      state == "healthy" ->
        ngettext("%{failed} of %{count} request failed in the last 24h (%{rate}), within the expected range for upstream calls", "%{failed} of %{count} requests failed in the last 24h (%{rate}), within the expected range for upstream calls", count, bindings)

      cancelled > 0 ->
        ngettext("%{failed} of %{count} request failed in the last 24h (%{rate}); %{cancelled} cancelled by the client not counted", "%{failed} of %{count} requests failed in the last 24h (%{rate}); %{cancelled} cancelled by the client not counted", count, bindings)

      true ->
        ngettext("%{failed} of %{count} request failed in the last 24h (%{rate})", "%{failed} of %{count} requests failed in the last 24h (%{rate})", count, bindings)
    end
  end

  defp request_note(_request_health), do: nil

  defp format_rate(rate) when is_float(rate),
    do: :erlang.float_to_binary(rate, decimals: 1) <> "%"

  defp format_rate(rate), do: "#{rate}%"

  # Every lane on this page belongs to the account in the header, so the
  # label only earns its place when an operator gave the lane its own name.
  defp lane_label(assignment, cockpit) do
    case assignment_label(assignment) do
      nil -> nil
      label -> if label == cockpit.header.title, do: nil, else: label
    end
  end

  defp assignment_label(%{assignment_label: label}) when is_binary(label) and label != "",
    do: label

  defp assignment_label(_assignment), do: nil

  # last_successful_refresh_at is stamped by account reconciliation, so name
  # the event rather than a vague "refreshed".
  defp reconciled_label(
         %{last_successful_refresh_at: %DateTime{} = reconciled_at},
         datetime_preferences
       ),
       do: gettext("reconciled %{time}", time: DateTimeDisplay.format_datetime(reconciled_at, datetime_preferences))

  defp reconciled_label(_assignment, _datetime_preferences), do: nil

  defp lane_share_label(_cockpit, _assignment, false, true), do: "…"
  defp lane_share_label(_cockpit, _assignment, false, false), do: "–"

  defp lane_share_label(cockpit, assignment, true, _loading?) do
    case contribution_item(cockpit, assignment) do
      %{bar_value: share} when is_number(share) -> "#{format_rate(share * 1.0)}"
      _item -> "–"
    end
  end

  defp lane_share_detail(_cockpit, _assignment, false, true), do: gettext("Loading request metrics")
  defp lane_share_detail(_cockpit, _assignment, false, false), do: gettext("Request metrics unavailable")

  defp lane_share_detail(cockpit, assignment, true, _loading?) do
    case contribution_item(cockpit, assignment) do
      %{successful_request_count_7d: count} ->
        ngettext("%{count} success · 7d", "%{count} successes · 7d", count || 0)

      _item ->
        gettext("no settled successes yet")
    end
  end

  defp contribution_item(cockpit, assignment) do
    Enum.find(cockpit.charts.pool_contribution.items, &(&1.assignment_id == assignment.id))
  end

  defp recent_event_rows(items) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {event, index} ->
      %{id: "upstream-event-summary-row-#{index}", event: event}
    end)
  end

  defp event_source_label("request_log"), do: gettext("request")
  defp event_source_label("audit_log"), do: gettext("audit")
  defp event_source_label("oauth_flow"), do: "oauth"
  defp event_source_label(source), do: source |> Formatting.status_text() |> String.downcase()

  defp event_source_tone("request_log"), do: :info
  defp event_source_tone("audit_log"), do: :primary
  defp event_source_tone("oauth_flow"), do: :warning
  defp event_source_tone(_source), do: :neutral

  defp confirming_saved_reset_redemption?(nil, _cockpit), do: false

  defp confirming_saved_reset_redemption?(%{identity_id: identity_id}, cockpit),
    do: identity_id == cockpit.identity.id

  defp confirming_saved_reset_redemption?(_confirmation, _cockpit), do: false

  defp default_pool_id(%{assignments: %{items: [%{pool_id: pool_id} | _items]}}), do: pool_id
  defp default_pool_id(_cockpit), do: nil
end
