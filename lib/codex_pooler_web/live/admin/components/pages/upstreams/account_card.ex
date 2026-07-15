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
  attr :panel_view, :atom, default: :usage, values: [:usage, :tokens, :pools]

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
      |> assign(:token_leaderboard, token_leaderboard(assigns.account))
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
            class="truncate text-xs leading-4 text-base-content/55"
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
            id={"upstream-account-#{@account.identity.id}-tokens-panel"}
            data-role="upstream-account-tokens-panel"
            aria-hidden={aria_bool(@panel_view != :tokens)}
            inert={@panel_view != :tokens}
            class={account_panel_class(@panel_view == :tokens)}
          >
            <div class="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-3">
              <div class="min-w-0">
                <p class="text-xs font-semibold uppercase text-primary">
                  tokens/<span class="normal-case">5m</span>
                </p>
                <p
                  id={"upstream-account-#{@account.identity.id}-tokens-summary"}
                  class="truncate text-xs text-base-content/60"
                >
                  {tokens_panel_summary(@account, @token_leaderboard)}
                </p>
              </div>
              <div class="min-w-0 text-right">
                <p class="text-xs font-semibold uppercase text-primary">Requests</p>
                <p
                  id={"upstream-account-#{@account.identity.id}-tokens-requests-summary"}
                  class="truncate text-xs text-base-content/60"
                  title="Settled requests in the last 5 minutes"
                >
                  {recent_request_count_label(@account)}
                </p>
              </div>
            </div>

            <div
              id={"upstream-account-#{@account.identity.id}-token-models"}
              data-role="upstream-account-token-models"
              class="grid content-start gap-0.5 overflow-y-auto pr-1"
            >
              <p
                :if={@token_leaderboard == []}
                data-role="upstream-account-token-models-empty"
                class="text-xs text-base-content/60"
              >
                No models advertised or used in the last 5 minutes.
              </p>

              <div
                :for={row <- @token_leaderboard}
                id={"upstream-account-#{@account.identity.id}-token-model-#{row.dom_id}"}
                data-role="upstream-account-token-model"
                class="grid min-w-0 grid-cols-[minmax(0,1fr)_4rem_3.5rem_3.5rem] items-center gap-3 rounded px-2 py-1.5 text-xs odd:bg-base-200/40"
              >
                <span
                  data-role="upstream-account-token-model-id"
                  class="min-w-0 truncate font-medium text-base-content"
                  title={row.label}
                >
                  {row.label}
                </span>
                <span class="h-1 overflow-hidden rounded-full bg-base-300/60" aria-hidden="true">
                  <span
                    class="block h-full rounded-full bg-primary/70"
                    style={"width: #{row.share_percent}%"}
                  ></span>
                </span>
                <span
                  data-role="upstream-account-token-model-tokens"
                  class={[
                    "justify-self-end tabular-nums",
                    if(row.tokens == 0, do: "text-base-content/45", else: "text-base-content/75")
                  ]}
                >
                  {Format.token_count(row.tokens)}
                </span>
                <span
                  data-role="upstream-account-token-model-cost"
                  class={[
                    "justify-self-end tabular-nums",
                    if(row.cost_micros == 0,
                      do: "text-base-content/40",
                      else: "text-base-content/60"
                    )
                  ]}
                >
                  {Format.money_from_micros(row.cost_micros)}
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
          <div class="group relative isolate min-w-0 pl-3" data-role="upstream-token-status-cell">
            <dt class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/35 transition-colors group-hover:text-primary/70">
              <button
                id={"upstream-account-#{@account.identity.id}-tokens-panel-trigger"}
                type="button"
                class={footer_panel_trigger_class(@panel_view == :tokens, :last)}
                phx-click="toggle_account_tokens_panel"
                phx-value-id={@account.identity.id}
                aria-controls={"upstream-account-#{@account.identity.id}-tokens-panel"}
                aria-expanded={aria_bool(@panel_view == :tokens)}
                aria-label={tokens_panel_trigger_label(@panel_view)}
              >
                <span class="sr-only">Tokens/5m</span>
              </button>
              <span class="pointer-events-none relative z-30 block max-w-full truncate text-left uppercase">
                tokens/<span class="normal-case">5m</span>
              </span>
            </dt>
            <dd class="pointer-events-none relative z-30 truncate text-base-content/60 transition-colors group-hover:text-base-content/75">
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

  defp normalize_panel_view(:tokens, _saved_resets, _account), do: :tokens

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
            id={"reconcile-upstream-account-#{@account.identity.id}"}
            icon="hero-arrow-path"
            label="Refresh quota"
            phx-click="reconcile_account"
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

  defp tokens_panel_summary(account, leaderboard) do
    tokens = recent_token_count_label(account)
    "#{tokens}, #{model_count_label(length(leaderboard))}"
  end

  # A leaderboard of the account's models over the trailing five minutes: one
  # row per distinct exposed model advertised by any routing lane or settled in
  # the window, ranked by settled tokens. Bars are relative to the leader.
  defp token_leaderboard(account) do
    usage_by_label =
      account
      |> recent_model_usage()
      |> Map.new(&{&1.label, &1})

    rows =
      account
      |> advertised_model_labels()
      |> MapSet.new()
      |> MapSet.union(usage_by_label |> Map.keys() |> MapSet.new())
      |> Enum.map(fn label ->
        usage = Map.get(usage_by_label, label, %{tokens: 0, cost_micros: 0})
        %{label: label, tokens: usage.tokens, cost_micros: usage.cost_micros}
      end)

    leader_tokens = rows |> Enum.map(& &1.tokens) |> Enum.max(fn -> 0 end)

    rows
    |> Enum.sort_by(&{-&1.tokens, &1.label})
    |> Enum.map(fn row ->
      Map.merge(row, %{
        dom_id: model_dom_id(row.label),
        share_percent: share_percent(row.tokens, leader_tokens)
      })
    end)
  end

  defp recent_model_usage(%{token_burn: %{recent_models: recent_models}})
       when is_list(recent_models),
       do: recent_models

  defp recent_model_usage(_account), do: []

  defp advertised_model_labels(%{assignments: assignments}) when is_list(assignments) do
    assignments
    |> Enum.flat_map(&assignment_models/1)
    |> Enum.map(& &1.exposed_model_id)
    |> Enum.uniq()
  end

  defp advertised_model_labels(_account), do: []

  defp assignment_models(%{models: models}) when is_list(models), do: models
  defp assignment_models(_assignment), do: []

  defp share_percent(_tokens, 0), do: 0
  defp share_percent(tokens, leader_tokens), do: round(tokens / leader_tokens * 100)

  defp model_dom_id(model_id),
    do: model_id |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.slice(0, 80)

  defp model_count_label(1), do: "1 model"

  defp model_count_label(count) when is_integer(count) and count >= 0,
    do: "#{count} models"

  defp tokens_panel_trigger_label(:tokens), do: "Show quota status"
  defp tokens_panel_trigger_label(_panel_view), do: "Show model usage for the last 5 minutes"

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
  # carry asymmetric divider padding (pl-3 on the middle and last), so each
  # position needs its own horizontal insets to end up symmetric.
  defp footer_panel_trigger_base_class do
    "absolute -inset-y-1.5 z-20 cursor-pointer rounded border transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
  end

  defp footer_panel_trigger_position_class(:middle), do: "left-1 right-1"
  defp footer_panel_trigger_position_class(:last), do: "left-1 -right-3"

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

  defp recent_request_count_label(%{token_burn: %{recent_requests: requests}})
       when is_integer(requests) and requests >= 0 do
    Format.integer(requests)
  end

  defp recent_request_count_label(_account), do: "0"

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
