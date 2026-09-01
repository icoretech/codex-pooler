defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.SelectorContracts do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :account, :map, required: true

  def refresh_status(assigns) do
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

  def selector_contracts(assigns) do
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

      <section
        id={"upstream-account-#{@account.identity.id}-quota-readiness-contract"}
        data-quota-tone={@account.quota_readiness.tone}
        data-routing-ready-now={to_string(@account.quota_readiness.routing_ready_now?)}
      >
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
end
