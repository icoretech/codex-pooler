defmodule CodexPoolerWeb.Admin.UpstreamCockpitComponents.Sections do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.UpstreamCockpitComponents.Formatting
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.SavedResetComponents
  alias Phoenix.HTML.Form

  def assignments_section(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="upstream-assignments"
      title="Pool assignments"
      description="Pools currently linked to this upstream account."
      count={Formatting.pluralize_count(@cockpit.assignments.count, "assignment", "assignments")}
    >
      <div :if={@cockpit.assignments.empty?} class="p-4">
        <AdminComponents.empty_state
          id="upstream-assignments-empty"
          title="No Pool assignments"
          description="This upstream account is visible but is not assigned to a Pool yet."
          icon="hero-link-slash"
        />
      </div>
      <div :if={!@cockpit.assignments.empty?} class="divide-y divide-base-300/70">
        <article
          :for={assignment <- @cockpit.assignments.items}
          id={"upstream-assignment-#{assignment.id}"}
          class="grid gap-3 p-4 md:grid-cols-[minmax(0,1.5fr)_minmax(0,1fr)_auto] md:items-center"
        >
          <div class="grid min-w-0 gap-1">
            <h3 class="break-words text-sm font-semibold text-base-content">
              {assignment.assignment_label}
            </h3>
            <.link
              id={"upstream-assignment-#{assignment.id}-pool-link"}
              navigate={~p"/admin/pools"}
              class="break-words text-sm font-medium text-primary hover:underline"
            >
              {assignment.pool_label}
            </.link>
          </div>
          <div class="flex flex-wrap gap-2">
            <span class={Formatting.assignment_status_class(assignment.status)}>
              {Formatting.status_label("Assignment", assignment.status)}
            </span>
            <span class={Formatting.assignment_status_class(assignment.health_status)}>
              {Formatting.status_label("Health", assignment.health_status)}
            </span>
            <span class={Formatting.assignment_status_class(assignment.eligibility_status)}>
              {Formatting.status_label("Routing", assignment.eligibility_status)}
            </span>
            <span class={Formatting.assignment_status_class(assignment.quota_priming_status)}>
              {assignment.quota_priming_label}
            </span>
            <span
              :if={quota_item = quota_item_for(@cockpit, assignment)}
              class={Formatting.assignment_status_class(quota_item.state)}
            >
              {quota_assignment_label(quota_item)}
            </span>
            <span
              :if={contribution_item = pool_contribution_item_for(@cockpit, assignment)}
              class={Formatting.assignment_status_class(contribution_item.assignment_state)}
            >
              {contribution_item.assignment_state_label}
            </span>
          </div>
          <span class="text-xs font-semibold uppercase tracking-wide text-base-content/55">
            {assignment.quota_priming_label}
          </span>
        </article>
      </div>
    </AdminComponents.admin_surface>
    """
  end

  attr :cockpit, :map, required: true
  attr :datetime_preferences, :map, required: true

  def recent_events_section(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="upstream-event-summary"
      title="Recent events"
      description="Metadata-only summary of recent request and audit activity for this upstream."
      count={Formatting.pluralize_count(@cockpit.recent_events.count, "event", "events")}
    >
      <div class="grid gap-4 p-4">
        <p class="text-sm leading-6 text-base-content/70">
          {recent_events_description(@cockpit.recent_events)}
        </p>

        <div
          :if={@cockpit.recent_events.items != []}
          id="upstream-event-summary-rows"
          class="grid gap-3"
          role="list"
        >
          <article
            :for={event_row <- recent_event_rows(@cockpit.recent_events.items)}
            id={event_row.id}
            data-role="recent-event-row"
            class="grid gap-3 rounded-box border border-base-300 bg-base-200/45 p-3 md:grid-cols-[auto_minmax(0,1fr)_auto] md:items-center"
            role="listitem"
          >
            <div class="flex items-start md:justify-center">
              <span
                data-role="recent-event-source"
                class={event_source_badge_class(event_row.event.source)}
              >
                {event_source_label(event_row.event.source)}
              </span>
            </div>
            <div class="grid min-w-0 gap-1">
              <h3
                data-role="recent-event-title"
                class="break-words text-sm font-semibold text-base-content"
              >
                {event_row.event.title}
              </h3>
              <p
                data-role="recent-event-subtitle"
                class="break-words text-xs leading-5 text-base-content/65"
              >
                {event_row.event.subtitle}
              </p>
              <time
                data-role="recent-event-timestamp"
                datetime={DateTime.to_iso8601(event_row.event.timestamp)}
                class="text-xs font-medium text-base-content/55"
              >
                {Formatting.format_event_timestamp(event_row.event.timestamp, @datetime_preferences)}
              </time>
            </div>
            <.link
              data-role="recent-event-link"
              href={event_row.event.link}
              class="btn btn-ghost btn-xs justify-self-start gap-2 md:justify-self-end"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
              <span>Open evidence</span>
            </.link>
          </article>
        </div>

        <AdminComponents.empty_state
          :if={@cockpit.recent_events.items == []}
          id="upstream-event-summary-empty"
          title="No recent upstream events"
          description="Request and audit activity for this upstream account will appear here when the read model projects compact metadata events."
          icon="hero-clipboard-document-list"
        />
      </div>
      <:footer>
        <div class="flex flex-col gap-3 text-sm text-base-content/65 md:flex-row md:items-center md:justify-between">
          <p>
            For manual audit filtering, use upstream identity id <span class="font-mono">{@cockpit.identity.id}</span>.
          </p>
          <div class="flex flex-wrap gap-2">
            <.link
              id="upstream-event-summary-request-logs-link"
              href={Formatting.request_logs_path(@cockpit)}
              class="btn btn-secondary btn-xs gap-2"
            >
              <.icon name="hero-document-magnifying-glass" class="size-3.5" />
              <span>Filtered request logs</span>
            </.link>
            <.link
              id="upstream-event-summary-audit-logs-link"
              href={Formatting.audit_logs_path(@cockpit)}
              class="btn btn-secondary btn-xs gap-2"
            >
              <.icon name="hero-clipboard-document-list" class="size-3.5" />
              <span>Audit logs</span>
            </.link>
          </div>
        </div>
      </:footer>
    </AdminComponents.admin_surface>
    """
  end

  attr :cockpit, :map, required: true
  attr :saved_reset_policy_form, :any, required: true
  attr :confirming_saved_reset_redemption, :map, default: nil

  attr :datetime_preferences, :map, required: true

  def actions_section(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="upstream-actions"
      title="Available actions"
      description="Bounded operator actions reuse the upstream account workflows and refresh this cockpit after successful mutations."
    >
      <div class="grid gap-3 p-4 sm:grid-cols-2 xl:grid-cols-3">
        <.cockpit_action_button
          id={"cockpit-rename-upstream-account-#{@cockpit.identity.id}"}
          label="Rename"
          icon="hero-pencil-square"
          action={@cockpit.actions.rename}
          phx-click="open_rename_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.cockpit_action_button
          id={"cockpit-pause-upstream-account-#{@cockpit.identity.id}"}
          label="Pause"
          icon="hero-pause"
          action={@cockpit.actions.pause}
          variant={:warning}
          phx-click="pause_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.cockpit_action_button
          id={"cockpit-reactivate-upstream-account-#{@cockpit.identity.id}"}
          label="Reactivate"
          icon="hero-play"
          action={@cockpit.actions.reactivate}
          variant={:positive}
          phx-click="reactivate_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.cockpit_action_button
          id={"cockpit-refresh-upstream-account-#{@cockpit.identity.id}"}
          label="Refresh token"
          icon="hero-arrow-path"
          action={@cockpit.actions.refresh_token}
          phx-click="refresh_account"
          phx-value-id={@cockpit.identity.id}
        />
        <.cockpit_action_button
          id={"cockpit-redeem-saved-reset-upstream-account-#{@cockpit.identity.id}"}
          label="Redeem saved reset"
          action={@cockpit.actions.redeem_saved_reset}
          icon="hero-bolt"
          phx-click="open_saved_reset_redemption_confirmation"
          phx-value-id={@cockpit.identity.id}
          phx-value-pool-id={default_pool_id(@cockpit)}
        />
        <.cockpit_action_button
          id={"cockpit-replace-auth-json-upstream-account-#{@cockpit.identity.id}"}
          label="Replace auth.json"
          icon="hero-document-arrow-up"
          action={@cockpit.actions.replace_auth_json}
          phx-click="open_import_auth_json"
          phx-value-id={@cockpit.identity.id}
          phx-value-pool-id={default_pool_id(@cockpit)}
        />
        <.cockpit_action_button
          id={"cockpit-oauth-relink-upstream-account-#{@cockpit.identity.id}"}
          label="OAuth relink"
          icon="hero-link"
          action={@cockpit.actions.oauth_relink}
          variant={:primary}
          phx-click="open_oauth_relink"
          phx-value-id={@cockpit.identity.id}
        />
        <.cockpit_reinvite_link cockpit={@cockpit} />
        <.cockpit_action_button
          id={"cockpit-delete-upstream-account-#{@cockpit.identity.id}"}
          label="Delete"
          icon="hero-trash"
          action={@cockpit.actions.delete}
          variant={:danger}
          phx-click="open_delete_account"
          phx-value-id={@cockpit.identity.id}
        />
      </div>
      <div
        :if={confirming_saved_reset_redemption?(@confirming_saved_reset_redemption, @cockpit)}
        id="cockpit-saved-reset-redemption-confirmation"
        class="mx-4 mb-4 grid gap-3 rounded-box border border-warning/30 bg-warning/10 p-4"
      >
        <div class="grid gap-1">
          <h3 class="text-sm font-semibold text-base-content">Confirm saved reset redemption</h3>
          <p class="text-sm leading-6 text-base-content/75">
            This queues one manual redemption for the selected upstream account. It is separate from the saved-reset policy form.
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
            label="Keep reset in bank"
            phx-click="cancel_saved_reset_redemption"
          />
        </div>
      </div>
      <div
        :if={@cockpit.saved_resets.available?}
        id="cockpit-saved-reset-expiration-summary"
        class="mx-4 mb-4 grid gap-3 rounded-box border border-base-300 bg-base-200/30 p-4"
      >
        <div class="grid gap-1">
          <h3 class="text-sm font-semibold text-base-content">Banked reset expirations</h3>
          <p class="text-xs leading-5 text-base-content/60">
            {@cockpit.saved_resets.label} currently available for this upstream account.
          </p>
        </div>
        <SavedResetComponents.saved_reset_expiration_table
          id="cockpit-saved-reset-expiration"
          saved_resets={@cockpit.saved_resets}
          datetime_preferences={@datetime_preferences}
          empty_label="No expiration dates reported for the available saved resets yet."
        />
      </div>
      <.form
        id="saved-reset-policy-form"
        for={@saved_reset_policy_form}
        phx-submit="save_saved_reset_policy"
        autocomplete="off"
        class="grid gap-4 border-t border-base-300 p-4"
      >
        <fieldset class="grid gap-4">
          <legend class="sr-only">Auto redeem policy</legend>
          <div
            id="saved-reset-policy-auto-redeem-control"
            class="grid gap-3 rounded-box border border-base-300 bg-base-200/30 p-4 lg:grid-cols-[minmax(0,1fr)_18rem] lg:items-start"
          >
            <div class="grid max-w-3xl gap-1">
              <p class="text-sm font-semibold text-base-content">Auto redeem policy</p>
              <p class="text-xs leading-5 text-base-content/60">
                Automatic redemption can wait until weekly quota is blocked, start earlier near the quota limit when every eligible account is under pressure, or rescue a soon-expiring reset when this account already has weekly usage. The reset buffer prevents spending when the weekly reset is close.
              </p>
            </div>
            <label
              id="saved-reset-policy-auto-redeem-card"
              for="saved-reset-policy-auto-redeem-enabled"
              class="flex min-h-12 w-full cursor-pointer items-center justify-between gap-3 rounded-box border border-base-300 bg-base-100 px-3 py-2 transition-colors hover:border-primary/50 hover:bg-primary/5"
            >
              <span class="text-sm font-medium text-base-content">Auto redeem saved resets</span>
              <input type="hidden" name="saved_reset_policy[auto_redeem_enabled]" value="false" />
              <input
                id="saved-reset-policy-auto-redeem-enabled"
                type="checkbox"
                name="saved_reset_policy[auto_redeem_enabled]"
                value="true"
                checked={form_checkbox_checked?(@saved_reset_policy_form[:auto_redeem_enabled])}
                class="toggle toggle-primary toggle-sm shrink-0"
              />
            </label>
          </div>

          <div id="saved-reset-policy-controls" class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            <.input
              field={@saved_reset_policy_form[:trigger_mode]}
              type="select"
              id="saved-reset-policy-trigger-mode"
              name="saved_reset_policy[trigger_mode]"
              label="Auto trigger"
              class="select select-bordered w-full"
              options={[
                {"Blocked or expiring", "blocked"},
                {"Near limit", "threshold"}
              ]}
            />
            <.input
              field={@saved_reset_policy_form[:quota_threshold_percent]}
              type="number"
              id="saved-reset-policy-quota-threshold-percent"
              name="saved_reset_policy[quota_threshold_percent]"
              label="Near limit %"
              class="input input-bordered w-full"
              min="1"
              max="100"
              step="1"
            />
            <.input
              field={@saved_reset_policy_form[:min_blocked_minutes]}
              type="number"
              id="saved-reset-policy-min-blocked-minutes"
              name="saved_reset_policy[min_blocked_minutes]"
              label="Reset buffer min"
              class="input input-bordered w-full"
              min="0"
            />
            <.input
              field={@saved_reset_policy_form[:keep_credits]}
              type="number"
              id="saved-reset-policy-keep-credits"
              name="saved_reset_policy[keep_credits]"
              label="Keep credits"
              class="input input-bordered w-full"
              min="0"
            />
          </div>
        </fieldset>

        <div class="flex justify-end border-t border-base-300/70 pt-3">
          <AdminComponents.action_button
            id="saved-reset-policy-submit"
            label="Save policy"
            icon="hero-check"
            type="submit"
            variant={:primary}
          />
        </div>
      </.form>
      <:footer>
        <p class="text-sm text-base-content/65">
          Assignment and Pool changes stay on linked admin pages; this cockpit only mutates the upstream identity lifecycle and credentials.
        </p>
      </:footer>
    </AdminComponents.admin_surface>
    """
  end

  attr :cockpit, :map, required: true

  def related_links_section(assigns) do
    ~H"""
    <AdminComponents.admin_surface
      id="upstream-related-links"
      title="Related admin pages"
      description="Use linked admin pages for full request and audit evidence."
    >
      <div class="flex flex-wrap gap-2 p-4">
        <.link
          href={Formatting.request_logs_path(@cockpit)}
          class="btn btn-secondary btn-sm gap-2"
        >
          <.icon name="hero-document-magnifying-glass" class="size-4" />
          <span>Request logs</span>
        </.link>
        <.link
          href={Formatting.audit_logs_path(@cockpit)}
          class="btn btn-secondary btn-sm gap-2"
        >
          <.icon name="hero-clipboard-document-list" class="size-4" />
          <span>Audit logs</span>
        </.link>
      </div>
    </AdminComponents.admin_surface>
    """
  end

  attr :cockpit, :map, required: true
  attr :refresh_data_message, :string, default: nil

  def refresh_section(assigns) do
    ~H"""
    <section
      id="upstream-refresh-data"
      class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p class="text-xs font-semibold uppercase tracking-wide text-primary">Refresh data</p>
          <h2 class="mt-1 text-lg font-semibold text-base-content">Refresh cockpit data</h2>
          <p class="mt-2 max-w-3xl text-sm leading-6 text-base-content/65">
            Quota and upstream lifecycle changes refresh automatically when scoped broadcasts are available. Request health, recent events, and contribution metrics refresh only when this cockpit is reloaded.
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <span class="badge badge-outline">refresh {@cockpit.header.refresh_status}</span>
          <AdminComponents.action_button
            id="upstream-refresh-data-button"
            icon="hero-arrow-path"
            label="Refresh cockpit data"
            phx-click="refresh_data"
            variant={:primary}
          />
        </div>
      </div>
      <p
        :if={@refresh_data_message}
        id="upstream-refresh-data-message"
        class="mt-3 rounded-box border border-success/30 bg-success/10 px-3 py-2 text-sm font-medium text-success"
      >
        {@refresh_data_message}
      </p>
      <dl class="mt-4 grid gap-3 text-sm sm:grid-cols-2">
        <div>
          <dt class="text-xs font-semibold uppercase text-base-content/45">Auth imported</dt>
          <dd class="mt-1 text-base-content">{@cockpit.header.auth_fresh_label}</dd>
        </div>
        <div>
          <dt class="text-xs font-semibold uppercase text-base-content/45">Token refresh</dt>
          <dd class="mt-1 text-base-content">{@cockpit.header.token_refresh_label}</dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :action, :map, required: true
  attr :variant, :atom, default: :neutral
  attr :rest, :global, include: ~w(phx-click phx-value-id phx-value-pool-id)

  defp cockpit_action_button(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-200/60 p-3">
      <div class="flex items-center justify-between gap-2">
        <AdminComponents.action_button
          id={@id}
          icon={@icon}
          label={@label}
          variant={@variant}
          disabled={!@action.available?}
          title={@action.reason}
          {@rest}
        />
        <span class={action_state_class(@action)}>{action_state_label(@action)}</span>
      </div>
      <p :if={!@action.available? && @action.reason} class="mt-2 text-xs text-base-content/60">
        {@action.reason}
      </p>
    </div>
    """
  end

  attr :cockpit, :map, required: true

  defp cockpit_reinvite_link(assigns) do
    assigns = assign(assigns, :path, reinvite_path(assigns.cockpit))

    ~H"""
    <div class="rounded-box border border-base-300 bg-base-200/60 p-3">
      <div class="flex items-center justify-between gap-2">
        <AdminComponents.action_button
          :if={@path}
          id={"cockpit-reinvite-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-user-plus"
          label="Reinvite account"
          navigate={@path}
          disabled={!@cockpit.actions.reinvite.available?}
          title={@cockpit.actions.reinvite.reason}
        />
        <AdminComponents.action_button
          :if={!@path}
          id={"cockpit-reinvite-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-user-plus"
          label="Reinvite account"
          disabled
          title={@cockpit.actions.reinvite.reason}
        />
        <span class={action_state_class(@cockpit.actions.reinvite)}>
          {action_state_label(@cockpit.actions.reinvite)}
        </span>
      </div>
      <p
        :if={!@cockpit.actions.reinvite.available? && @cockpit.actions.reinvite.reason}
        class="mt-2 text-xs text-base-content/60"
      >
        {@cockpit.actions.reinvite.reason}
      </p>
    </div>
    """
  end

  defp form_checkbox_checked?(field) do
    Form.normalize_value("checkbox", field.value)
  end

  defp default_pool_id(%{assignments: %{items: [%{pool_id: pool_id} | _items]}}), do: pool_id
  defp default_pool_id(_cockpit), do: nil

  defp confirming_saved_reset_redemption?(%{identity_id: identity_id}, %{
         identity: %{id: identity_id}
       }),
       do: true

  defp confirming_saved_reset_redemption?(_confirmation, _cockpit), do: false

  defp reinvite_path(cockpit) do
    pool_id = default_pool_id(cockpit)

    if cockpit.actions.reinvite.available? and is_binary(pool_id) do
      ~p"/admin/invites?#{%{create: "1", pool_id: pool_id}}"
    end
  end

  defp recent_events_description(%{empty?: true}), do: "No recent upstream events"

  defp recent_events_description(%{count: count, degraded?: true}) do
    "#{Formatting.pluralize_count(count, "recent event", "recent events")} need operator review."
  end

  defp recent_events_description(%{count: count}) do
    "#{Formatting.pluralize_count(count, "recent event", "recent events")} are available on linked evidence pages."
  end

  defp recent_event_rows(items) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {event, index} ->
      %{id: "upstream-event-summary-row-#{index}", event: event}
    end)
  end

  defp event_source_label("request_log"), do: "request log"
  defp event_source_label("audit_log"), do: "audit log"
  defp event_source_label(source), do: source |> Formatting.status_text() |> String.downcase()

  defp event_source_badge_class("request_log"), do: "badge badge-info badge-sm"
  defp event_source_badge_class("audit_log"), do: "badge badge-primary badge-sm"
  defp event_source_badge_class(_source), do: "badge badge-neutral badge-sm"

  defp quota_item_for(cockpit, assignment) do
    Enum.find(cockpit.charts.quota_health.items, &(&1.assignment_id == assignment.id))
  end

  defp pool_contribution_item_for(cockpit, assignment) do
    Enum.find(cockpit.charts.pool_contribution.items, &(&1.assignment_id == assignment.id))
  end

  defp quota_assignment_label(%{state: "missing_evidence"}), do: "Quota missing"
  defp quota_assignment_label(%{state: "stale"}), do: "Quota refresh needed"
  defp quota_assignment_label(%{state: state}), do: Formatting.status_label("Quota", state)

  defp action_state_label(%{available?: true}), do: "available"
  defp action_state_label(_action), do: "not available"

  defp action_state_class(%{available?: true}), do: "badge badge-success"
  defp action_state_class(_action), do: "badge badge-neutral"
end
