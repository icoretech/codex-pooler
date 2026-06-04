defmodule CodexPoolerWeb.OnboardingLive.Invite.Components do
  @moduledoc """
  Presentation components for public invite onboarding.
  """

  use CodexPoolerWeb, :html

  attr :flash, :map, required: true
  attr :current_scope, :any, required: true
  attr :contract, :any, required: true
  attr :device_authorization, :any, required: true
  attr :device_polling?, :boolean, required: true
  attr :device_poll_status, :string, required: true
  attr :completed_onboarding, :any, required: true
  attr :invite_state, :atom, required: true
  attr :error_message, :any, required: true

  def invite_page(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} chrome={:invite}>
      <section class="mx-auto grid min-h-[calc(100svh-4rem)] w-full max-w-6xl items-center px-4 py-8 sm:px-6 lg:px-8">
        <div
          id="invite-page"
          class="grid overflow-hidden rounded-box border border-base-300 bg-base-100 shadow-sm lg:grid-cols-[minmax(0,0.95fr)_minmax(0,1.05fr)]"
        >
          <div class="grid content-between gap-8 border-b border-base-300 bg-base-200/60 p-6 sm:p-8 lg:border-b-0 lg:border-r">
            <div class="space-y-4">
              <p class="font-mono text-xs font-semibold uppercase tracking-[0.2em] text-primary">
                device onboarding
              </p>
              <h1 class="max-w-md text-3xl font-bold uppercase text-primary sm:text-4xl">
                Connect your Codex account
              </h1>
              <p class="max-w-md text-sm leading-6 text-base-content/70">
                Approve this invite with the OpenAI device page. Codex Pooler stores only the account connection metadata needed for the selected Pool.
              </p>
            </div>
          </div>

          <div class="p-6 sm:p-8">
            <div :if={@contract} id="invite-metadata" class="grid gap-6">
              <div id="invite-contract" class="contents">
                <div class="space-y-2">
                  <h2 class="text-xl font-semibold text-base-content">Invite details</h2>
                  <p class="text-sm leading-6 text-base-content/70">
                    Confirm the inviter and target email before starting the device approval.
                  </p>
                </div>

                <div class="rounded-box border border-base-300 bg-base-200/40 p-4">
                  <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                    Target Pool
                  </p>
                  <p id="invite-pool-name" class="mt-1 text-lg font-semibold text-base-content">
                    {@contract.pool_name}
                  </p>
                </div>

                <dl class="grid gap-3 sm:grid-cols-2">
                  <div class="rounded-box border border-base-300 bg-base-100 p-4">
                    <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Invited by
                    </dt>
                    <dd id="invite-inviter" class="mt-2 font-semibold text-base-content">
                      {@contract.inviter_label}
                    </dd>
                  </div>
                  <div class="rounded-box border border-base-300 bg-base-100 p-4">
                    <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Invited email
                    </dt>
                    <dd id="invite-invited-email" class="mt-2 font-semibold text-base-content">
                      {invited_email_label(@contract.invited_email)}
                    </dd>
                  </div>
                  <div class="rounded-box border border-base-300 bg-base-100 p-4">
                    <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Invite status
                    </dt>
                    <dd id="invite-status" class="mt-2 font-semibold text-base-content">
                      {invite_status_label(@contract.status)}
                    </dd>
                  </div>
                  <div class="rounded-box border border-base-300 bg-base-100 p-4">
                    <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                      Expires
                    </dt>
                    <dd id="invite-expiry-countdown" class="mt-2 font-semibold text-base-content">
                      {expiry_countdown(@contract.expires_at)}
                    </dd>
                  </div>
                </dl>

                <div id="onboarding-actions" class="grid gap-3">
                  <button
                    id="device-onboarding-button"
                    type="button"
                    class="btn btn-primary w-full gap-2 sm:w-fit"
                    phx-click="start_device"
                    phx-disable-with="Starting device approval..."
                  >
                    <.icon name="hero-device-phone-mobile" class="size-4" />
                    <span>Start device approval</span>
                  </button>
                  <p class="text-sm leading-6 text-base-content/65">
                    Keep this page open after entering the code. It will continue automatically when approval is complete.
                  </p>
                </div>

                <div
                  :if={@device_authorization}
                  id="device-authorization"
                  class="rounded-box border border-base-300 bg-base-100 p-4"
                >
                  <div class="grid gap-4">
                    <div class="min-w-0">
                      <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                        Device code
                      </p>
                      <div class="mt-2 flex items-center gap-2">
                        <p
                          id="device-user-code"
                          class="font-mono text-3xl font-bold tracking-tight text-base-content"
                        >
                          {@device_authorization.user_code}
                        </p>
                        <button
                          id="invite-device-code-copy"
                          type="button"
                          class="btn btn-secondary btn-outline btn-square btn-sm shrink-0"
                          aria-label="Copy device code"
                          phx-hook="ClipboardCopy"
                          data-copy-text={@device_authorization.user_code}
                        >
                          <.icon name="hero-clipboard-document" class="copy-icon size-4" />
                        </button>
                      </div>
                    </div>

                    <div class="grid gap-2">
                      <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                        Verification page
                      </p>
                      <.link
                        id="device-verification-url"
                        href={@device_authorization.url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="link text-sm break-all"
                      >
                        {@device_authorization.url}
                      </.link>
                    </div>

                    <div
                      id="device-poll-status"
                      class="flex min-h-12 items-center gap-3 rounded-box border border-base-300 bg-base-200/50 px-3 py-2 text-sm text-base-content/70"
                      role="status"
                      aria-live="polite"
                    >
                      <span
                        :if={@device_polling?}
                        id="device-poll-spinner"
                        class="loading loading-spinner loading-sm shrink-0 text-primary"
                        aria-hidden="true"
                      />
                      <span>{@device_poll_status}</span>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <div
              :if={@completed_onboarding}
              id="invite-accepted"
              class="grid gap-5 rounded-box border border-success/30 bg-success/10 p-5 text-base-content shadow-sm"
            >
              <div class="flex items-start gap-3">
                <span class="grid size-10 shrink-0 place-items-center rounded-box bg-success/15 text-success">
                  <.icon name="hero-check-circle" class="size-6" />
                </span>
                <div class="grid gap-1">
                  <p class="text-lg font-semibold">Codex account connected</p>
                  <p id="completed-account-email" class="text-sm leading-6 text-base-content/75">
                    {@completed_onboarding.account_email || "Account verified"}
                  </p>
                  <p class="text-sm leading-6 text-base-content/70">
                    The upstream account is linked. Configure Codex with this load-balancer endpoint and your Pooler API key.
                  </p>
                </div>
              </div>

              <div id="invite-config-panel" class="rounded-box border border-base-300 bg-base-100 p-4">
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <div>
                    <p class="text-xs font-semibold uppercase tracking-wide text-primary">
                      Codex config.toml
                    </p>
                    <p class="mt-1 text-sm text-base-content/65">
                      Store the API key in <code>CODEX_POOLER_API_KEY</code>; it is not embedded here.
                    </p>
                  </div>
                  <button
                    id="invite-config-copy"
                    type="button"
                    class="btn btn-primary btn-sm gap-2"
                    phx-hook="ClipboardCopy"
                    data-copy-text={@completed_onboarding.config_text}
                    data-copy-label="Copy config"
                    data-copied-label="Copied"
                  >
                    <.icon name="hero-clipboard-document" class="copy-icon size-4" />
                    <span data-copy-label>Copy config</span>
                  </button>
                </div>
                <pre
                  id="invite-config-toml"
                  class="mt-4 overflow-x-auto rounded-box bg-base-200 p-3 text-xs leading-5 text-base-content"
                ><code>{@completed_onboarding.config_text}</code></pre>
              </div>
            </div>

            <div
              :if={@invite_state == :expired}
              id="invite-expired"
              class="alert alert-warning items-start"
            >
              <.icon name="hero-clock" class="mt-0.5 size-5" />
              <div>
                <p class="font-semibold">Invite expired</p>
                <p class="text-sm leading-6">
                  This invite expired before onboarding completed. Ask the operator for a fresh invite.
                </p>
              </div>
            </div>

            <div :if={@error_message} id="invite-error" class="alert alert-error items-start">
              <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5" />
              <div>
                <p class="font-semibold">Invite unavailable</p>
                <p class="text-sm leading-6">{@error_message}</p>
              </div>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp invited_email_label(email) when is_binary(email) and email != "", do: email
  defp invited_email_label(_email), do: "Codex account email required"

  defp invite_status_label("active"), do: "Active invite"
  defp invite_status_label(status) when is_binary(status), do: String.capitalize(status)
  defp invite_status_label(_status), do: "Unknown"

  defp expiry_countdown(nil), do: "No expiry date"

  defp expiry_countdown(expires_at) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, expires_at, _offset} -> expiry_countdown(expires_at)
      _error -> "Expiry unavailable"
    end
  end

  defp expiry_countdown(%DateTime{} = expires_at) do
    seconds = DateTime.diff(expires_at, DateTime.utc_now(), :second)

    cond do
      seconds <= 0 -> "Expired"
      seconds < 60 -> "Expires in under 1 minute"
      seconds < 3_600 -> "Expires in #{ceil_div(seconds, 60)} minutes"
      seconds < 86_400 -> "Expires in #{ceil_div(seconds, 3_600)} hours"
      true -> "Expires in #{ceil_div(seconds, 86_400)} days"
    end
  end

  defp ceil_div(value, unit), do: div(value + unit - 1, unit)
end
