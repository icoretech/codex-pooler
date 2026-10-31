defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.SelectorContracts do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :account, :map, required: true

  @spec refresh_status(map()) :: Phoenix.LiveView.Rendered.t()
  def refresh_status(assigns) do
    ~H"""
    <div class="hidden">
      <div id={"upstream-account-#{@account.identity.id}-refresh-status"}>
        {refresh_status_label(@account.refresh_status, @account.refresh_job_state)}
      </div>
    </div>
    """
  end

  attr :account, :map, required: true
  attr :routing_readiness, :map, required: true

  @spec selector_contracts(map()) :: Phoenix.LiveView.Rendered.t()
  def selector_contracts(assigns) do
    ~H"""
    <div class="hidden" data-role="upstream-account-selector-contracts">
      <section id={"upstream-account-#{@account.identity.id}-routing-readiness-contract"}>
        {gettext("routing readiness")}
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
        {gettext("quota readiness")}
        <span id={"upstream-account-#{@account.identity.id}-quota-readiness-state"}>
          {@account.quota_readiness.state}
        </span>
        <span id={"upstream-account-#{@account.identity.id}-quota-readiness-label"}>
          {@account.quota_readiness.label}
        </span>
      </section>

      <section id={"upstream-account-#{@account.identity.id}-auth-health"}>
        {gettext("Auth health")}
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
        {gettext("quota refresh %{status}", status: @account.quota_refresh_status)}
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
        <p :if={@account.assignments == []}>{gettext("No active Pool assignments")}</p>
      </section>
    </div>
    """
  end

  defp refresh_status_label(status, nil),
    do: gettext("Refresh: %{status}", status: status)

  defp refresh_status_label(status, job_state),
    do: gettext("Refresh: %{status} · job %{job}", status: status, job: job_state)
end
