defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.Upstreams.SavedResets
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.Format
  alias CodexPoolerWeb.Admin.PoolInviteForm
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.Formatting, as: ResetFormatting
  alias CodexPoolerWeb.DateTimeDisplay

  @reactivatable_statuses ~w(paused refresh_due refresh_failed)
  @recovery_statuses ~w(paused refresh_due refresh_failed reauth_required)
  @usable_refresh_statuses ~w(succeeded imported refreshing)

  attr :account, :map, required: true
  attr :account_index, :integer, required: true
  attr :panel_view, :atom, default: :usage, values: [:usage, :pools]

  attr :datetime_preferences, :map, default: nil

  def account_card(assigns) do
    datetime_preferences =
      Map.get(assigns, :datetime_preferences) || DateTimeDisplay.preferences_for_user(nil)

    saved_resets = saved_resets(assigns.account)
    saved_reset_policy = saved_reset_policy(assigns.account)
    subject_ref = Map.get(assigns.account, :subject_ref)

    assigns =
      assigns
      |> assign(:datetime_preferences, datetime_preferences)
      |> assign(:reported_quota_limits, reported_quota_limits(assigns.account.quota_limits))
      |> assign(:workspace_context_label, workspace_context_label(assigns.account))
      |> assign(:workspace_context_title, workspace_context_title(assigns.account))
      |> assign(:routing_readiness, routing_readiness(assigns.account))
      |> assign(:subject_ref, subject_ref)
      |> assign(:saved_resets, saved_resets)
      |> assign(:saved_reset_policy, saved_reset_policy)
      |> assign(
        :panel_view,
        normalize_panel_view(assigns.panel_view, saved_resets, assigns.account)
      )

    ~H"""
    <article
      id={"upstream-account-#{@account.identity.id}"}
      data-role="upstream-account-card"
      class={[
        "min-w-0 rounded-box border border-l-2 border-base-300 bg-base-100 transition-colors",
        @routing_readiness.border_class
      ]}
    >
      <header
        data-role="upstream-account-card-header"
        class="flex flex-row items-center justify-between gap-3 border-b border-base-300 bg-base-200/35 px-4 py-3"
      >
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            <h3 class="min-w-0 text-base font-semibold leading-5 text-base-content">
              <.link
                id={"upstream-account-#{@account.identity.id}-mail"}
                navigate={~p"/admin/upstreams/#{@account.identity.id}"}
                class="block truncate hover:text-primary focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
              >
                {@account.label}
              </.link>
            </h3>
            <span
              :if={@workspace_context_label != ""}
              id={"upstream-account-#{@account.identity.id}-workspace"}
              data-role="upstream-workspace-context"
              class="badge badge-ghost badge-sm shrink-0 max-w-48 truncate text-[0.65rem] text-base-content/50"
              title={@workspace_context_title}
            >
              {@workspace_context_label}
            </span>
            <span
              :if={@subject_ref}
              id={"upstream-account-#{@account.identity.id}-subject-ref"}
              data-role="upstream-subject-ref"
              class="badge badge-outline badge-sm shrink-0 font-mono text-[0.65rem] text-base-content/50"
            >
              Subject {@subject_ref}
            </span>
          </div>
        </div>
        <div
          id={"upstream-account-#{@account.identity.id}-header-actions"}
          class="flex shrink-0 items-center gap-2 self-center"
        >
          <.saved_reset_count_badge
            id={"upstream-account-#{@account.identity.id}-saved-reset-count"}
            identity_id={@account.identity.id}
            disabled={@account.identity.status == "deleted"}
            saved_resets={@saved_resets}
            saved_reset_policy={@saved_reset_policy}
          />
          <.upstream_plan_indicator account={@account} account_index={@account_index} />
          <.upstream_account_actions account={@account} />
        </div>
      </header>

      <div class="grid gap-4 p-4">
        <div
          id={"upstream-account-#{@account.identity.id}-panel-switcher"}
          data-role="upstream-account-panel-switcher"
          data-panel-view={@panel_view}
          class="grid min-w-0 overflow-hidden"
        >
          <section
            id={"upstream-account-#{@account.identity.id}-usage-panel"}
            data-role="upstream-account-usage-panel"
            aria-hidden={aria_bool(@panel_view != :usage)}
            inert={@panel_view != :usage}
            class={account_panel_class(@panel_view == :usage)}
          >
            <div class="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-3">
              <div class="min-w-0">
                <p class="text-xs font-semibold uppercase text-primary">Status</p>
                <p
                  id={"upstream-account-#{@account.identity.id}-limits-summary"}
                  class="truncate text-xs text-base-content/60"
                >
                  {account_status_label(@account)}
                </p>
              </div>
              <div
                id={"upstream-account-#{@account.identity.id}-token-burn"}
                data-role="upstream-token-burn-summary"
                class="text-right"
              >
                <p
                  id={"upstream-account-#{@account.identity.id}-token-burn-label"}
                  class="text-xs font-semibold uppercase text-primary"
                >
                  TOKEN BURN
                </p>
                <.token_burn_popover
                  id={"upstream-account-#{@account.identity.id}-token-burn-value"}
                  content_id={"upstream-account-#{@account.identity.id}-token-burn-content"}
                  token_burn={token_burn(@account)}
                />
              </div>
            </div>
            <div
              id={"upstream-account-#{@account.identity.id}-limits"}
              class={quota_limits_grid_class(@reported_quota_limits)}
            >
              <.quota_limit_row
                :for={limit <- @reported_quota_limits}
                id={"upstream-account-#{@account.identity.id}-limit-#{limit.key}"}
                limit={limit}
              />
              <.saved_reset_meter
                :if={saved_reset_panel_available?(@saved_resets)}
                id={"upstream-account-#{@account.identity.id}-saved-reset-meter"}
                saved_resets={@saved_resets}
                saved_reset_policy={@saved_reset_policy}
                class={saved_reset_meter_grid_class(@reported_quota_limits)}
              />
            </div>
          </section>

          <section
            :if={pools_panel_available?(@account)}
            id={"upstream-account-#{@account.identity.id}-pools-panel"}
            data-role="upstream-account-pools-panel"
            aria-hidden={aria_bool(@panel_view != :pools)}
            inert={@panel_view != :pools}
            class={account_panel_class(@panel_view == :pools)}
          >
            <div class="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-3">
              <div class="min-w-0">
                <p class="text-xs font-semibold uppercase text-primary">Pools</p>
                <p
                  id={"upstream-account-#{@account.identity.id}-pools-summary"}
                  class="truncate text-xs text-base-content/60"
                >
                  {pool_assignment_summary_label(@account.assignments)}
                </p>
              </div>
              <div class="min-w-0 text-right">
                <p class="text-xs font-semibold uppercase text-primary">Routing</p>
                <p
                  id={"upstream-account-#{@account.identity.id}-pools-routing-summary"}
                  class="truncate text-xs text-base-content/60"
                  title={@routing_readiness.reason}
                >
                  {@routing_readiness.label}
                </p>
              </div>
            </div>

            <div
              id={"upstream-account-#{@account.identity.id}-pool-assignments"}
              data-role="upstream-account-pool-assignments"
              class="grid gap-3"
            >
              <div
                :for={assignment <- @account.assignments}
                id={"upstream-account-#{@account.identity.id}-pool-assignment-#{assignment.id}"}
                data-role="upstream-account-pool-assignment"
                class="grid gap-1.5"
              >
                <div class="flex min-w-0 items-center justify-between gap-3 text-xs">
                  <span
                    data-role="upstream-account-pool-assignment-pool"
                    class="min-w-0 truncate font-medium text-base-content"
                    title={assignment.pool_label}
                  >
                    {assignment.pool_label}
                  </span>
                  <span
                    data-role="upstream-account-pool-assignment-eligibility"
                    class={assignment_eligibility_class(assignment.eligibility_status)}
                  >
                    {assignment_eligibility_label(assignment.eligibility_status)}
                  </span>
                </div>
                <div
                  id={"upstream-account-#{@account.identity.id}-pool-assignment-#{assignment.id}-route"}
                  data-role="upstream-account-pool-route"
                  role="meter"
                  aria-valuemin="0"
                  aria-valuemax="3"
                  aria-valuenow={pool_route_ready_count(assignment)}
                  aria-label={pool_route_aria_label(assignment)}
                  class="grid grid-cols-3 gap-1"
                >
                  <span
                    :for={segment <- pool_route_segments(assignment)}
                    id={"upstream-account-#{@account.identity.id}-pool-assignment-#{assignment.id}-route-#{segment.key}"}
                    data-role="upstream-account-pool-route-segment"
                    title={segment.detail_label}
                    class={pool_route_segment_class(segment)}
                  >
                    {segment.label}
                  </span>
                </div>
              </div>
            </div>
          </section>
        </div>

        <.upstream_lifecycle_blocker_warning
          account={@account}
          routing_readiness={@routing_readiness}
        />
      </div>
      <footer
        data-role="upstream-account-card-footer"
        class="border-t border-base-300 bg-base-200/20 px-4 py-2.5"
      >
        <dl
          id={"upstream-account-#{@account.identity.id}-routing-readiness"}
          class="grid min-w-0 grid-cols-3 divide-x divide-base-300/70 text-xs leading-5"
        >
          <div class="min-w-0 pr-3" data-role="upstream-routing-cell">
            <dt class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/35">
              Routing
            </dt>
            <dd class="truncate text-base-content/60" title={@routing_readiness.reason}>
              {@routing_readiness.label}
            </dd>
          </div>
          <div class="group relative isolate min-w-0 pl-3" data-role="upstream-pool-count-cell">
            <dt class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/35 transition-colors group-hover:text-primary/70">
              <button
                id={"upstream-account-#{@account.identity.id}-pools-panel-trigger"}
                type="button"
                class={pools_footer_trigger_class(@panel_view == :pools)}
                phx-click="toggle_account_pools_panel"
                phx-value-id={@account.identity.id}
                aria-controls={"upstream-account-#{@account.identity.id}-pools-panel"}
                aria-expanded={aria_bool(@panel_view == :pools)}
                aria-label={pools_panel_trigger_label(@panel_view, @account.assignments)}
              >
                <span class="sr-only">Pools</span>
              </button>
              <span class="pointer-events-none relative z-30 block max-w-full truncate text-left uppercase">
                Pools
              </span>
            </dt>
            <dd class="pointer-events-none relative z-30 truncate text-base-content/60 transition-colors group-hover:text-base-content/75">
              {assignment_count_label(@account.assignments)}
            </dd>
          </div>
          <div class="min-w-0 pl-3" data-role="upstream-token-status-cell">
            <dt class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/35">
              5m tokens
            </dt>
            <dd class="truncate text-base-content/60">
              {recent_token_count_label(@account)}
            </dd>
          </div>
        </dl>
      </footer>
      <.upstream_refresh_status account={@account} />
      <.upstream_selector_contracts account={@account} routing_readiness={@routing_readiness} />
    </article>
    """
  end

  defp saved_resets(%{saved_resets: saved_resets}), do: saved_resets
  defp saved_resets(%{identity: identity}), do: SavedResets.snapshot(identity)
  defp saved_resets(_account), do: SavedResets.snapshot(nil)

  defp saved_reset_policy(%{saved_reset_policy: saved_reset_policy}), do: saved_reset_policy
  defp saved_reset_policy(%{identity: identity}), do: SavedResets.auto_policy(identity)

  defp normalize_panel_view(:pools, _saved_resets, account) do
    if pools_panel_available?(account), do: :pools, else: :usage
  end

  defp normalize_panel_view(_panel_view, _saved_resets, _account), do: :usage

  defp saved_reset_panel_available?(%{reported?: true, available_count: count})
       when is_integer(count) and count > 0,
       do: true

  defp saved_reset_panel_available?(_saved_resets), do: false

  defp pools_panel_available?(%{assignments: assignments}) when is_list(assignments),
    do: assignments != []

  defp pools_panel_available?(_account), do: false

  defp account_panel_class(true) do
    "grid min-w-0 max-h-[28rem] gap-3 overflow-hidden opacity-100 transition-opacity duration-150 ease-out motion-reduce:transition-none"
  end

  defp account_panel_class(false) do
    "pointer-events-none grid min-w-0 max-h-0 gap-3 overflow-hidden opacity-0 transition-opacity duration-150 ease-out motion-reduce:transition-none"
  end

  defp aria_bool(true), do: "true"
  defp aria_bool(false), do: "false"

  attr :account, :map, required: true

  defp upstream_account_actions(assigns) do
    assigns =
      assign(assigns,
        recovery_eligible?: recovery_eligible?(assigns.account),
        recovery_default_pool_id: recovery_default_pool_id(assigns.account),
        recovery_reinvite_path: recovery_reinvite_path(assigns.account),
        oauth_relink_available?: oauth_relink_available?(assigns.account),
        oauth_relink_unavailable_reason: oauth_relink_unavailable_reason(assigns.account)
      )

    ~H"""
    <div
      class="dropdown dropdown-end inline-block shrink-0 self-center"
      data-role="upstream-account-actions"
    >
      <button
        id={"upstream-account-actions-menu-#{@account.identity.id}"}
        type="button"
        class="btn btn-ghost btn-sm btn-square"
        tabindex="0"
        aria-label={"Actions for #{@account.label}"}
      >
        <.icon name="hero-ellipsis-vertical" class="size-5" />
      </button>
      <ul
        tabindex="0"
        class="menu dropdown-content z-20 mt-2 w-60 rounded-box border border-base-300 bg-base-100 p-2 text-left shadow-xl"
      >
        <li>
          <AdminComponents.dropdown_action_item
            id={"rename-upstream-account-#{@account.identity.id}"}
            icon="hero-pencil-square"
            label="Rename"
            phx-click="open_rename_account"
            phx-value-id={@account.identity.id}
            disabled={@account.identity.status == "deleted"}
          />
        </li>
        <li>
          <AdminComponents.dropdown_action_item
            id={"pause-upstream-account-#{@account.identity.id}"}
            icon="hero-pause"
            label="Pause"
            variant={:warning}
            phx-click="pause_account"
            phx-value-id={@account.identity.id}
            disabled={!pausable?(@account.identity.status)}
          />
        </li>
        <li>
          <AdminComponents.dropdown_action_item
            id={"reactivate-upstream-account-#{@account.identity.id}"}
            icon="hero-play"
            label="Reactivate"
            variant={:positive}
            phx-click="reactivate_account"
            phx-value-id={@account.identity.id}
            disabled={!reactivatable?(@account.identity.status)}
          />
        </li>
        <li :if={@recovery_eligible?}>
          <AdminComponents.dropdown_action_item
            id={"replace-auth-json-upstream-account-#{@account.identity.id}"}
            icon="hero-document-arrow-up"
            label="Replace auth.json"
            phx-click="open_import_auth_json"
            phx-value-pool-id={@recovery_default_pool_id}
          />
        </li>
        <li :if={@recovery_eligible?}>
          <AdminComponents.dropdown_action_item
            id={"oauth-relink-upstream-account-#{@account.identity.id}"}
            icon="hero-link"
            label="Relink account"
            phx-click="open_oauth_relink"
            phx-value-id={@account.identity.id}
            disabled={!@oauth_relink_available?}
            title={@oauth_relink_unavailable_reason}
          />
        </li>
        <li :if={@recovery_eligible?}>
          <AdminComponents.dropdown_action_item
            :if={@recovery_reinvite_path}
            id={"reinvite-upstream-account-#{@account.identity.id}"}
            icon="hero-user-plus"
            label="Reinvite account"
            navigate={@recovery_reinvite_path}
          />
          <AdminComponents.dropdown_action_item
            :if={!@recovery_reinvite_path}
            id={"reinvite-upstream-account-#{@account.identity.id}"}
            icon="hero-user-plus"
            label="Reinvite account"
            disabled
            title="Assign this account to a visible Pool before creating a reinvite."
          />
        </li>
        <li>
          <AdminComponents.dropdown_action_item
            id={"refresh-upstream-account-#{@account.identity.id}"}
            icon="hero-arrow-path"
            label="Refresh token"
            phx-click="refresh_account"
            phx-value-id={@account.identity.id}
            disabled={!refreshable?(@account.identity.status)}
          />
        </li>
        <li>
          <AdminComponents.dropdown_action_item
            id={"saved-reset-policy-upstream-account-#{@account.identity.id}"}
            icon="hero-battery-100"
            label="Saved resets"
            phx-click="open_saved_reset_policy"
            phx-value-id={@account.identity.id}
            disabled={@account.identity.status == "deleted"}
          />
        </li>
        <li>
          <AdminComponents.dropdown_action_item
            id={"delete-upstream-account-#{@account.identity.id}"}
            icon="hero-trash"
            label="Delete"
            variant={:danger}
            phx-click="delete_account"
            phx-value-id={@account.identity.id}
            disabled={@account.identity.status == "deleted"}
          />
        </li>
      </ul>
    </div>
    """
  end

  attr :account, :map, required: true
  attr :account_index, :integer, required: true

  defp upstream_plan_indicator(assigns) do
    ~H"""
    <AdminBadges.plan_badge
      :if={@account.plan_reported?}
      id={account_plan_label_id(@account, @account_index)}
      label={@account.plan_label}
      variant={:metadata}
      class="self-center"
      aria-label={"Account plan: #{@account.plan_label}"}
    />
    <AdminComponents.diagnostic_popover
      :if={!@account.plan_reported?}
      id={account_plan_label_id(@account, @account_index)}
      label="Account did not report plan or quota details"
      title="Plan and quota not reported"
      description="This account did not report plan or quota details. Routing still depends on separate quota evidence before dispatch."
      placement={:end}
    />
    """
  end

  attr :id, :string, required: true
  attr :identity_id, :string, required: true
  attr :saved_resets, :map, required: true
  attr :saved_reset_policy, :map, required: true
  attr :disabled, :boolean, default: false

  defp saved_reset_count_badge(
         %{saved_resets: %{reported?: true, available_count: count}} = assigns
       )
       when is_integer(count) and count > 0 do
    assigns =
      assigns
      |> assign(:badge_class, saved_reset_count_badge_class(assigns.saved_reset_policy))
      |> assign(:badge_icon_class, saved_reset_count_badge_icon_class(assigns.saved_reset_policy))
      |> assign(:aria_label, saved_reset_count_badge_aria_label(assigns.saved_resets))

    ~H"""
    <button
      id={@id}
      type="button"
      data-role="upstream-saved-reset-count-badge"
      class={@badge_class}
      aria-label={@aria_label}
      aria-controls="saved-reset-policy-dialog"
      aria-haspopup="dialog"
      phx-click="open_saved_reset_policy"
      phx-value-id={@identity_id}
      disabled={@disabled}
    >
      <.icon name="hero-battery-100" class={@badge_icon_class} />
      <span>{@saved_resets.available_count}</span>
    </button>
    """
  end

  defp saved_reset_count_badge(assigns) do
    ~H"""
    """
  end

  defp saved_reset_count_badge_class(policy), do: saved_reset_count_badge_tone_class(policy)

  defp saved_reset_count_badge_tone_class(%{enabled?: true}) do
    [
      saved_reset_count_badge_base_class(),
      "border-success/40 bg-success/15 text-success hover:bg-success/20 dark:border-success/60 dark:bg-success/20 dark:text-success"
    ]
  end

  defp saved_reset_count_badge_tone_class(_policy) do
    [
      saved_reset_count_badge_base_class(),
      "border-violet-500/50 bg-violet-500/10 text-violet-700 hover:bg-violet-500/15 dark:border-violet-300/50 dark:bg-violet-400/10 dark:text-violet-200"
    ]
  end

  defp saved_reset_count_badge_base_class do
    "inline-flex cursor-pointer items-center rounded-full border px-2.5 py-1 text-xs font-medium leading-none transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary disabled:cursor-default disabled:opacity-70 gap-1.5 self-center whitespace-nowrap tabular-nums"
  end

  defp saved_reset_count_badge_icon_class(%{enabled?: true}) do
    "size-3 shrink-0 text-current"
  end

  defp saved_reset_count_badge_icon_class(_policy) do
    "size-3 shrink-0 text-violet-600 dark:text-violet-300"
  end

  defp pool_assignment_summary_label([_assignment]), do: "1 routing lane"
  defp pool_assignment_summary_label(assignments), do: "#{length(assignments)} routing lanes"

  defp pools_panel_trigger_label(:pools, _assignments), do: "Show quota status"

  defp pools_panel_trigger_label(_panel_view, assignments),
    do: "Show Pool assignments: #{assignment_count_label(assignments)}"

  defp pools_footer_trigger_class(true) do
    [
      pools_footer_trigger_base_class(),
      "border-primary/35 bg-primary/5"
    ]
  end

  defp pools_footer_trigger_class(false) do
    [
      pools_footer_trigger_base_class(),
      "border-transparent hover:border-primary/25 hover:bg-primary/5"
    ]
  end

  defp pools_footer_trigger_base_class do
    "absolute inset-x-1 inset-y-[-0.35rem] z-20 cursor-pointer rounded border transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
  end

  defp saved_reset_count_badge_aria_label(saved_resets),
    do: "Open saved reset bank: #{saved_resets.label}"

  attr :id, :string, required: true
  attr :saved_resets, :map, required: true
  attr :saved_reset_policy, :map, required: true
  attr :class, :any, default: nil

  defp saved_reset_meter(assigns) do
    assigns =
      assigns
      |> assign(:segments, saved_reset_meter_segments(assigns.saved_resets))
      |> assign(:meter_max, saved_reset_meter_max(assigns.saved_resets))
      |> assign(:meter_value, saved_reset_meter_value(assigns.saved_resets))
      |> assign(:meter_label, saved_reset_meter_label(assigns.saved_resets))
      |> assign(:meter_count_label, saved_reset_meter_count_label(assigns.saved_resets))
      |> assign(:meter_reset_label, saved_reset_meter_reset_label(assigns.saved_resets))
      |> assign(:meter_policy_active, saved_reset_policy_active?(assigns.saved_reset_policy))

    ~H"""
    <div id={@id} data-role="upstream-saved-reset-meter" class={["grid gap-1.5", @class]}>
      <div class="flex min-w-0 items-center justify-between gap-3 text-xs">
        <span
          data-role="upstream-saved-reset-meter-title"
          class="min-w-0 truncate font-medium text-base-content"
        >
          Banked Resets
        </span>
        <span
          data-role="upstream-saved-reset-meter-count"
          class={saved_reset_meter_count_class(@saved_reset_policy)}
        >
          {@meter_count_label}
        </span>
      </div>
      <div
        id={"#{@id}-bar"}
        role="meter"
        aria-valuemin="0"
        aria-valuemax={@meter_max}
        aria-valuenow={@meter_value}
        aria-label={@meter_label}
        class="grid grid-cols-5 gap-1"
      >
        <span
          :for={segment <- @segments}
          id={"#{@id}-segment-#{segment.index}"}
          data-role="upstream-saved-reset-meter-segment"
          aria-hidden="true"
          class={saved_reset_meter_segment_class(segment, @saved_reset_policy)}
        ></span>
      </div>
      <div class="flex items-center justify-between gap-3 text-[11px] text-base-content/60">
        <span
          id={"#{@id}-policy"}
          data-role="upstream-saved-reset-meter-policy"
          class="min-w-0 truncate"
        >
          Auto redeem
          <span :if={@meter_policy_active} class="font-medium text-violet-700 dark:text-violet-200">
            active
          </span>
          <span :if={!@meter_policy_active}>inactive</span>
        </span>
        <span
          :if={@meter_reset_label}
          id={"#{@id}-reset"}
          class="inline-flex shrink-0 items-center gap-1"
          title={@saved_resets.next_expires_title}
        >
          <.icon name="hero-clock" class="size-3 shrink-0" />
          <span class="truncate">{@meter_reset_label}</span>
        </span>
      </div>
    </div>
    """
  end

  defp saved_reset_meter_segments(saved_resets) do
    filled_count = min(saved_reset_meter_value(saved_resets), 5)

    Enum.map(1..5, fn index ->
      %{index: index, filled?: index <= filled_count}
    end)
  end

  defp saved_reset_meter_value(%{available_count: count}) when is_integer(count) and count >= 0,
    do: count

  defp saved_reset_meter_value(_saved_resets), do: 0

  defp saved_reset_meter_max(saved_resets), do: max(saved_reset_meter_value(saved_resets), 5)

  defp saved_reset_meter_label(%{label: label}) when is_binary(label) and label != "",
    do: label

  defp saved_reset_meter_label(saved_resets),
    do: "#{saved_reset_meter_value(saved_resets)} saved resets"

  defp saved_reset_meter_count_label(%{available_count: count})
       when is_integer(count) and count >= 0,
       do: "x#{count}"

  defp saved_reset_meter_count_label(saved_resets),
    do: "x#{saved_reset_meter_value(saved_resets)}"

  defp saved_reset_meter_reset_label(%{next_expires_at: expires_at}) do
    case ResetFormatting.parse_datetime(expires_at) do
      %DateTime{} = expires_at -> reset_time_left_label(expires_at)
      nil -> nil
    end
  end

  defp saved_reset_meter_reset_label(_saved_resets), do: nil

  defp reset_time_left_label(%DateTime{} = expires_at) do
    seconds_until_expiration = DateTime.diff(expires_at, DateTime.utc_now(), :second)

    if seconds_until_expiration > 0 do
      "in #{ResetFormatting.format_reset_duration(seconds_until_expiration)}"
    else
      "expired"
    end
  end

  defp saved_reset_policy_active?(%{enabled?: true}), do: true
  defp saved_reset_policy_active?(_policy), do: false

  defp saved_reset_meter_count_class(_policy),
    do: "shrink-0 tabular-nums font-medium text-violet-700 dark:text-violet-200"

  defp saved_reset_meter_segment_class(%{filled?: true}, _policy),
    do: "h-1.5 rounded-full bg-violet-500/80 dark:bg-violet-300/80"

  defp saved_reset_meter_segment_class(_segment, _policy),
    do: "h-1.5 rounded-full bg-base-300/70"

  attr :account, :map, required: true
  attr :routing_readiness, :map, required: true

  defp upstream_lifecycle_blocker_warning(assigns) do
    assigns =
      assigns
      |> assign(:warning, lifecycle_blocker_warning(assigns.account, assigns.routing_readiness))

    ~H"""
    <div
      :if={@warning}
      id={@warning.id}
      class="rounded-box border border-error/30 bg-error/10 p-3 text-sm text-base-content"
    >
      <div class="flex items-start gap-2">
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-error" />
        <div class="space-y-1">
          <p class="font-semibold text-error">{@warning.title}</p>
          <p>
            {@warning.body}
          </p>
          <p :if={@account.reauth_reason_message} class="text-xs text-base-content/70">
            Reason: {@account.reauth_reason_code || "token refresh failed"} — {@account.reauth_reason_message}
          </p>
          <p
            :if={!@account.reauth_reason_message && @account.reauth_reason_code}
            class="text-xs text-base-content/70"
          >
            Reason: {@account.reauth_reason_code}
          </p>
          <p class="text-xs font-medium text-base-content/75">
            Recovery: {@warning.recovery}
          </p>
        </div>
      </div>
    </div>
    """
  end

  attr :account, :map, required: true

  defp upstream_refresh_status(assigns) do
    ~H"""
    <div class="hidden">
      <div id={"upstream-account-#{@account.identity.id}-refresh-status"}>
        Refresh: {@account.refresh_status}
        <span :if={@account.refresh_job_state}>
          · job {@account.refresh_job_state}
        </span>
      </div>
    </div>
    """
  end

  attr :account, :map, required: true
  attr :routing_readiness, :map, required: true

  defp upstream_selector_contracts(assigns) do
    ~H"""
    <div class="hidden" data-role="upstream-account-selector-contracts">
      <section id={"upstream-account-#{@account.identity.id}-routing-readiness-contract"}>
        routing readiness
        <span id={"upstream-account-#{@account.identity.id}-routing-readiness-state"}>
          {@routing_readiness.state}
        </span>
        <span id={"upstream-account-#{@account.identity.id}-routing-readiness-label"}>
          {@routing_readiness.label}
        </span>
        <span id={"upstream-account-#{@account.identity.id}-routing-readiness-reason"}>
          {@routing_readiness.reason}
        </span>
      </section>

      <section id={"upstream-account-#{@account.identity.id}-quota-readiness-contract"}>
        quota readiness
        <span id={"upstream-account-#{@account.identity.id}-quota-readiness-state"}>
          {@account.quota_readiness.state}
        </span>
        <span id={"upstream-account-#{@account.identity.id}-quota-readiness-label"}>
          {@account.quota_readiness.label}
        </span>
      </section>

      <section id={"upstream-account-#{@account.identity.id}-auth-health"}>
        Auth health
        <span id={"upstream-account-#{@account.identity.id}-auth-fresh"}>
          {@account.auth_fresh_label}
        </span>
        <span id={"upstream-account-#{@account.identity.id}-auth-verified"}>
          {@account.auth_verified_label}
        </span>
        <span id={"upstream-account-#{@account.identity.id}-access-token"}>
          {@account.access_token_label}
        </span>
        <span id={"upstream-account-#{@account.identity.id}-token-refresh"}>
          {@account.token_refresh_label}
        </span>
      </section>

      <section>
        quota refresh {@account.quota_refresh_status}
      </section>

      <section>
        <div
          :for={assignment <- @account.assignments}
          id={"upstream-account-#{@account.identity.id}-assignment-#{assignment.id}"}
        >
          <span>{assignment.pool_label}</span>
          <span>{assignment.assignment_label}</span>
          <span>{assignment.status}</span>
          <span>{assignment.eligibility_status}</span>
          <span id={"upstream-account-#{@account.identity.id}-assignment-#{assignment.id}-quota-priming"}>
            {assignment.quota_priming_label}
          </span>
        </div>
        <p :if={@account.assignments == []}>No active Pool assignments</p>
      </section>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :content_id, :string, required: true
  attr :token_burn, :map, required: true

  defp token_burn_popover(assigns) do
    ~H"""
    <span
      id={"#{@id}-popover"}
      data-role="upstream-token-burn-popover"
      class="dropdown dropdown-end dropdown-bottom inline-flex justify-end"
    >
      <button
        id={@id}
        type="button"
        class="inline-flex cursor-pointer items-center justify-end gap-1 rounded px-1 text-xs font-medium text-base-content/70 transition-colors hover:bg-base-300/60 hover:text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        tabindex="0"
        aria-label="Token burn calculation"
        aria-haspopup="true"
        aria-describedby={@content_id}
      >
        <.icon name="hero-fire" class={token_burn_icon_class(@token_burn)} />
        <span>{@token_burn.label}</span>
      </button>
      <span
        id={@content_id}
        role="tooltip"
        tabindex="0"
        class="dropdown-content z-50 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-3 text-left text-xs font-normal leading-5 text-base-content/70 shadow-xl sm:w-72"
      >
        <span class="block">
          Compares settled tokens from the last 5 minutes with the previous 1 hour baseline.
        </span>
        <span class="mt-2 grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1">
          <span class="font-medium text-base-content/55">Last 5 minutes</span>
          <span class="text-base-content">{token_burn_recent_token_label(@token_burn)}</span>
          <span class="font-medium text-base-content/55">Previous 1 hour</span>
          <span class="text-base-content">{token_burn_baseline_token_label(@token_burn)}</span>
        </span>
      </span>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :limit, :map, required: true

  defp quota_limit_row(assigns) do
    ~H"""
    <div id={@id} data-role="upstream-limit-chart" class="grid min-w-0 gap-1.5">
      <div class="flex min-w-0 items-center justify-between gap-3 text-xs">
        <span data-role="upstream-limit-title" class="min-w-0 truncate font-medium text-base-content">
          {@limit.label}
        </span>
        <span class={[quota_limit_percent_class(@limit), "shrink-0"]}>{@limit.percent_label}</span>
      </div>
      <progress
        id={"#{@id}-progress"}
        data-role="upstream-limit-progress"
        aria-label={"#{@limit.label} remaining #{@limit.percent_label}"}
        class={quota_limit_progress_class(@limit)}
        value={@limit.percent_value}
        max="100"
      >
        {@limit.percent_label}
      </progress>
      <div
        :if={quota_limit_details?(@limit)}
        class="flex items-center justify-between gap-3 text-[11px] text-base-content/60"
      >
        <span :if={@limit.count_label} id={"#{@id}-count"} class="tabular-nums">
          {@limit.count_label}
        </span>
        <span :if={is_nil(@limit.count_label)} aria-hidden="true"></span>
        <span
          :if={@limit.reset_label}
          id={"#{@id}-reset"}
          class="inline-flex items-center gap-1"
          title={@limit.reset_title}
        >
          <.icon name="hero-clock" class="size-3" />
          <span>{@limit.reset_label}</span>
        </span>
      </div>
    </div>
    """
  end

  defp quota_limit_details?(%{count_label: count_label, reset_label: reset_label}) do
    present_string?(count_label) or present_string?(reset_label)
  end

  @spec routing_readiness(map()) :: map()
  defp routing_readiness(%{routing_readiness: routing_readiness}) when is_map(routing_readiness),
    do: routing_readiness

  defp routing_readiness(_account) do
    %{
      state: "unavailable",
      label: "Routing unavailable",
      tone: :warning,
      border_class: "border-l-warning",
      routing_ready_now?: false,
      reason: "Routing readiness is unavailable for this upstream account.",
      reason_code: "routing_readiness_unavailable",
      recovery_action: nil
    }
  end

  @spec lifecycle_blocker_warning(map(), map()) :: map() | nil
  defp lifecycle_blocker_warning(
         %{identity: %{id: id, status: "refresh_failed"}},
         _routing_readiness
       ) do
    %{
      id: "upstream-account-#{id}-refresh-failed-warning",
      title: "Token refresh failed",
      body:
        "This account is excluded from runtime routing until token refresh succeeds or credentials are relinked.",
      recovery:
        "use Refresh token to retry token refresh, Relink account to complete OpenAI OAuth again, Replace auth.json to load fresh credentials, or Reinvite account when the operator needs to complete hosted sign-in again."
    }
  end

  defp lifecycle_blocker_warning(
         %{identity: %{id: id, status: "reauth_required"}},
         _routing_readiness
       ) do
    %{
      id: "upstream-account-#{id}-reauth-warning",
      title: "Reauthentication required",
      body: "This account is excluded from routing until credentials are replaced.",
      recovery:
        "use Relink account to complete OpenAI OAuth again, Replace auth.json to load fresh credentials, or Reinvite account when the operator needs to complete hosted sign-in again."
    }
  end

  defp lifecycle_blocker_warning(_account, _routing_readiness), do: nil

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp quota_limit_percent_class(%{percent: %Decimal{} = percent}) do
    cond do
      Decimal.compare(percent, Decimal.new(70)) != :lt -> "tabular-nums font-medium text-success"
      Decimal.compare(percent, Decimal.new(30)) != :lt -> "tabular-nums font-medium text-warning"
      true -> "tabular-nums font-medium text-error"
    end
  end

  defp quota_limit_percent_class(_limit), do: "tabular-nums font-medium text-base-content/50"

  defp quota_limit_progress_class(%{percent: %Decimal{} = percent}) do
    tone_class =
      cond do
        Decimal.compare(percent, Decimal.new(70)) != :lt -> "progress-success"
        Decimal.compare(percent, Decimal.new(30)) != :lt -> "progress-warning"
        true -> "progress-error"
      end

    "progress admin-live-progress #{tone_class} h-1.5 w-full"
  end

  defp quota_limit_progress_class(_limit),
    do: "progress admin-live-progress progress-neutral h-1.5 w-full"

  defp token_burn(%{token_burn: token_burn}) when is_map(token_burn), do: token_burn

  defp token_burn(_account) do
    %{
      level: 0,
      label: "x0",
      title: "last 5m: 0 tokens; previous 1h: 0 tokens",
      recent_tokens: 0,
      baseline_tokens: 0
    }
  end

  defp token_burn_recent_token_label(%{recent_tokens: tokens})
       when is_integer(tokens) and tokens >= 0 do
    "#{Format.token_count(tokens)} tokens"
  end

  defp token_burn_recent_token_label(_token_burn), do: "0 tokens"

  defp token_burn_baseline_token_label(%{baseline_tokens: tokens})
       when is_integer(tokens) and tokens >= 0 do
    "#{Format.token_count(tokens)} tokens"
  end

  defp token_burn_baseline_token_label(_token_burn), do: "0 tokens"

  defp token_burn_icon_class(%{level: 0}), do: "size-3.5 text-base-content/35"
  defp token_burn_icon_class(%{level: level}) when level in 1..2, do: "size-3.5 text-warning/70"
  defp token_burn_icon_class(%{level: level}) when level in 3..4, do: "size-3.5 text-warning"
  defp token_burn_icon_class(%{level: 5}), do: "size-3.5 text-error"
  defp token_burn_icon_class(_token_burn), do: "size-3.5 text-base-content/35"

  @spec workspace_context_label(map()) :: String.t()
  defp workspace_context_label(%{workspace_label: label}) when is_binary(label) and label != "",
    do: "Workspace " <> label

  defp workspace_context_label(%{workspace_ref: "legacy"}), do: ""

  defp workspace_context_label(%{workspace_ref: ref}) when is_binary(ref) and ref != "",
    do: "Workspace " <> ref

  defp workspace_context_label(_account), do: ""

  @spec workspace_context_title(map()) :: String.t() | nil
  defp workspace_context_title(%{workspace_ref: "legacy"}), do: nil

  defp workspace_context_title(%{workspace_ref: ref}) when is_binary(ref) and ref != "",
    do: "Workspace reference " <> ref

  defp workspace_context_title(_account), do: nil

  defp account_status_label(%{identity: %{status: status}}) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp account_status_label(_account), do: "Unknown"

  defp reported_quota_limits(quota_limits) when is_list(quota_limits) do
    Enum.filter(quota_limits, &match?(%{percent: %Decimal{}}, &1))
  end

  defp reported_quota_limits(_quota_limits), do: []

  defp quota_limits_grid_class([_single_limit]), do: "grid gap-3"
  defp quota_limits_grid_class(_limits), do: "grid gap-3 md:grid-cols-2"

  defp saved_reset_meter_grid_class([_single_limit]), do: nil
  defp saved_reset_meter_grid_class(_limits), do: "md:col-span-2"

  defp account_plan_label_id(account, _index),
    do: "upstream-account-#{account.identity.id}-plan-label"

  defp assignment_count_label([]), do: "No Pools"
  defp assignment_count_label([_assignment]), do: "1 Pool"
  defp assignment_count_label(assignments), do: "#{length(assignments)} Pools"

  defp assignment_eligibility_label(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp assignment_eligibility_label(_value), do: "Unknown"

  defp assignment_eligibility_class("eligible") do
    "shrink-0 text-[11px] font-medium leading-4 text-success"
  end

  defp assignment_eligibility_class("blocked") do
    "shrink-0 text-[11px] font-medium leading-4 text-error"
  end

  defp assignment_eligibility_class("paused") do
    "shrink-0 text-[11px] font-medium leading-4 text-warning"
  end

  defp assignment_eligibility_class(_status) do
    "shrink-0 text-[11px] font-medium leading-4 text-base-content/60"
  end

  defp pool_route_segments(assignment) do
    [
      %{
        key: "assignment",
        label: "Assignment",
        detail_label: assignment_state_label(Map.get(assignment, :status)),
        ready?: Map.get(assignment, :status) == "active",
        tone: assignment_state_tone(Map.get(assignment, :status))
      },
      %{
        key: "health",
        label: "Health",
        detail_label: assignment_health_label(Map.get(assignment, :health_status)),
        ready?: Map.get(assignment, :health_status) == "active",
        tone: assignment_health_tone(Map.get(assignment, :health_status))
      },
      %{
        key: "quota",
        label: "Quota",
        detail_label: Map.get(assignment, :quota_priming_label) || "Quota unknown",
        ready?: quota_priming_ready?(Map.get(assignment, :quota_priming_status)),
        tone: quota_priming_tone(Map.get(assignment, :quota_priming_status))
      }
    ]
  end

  defp pool_route_ready_count(assignment) do
    assignment
    |> pool_route_segments()
    |> Enum.count(& &1.ready?)
  end

  defp pool_route_aria_label(assignment) do
    segment_labels =
      assignment
      |> pool_route_segments()
      |> Enum.map_join(", ", & &1.detail_label)

    "#{Map.get(assignment, :pool_label, "Pool")} route path: #{segment_labels}"
  end

  defp pool_route_segment_class(%{tone: :success}),
    do: [pool_route_segment_base_class(), "bg-success/80 text-success-content"]

  defp pool_route_segment_class(%{tone: :warning}),
    do: [pool_route_segment_base_class(), "bg-warning/80 text-warning-content"]

  defp pool_route_segment_class(%{tone: :error}),
    do: [pool_route_segment_base_class(), "bg-error/80 text-error-content"]

  defp pool_route_segment_class(_segment) do
    [pool_route_segment_base_class(), "bg-base-300/70 text-base-content/55"]
  end

  defp pool_route_segment_base_class do
    "inline-flex h-4 min-w-0 items-center justify-center truncate rounded-full px-1 text-center text-[0.55rem] font-semibold uppercase leading-none tracking-[0.04em]"
  end

  defp assignment_state_label("active"), do: "Assignment active"
  defp assignment_state_label("paused"), do: "Assignment paused"
  defp assignment_state_label("disabled"), do: "Assignment disabled"
  defp assignment_state_label("deleted"), do: "Assignment deleted"
  defp assignment_state_label(status), do: "Assignment #{human_status_label(status)}"

  defp assignment_health_label("active"), do: "Health active"
  defp assignment_health_label("degraded"), do: "Health degraded"
  defp assignment_health_label("errored"), do: "Health errored"
  defp assignment_health_label(status), do: "Health #{human_status_label(status)}"

  defp assignment_state_tone("active"), do: :success
  defp assignment_state_tone("paused"), do: :warning
  defp assignment_state_tone("deleted"), do: :error
  defp assignment_state_tone("disabled"), do: :error
  defp assignment_state_tone(_status), do: :warning

  defp assignment_health_tone("active"), do: :success
  defp assignment_health_tone("degraded"), do: :warning
  defp assignment_health_tone("errored"), do: :error
  defp assignment_health_tone(_status), do: :warning

  defp quota_priming_ready?(status), do: status in ["known", "weekly_only_probe"]

  defp quota_priming_tone(status) when status in ["known", "weekly_only_probe"], do: :success
  defp quota_priming_tone(status) when status in ["failed", "blocked", "expired"], do: :error
  defp quota_priming_tone(_status), do: :warning

  defp human_status_label(value) when is_binary(value) and value != "" do
    value
    |> String.replace("_", " ")
    |> String.downcase()
  end

  defp human_status_label(_value), do: "unknown"

  defp recent_token_count_label(%{token_burn: %{recent_tokens: tokens}})
       when is_integer(tokens) and tokens >= 0 do
    "#{Format.token_count(tokens)} tokens"
  end

  defp recent_token_count_label(_account), do: "0 tokens"

  @spec recovery_eligible?(map()) :: boolean()
  defp recovery_eligible?(%{identity: %{status: status}} = account) do
    status in @recovery_statuses and status != "deleted" and not auth_clearly_usable?(account)
  end

  defp recovery_eligible?(_account), do: false

  @spec auth_clearly_usable?(map()) :: boolean()
  defp auth_clearly_usable?(%{
         reauth_required?: false,
         refresh_status: refresh_status,
         access_token_label: access_token_label
       }) do
    refresh_status in @usable_refresh_statuses and
      not expired_access_token_label?(access_token_label)
  end

  defp auth_clearly_usable?(_account), do: false

  @spec expired_access_token_label?(term()) :: boolean()
  defp expired_access_token_label?(label) when is_binary(label),
    do: String.starts_with?(label, "access token expired")

  defp expired_access_token_label?(_label), do: false

  @spec recovery_default_pool_id(map()) :: String.t() | nil
  defp recovery_default_pool_id(%{assignments: [assignment | _assignments]}),
    do: assignment.pool_id

  defp recovery_default_pool_id(_account), do: nil

  @spec recovery_reinvite_path(map()) :: String.t() | nil
  defp recovery_reinvite_path(%{assignments: [assignment | _assignments]} = account) do
    params = recovery_invite_params(account, assignment.pool_id)
    ~p"/admin/invites?#{params}"
  end

  defp recovery_reinvite_path(_account), do: nil

  @spec oauth_relink_available?(map()) :: boolean()
  defp oauth_relink_available?(%{identity: %{status: status}, assignments: assignments})
       when is_list(assignments),
       do: status != "deleted" and assignments != []

  defp oauth_relink_available?(_account), do: false

  @spec oauth_relink_unavailable_reason(map()) :: String.t() | nil
  defp oauth_relink_unavailable_reason(%{identity: %{status: "deleted"}}),
    do: "Deleted accounts cannot be relinked."

  defp oauth_relink_unavailable_reason(%{assignments: []}),
    do: "Assign this account to a visible Pool before relinking."

  defp oauth_relink_unavailable_reason(_account), do: nil

  @spec recovery_invite_params(map(), String.t()) :: map()
  defp recovery_invite_params(account, pool_id) do
    params = %{"create" => "1", "pool_id" => pool_id}

    case recovery_invite_email(account, pool_id) do
      nil -> params
      invited_email -> Map.put(params, "invited_email", invited_email)
    end
  end

  @spec recovery_invite_email(map(), String.t()) :: String.t() | nil
  defp recovery_invite_email(account, pool_id) do
    [
      account.identity.account_email,
      account.identity.chatgpt_account_id,
      account.label
    ]
    |> Enum.map(&present_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.find(&valid_invite_email?(&1, pool_id))
  end

  @spec valid_invite_email?(String.t(), String.t()) :: boolean()
  defp valid_invite_email?(candidate, pool_id) do
    %{"pool_id" => pool_id, "invited_email" => candidate, "send_email" => "false"}
    |> PoolInviteForm.changeset(%{id: pool_id})
    |> Map.fetch!(:valid?)
  end

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp pausable?("active"), do: true
  defp pausable?("refresh_due"), do: true
  defp pausable?("refresh_failed"), do: true
  defp pausable?(_status), do: false

  defp reactivatable?(status), do: status in @reactivatable_statuses

  defp refreshable?(status), do: status in ["active", "refresh_due", "refresh_failed"]
end
