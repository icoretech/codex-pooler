defmodule CodexPoolerWeb.Admin.SettingsPageComponents.Security do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.DateTimeDisplay

  attr :totp_enabled?, :boolean, required: true
  attr :totp_setup, :map, default: nil
  attr :current_scope, :any, required: true
  attr :datetime_preferences, :map, required: true
  attr :password_form, :any, required: true
  attr :browser_sessions, :list, required: true

  def panel(assigns) do
    ~H"""
    <section id="settings-security-panel" class="grid gap-4">
      <.totp_panel
        current_scope={@current_scope}
        totp_enabled?={@totp_enabled?}
        totp_setup={@totp_setup}
      />
      <.password_panel password_form={@password_form} />
      <.browser_sessions_panel
        browser_sessions={@browser_sessions}
        datetime_preferences={@datetime_preferences}
      />
    </section>
    """
  end

  attr :totp_enabled?, :boolean, required: true
  attr :totp_setup, :map, default: nil
  attr :current_scope, :any, required: true

  defp totp_panel(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm">
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="grid gap-2">
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
            Second factor
          </p>
          <h3 class="text-xl font-semibold text-base-content">Authenticator app</h3>
          <p id="settings-totp-status" class="text-sm leading-6 text-base-content/65">
            {if @totp_enabled?,
              do: "TOTP enabled",
              else: "TOTP not set up"}
          </p>
        </div>
        <AdminComponents.action_button
          :if={!@totp_enabled?}
          id="settings-enable-totp"
          icon="hero-shield-check"
          label="Set up TOTP"
          phx-click="enable_totp"
          variant={:primary}
        />
      </div>

      <div
        :if={@totp_setup}
        id="settings-totp-setup-result"
        class="mt-5 grid gap-4 rounded-box border border-warning/25 bg-warning/10 p-4 lg:grid-cols-[13rem_minmax(0,1fr)]"
      >
        <div
          id="settings-totp-setup-tools"
          class="grid content-start gap-3"
          phx-hook="TotpSetupTools"
          data-otpauth-uri={totp_otpauth_uri(@totp_setup, @current_scope.user)}
        >
          <div class="rounded-box border border-base-300 bg-base-100 p-3">
            <div
              id="settings-totp-qr"
              data-totp-qr
              data-qr-size="176"
              class="size-44"
            >
            </div>
          </div>
          <button
            id="settings-totp-secret-copy"
            type="button"
            class="btn btn-secondary btn-sm gap-2"
            phx-hook="ClipboardCopy"
            data-copy-text={@totp_setup.secret}
            data-copy-label="Copy secret"
            data-copied-label="Copied"
          >
            <.icon name="hero-clipboard-document" class="copy-icon size-4" />
            <span data-copy-label>Copy secret</span>
          </button>
        </div>
        <div class="grid min-w-0 gap-4">
          <div class="grid gap-1">
            <p class="font-semibold text-base-content">Save these details now</p>
            <p class="text-sm leading-6 text-base-content/70">
              Scan the QR code, copy the secret if scanning is not available, then download the recovery codes.
            </p>
          </div>
          <code
            id="settings-totp-secret"
            class="break-all rounded-box border border-base-300 bg-base-100 p-3 font-mono text-sm"
          >
            {@totp_setup.secret}
          </code>
          <div class="flex flex-wrap items-center justify-between gap-2">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
              Recovery codes
            </p>
            <div class="flex flex-wrap gap-2">
              <button
                id="settings-totp-recovery-copy"
                type="button"
                class="btn btn-secondary btn-sm gap-2"
                phx-hook="ClipboardCopy"
                data-copy-text={recovery_codes_text(@totp_setup)}
                data-copy-label="Copy codes"
                data-copied-label="Copied"
              >
                <.icon name="hero-clipboard-document" class="copy-icon size-4" />
                <span data-copy-label>Copy codes</span>
              </button>
              <a
                id="settings-totp-recovery-download"
                class="btn btn-secondary btn-sm gap-2"
                href={recovery_codes_data_uri(@totp_setup)}
                download="codex-pooler-recovery-codes.txt"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" />
                <span>Download</span>
              </a>
            </div>
          </div>
          <ul id="settings-totp-recovery-codes" class="grid gap-1 sm:grid-cols-2">
            <li
              :for={code <- @totp_setup.recovery_codes}
              class="rounded border border-base-300 bg-base-100 px-3 py-2 font-mono text-xs"
            >
              {code}
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :password_form, :any, required: true

  defp password_panel(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-4 shadow-sm">
      <.form
        id="settings-password-form"
        for={@password_form}
        phx-submit="save_password"
        autocomplete="off"
        class="grid gap-4"
      >
        <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,2fr)]">
          <div>
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
              Password
            </p>
            <h3 class="mt-1 text-xl font-semibold text-base-content">Change password</h3>
            <p class="mt-1 text-sm leading-6 text-base-content/65">
              Enter your current password and choose the password you will use next.
            </p>
          </div>
          <div class="grid gap-4 md:grid-cols-3">
            <.input
              id="settings-current-password"
              field={@password_form[:current_password]}
              type="password"
              label="Current password"
              autocomplete="current-password"
              required
            />
            <.input
              id="settings-new-password"
              field={@password_form[:new_password]}
              type="password"
              label="New password"
              autocomplete="new-password"
              required
            />
            <.input
              id="settings-new-password-confirmation"
              field={@password_form[:new_password_confirmation]}
              type="password"
              label="Confirm new password"
              autocomplete="new-password"
              required
            />
          </div>
        </div>
        <div class="flex justify-end border-t border-base-300 pt-4">
          <AdminComponents.action_button
            id="settings-password-submit"
            icon="hero-lock-closed"
            label="Update password"
            type="submit"
            variant={:primary}
          />
        </div>
      </.form>
    </div>
    """
  end

  attr :browser_sessions, :list, required: true
  attr :datetime_preferences, :map, required: true

  defp browser_sessions_panel(assigns) do
    ~H"""
    <div
      id="settings-session-panel"
      class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm"
    >
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="grid gap-2">
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
            Sessions
          </p>
          <h3 class="text-xl font-semibold text-base-content">Browser sessions</h3>
          <p class="text-sm leading-6 text-base-content/65">
            Review active browser sessions for this operator account.
          </p>
        </div>
        <AdminComponents.action_button
          id="settings-logout-other-sessions"
          icon="hero-arrow-left-start-on-rectangle"
          label="Log out other sessions"
          phx-click="logout_other_sessions"
          disabled={other_session_count(@browser_sessions) == 0}
          variant={:secondary}
        />
      </div>

      <ul id="settings-session-list" class="mt-5 grid gap-2">
        <li
          :for={session <- @browser_sessions}
          id={"settings-session-#{session.id}"}
          data-session-device={session_device(session)}
          class="grid min-w-0 gap-3 rounded-box border border-base-300 bg-base-100 p-4 md:grid-cols-[12rem_minmax(0,1fr)_auto]"
        >
          <div class="flex min-w-0 items-center gap-3">
            <span class="grid size-9 shrink-0 place-items-center rounded-field bg-base-200 text-base-content/70">
              <.icon name={session_icon(session)} class="size-5" />
            </span>
            <div class="min-w-0">
              <p class="truncate font-semibold leading-5 text-base-content">
                {session_title(session)}
              </p>
              <span
                :if={session.current?}
                id="settings-current-session-badge"
                class="badge badge-primary badge-sm mt-1"
              >
                This session
              </span>
            </div>
          </div>
          <div class="grid min-w-0 content-center gap-1">
            <p
              id={"settings-session-user-agent-#{session.id}"}
              class="truncate text-sm leading-5 text-base-content/65"
            >
              {user_agent_label(session.user_agent)}
            </p>
            <p class="text-xs leading-5 text-base-content/50">
              IP {ip_address_label(session.ip_address)} · Created {datetime_label(
                session.created_at,
                @datetime_preferences
              )} · Last seen {datetime_label(session.last_seen_at, @datetime_preferences)} · Expires {datetime_label(
                session.expires_at,
                @datetime_preferences
              )}
            </p>
          </div>
          <button
            id={"settings-session-revoke-#{session.id}"}
            type="button"
            class="btn btn-secondary btn-sm gap-2 md:self-center"
            phx-click="logout_session"
            phx-value-id={session.id}
          >
            <.icon name="hero-arrow-left-start-on-rectangle" class="size-4" />
            <span>Sign out</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp totp_otpauth_uri(%{secret: secret}, user) when is_binary(secret) do
    label =
      ["Codex Pooler", user.email || "operator"]
      |> Enum.join(":")
      |> URI.encode(&URI.char_unreserved?/1)

    query =
      URI.encode_query(%{
        secret: secret,
        issuer: "Codex Pooler",
        algorithm: "SHA1",
        digits: "6",
        period: "30"
      })

    "otpauth://totp/#{label}?#{query}"
  end

  defp recovery_codes_text(%{recovery_codes: codes}) when is_list(codes) do
    Enum.join(codes, "\n") <> "\n"
  end

  defp recovery_codes_data_uri(setup) do
    "data:text/plain;charset=utf-8,#{URI.encode(recovery_codes_text(setup))}"
  end

  defp other_session_count(sessions), do: Enum.count(sessions, &(not &1.current?))

  defp session_icon(session) do
    case session_device(session) do
      "mobile" -> "hero-device-phone-mobile"
      "tablet" -> "hero-device-tablet"
      _device -> "hero-computer-desktop"
    end
  end

  defp session_device(%{user_agent: user_agent}) when is_binary(user_agent) do
    user_agent = String.downcase(user_agent)

    cond do
      String.contains?(user_agent, ["ipad", "tablet"]) -> "tablet"
      String.contains?(user_agent, ["mobile", "iphone", "android"]) -> "mobile"
      true -> "desktop"
    end
  end

  defp session_device(_session), do: "desktop"

  defp session_title(%{current?: true}), do: "Current browser"
  defp session_title(_session), do: "Browser session"

  defp user_agent_label(user_agent) when is_binary(user_agent) and user_agent != "",
    do: user_agent

  defp user_agent_label(_user_agent), do: "Unknown browser"

  defp ip_address_label(ip_address) when is_binary(ip_address) and ip_address != "",
    do: ip_address

  defp ip_address_label(_ip_address), do: "not recorded"

  defp datetime_label(datetime, preferences) do
    DateTimeDisplay.format_datetime(datetime, preferences, missing_label: "not yet")
  end
end
