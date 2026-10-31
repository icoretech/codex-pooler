defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.ReconciliationStatus do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :id_prefix, :string, required: true
  attr :identity_observability, :map, required: true
  attr :reauth_required?, :boolean, required: true
  attr :lifecycle_warning, :map, default: nil

  @spec reconciliation_status(map()) :: Phoenix.LiveView.Rendered.t()
  def reconciliation_status(assigns) do
    assigns =
      assign(
        assigns,
        :state,
        state(assigns.identity_observability, assigns.reauth_required?, assigns.lifecycle_warning)
      )

    ~H"""
    <details
      :if={@state.visible?}
      id={"#{@id_prefix}-reconciliation-status"}
      data-role="upstream-reconciliation-status"
      data-reconciliation-status={@state.reconciliation_status}
      data-preserve-open
      class="group min-w-0 rounded-box border border-base-300 bg-base-200/40"
    >
      <summary class="flex min-w-0 cursor-pointer list-none items-center gap-2 rounded-box px-3 py-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary [&::-webkit-details-marker]:hidden">
        <span class={tone_dot_class(@state.tone)} aria-hidden="true"></span>
        <h3
          id={"#{@id_prefix}-reconciliation-title"}
          class="min-w-0 flex-1 truncate text-sm font-semibold text-base-content"
        >
          {@state.title}
        </h3>
        <span
          :if={@state.attempt_age}
          id={"#{@id_prefix}-reconciliation-attempt-age"}
          class="shrink-0 text-xs text-base-content/55"
        >
          {gettext("latest attempt %{age}", age: @state.attempt_age)}
        </span>
        <.icon
          name="hero-chevron-right"
          class="size-3 shrink-0 text-base-content/40 transition-transform group-open:rotate-90"
        />
      </summary>
      <div class="grid min-w-0 gap-1 border-t border-base-300/70 px-3 py-2.5 text-sm">
        <p id={"#{@id_prefix}-reconciliation-summary"} class="text-base-content/75">
          {@state.summary}
        </p>
        <p
          :if={@state.reason}
          id={"#{@id_prefix}-reconciliation-reason"}
          class="text-xs text-base-content/70"
        >
          {@state.reason}
        </p>
        <dl class="flex flex-wrap gap-x-4 gap-y-0.5 text-xs text-base-content/55">
          <div>
            <dt class="sr-only">{gettext("Last successful refresh")}</dt>
            <dd id={"#{@id_prefix}-last-successful-refresh"}>
              {age_label(:last_successful_refresh, @state.last_successful_refresh_age)}
            </dd>
          </div>
          <div>
            <dt class="sr-only">{gettext("Quota evidence age")}</dt>
            <dd id={"#{@id_prefix}-quota-evidence-age"}>
              {age_label(:quota_evidence, @state.quota_evidence_age)}
            </dd>
          </div>
        </dl>
      </div>
    </details>
    """
  end

  defp state(observability, reauth_required?, lifecycle_warning) do
    reconciliation = Map.get(observability, :reconciliation, %{})
    reconciliation_status = Map.get(reconciliation, :status)
    reconciliation_reason = Map.get(reconciliation, :message) || Map.get(reconciliation, :code)

    {tone, title, summary, reason} =
      cond do
        is_map(lifecycle_warning) ->
          {:error, Map.fetch!(lifecycle_warning, :title), Map.fetch!(lifecycle_warning, :body), Map.get(lifecycle_warning, :reason) || reconciliation_reason}

        reauth_required? ->
          {:error, gettext("Reauthentication required"), gettext("Credentials need recovery before this account can route."), reconciliation_reason}

        reconciliation_status in ["failed", "partial", "blocked"] ->
          {:error, gettext("Quota reconciliation needs attention"), reconciliation_reason || gettext("The latest reconciliation did not complete successfully."), nil}

        true ->
          {:neutral, nil, nil, nil}
      end

    %{
      visible?: tone != :neutral,
      tone: tone,
      title: title,
      summary: summary,
      reason: reason,
      reconciliation_status: reconciliation_status || "unavailable",
      attempt_age: Map.get(reconciliation, :attempt_age),
      last_successful_refresh_age: Map.get(observability, :last_successful_quota_refresh_age),
      quota_evidence_age: Map.get(observability, :quota_evidence_age)
    }
  end

  defp age_label(:last_successful_refresh, age) when is_binary(age) and age != "",
    do: gettext("Last successful quota refresh %{age}", age: age)

  defp age_label(:last_successful_refresh, _age), do: gettext("Last successful quota refresh not reported")

  defp age_label(:quota_evidence, age) when is_binary(age) and age != "",
    do: gettext("Quota evidence %{age}", age: age)

  defp age_label(:quota_evidence, _age), do: gettext("Quota evidence not reported")

  defp tone_dot_class(:error),
    do: "size-2 shrink-0 rounded-full bg-error ring-[3px] ring-error/15"

  defp tone_dot_class(_tone),
    do: "size-2 shrink-0 rounded-full bg-base-content/40 ring-[3px] ring-base-content/10"
end
