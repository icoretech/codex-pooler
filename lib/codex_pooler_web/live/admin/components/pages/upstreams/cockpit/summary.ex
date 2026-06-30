defmodule CodexPoolerWeb.Admin.UpstreamCockpitComponents.Summary do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.UpstreamCockpitComponents.Formatting
  alias CodexPoolerWeb.DateTimeDisplay

  def cockpit_navigation(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-3">
      <.link
        id="upstream-cockpit-back-link"
        navigate={~p"/admin/upstreams"}
        class="btn btn-ghost btn-sm gap-2"
      >
        <.icon name="hero-arrow-left" class="size-4" />
        <span>Upstreams</span>
      </.link>
    </div>
    """
  end

  attr :cockpit, :map, required: true
  attr :datetime_preferences, :map, required: true

  def oauth_flow_state(assigns) do
    assigns = assign(assigns, :oauth_flows, assigns.cockpit.oauth_flows)

    ~H"""
    <section
      :if={!@oauth_flows.empty?}
      id="upstream-cockpit-oauth-flow-state"
      class="grid gap-3 border-y border-base-300 bg-base-100/60 py-4"
    >
      <div>
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
          OAuth activity
        </h2>
        <p class="text-xs text-base-content/60">
          {@oauth_flows.pending_count} pending of {@oauth_flows.count}
        </p>
      </div>

      <div class="grid gap-2 md:grid-cols-2">
        <article
          :for={flow <- @oauth_flows.items}
          id={"upstream-cockpit-oauth-flow-#{flow.id}"}
          data-flow-kind={flow.flow_kind}
          data-flow-status={flow.status}
          class="grid gap-2 rounded-lg border border-base-300 bg-base-100 p-4"
        >
          <div class="flex flex-wrap items-start justify-between gap-2">
            <div class="min-w-0">
              <p class="font-medium text-base-content">{flow.status_label}</p>
              <p class="text-xs text-base-content/60">
                {flow.flow_kind} · {flow.purpose}
              </p>
            </div>
            <span class="badge badge-outline badge-sm">{flow.status}</span>
          </div>

          <dl class="grid gap-1 text-xs text-base-content/70">
            <div>
              <dt class="sr-only">Expires</dt>
              <dd>
                expires {Formatting.format_oauth_flow_time(flow.expires_at, @datetime_preferences)}
              </dd>
            </div>
            <div :if={flow.poll_after_at}>
              <dt class="sr-only">Next poll</dt>
              <dd>
                next poll {Formatting.format_oauth_flow_time(
                  flow.poll_after_at,
                  @datetime_preferences
                )}
              </dd>
            </div>
            <div :if={flow.device}>
              <dt class="sr-only">Device code</dt>
              <dd>device code {flow.device.user_code}</dd>
            </div>
            <div :if={flow.device && flow.device.verification_uri}>
              <dt class="sr-only">Verification URL</dt>
              <dd>
                <a
                  href={flow.device.verification_uri}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="link link-primary break-all"
                >
                  {flow.device.verification_uri}
                </a>
              </dd>
            </div>
            <div :if={flow.error}>
              <dt class="sr-only">Error</dt>
              <dd>{flow.error.message || flow.error.code}</dd>
            </div>
            <div :if={flow.result_identity}>
              <dt class="sr-only">Completed identity</dt>
              <dd>{flow.result_identity.label}</dd>
            </div>
          </dl>
        </article>
      </div>
    </section>
    """
  end

  attr :cockpit, :map, required: true

  def identity_summary(assigns) do
    ~H"""
    <AdminComponents.page_header
      id="upstream-cockpit-header"
      eyebrow="Upstream cockpit"
      title={@cockpit.header.title}
      description="Identity-scoped operational cockpit with redacted account state, assignment posture, chart placeholders, recent event summary, and safe cross-links."
    >
      <:actions>
        <span
          id="upstream-cockpit-safe-account-id"
          class="badge badge-outline max-w-full break-all font-mono"
        >
          {@cockpit.header.safe_account_id_label}
        </span>
        <span
          :if={@cockpit.header.subject_ref}
          id="upstream-cockpit-safe-subject-ref"
          data-role="upstream-subject-ref"
          class="badge badge-outline max-w-full break-all font-mono"
        >
          Subject {@cockpit.header.subject_ref}
        </span>
        <span class={Formatting.status_badge_class(@cockpit.header.status)}>
          {@cockpit.header.status_label}
        </span>
        <span :if={@cockpit.header.plan_reported?} class="badge badge-outline">
          {@cockpit.header.plan_label}
        </span>
      </:actions>
    </AdminComponents.page_header>
    """
  end

  attr :cockpit, :map, required: true
  attr :datetime_preferences, :map, required: true

  def status_summary(assigns) do
    assigns =
      assign(
        assigns,
        :cockpit,
        with_saved_reset_expiration_label(assigns.cockpit, assigns.datetime_preferences)
      )

    ~H"""
    <AdminComponents.metric_strip id="upstream-status-summary" compact_mobile={true}>
      <AdminComponents.metric_card
        id="upstream-status-summary-identity"
        icon="hero-signal"
        label="Identity state"
        value={identity_state_label(@cockpit)}
        description={@cockpit.header.safe_account_id_label}
        tone={identity_state_tone(@cockpit)}
        compact_mobile={true}
      />
      <AdminComponents.metric_card
        id="upstream-status-summary-quota"
        icon="hero-chart-bar-square"
        label="Quota posture"
        value={quota_summary_label(@cockpit.charts.quota_health)}
        description={quota_summary_description(@cockpit.charts.quota_health)}
        tone={quota_summary_tone(@cockpit.charts.quota_health)}
        compact_mobile={true}
      />
      <AdminComponents.metric_card
        id="upstream-status-summary-saved-resets"
        icon="hero-arrow-path"
        label="Saved resets"
        value={@cockpit.saved_resets.label}
        description={
          saved_reset_summary_description(@cockpit.saved_resets, @cockpit.saved_reset_policy)
        }
        tone={saved_reset_summary_tone(@cockpit.saved_resets)}
        compact_mobile={true}
      />
      <AdminComponents.metric_card
        id="upstream-status-summary-requests"
        icon="hero-arrow-path-rounded-square"
        label="Request posture"
        value={request_summary_label(@cockpit.charts.request_health)}
        description={request_summary_description(@cockpit.charts.request_health)}
        tone={request_summary_tone(@cockpit.charts.request_health)}
        compact_mobile={true}
      />
      <div
        id="upstream-status-summary-details"
        class="col-span-full flex min-w-0 flex-wrap gap-2 rounded-box border border-base-300 bg-base-100 p-3"
      >
        <span
          :for={detail <- status_summary_details(@cockpit)}
          id={detail.id}
          class={detail.class}
        >
          {detail.label}
        </span>
      </div>
    </AdminComponents.metric_strip>
    """
  end

  attr :cockpit, :map, required: true

  defp identity_state_label(%{flags: %{disabled_identity?: true}}), do: "Identity disabled"
  defp identity_state_label(%{flags: %{reauth_required?: true}}), do: "Reauth required"
  defp identity_state_label(%{header: %{status: "active"}}), do: "Identity active"

  defp identity_state_label(%{header: %{status: status}}),
    do: Formatting.status_label("Identity", status)

  defp identity_state_tone(%{flags: %{disabled_identity?: true}}), do: :warning
  defp identity_state_tone(%{flags: %{reauth_required?: true}}), do: :error
  defp identity_state_tone(%{header: %{status: status}}) when status in ["active"], do: :success
  defp identity_state_tone(_cockpit), do: :warning

  defp status_summary_details(cockpit) do
    [
      detail("identity-detail", identity_state_label(cockpit), cockpit.header.status),
      optional_detail("plan", plan_status_label(cockpit), "active"),
      detail(
        "auth-verified",
        auth_verified_summary_label(cockpit.header.auth_verified_label),
        "active"
      ),
      detail("access-token", cockpit.header.access_token_label, token_detail_status(cockpit)),
      detail("token-refresh", cockpit.header.token_refresh_label, cockpit.header.refresh_status),
      detail("quota-refresh", "Quota refresh #{cockpit.header.quota_refresh_status}", "active"),
      detail(
        "quota-state-detail",
        quota_status_detail_label(cockpit.charts.quota_health),
        cockpit.charts.quota_health.state
      ),
      optional_detail(
        "saved-reset-expiration",
        Map.get(cockpit.saved_resets, :next_expires_label),
        "active"
      ),
      optional_detail("reauth-code", cockpit.header.reauth_reason_code, "reauth_required"),
      optional_detail("reauth-message", cockpit.header.reauth_reason_message, "reauth_required")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp detail(id, label, status) do
    %{
      id: "upstream-status-summary-#{id}",
      label: label,
      class: Formatting.assignment_status_class(status)
    }
  end

  defp optional_detail(_id, nil, _status), do: nil
  defp optional_detail(_id, "", _status), do: nil
  defp optional_detail(id, label, status), do: detail(id, label, status)

  defp with_saved_reset_expiration_label(cockpit, datetime_preferences) do
    saved_resets =
      Map.put_new(
        cockpit.saved_resets,
        :next_expires_label,
        saved_reset_next_expires_label(cockpit.saved_resets, datetime_preferences)
      )

    Map.put(cockpit, :saved_resets, saved_resets)
  end

  defp saved_reset_next_expires_label(%{next_expires_at: expires_at}, datetime_preferences) do
    case parse_datetime(expires_at) do
      %DateTime{} = datetime ->
        "Next expires " <> DateTimeDisplay.format_datetime(datetime, datetime_preferences)

      nil ->
        nil
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _invalid -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp plan_status_label(%{header: %{plan_reported?: true, plan_label: plan_label}}),
    do: "Plan #{plan_label}"

  defp plan_status_label(_cockpit), do: nil

  defp token_detail_status(%{header: %{access_token_label: label}}) do
    if String.contains?(label, "expired"), do: "expired", else: "active"
  end

  defp auth_verified_summary_label("auth verified not reported"), do: "Never verified"
  defp auth_verified_summary_label(label), do: sentence_label(label)

  defp sentence_label(label) when is_binary(label) do
    case String.split_at(label, 1) do
      {first, rest} -> String.upcase(first) <> rest
    end
  end

  defp sentence_label(label), do: label

  defp quota_status_detail_label(%{state: "missing_evidence"}), do: "Quota missing"
  defp quota_status_detail_label(%{state: "stale"}), do: "Quota refresh needed"
  defp quota_status_detail_label(%{state: state}), do: Formatting.status_label("Quota", state)

  defp quota_summary_label(%{state: "missing_evidence"}), do: "Quota evidence is missing"
  defp quota_summary_label(%{state: "weekly_only"}), do: "Weekly-only quota"
  defp quota_summary_label(%{state: state}), do: Formatting.humanize_state(state)

  defp quota_summary_description(%{kpis: kpis}) do
    "#{kpis.routing_usable_count} routing usable, #{kpis.stale_or_missing_count} stale or missing"
  end

  defp quota_summary_tone(%{missing?: true}), do: :warning
  defp quota_summary_tone(%{degraded?: true}), do: :warning
  defp quota_summary_tone(_quota), do: :success

  defp saved_reset_summary_description(saved_resets, policy) do
    [
      saved_reset_policy_description(policy),
      saved_reset_next_expires_description(saved_resets)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp saved_reset_policy_description(%{
         enabled?: true,
         trigger_mode: "threshold",
         keep_credits: keep_credits,
         quota_threshold_percent: threshold
       }),
       do: "Auto redeem on · near #{threshold}% · keep #{keep_credits}"

  defp saved_reset_policy_description(%{enabled?: true, keep_credits: keep_credits}),
    do: "Auto redeem on · blocked/expiring · keep #{keep_credits}"

  defp saved_reset_policy_description(_policy), do: "Auto redeem off"

  defp saved_reset_next_expires_description(%{next_expires_label: label}) when is_binary(label),
    do: label

  defp saved_reset_next_expires_description(_saved_resets), do: nil

  defp saved_reset_summary_tone(%{available?: true}), do: :success
  defp saved_reset_summary_tone(%{reported?: true}), do: :neutral
  defp saved_reset_summary_tone(_saved_resets), do: :warning

  defp request_summary_label(%{state: "empty"}), do: "No request traffic"
  defp request_summary_label(%{state: state}), do: Formatting.humanize_state(state)

  defp request_summary_description(%{kpis: kpis}) do
    "#{kpis.total_requests_24h} requests and #{kpis.failed_requests_24h} failures in 24h"
  end

  defp request_summary_tone(%{state: "failed"}), do: :error
  defp request_summary_tone(%{degraded?: true}), do: :warning
  defp request_summary_tone(_request_health), do: :success
end
