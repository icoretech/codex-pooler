defmodule CodexPoolerWeb.Admin.UpstreamAccountCard do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  @reactivatable_statuses ~w(paused refresh_due refresh_failed)

  attr :account, :map, required: true
  attr :account_index, :integer, required: true

  def account_card(assigns) do
    ~H"""
    <article
      id={"upstream-account-#{@account.identity.id}"}
      data-role="upstream-account-card"
      class="rounded-box border border-base-300 bg-base-100 p-4 shadow-sm transition-colors hover:border-primary/30"
    >
      <div class="grid gap-4 md:grid-cols-[minmax(11rem,0.72fr)_minmax(0,1fr)]">
        <section class="grid content-start gap-3 rounded-box border border-base-300 bg-base-200/40 p-3">
          <div class="flex items-start justify-between gap-3">
            <span class={status_dot_class(@account)} aria-hidden="true" />
            <.upstream_account_actions account={@account} />
          </div>
          <div class="min-w-0">
            <p class="text-xs font-medium text-base-content/55">Account</p>
            <h3
              id={"upstream-account-#{@account.identity.id}-mail"}
              class="mt-1 truncate text-lg font-semibold text-base-content"
            >
              {@account.label}
            </h3>
            <p class="mt-1 truncate text-xs text-base-content/55">
              {@account.identifier_label}
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <span
              id={"upstream-account-#{@account.identity.id}-state"}
              class={lifecycle_badge_class(@account.identity.status)}
            >
              {@account.identity.status}
            </span>
            <.upstream_plan_indicator account={@account} account_index={@account_index} />
          </div>
        </section>

        <section class="grid gap-3">
          <div class="rounded-box border border-base-300 bg-base-100 p-3">
            <p class="text-xs font-medium text-base-content/55">Routing readiness</p>
            <div class="mt-1 flex flex-wrap items-center gap-2">
              <p
                id={"upstream-account-#{@account.identity.id}-routing-readiness"}
                class="text-base font-semibold text-base-content"
              >
                {routing_signal_label(@account)}
              </p>
              <span class={lifecycle_badge_class(@account.identity.status)}>
                {@account.identity.status}
              </span>
            </div>
            <p class="mt-1 text-xs text-base-content/60">
              {assignment_count_label(@account.assignments)} · quota refresh {@account.quota_refresh_status} · {@account.token_refresh_label}
            </p>
          </div>
          <.upstream_reauth_warning account={@account} />
          <.upstream_auth_health account={@account} />
          <.upstream_quota_limits account={@account} />
          <.upstream_pool_assignments account={@account} />
        </section>
        <.upstream_refresh_status account={@account} />
      </div>
    </article>
    """
  end

  attr :account, :map, required: true

  defp upstream_account_actions(assigns) do
    ~H"""
    <div class="dropdown dropdown-end inline-block">
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
      aria-label={"Account plan: #{@account.plan_label}"}
    />
    <AdminComponents.diagnostic_popover
      :if={!@account.plan_reported?}
      id={account_plan_label_id(@account, @account_index)}
      label="Account did not report plan or quota details"
      title="Plan and quota not reported"
      description="This account did not report plan or quota details. Routing still depends on separate quota evidence before dispatch."
    />
    """
  end

  attr :account, :map, required: true

  defp upstream_reauth_warning(assigns) do
    ~H"""
    <div
      :if={@account.reauth_required?}
      id={"upstream-account-#{@account.identity.id}-reauth-warning"}
      class="rounded-box border border-error/30 bg-error/10 p-3 text-sm text-error-content"
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
            Remediation: Reauthenticate / replace credentials with a fresh token or auth.json import.
          </p>
        </div>
      </div>
    </div>
    """
  end

  attr :account, :map, required: true

  defp upstream_auth_health(assigns) do
    ~H"""
    <div
      id={"upstream-account-#{@account.identity.id}-auth-health"}
      data-role="upstream-auth-health"
      class="rounded-box border border-base-300 bg-base-100 p-3"
    >
      <div class="flex items-center justify-between gap-3">
        <p class="text-xs font-semibold text-base-content/55">Auth health</p>
        <span class={AdminBadges.status_chip_class(@account.refresh_status)}>
          {@account.refresh_status}
        </span>
      </div>
      <dl class="mt-2 grid gap-1.5 text-xs text-base-content/70">
        <div class="grid gap-0.5 sm:grid-cols-[8rem_minmax(0,1fr)]">
          <dt class="font-medium text-base-content/55">Imported</dt>
          <dd id={"upstream-account-#{@account.identity.id}-auth-fresh"}>
            {@account.auth_fresh_label}
          </dd>
        </div>
        <div class="grid gap-0.5 sm:grid-cols-[8rem_minmax(0,1fr)]">
          <dt class="font-medium text-base-content/55">Verified</dt>
          <dd id={"upstream-account-#{@account.identity.id}-auth-verified"}>
            {@account.auth_verified_label}
          </dd>
        </div>
        <div class="grid gap-0.5 sm:grid-cols-[8rem_minmax(0,1fr)]">
          <dt class="font-medium text-base-content/55">Access token</dt>
          <dd id={"upstream-account-#{@account.identity.id}-access-token"}>
            {@account.access_token_label}
          </dd>
        </div>
        <div class="grid gap-0.5 sm:grid-cols-[8rem_minmax(0,1fr)]">
          <dt class="font-medium text-base-content/55">Refresh</dt>
          <dd id={"upstream-account-#{@account.identity.id}-token-refresh"}>
            {@account.token_refresh_label}
          </dd>
        </div>
      </dl>
    </div>
    """
  end

  attr :account, :map, required: true

  defp upstream_quota_limits(assigns) do
    ~H"""
    <div id={"upstream-account-#{@account.identity.id}-limits"} class="grid gap-3">
      <div class="flex items-center justify-between gap-3">
        <p class="text-xs font-semibold text-base-content/55">Limits</p>
        <p class="text-xs text-base-content/50">reported by upstream</p>
      </div>
      <.quota_limit_row
        :for={limit <- @account.quota_limits}
        id={"upstream-account-#{@account.identity.id}-limit-#{limit.key}"}
        limit={limit}
      />
    </div>
    """
  end

  attr :account, :map, required: true

  defp upstream_pool_assignments(assigns) do
    ~H"""
    <div class="grid gap-2">
      <div class="flex items-center justify-between gap-3">
        <p class="text-xs font-semibold text-base-content/55">Pool assignments</p>
        <span class="text-xs text-base-content/50">
          {assignment_count_label(@account.assignments)}
        </span>
      </div>
      <div
        :for={assignment <- @account.assignments}
        id={"upstream-account-#{@account.identity.id}-assignment-#{assignment.id}"}
        class="grid gap-2 rounded-box border border-base-300 bg-base-200/40 p-2 text-xs sm:grid-cols-[minmax(0,1fr)_auto]"
      >
        <div class="min-w-0">
          <p class="truncate font-semibold text-base-content">{assignment.pool_label}</p>
          <p class="truncate text-base-content/60">{assignment.assignment_label}</p>
        </div>
        <div class="flex flex-wrap justify-start gap-1.5 sm:justify-end">
          <span class={assignment_status_badge_class(assignment.status)}>
            {assignment.status}
          </span>
          <span class={assignment_status_badge_class(assignment.eligibility_status)}>
            {assignment.eligibility_status}
          </span>
          <span
            id={"upstream-account-#{@account.identity.id}-assignment-#{assignment.id}-quota-priming"}
            class={AdminBadges.status_chip_class(assignment.quota_priming_status)}
          >
            {assignment.quota_priming_label}
          </span>
        </div>
      </div>
      <p :if={@account.assignments == []} class="text-xs text-base-content/60">
        No active Pool assignments
      </p>
    </div>
    """
  end

  attr :account, :map, required: true

  defp upstream_refresh_status(assigns) do
    ~H"""
    <div class="sr-only">
      <div id={"upstream-account-#{@account.identity.id}-refresh-status"}>
        Refresh: {@account.refresh_status}
        <span :if={@account.refresh_job_state}>
          · job {@account.refresh_job_state}
        </span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :limit, :map, required: true

  defp quota_limit_row(assigns) do
    ~H"""
    <div id={@id} data-role="upstream-limit-chart" class="grid gap-1.5">
      <div class="flex items-center justify-between gap-3 text-xs">
        <span class="font-medium text-base-content">{@limit.label} remaining</span>
        <span class={quota_limit_percent_class(@limit)}>{@limit.percent_label}</span>
      </div>
      <progress
        id={"#{@id}-progress"}
        data-role="upstream-limit-progress"
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

  defp status_dot_class(%{reauth_required?: true}), do: "size-2.5 shrink-0 rounded-full bg-error"

  defp status_dot_class(%{identity: %{status: "active"}}),
    do: "size-2.5 shrink-0 rounded-full bg-success"

  defp status_dot_class(_account), do: "size-2.5 shrink-0 rounded-full bg-warning"

  defp assignment_status_badge_class(status) when status in ["active", "eligible", "healthy"],
    do: "badge badge-success badge-sm"

  defp assignment_status_badge_class(status) when status in ["paused", "inactive", "ineligible"],
    do: "badge badge-warning badge-sm"

  defp assignment_status_badge_class(_status), do: "badge badge-ghost badge-sm"

  defp pausable?("active"), do: true
  defp pausable?("refresh_due"), do: true
  defp pausable?("refresh_failed"), do: true
  defp pausable?(_status), do: false

  defp reactivatable?(status), do: status in @reactivatable_statuses

  defp refreshable?(status), do: status in ["active", "refresh_due", "refresh_failed"]

  defp lifecycle_badge_class(status), do: AdminBadges.lifecycle_chip_class(status)
end
