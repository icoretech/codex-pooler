defmodule CodexPoolerWeb.Admin.UpstreamCockpitComponents.Summary do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.AvatarComponents
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.UpstreamCockpitComponents.Formatting

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
      class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100"
    >
      <header class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 bg-base-200/35 px-4 py-3">
        <h2 class="text-base font-semibold leading-5 text-base-content">OAuth activity</h2>
        <span class={AdminBadges.count_chip_class()}>
          {@oauth_flows.pending_count} pending of {@oauth_flows.count}
        </span>
      </header>

      <div class="grid gap-2 p-4 md:grid-cols-2">
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
            <span class={AdminBadges.status_chip_class(flow.status)}>{flow.status}</span>
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

  @doc """
  Credential card: the account rendered as a badge — avatar with a lifecycle
  presence dot, name and status lockup, plan chip, onboarding meta line, and
  a fingerprint band (account hash / subject ref / workspace).
  """
  attr :cockpit, :map, required: true

  def credential_card(assigns) do
    ~H"""
    <section
      id="upstream-cockpit-header"
      aria-label="Account identity"
      class="relative min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100"
    >
      <.icon
        name="hero-key"
        class="pointer-events-none absolute -right-3 bottom-9 size-28 text-base-content/5"
      />
      <div class="relative grid gap-3 px-4 pb-3.5 pt-4">
        <div class="flex items-center gap-3">
          <.cockpit_avatar identity={@cockpit.identity} status={@cockpit.header.status} />
          <div class="min-w-0 flex-1">
            <h1 class="truncate text-xl font-bold leading-tight text-base-content">
              {@cockpit.header.title}
            </h1>
            <p
              id="upstream-cockpit-status"
              class={["mt-0.5 text-xs font-semibold", status_text_class(@cockpit.header.status)]}
            >
              {Formatting.humanize_state(@cockpit.header.status)}
            </p>
          </div>
          <AdminBadges.plan_badge
            :if={@cockpit.header.plan_reported?}
            id="upstream-cockpit-plan-badge"
            label={@cockpit.header.plan_label}
            class="self-start"
          />
        </div>
        <p class="text-xs text-base-content/55">{onboarding_meta(@cockpit.identity)}</p>
      </div>
      <dl class="relative border-t border-base-300/70 bg-base-200/45">
        <.fingerprint_row
          id="upstream-cockpit-safe-account-id"
          icon="hero-finger-print"
          label="account"
          value={fingerprint_value(@cockpit.header.safe_account_id_label)}
          title={@cockpit.header.safe_account_id_label}
        />
        <.fingerprint_row
          id="upstream-cockpit-safe-subject-ref"
          data-role="upstream-subject-ref"
          icon="hero-user"
          label="user"
          value={@cockpit.header.subject_ref}
          title="Sanitized reference to the ChatGPT user behind this credential; it separates credentials that share the same account"
        />
        <.fingerprint_row
          id="upstream-cockpit-workspace"
          icon="hero-briefcase"
          label="workspace"
          value={workspace_value(@cockpit.identity)}
          title={workspace_title(@cockpit.identity)}
        />
      </dl>
    </section>
    """
  end

  attr :identity, :map, required: true
  attr :status, :string, required: true

  defp cockpit_avatar(assigns) do
    ~H"""
    <span class="relative inline-block size-11 shrink-0" aria-hidden="true">
      <img
        :if={@identity.account_email}
        id="upstream-cockpit-avatar"
        src={AvatarComponents.gravatar_url(@identity.account_email, size: 88)}
        alt=""
        loading="lazy"
        referrerpolicy="no-referrer"
        class="size-11 rounded-full bg-base-200 ring-1 ring-base-300"
      />
      <span
        :if={!@identity.account_email}
        id="upstream-cockpit-avatar"
        class="grid size-11 place-items-center rounded-full border border-primary/25 bg-primary/10 text-sm font-extrabold text-primary"
      >
        {monogram(@identity.label)}
      </span>
      <span
        id="upstream-cockpit-presence"
        data-status={@status}
        class={[
          "absolute -bottom-px -right-px size-3 rounded-full border-2 border-base-100",
          presence_class(@status)
        ]}
      ></span>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: nil
  attr :title, :string, default: nil
  attr :rest, :global

  defp fingerprint_row(assigns) do
    ~H"""
    <div
      id={@id}
      title={@title}
      class="flex items-center gap-2.5 border-t border-base-300/45 px-3.5 py-2 first:border-t-0"
      {@rest}
    >
      <.icon name={@icon} class="size-3.5 shrink-0 text-base-content/40" />
      <dt class="w-[4.2rem] shrink-0 text-[10px] font-semibold uppercase tracking-[0.07em] text-base-content/40">
        {@label}
      </dt>
      <dd class={[
        "min-w-0 truncate font-mono text-[11.5px] tracking-wide",
        (@value && "text-base-content/75") || "text-base-content/40"
      ]}>
        {@value || "–"}
      </dd>
    </div>
    """
  end

  @doc """
  Vitals: credential and evidence freshness — the facts an operator checks
  before deciding whether recovery is needed.
  """
  attr :cockpit, :map, required: true

  def vitals_card(assigns) do
    assigns = assign(assigns, :rows, vitals_rows(assigns.cockpit))

    ~H"""
    <section
      id="upstream-status-summary"
      aria-label="Credential and evidence vitals"
      class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100"
    >
      <header class="border-b border-base-300 bg-base-200/35 px-4 py-3">
        <h2 class="text-base font-semibold leading-5 text-base-content">Vitals</h2>
        <p class="text-xs leading-5 text-base-content/60">Credential &amp; evidence freshness</p>
      </header>
      <dl>
        <div
          :for={row <- @rows}
          id={row.id}
          class="flex items-baseline justify-between gap-3 border-t border-base-300/50 px-4 py-2 text-xs first:border-t-0"
        >
          <dt class="shrink-0 text-base-content/55">{row.label}</dt>
          <dd class={["min-w-0 truncate text-right font-semibold tabular-nums", row.class]}>
            {row.value}
          </dd>
        </div>
      </dl>
    </section>
    """
  end

  defp vitals_rows(cockpit) do
    header = cockpit.header
    observability = header.identity_observability

    [
      %{
        id: "upstream-vitals-access-token",
        label: "Access token",
        value: Formatting.strip_label_prefix(header.access_token_label, "access token "),
        class: access_token_class(header.access_token_label)
      },
      %{
        id: "upstream-vitals-token-refresh",
        label: "Token refresh",
        value: Formatting.strip_label_prefix(header.token_refresh_label, "token refresh "),
        class: refresh_status_class(header.refresh_status)
      },
      %{
        id: "upstream-vitals-auth-verified",
        label: "Auth verified",
        value: Formatting.strip_label_prefix(header.auth_verified_label, "auth verified "),
        class: "text-base-content/80"
      },
      %{
        id: "upstream-vitals-quota-refresh",
        label: "Quota refresh",
        value: Formatting.status_text(header.quota_refresh_status),
        class: refresh_status_class(header.quota_refresh_status)
      },
      quota_evidence_row(observability),
      reconciliation_row(observability)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp quota_evidence_row(%{quota_evidence_age: age}) when is_binary(age) and age != "" do
    %{
      id: "upstream-vitals-quota-evidence",
      label: "Quota evidence",
      value: age,
      class: "text-base-content/80"
    }
  end

  defp quota_evidence_row(_observability) do
    %{
      id: "upstream-vitals-quota-evidence",
      label: "Quota evidence",
      value: "not reported",
      class: "text-base-content/45"
    }
  end

  defp reconciliation_row(%{reconciliation: %{status: status, message: message} = reconciliation})
       when is_binary(status) do
    value =
      [message || Formatting.status_text(status), reconciliation_age(reconciliation)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    %{
      id: "upstream-vitals-reconciliation",
      label: "Reconciliation",
      value: value,
      class: reconciliation_class(status)
    }
  end

  defp reconciliation_row(_observability), do: nil

  defp reconciliation_age(%{attempt_age: age}) when is_binary(age) and age != "", do: age
  defp reconciliation_age(_reconciliation), do: nil

  defp reconciliation_class("succeeded"), do: "text-success"
  defp reconciliation_class("failed"), do: "text-error"
  defp reconciliation_class(_status), do: "text-warning"

  defp access_token_class(label) when is_binary(label) do
    if String.contains?(label, "expired"), do: "text-error", else: "text-base-content/80"
  end

  defp access_token_class(_label), do: "text-base-content/80"

  defp refresh_status_class(status) when status in ["succeeded", "imported"], do: "text-success"
  defp refresh_status_class("refreshing"), do: "text-info"
  defp refresh_status_class(status) when status in ["failed", "errored"], do: "text-error"
  defp refresh_status_class(_status), do: "text-base-content/80"

  defp status_text_class("active"), do: "text-success"

  defp status_text_class(status) when status in ["refresh_failed", "reauth_required", "errored"],
    do: "text-error"

  defp status_text_class(_status), do: "text-warning"

  defp presence_class("active"), do: "bg-success"

  defp presence_class(status) when status in ["refresh_failed", "reauth_required", "errored"],
    do: "bg-error"

  defp presence_class(_status), do: "bg-warning"

  defp monogram(label) when is_binary(label) and label != "" do
    label
    |> String.trim()
    |> String.slice(0, 2)
    |> String.upcase()
  end

  defp monogram(_label), do: "?"

  defp onboarding_meta(identity) do
    ["linked via #{onboarding_method_label(identity.onboarding_method)}"]
    |> Enum.join(" · ")
  end

  defp onboarding_method_label("browser"), do: "OAuth (browser)"
  defp onboarding_method_label("device"), do: "OAuth (device code)"
  defp onboarding_method_label("import"), do: "auth.json import"
  defp onboarding_method_label("invite"), do: "invite"
  defp onboarding_method_label(_method), do: "unreported onboarding"

  defp fingerprint_value("stored account id " <> rest), do: rest
  defp fingerprint_value(_label), do: nil

  defp workspace_value(%{workspace_label: label}) when is_binary(label) and label != "", do: label

  defp workspace_value(%{workspace_ref: ref}) when is_binary(ref) and ref not in ["", "legacy"],
    do: ref

  defp workspace_value(_identity), do: nil

  defp workspace_title(%{workspace_ref: ref}) when is_binary(ref) and ref not in ["", "legacy"],
    do: "Workspace reference #{ref}"

  defp workspace_title(_identity), do: "Workspace reference, when the account reports one"
end
