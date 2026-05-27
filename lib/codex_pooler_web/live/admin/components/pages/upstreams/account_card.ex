defmodule CodexPoolerWeb.Admin.UpstreamAccountCard do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolInviteForm

  @reactivatable_statuses ~w(paused refresh_due refresh_failed)
  @recovery_statuses ~w(paused refresh_due refresh_failed reauth_required)
  @usable_refresh_statuses ~w(succeeded imported refreshing)

  attr :account, :map, required: true
  attr :account_index, :integer, required: true

  def account_card(assigns) do
    ~H"""
    <article
      id={"upstream-account-#{@account.identity.id}"}
      data-role="upstream-account-card"
      class={[
        "min-w-0 rounded-box border border-l-2 border-base-300 bg-base-100 shadow-sm transition-colors",
        status_border_class(@account)
      ]}
    >
      <header
        data-role="upstream-account-card-header"
        class="flex flex-row items-start justify-between gap-3 border-b border-base-300 bg-base-200/35 p-4"
      >
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            <h3 class="min-w-0 text-lg font-semibold text-base-content">
              <.link
                id={"upstream-account-#{@account.identity.id}-mail"}
                navigate={~p"/admin/upstreams/#{@account.identity.id}"}
                class="block truncate hover:text-primary focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
              >
                {@account.label}
              </.link>
            </h3>
          </div>
          <p
            id={"upstream-account-#{@account.identity.id}-routing-readiness"}
            class="mt-1 text-xs leading-5 text-base-content/55"
          >
            {routing_signal_label(@account)} · {assignment_count_label(@account.assignments)}
          </p>
        </div>
        <div
          id={"upstream-account-#{@account.identity.id}-header-actions"}
          class="flex shrink-0 items-center gap-2 self-start"
        >
          <.upstream_plan_indicator account={@account} account_index={@account_index} />
          <.upstream_account_actions account={@account} />
        </div>
      </header>

      <div class="grid gap-4 p-4">
        <section class="grid gap-3">
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
            class="grid gap-3 md:grid-cols-2"
          >
            <.quota_limit_row
              :for={limit <- reported_quota_limits(@account.quota_limits)}
              id={"upstream-account-#{@account.identity.id}-limit-#{limit.key}"}
              limit={limit}
            />
          </div>
        </section>

        <.upstream_reauth_warning account={@account} />
      </div>
      <.upstream_refresh_status account={@account} />
      <.upstream_selector_contracts account={@account} />
    </article>
    """
  end

  attr :account, :map, required: true

  defp upstream_account_actions(assigns) do
    assigns =
      assign(assigns,
        recovery_eligible?: recovery_eligible?(assigns.account),
        recovery_default_pool_id: recovery_default_pool_id(assigns.account),
        recovery_reinvite_path: recovery_reinvite_path(assigns.account)
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

  attr :account, :map, required: true

  defp upstream_reauth_warning(assigns) do
    ~H"""
    <div
      :if={@account.reauth_required?}
      id={"upstream-account-#{@account.identity.id}-reauth-warning"}
      class="rounded-box border border-error/30 bg-error/10 p-3 text-sm text-base-content"
    >
      <div class="flex items-start gap-2">
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-error" />
        <div class="space-y-1">
          <p class="font-semibold text-error">Reauthentication required</p>
          <p>
            This account is excluded from routing until credentials are replaced.
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
            Recovery: use Replace auth.json to load fresh credentials, or Reinvite account when the operator needs to complete hosted sign-in again.
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

  defp upstream_selector_contracts(assigns) do
    ~H"""
    <div class="hidden" data-role="upstream-account-selector-contracts">
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
    <span class="dropdown dropdown-hover dropdown-end inline-flex justify-end">
      <button
        id={@id}
        type="button"
        class="inline-flex items-center justify-end gap-1 rounded px-1 text-xs font-medium text-base-content/70 transition-colors hover:bg-base-300/60 hover:text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        tabindex="0"
        aria-label="Token burn calculation"
        aria-describedby={@content_id}
        title={@token_burn.title}
      >
        <.icon name="hero-fire" class={token_burn_icon_class(@token_burn)} />
        <span>{@token_burn.label}</span>
      </button>
      <span
        id={@content_id}
        role="tooltip"
        tabindex="0"
        class="dropdown-content z-20 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-3 text-left text-xs font-normal leading-5 text-base-content/70 shadow-xl sm:w-72"
      >
        Compares settled tokens from the last 5 minutes with the previous 1 hour baseline.
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

  defp token_burn_icon_class(%{level: 0}), do: "size-3.5 text-base-content/35"
  defp token_burn_icon_class(%{level: level}) when level in 1..2, do: "size-3.5 text-warning/70"
  defp token_burn_icon_class(%{level: level}) when level in 3..4, do: "size-3.5 text-warning"
  defp token_burn_icon_class(%{level: 5}), do: "size-3.5 text-error"
  defp token_burn_icon_class(_token_burn), do: "size-3.5 text-base-content/35"

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

  defp account_plan_label_id(account, _index),
    do: "upstream-account-#{account.identity.id}-plan-label"

  defp assignment_count_label([]), do: "No Pools"
  defp assignment_count_label([_assignment]), do: "1 Pool"
  defp assignment_count_label(assignments), do: "#{length(assignments)} Pools"

  defp routing_signal_label(%{reauth_required?: true}), do: "Needs reauth"
  defp routing_signal_label(%{assignments: []}), do: "Not assigned"

  defp routing_signal_label(%{identity: %{status: "active"}, assignments: assignments}),
    do: quota_routing_signal_label(assignments)

  defp routing_signal_label(%{identity: %{status: "refresh_due"}}), do: "Refresh due"
  defp routing_signal_label(%{identity: %{status: "refresh_failed"}}), do: "Refresh failed"
  defp routing_signal_label(_account), do: "Not routable"

  defp quota_routing_signal_label(assignments) do
    statuses = Enum.map(assignments, & &1.quota_priming_status)

    cond do
      "known" in statuses -> "Routing candidate"
      "weekly_only_probe" in statuses -> "Weekly quota probe"
      "refreshing" in statuses -> "Quota reconciling"
      "blocked" in statuses -> "Quota blocked"
      "failed" in statuses -> "Quota failed"
      "expired" in statuses -> "Quota expired"
      "stale" in statuses -> "Quota stale"
      true -> "Quota pending"
    end
  end

  defp status_border_class(%{reauth_required?: true}), do: "border-l-error"

  defp status_border_class(%{identity: %{status: "active"}}), do: "border-l-success"

  defp status_border_class(_account), do: "border-l-warning"

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
    [account.identity.chatgpt_account_id, account.label]
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
