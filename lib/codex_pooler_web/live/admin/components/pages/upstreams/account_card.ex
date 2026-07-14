defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.Upstreams.SavedResets
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.Format

  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.{
    QuotaLimitRow,
    SavedResetMeter,
    SelectorContracts,
    TokenBurnPopover
  }

  alias CodexPoolerWeb.Admin.UpstreamPageComponents.{ReconciliationStatus, ReinviteLink}
  alias CodexPoolerWeb.DateTimeDisplay

  @reactivatable_statuses ~w(paused refresh_due refresh_failed)
  @recovery_statuses ~w(paused refresh_due refresh_failed reauth_required)
  @usable_refresh_statuses ~w(succeeded imported refreshing)

  attr :account, :map, required: true
  attr :account_index, :integer, required: true
  attr :panel_view, :atom, default: :usage, values: [:usage, :routing, :pools]

  attr :datetime_preferences, :map, default: nil

  def account_card(assigns) do
    datetime_preferences =
      Map.get(assigns, :datetime_preferences) || DateTimeDisplay.preferences_for_user(nil)

    saved_resets = saved_resets(assigns.account)
    saved_reset_policy = saved_reset_policy(assigns.account)
    routing_readiness = routing_readiness(assigns.account)
    lifecycle_warning = lifecycle_blocker_warning(assigns.account, routing_readiness)

    assigns =
      assigns
      |> assign(:datetime_preferences, datetime_preferences)
      |> assign(:reported_quota_limits, reported_quota_limits(assigns.account.quota_limits))
      |> assign(:workspace_context_label, workspace_context_label(assigns.account))
      |> assign(:workspace_context_title, workspace_context_title(assigns.account))
      |> assign(:auth_expiration, auth_expiration(assigns.account, datetime_preferences))
      |> assign(:routing_readiness, routing_readiness)
      |> assign(:lifecycle_warning, lifecycle_warning)
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
        "min-w-0 rounded-box border border-l border-base-300 bg-base-100 transition-colors",
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
          </div>
          <p
            id={"upstream-account-#{@account.identity.id}-auth-expiration"}
            data-role="upstream-auth-expiration"
            class="mt-1 truncate text-xs leading-5 text-base-content/55"
            title={@auth_expiration.title}
          >
            {@auth_expiration.label}
          </p>
        </div>
        <div
          id={"upstream-account-#{@account.identity.id}-header-actions"}
          class="flex shrink-0 items-center gap-2 self-center"
        >
          <SavedResetMeter.saved_reset_count_badge
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
                <TokenBurnPopover.token_burn_popover
                  id={"upstream-account-#{@account.identity.id}-token-burn-value"}
                  content_id={"upstream-account-#{@account.identity.id}-token-burn-content"}
                  token_burn={@account.token_burn}
                />
              </div>
            </div>
            <div
              id={"upstream-account-#{@account.identity.id}-limits"}
              class={quota_limits_grid_class(@reported_quota_limits)}
            >
              <QuotaLimitRow.quota_limit_row
                :for={limit <- @reported_quota_limits}
                id={"upstream-account-#{@account.identity.id}-limit-#{limit.key}"}
                limit={limit}
              />
              <SavedResetMeter.saved_reset_meter
                :if={saved_reset_panel_available?(@saved_resets)}
                id={"upstream-account-#{@account.identity.id}-saved-reset-meter"}
                saved_resets={@saved_resets}
                saved_reset_policy={@saved_reset_policy}
                class={saved_reset_meter_grid_class(@reported_quota_limits)}
              />
            </div>
          </section>

          <section
            :if={routing_panel_available?(@account)}
            id={"upstream-account-#{@account.identity.id}-routing-panel"}
            data-role="upstream-account-routing-panel"
            aria-hidden={aria_bool(@panel_view != :routing)}
            inert={@panel_view != :routing}
            class={account_panel_class(@panel_view == :routing)}
          >
            <div class="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-3">
              <div class="min-w-0">
                <p class="text-xs font-semibold uppercase text-primary">Routing</p>
                <p
                  id={"upstream-account-#{@account.identity.id}-routing-summary"}
                  class="truncate text-xs text-base-content/60"
                >
                  {routing_panel_summary(@account.assignments)}
                </p>
              </div>
              <div class="min-w-0 text-right">
                <p class="text-xs font-semibold uppercase text-primary">Readiness</p>
                <p
                  id={"upstream-account-#{@account.identity.id}-routing-readiness-summary"}
                  class="truncate text-xs text-base-content/60"
                  title={@routing_readiness.reason}
                >
                  {@routing_readiness.label}
                </p>
              </div>
            </div>

            <div
              id={"upstream-account-#{@account.identity.id}-routing-models"}
              data-role="upstream-account-routing-models"
              class="grid content-start gap-0.5 overflow-y-auto pr-1"
            >
              <p
                :if={routing_model_rows(@account.assignments) == []}
                data-role="upstream-account-routing-empty"
                class="text-xs text-base-content/60"
              >
                No models advertised for this account.
              </p>

              <div
                :for={row <- routing_model_rows(@account.assignments)}
                id={"upstream-account-#{@account.identity.id}-routing-model-#{row.dom_id}"}
                data-role="upstream-account-routing-model"
                class="flex min-w-0 items-center justify-between gap-3 rounded px-2 py-1.5 text-xs odd:bg-base-200/40"
              >
                <span
                  data-role="upstream-account-routing-model-id"
                  class="min-w-0 truncate font-medium text-base-content"
                  title={row.exposed_model_id}
                >
                  {row.exposed_model_id}
                </span>
                <span class="flex shrink-0 flex-wrap items-center justify-end gap-1">
                  <span
                    :for={alert <- row.alerts}
                    data-role="upstream-account-routing-serving-signal"
                    class={routing_signal_class(alert.serving_state)}
                    title={"#{routing_route_class_label(alert.route_class)} transport: #{routing_signal_label(alert.serving_state)}"}
                  >
                    {routing_route_class_label(alert.route_class)}: {routing_signal_label(
                      alert.serving_state
                    )}
                  </span>
                  <span
                    :if={row.preserved?}
                    data-role="upstream-account-routing-model-provenance"
                    class="rounded bg-warning/10 px-1.5 py-0.5 text-[0.65rem] text-warning"
                    title="Kept from an earlier catalog sync; not observed in the latest discovery"
                  >
                    preserved
                  </span>
                  <span
                    :if={row.pool_scoped?}
                    data-role="upstream-account-routing-model-pools"
                    class="rounded bg-base-200 px-1.5 py-0.5 text-[0.65rem] text-base-content/60"
                    title={"Advertised only in: " <> Enum.join(row.pool_labels, ", ")}
                  >
                    {routing_pool_scope_label(row.pool_labels)}
                  </span>
                </span>
              </div>
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

        <ReconciliationStatus.reconciliation_status
          id_prefix={"upstream-account-#{@account.identity.id}"}
          identity_observability={@account.identity_observability}
          reauth_required?={@account.reauth_required?}
          lifecycle_warning={@lifecycle_warning}
          recovery_href={~p"/admin/upstreams/#{@account.identity.id}"}
          recovery_label="Open recovery actions"
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
          <div class="group relative isolate min-w-0 pr-3" data-role="upstream-routing-cell">
            <dt class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/35 transition-colors group-hover:text-primary/70">
              <button
                :if={routing_panel_available?(@account)}
                id={"upstream-account-#{@account.identity.id}-routing-panel-trigger"}
                type="button"
                class={footer_panel_trigger_class(@panel_view == :routing, :first)}
                phx-click="toggle_account_routing_panel"
                phx-value-id={@account.identity.id}
                aria-controls={"upstream-account-#{@account.identity.id}-routing-panel"}
                aria-expanded={aria_bool(@panel_view == :routing)}
                aria-label={routing_panel_trigger_label(@panel_view, @account.assignments)}
              >
                <span class="sr-only">Routing</span>
              </button>
              <span class="pointer-events-none relative z-30 block max-w-full truncate text-left uppercase">
                Routing
              </span>
            </dt>
            <dd
              class="pointer-events-none relative z-30 truncate text-base-content/60 transition-colors group-hover:text-base-content/75"
              title={@routing_readiness.reason}
            >
              {@routing_readiness.label}
            </dd>
          </div>
          <div class="group relative isolate min-w-0 pl-3" data-role="upstream-pool-count-cell">
            <dt class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/35 transition-colors group-hover:text-primary/70">
              <button
                id={"upstream-account-#{@account.identity.id}-pools-panel-trigger"}
                type="button"
                class={footer_panel_trigger_class(@panel_view == :pools, :middle)}
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
      <SelectorContracts.refresh_status account={@account} />
      <SelectorContracts.selector_contracts account={@account} routing_readiness={@routing_readiness} />
    </article>
    """
  end

  defp saved_resets(%{saved_resets: saved_resets}), do: saved_resets
  defp saved_resets(%{identity: identity}), do: SavedResets.snapshot(identity)
  defp saved_resets(_account), do: SavedResets.snapshot(nil)

  defp saved_reset_policy(%{saved_reset_policy: saved_reset_policy}), do: saved_reset_policy
  defp saved_reset_policy(%{identity: identity}), do: SavedResets.auto_policy(identity)

  @type auth_expiration :: %{label: String.t(), title: String.t() | nil}

  @spec auth_expiration(map(), DateTimeDisplay.preferences()) :: auth_expiration()
  defp auth_expiration(
         %{identity_observability: %{credential_expiry: credential_expiry}},
         preferences
       )
       when is_map(credential_expiry) do
    case credential_expiry do
      %{state: "known_future", expires_at: %DateTime{} = expires_at} ->
        %{
          label: "Auth expires #{credential_expiry_label(credential_expiry)}",
          title: DateTimeDisplay.format_datetime(expires_at, preferences)
        }

      %{state: "known_past", expires_at: %DateTime{} = expires_at} ->
        %{
          label: "Auth expired #{credential_expiry_label(credential_expiry)}",
          title: DateTimeDisplay.format_datetime(expires_at, preferences)
        }

      _unavailable ->
        %{label: "Expiration unavailable", title: nil}
    end
  end

  defp auth_expiration(_account, _preferences), do: %{label: "Expiration unavailable", title: nil}

  @spec credential_expiry_label(map()) :: String.t()
  defp credential_expiry_label(%{age: age}) when is_binary(age) and age != "", do: age
  defp credential_expiry_label(_credential_expiry), do: "at an unknown time"

  defp normalize_panel_view(panel_view, _saved_resets, account)
       when panel_view in [:routing, :pools] do
    if pools_panel_available?(account), do: panel_view, else: :usage
  end

  defp normalize_panel_view(_panel_view, _saved_resets, _account), do: :usage

  defp saved_reset_panel_available?(%{reported?: true, available_count: count})
       when is_integer(count) and count > 0,
       do: true

  defp saved_reset_panel_available?(_saved_resets), do: false

  defp pools_panel_available?(%{assignments: assignments}) when is_list(assignments),
    do: assignments != []

  defp pools_panel_available?(_account), do: false

  defp routing_panel_available?(account), do: pools_panel_available?(account)

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
        recovery_reinvite_path: ReinviteLink.path_for_account(assigns.account),
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
            id={"assign-pool-upstream-account-#{@account.identity.id}"}
            icon="hero-server-stack"
            label="Assign to Pool"
            phx-click="open_assign_pool"
            phx-value-id={@account.identity.id}
            disabled={@account.identity.status == "deleted"}
          />
        </li>
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
            phx-click="open_delete_account"
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

  defp pool_assignment_summary_label([_assignment]), do: "1 routing lane"
  defp pool_assignment_summary_label(assignments), do: "#{length(assignments)} routing lanes"

  defp routing_panel_summary(assignments) do
    model_count = assignments |> routing_model_rows() |> length()
    "#{routing_model_count_label(model_count)}, #{assignment_count_label(assignments)}"
  end

  # One row per distinct exposed model across every routing lane: model names
  # are the payload, everything else appears only when it says something — a
  # non-nominal serving signal, preserved provenance, or a model advertised in
  # only some of the account's Pools. Nominal state renders nothing.
  defp routing_model_rows(assignments) when is_list(assignments) do
    pool_count = assignments |> Enum.map(& &1.pool_label) |> Enum.uniq() |> length()

    assignments
    |> Enum.flat_map(fn assignment ->
      Enum.map(routing_models(assignment), &{assignment, &1})
    end)
    |> Enum.group_by(fn {_assignment, model} -> model.exposed_model_id end)
    |> Enum.map(fn {model_id, entries} ->
      pool_labels =
        entries
        |> Enum.map(fn {assignment, _model} -> assignment.pool_label end)
        |> Enum.uniq()
        |> Enum.sort()

      %{
        exposed_model_id: model_id,
        dom_id: routing_model_dom_id(model_id),
        pool_labels: pool_labels,
        pool_scoped?: pool_count > 1 and length(pool_labels) < pool_count,
        preserved?:
          Enum.any?(entries, fn {_assignment, model} -> model.provenance == :preserved end),
        alerts: routing_model_alerts(entries)
      }
    end)
    |> Enum.sort_by(& &1.exposed_model_id)
  end

  defp routing_model_rows(_assignments), do: []

  defp routing_model_alerts(entries) do
    entries
    |> Enum.flat_map(fn {_assignment, model} -> model.serving_signals end)
    |> Enum.reject(&(&1.serving_state in [:available_observed, :unverified]))
    |> Enum.uniq_by(&{&1.route_class, &1.serving_state})
    |> Enum.sort_by(&{&1.route_class, &1.serving_state})
  end

  defp routing_model_dom_id(model_id),
    do: model_id |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.slice(0, 80)

  defp routing_pool_scope_label([pool_label]), do: "#{pool_label} only"
  defp routing_pool_scope_label(pool_labels), do: "#{length(pool_labels)} of the Pools"

  defp routing_models(%{models: models}) when is_list(models), do: models
  defp routing_models(_assignment), do: []

  defp routing_model_count_label(1), do: "1 model"

  defp routing_model_count_label(count) when is_integer(count) and count >= 0,
    do: "#{count} models"

  defp routing_panel_trigger_label(:routing, _assignments), do: "Show quota status"

  defp routing_panel_trigger_label(_panel_view, assignments),
    do: "Show routing models: #{routing_panel_summary(assignments)}"

  defp pools_panel_trigger_label(:pools, _assignments), do: "Show quota status"

  defp pools_panel_trigger_label(_panel_view, assignments),
    do: "Show Pool assignments: #{assignment_count_label(assignments)}"

  defp footer_panel_trigger_class(active?, position) do
    [
      footer_panel_trigger_base_class(),
      footer_panel_trigger_position_class(position),
      if(active?,
        do: "border-primary/35 bg-primary/5",
        else: "border-transparent hover:border-primary/25 hover:bg-primary/5"
      )
    ]
  end

  # The overlay must read as the footer cell block: an even ~4px breathing gap
  # against the footer edges and the column dividers on every side. The cells
  # carry asymmetric divider padding (pr-3 on the first, pl-3 on the middle),
  # so each position needs its own horizontal insets to end up symmetric.
  defp footer_panel_trigger_base_class do
    "absolute -inset-y-1.5 z-20 cursor-pointer rounded border transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
  end

  defp footer_panel_trigger_position_class(:first), do: "-left-3 right-1"
  defp footer_panel_trigger_position_class(:middle), do: "left-1 right-1"

  defp routing_route_class_label("proxy_http"), do: "HTTP"
  defp routing_route_class_label("proxy_stream"), do: "SSE"
  defp routing_route_class_label("proxy_websocket"), do: "Websocket"
  defp routing_route_class_label(_route_class), do: "Route"

  defp routing_signal_label(:available_observed), do: "Available observed"
  defp routing_signal_label(:serving_rejection_observed), do: "Serving rejection observed"
  defp routing_signal_label(:temporarily_unavailable), do: "Temporarily avoided"
  defp routing_signal_label(:probe_in_progress), do: "Probe in progress"
  defp routing_signal_label(:probe_due), do: "Probe due"
  defp routing_signal_label(_state), do: "Unverified"

  defp routing_signal_class(:serving_rejection_observed),
    do: "rounded border border-warning/35 bg-warning/10 px-1.5 py-0.5 text-[0.65rem] text-warning"

  defp routing_signal_class(:temporarily_unavailable),
    do: "rounded border border-error/35 bg-error/10 px-1.5 py-0.5 text-[0.65rem] text-error"

  defp routing_signal_class(:probe_in_progress),
    do: "rounded border border-info/35 bg-info/10 px-1.5 py-0.5 text-[0.65rem] text-info"

  defp routing_signal_class(:probe_due),
    do: "rounded border border-warning/35 bg-warning/10 px-1.5 py-0.5 text-[0.65rem] text-warning"

  defp routing_signal_class(:available_observed),
    do: "rounded border border-success/35 bg-success/10 px-1.5 py-0.5 text-[0.65rem] text-success"

  defp routing_signal_class(_state),
    do:
      "rounded border border-base-300 bg-base-200 px-1.5 py-0.5 text-[0.65rem] text-base-content/60"

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
         %{identity: %{id: id, status: "refresh_failed"}} = account,
         _routing_readiness
       ) do
    %{
      id: "upstream-account-#{id}-refresh-failed-warning",
      title: "Token refresh failed",
      body:
        "This account is excluded from runtime routing until token refresh succeeds or credentials are relinked.",
      reason: lifecycle_reason(account)
    }
  end

  defp lifecycle_blocker_warning(
         %{identity: %{id: id, status: "reauth_required"}} = account,
         _routing_readiness
       ) do
    %{
      id: "upstream-account-#{id}-reauth-warning",
      title: "Reauthentication required",
      body: "This account is excluded from routing until credentials are replaced.",
      reason: lifecycle_reason(account)
    }
  end

  defp lifecycle_blocker_warning(_account, _routing_readiness), do: nil

  @spec lifecycle_reason(map()) :: String.t() | nil
  defp lifecycle_reason(%{reauth_reason_message: message, reauth_reason_code: code})
       when is_binary(message) and message != "" do
    "#{code || "token refresh failed"} - #{message}"
  end

  defp lifecycle_reason(%{reauth_reason_code: code}) when is_binary(code) and code != "", do: code
  defp lifecycle_reason(_account), do: nil

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
    Enum.filter(quota_limits, &reported_quota_limit?/1)
  end

  defp reported_quota_limits(_quota_limits), do: []

  defp reported_quota_limit?(%{percent: %Decimal{}}), do: true

  defp reported_quota_limit?(%{reset_label: reset_label}) when is_binary(reset_label),
    do: true

  defp reported_quota_limit?(%{count_label: count_label}) when is_binary(count_label),
    do: true

  defp reported_quota_limit?(_limit), do: false

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

  defp pausable?("active"), do: true
  defp pausable?("refresh_due"), do: true
  defp pausable?("refresh_failed"), do: true
  defp pausable?(_status), do: false

  defp reactivatable?(status), do: status in @reactivatable_statuses

  defp refreshable?(status), do: status in ["active", "refresh_due", "refresh_failed"]
end
