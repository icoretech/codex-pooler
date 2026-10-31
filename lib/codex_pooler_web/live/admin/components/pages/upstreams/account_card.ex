defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.Catalog.ModelInfo
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.Format
  alias CodexPoolerWeb.Admin.UpstreamAccountActions
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetProjection
  alias CodexPoolerWeb.Admin.UpstreamCockpitComponents.Formatting, as: CockpitFormatting

  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.{
    QuotaLimitRow,
    SavedResetMeter,
    SelectorContracts,
    TokenBurnPopover
  }

  alias CodexPoolerWeb.Admin.UpstreamPageComponents.{
    DeletionNotice,
    ProviderCreditsComponents,
    ReconciliationStatus,
    ReinviteLink,
    RoutePath,
    SavedResetOperation,
    UsagePollPause
  }

  alias CodexPoolerWeb.DateTimeDisplay

  @reactivatable_statuses ~w(paused refresh_due refresh_failed)
  @recovery_statuses ~w(paused refresh_due refresh_failed reauth_required)
  attr :account, :map, required: true
  attr :account_index, :integer, required: true
  attr :panel_view, :atom, default: :usage, values: [:usage, :tokens, :pools]
  attr :can_manage_pools?, :boolean, default: false
  attr :pool_editor_query_params, :map, default: %{}

  attr :datetime_preferences, :map, default: nil

  @spec account_card(map()) :: Phoenix.LiveView.Rendered.t()
  def account_card(assigns) do
    datetime_preferences =
      Map.get(assigns, :datetime_preferences) || DateTimeDisplay.preferences_for_user(nil)

    saved_resets = saved_resets(assigns.account)
    saved_reset_policy = saved_reset_policy(assigns.account)
    saved_reset_confirmation = Map.get(assigns.account, :saved_reset_confirmation)
    routing_readiness = routing_readiness(assigns.account)
    lifecycle_warning = lifecycle_blocker_warning(assigns.account, routing_readiness)

    assigns =
      assigns
      |> assign(:datetime_preferences, datetime_preferences)
      |> assign(:deleting?, Map.get(assigns.account, :deletion_state) == :in_progress)
      |> assign(:reported_quota_limits, reported_quota_limits(assigns.account.quota_limits))
      |> assign(:workspace_context_label, workspace_context_label(assigns.account))
      |> assign(:workspace_context_title, workspace_context_title(assigns.account))
      |> assign(:auth_expiration, auth_expiration(assigns.account, datetime_preferences))
      |> assign(:routing_readiness, routing_readiness)
      |> assign(:lifecycle_warning, lifecycle_warning)
      |> assign(:saved_resets, saved_resets)
      |> assign(:saved_reset_policy, saved_reset_policy)
      |> assign(:saved_reset_confirmation, saved_reset_confirmation)
      |> assign(:token_leaderboard, token_leaderboard(assigns.account))
      |> assign(
        :panel_view,
        normalize_panel_view(assigns.panel_view, saved_resets, assigns.account)
      )

    ~H"""
    <article
      id={"upstream-account-#{@account.identity.id}"}
      data-role="upstream-account-card"
      data-deletion-state={Map.get(@account, :deletion_state, :none)}
      data-routing-state={@routing_readiness.state}
      data-routing-tone={@routing_readiness.tone}
      data-routing-ready-now={to_string(@routing_readiness.routing_ready_now?)}
      class={[
        "upstream-account-card min-w-0 rounded-box border border-base-300 bg-base-100 transition-colors",
        @deleting? && "grid isolate",
        token_burn_active?(@account) && "admin-token-burn-active"
      ]}
      style={quota_shine_style(@account, @account_index)}
    >
      <div
        data-role="upstream-account-card-content"
        inert={@deleting?}
        aria-busy={to_string(@deleting?)}
        class={@deleting? && "pointer-events-none col-start-1 row-start-1 min-w-0 opacity-35"}
      >
        <header
          data-role="upstream-account-card-header"
          class="flex items-center justify-between gap-2 border-b border-base-300 bg-base-200/35 px-4 py-3"
        >
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-2">
              <h3 class="min-w-0 max-w-full text-base font-semibold leading-5 text-base-content">
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
                class={[
                  AdminBadges.metadata_chip_class(:neutral),
                  "!px-2 !py-0.5 !text-[10px] shrink-0 max-w-48 truncate"
                ]}
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
            <.upstream_plan_indicator account={@account} account_index={@account_index} />
            <.upstream_account_actions account={@account} />
          </div>
        </header>

        <div class="grid gap-4 p-4">
          <div
            id={"upstream-account-#{@account.identity.id}-panel-switcher"}
            data-role="upstream-account-panel-switcher"
            data-panel-view={@panel_view}
            class="grid min-w-0"
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
                  <p class="text-xs font-semibold uppercase text-primary">{gettext("Status")}</p>
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
                  data-usage-state={token_burn_usage_state(@account)}
                  class="text-right"
                >
                  <p
                    id={"upstream-account-#{@account.identity.id}-token-burn-label"}
                    class="text-xs font-semibold uppercase text-primary"
                  >
                    {gettext("TOKEN BURN")}
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
                data-role="upstream-account-quota-limits"
                class={quota_limits_grid_class(@reported_quota_limits)}
              >
                <QuotaLimitRow.quota_limit_row
                  :for={limit <- @reported_quota_limits}
                  id={"upstream-account-#{@account.identity.id}-limit-#{limit.key}"}
                  account_label={@account.label}
                  limit={limit}
                />
                <ProviderCreditsComponents.provider_credits_summary
                  :if={Map.has_key?(@account, :provider_credits_summary)}
                  id={"upstream-account-#{@account.identity.id}-provider-credits"}
                  summary={@account.provider_credits_summary}
                  open_policy={if @account.can_manage_provider_credits? and @account.identity.status != "deleted", do: JS.push_focus() |> JS.push("open_provider_credits_policy", value: %{id: @account.identity.id})}
                />
                <SavedResetMeter.saved_reset_meter
                  :if={@account.identity.status != "deleted" and saved_reset_panel_available?(@saved_resets, @saved_reset_confirmation)}
                  id={"upstream-account-#{@account.identity.id}-saved-reset-meter"}
                  identity_id={@account.identity.id}
                  saved_resets={@saved_resets}
                  saved_reset_policy={@saved_reset_policy}
                  class={saved_reset_meter_grid_class(@reported_quota_limits)}
                />
              </div>
              <AdminComponents.saved_reset_operation
                :if={Map.has_key?(@account, :saved_reset_operation) && SavedResetOperation.list_visible?(@account.saved_reset_operation)}
                identity_id={@account.identity.id}
                surface={:list}
                operation={@account.saved_reset_operation}
                refreshing={Map.get(@account, :saved_reset_status_refreshing?, false)}
                status_view_disabled={UpstreamAccountActions.assignment_unavailable_reason(@account.assignments) != nil or @account.identity.status == "deleted"}
              />
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
                    {gettext("tokens/5m")}
                  </p>
                  <p
                    id={"upstream-account-#{@account.identity.id}-tokens-summary"}
                    class="truncate text-xs text-base-content/60"
                  >
                    {tokens_panel_summary(@token_leaderboard)}
                  </p>
                </div>
                <div class="min-w-0 text-right">
                  <p class="text-xs font-semibold uppercase text-primary">{gettext("Requests")}</p>
                  <p
                    id={"upstream-account-#{@account.identity.id}-tokens-requests-summary"}
                    class="truncate text-xs text-base-content/60"
                    title={gettext("Settled requests in the last 5 minutes")}
                  >
                    {recent_request_count_label(@account)}
                  </p>
                </div>
              </div>

              <div
                id={"upstream-account-#{@account.identity.id}-token-models"}
                data-role="upstream-account-token-models"
                class="upstream-account-token-model-grid grid max-h-[24rem] content-start gap-0.5 overflow-y-auto pr-1"
              >
                <p
                  :if={@token_leaderboard == []}
                  data-role="upstream-account-token-models-empty"
                  class="text-xs text-base-content/60"
                >
                  {gettext("No models advertised or used in the last 5 minutes.")}
                </p>

                <div
                  :for={row <- @token_leaderboard}
                  id={"upstream-account-#{@account.identity.id}-token-model-#{row.dom_id}"}
                  data-role="upstream-account-token-model"
                  class="upstream-account-token-model-row grid min-w-0 items-center rounded px-2 py-1.5 text-xs odd:bg-base-200/40"
                >
                  <div
                    data-role="upstream-account-token-model-id"
                    class="min-w-0"
                    title={row.label}
                  >
                    <AdminComponents.model_info_popover
                      :if={ModelInfo.present?(row.model_info)}
                      id={
                      "upstream-account-#{@account.identity.id}-token-model-#{row.dom_id}-model-info"
                    }
                      model_id={row.label}
                      info={row.model_info}
                      trigger={:label}
                      class="w-full min-w-0"
                      trigger_class="block w-full"
                    />
                    <span
                      :if={!ModelInfo.present?(row.model_info)}
                      class="block min-w-0 truncate font-medium text-base-content"
                    >
                      {row.label}
                    </span>
                  </div>
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
                  <p class="text-xs font-semibold uppercase text-primary">{gettext("Pools")}</p>
                  <p
                    id={"upstream-account-#{@account.identity.id}-pools-summary"}
                    class="truncate text-xs text-base-content/60"
                  >
                    {pool_assignment_summary_label(@account.assignments)}
                  </p>
                </div>
                <div class="min-w-0 text-right">
                  <p class="text-xs font-semibold uppercase text-primary">{gettext("Routing")}</p>
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
                class="grid max-h-[24rem] gap-3 overflow-y-auto pr-1"
              >
                <.pool_assignment_block
                  :for={assignment <- @account.assignments}
                  account_id={@account.identity.id}
                  assignment={assignment}
                  can_manage_pools?={@can_manage_pools?}
                  query_params={@pool_editor_query_params}
                />
              </div>
            </section>
          </div>

          <ReconciliationStatus.reconciliation_status
            id_prefix={"upstream-account-#{@account.identity.id}"}
            identity_observability={@account.identity_observability}
            reauth_required?={@account.reauth_required?}
            lifecycle_warning={@lifecycle_warning}
          />

          <UsagePollPause.usage_poll_pause
            :if={@account.identity.status != "deleted"}
            id_prefix={"upstream-account-#{@account.identity.id}"}
            pause={Map.get(@account, :usage_poll_pause)}
          />
        </div>
        <AdminComponents.card_fact_strip
          id={"upstream-account-#{@account.identity.id}-routing-readiness"}
          data-role="upstream-account-card-footer"
          class="upstream-account-card-footer"
        >
          <:fact role="upstream-routing-cell">
            <AdminComponents.card_fact_label>{gettext("Routing")}</AdminComponents.card_fact_label>
            <AdminComponents.card_fact_value title={@routing_readiness.reason}>
              {@routing_readiness.label}
            </AdminComponents.card_fact_value>
          </:fact>
          <:fact role="upstream-pool-count-cell" interactive>
            <AdminComponents.card_fact_label
              tone_class={footer_panel_label_tone(@panel_view == :pools)}
              class="transition-colors"
            >
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
                <span class="sr-only">{gettext("Pools")}</span>
              </button>
              <span class="pointer-events-none relative z-30 block max-w-full truncate text-left">
                {gettext("Pools")}
              </span>
            </AdminComponents.card_fact_label>
            <AdminComponents.card_fact_value
              tone_class={
                if @account.assignments == [],
                  do: "text-warning",
                  else: footer_panel_value_tone(@panel_view == :pools)
              }
              class="pointer-events-none relative z-30 transition-colors"
            >
              {assignment_count_label(@account.assignments)}
            </AdminComponents.card_fact_value>
          </:fact>
          <:fact role="upstream-token-status-cell" interactive>
            <AdminComponents.card_fact_label
              tone_class={footer_panel_label_tone(@panel_view == :tokens)}
              class="transition-colors"
            >
              <button
                id={"upstream-account-#{@account.identity.id}-tokens-panel-trigger"}
                type="button"
                class={footer_panel_trigger_class(@panel_view == :tokens, :last)}
                phx-click="toggle_account_tokens_panel"
                phx-value-id={@account.identity.id}
                aria-controls={"upstream-account-#{@account.identity.id}-tokens-panel"}
                aria-describedby={"upstream-account-#{@account.identity.id}-tokens-5m-value"}
                aria-expanded={aria_bool(@panel_view == :tokens)}
                aria-label={tokens_panel_trigger_label(@panel_view)}
              >
                <span class="sr-only">{gettext("Tokens/5m")}</span>
              </button>
              <span class="pointer-events-none relative z-30 block max-w-full truncate text-left">
                {gettext("tokens/5m")}
              </span>
            </AdminComponents.card_fact_label>
            <AdminComponents.card_fact_value
              id={"upstream-account-#{@account.identity.id}-tokens-5m-value"}
              data-usage-state={token_burn_usage_state(@account)}
              tone_class={footer_panel_value_tone(@panel_view == :tokens)}
              class="pointer-events-none relative z-30 transition-colors"
              title={token_burn_title(@account)}
            >
              {recent_token_count_label(@account)}
            </AdminComponents.card_fact_value>
          </:fact>
        </AdminComponents.card_fact_strip>
        <SelectorContracts.refresh_status account={@account} />
        <SelectorContracts.selector_contracts account={@account} routing_readiness={@routing_readiness} />
      </div>
      <div :if={@deleting?} class="z-10 col-start-1 row-start-1 min-w-0 self-center p-4">
        <DeletionNotice.deletion_notice
          id={"upstream-account-#{@account.identity.id}-deletion-notice"}
          label={@account.label}
          paused={Map.get(@account, :deletion_updates_paused?, false)}
        />
      </div>
    </article>
    """
  end

  attr :account_id, :string, required: true
  attr :assignment, :map, required: true
  attr :can_manage_pools?, :boolean, required: true
  attr :query_params, :map, required: true

  defp pool_assignment_block(assigns) do
    assigns =
      assigns
      |> assign(
        :id,
        "upstream-account-#{assigns.account_id}-pool-assignment-#{assigns.assignment.id}"
      )
      |> assign(
        :editor_path,
        pool_editor_path(assigns.assignment.pool_id, assigns.query_params)
      )

    ~H"""
    <.link
      :if={@can_manage_pools?}
      id={@id}
      patch={@editor_path}
      data-role="upstream-account-pool-assignment"
      aria-label={gettext("Edit %{pool} upstream assignments", pool: @assignment.pool_label)}
      class="saved-reset-open-gloss relative grid min-w-0 gap-1.5 overflow-hidden rounded border border-transparent px-2 py-1.5 transition-colors hover:border-primary/25 hover:bg-primary/5 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
    >
      <.pool_assignment_content
        account_id={@account_id}
        assignment={@assignment}
      />
    </.link>
    <div
      :if={!@can_manage_pools?}
      id={@id}
      data-role="upstream-account-pool-assignment"
      class="grid min-w-0 gap-1.5 px-2 py-1.5"
    >
      <.pool_assignment_content
        account_id={@account_id}
        assignment={@assignment}
      />
    </div>
    """
  end

  attr :account_id, :string, required: true
  attr :assignment, :map, required: true

  defp pool_assignment_content(assigns) do
    ~H"""
    <div class="flex min-w-0 items-center justify-between gap-3 text-xs">
      <span
        data-role="upstream-account-pool-assignment-pool"
        class="min-w-0 truncate font-medium text-base-content"
        title={@assignment.pool_label}
      >
        {@assignment.pool_label}
      </span>
      <span
        data-role="upstream-account-pool-assignment-traffic"
        class="shrink-0 text-[11px] font-medium leading-4 tabular-nums text-base-content/60"
        title={assignment_traffic_title(@assignment)}
      >
        {assignment_traffic_label(@assignment)}
      </span>
    </div>
    <div
      id={"upstream-account-#{@account_id}-pool-assignment-#{@assignment.id}-route"}
      data-role="upstream-account-pool-route"
      role="meter"
      aria-valuemin="0"
      aria-valuemax={RoutePath.segment_count()}
      aria-valuenow={RoutePath.ready_count(@assignment)}
      aria-label={RoutePath.aria_label(@assignment)}
      aria-valuetext={RoutePath.aria_label(@assignment)}
      class="route-chevron-flow"
    >
      <span
        :for={segment <- RoutePath.segments(@assignment)}
        id={"upstream-account-#{@account_id}-pool-assignment-#{@assignment.id}-route-#{segment.key}"}
        data-role="upstream-account-pool-route-segment"
        title={segment.detail_label}
        class={RoutePath.segment_class(segment)}
      >
        {segment.short_label}
      </span>
    </div>
    """
  end

  defp pool_editor_path(pool_id, query_params) do
    params = Map.merge(query_params, %{"edit_pool_id" => pool_id, "step" => "upstreams"})
    ~p"/admin/upstreams?#{params}"
  end

  defp saved_resets(%{saved_resets: saved_resets}), do: saved_resets
  defp saved_resets(%{identity: identity}), do: SavedResetProjection.snapshot(identity, DateTimeDisplay.preferences_for_user(nil))
  defp saved_resets(_account), do: SavedResetProjection.snapshot(nil, DateTimeDisplay.preferences_for_user(nil))

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
          label: gettext("Access token expires %{age}", age: credential_expiry_label(credential_expiry)),
          title: DateTimeDisplay.format_datetime(expires_at, preferences)
        }

      %{state: "known_past", expires_at: %DateTime{} = expires_at} ->
        %{
          label: gettext("Access token expired %{age}", age: credential_expiry_label(credential_expiry)),
          title: DateTimeDisplay.format_datetime(expires_at, preferences)
        }

      _unavailable ->
        %{label: gettext("Access token expiry unavailable"), title: nil}
    end
  end

  defp auth_expiration(_account, _preferences),
    do: %{label: gettext("Access token expiry unavailable"), title: nil}

  @spec credential_expiry_label(map()) :: String.t()
  defp credential_expiry_label(%{age: age}) when is_binary(age) and age != "", do: age
  defp credential_expiry_label(_credential_expiry), do: gettext("at an unknown time")

  defp normalize_panel_view(:tokens, _saved_resets, _account), do: :tokens

  defp normalize_panel_view(:pools, _saved_resets, account) do
    if pools_panel_available?(account), do: :pools, else: :usage
  end

  defp normalize_panel_view(_panel_view, _saved_resets, _account), do: :usage

  defp saved_reset_panel_available?(_saved_resets, confirmation) when is_map(confirmation),
    do: true

  defp saved_reset_panel_available?(%{reported?: true, available_count: count}, _confirmation)
       when is_integer(count) and count > 0,
       do: true

  defp saved_reset_panel_available?(_saved_resets, _confirmation), do: false

  defp pools_panel_available?(%{assignments: assignments}) when is_list(assignments),
    do: assignments != []

  defp pools_panel_available?(_account), do: false

  defp account_panel_class(true) do
    "grid min-w-0 gap-3 opacity-100 transition-opacity duration-150 ease-out motion-reduce:transition-none"
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
        assignment_unavailable_reason: UpstreamAccountActions.assignment_unavailable_reason(assigns.account.assignments),
        recovery_eligible?: recovery_eligible?(assigns.account),
        recovery_default_pool_id: recovery_default_pool_id(assigns.account),
        recovery_reinvite_path: ReinviteLink.path_for_account(assigns.account),
        oauth_relink_available?: oauth_relink_available?(assigns.account),
        oauth_relink_unavailable_reason: oauth_relink_unavailable_reason(assigns.account)
      )

    ~H"""
    <div
      class="dropdown dropdown-end relative inline-block shrink-0 self-center focus-within:z-50"
      data-role="upstream-account-actions"
    >
      <button
        id={"upstream-account-actions-menu-#{@account.identity.id}"}
        type="button"
        class="btn btn-ghost btn-sm btn-square"
        tabindex="0"
        aria-label={gettext("Actions for %{label}", label: @account.label)}
        title={actions_menu_title(@account)}
      >
        <.icon name="hero-ellipsis-vertical" class="size-5" />
      </button>
      <ul
        tabindex="0"
        class="menu dropdown-content z-20 mt-2 w-60 rounded-box border border-base-300 bg-base-100 p-2 text-left shadow-xl"
      >
        <li :if={@account.identity.status != "deleted"}>
          <AdminComponents.dropdown_action_item
            id={"rename-upstream-account-#{@account.identity.id}"}
            icon="hero-pencil-square"
            label={gettext("Rename")}
            phx-click="open_rename_account"
            phx-value-id={@account.identity.id}
            disabled={@assignment_unavailable_reason != nil or @account.identity.status == "deleted"}
            title={@assignment_unavailable_reason}
          />
        </li>
        <li :if={@account.identity.status != "deleted"}>
          <AdminComponents.dropdown_action_item
            id={"pause-upstream-account-#{@account.identity.id}"}
            icon="hero-pause"
            label={gettext("Pause")}
            variant={:warning}
            phx-click="pause_account"
            phx-value-id={@account.identity.id}
            disabled={@assignment_unavailable_reason != nil or !pausable?(@account.identity.status)}
            title={@assignment_unavailable_reason}
          />
        </li>
        <li :if={@account.identity.status != "deleted"}>
          <AdminComponents.dropdown_action_item
            id={"reactivate-upstream-account-#{@account.identity.id}"}
            icon="hero-play"
            label={gettext("Reactivate")}
            variant={:positive}
            phx-click="reactivate_account"
            phx-value-id={@account.identity.id}
            disabled={@assignment_unavailable_reason != nil or !reactivatable?(@account.identity.status)}
            title={@assignment_unavailable_reason}
          />
        </li>
        <li :if={@recovery_eligible?}>
          <AdminComponents.dropdown_action_item
            id={"replace-auth-json-upstream-account-#{@account.identity.id}"}
            icon="hero-document-arrow-up"
            label={gettext("Replace auth.json")}
            phx-click="open_import_auth_json"
            phx-value-pool-id={@recovery_default_pool_id}
          />
        </li>
        <li :if={@recovery_eligible?}>
          <AdminComponents.dropdown_action_item
            id={"oauth-relink-upstream-account-#{@account.identity.id}"}
            icon="hero-link"
            label={gettext("Relink account")}
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
            label={gettext("Reinvite account")}
            navigate={@recovery_reinvite_path}
          />
          <AdminComponents.dropdown_action_item
            :if={!@recovery_reinvite_path}
            id={"reinvite-upstream-account-#{@account.identity.id}"}
            icon="hero-user-plus"
            label={gettext("Reinvite account")}
            disabled
            title={gettext("Assign this account to a visible Pool before creating a reinvite.")}
          />
        </li>
        <li :if={@account.identity.status != "deleted"}>
          <AdminComponents.dropdown_action_item
            id={"refresh-upstream-account-#{@account.identity.id}"}
            icon="hero-arrow-path"
            label={gettext("Refresh token")}
            phx-click="refresh_account"
            phx-value-id={@account.identity.id}
            disabled={@assignment_unavailable_reason != nil or !refreshable?(@account.identity.status)}
            title={@assignment_unavailable_reason}
          />
        </li>
        <li :if={Map.get(@account, :can_manage_provider_credits?, false) and @account.identity.status != "deleted"}>
          <AdminComponents.dropdown_action_item
            id={"provider-credits-policy-upstream-account-#{@account.identity.id}"}
            icon="hero-currency-dollar"
            label={gettext("Provider credits")}
            phx-click={JS.push_focus() |> JS.push("open_provider_credits_policy")}
            phx-value-id={@account.identity.id}
            aria-controls="provider-credits-policy-dialog"
            aria-haspopup="dialog"
          />
        </li>
        <li :if={@account.identity.status != "deleted"}>
          <AdminComponents.dropdown_action_item
            id={"saved-reset-policy-upstream-account-#{@account.identity.id}"}
            icon="hero-building-library-micro"
            label={gettext("Saved resets")}
            phx-click="open_saved_reset_policy"
            phx-value-id={@account.identity.id}
            disabled={@assignment_unavailable_reason != nil or @account.identity.status == "deleted"}
            title={@assignment_unavailable_reason}
          />
        </li>
        <li>
          <AdminComponents.dropdown_action_item
            id={"delete-upstream-account-#{@account.identity.id}"}
            icon="hero-trash"
            label={gettext("Delete")}
            variant={:danger}
            phx-click="open_delete_account"
            phx-value-id={@account.identity.id}
            disabled={!Map.get(@account, :can_delete?, false)}
            title={delete_unavailable_reason(@account)}
          />
        </li>
      </ul>
    </div>
    """
  end

  defp delete_unavailable_reason(%{deletion_state: :in_progress}),
    do: gettext("Account deletion is already in progress.")

  defp delete_unavailable_reason(%{can_delete?: true}), do: nil

  defp delete_unavailable_reason(%{assignments: [_ | _]}),
    do: gettext("Remove this account from all Pools before deleting it.")

  defp delete_unavailable_reason(_account),
    do: gettext("You do not have permission to permanently delete this account.")

  defp actions_menu_title(%{identity: %{status: "deleted"}} = account),
    do: delete_unavailable_reason(account)

  defp actions_menu_title(%{can_delete?: true}), do: nil

  defp actions_menu_title(account),
    do: UpstreamAccountActions.assignment_unavailable_reason(account.assignments)

  attr :account, :map, required: true
  attr :account_index, :integer, required: true

  defp upstream_plan_indicator(assigns) do
    ~H"""
    <AdminBadges.plan_badge
      :if={@account.plan_reported?}
      id={account_plan_label_id(@account, @account_index)}
      label={@account.plan_label}
      class="self-center"
      aria-label={gettext("Account plan: %{plan}", plan: @account.plan_label)}
    />
    <AdminComponents.diagnostic_popover
      :if={!@account.plan_reported?}
      id={account_plan_label_id(@account, @account_index)}
      label={gettext("Account did not report plan or quota details")}
      title={gettext("Plan and quota not reported")}
      description={gettext("This account did not report plan or quota details. Routing still depends on separate quota evidence before dispatch.")}
      placement={:end}
    />
    """
  end

  defp pool_assignment_summary_label(assignments),
    do: ngettext("%{count} routing lane", "%{count} routing lanes", length(assignments))

  # The footer cell below already carries the window's token total, so the
  # panel summary adds what nothing else shows: the settled spend.
  defp tokens_panel_summary(leaderboard) do
    total_cost_micros = leaderboard |> Enum.map(& &1.cost_micros) |> Enum.sum()
    ngettext("%{count} model, %{cost}", "%{count} models, %{cost}", length(leaderboard), cost: Format.money_from_micros(total_cost_micros))
  end

  # A leaderboard of the account's models over the trailing five minutes: one
  # row per distinct exposed model advertised by any routing lane or settled in
  # the window, ranked by settled tokens. Bars are relative to the leader. Ties
  # fall back to descending name so newer model generations surface first.
  defp token_leaderboard(account) do
    usage_by_label =
      account
      |> recent_model_usage()
      |> Map.new(&{&1.label, &1})

    model_info_by_label =
      account
      |> advertised_models()
      |> Enum.group_by(& &1.exposed_model_id)
      |> Map.new(fn {label, models} ->
        {label, models |> Enum.map(& &1.model_info) |> ModelInfo.merge()}
      end)

    rows =
      model_info_by_label
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(usage_by_label |> Map.keys() |> MapSet.new())
      |> Enum.map(fn label ->
        usage = Map.get(usage_by_label, label, %{tokens: 0, cost_micros: 0})

        %{
          label: label,
          tokens: usage.tokens,
          cost_micros: usage.cost_micros,
          model_info: Map.get(model_info_by_label, label, ModelInfo.empty())
        }
      end)

    leader_tokens = rows |> Enum.map(& &1.tokens) |> Enum.max(fn -> 0 end)

    rows
    |> Enum.sort_by(&{&1.tokens, &1.label}, :desc)
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

  defp advertised_models(%{assignments: assignments}) when is_list(assignments) do
    assignments
    |> Enum.flat_map(&assignment_models/1)
  end

  defp advertised_models(_account), do: []

  defp assignment_models(%{models: models}) when is_list(models), do: models
  defp assignment_models(_assignment), do: []

  defp share_percent(_tokens, 0), do: 0
  defp share_percent(tokens, leader_tokens), do: round(tokens / leader_tokens * 100)

  defp model_dom_id(model_id),
    do: model_id |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.slice(0, 80)

  defp tokens_panel_trigger_label(:tokens), do: gettext("Show quota status")
  defp tokens_panel_trigger_label(_panel_view), do: gettext("Show model usage for the last 5 minutes")

  defp pools_panel_trigger_label(:pools, _assignments), do: gettext("Show quota status")

  defp pools_panel_trigger_label(_panel_view, assignments),
    do: gettext("Show Pool assignments: %{count_label}", count_label: assignment_count_label(assignments))

  # The open panel keeps its trigger cell in the hover tint, so the footer
  # shows which panel the card body is currently disclosing.
  defp footer_panel_label_tone(true), do: "text-primary/70"
  defp footer_panel_label_tone(false), do: "text-base-content/35 group-hover:text-primary/70"

  defp footer_panel_value_tone(true), do: "text-base-content/75"

  defp footer_panel_value_tone(false),
    do: "text-base-content/60 group-hover:text-base-content/75"

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
  # against the footer edges and the column dividers on every side. The last
  # cell has no divider to its right, only the footer's own px-4, so it reaches
  # past its box to land on the same 4px gap as the other edges.
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
      label: gettext("Routing unavailable"),
      tone: :warning,
      routing_ready_now?: false,
      reason: gettext("Routing readiness is unavailable for this upstream account."),
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
      title: gettext("Token refresh failed"),
      body: gettext("This account is excluded from runtime routing until token refresh succeeds or credentials are relinked."),
      reason: lifecycle_reason(account)
    }
  end

  defp lifecycle_blocker_warning(
         %{identity: %{id: id, status: "reauth_required"}} = account,
         _routing_readiness
       ) do
    %{
      id: "upstream-account-#{id}-reauth-warning",
      title: gettext("Reauthentication required"),
      body: gettext("This account is excluded from routing until credentials are replaced."),
      reason: lifecycle_reason(account)
    }
  end

  defp lifecycle_blocker_warning(_account, _routing_readiness), do: nil

  @spec lifecycle_reason(map()) :: String.t() | nil
  defp lifecycle_reason(%{reauth_reason_message: message, reauth_reason_code: code})
       when is_binary(message) and message != "" do
    gettext("%{code} - %{message}", code: code || gettext("token refresh failed"), message: message)
  end

  defp lifecycle_reason(%{reauth_reason_code: code}) when is_binary(code) and code != "", do: code
  defp lifecycle_reason(_account), do: nil

  @spec workspace_context_label(map()) :: String.t()
  defp workspace_context_label(%{workspace_label: label}) when is_binary(label) and label != "",
    do: gettext("Workspace %{label}", label: label)

  defp workspace_context_label(%{workspace_ref: "legacy"}), do: ""

  defp workspace_context_label(%{workspace_ref: ref}) when is_binary(ref) and ref != "",
    do: gettext("Workspace %{label}", label: ref)

  defp workspace_context_label(_account), do: ""

  @spec workspace_context_title(map()) :: String.t() | nil
  defp workspace_context_title(%{workspace_ref: "legacy"}), do: nil

  defp workspace_context_title(%{workspace_ref: ref}) when is_binary(ref) and ref != "",
    do: gettext("Workspace reference %{ref}", ref: ref)

  defp workspace_context_title(_account), do: nil

  defp account_status_label(%{deletion_state: :in_progress}), do: gettext("Deletion in progress")
  defp account_status_label(%{deletion_state: :failed}), do: gettext("Deletion failed - retry Delete")

  defp account_status_label(%{identity: %{status: status}}) when is_binary(status),
    do: CockpitFormatting.humanize_state(status)

  defp account_status_label(_account), do: gettext("Unknown")

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

  defp quota_limits_grid_class([_single_limit]),
    do: "upstream-account-quota-limits grid gap-3"

  defp quota_limits_grid_class(_limits),
    do: "upstream-account-quota-limits upstream-account-quota-limits-multiple grid gap-3"

  defp saved_reset_meter_grid_class([_single_limit]), do: nil
  defp saved_reset_meter_grid_class(_limits), do: "upstream-account-saved-reset-meter-wide"

  defp account_plan_label_id(account, _index),
    do: "upstream-account-#{account.identity.id}-plan-label"

  defp assignment_count_label([]), do: gettext("No Pools")
  defp assignment_count_label(assignments), do: ngettext("%{count} Pool", "%{count} Pools", length(assignments))

  # Settled tokens this account routed toward the assignment's Pool in the
  # last 5 minutes — same window and ledger rows as the token burn indicator.
  # Requests whose usage has not settled yet cannot be counted, so a row that
  # is all-unknown shows "?" rather than a false zero.
  defp assignment_traffic_label(assignment) do
    case assignment_recent_traffic(assignment) do
      %{tokens: 0, request_count: requests, known_request_count: 0} when requests > 0 ->
        "? tok/5m"

      %{tokens: tokens} ->
        "#{Format.token_count(tokens)} tok/5m"
    end
  end

  defp assignment_traffic_title(%{pool_label: pool_label} = assignment) do
    case assignment_recent_traffic(assignment) do
      %{request_count: 0} ->
        gettext("No requests toward %{pool} in the last 5 minutes.", pool: pool_label)

      %{tokens: tokens, request_count: requests, unknown_request_count: 0} ->
        gettext("Last 5m toward %{pool}: %{tokens} across %{requests}.", pool: pool_label, tokens: settled_token_count_label(tokens), requests: request_count_label(requests))

      %{tokens: tokens, request_count: requests, unknown_request_count: unknown} ->
        gettext("Last 5m toward %{pool}: %{tokens} across %{requests}; usage still missing for %{missing}.", pool: pool_label, tokens: settled_token_count_label(tokens), requests: request_count_label(requests), missing: request_count_label(unknown))
    end
  end

  defp request_count_label(count), do: ngettext("%{count} request", "%{count} requests", count)

  defp settled_token_count_label(tokens),
    do: ngettext("%{tokens} settled token", "%{tokens} settled tokens", tokens, tokens: Format.token_count(tokens))

  defp assignment_recent_traffic(assignment) do
    Map.get(assignment, :recent_traffic) ||
      %{tokens: 0, request_count: 0, known_request_count: 0, unknown_request_count: 0}
  end

  defp recent_token_count_label(%{token_burn: %{usage_state: :unknown}}),
    do: gettext("Usage unavailable")

  defp recent_token_count_label(%{token_burn: %{usage_state: :partial, recent_tokens: tokens}})
       when is_integer(tokens) and tokens >= 0 do
    ngettext("%{tokens}+ token", "%{tokens}+ tokens", tokens, tokens: Format.token_count(tokens))
  end

  defp recent_token_count_label(%{token_burn: %{recent_tokens: tokens}})
       when is_integer(tokens) and tokens >= 0 do
    ngettext("%{tokens} token", "%{tokens} tokens", tokens, tokens: Format.token_count(tokens))
  end

  defp recent_token_count_label(_account), do: ngettext("%{count} token", "%{count} tokens", 0)

  defp token_burn_title(%{token_burn: %{title: title}}) when is_binary(title), do: title
  defp token_burn_title(_account), do: gettext("Token usage in the last 5 minutes")

  defp recent_request_count_label(%{token_burn: %{recent_requests: requests}})
       when is_integer(requests) and requests >= 0 do
    Format.integer(requests)
  end

  defp recent_request_count_label(_account), do: "0"

  defp token_burn_usage_state(%{token_burn: %{usage_state: usage_state}})
       when usage_state in [:idle, :complete, :partial, :unknown],
       do: usage_state

  defp token_burn_usage_state(_account), do: :idle

  defp token_burn_active?(%{token_burn: %{level: level}}), do: is_integer(level) and level > 0
  defp token_burn_active?(_account), do: false

  defp quota_shine_style(account, account_index) do
    delay = "--shine-delay: #{rem(account_index, 7) * 400}ms"

    case account do
      %{token_burn: %{level: level}} when is_integer(level) and level > 0 ->
        "#{delay}; --shine-period: #{3400 - min(level, 5) * 400}ms"

      _account ->
        delay
    end
  end

  @spec recovery_eligible?(map()) :: boolean()
  defp recovery_eligible?(%{identity: %{status: status}} = account) do
    status in @recovery_statuses and status != "deleted" and not auth_clearly_usable?(account)
  end

  defp recovery_eligible?(_account), do: false

  @spec auth_clearly_usable?(map()) :: boolean()
  defp auth_clearly_usable?(%{
         reauth_required?: false,
         refresh_status: refresh_status,
         secret_status: :present
       }) do
    refresh_status in ~w(succeeded imported refreshing)
  end

  defp auth_clearly_usable?(_account), do: false

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
    do: gettext("Deleted accounts cannot be relinked.")

  defp oauth_relink_unavailable_reason(%{assignments: []}),
    do: gettext("Assign this account to a visible Pool before relinking.")

  defp oauth_relink_unavailable_reason(_account), do: nil

  defp pausable?("active"), do: true
  defp pausable?("refresh_due"), do: true
  defp pausable?("refresh_failed"), do: true
  defp pausable?(_status), do: false

  defp reactivatable?(status), do: status in @reactivatable_statuses

  defp refreshable?(status), do: status in ["active", "refresh_due", "refresh_failed"]
end
