defmodule CodexPoolerWeb.Admin.UpstreamCockpitComponents.Charts do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.UpstreamAccountActions
  alias CodexPoolerWeb.Admin.UpstreamCockpitComponents.Formatting
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.{QuotaLimitRow, SavedResetMeter}
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.ProviderCreditsComponents
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.SavedResetComponents
  alias Phoenix.HTML.Form

  @doc """
  Quota & banked resets: account-level quota windows (same rows as the index
  card), the banked-reset meter with expirations, and the auto redeem policy.
  """
  attr :cockpit, :map, required: true
  attr :saved_reset_policy_form, :any, required: true
  attr :datetime_preferences, :map, required: true

  @spec quota_section(map()) :: Phoenix.LiveView.Rendered.t()
  def quota_section(assigns) do
    assigns =
      assign(assigns, :reported_limits, reported_quota_limits(assigns.cockpit.quota_limits))

    ~H"""
    <section
      id="upstream-quota"
      aria-label={gettext("Quota and banked resets")}
      class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100"
    >
      <header class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 bg-base-200/35 px-4 py-3">
        <div class="grid min-w-0 gap-0.5">
          <h2 class="text-base font-semibold leading-5 text-base-content">
            {gettext("Quota & banked resets")}
          </h2>
          <p class="text-xs leading-5 text-base-content/60">
            {quota_description(@cockpit.charts.quota_health)}
          </p>
        </div>
        <span class={AdminBadges.status_chip_class(@cockpit.charts.quota_health.state)}>
          {quota_state_label(@cockpit.charts.quota_health)}
        </span>
      </header>

      <div
        :if={@reported_limits != [] or Map.get(@cockpit.provider_credits_summary, :display_row?, false)}
        id="upstream-quota-limits"
        class="grid gap-4 p-4 md:grid-cols-2"
      >
        <QuotaLimitRow.quota_limit_row
          :for={limit <- @reported_limits}
          id={"upstream-quota-limit-#{limit.key}"}
          account_label={@cockpit.header.title}
          limit={limit}
        />
        <ProviderCreditsComponents.provider_credits_summary
          id="upstream-provider-credits"
          summary={@cockpit.provider_credits_summary}
          trigger_id="provider-credits-policy-open"
          open_policy={if @cockpit.can_manage_provider_credits? and @cockpit.identity.status != "deleted", do: JS.push_focus() |> JS.push("open_provider_credits_policy")}
        />
      </div>
      <p
        :if={@reported_limits == []}
        id="upstream-quota-limits-empty"
        class="px-4 py-4 text-sm text-base-content/60"
      >
        {gettext("No quota windows are reported for this account yet.")}
      </p>
      <div :if={not Map.get(@cockpit.provider_credits_summary, :display_row?, false) and @cockpit.can_manage_provider_credits? and @cockpit.identity.status != "deleted"} class="px-4 pb-4">
        <AdminComponents.action_button
          id="provider-credits-policy-open"
          label={gettext("Provider credits policy")}
          icon="hero-currency-dollar"
          phx-click={JS.push_focus() |> JS.push("open_provider_credits_policy")}
          aria-controls="provider-credits-policy-dialog"
          aria-haspopup="dialog"
          variant={:secondary}
        />
      </div>

      <details
        id="saved-reset-bank-disclosure"
        class="border-t border-base-300/60"
        data-preserve-open
      >
        <summary class="block cursor-pointer list-none px-4 py-3 transition-colors hover:bg-base-200/50 [&::-webkit-details-marker]:hidden">
          <SavedResetMeter.saved_reset_meter
            id="upstream-quota-saved-reset-meter"
            saved_resets={@cockpit.saved_resets}
            saved_reset_policy={@cockpit.saved_reset_policy}
          />
        </summary>
        <div class="grid gap-3 px-4 pb-3">
          <SavedResetComponents.saved_reset_last_auto_redemption_cause
            id="cockpit-saved-reset-last-auto-redemption-cause"
            cause={@cockpit.saved_resets.last_auto_redemption_cause}
          />
          <div
            :if={@cockpit.saved_resets.available?}
            id="cockpit-saved-reset-expiration-summary"
            class="grid gap-2"
          >
            <SavedResetComponents.saved_reset_expiration_table
              id="cockpit-saved-reset-expiration"
              saved_resets={@cockpit.saved_resets}
              calendar_path={~p"/admin/upstreams/#{@cockpit.identity.id}/saved-reset-expirations.ics"}
              datetime_preferences={@datetime_preferences}
              empty_label={gettext("No expiration dates reported for the available saved resets yet.")}
            />
          </div>
        </div>
      </details>

      <details
        id="saved-reset-policy-disclosure"
        class="border-t border-base-300/60"
        data-preserve-open
      >
        <summary class="flex cursor-pointer items-center justify-between gap-3 px-4 py-3 text-sm font-semibold text-base-content transition-colors hover:bg-base-200/50 [&::-webkit-details-marker]:hidden">
          <span>{gettext("Auto redeem policy")}</span>
          <span class={[
            AdminBadges.metadata_chip_class(policy_tone(@cockpit.saved_reset_policy)),
            "!px-2 !py-0.5 !text-[10px] uppercase"
          ]}>
            {policy_state_label(@cockpit.saved_reset_policy)}
          </span>
        </summary>
        <.form
          id="saved-reset-policy-form"
          data-saved-reset-form
          for={@saved_reset_policy_form}
          phx-change="validate_saved_reset_policy"
          phx-submit="save_saved_reset_policy"
          autocomplete="off"
          class="grid gap-4 border-t border-base-300/50 p-4"
        >
          <label
            id="saved-reset-policy-auto-redeem-control"
            for="saved-reset-policy-auto-redeem-enabled"
            class="flex cursor-pointer items-center justify-between gap-3"
          >
            <span class="grid gap-0.5">
              <span class="text-sm font-semibold text-base-content">{gettext("Auto redeem saved resets")}</span>
              <span class="text-xs leading-5 text-base-content/60">
                {gettext("Spend banked resets without operator action; the cards below decide when.")}
              </span>
            </span>
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

          <SavedResetComponents.saved_reset_policy_fields form={@saved_reset_policy_form} />

          <div class="flex justify-end border-t border-base-300/70 pt-3">
            <AdminComponents.action_button
              id="saved-reset-policy-submit"
              data-saved-reset-action="save-policy"
              data-server-disabled={to_string(@cockpit.assignments.empty?)}
              label={gettext("Save policy")}
              icon="hero-check"
              type="submit"
              variant={:primary}
              disabled={@cockpit.assignments.empty?}
              title={UpstreamAccountActions.assignment_unavailable_reason(@cockpit.assignments.items)}
            />
          </div>
        </.form>
      </details>
    </section>
    """
  end

  @doc """
  Request health: traffic routed through this account over the last 7 days,
  with a 24h error-code breakdown and on-demand refresh.
  """
  attr :cockpit, :map, required: true
  attr :refresh_data_message, :string, default: nil
  attr :request_metrics_loaded?, :boolean, default: true
  attr :request_metrics_loading?, :boolean, default: false
  attr :request_metrics_running?, :boolean, default: false

  @spec request_section(map()) :: Phoenix.LiveView.Rendered.t()
  def request_section(assigns) do
    assigns =
      assign(assigns, :model, request_health_chart_model(assigns.cockpit.charts.request_health))

    ~H"""
    <section
      id="request-health-chart"
      aria-label={gettext("Request health")}
      aria-busy={to_string(@request_metrics_loading? || @request_metrics_running?)}
      class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100"
    >
      <header class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 bg-base-200/35 px-4 py-3">
        <div class="grid min-w-0 gap-0.5">
          <h2 class="text-base font-semibold leading-5 text-base-content">{gettext("Request health")}</h2>
          <p class="text-xs leading-5 text-base-content/60">
            {gettext("Traffic routed through this account · last 7 days")}
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <span
            :if={@refresh_data_message}
            id="upstream-refresh-data-message"
            class={[AdminBadges.metadata_chip_class(:success), "!text-[10px]"]}
          >
            {@refresh_data_message}
          </span>
          <button
            id="upstream-refresh-data-button"
            type="button"
            phx-click="refresh_data"
            title={gettext("Traffic, contribution, and activity data refresh on page load or on demand")}
            class="btn btn-ghost btn-xs gap-1.5 text-base-content/65"
          >
            <.icon name="hero-arrow-path" class="size-3.5" />
            <span class="admin-control-label">{gettext("Refresh")}</span>
          </button>
          <.link
            id="request-health-chart-logs-link"
            href={Formatting.request_logs_path(@cockpit)}
            class="btn btn-ghost btn-xs gap-1.5 text-base-content/65"
          >
            <span class="admin-control-label">{gettext("Request logs")}</span>
            <.icon name="hero-arrow-right" class="size-3" />
          </.link>
        </div>
      </header>

      <div
        :if={!@request_metrics_loaded?}
        id="request-health-state-wrapper"
        class="p-4"
      >
        <AdminComponents.empty_state
          id={
            if @request_metrics_loading?,
              do: "request-health-loading-state",
              else: "request-health-error-state"
          }
          title={
            if @request_metrics_loading?,
              do: gettext("Loading request metrics"),
              else: gettext("Request metrics are not available")
          }
          description={
            if @request_metrics_loading?,
              do: gettext("Building request health and Pool contribution for this account."),
              else: gettext("Refresh the account data to try again.")
          }
          icon={if @request_metrics_loading?, do: "hero-arrow-path", else: "hero-chart-bar"}
          loading?={@request_metrics_loading?}
        />
      </div>

      <div
        :if={@request_metrics_loaded?}
        class="flex flex-wrap gap-x-7 gap-y-2 px-4 pb-1 pt-3"
      >
        <.health_fact
          label={gettext("24h requests")}
          value={@cockpit.charts.request_health.kpis.total_requests_24h}
        />
        <.health_fact
          label={gettext("24h failed")}
          value={@cockpit.charts.request_health.kpis.failed_requests_24h}
        />
        <.health_fact
          id="request-health-client-cancelled"
          label={gettext("24h client cancelled")}
          value={@cockpit.charts.request_health.kpis.client_cancelled_requests_24h}
          title={gettext("Requests the client closed before the response finished; not counted as failures")}
        />
        <.health_fact
          label={gettext("Failure rate")}
          value={@model.failure_rate_label}
          title={gettext("Failed requests over the requests that were not cancelled by the client")}
        />
        <.health_fact
          label={gettext("7d requests")}
          value={@cockpit.charts.request_health.kpis.total_requests_7d}
        />
        <.health_fact
          :if={@model.p50_latency_label}
          label={gettext("p50 latency")}
          value={@model.p50_latency_label}
        />
      </div>

      <div :if={@request_metrics_loaded?} class="p-4 pt-2">
        <div
          id="request-health-chart-plot"
          class="admin-apex-bar-chart min-h-56 w-full"
          phx-hook="ApexTimeSeriesChart"
          phx-update="ignore"
          role="img"
          aria-labelledby="request-health-chart-title request-health-chart-summary"
          data-chart="request-health"
          data-chart-state={@cockpit.charts.request_health.state}
          data-chart-total={@cockpit.charts.request_health.kpis.total_requests_7d}
          data-chart-categories={@model.categories}
          data-chart-series={@model.series}
          data-chart-unit="requests"
          data-chart-units={@model.units}
          data-chart-unit-label={gettext("requests")}
          data-chart-unit-labels={@model.unit_labels}
          data-chart-interval-description={gettext("Showing interval values for each time bucket.")}
          data-chart-cumulative-description={gettext("Showing cumulative running totals through each time bucket.")}
          data-chart-default-series-label={gettext("Value")}
          data-chart-series-label={gettext("Series %{index}", index: "%{index}")}
          data-chart-yaxis={@model.yaxis}
          data-chart-height="220"
          data-chart-colors={@model.colors}
          data-chart-labels="true"
          data-chart-zoom="false"
          data-chart-wheel-scroll="page"
        >
        </div>
        <p id="request-health-chart-title" class="sr-only">{gettext("Request health")}</p>
        <p id="request-health-chart-summary" class="sr-only" data-role="chart-sr-summary">
          {@model.summary}
        </p>
        <ul class="sr-only">
          <li :for={point <- @model.points}>
            {ngettext("%{date}: %{succeeded} succeeded, %{failed} failed, %{cancelled} client cancelled, %{count} total request", "%{date}: %{succeeded} succeeded, %{failed} failed, %{cancelled} client cancelled, %{count} total requests", point.total_count, date: point.label, succeeded: point.success_count, failed: point.failure_count, cancelled: point.client_cancelled_count)}
          </li>
        </ul>
      </div>

      <div
        :if={@request_metrics_loaded? && @model.error_breakdown != []}
        id="request-health-error-breakdown"
        class="border-t border-base-300/60"
      >
        <div
          :for={entry <- @model.error_breakdown}
          data-role="request-error-breakdown-row"
          class="flex items-center justify-between gap-3 border-t border-base-300/45 px-4 py-1.5 text-xs first:border-t-0"
        >
          <span class="min-w-0 truncate text-base-content/65">{entry.label}</span>
          <span class="shrink-0 font-semibold tabular-nums text-base-content/80">
            {entry.count}
          </span>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :title, :string, default: nil

  defp health_fact(assigns) do
    ~H"""
    <div id={@id} class="grid gap-0.5" title={@title}>
      <span class="text-[10px] font-semibold uppercase tracking-[0.08em] text-base-content/40">
        {@label}
      </span>
      <span class="text-base font-semibold tabular-nums leading-tight text-base-content">
        {@value}
      </span>
    </div>
    """
  end

  defp reported_quota_limits(quota_limits) when is_list(quota_limits) do
    Enum.filter(quota_limits, &reported_quota_limit?/1)
  end

  defp reported_quota_limits(_quota_limits), do: []

  defp reported_quota_limit?(%{percent: %Decimal{}}), do: true
  defp reported_quota_limit?(%{reset_label: reset_label}) when is_binary(reset_label), do: true
  defp reported_quota_limit?(%{count_label: count_label}) when is_binary(count_label), do: true
  defp reported_quota_limit?(_limit), do: false

  defp quota_description(%{state: "missing_evidence"}),
    do: gettext("Quota evidence is missing for this account")

  defp quota_description(_quota_health), do: gettext("Account-level windows and the saved-reset bank")

  defp quota_state_label(%{state: "missing_evidence"}), do: gettext("Quota missing")
  defp quota_state_label(%{state: "weekly_only"}), do: gettext("Weekly-only")
  defp quota_state_label(%{state: state}), do: Formatting.humanize_state(state)

  defp policy_tone(%{enabled?: true}), do: :success
  defp policy_tone(_policy), do: :neutral

  defp policy_state_label(%{enabled?: true, trigger_mode: "threshold"}), do: gettext("on · near limit")
  defp policy_state_label(%{enabled?: true}), do: gettext("on · blocked/expiring")
  defp policy_state_label(_policy), do: gettext("off")

  defp form_checkbox_checked?(field) do
    Form.normalize_value("checkbox", field.value)
  end

  defp request_health_chart_model(chart) do
    points = Enum.map(chart.items, &request_health_point/1)
    success_values = Enum.map(points, & &1.success_count)
    failure_values = Enum.map(points, & &1.failure_count)
    client_cancelled_values = Enum.map(points, & &1.client_cancelled_count)

    %{
      points: points,
      categories: CodexPooler.JSON.encode!(Enum.map(points, & &1.label)),
      series:
        CodexPooler.JSON.encode!([
          %{name: gettext("Succeeded"), type: "column", data: success_values},
          %{name: gettext("Failed"), type: "column", data: failure_values},
          %{name: gettext("Client cancelled"), type: "column", data: client_cancelled_values}
        ]),
      units: CodexPooler.JSON.encode!(["requests", "failures", "cancellations"]),
      unit_labels: CodexPooler.JSON.encode!([gettext("requests"), gettext("failures"), gettext("cancellations")]),
      yaxis: CodexPooler.JSON.encode!([%{seriesName: gettext("Succeeded"), title: gettext("requests")}]),
      colors: CodexPooler.JSON.encode!(["var(--color-success)", "var(--color-error)", "var(--color-warning)"]),
      failure_rate_label: rate_percent_label(chart.kpis.failure_rate_24h),
      p50_latency_label: latency_label(chart.kpis.p50_latency_ms_24h),
      error_breakdown: Enum.map(chart.kpis.error_breakdown_24h, &error_breakdown_entry/1),
      summary: ngettext("%{count} request over seven days; %{failed} failed in the last 24h; failure rate %{rate}; %{cancelled} cancelled by the client, not counted as failures.", "%{count} requests over seven days; %{failed} failed in the last 24h; failure rate %{rate}; %{cancelled} cancelled by the client, not counted as failures.", chart.kpis.total_requests_7d || 0, failed: chart.kpis.failed_requests_24h, rate: rate_percent_label(chart.kpis.failure_rate_24h), cancelled: chart.kpis.client_cancelled_requests_24h)
    }
  end

  defp request_health_point(item) do
    %{
      label: chart_date_label(item.date),
      success_count: item.success_count,
      failure_count: item.failure_count,
      client_cancelled_count: item.client_cancelled_count,
      total_count: item.total_count
    }
  end

  defp error_breakdown_entry(entry) do
    label =
      [status_code_label(entry.status_code), entry.error_code]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")
      |> case do
        "" -> gettext("unclassified failure")
        label -> label
      end

    %{label: label, count: entry.count}
  end

  defp status_code_label(nil), do: nil
  defp status_code_label(status_code), do: "HTTP #{status_code}"

  defp latency_label(nil), do: nil
  defp latency_label(ms) when ms >= 10_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp latency_label(ms) when ms >= 1_000, do: "#{Float.round(ms / 1000, 2)}s"
  defp latency_label(ms), do: "#{ms}ms"

  defp rate_percent_label(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 1) <> "%"

  defp rate_percent_label(value) when is_integer(value), do: rate_percent_label(value * 1.0)

  defp chart_date_label(<<_year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2)>>),
    do: month <> "-" <> day

  defp chart_date_label(date), do: to_string(date)
end
