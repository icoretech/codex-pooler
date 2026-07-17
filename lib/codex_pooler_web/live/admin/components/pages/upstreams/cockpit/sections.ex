defmodule CodexPoolerWeb.Admin.UpstreamCockpitComponents.Sections do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
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

  def readiness_section(assigns) do
    ~H"""
    <section
      id="upstream-assignments"
      aria-label="Routing lanes"
      class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100"
    >
      <header class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 bg-base-200/35 px-4 py-3">
        <div class="grid min-w-0 gap-0.5">
          <h2 class="text-base font-semibold leading-5 text-base-content">Routing lanes</h2>
          <p class="text-xs leading-5 text-base-content/60">
            Each Pool assignment must pass assignment → health → quota to receive traffic
          </p>
        </div>
        <span class={AdminBadges.count_chip_class()}>
          {Formatting.pluralize_count(@cockpit.assignments.count, "lane", "lanes")}
        </span>
      </header>

      <div
        id="upstream-routing-verdict"
        data-tone={verdict_tone(@cockpit)}
        class={[
          "flex items-start gap-3 border-b border-base-300/60 px-4 py-3",
          verdict_wash_class(verdict_tone(@cockpit))
        ]}
      >
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
            :if={request_note(@cockpit.charts.request_health)}
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
          title="No Pool assignments"
          description="Assign this account to a Pool before it can receive traffic."
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
            <p class="truncate text-[11px] leading-4 text-base-content/50">
              {assignment_meta(assignment, @datetime_preferences)}
            </p>
          </div>
          <div
            id={"upstream-assignment-#{assignment.id}-route"}
            data-role="upstream-assignment-route"
            role="meter"
            aria-valuemin="0"
            aria-valuemax="3"
            aria-valuenow={RoutePath.ready_count(assignment)}
            aria-label={RoutePath.aria_label(assignment)}
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
              {lane_share_label(@cockpit, assignment)}
            </span>
            <span class="text-[11px] leading-4 tabular-nums text-base-content/50">
              {lane_share_detail(@cockpit, assignment)}
            </span>
          </div>
        </article>
      </div>
    </section>
    """
  end

  @doc """
  Actions rail: every lifecycle/recovery action, always visible; unavailable
  actions stay disabled with the gating reason as tooltip and hint.
  """
  attr :cockpit, :map, required: true
  attr :confirming_saved_reset_redemption, :map, default: nil

  def actions_rail(assigns) do
    ~H"""
    <section
      id="upstream-actions"
      aria-label="Account actions"
      class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100"
    >
      <header class="border-b border-base-300 bg-base-200/35 px-4 py-3">
        <h2 class="text-base font-semibold leading-5 text-base-content">Actions</h2>
      </header>
      <div class="grid">
        <.rail_action
          id={"cockpit-refresh-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-arrow-path"
          label="Refresh token"
          action={@cockpit.actions.refresh_token}
          phx-click="refresh_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.rail_action
          id={"cockpit-oauth-relink-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-link"
          label="OAuth relink"
          action={@cockpit.actions.oauth_relink}
          phx-click="open_oauth_relink"
          phx-value-id={@cockpit.identity.id}
        />
        <.rail_action
          id={"cockpit-replace-auth-json-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-document-arrow-up"
          label="Replace auth.json"
          action={@cockpit.actions.replace_auth_json}
          phx-click="open_import_auth_json"
          phx-value-id={@cockpit.identity.id}
          phx-value-pool-id={default_pool_id(@cockpit)}
        />
        <.rail_action
          id={"cockpit-pause-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-pause"
          label="Pause"
          action={@cockpit.actions.pause}
          phx-click="pause_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.rail_action
          id={"cockpit-reactivate-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-play"
          label="Reactivate"
          action={@cockpit.actions.reactivate}
          phx-click="reactivate_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.rail_action
          id={"cockpit-redeem-saved-reset-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-bolt"
          label="Redeem saved reset"
          action={@cockpit.actions.redeem_saved_reset}
          phx-click="open_saved_reset_redemption_confirmation"
          phx-value-id={@cockpit.identity.id}
          phx-value-pool-id={default_pool_id(@cockpit)}
        />
        <div
          :if={confirming_saved_reset_redemption?(@confirming_saved_reset_redemption, @cockpit)}
          id="cockpit-saved-reset-redemption-confirmation"
          class="mx-3 mb-2 grid gap-3 rounded-box border border-warning/30 bg-warning/10 p-3"
        >
          <div class="grid gap-1">
            <h3 class="text-sm font-semibold text-base-content">Confirm saved reset redemption</h3>
            <p class="text-xs leading-5 text-base-content/75">
              This queues one manual redemption for this account. It is separate from the auto
              redeem policy.
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <AdminComponents.action_button
              id="cockpit-saved-reset-redemption-confirm"
              icon="hero-check"
              label="Confirm redemption"
              phx-click="redeem_saved_reset"
              phx-value-id={@cockpit.identity.id}
              phx-value-pool-id={default_pool_id(@cockpit)}
              variant={:primary}
            />
            <AdminComponents.action_button
              id="cockpit-saved-reset-redemption-cancel"
              icon="hero-x-mark"
              label="Keep resets in bank"
              phx-click="cancel_saved_reset_redemption"
            />
          </div>
        </div>
        <.rail_action
          id={"cockpit-rename-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-pencil-square"
          label="Rename"
          action={@cockpit.actions.rename}
          phx-click="open_rename_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.cockpit_reinvite_link cockpit={@cockpit} />
        <.rail_action
          id={"cockpit-delete-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-trash"
          label="Delete account…"
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
  attr :variant, :atom, default: :neutral, values: [:neutral, :danger]
  attr :rest, :global, include: ~w(phx-click phx-value-id phx-value-pool-id navigate)

  defp rail_action(assigns) do
    if assigns.rest[:navigate] do
      ~H"""
      <.link id={@id} class={rail_action_class(@variant, @action.available?)} {@rest}>
        <.icon name={@icon} class="size-4 shrink-0" />
        <span class="min-w-0 truncate">{@label}</span>
      </.link>
      """
    else
      ~H"""
      <button
        id={@id}
        type="button"
        class={rail_action_class(@variant, @action.available?)}
        disabled={!@action.available?}
        title={@action.reason}
        {@rest}
      >
        <.icon name={@icon} class="size-4 shrink-0" />
        <span class="min-w-0 truncate">{@label}</span>
        <span
          :if={!@action.available?}
          class="ml-auto shrink-0 text-[10px] font-normal text-base-content/35"
        >
          unavailable
        </span>
      </button>
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
      label="Reinvite account"
      action={@cockpit.actions.reinvite}
      navigate={@path}
    />
    <.rail_action
      :if={!@path}
      id={"cockpit-reinvite-upstream-account-#{@cockpit.identity.id}"}
      icon="hero-user-plus"
      label="Reinvite account"
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

  def recent_events_section(assigns) do
    ~H"""
    <section
      id="upstream-event-summary"
      aria-label="Recent activity"
      class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100"
    >
      <header class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 bg-base-200/35 px-4 py-3">
        <div class="grid min-w-0 gap-0.5">
          <h2 class="text-base font-semibold leading-5 text-base-content">Recent activity</h2>
          <p class="text-xs leading-5 text-base-content/60">
            Failed requests and account changes
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.link
            id="upstream-event-summary-request-logs-link"
            href={Formatting.request_logs_path(@cockpit)}
            class="btn btn-ghost btn-xs gap-1.5 text-base-content/65"
          >
            <span>Request logs</span>
            <.icon name="hero-arrow-right" class="size-3" />
          </.link>
          <.link
            id="upstream-event-summary-audit-logs-link"
            href={Formatting.audit_logs_path(@cockpit)}
            class="btn btn-ghost btn-xs gap-1.5 text-base-content/65"
          >
            <span>Audit logs</span>
            <.icon name="hero-arrow-right" class="size-3" />
          </.link>
          <.link
            id="upstream-event-summary-jobs-link"
            href={Formatting.jobs_path(@cockpit)}
            class="btn btn-ghost btn-xs gap-1.5 text-base-content/65"
          >
            <span>Jobs</span>
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
            title="Open request evidence"
            aria-label="Open request evidence"
            class="btn btn-ghost btn-xs btn-square justify-self-end text-base-content/45 hover:text-primary"
          >
            <.icon name="hero-magnifying-glass" class="size-3.5" />
          </button>
          <.link
            :if={!event_row.event.request_id && event_row.event.link}
            data-role="recent-event-link"
            href={event_row.event.link}
            title="Open in audit logs"
            aria-label="Open in audit logs"
            class="btn btn-ghost btn-xs btn-square justify-self-end text-base-content/45 hover:text-primary"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
          </.link>
          <span
            :if={!event_row.event.request_id && !event_row.event.link}
            class="size-6 justify-self-end"
            aria-hidden="true"
          ></span>
        </article>
      </div>

      <div :if={@cockpit.recent_events.items == []} class="p-4">
        <AdminComponents.empty_state
          id="upstream-event-summary-empty"
          title="No recent upstream events"
          description="Request failures and audit activity for this account will appear here."
          icon="hero-clipboard-document-list"
        />
      </div>
    </section>
    """
  end

  defp routing_readiness(%{header: %{routing_readiness: readiness}}) when is_map(readiness),
    do: readiness

  defp routing_readiness(_cockpit) do
    %{
      state: "unavailable",
      label: "Routing unavailable",
      tone: :warning,
      reason: "Routing readiness is unavailable for this upstream account."
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

  defp request_note(%{kpis: %{total_requests_24h: 0}}), do: nil

  defp request_note(%{state: state, kpis: kpis})
       when state in ["healthy", "degraded", "failed"] do
    base =
      "#{kpis.failed_requests_24h} of #{kpis.total_requests_24h} requests failed in the last 24h (#{format_rate(kpis.failure_rate_24h)})"

    case state do
      "healthy" -> base <> ", within the expected range for upstream calls"
      _degraded -> base
    end
  end

  defp request_note(_request_health), do: nil

  defp format_rate(rate) when is_float(rate),
    do: :erlang.float_to_binary(rate, decimals: 1) <> "%"

  defp format_rate(rate), do: "#{rate}%"

  defp assignment_meta(assignment, datetime_preferences) do
    [
      assignment.assignment_label,
      refreshed_label(assignment.last_successful_refresh_at, datetime_preferences)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp refreshed_label(%DateTime{} = refreshed_at, datetime_preferences),
    do: "refreshed #{DateTimeDisplay.format_datetime(refreshed_at, datetime_preferences)}"

  defp refreshed_label(_refreshed_at, _datetime_preferences), do: nil

  defp lane_share_label(cockpit, assignment) do
    case contribution_item(cockpit, assignment) do
      %{bar_value: share} when is_number(share) -> "#{format_rate(share * 1.0)}"
      _item -> "–"
    end
  end

  defp lane_share_detail(cockpit, assignment) do
    case contribution_item(cockpit, assignment) do
      %{successful_request_count_7d: count} ->
        "#{Formatting.pluralize_count(count, "success", "successes")} · 7d"

      _item ->
        "no settled successes yet"
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

  defp event_source_label("request_log"), do: "request"
  defp event_source_label("audit_log"), do: "audit"
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
